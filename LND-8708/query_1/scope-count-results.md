# Query 1 — Scope count results

Run of `unmapped-leases-scope-count.sql` on the CSTitle server (`aus2-dtf-pap01v.na.drillinginfo.com`), anti-join vs DIV1 `tblleaseAbstractMapping` via `LinktoDiv1Repl`. Population = published leases (`tblexportLog`) that are currently publishable (`recordIsLease=1`, `statusID IN (4,10)`) with **zero** abstract mapping in DIV1 (⟺ no land descriptions ⟺ null `mapping_id`).

**Total (STEP 3): 88,643 zero-mapping leases** — the expected df2 doc volume added to the `legal_lease` ES index.

## By state (STEP 2)

| State | Zero-mapping leases |
|-------|--------------------:|
| TX    | 53,085 |
| WV    | 15,573 |
| OH    | 13,436 |
| LA    | 2,463 |
| NM    | 1,759 |
| PA    | 658 |
| OK    | 528 |
| CO    | 334 |
| ND    | 316 |
| MS    | 142 |
| WY    | 105 |
| CA    | 69 |
| KS    | 63 |
| MT    | 35 |
| AR    | 33 |
| UT    | 24 |
| MI    | 19 |
| NV    | 1 |
| **Total** | **88,643** |

## Reading

- **TX dominates: 53,085 (60%).** TX + WV + OH = 82,094 (93% of all zero-mapping leases).
- **PA is only 658** — confirms LND-8426: PA is well-mapped, the Marcellus (PA/OH/WV) theory stays refuted, and TX (non-Marcellus) is the real weight.
- **Reconciliation:** the 18 state rows sum exactly to the STEP 3 total (88,643). No `UNKNOWN` bucket, so every zero-mapping lease resolved to a `stateID` — the by-state breakdown is complete, not truncated. (This is what the LEFT JOIN + `ISNULL(...,'UNKNOWN')` change guards against.)
