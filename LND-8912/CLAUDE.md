# LND-8912: Fix Lease Publishing Gap Caused by Export Lookback Window

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-8912
**Status:** Ready for Dev

**Summary**
During the Legal Leases health review meeting, Daniel identified that leases logged in the tblexportlog courthouse export backlog are not consistently published to the DI Web leasing product. The export log count has grown to ~500 entries over the past 3 months. Of 4 examples inspected, 2 were confirmed not published on DI Web. With the recent change to publish all no-geometry leases, the impact of missing publications is now greater.

**Steps to Reproduce**

1. A lease is created and a DIL file is sent to IIF to capture the leaseID
2. The lease loads outside the ~20-minute post-DIL lookback window
3. The lease ID is not captured in tblexportlog within the window
4. The lease remains in the courthouse export log backlog and is never published to DI Web

**Expected Behavior**
All legal leases (including no-geometry leases) are eventually published to the DI Web leasing product, with tblexportlog entries resolved once published.

**Actual Behavior**
Leases that miss the ~20-minute lookback window after DIL file submission are not published to DI Web. Periodic manual lookback runs catch some, but the backlog has grown to ~500 entries. 2 of 4 sampled entries confirmed not published in DI Web.

**Impact / Severity**
Customers and internal users cannot see affected leases in the DI Web leasing product. Impact is growing now that all no-geometry leases are expected to be published. Example: Henderson, NULL leaseID `9a37b03c-d029-4f5a-bdbb-999b76a60689`

**Environment**
Production — DI Web leasing product; tblexportlog courthouse export log

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
