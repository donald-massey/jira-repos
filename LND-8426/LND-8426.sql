/*

1. Check tblexportlog joined to tblrecord for LeaseID, recordIsLease, statusID IN (4,10)
	1a. These are the values used in the land-lease-producer job to identify candidate leases
	1b. Need to identify why ch-lease-exporter didn't match on the DIV1 natural keys, that's blocking '46e238a6-4e63-4f1e-95bf-916083355f24'

2. Verify there aren't issues with the county in countyScanstitle.dbo.tbldataloaderspercounty
	1a. Both look good from what I see, full reloads have been done since each records _ModifiedDateTime in countyScansTitle.dbo.tblrecord
	    Which is used by land-lease-producer to identify candidate records

3. Check the elasticSearch index for leaseIDs
https://cerebro.drillinginfo.com/#/overview?host=Elasticsearch%20DI%20Regulatory%206x%20Client

4. If record isn't available on the ElasticSearch index, create a branch in land-lease-producer to gather only the effected record
	and place a break point before publishing to kafka. This will verify if the record should publish and the investigation needs
	to continue with https://git.drillinginfo.com/Land/land-aws-glue

*/

-- leaseID = 4696618, recordIsLease = 1, statusID = 4
-- recordNumber = 201906966
SELECT *
FROM dbo.tblexportLog l
JOIN dbo.tblrecord r ON r.recordID = l.recordID
JOIN dbo.tblDataLoadersPerCounty c ON c.CountyID = r.countyID
WHERE l.recordID IN ('a688f5be-8530-4647-b73d-089c185c8262'
,'46e238a6-4e63-4f1e-95bf-916083355f24')


-- leaseID = NULL, recordIsLease = 1, statusID = 4
-- recordNumber = 2023-004291
SELECT *
FROM dbo.tblexportLog l
JOIN dbo.tblrecord r ON r.recordID = l.recordID
JOIN dbo.tblDataLoadersPerCounty c ON c.CountyID = r.countyID
WHERE l.recordID = '46e238a6-4e63-4f1e-95bf-916083355f24'


