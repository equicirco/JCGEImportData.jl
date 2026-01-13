# Adapter Template (IO Bundle Mapping)

This template documents the minimal raw tables that should be mapped into an
`IOBundle`. The goal is to standardize source-specific adapters (Eurostat,
GTAP, etc.) without imposing model-specific logic.

## Required tables

1) `use` (goods x activities)
- Rows: goods
- Columns: activities
- Values: intermediate inputs (commodity i used by activity j)

2) `supply` (activities x goods)
- Rows: activities
- Columns: goods
- Values: output/make matrix (activity j produces commodity i)

3) `value_added` (factors x activities)
- Rows: factors
- Columns: activities
- Values: factor inputs by activity

4) `final_demand` (goods x institutions)
- Rows: goods
- Columns: institutions (e.g., HOH, GOV, INV, ROW/CAP)
- Values: final demand by institution

## Optional tables

5) `taxes` (tax accounts x accounts)
- Rows: tax accounts (e.g., IDT, TRF)
- Columns: any account receiving/collecting the tax

6) `imports` (goods x external accounts)
- Rows: goods
- Columns: external accounts (e.g., ROW, CAP)

7) `exports` (goods x external accounts)
- Rows: goods
- Columns: external accounts (e.g., ROW, CAP)

8) `factor_income` (institutions x factors)
- Rows: institutions
- Columns: factors
- Values: factor income allocation

## Default behaviors

- Goods and activities are distinct sets by default. Adapters may map them
  1-to-1 if the source assumes that, but it is not required.
- Tax accounts and external accounts are always created even if empty.
- If `factor_income` is omitted, all factor income is assigned to the first
  institution.

## Output

Adapters should emit a populated `IOBundle` that can be passed to:

```julia
sam = sam_from_io(bundle)
write_canonical_dataset("path/to/model/data", bundle)
```

## Notes for GTAP / Eurostat

- Map the source classifications into the target `goods`, `activities`,
  `factors`, and `institutions` lists before constructing matrices.
- Keep a separate mapping table if classification reduction is performed.
- Do not embed calibration logic in the adapter; only normalize to IO tables.
