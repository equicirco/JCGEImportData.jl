# Usage

`JCGEImportData` converts selected source accounts into normalized SUT, IO,
satellite, and canonical SAM inputs.

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

## Prepare data for JCGECalibrate

`write_canonical_dataset` writes the canonical `sam.csv` and `sets.csv` files
read by `JCGECalibrate`. The preparation sequence is deliberately explicit:

1. Download and normalize the chosen source accounts with JCGEImportData.
2. In the model project, record and apply source-to-model classifications,
   aggregation, valuation treatment, institutional and external-account
   treatment, and the chosen balancing method.
3. Build an `IOBundle` containing the intended goods, activities, factors,
   institutions, tax accounts, external accounts, intermediate use, supply,
   value added, and final demand. Add tax, trade, and factor-income tables when
   they are part of the intended SAM.
4. Check the IO and resulting SAM balances, resolve any imbalance deliberately,
   then write the canonical files.
5. Add optional `params.csv`, `subsets.csv`, `labels.csv`, and `mappings.csv`
   only when they are needed by the model specification.

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

The source import functions deliberately do not perform steps 2--4: mapping
published accounts to a SAM and choosing its closure are model decisions. Pass
an explicitly prepared parameter table as `params = ...` when the model needs
`params.csv`.

## Read a direct industry-by-industry IO table

`IOTAdapter` reads three local long-form files: intermediate transactions,
final demand, and gross output. Its default columns are, respectively,
`supplier_region`, `supplier_industry`, `user_region`, `user_industry`, and
`value`; `supplier_region`, `supplier_industry`, `demand_region`, `final_use`,
and `value`; and `region`, `industry`, and `value`.

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

Direct industry-by-industry sources have no product sales structure, so the
adapter does not fabricate one. Source classifications, aggregation, and the
mapping of value added or institutions to a SAM remain outside the import.

## Transform an SUT with Model D

`symmetric_io_model_d` creates a sparse, industry-by-industry
`MultiRegionIOT` using a fixed product-sales structure. For each product
origin, every recorded product use is allocated among the industries that
supplied that product in the source SUT.

```julia
iot = symmetric_io_model_d(sut)
diagnostics = check_iot_balance(iot)

diagnostics.sales       # product sales shares sum to one
diagnostics.industries  # output versus allocated industry sales
```

The transformation retains origin and destination regions. It converts only
product rows: factor, tax, and other non-product rows remain source data for a
model to map explicitly when constructing its SAM.

## BEA Make and Use tables

`BEAAdapter` reads long-form Make and Use exports with explicit source columns:

```julia
adapter = BEAAdapter(
    "bea_make.csv",
    "bea_use.csv";
    products = ["1111A0", "311000"],
    activities = ["11", "31G"],
    final_uses = ["P3", "P51"],
    region = "US",
    valuation = "selected BEA published valuation",
)
sut = load_sut(adapter)
check_sut_balance(sut)
```

The Make export must contain `commodity`, `industry`, and `value`; the Use
export must contain `commodity`, `account`, and `value`. `products`,
`activities`, and `final_uses` identify the retained accounts without guessing
from source totals or adjustment labels. The adapter preserves the selected BEA
source valuation and does not reconcile producer and purchaser prices, import
adjustments, margins, or taxes before a model selects an SUT-to-IO
transformation.

### Download BEA tables once

`download_bea` requires a registered BEA API key. The caller selects a specific
year and published Make/Use table pair; the key is never retained in the cache
manifest.

```julia
release = BEARelease(reference_year, make_table_id, use_table_id)
files = download_bea(release, "data/raw/bea"; api_key = ENV["BEA_API_KEY"])
```

The cache contains raw API responses, long-form Make and Use CSV files, and a
manifest with the selected table identifiers, source year, retrieval time, and
checksums. Choose table identifiers through the BEA InputOutput API metadata;
the package does not assume a preferred BEA table family.

### Download BEA national accounts once

`BEANationalAccountsRelease` caches a caller-selected published BEA National
Income and Product Accounts (NIPA) table. It preserves the table name, line,
series code, description, metric, unit, unit multiplier, and value for a later
explicit SAM mapping:

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

The cache manifest records source selection and checksums, but never the API
key. It does not select NIPA tables or translate their lines into SAM accounts.

## Eurostat national SUTs

