# {TICKET} — Level 1: search the IIF Lease Importer log for a DIL zip
# Runbook: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/38336692284
#
# IIF Lease Importer runs on \\prod-loader05.prod.aus and picks up DIL zips from
#   \\smb.dc2isilon.na.drillinginfo.com\lease_data_entry\ch_lease_exporter\input
# Logs rotate weekly by ISO week: iifLegalLeaseLoader.log.YYYY-WW (archive back to 2012).
# IIF polls every ~4 min off-hours but SLEEPS ~08:00-22:00 CST during business hours —
# a zip deposited in that window can be cleaned up before the 22:00 wake-up (timing race).

$zipName = '{ZIPNAME}'
$week    = '{YYYY-WW}'   # ISO week the zip's exportDate falls in
$log     = "\\prod-loader05.prod.aus\logs\loaders\iif\iifLegalLeaseLoader.log.$week"

# 1) Did IIF ever see the zip?
#    Match  -> IIF processed it; look for ERROR lines just after (e.g.
#              'ColonialLocationName can not be empty', 'bad term of N months', 'Error in load: 0').
#    No match -> IIF never processed it; most likely the business-hours timing race.
Select-String -Path $log -Pattern $zipName

# 2) If absent, list what IIF DID process that period (confirms the race / when it ran).
# Select-String -Path $log -Pattern 'Processing file'
