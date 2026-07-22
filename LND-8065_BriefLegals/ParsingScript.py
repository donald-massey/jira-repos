import pandas as pd
import re
from datetime import datetime

# ─────────────────────────────────────────────
# CONFIGURATION — update before running
# ─────────────────────────────────────────────
TICKET_NUMBER = "LND-8018"
INPUT_CSV = "brieflegal_export_Ellis_2026-04-17.csv"
OUTPUT_CSV = f"parsed_output_{datetime.today().strftime('%Y-%m-%d')}.csv"

# ─────────────────────────────────────────────
# REGEX PATTERNS
# ─────────────────────────────────────────────

# Lot: LT, LOT, LTS, LOTS, PT LT, PT LOT, PART OF LOT, TCT, TCTS, TR
LOT_PATTERN = re.compile(
    r'\b(?:PART\s+OF\s+LOT|PT\s+LOT|PT\s+LT|PT\s+LTS|LTS|LOTS|LOT|LT|TCTS|TCT|TR)\s+([\w\d&,\-\s]+?)(?=\s+BLK|\s+BLOCK|\s+[A-Z]{2,}|\s*$)',
    re.IGNORECASE
)

# Block: BLK, BLOCK
BLOCK_PATTERN = re.compile(
    r'\b(?:BLK|BLOCK)\s+([\w\d]+)',
    re.IGNORECASE
)

# Abstract: ABSTR NO, ABSTRACT NO, ABSTRACT, ABSTR, A-###, A-### ###
# Captures full abstract+survey strings; multiple values returned comma-separated
ABSTRACT_PATTERN = re.compile(
    r'(?:'
    r'(?:ABSTR(?:ACT)?\s+NO\.?\s*\d+\s+[\w\s\.]+?(?=ABSTR|ABSTRACT|A-\d|\d+\.\d+\s*AC|\d+\.\d+\s*ACRES|$|\s{2,}))'
    r'|(?:A-\d[\d\s]*[\w\s\.]+?(?=ABSTR|ABSTRACT|A-\d|\d+\.\d+\s*AC|\d+\.\d+\s*ACRES|$|\s{2,}))'
    r'|(?:ABSTR\s+\d+\s+[\w\s\.]+?(?=ABSTR|ABSTRACT|A-\d|\d+\.\d+\s*AC|\d+\.\d+\s*ACRES|$|\s{2,}))'
    r')',
    re.IGNORECASE
)

# Acreage: numeric value followed by AC, ACS, ACRES
ACREAGE_PATTERN = re.compile(
    r'(\d+(?:\.\d+)?)\s*(?:ACRES?|ACS?)\b',
    re.IGNORECASE
)

# Quarter calls: NE/4, NW4, SW/4, SE4, N/2, S/2, etc.
QUARTER_PATTERN = re.compile(
    r'\b((?:NE|NW|SW|SE|N|S|E|W)[\/]?\d(?:\s*(?:NE|NW|SW|SE|N|S|E|W)[\/]?\d)*)\b',
    re.IGNORECASE
)

# Tokens to SKIP — do not parse subdivision from these
# NOTE: SEE INSTRUMENT alone is a skip, but SEE INSTRUMENT followed by parseable
# content is handled by stripping the prefix inside parse_subdivision()
SKIP_PATTERNS = [
    re.compile(p, re.IGNORECASE) for p in [
        r'^\s*N/A\s*$',
        r'^SEE\s+INSTRUMENT\s*(?:MULTI\s+\w+)?\s*$',  # SEE INSTRUMENT alone or with MULTI TCTS etc.
        r'^\s*SEE\s+INSTRUMENTS?\s*$',
        r'\bVOL\s+\d+',
        r'\bINSTR(?:UMENT)?\s*(?:NO\.?)?\s*\d+',
        r'\bCAUSE\s+NO\b',
        r'\bIV\s*D\s+CASE\b',
        r'\bTRIBUNAL\s+NO\b',
        r'\bTAXPAYER\s+(?:NO|NUMBER)\b',
        r'\bSERIAL\s+NO\b',
        r'\bTWC\s+TAX\b',
        r'\bCAB\s+\w+\s+SLD\b',
        r'\bMULTIPLE\s+PROPERTIES\b',
        r'\bDEPUTY\s+SHERIFF\b',
        r'\bASST\s+COUNTY\b',
        r'\bANNEXATION\b',
        r'^\s*$',
    ]
]

CITY_SUFFIX = re.compile(
    r'\b((?:CITY\s+OF|TOWN\s+OF|TOWN)\s*(?:[A-Z]+\s*)*)',
    re.IGNORECASE
)

def should_skip(text):
    """Returns True if the BriefLegal value should not be parsed at all."""
    if not isinstance(text, str) or not text.strip():
        return True
    for p in SKIP_PATTERNS:
        if p.search(text):
            return True
    return False

