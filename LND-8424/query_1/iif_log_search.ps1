# LND-8424 — Level 1: search the IIF Lease Importer log for the DIL zip
# MERCED, CA — RecordNumber 2024017111
# Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284
#
# IIF Lease Importer runs on \\prod-loader05.prod.aus and picks up DIL zips from
#   \\smb.dc2isilon.na.drillinginfo.com\lease_data_entry\ch_lease_exporter\input
# Logs rotate weekly by ISO week: iifLegalLeaseLoader.log.YYYY-WW (archive back to 2012).
# IIF sleeps ~08:00-22:00 CST during business hours — a zip deposited in that window
# can be cleaned up before the 22:00 wake-up (timing race).

# NOT a timing race: batch-impact showed 183/184 matched in each zip — IIF processed
# them fine; only c5d14542 (RecordNumber 2024017111, file date 2024-07-23) came back NULL.
# So this is a PER-RECORD failure. Hunt the specific import error (or confirm no error,
# which points to a natural-key match-back failure vs the duplicate 90c3e6e1 instead).
$week = '2024-35'                                             # ISO week of 2024-08-31; verify the filename exists
$zips = @('CH_08.31.2024.17.00_leases','CH_08.31.2024.17.01_leases')
$log  = "\\prod-loader05.prod.aus\logs\loaders\iif\iifLegalLeaseLoader.log.$week"

# 1) Locate where IIF processed each zip (context anchor).
foreach ($z in $zips) {
    "==== $z ===="
    Select-String -Path $log -Pattern $z -Context 0,3
}

# 2) Any line mentioning this record or a per-record error? (the actual answer)
#    A hit like 'ColonialLocationName can not be empty' / 'bad term of N months' /
#    'Error in load: 0' => genuine import failure. No hit => IIF imported nothing wrong;
#    the NULL is a match-back miss — likely because 90c3e6e1 already claimed the lease
#    (see compare_duplicate_records.sql).
Select-String -Path $log -Pattern '2024017111'
Select-String -Path $log -Pattern 'ERROR|Error in load|can not be empty|bad term'
