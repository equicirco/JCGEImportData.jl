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
Import utilities that normalize external economic accounts for [JCGE](https://jcge.org)
model calibration.

Scope:
- ETL from external datasets into normalized SUT or IO/SAM inputs.
- No model-specific aggregation, calibration, or closure assumptions.
- Canonical IO/SAM data can be written with `write_canonical_dataset`.

JCGEImportData supports CGE calibration but does not prescribe a complete
pipeline from source tables to a Social Accounting Matrix. Sector and regional
aggregation, trade and institutional treatment, balancing choices, and SAM
closure are model-specific decisions.

## Preparing a calibration dataset for JCGECalibrate

`write_canonical_dataset` writes the canonical `sam.csv` and `sets.csv` files
read directly by [JCGECalibrate](https://jcge.org). A reproducible preparation
workflow is:

1. Download and normalize the selected source SUT, IO, satellite, or national-
   accounts tables with this package.
2. In the model project, document and apply the required classification mapping,
   aggregation, valuation treatment, institutional and external-account
   treatment, and balancing method.
3. Assemble an `IOBundle` with the model's goods, activities, factors,
   institutions, tax accounts, external accounts, intermediate use, supply,
   value added, and final demand. Add explicit tax, trade, and factor-income
   tables where the intended SAM requires them.
4. Run `check_io_balance` and `check_sam_balance`, resolve material imbalance
   deliberately, then write the canonical files.
5. Add optional `params.csv`, `subsets.csv`, `labels.csv`, or `mappings.csv`
   only when the model needs them, then load the result through JCGECalibrate.

```julia
using JCGEImportData
using JCGECalibrate

check_io_balance(bundle)
sam_table = sam_from_io(bundle)
check_sam_balance(sam_table)
write_canonical_dataset("data/calibration", bundle; sam = sam_table)

sets = load_canonical_sets("data/calibration")
sam = load_canonical_sam("data/calibration"; goods = bundle.goods, factors = bundle.factors)
```

The importers intentionally stop before steps 2--4: source-to-SAM mappings and
closure assumptions cannot be made safely without a model-specific decision.
Pass an explicitly prepared parameter table as `params = ...` when the model
requires `params.csv`.

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

## API

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

## Eurostat FIGARO

`EurostatAdapter` reads local flat supply and use exports from the
[Eurostat FIGARO system](https://ec.europa.eu/eurostat/en/web/esa-supply-use-input-tables/database)
into `MultiRegionSUT`. It preserves all source regions, product origins,
activities, and final-use accounts. It does not aggregate regions or industries,
create a symmetric IO table, or impose a model closure.

```julia
using JCGEImportData

adapter = EurostatAdapter(
    "figaro_supply.tsv",
    "figaro_use.tsv",
)
sut = load_sut(adapter)
check_sut_balance(sut)
```

The default flat-table schema expects the columns
`row_country`, `row_code`, `col_country`, `col_code`, and `value_meur`, with
tab delimiters. `FIGAROFlatSchema` lets callers map equivalent column names,
delimiters, domestic-origin markers, and product-code prefixes. A `DOM` origin
in a use row is resolved to the corresponding destination region.

The resulting SUT is deliberately an intermediate representation. Models can
apply the supplied `symmetric_io_model_d(sut)` transformation, which uses the
fixed-product sales structure convention, or make another explicit SUT-to-IO
choice. Regional and industry aggregation, factor and tax mapping, and closure
remain model-level decisions.

```julia
iot = symmetric_io_model_d(sut)
diagnostics = check_iot_balance(iot)
```

`MultiRegionIOT` stores sparse industry-to-industry intermediate sales,
industry-to-final-use sales, industry output, and the product sales structure
used for the allocation. Non-product source rows are not transformed because
their mapping to factor, tax, and institutional accounts is model-specific.

## Direct industry-by-industry IO tables

`IOTAdapter` reads three local long-form files: intermediate transactions,
final demand, and gross output. The default intermediate fields are
`supplier_region`, `supplier_industry`, `user_region`, `user_industry`, and
`value`; the final-demand fields replace the user fields with `demand_region`
and `final_use`; output uses `region`, `industry`, and `value`.

```julia
iot = load_iot(IOTAdapter(
    "intermediate.csv", "final_demand.csv", "output.csv";
    regions = region_codes,
    industries = industry_codes,
    final_uses = final_use_codes,
    valuation = "selected source valuation",
    year = reference_year,
))
check_iot_balance(iot)
```

This direct-IO representation has no product sales structure, because none is
observed or needed. `OECDICIOAdapter` uses the same local layout and adds the
selected OECD ICIO edition to provenance:

```julia
iot = load_iot(OECDICIOAdapter(
    "icio_intermediate.csv", "icio_final_demand.csv", "icio_output.csv";
    edition = "selected OECD ICIO edition",
    regions = region_codes,
    industries = industry_codes,
    final_uses = final_use_codes,
    valuation = "basic prices",
    year = reference_year,
))
```

### Download an OECD ICIO archive once

`download_oecd_icio` caches one caller-selected official ICIO archive with a
checksum manifest. The archive URL, edition, and period are explicit, so a
model decides which OECD release to use:

```julia
release = OECDICIORelease(
    "2025 edition",
    "2016-2022",
    "https://webfs-sti.oecd.org/files/STI-PIE/ICIO/2025/2016-2022_SML.zip",
)
files = download_oecd_icio(release, "data/raw/oecd_icio")
```

Normalize one selected year and source-code selection to the local IO layout:

```julia
io_files = normalize_oecd_icio(
    release,
    files.archive_path,
    "data/interim/oecd_icio";
    reference_year = 2020,
    regions = region_codes,
    industries = industry_codes,
    final_uses = final_use_codes,
)
```

The archive is structurally verified before caching and the normalized files
receive their own checksum manifest. This reader supports the regular OECD
ICIO CSV archive structure. It does not choose an edition, geography,
aggregation, factor treatment, or source-to-SAM pipeline.

## Eurostat national SUTs

`EurostatNationalSUTAdapter` reads a selected local long-form national supply
and use export. Its default supply columns are `product`, `activity`, and
`value`; use uses `product`, `account`, and `value`.

```julia
sut = load_sut(EurostatNationalSUTAdapter(
    "national_supply.csv", "national_use.csv";
    products = product_codes,
    activities = activity_codes,
    final_uses = final_use_codes,
    region = "DE",
    valuation = "selected Eurostat source valuation",
    year = reference_year,
))
```

### Download a national SUT once

The default release pairs Eurostat's annual current-price supply table
(`naio_10_cp15`) with the annual use table at purchasers' prices
(`naio_10_cp16`). Product, activity, and final-use selections are explicit:

```julia
release = EurostatNationalSUTRelease(2020, "DE")
files = download_eurostat_national_sut(
    release,
    "data/raw/eurostat_national";
    products = ["CPA_C26", "CPA_C27"],
    activities = ["C26", "C27"],
    final_uses = ["P3_S14"],
)

sut = load_sut(EurostatNationalSUTAdapter(
    files.supply_path,
    files.use_path;
    products = ["CPA_C26", "CPA_C27"],
    activities = ["C26", "C27"],
    final_uses = ["P3_S14"],
    region = "DE",
    valuation = "Eurostat annual supply at basic prices and use at purchasers' prices",
    year = 2020,
))
```

The cache retains raw JSON-stat responses, normalized local CSV files, and a
checksum manifest. Another published supply/use pair can be selected through
the release keywords. The caller must still select the appropriate valuation
and reconcile imports, margins, taxes, and any balancing required by the
model; the downloader does not turn the published tables into a calibration
dataset automatically.

## Eurostat national accounts

`EurostatNationalAccountsRelease` downloads selected national-account series
for later, explicit SAM preparation. It preserves the published institutional
sector and transaction dimensions instead of assigning them to model accounts.
For example, annual non-financial sector accounts can provide payments and
receipts of compensation of employees:

```julia
release = EurostatNationalAccountsRelease(
    2016,
    "nasa_10_nf_tr";
    unit = "CP_MEUR",
    dimensions = ["direct", "na_item", "sector"],
)
files = download_eurostat_national_accounts(
    release,
    "data/raw/eurostat_national_accounts";
    regions = ["DE", "FR"],
    selections = Dict(
        "direct" => ["PAID", "RECV"],
        "na_item" => ["D1"],
        "sector" => ["S1", "S13", "S14"],
    ),
)
```

The output has `region`, the declared source dimensions, `unit`, and `value`,
with raw API responses and checksums in its manifest. Other Eurostat national
accounts dataflows use the same interface when their source dimensions and
selected codes are declared by the calling workflow.

## Satellite tables

`SatelliteAdapter` reads local long-form observations with `region`,
`industry`, `indicator`, `unit`, and `value` fields. It preserves the unit on
every observation and keeps physical quantities, employment, emissions, and
material use separate from monetary IO accounts.

```julia
satellite = load_satellite(SatelliteAdapter(
    "satellite.csv";
    regions = region_codes,
    industries = industry_codes,
    indicators = ["employment", "material_use"],
    source = "selected satellite source",
    year = reference_year,
))
```

### Download Eurostat satellite data once

`EurostatSatelliteRelease` makes source dimensions explicit and writes a local
unit-preserving table. For example, national-accounts employment by NACE
industry can be selected as follows:

```julia
release = EurostatSatelliteRelease(
    2020,
    "nama_10_a64_e";
    unit = "THS_PER",
    industry_dimension = "nace_r2",
    indicator_dimension = "na_item",
)
files = download_eurostat_satellite(
    release,
    "data/raw/eurostat_satellites";
    regions = ["DE", "FR"],
    industries = ["C26", "C27"],
    indicators = ["EMP_DC"],
)
```

The same interface supports labour compensation from `nama_10_a64` (using
`nace_r2` and `na_item`, for example `D1`, with unit `CP_MEUR`) and air
emissions accounts from `env_ac_ainah_r2` (using `nace_r2` and `airpol`, with
unit `T` or `THS_T`). Economy-wide material-flow accounts from `env_ac_mfa`
have no industry dimension: set `industry_dimension = nothing`, filter on
their published account dimension, and explicitly choose `aggregate_industry`
for the output record. The downloader retains raw JSON-stat responses and a
checksum manifest; it does not infer mappings between source classifications
and a model's industries.

## BEA Make and Use tables

`BEAAdapter` reads local, long-form Make and Use exports from the U.S. Bureau
of Economic Analysis. The Make file has `commodity`, `industry`, and `value`
columns; the Use file has `commodity`, `account`, and `value` columns. A caller
explicitly identifies the retained commodity, industry, and final-use codes and
records the valuation of the selected source tables.

```julia
adapter = BEAAdapter(
    "bea_make.csv",
    "bea_use.csv";
    products = ["1111A0", "311000"],
    activities = ["11", "31G"],
    final_uses = ["P3", "P51"],
    region = "US",
    valuation = "selected BEA published valuation",
    year = 2022,
)
sut = load_sut(adapter)
```

BEA publishes Make, Use, Supply, and import-related tables with different
valuation and adjustment conventions. This adapter preserves those source
choices; it does not reconcile producer and purchaser prices, imports, margins,
or taxes. Run `check_sut_balance(sut)` before selecting Model D or another
SUT-to-IO transformation.

### Download BEA tables once

The BEA API requires a registered key. A caller selects the published Make and
Use table identifiers explicitly, then caches both raw API responses and the
corresponding long-form files:

```julia
release = BEARelease(reference_year, make_table_id, use_table_id)
files = download_bea(release, "data/raw/bea"; api_key = ENV["BEA_API_KEY"])

adapter = BEAAdapter(
    files.make_path,
    files.use_path;
    products = commodity_codes,
    activities = industry_codes,
    final_uses = final_use_codes,
    region = "US",
    valuation = "selected BEA published valuation",
    year = reference_year,
)
```

The manifest records the table identifiers, year, response files, and checksums;
it never records the API key.

## BEA national accounts

`BEANationalAccountsRelease` caches one caller-selected published BEA National
Income and Product Accounts (NIPA) table. The output preserves the table name,
line number, series code, description, metric, unit, unit multiplier, and
value, so a later SAM workflow can make an explicit account mapping:

```julia
release = BEANationalAccountsRelease(2016, "T10105")
files = download_bea_national_accounts(
    release,
    "data/raw/bea_national_accounts";
    api_key = ENV["BEA_API_KEY"],
    lines = ["1"],
    metrics = ["Current Dollars"],
)
```

The downloader records the selected published line and metric labels plus
checksums, but never the API key. It does not choose NIPA tables or translate
their lines into a SAM.

### Download once, then work locally

`load_sut` never accesses the network. Downloading from Eurostat is a separate,
explicit setup action. Select the source year and the regional subsystem to
cache:

```julia
release = FIGARORelease(2016)
files = download_figaro(release, "data/raw/figaro"; regions = ["DE", "FR"])

sut = load_sut(EurostatAdapter(files.supply_path, files.use_path; year = 2016))
```

The downloader uses Eurostat's official SDMX API. It refuses to overwrite an
existing cache and writes a TOML manifest with the source dataflows, all query
URLs, retrieval time, local file names, and SHA-256 checksums. A model chooses
its own geographic scope; flows involving regions outside the selected set are
not silently represented as domestic transactions.

## Transformation notes

- SAM columns are expenditures; rows are receipts.
- `imports` and `exports` populate external accounts (goods x externals).
- If `factor_income` is not provided, all factor income is assigned to the
  first institution as a default placeholder. Provide `factor_income` to
  override this behavior.

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

If you use a specific tagged release, please cite the version DOI assigned on Zenodo for that release (preferred for exact reproducibility).
