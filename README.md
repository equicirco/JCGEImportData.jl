<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/src/assets/jcge_importdata_logo_dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/src/assets/jcge_importdata_logo_light.png">
  <img alt="JCGE ImportData logo" src="docs/src/assets/jcge_importdata_logo_light.png" height="150">
</picture>

# JCGEImportData

## What is a CGE?

A Computable General Equilibrium (CGE) model represents an economy as
interconnected markets for goods and services, production factors,
institutions, and trade. It is calibrated with economic accounts—typically a
Social Accounting Matrix (SAM)—and solved numerically for an equilibrium.

## What is JCGE?

[JCGE](https://jcge.org) is a block-based CGE modeling and execution framework
in Julia. It provides a common model specification and reusable components for
constructing, validating, solving, and comparing CGE models.

## What is this package?

JCGEImportData prepares external economic accounts for use with
[JCGE](https://jcge.org). It normalizes selected source data into supply-use
tables (SUTs), industry-by-industry input-output (IO) tables, satellite tables,
and the canonical CSV inputs read by JCGECalibrate.

It does not choose a model's sector or regional aggregation, valuation
treatment, institutional and trade accounts, balancing method, or closure.
Those are model-specific decisions.

## Main features

- Construct and validate normalized IO/SAM bundles.
- Transform a SUT to a symmetric industry-by-industry IO table with Model D.
- Write canonical `sam.csv` and `sets.csv` inputs for JCGECalibrate.
- Preserve selected source data, units, and provenance in local caches.

## Supported sources

Source-specific functions use explicit release, year, code, and scope choices.
They cache the selected source files locally; they do not impose a complete
source-to-SAM pipeline.

- **BEA:** U.S. Make and Use tables and National Income and Product Accounts.
- **Eurostat:** national SUTs, national accounts, and satellite accounts.
- **FIGARO:** Eurostat multi-regional supply-use tables.
- **OECD ICIO:** archive download and normalization of selected
  industry-by-industry IO data.

The [usage guide](https://importdata.jcge.org/stable/usage/) gives the
source-specific procedures. The [API reference](https://importdata.jcge.org/stable/api/)
lists the corresponding types and functions in the same order.

## Preparing data for JCGECalibrate

Use this package to select, download, normalize, and validate source accounts.
In the model project, make and document the required mappings, aggregation,
balancing, and SAM-accounting decisions. Then assemble an `IOBundle`, validate
it with `check_io_balance` and `check_sam_balance`, and write the canonical
dataset with `write_canonical_dataset`.

The [calibration preparation guide](https://importdata.jcge.org/stable/usage/#Prepare-data-for-JCGECalibrate)
describes this hand-off to JCGECalibrate.

## How to cite

If you use the [JCGE](https://jcge.org) framework, please cite:

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

If you use a specific tagged release, please cite the version DOI assigned on
Zenodo for that release.
