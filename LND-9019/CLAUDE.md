# LND-9019: Orange County Enhanced Clerk – Legal Descriptions Not Publishing to Plant

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-9019
**Status:** CANDIDATE FOR DEV

While ingesting plats into the **Orange County Enhanced Clerk** plant, we discovered that legal descriptions are not being published to the product.

As part of our investigation, we queried the **CS_Digital** database and confirmed that Orange County records do not contain legal descriptions in tbllandDescription. As a result, no legal descriptions are being published to the Enhanced Clerk plant.

However, the source index received from the clerk does contain legal descriptions, indicating that the legal data is being lost somewhere during the ingestion or transformation process before reaching CS_Digital.

**Request:**

- Investigate why legal descriptions from the source index are not being populated in CS_Digital.
- Determine where in the ingestion process the legal data is being dropped.
- Verify whether this issue affects only plat records or if other Orange County record types may be impacted.
- Provide a resolution to ensure legal descriptions are retained and published to the Enhanced Clerk plant.

**Business Impact:** Legal descriptions are a critical component of all Enverus products. Because the legal data is not making it into CS_Digital, the information is unavailable to customers in the final product, reducing the usefulness and completeness of the Orange County Enhanced Clerk plant.

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
