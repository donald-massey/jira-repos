## LND-6732_Abstract Plants + Lease County From Div1 To CountyScansTitle-RESEARCH.sql

This contains the queries I used to create the update statements in 

# LND-6732_Abstract Plants + Lease County From Div1 To CountyScansTitle-UPDATE.sql
---
This is the main SQL file that contains all of the update statements required for moving the Lease records from DIV1 to County Scans Title.

## LND-6732_Abstract Plants + Lease County From Div1 To CountyScansTitle-QA.sql

Contains basic SQL queries for each of the tables involved in the process, CST.tblRecord, CST.tblExportLog, CST.tblLandDescription, CST.tblGrantorGrantee, CST.tbldeedReferenceVolumePage

## LND-6838_Map Land Descriptions Values From DIV1 To CountyScansTitle.sql

This file contains the queries I used to create the update statements for tblLandDescription.

## LND-6838_map land descriptions.py

Intermediary file to update tblLandDescription with the results from the brief-legals-parser.

## LND-6833_Map Grantor Grantee Values From DIV1 to countyScansTitle.sql

This file contains the queries I used to create the update statements for tblGrantorGrantee.

## LND-6836_Map Prior Reference Values From DIV1 to countyScansTitle.sql

This file contains the queries I used to create the update statements for tbldeedReferenceVolumePage.