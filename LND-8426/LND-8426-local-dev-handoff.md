# LND-8426 — Local Dev Handoff (land-lease-producer + land-aws-glue)

Consolidated handoff for the LANDO team. This is the end-to-end local reproduction of
"Recent PA LegalLeases Not Published": publish one known PA lease from **land-lease-producer**
to a test Kafka topic, consume it locally in **land-aws-glue** (kafka-to-adl), and observe
where it drops. Use it to re-verify the finding or extend the checks to other records/states.

## TL;DR finding

The affected records reach Kafka but carry **no land descriptions**, so they have no
`mapping_id`, and the glue `legal_lease` ES writer drops them by design. This was confirmed
against **production** data — it is not a pipeline bug in the producer or glue. The gap is
**upstream in courthouse data loading** (the legal description was never parsed into
`tblLandDescription`, and the lease was never mapped to an abstract in DIV1). See
`LND-8426-pa-mapping-checks.sql` and the finding section below.

## Data flow

```
land-lease-producer (debug mode)
        │  publishes 1 lease
        ▼
Kafka topic  dp.pres.legalleases.v3_test   (dev cluster)
        │  consumed by
        ▼
land-aws-glue  kafka-to-adl  (local Docker, Glue 5.0)
        │  writes
        ▼
Elasticsearch index  legal_lease_test_<date>   (dev "Regulatory 6x Client")
        │
        ▼
record dropped — no mapping_id (0 docs indexed)
```

## Prerequisites (both repos)

- VPN active (containers must reach dev Kafka brokers and dev ES).
- Docker Desktop.
- Fresh AWS session credentials for the producer run (the IIE enricher hits S3).
- The test lease: RecordID `a688f5be-8530-4647-b73d-089c185c8262`, Div1 LeaseID `4696618`,
  COLUMBIA, PA.

---

## Part 1 — land-lease-producer: publish the test lease

Branch `LND-8426`. Three temporary debug overrides — **revert before merging.**

**`lease_producer/land_lease_producer.py`** — restrict to the one county, in the `run()` county loop:
```python
if not (county_name == 'COLUMBIA' and state_abbreviation == 'PA'):
    continue
```

**`data_providers/cstitle_lease_data_provider/cstitle_lease_data_provider.py`** — hardcode the
candidate instrument at the top of `get_modified_instrument_ids()`:
```python
return ['a688f5be-8530-4647-b73d-089c185c8262']
```