def parse_lot(text):
    m = LOT_PATTERN.search(text)
    if m:
        return m.group(1).strip().rstrip(',').strip()
    return None

def parse_block(text):
    m = BLOCK_PATTERN.search(text)
    if m:
        return m.group(1).strip()
    return None

def parse_abstract(text):
    matches = ABSTRACT_PATTERN.findall(text)
    if matches:
        cleaned = [m.strip().rstrip(',').strip() for m in matches if m.strip()]
        return ', '.join(cleaned) if cleaned else None
    return None

def parse_acreage(text):
    matches = ACREAGE_PATTERN.findall(text)
    if matches:
        return ', '.join(matches)
    return None

def parse_quarter_calls(text):
    matches = QUARTER_PATTERN.findall(text)
    if matches:
        return ', '.join(m.strip() for m in matches)
    return None

def parse_subdivision(text):
    """
    Attempts to extract subdivision name by removing known prefixes
    (lot, block, abstract, acreage, see instrument, etc.) and returning
    what remains as the subdivision name.
    Phases, units, sections remain part of the subdivision name.
    """
    if should_skip(text):
        return None

    working = text.strip()

    # Strip SEE INSTRUMENT prefix if followed by parseable content
    working = re.sub(r'^SEE\s+INSTRUMENT\s*', '', working, flags=re.IGNORECASE).strip()

    # Remove abstract blocks
    working = re.sub(
        r'(?:ABSTR(?:ACT)?\s+(?:NO\.?)?\s*\d+|A-\d[\d\s]*)[\w\s\.\,]*?(?=\d+\.\d+\s*(?:AC|ACRES?)|$|\s{2,})',
        '', working, flags=re.IGNORECASE
    ).strip()

    # Remove acreage
    working = re.sub(r'\d+(?:\.\d+)?\s*(?:ACRES?|ACS?)\b', '', working, flags=re.IGNORECASE).strip()

    # Remove lot prefix
    working = re.sub(
        r'^(?:PART\s+OF\s+LOT|PT\s+LOT|PT\s+LT|PT\s+LTS|LTS|LOTS|LOT|LT|TCTS|TCT|TR)\s+[\w\d&,\-\s]+?(?=\s+BLK|\s+BLOCK|\s+[A-Z]{3,})',
        '', working, flags=re.IGNORECASE
    ).strip()

    # Remove block prefix
    working = re.sub(r'^(?:BLK|BLOCK)\s+\w+\s*', '', working, flags=re.IGNORECASE).strip()

    # Remove volume/page/instrument refs
    working = re.sub(r'\bVOL\s+\d+[\w\s]*PG\w*\s*\d+', '', working, flags=re.IGNORECASE)
    working = re.sub(r'\bINSTR(?:UMENT)?\s*(?:NO\.?)?\s*[\d#]+', '', working, flags=re.IGNORECASE)

    # Remove stray leading punctuation
    working = re.sub(r'^[\s,\.]+', '', working).strip()

    if not working or len(working) < 3:
        return None

    if re.match(r'^\d+$', working):
        return None

    return working.strip()

# ─────────────────────────────────────────────
# MAIN PROCESSING
# ─────────────────────────────────────────────

