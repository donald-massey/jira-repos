# LND-9325: [auto-aliasing] Run image as non-root + add runAsNonRoot to dev chart; pin dev off :latest

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-9325
**Status:** In Progress

**Summary:** auto-aliasing's image and dev CronJob still run as root, so Kyverno denies its pods in dev. Make both run as UID 1000 with `runAsNonRoot`.

**Given:**
Kyverno's `require-run-as-non-root` rule is enforced on the dev cluster. The auto-aliasing dev CronJob (`auto-alias-enricher`, 02:00 daily) runs the root `:latest` image with no `securityContext`, so every Job's pod is denied at admission. Last success was 2026-11-02 and 6 pod-less Jobs are active, because `concurrencyPolicy: Allow` lets them pile up. This follows LND-9275 (COLE, same fix). Prod pins root `1.5.0` and doesn't appear to enforce yet, but will.

**Expect:**

- Dockerfile ends with numeric `USER 1000`, with `--chown` on the copied code (`/opt/app`). It has no `git+ssh` requirements, so the `COPY --from=auth /root/.ssh` layer is dropped and the image carries no keys. `PYTHONDONTWRITEBYTECODE=1`.
- A local run with `--user 1000:1000 --read-only --tmpfs /tmp` matches the root baseline (the enricher runs against its inputs and completes; the pyodbc/ODBC driver still loads).
- The dev CronJob template in `enverus.deployments/land-courthouse/auto-aliasing` sets `runAsNonRoot: true`, and the dev image tag is a branch or release tag, not `latest`.
- The stuck dev Jobs are cleared (needs write access or SRE), and one dev run completes with non-root pods, 0 restarts and no errors.
- Prod is untouched. It follows a release and version bump, in the same PR as the template change.

**Comment (Denison Brennan, 2026-11-09):** Follows LND-9275 (COLE), full design and verification in PR #167 (enverus-ea/land.courthouse-ocr-legals-extractor). Dockerfile (ubuntu:24.04, `HOME=/opt/app`): user `ubuntu` already exists at UID/GID 1000, so no `useradd`; end with numeric `USER 1000`. Add `--chown=1000:1000` to `COPY python_modules ${HOME}/python_modules`, and `install -d -o 1000 -g 1000 ${HOME}`. Drop the `git-auth` stage and `COPY --from=auth /root/.ssh /root/.ssh`. If a private dependency is added later, delete keys in the same `RUN` as `pip install`. `ENV PYTHONDONTWRITEBYTECODE=1`. `pip install` stays root. Chart: in `enverus.deployments/land-courthouse/auto-aliasing/dev/templates/cronjob.yaml` add `securityContext: {runAsNonRoot: true}` at pod level next to `restartPolicy`; set dev `values.yaml` tag to the branch/release tag, replacing `latest`. Don't touch `prod/` until a release exists with the non-root image (prod pins root `1.5.0`; `runAsNonRoot` against a root image fails with `CreateContainerConfigError`) — ship prod template change and tag bump in the same PR. Verify: run locally with `--user 1000:1000 --read-only --tmpfs /tmp:exec,mode=1777` against a root baseline; confirm `python3 python_modules/run_enricher.py` starts and ODBC/`pyodbc` import cleanly. In dev, clear stuck Jobs first (needs write access or SRE), then wait for the 02:00 tick and confirm `runAsNonRoot: true`, 0 restarts, no errors.

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
