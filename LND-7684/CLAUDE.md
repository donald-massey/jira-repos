# LND-7684: Non-S3 Leases Missing Published Image in DI Web

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-7684
**Status:** Backlog

Investigate the last ~1,300 images that failed to be published to the Elasticsearch index from the land-lease-producer pipeline.

GIVEN: A repository was created for LND-6827 work (migrating lease document images to S3 and populating tblS3Image). That repository is the starting point for investigating the remaining 1,300 missing cases.

EXPECTED: Read through LND-6827 and its repository to identify:

1. Does the issue still persist — all images were copied and entries made in tblS3Image and tblDimlXRef, but the images weren't making it to the Kafka topic. Verify that is still the case.
2. If so, begin identifying the root cause of why these leases are excluded from the published topic.

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