def process(input_csv, output_csv, ticket_number):
    # FIX: treat "NULL" string exports from SQL Server as real nulls
    df = pd.read_csv(input_csv, dtype=str, na_values=['NULL', 'null', 'N/A', ''])
    df = df.where(pd.notnull(df), None)

    results = []
    summary = {
        'total_rows': len(df),
        'skipped_no_brief_legal': 0,
        'skipped_skip_pattern': 0,
        'subdivision_would_populate': 0,
        'subdivision_already_populated_skipped': 0,
        'lot_would_populate': 0,
        'block_would_populate': 0,
        'abstract_would_populate': 0,
        'acreage_would_populate': 0,
        'quarter_calls_would_populate': 0,
        'multi_value_warning': 0,
    }

    for _, row in df.iterrows():
        brief = row.get('BriefLegal')
        record_id = row.get('RecordID')
        land_desc_id = row.get('LandDescriptionID')

        result = {
            'RecordID': record_id,
            'LandDescriptionID': land_desc_id,
            'BriefLegal': brief,
            'Parsed_Subdivision': None,
            'Parsed_Lot': None,
            'Parsed_Block': None,
            'Parsed_AbstractName': None,
            'Parsed_AcreageByTract': None,
            'Parsed_QuarterCalls': None,
            'Existing_Subdivision': row.get('Subdivision'),
            'Existing_Lot': row.get('Lot'),
            'Existing_Block': row.get('Block'),
            'Existing_AbstractName': row.get('AbstractName'),
            'Existing_AcreageByTract': row.get('AcreageByTract'),
            'Existing_QuarterCalls': row.get('QuarterCalls'),
            'Action': '',
            'Notes': '',
            'TicketNumber': ticket_number,
        }

        if not isinstance(brief, str) or not brief.strip():
            summary['skipped_no_brief_legal'] += 1
            result['Action'] = 'SKIP'
            result['Notes'] = 'No BriefLegal value'
            results.append(result)
            continue

        if should_skip(brief):
            summary['skipped_skip_pattern'] += 1
            result['Action'] = 'SKIP'
            result['Notes'] = 'Matches skip pattern (VOL/INSTR/SEE INSTRUMENT alone/N/A/etc.)'
            results.append(result)
            continue

        notes = []

        parsed_sub = parse_subdivision(brief)
        parsed_lot = parse_lot(brief)
        parsed_block = parse_block(brief)
        parsed_abstract = parse_abstract(brief)
        parsed_acreage = parse_acreage(brief)
        parsed_qc = parse_quarter_calls(brief)

        def should_write(parsed, existing):
            return parsed and (not existing or str(existing).strip() == '')

        if should_write(parsed_sub, row.get('Subdivision')):
            result['Parsed_Subdivision'] = parsed_sub
            summary['subdivision_would_populate'] += 1
        elif parsed_sub:
            summary['subdivision_already_populated_skipped'] += 1
            notes.append('Subdivision already populated — skipped')

        if should_write(parsed_lot, row.get('Lot')):
            result['Parsed_Lot'] = parsed_lot
            summary['lot_would_populate'] += 1

        if should_write(parsed_block, row.get('Block')):
            result['Parsed_Block'] = parsed_block
            summary['block_would_populate'] += 1

        if should_write(parsed_abstract, row.get('AbstractName')):
            result['Parsed_AbstractName'] = parsed_abstract
            summary['abstract_would_populate'] += 1

        if should_write(parsed_acreage, row.get('AcreageByTract')):
            result['Parsed_AcreageByTract'] = parsed_acreage
            summary['acreage_would_populate'] += 1

        if should_write(parsed_qc, row.get('QuarterCalls')):
            result['Parsed_QuarterCalls'] = parsed_qc
            summary['quarter_calls_would_populate'] += 1

        for field, val in [('Lot', parsed_lot), ('Block', parsed_block)]:
            if val and any(sep in str(val) for sep in ['&', ',', '-']):
                notes.append(f'⚠️ Multi-value {field} detected — verify against discrete tract rows')
                summary['multi_value_warning'] += 1

        has_any_change = any([
            result['Parsed_Subdivision'],
            result['Parsed_Lot'],
            result['Parsed_Block'],
            result['Parsed_AbstractName'],
            result['Parsed_AcreageByTract'],
            result['Parsed_QuarterCalls'],
        ])

        result['Action'] = 'UPDATE' if has_any_change else 'NO CHANGE'
        result['Notes'] = '; '.join(notes) if notes else ''
        results.append(result)

    output_df = pd.DataFrame(results)
    output_df.to_csv(output_csv, index=False)

    print("=" * 60)
    print(f"PARSING SUMMARY — {ticket_number}")
    print("=" * 60)
    print(f"Total rows processed:                {summary['total_rows']}")
    print(f"Skipped (no BriefLegal):             {summary['skipped_no_brief_legal']}")
    print(f"Skipped (skip pattern match):        {summary['skipped_skip_pattern']}")
    print(f"")
    print(f"Would populate Subdivision:          {summary['subdivision_would_populate']}")
    print(f"Subdivision already populated:       {summary['subdivision_already_populated_skipped']}")
    print(f"Would populate Lot:                  {summary['lot_would_populate']}")
    print(f"Would populate Block:                {summary['block_would_populate']}")
    print(f"Would populate AbstractName:         {summary['abstract_would_populate']}")
    print(f"Would populate AcreageByTract:       {summary['acreage_would_populate']}")
    print(f"Would populate QuarterCalls:         {summary['quarter_calls_would_populate']}")
    print(f"")
    print(f"⚠️  Multi-value warnings (review):   {summary['multi_value_warning']}")
    print(f"")
    print(f"Output written to: {output_csv}")
    print("=" * 60)
    print()
    print("NEXT STEPS:")
    print("  1. Open the output CSV and review rows where Action = UPDATE")
    print("  2. Spot-check Parsed_Subdivision against BriefLegal values")
    print("  3. Review all rows flagged with multi-value warnings")
    print("  4. Decide how to handle multi-lot BriefLegal rows (see Step 5)")
    print("  5. When satisfied, proceed to Step 6 (update script)")

if __name__ == '__main__':
    process(INPUT_CSV, OUTPUT_CSV, TICKET_NUMBER)