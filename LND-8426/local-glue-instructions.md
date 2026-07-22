# Running kafka-to-adl locally (branch LND-8426)

Reference for running the `land-aws-glue` **kafka-to-adl** job locally in Docker to consume a
single lease from the dev test topic `dp.pres.legalleases.v3_test` and write it to an isolated
Elasticsearch test index (`legal_lease_test_*`), to verify the downstream glue path. All changes
below are on branch `LND-8426` and are **local-test only — revert `main.py` and `docker-compose.yml`
before merging.**

## Prerequisites

- VPN active (the container must reach the dev Kafka brokers and the ES router nodes).
- `C:\tmp\LND-8426` on the host (Docker creates it if missing) — used for generated data.

## Run

```powershell
docker-compose build
docker-compose up
```

## Verify

The ES coordinating (router) nodes of "Elasticsearch DI Regulatory 6x Client" (from cerebro):
`10.25.14.135, 10.25.14.45, 10.25.15.187`.

```powershell
curl -s "http://10.25.14.135:9200/_cat/indices/legal_lease_test*?v"
curl -s "http://10.25.14.135:9200/legal_lease_test_*/_search?q=lease_id:4696618&pretty"
```

## Changes made

### `main.py` — `run_job_locally()`
- Consumes `dp.pres.legalleases.v3_test` from the dev brokers
  (`10.25.15.144,10.25.14.165,10.25.14.52,10.25.10.107,10.25.15.163`, port 9092).
- Uses `LocalFileSystem` (not `S3FileSystem`).
- `source_code_artifact_path` and the ES cache `src_prefix` point at the mounted repo
  (`/opt/diml-service`), so `schema.json` and `es_map/` resolve from source.
- `data_artifact_path=/tmp/data`.
- Builds only an `ElasticSearch6Cache` (no DS9 / S3 / Databricks / Prism), with index bases
  `['landtrac_lease_test','legal_lease_test']` and `manage_alias=False` (index-only: writes the
  timestamped index but never repoints or deletes any live alias).

### `jobs/kafka_to_adl/src/kafka_to_adl.py` — `ElasticSearch6Cache`
- Added `manage_alias: bool = True`. Default preserves production behavior (used by `main()`).
  When `False`, the write still creates the timestamped index with mappings but skips the alias
  update and the old-index deletion.

### `Dockerfile`
- Base image `amazon/aws-glue-libs:glue_libs_1.0.0_image_01` (Spark 2.4 / Scala 2.11 / Py3.6) →
  `public.ecr.aws/glue/aws-glue-libs:5` (Spark 3.5 / Scala 2.12 / Py3.11), to match the
  `jobs/dependencies/*.jar` (Spark 3.5 / Scala 2.12) and the Glue 5.0 production runtime.
- Added `USER root` before the build-time setup — the Glue 5.0 base builds as a non-root user, so
  `useradd`/`pip`/`COPY` fail without it.
- `ENV PYTHONPATH` changed from overwrite to **append** (`${DIML_HOME}:${PYTHONPATH}`) so the base
  image's `awsglue` (`PyGlue.zip`) and `pyspark` stay importable.
- `ENTRYPOINT []` + `CMD ["bash","-lc","export PYTHONPATH=${DIML_HOME}:$PYTHONPATH && exec python3 main.py"]`.
  The Glue 5.0 base sets `ENTRYPOINT ["bash","-l"]`, which turned the exec-form `CMD ["python3","main.py"]`
  into `bash -l python3 main.py` (treating `python3` as a script → "cannot execute binary file").
  Resetting the entrypoint and running via a login shell picks up `SPARK_HOME`/`PYTHONPATH`.

### `requirements.txt`
- `pymssql 2.2.1 → 2.3.13`, `shapely 1.6.4 → 1.8.5` (Python 3.11 wheels; matches prod
  `--additional-python-modules`).
- Pinned `numpy==1.26.4` — `elasticsearch==6.8.2` references `np.float_`, removed in NumPy 2.0
  (which the Glue 5.0 image ships). The 6.x client is required for the ES 6.2.4 cluster.

### `docker-compose.yml`
- Removed the obsolete `version` key.
- `DOCKER_REGISTRY: aws-ecr-ue1.dev.drillinginfo.com` (avoids AWS ECR auth for the `git-auth` stage).
- `user: root` — the Windows bind mounts present as `root:root 0755`, so `diml` (uid 992) can't
  write `/tmp/data` or the CWD (`Mkdirs failed to create ...`).
- Volumes: repo mounted at `/opt/diml-service` (so `local_testing/`, `es_map/`, `schema.json`, and
  the jars resolve from source); `C:\tmp\LND-8426:/tmp/data` for generated data; `.aws` mount.

## Gotchas encountered (in order)

| Symptom | Cause | Fix |
|---|---|---|
| `useradd: Permission denied` | Glue 5.0 base builds as non-root | `USER root` before build steps |
| `python3: cannot execute binary file` | base `ENTRYPOINT ["bash","-l"]` mangled the exec-form CMD | `ENTRYPOINT []` + `bash -lc` CMD |
| `ModuleNotFoundError: No module named 'awsglue'` | `ENV PYTHONPATH` overwrote the base glue paths | append instead of overwrite |
| `AttributeError: np.float_ was removed in NumPy 2.0` | `elasticsearch 6.8.2` vs NumPy 2.0 | pin `numpy==1.26.4` |
| `Mkdirs failed to create file:/tmp/data/...` | root-owned Windows bind mount | `user: root` |
