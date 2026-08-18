/* ============================================================================
   LND-8425 — REVERT / RESTORE for the tblexportLog delete (remediation step 2)

   Before clearing the stale export-log row (to force ch-lease-exporter to
   re-select the newly-keyed record 68125b82), the exact row was captured so it
   can be re-inserted verbatim if the re-export needs to be undone.

   Snapshot taken: 2026-08-14 (post-overnight-keying) from
     [countyScansTitle].[dbo].[tblexportLog]  on AUS2-DTF-PAP01V.NA.DRILLINGINFO.COM
     WHERE recordID = '68125b82-1ae2-4058-a46f-f3e46709e47b'   (1 row).

   exportLogID is an IDENTITY column, so IDENTITY_INSERT must be toggled to
   restore the original key value (7536774).

   RUN THIS ONLY TO REVERT — i.e. if the delete+re-export must be rolled back and
   the record put back into its prior "already exported, do not re-select" state.
   Verify the row is absent first (the delete succeeded) before restoring.
   ============================================================================ */

SET IDENTITY_INSERT [countyScansTitle].[dbo].[tblexportLog] ON;

INSERT INTO [countyScansTitle].[dbo].[tblexportLog]
    (exportLogID, recordID, LeaseID, exportDate, sentToAudit, zipName,
     zipCopied, imageCopied, _CreatedDateTime, _CreatedBy,
     _ModifiedDateTime, _ModifiedBy, StatusOfLastAttempt,
     DateOfLastAttempt, CountOfLastAttempt)
VALUES
    (7536774,
     '68125b82-1ae2-4058-a46f-f3e46709e47b',
     5184347,
     '2025-09-22 14:09:01',
     0,
     'CH_09.22.2025.14.26_leases',
     0,
     0,
     '2025-09-22 19:47:02.610',
     'dataentry',
     '2025-09-28 12:00:00.863',
     'usp_UpdateLeaseID_tblExportLog',
     NULL,   -- StatusOfLastAttempt
     NULL,   -- DateOfLastAttempt
     NULL);  -- CountOfLastAttempt

SET IDENTITY_INSERT [countyScansTitle].[dbo].[tblexportLog] OFF;

-- Verify the restore:
SELECT * FROM [countyScansTitle].[dbo].[tblexportLog]
WHERE recordID = '68125b82-1ae2-4058-a46f-f3e46709e47b';
