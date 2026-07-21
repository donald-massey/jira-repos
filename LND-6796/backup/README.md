# Restore-grade backups of deleted tblDimlXref rows.
# LND-6796_shape1_deleted_xref_backup.csv is produced by running Section 1b of
# LND-6796_primary_issue_orphan_cleanup.sql (SELECT x.* -> all tblDimlXref columns)
# BEFORE the DELETE commits, and saving the result set here with header.
