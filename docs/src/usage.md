# Usage

`JCGEImportData` converts IO tables into the canonical SAM schema.

## Build a bundle

```julia
using JCGEImportData

bundle = IOBundle(
    goods=..., activities=..., factors=..., institutions=...,
    use=..., supply=..., value_added=..., final_demand=...
)
```

## Write CSVs

```julia
write_canonical_dataset("data", bundle)
```

## Checks

`check_sam_balance` and `check_io_balance` provide consistency diagnostics.

