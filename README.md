<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/src/assets/jcge_importdata_logo_dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/src/assets/jcge_importdata_logo_light.png">
  <img alt="JCGE ImportData logo" src="docs/src/assets/jcge_importdata_logo_light.png" height="150">
</picture>

# JCGEImportData

## What is a CGE?
A Computable General Equilibrium (CGE) model is a quantitative economic model that represents an economy as interconnected markets for goods and services, factors of production, institutions, and the rest of the world. It is calibrated with data (typically a Social Accounting Matrix) and solved numerically as a system of nonlinear equations until equilibrium conditions (zero-profit, market-clearing, and income-balance) hold within tolerance.

## What is JCGE?
[JCGE](https://jcge.org) is a block-based CGE modeling and execution framework in Julia. It defines a shared RunSpec structure and reusable blocks so models can be assembled, validated, solved, and compared consistently across packages.

## What is this package?
Import utilities that extract data from external sources (e.g., GTAP, Eurostat)

and emit canonical JCGE CSV datasets for model calibration.

Scope:
- ETL from external datasets into the canonical schema.
- No model-specific logic (writes files under a model data directory).
- Canonical schema is defined in `packages/JCGECalibrate/README.md`.

## Minimal IO bundle

JCGEImportData standardizes a minimal IO bundle that can be produced by
source-specific adapters and then transformed into a SAM:

- `use`: intermediate inputs (goods x activities)
- `supply`: output by activity (activities x goods)
- `value_added`: factors x activities
- `final_demand`: goods x institutions (HOH/GOV/INV/etc.)
- `taxes` (optional): tax accounts x accounts (receipts)
- `imports` (optional): goods x external accounts
- `exports` (optional): goods x external accounts
- `factor_income` (optional): institutions x factors

Goods and activities are distinct sets (1-to-1 is optional, not required).
Tax accounts and external accounts are always created even when empty.

## API (v0.1)

```julia
using JCGEImportData

bundle = IOBundle(
    goods = ["G1", "G2"],
    activities = ["A1", "A2"],
    factors = ["K", "L"],
    institutions = ["HOH", "GOV", "INV"],
    tax_accounts = ["IDT", "TRF"],
    ext_accounts = ["ROW", "CAP"],
    use = LabeledMatrix(["G1", "G2"], ["A1", "A2"], [1 2; 3 4]),
    supply = LabeledMatrix(["A1", "A2"], ["G1", "G2"], [5 6; 7 8]),
    value_added = LabeledMatrix(["K", "L"], ["A1", "A2"], [2 1; 3 4]),
    final_demand = LabeledMatrix(["G1", "G2"], ["HOH", "GOV", "INV"], [1 0 2; 2 1 0]),
)

sam = sam_from_io(bundle)
write_canonical_dataset("path/to/model/data", bundle)
```

## Balance checks

```julia
sam = sam_from_io(bundle)
sam_balance = check_sam_balance(sam)

io_balance = check_io_balance(bundle)
io_balance.goods
io_balance.activities
```

`check_sam_balance` reports row/column totals and per-account imbalances.
`check_io_balance` reports goods balance (output vs. use+final+exports-imports)
and activity balance (output vs. intermediate+value_added).

## Adapters

Adapter stubs define the expected entry points for external data sources:

```julia
bundle = load_iobundle(EurostatAdapter("path/or/source"))
bundle = load_iobundle(GTAPAdapter("path/or/source"))
```

These are placeholders to be filled with source-specific mappings into the
IO bundle.

See `packages/JCGEImportData/ADAPTER_TEMPLATE.md` for a checklist of required
raw tables and expected shapes.
The adapter stubs live in `packages/JCGEImportData/src/Adapters.jl`.

## Transformation notes

- SAM columns are expenditures; rows are receipts.
- `imports` and `exports` populate external accounts (goods x externals).
- If `factor_income` is not provided, all factor income is assigned to the
  first institution as a default placeholder. Provide `factor_income` to
  override this behavior.

## How to cite

If you use the JCGE framework, please cite:

Boero, R. *JCGE - Julia Computable General Equilibrium Framework* [software], 2026.
DOI: 10.5281/zenodo.18282436
URL: https://JCGE.org

```bibtex
@software{boero_jcge_2026,
  title  = {JCGE - Julia Computable General Equilibrium Framework},
  author = {Boero, Riccardo},
  year   = {2026},
  doi    = {10.5281/zenodo.18282436},
  url    = {https://JCGE.org}
}
```

If you use this package, please cite:

Boero, R. *JCGEImportData.jl - Canonical IO/SAM schema and import utilities for JCGE.jl.* [software], 2026.
DOI: 10.5281/zenodo.18274911
URL: https://ImportData.JCGE.org
SourceCode: https://github.com/equicirco/JCGEImportData.jl

```bibtex
@software{boero_jcgeimportdata_2026,
  title  = {JCGEImportData.jl - Canonical IO/SAM schema and import utilities for JCGE.jl.},
  author = {Boero, Riccardo},
  year   = {2026},
  doi    = {10.5281/zenodo.18274911},
  url    = {https://ImportData.JCGE.org}
}
```

If you use a specific tagged release, please cite the version DOI assigned on Zenodo for that release (preferred for exact reproducibility).
