# LND-9171: Add Two Letter State Abbreviation Column to Landtrac Units ADL/Prism

## Goal

**Ticket:** https://enverus.atlassian.net/browse/LND-9171
**Status:** CANDIDATE FOR DEV

**Given:**

Strike is using the databricks view in the Enverus catalog for prism landtrac units: `ea_prism_etl_prod.publish.landtrac_unit_foundations_view`

BDD delivers this data.

There is no state abbreviation column in the dataset, there is only the full state name. This causes a problem for multi-dataset filters that rely on a two character state abbreviation (TX, NM, etc.)

We need to include a state abbreviation column without state for the ADL Prism delivery.

Here is confluence documentation from the last time a column was added: https://enverus.atlassian.net/wiki/spaces/DAQ/pages/35502786242/Landtrac+Leases+Units+Schema+Change

Look at the PR's in the LND-8450 card (https://enverus.atlassian.net/browse/LND-8450) for examples of the necessary changes.

The landtrac lease dataset has a column named 'state_code_conformed' - this should be the name of the new column.

The landtrac lease dataset (https://enverus-ea-ue1-dev.cloud.databricks.com/explore/data/enverus/prism/landtrac_leases_view?o=614278180845878&activeTab=sample) in Enverus Prism databricks unity catalog contains the State_Code column so state_code_conformed in landtac units will keep the name consistent.

Bdd delivers the data to the prism team in adl and they will pick up from there and load the data/create a column in the unity view.

**Expect:**

Include the state abbreviation in the bdd delivery of landtrac units to adl.

Add it as a new column, state_code_conformed and then we can switch to it. Don't replace the existing one because that would break Prism.

The source for the state_code_conformed in landtrac units should be the equivalent of the same column source in landtrac lease bdd.

## Approach

<!-- Populated during planning session -->

## Completed

<!-- Updated as work is finished -->
