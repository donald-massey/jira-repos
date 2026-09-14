# LND-7634: Remove Unused Mounts From land-lease-producer

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-7634
**Status:** In Progress

**Given**: The land-lease-producer has two volumes defined that correspond with image fileshares.

**Given**: A search reveals that these mounts are only referred to in code which has been commented out.

- https://git.drillinginfo.com/Land/land-lease-producer/search?q=DIDOCUMENTS_IMAGE_MOUNT
- https://git.drillinginfo.com/Land/land-lease-producer/search?q=COUNTY_SCANS_BETA&type=

**Expect**: Remove the volumes defined from the [Nomad Job Definition](https://git.drillinginfo.com/SRE/og-nomad-scheduler/blob/master/jobs/land/land_lease_producer_job.ctmpl#L62) and in its [Consul-KV file](https://git.drillinginfo.com/DI2Infrastructure/consul-kv/blob/prod/services/land-lease-producer.yaml#L23).

**Expect**: Remove the code which has been commented out.

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