`EurostatNationalSUTAdapter` reads a selected local national SUT export. The
supply file has `product`, `activity`, and `value`; the use file has `product`,
`account`, and `value` by default.

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
check_sut_balance(sut)
```

### Download a national SUT once

The default release pairs Eurostat's annual current-price supply table
(`naio_10_cp15`) with its annual use table at purchasers' prices
(`naio_10_cp16`). The retained products, activities, and final-use accounts
are explicit:

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

The cache retains raw JSON-stat responses, normalized CSV files, and a
checksum manifest. Another published supply/use pair can be selected through
the release keywords. The caller chooses the valuation and must reconcile
imports, margins, taxes, and any balancing needed for the model; the importer
does not construct a calibration dataset automatically.

### Download Eurostat national accounts once

`EurostatNationalAccountsRelease` caches selected source series for later,
explicit SAM preparation. It preserves published institutional-sector and
transaction dimensions rather than mapping them to model accounts.

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

The normalized CSV contains `region`, the declared source-dimension columns,
`unit`, and `value`; its manifest retains the query, source codes, raw
responses, and checksums. Other Eurostat national-accounts dataflows use the
same interface with their own explicitly supplied dimensions and selections.

### Eurostat satellite data

`SatelliteAdapter` preserves non-monetary source data separately from IO
accounts. Its local long-form input must contain `region`, `industry`,
`indicator`, `unit`, and `value`.

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

`EurostatSatelliteRelease` declares the source dimensions explicitly. For
example, this downloads national-accounts employment by NACE industry:

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

The same interface supports labour compensation from `nama_10_a64` and
air-emissions accounts from `env_ac_ainah_r2`. Economy-wide material-flow
accounts from `env_ac_mfa` have no industry dimension: use
`industry_dimension = nothing`, filter on the published material-account
dimension, and explicitly provide `aggregate_industry`.

## Eurostat FIGARO

`EurostatAdapter` reads local flat FIGARO supply and use tables into a
`MultiRegionSUT`.

```julia
adapter = EurostatAdapter(
    "figaro_supply.tsv",
    "figaro_use.tsv",
)
sut = load_sut(adapter)
product_balance = check_sut_balance(sut)
```

The default schema expects tab-separated fields named `row_country`,
`row_code`, `col_country`, `col_code`, and `value_meur`. It identifies product
rows through the `CPA_` prefix and resolves `DOM` product origins to the
destination region. Source regions, products, activities, final uses, and
product origins are retained without aggregation.

For equivalent FIGARO exports with another layout, pass an explicit schema:

```julia
schema = FIGAROFlatSchema(
    row_region = :origin,
    row_code = :row,
    column_region = :destination,
    column_code = :column,
    value = :value,
    delimiter = ',',
)
sut = load_sut(EurostatAdapter("supply.csv", "use.csv"; schema))
```

The output is an SUT rather than an `IOBundle`. Regional and industry
aggregation, factor and tax mapping, and institutional closure remain explicit
model-level choices.

### Download a FIGARO release once

`load_sut` is local-only. Downloading is a separate, explicit setup action:

```julia
release = FIGARORelease(2016)
files = download_figaro(release, "data/raw/figaro"; regions = ["DE", "FR"])
```

`download_figaro` uses Eurostat's official SDMX API, refuses to overwrite a
cache, and writes a TOML manifest with the queried dataflows, query URLs,
retrieval time, local filenames, and SHA-256 checksums. The region set is
always supplied by the calling model. Subsequent imports use
`files.supply_path` and `files.use_path` locally.

## OECD ICIO

`OECDICIOAdapter` uses the same three-file direct-IO layout while recording the
selected OECD Inter-Country Input-Output (ICIO) edition in provenance:

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

The archive URL, edition, and period are chosen explicitly by the calling
workflow:

```julia
release = OECDICIORelease(
    "2025 edition",
    "2016-2022",
    "https://webfs-sti.oecd.org/files/STI-PIE/ICIO/2025/2016-2022_SML.zip",
)
files = download_oecd_icio(release, "data/raw/oecd_icio")
```

Normalize one selected year and source-code selection to the package's local
IO layout:

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
receive their own checksum manifest. The reader supports the regular OECD
ICIO CSV archive structure but does not choose an edition, geography,
aggregation, factor treatment, or source-to-SAM pipeline. OECD ICIO is an
annual symmetric industry-by-industry system; see the
[OECD ICIO documentation](https://www.oecd.org/en/data/datasets/inter-country-input-output-tables.html).

## Scope boundary

The package supports CGE calibration but does not define a complete
source-to-SAM pipeline. Regional or sector aggregation, trade and institutional
accounts, balancing methods, and model closure are deliberately left to the
model using these imported data.
