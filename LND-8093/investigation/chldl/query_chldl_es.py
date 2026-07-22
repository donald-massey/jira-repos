"""Query the CHLDL Elasticsearch cluster for the 131 LND-8093 recordIDs.

Auth via env (pick one):
  ES_ENDPOINT   e.g. https://<host>.<region>.gcp.cloud.es.io:9243   (required)
  ES_API_KEY    base64 API key from Kibana -> Stack Management -> API keys
    -- or --
  ES_USER / ES_PWD   basic-auth (Vault: di-secrets/elm/land/courthouse-land-data-loader/elasticsearch)

Usage:
  python query_chldl_es.py                      # sweep all courthouse-*_dbpipeline-*
  python query_chldl_es.py courthouse-abstractplants_dbpipeline-*
"""
import csv
import os
import sys

import requests
from dotenv import load_dotenv

# Paths resolve from this file's location, not cwd, so the script runs from anywhere.
_HERE = os.path.dirname(os.path.abspath(__file__))          # investigation/chldl
_INVESTIGATION = os.path.dirname(_HERE)                     # investigation
_REPO_ROOT = os.path.dirname(_INVESTIGATION)                # repo root

load_dotenv(os.path.join(_REPO_ROOT, ".env"))

RECORD_IDS_CSV = os.path.join(_INVESTIGATION, "records_to_investigate.csv")
OUT_CSV = os.path.join(_HERE, "chldl_es_results.csv")
DEFAULT_INDEX = "courthouse-*_dbpipeline-*"


def load_record_ids(path: str) -> list:
    with open(path, encoding="utf-8-sig", newline="") as f:
        ids = [line.split(",")[3].strip() for line in f.read().splitlines()[1:] if line.strip()]
    return sorted(set(ids))


def main() -> None:
    endpoint = os.environ["ES_ENDPOINT"].rstrip("/")
    index = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_INDEX

    headers = {"Content-Type": "application/json"}
    auth = None
    if os.environ.get("ES_API_KEY"):
        headers["Authorization"] = f"ApiKey {os.environ['ES_API_KEY']}"
    else:
        auth = (os.environ["ES_USER"], os.environ["ES_PWD"])

    ids = load_record_ids(RECORD_IDS_CSV)
    body = {
        "size": len(ids),
        "query": {"terms": {"_id": ids}},
        "_source": ["RecordId", "State", "County", "ImageLocation", "PageCount", "MfgUpdatedAt"],
        "sort": [{"_index": "asc"}],
    }

    resp = requests.post(f"{endpoint}/{index}/_search", headers=headers, auth=auth, json=body, timeout=60)
    resp.raise_for_status()
    hits = resp.json()["hits"]["hits"]

    found = {h["_id"] for h in hits}
    with_chd = sum(1 for h in hits if (h["_source"].get("ImageLocation") or "").startswith("s3://enverus-courthouse-prod-chd-plants"))
    print(f"queried={len(ids)}  found={len(found)}  missing={len(ids) - len(found)}  imageLocation_on_chd_plants={with_chd}")

    with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["recordID", "index", "State", "County", "ImageLocation", "PageCount", "MfgUpdatedAt", "present"])
        for h in hits:
            s = h["_source"]
            w.writerow([h["_id"], h["_index"], s.get("State"), s.get("County"),
                        s.get("ImageLocation"), s.get("PageCount"), s.get("MfgUpdatedAt"), 1])
        for rid in ids:
            if rid not in found:
                w.writerow([rid, "", "", "", "", "", "", 0])
    print(f"wrote {OUT_CSV}")


if __name__ == "__main__":
    main()
