# LND-8655 — Query 2: Pipeline Verification (record `7f84be77`)

**Record:** `7f84be77-3052-485b-a438-f2e17b5aa100` (Beauregard, LA — REOGL)
**DIV1 LeaseID:** 5250310 · **exportLogID (original):** 11344487 · **exportDate:** 2026-04-21

Only actionable record in the ticket — legal is in the PDF, `tblLandDescription` was
never keyed. Remediation = rekey → delete old `tblexportLog` row → re-export → verify.
The other 23 records are document-type limitations (CO2 releases / offshore coordinate
leases) and are not rekeyable.

## Gate checklist

| Gate | Where | Pass condition | Result | Date |
|---|---|---|---|---|
| 1. Rekey landed | CSTitle `tblLandDescription` (query A) | ≥1 row, IsDeleted=0, S/T/R or BriefLegal populated | ☐ pending | |
| 2. Re-export | CSTitle `tblexportLog` (query B) | new row, fresh exportLogID, leaseID 5250310 | ☐ pending | |
| 3. mapping_id created | DIV1 `tblleaseAbstractMapping` (query C) | ≥1 row for LeaseID 5250310 | ☐ pending | |
| 4. Published | ES `legal_lease` (es_legal_lease_check.json) | ≥1 hit on lease_id 5250310 | ☐ pending | |

Gate 3 is decisive — glue's `filter_records_without_mapping_id()` drops anything with
a null mapping_id. Gates 1→2 are the manual prerequisites (keyers, then the manual
`tblexportLog` delete); 2→3→4 flow automatically on the next exporter/producer/glue run.

## Notes / observations

_(fill in as each gate is checked)_