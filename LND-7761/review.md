# LND-7761 - Land org repo archive review

All **119 active** repos in the Land org, grouped by recommended verdict.

## How to review

- **Check the `keep` box** on any repo that should stay (exclude from archiving).
- Add your initials + reasoning in the `notes:` slot, especially for anything you keep or flag.
- Leave a box unchecked to accept the recommended verdict.
- **DAG**-tagged repos must have their Airflow DAG removed *before* archiving even if not kept.

**Tags:** `migr-push` = pushed_at is GitHub-migration noise (push/update years) | `DAG` = ships an Airflow dag | `nomad` = has a Nomad job template | `clone` = a local clone exists.

**Counts:** ARCHIVE 47 | CHECK 50 | KEEP? 5 | KEEP 17

## ARCHIVE (47)

_Recommend archiving. Reviewer: check `keep` to veto._

- [ ] [captcha](https://git.drillinginfo.com/Land/captcha) - updated 2019-08-06 - stale since 2019, standalone  
  notes: 
- [ ] [chd-tif2pdf-s3batchop-csvgen-prefect](https://git.drillinginfo.com/Land/chd-tif2pdf-s3batchop-csvgen-prefect) - updated 2022-01-22 - empty repo  
  notes: 
- [ ] [chdplant-instrument-deduper](https://git.drillinginfo.com/Land/chdplant-instrument-deduper) - updated 2021-04-09 - stale since 2021, standalone  
  notes: 
- [ ] [County-Gap-Checker](https://git.drillinginfo.com/Land/County-Gap-Checker) - updated 2021-06-22 - stale since 2021, standalone  
  notes: 
- [ ] [courthouseDirectDbRDS](https://git.drillinginfo.com/Land/courthouseDirectDbRDS) - updated 2022-07-18 - empty repo  
  notes: 
- [ ] [CoverageDateAnalysis](https://git.drillinginfo.com/Land/CoverageDateAnalysis) - updated 2021-11-06 - stale since 2021, standalone  
  notes: 
- [ ] [CSTitle_Loader](https://git.drillinginfo.com/Land/CSTitle_Loader) - updated 2020-04-29 - stale since 2020, standalone  
  notes: 
- [ ] [CSTitle_Loader_SyndicateLite](https://git.drillinginfo.com/Land/CSTitle_Loader_SyndicateLite) - updated 2020-04-29 - stale since 2020, standalone  
  notes: 
- [ ] [DataClean_Title](https://git.drillinginfo.com/Land/DataClean_Title) - updated 2023-01-18 - empty repo  
  notes: 
- [ ] [DepthSeverancesOCR](https://git.drillinginfo.com/Land/DepthSeverancesOCR) - updated 2019-05-10 - stale since 2019, standalone  
  notes: 
- [ ] [DID_AssignmentsSupervisor](https://git.drillinginfo.com/Land/DID_AssignmentsSupervisor) - updated 2017-10-06 - stale since 2017, standalone; migr-push(2026/2017)  
  notes: 
- [ ] [DID_CourthouseSupervisor](https://git.drillinginfo.com/Land/DID_CourthouseSupervisor) - updated 2017-11-22 - stale since 2017, standalone; migr-push(2026/2017)  
  notes: 
- [ ] [DID_Employee](https://git.drillinginfo.com/Land/DID_Employee) - updated 2017-10-03 - stale since 2018, standalone  
  notes: 
- [ ] [DID_HistprodUpdates](https://git.drillinginfo.com/Land/DID_HistprodUpdates) - updated 2017-10-18 - stale since 2017, standalone  
  notes: 
- [ ] [DID_ImageViewerExtension](https://git.drillinginfo.com/Land/DID_ImageViewerExtension) - updated 2017-10-03 - stale since 2017, standalone  
  notes: 
- [ ] [DID_LeadToolsLicense](https://git.drillinginfo.com/Land/DID_LeadToolsLicense) - updated 2021-12-13 - stale since 2021, standalone  
  notes: 
- [ ] [DID_LUG](https://git.drillinginfo.com/Land/DID_LUG) - updated 2020-08-03 - stale since 2020, standalone  
  notes: 
- [ ] [DID_NDAssignmentsDownloader](https://git.drillinginfo.com/Land/DID_NDAssignmentsDownloader) - updated 2017-10-03 - stale since 2017, standalone  
  notes: 
- [ ] [DID_ProductionPublisher](https://git.drillinginfo.com/Land/DID_ProductionPublisher) - updated 2017-11-07 - stale since 2017, standalone  
  notes: 
- [ ] [DID_SQLbasics](https://git.drillinginfo.com/Land/DID_SQLbasics) - updated 2017-10-03 - stale since 2017, standalone; migr-push(2022/2017)  
  notes: 
- [ ] [DID_WebApps](https://git.drillinginfo.com/Land/DID_WebApps) - updated 2017-11-16 - stale since 2017, standalone  
  notes: 
- [ ] [DID_WellLogDigitization](https://git.drillinginfo.com/Land/DID_WellLogDigitization) - updated 2017-11-07 - stale since 2017, standalone  
  notes: 
- [ ] [directional-survey-scripts](https://git.drillinginfo.com/Land/directional-survey-scripts) - updated 2020-02-21 - stale since 2020, standalone  
  notes: 
- [ ] [docker-database](https://git.drillinginfo.com/Land/docker-database) - updated 2021-04-09 - stale since 2021, standalone  
  notes: 
- [ ] [gis-att-export](https://git.drillinginfo.com/Land/gis-att-export) - updated 2021-05-28 - stale since 2021, standalone  
  notes: 
- [ ] [grid-convergence-reporting-backup-tables](https://git.drillinginfo.com/Land/grid-convergence-reporting-backup-tables) - updated 2019-09-18 - stale since 2019, standalone  
  notes: 
- [ ] [HackthonGit](https://git.drillinginfo.com/Land/HackthonGit) - updated 2022-08-23 - test/experiment  
  notes: 
- [ ] [image-drive-map](https://git.drillinginfo.com/Land/image-drive-map) - updated 2021-11-30 - stale since 2021, standalone  
  notes: 
- [ ] [indentify-closure-azimuth](https://git.drillinginfo.com/Land/indentify-closure-azimuth) - updated 2019-09-26 - stale since 2019, standalone  
  notes: 
- [ ] [land-dash](https://git.drillinginfo.com/Land/land-dash) - updated 2019-05-06 - stale since 2019, standalone  
  notes: 
- [ ] [land_notifications](https://git.drillinginfo.com/Land/land_notifications) - updated 2021-07-15 - stale since 2021, standalone  
  notes: 
- [ ] [landex_scraper_downloader](https://git.drillinginfo.com/Land/landex_scraper_downloader) - updated 2021-10-14 - stale since 2021, standalone  
  notes: 
- [ ] [landpres-loader](https://git.drillinginfo.com/Land/landpres-loader) - updated 2020-05-20 - stale since 2020, standalone  
  notes: 
- [ ] [las-hot-folder](https://git.drillinginfo.com/Land/las-hot-folder) - updated 2020-07-28 - stale since 2020, standalone  
  notes: 
- [ ] [mapzone-queue-generator](https://git.drillinginfo.com/Land/mapzone-queue-generator) - updated 2020-04-08 - stale since 2020, standalone  
  notes: 
- [ ] [midlandmap-shapefile-scripts](https://git.drillinginfo.com/Land/midlandmap-shapefile-scripts) - updated 2020-02-10 - stale since 2020, standalone  
  notes: 
- [ ] [operator-aliasing-plugin](https://git.drillinginfo.com/Land/operator-aliasing-plugin) - updated 2018-06-19 - stale since 2018, standalone  
  notes: 
- [ ] [redash-nginx](https://git.drillinginfo.com/Land/redash-nginx) - updated 2018-03-21 - stale since 2018, standalone  
  notes: 
- [ ] [share-ds-survey-data](https://git.drillinginfo.com/Land/share-ds-survey-data) - updated 2020-04-29 - stale since 2020, standalone  
  notes: 
- [ ] [sql-hcl-mapper](https://git.drillinginfo.com/Land/sql-hcl-mapper) - updated 2020-11-17 - stale since 2020, standalone  
  notes: 
- [ ] [test_repo_sam_yesipov](https://git.drillinginfo.com/Land/test_repo_sam_yesipov) - updated 2021-12-09 - empty repo  
  notes: 
- [ ] [thoughttrace-api-helper](https://git.drillinginfo.com/Land/thoughttrace-api-helper) - updated 2019-09-17 - stale since 2019, standalone  
  notes: 
- [ ] [volpgfromocr](https://git.drillinginfo.com/Land/volpgfromocr) - updated 2019-05-09 - stale since 2019, standalone  
  notes: 
- [ ] [WEBSITE_IMAGE_AUTO_EXPORTER_DI2.0](https://git.drillinginfo.com/Land/WEBSITE_IMAGE_AUTO_EXPORTER_DI2.0) - updated 2020-07-14 - stale since 2020, standalone  
  notes: 
- [ ] [well-log-scraper](https://git.drillinginfo.com/Land/well-log-scraper) - updated 2020-03-20 - stale since 2020, standalone  
  notes: 
- [ ] [well-log-updates](https://git.drillinginfo.com/Land/well-log-updates) - updated 2020-10-15 - stale since 2020, standalone  
  notes: 
- [ ] [xlrd](https://git.drillinginfo.com/Land/xlrd) - updated 2019-04-09 - stale since 2019, standalone  
  notes: 

## CHECK (50)

_Needs a decision. Reviewer: check `keep` to retain, or leave unchecked and note "archive"._

- [ ] [Application-Utilities](https://git.drillinginfo.com/Land/Application-Utilities) - updated 2023-04-19 - mid-age (2023)  
  notes: 
- [ ] [assignment-exporter](https://git.drillinginfo.com/Land/assignment-exporter) - updated 2023-05-04 - ships DAG - remove/verify before archive; migr-push(2025/2023), DAG, nomad  
  notes: 
- [ ] [automated-stapler](https://git.drillinginfo.com/Land/automated-stapler) - updated 2022-08-10 - you keep a local clone (active?); migr-push(2026/2022), clone  
  notes: 
- [ ] [backlog-reporting-updater](https://git.drillinginfo.com/Land/backlog-reporting-updater) - updated 2019-06-18 - ships DAG - remove/verify before archive; DAG  
  notes: 
- [ ] [bdd-di-producing-unit-datum-conversion](https://git.drillinginfo.com/Land/bdd-di-producing-unit-datum-conversion) - updated 2022-09-07 - mid-age (2022)  
  notes: 
- [ ] [blm_state_lease_loader](https://git.drillinginfo.com/Land/blm_state_lease_loader) - updated 2026-06-24 - you keep a local clone (active?); clone  
  notes: 
- [ ] [brief-legals-parser](https://git.drillinginfo.com/Land/brief-legals-parser) - updated 2025-10-07 - you keep a local clone (active?); clone  
  notes: 
- [ ] [caddo-courthouse-custom-export](https://git.drillinginfo.com/Land/caddo-courthouse-custom-export) - updated 2021-09-07 - ships DAG - remove/verify before archive; DAG  
  notes: 
- [ ] [ch-database-exports](https://git.drillinginfo.com/Land/ch-database-exports) - updated 2026-04-27 - you keep a local clone (active?); DAG, nomad, clone  
  notes: 
- [ ] [ch-lease-exporter](https://git.drillinginfo.com/Land/ch-lease-exporter) - updated 2026-04-30 - you keep a local clone (active?); DAG, nomad, clone  
  notes: 
- [ ] [ch-lease-image-uploader](https://git.drillinginfo.com/Land/ch-lease-image-uploader) - updated 2022-06-08 - ships DAG - remove/verify before archive; migr-push(2025/2022), DAG, nomad  
  notes: 
- [ ] [ch-reporting-service](https://git.drillinginfo.com/Land/ch-reporting-service) - updated 2019-05-06 - has Nomad job template (may be live); nomad  
  notes: 
- [ ] [chd-tif2pdf-s3batchop-csvgen](https://git.drillinginfo.com/Land/chd-tif2pdf-s3batchop-csvgen) - updated 2021-03-18 - mid-age (2022)  
  notes: 
- [ ] [common-sql-scripts](https://git.drillinginfo.com/Land/common-sql-scripts) - updated 2022-03-01 - mid-age (2022)  
  notes: 
- [ ] [courthouse-mfg](https://git.drillinginfo.com/Land/courthouse-mfg) - updated 2026-04-14 - you keep a local clone (active?); DAG, clone  
  notes: 
- [ ] [cs-digital-mfg](https://git.drillinginfo.com/Land/cs-digital-mfg) - updated 2026-06-23 - you keep a local clone (active?); DAG, nomad, clone  
  notes: 
- [ ] [csdigital-to-assignments-etl](https://git.drillinginfo.com/Land/csdigital-to-assignments-etl) - updated 2026-01-28 - you keep a local clone (active?); DAG, nomad, clone  
  notes: 
- [ ] [csdigital-to-cstitle](https://git.drillinginfo.com/Land/csdigital-to-cstitle) - updated 2026-04-23 - you keep a local clone (active?); DAG, nomad, clone  
  notes: 
- [ ] [csdigital-to-ds9-etl](https://git.drillinginfo.com/Land/csdigital-to-ds9-etl) - updated 2019-05-09 - ships DAG - remove/verify before archive; migr-push(2021/2019), DAG, nomad  
  notes: 
- [ ] [csdigital_manifests_prod2dev](https://git.drillinginfo.com/Land/csdigital_manifests_prod2dev) - updated 2022-01-27 - mid-age (2022)  
  notes: 
- [ ] [cstitle-to-kafka-pres](https://git.drillinginfo.com/Land/cstitle-to-kafka-pres) - updated 2026-03-18 - you keep a local clone (active?); DAG, nomad, clone  
  notes: 
- [ ] [cstitle_assignments_img_urlloader](https://git.drillinginfo.com/Land/cstitle_assignments_img_urlloader) - updated 2024-02-13 - you keep a local clone (active?); DAG, nomad, clone  
  notes: 
- [ ] [di-courthouse2-image-exporter](https://git.drillinginfo.com/Land/di-courthouse2-image-exporter) - updated 2023-12-05 - ships DAG - remove/verify before archive; migr-push(2025/2023), DAG, nomad  
  notes: 
- [ ] [DID_AssignmentsQC](https://git.drillinginfo.com/Land/DID_AssignmentsQC) - updated 2022-08-30 - mid-age (2022); migr-push(2025/2022)  
  notes: 
- [ ] [DID_CourthouseLeasingEmployee](https://git.drillinginfo.com/Land/DID_CourthouseLeasingEmployee) - updated 2017-12-08 - possible DLL dep of active DID combined-form apps  
  notes: 
- [ ] [DID_CourthouseLeasingSendMail](https://git.drillinginfo.com/Land/DID_CourthouseLeasingSendMail) - updated 2017-12-11 - possible DLL dep of active DID combined-form apps; migr-push(2022/2017)  
  notes: 
- [ ] [DID_RSTIFAS](https://git.drillinginfo.com/Land/DID_RSTIFAS) - updated 2022-11-16 - mid-age (2023)  
  notes: 
- [ ] [digital-clerk-handler](https://git.drillinginfo.com/Land/digital-clerk-handler) - updated 2026-06-23 - you keep a local clone (active?); DAG, nomad, clone  
  notes: 
- [ ] [diml-depth-extractor](https://git.drillinginfo.com/Land/diml-depth-extractor) - updated 2019-05-09 - has Nomad job template (may be live); nomad  
  notes: 
- [ ] [diml-loaders](https://git.drillinginfo.com/Land/diml-loaders) - updated 2026-04-08 - you keep a local clone (active?); DAG, nomad, clone  
  notes: 
- [ ] [gathered-batch-handler](https://git.drillinginfo.com/Land/gathered-batch-handler) - updated 2026-06-10 - you keep a local clone (active?); nomad, clone  
  notes: 
- [ ] [ground-truth-editor](https://git.drillinginfo.com/Land/ground-truth-editor) - updated 2026-04-23 - you keep a local clone (active?); clone  
  notes: 
- [ ] [land-aws-glue](https://git.drillinginfo.com/Land/land-aws-glue) - updated 2026-06-10 - you keep a local clone (active?); clone  
  notes: 
- [ ] [land-lease-ocr](https://git.drillinginfo.com/Land/land-lease-ocr) - updated 2020-06-24 - has Nomad job template (may be live); nomad  
  notes: 
- [ ] [land-lease-producer](https://git.drillinginfo.com/Land/land-lease-producer) - updated 2026-03-02 - you keep a local clone (active?); DAG, nomad, clone  
  notes: 
- [ ] [land-manufacturing-scripts](https://git.drillinginfo.com/Land/land-manufacturing-scripts) - updated 2022-03-24 - mid-age (2022)  
  notes: 
- [ ] [land-sla-reporter](https://git.drillinginfo.com/Land/land-sla-reporter) - updated 2020-04-27 - ships DAG - remove/verify before archive; migr-push(2022/2020), DAG  
  notes: 
- [ ] [landtrac-unit-to-kafka](https://git.drillinginfo.com/Land/landtrac-unit-to-kafka) - updated 2022-08-15 - ships DAG - remove/verify before archive; migr-push(2025/2022), DAG, nomad  
  notes: 
- [ ] [LDI-tools](https://git.drillinginfo.com/Land/LDI-tools) - updated 2026-06-23 - you keep a local clone (active?); clone  
  notes: 
- [ ] [lg-geoprocessing](https://git.drillinginfo.com/Land/lg-geoprocessing) - updated 2021-04-01 - ships DAG - remove/verify before archive; DAG, nomad  
  notes: 
- [ ] [LND-2643](https://git.drillinginfo.com/Land/LND-2643) - updated 2022-02-11 - mid-age (2022)  
  notes: 
- [ ] [LUG_Image_to_FTP](https://git.drillinginfo.com/Land/LUG_Image_to_FTP) - updated 2023-06-03 - mid-age (2023)  
  notes: 
- [ ] [midland-maps-converter](https://git.drillinginfo.com/Land/midland-maps-converter) - updated 2022-03-03 - ships DAG - remove/verify before archive; migr-push(2025/2022), DAG, nomad  
  notes: 
- [ ] [midlandmaps-to-kafka](https://git.drillinginfo.com/Land/midlandmaps-to-kafka) - updated 2023-06-12 - you keep a local clone (active?); migr-push(2026/2023), DAG, nomad, clone  
  notes: 
- [ ] [mineral-appraisal-parser](https://git.drillinginfo.com/Land/mineral-appraisal-parser) - updated 2018-04-30 - has Nomad job template (may be live); nomad  
  notes: 
- [ ] [ndrin_url_scraper](https://git.drillinginfo.com/Land/ndrin_url_scraper) - updated 2022-06-17 - mid-age (2022)  
  notes: 
- [ ] [nondigital-cstitle-loader](https://git.drillinginfo.com/Land/nondigital-cstitle-loader) - updated 2026-06-04 - you keep a local clone (active?); DAG, nomad, clone  
  notes: 
- [ ] [ok-county-records-scraper](https://git.drillinginfo.com/Land/ok-county-records-scraper) - updated 2020-09-21 - ships DAG - remove/verify before archive; DAG  
  notes: 
- [ ] [process-digital-clerk](https://git.drillinginfo.com/Land/process-digital-clerk) - updated 2017-04-25 - you keep a local clone (active?); nomad, clone  
  notes: 
- [ ] [vault-helper](https://git.drillinginfo.com/Land/vault-helper) - updated 2022-02-08 - mid-age (2022)  
  notes: 

## KEEP? (5)

_Lean keep. Check `keep` to confirm._

- [ ] [bulk-fileviewer-updates](https://git.drillinginfo.com/Land/bulk-fileviewer-updates) - updated 2024-01-03 - fairly recent  
  notes: 
- [ ] [InstrumentTypeAliasing](https://git.drillinginfo.com/Land/InstrumentTypeAliasing) - updated 2024-11-20 - fairly recent  
  notes: 
- [ ] [land-prefect-agent](https://git.drillinginfo.com/Land/land-prefect-agent) - updated 2023-11-07 - fairly recent; nomad  
  notes: 
- [ ] [Retool](https://git.drillinginfo.com/Land/Retool) - updated 2023-04-04 - fairly recent  
  notes: 
- [ ] [Retool-Dev](https://git.drillinginfo.com/Land/Retool-Dev) - updated 2024-05-08 - fairly recent  
  notes: 

## KEEP (17)

_Active - keep. Pre-checked; uncheck only if you disagree._

- [x] [auto-aliasing](https://git.drillinginfo.com/Land/auto-aliasing) - updated 2025-11-17 - recent real activity  
  notes: 
- [x] [ch-digital-to-title](https://git.drillinginfo.com/Land/ch-digital-to-title) - updated 2026-02-18 - recent real activity; DAG, nomad  
  notes: 
- [x] [chdtitle-missing-image-backfill](https://git.drillinginfo.com/Land/chdtitle-missing-image-backfill) - updated 2026-03-09 - recent real activity; DAG, nomad  
  notes: 
- [x] [CHDTitleQC](https://git.drillinginfo.com/Land/CHDTitleQC) - updated 2026-05-27 - recent real activity  
  notes: 
- [x] [cstitle-to-chd-exporter](https://git.drillinginfo.com/Land/cstitle-to-chd-exporter) - updated 2026-02-04 - recent real activity; DAG, nomad  
  notes: 
- [x] [DID_AssignmentsDataEntry](https://git.drillinginfo.com/Land/DID_AssignmentsDataEntry) - updated 2025-09-10 - recent real activity  
  notes: 
- [x] [DID_CourthouseLeasingEntry](https://git.drillinginfo.com/Land/DID_CourthouseLeasingEntry) - updated 2026-01-28 - recent real activity  
  notes: 
- [x] [DID_CourthouseLeasingQC](https://git.drillinginfo.com/Land/DID_CourthouseLeasingQC) - updated 2026-03-09 - recent real activity  
  notes: 
- [x] [instrument-type-alias-enricher](https://git.drillinginfo.com/Land/instrument-type-alias-enricher) - updated 2026-06-18 - recent real activity  
  notes: 
- [x] [land-team-databases](https://git.drillinginfo.com/Land/land-team-databases) - updated 2026-05-19 - recent real activity  
  notes: 
- [x] [land.lando-utilities](https://git.drillinginfo.com/Land/land.lando-utilities) - updated 2026-04-28 - recent real activity  
  notes: 
- [x] [LeaseGranteeAliasing](https://git.drillinginfo.com/Land/LeaseGranteeAliasing) - updated 2026-04-09 - recent real activity  
  notes: 
- [x] [midland-map-shapefile-converter](https://git.drillinginfo.com/Land/midland-map-shapefile-converter) - updated 2024-03-05 - recent real activity; DAG, nomad  
  notes: 
- [x] [mineral-appraisals-parsing](https://git.drillinginfo.com/Land/mineral-appraisals-parsing) - updated 2025-06-05 - recent real activity  
  notes: 
- [x] [Mineral_Appraisal](https://git.drillinginfo.com/Land/Mineral_Appraisal) - updated 2025-01-07 - recent real activity  
  notes: 
- [x] [parcel-enricher](https://git.drillinginfo.com/Land/parcel-enricher) - updated 2026-06-05 - recent real activity  
  notes: 
- [x] [subdivision-alias-enricher](https://git.drillinginfo.com/Land/subdivision-alias-enricher) - updated 2026-06-08 - recent real activity  
  notes: 