**`utilities/kafka_producer.py`** — allow a direct broker override at the top of `_get_brokers()`
(bypasses Consul SRV DNS, which doesn't resolve inside the container). Safe to keep — no-op when
`KAFKA_BROKERS` is unset:
```python
direct = os.environ.get('KAFKA_BROKERS')
if direct:
    return direct
```

**`docker-compose.yml`:**
```yaml
args:
  DOCKER_REGISTRY: aws-ecr-ue1.dev.drillinginfo.com
environment:
  # fresh temp creds — all three required (IIE enricher S3 call fails without the session token)
  - AWS_ACCESS_KEY_ID=<paste fresh key>
  - AWS_SECRET_ACCESS_KEY=<paste fresh secret>
  - AWS_SESSION_TOKEN=<paste fresh session token>
  # direct dev brokers (revolving; from consul kafka-cluster) + test topic
  - KAFKA_BROKERS=10.25.15.144:9092,10.25.14.165:9092,10.25.14.52:9092,10.25.10.107:9092,10.25.15.163:9092
  - OUTPUT_KAFKA_TOPIC=dp.pres.legalleases.v3_test
```
Databases: use the DEV settings block already in the file. **Note:** re-running with **prod**
DIV1 (`V02PDIPRODDIV01.PROD.AUS`) produced the same empty land-description result — the finding
is not a dev-data artifact.

**Run:**
```powershell
docker-compose build
docker-compose up
```
Expected: `Initializing kafka producer to send 1 lease(s) to dp.pres.legalleases.v3_test`,
published with key `lease::4696618`.

---

## Part 2 — land-aws-glue: consume + index locally

Branch `LND-8426`. Runs the kafka-to-adl job locally against the test topic and writes to an
isolated ES **index only** (no alias repoint, no other caches). Full detail in
`local-glue-instructions.md`. **Revert `main.py` and `docker-compose.yml` before merging.**

Changes:
- **`main.py` `run_job_locally()`** — consumes `dp.pres.legalleases.v3_test` from the dev brokers,
  `LocalFileSystem`, ES router nodes `10.25.14.135,10.25.14.45,10.25.15.187`, index base
  `legal_lease_test`, `manage_alias=False` (index-only), only the `ElasticSearch6Cache`.
- **`jobs/kafka_to_adl/src/kafka_to_adl.py`** — `ElasticSearch6Cache` gained `manage_alias`
  (default `True` = prod behavior; `False` writes the index but skips alias repoint + old-index delete).
- **`Dockerfile`** — base image bumped `glue_libs_1.0.0` → `public.ecr.aws/glue/aws-glue-libs:5`
  (Spark 3.5, matches the jars + prod); `USER root` for build; `PYTHONPATH` appended (not
  overwritten); `ENTRYPOINT []` + `bash -lc` CMD to pick up the Glue login-shell env.
- **`requirements.txt`** — `pymssql 2.3.13`, `shapely 1.8.5` (Py3.11); `numpy==1.26.4`
  (elasticsearch 6.8.2 uses `np.float_`, removed in numpy 2.0).
- **`docker-compose.yml`** — dev registry; `user: root` (Windows bind mounts are root-owned);
  repo mounted at `/opt/diml-service`; `C:\tmp\LND-8426:/tmp/data`.

**Run:**
```powershell
docker-compose build
docker-compose up
```

**Verify:**
```powershell
curl -s "http://10.25.14.135:9200/_cat/indices/legal_lease_test*?v"
curl -s "http://10.25.14.135:9200/legal_lease_test_*/_search?q=lease_id:4696618&pretty"
```
A hit means the record indexed; zero docs means it was dropped (the observed result).

### Gotchas encountered migrating the local image to Glue 5.0

| Symptom | Cause | Fix |
|---|---|---|
| `useradd: Permission denied` (build) | Glue 5.0 base builds as non-root | `USER root` before build steps |
| `python3: cannot execute binary file` | base `ENTRYPOINT ["bash","-l"]` mangled the exec-form CMD | `ENTRYPOINT []` + `bash -lc` CMD |
| `ModuleNotFoundError: awsglue` | `ENV PYTHONPATH` overwrote the base glue paths | append instead of overwrite |
| `np.float_ was removed in NumPy 2.0` | elasticsearch 6.8.2 vs numpy 2.0 | pin `numpy==1.26.4` |
| `Mkdirs failed to create file:/tmp/data/...` | root-owned Windows bind mount | `user: root` |

---

## Finding (production-confirmed)

Source-data checks for the test record (`LND-8426-pa-mapping-checks.sql`; DIV1 =
`V02PDIPRODDIV01.PROD.AUS`, CSTitle = `countyScansTitle`):

| Check | Source | Result |
|---|---|---|
| `tblRecord` | CSTitle | record exists |
| `tblLandDescription` (base) | CSTitle | none |
| `TblAddsFields` (PA additional) | CSTitle | none |
| abstract mapping, OH/WV/PA | DIV1 | none |
| abstract mapping, other states | DIV1 | none |
| abstract mapping, any state | DIV1 | none |

The record is a valid lease in CSTitle but has **no land-description data anywhere** — no base
`tblLandDescription`, no PA `TblAddsFields`, and no DIV1 abstract mapping in any state. With no
land descriptions there is no `legacy_mapping_id`, so the `legal_lease` ES writer
(`filter_records_without_mapping_id` = `where(mapping_id IS NOT NULL)`) correctly drops it.

The record still has a document image (`image_link`) and a landtrac polygon (via
`legacy_polygon_group_id`, a separate path), which is why it can appear in `landtrac_lease` but
never `legal_lease`.

## Open question for the team

Working hypothesis (to confirm): PA/OH/WV may lack the land grid used to derive abstract-level
land descriptions, so land descriptions aren't gathered for these areas. If intended, the
resolution is likely an explicit exception for these states rather than a pipeline fix — needs a
team decision on eventual land-description acquisition for PA/OH/WV. Next: confirm the pattern
generalizes on the Jefferson record (`46e238a6-4e63-4f1e-95bf-916083355f24`) and other missing PA
leases.

## References

- Jira LND-8426, comment 5023656 (working history + breadcrumb)
- `LND-8426-pa-mapping-checks.sql` (land-aws-glue, branch LND-8426)
- `local-glue-instructions.md` (land-aws-glue, branch LND-8426)
