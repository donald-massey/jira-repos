"""
Check Elasticsearch for repaired records that should be published
(repaired 08-14, pipeline runs 5 AM UTC daily, so 3 runs have passed).
Hits the courthouse-chdplants_v2 alias on the ES8 cluster.
"""

import os
from elasticsearch import Elasticsearch

ES_HOST = os.environ.get("ES_HOST", "https://your-es8-host:9200")
ES_API_KEY = os.environ.get("ES_API_KEY", "")

# 08-14 repaired records — should be in ES by now
RECORD_IDS = [
    "00dc069f-708f-440e-a298-dcb0226b6db2",
    "015ca42c-35d0-4533-9e31-ae2c5c319dee",
    "19e360e4-cfff-4d69-ae8b-065cd76112ed",
    "1a381ff5-d9ea-4c8d-94de-1afe3dd69c6e",
    "1a3ac7dc-ceb6-4394-84a4-be6da71440b9",
]

es = Elasticsearch(ES_HOST, api_key=ES_API_KEY, verify_certs=False)

query = {
    "query": {
        "terms": {
            "record_id.keyword": RECORD_IDS
        }
    },
    "_source": ["record_id", "image_url", "page_count", "file_size_bytes", "status_id"],
    "size": len(RECORD_IDS)
}

resp = es.search(index="courthouse-chdplants_v2", body=query)
hits = resp["hits"]["hits"]
print(f"Found {len(hits)}/{len(RECORD_IDS)} records in ES")
for h in hits:
    src = h["_source"]
    print(f"  {src.get('record_id')} | image_url={src.get('image_url')} | pages={src.get('page_count')} | status={src.get('status_id')}")

missing = set(RECORD_IDS) - {h["_source"].get("record_id") for h in hits}
if missing:
    print(f"\nMissing from ES ({len(missing)}):")
    for r in sorted(missing):
        print(f"  {r}")
