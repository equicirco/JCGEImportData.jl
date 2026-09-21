"""
Source adapters for external IO and SUT datasets.
"""
module Adapters

using CSV
using DataFrames
using Dates
using Downloads
using JSON3
using SHA
using TOML

using ..JCGEImportData: MultiRegionSUT

export EurostatAdapter
export BEAAdapter
export FIGAROFlatSchema
export BEAFlatSchema
export FIGARORelease
export download_figaro
export BEARelease
export download_bea
export BEANationalAccountsRelease
export download_bea_national_accounts
export load_iobundle
export load_sut

"""
    FIGAROFlatSchema(; ...)

Column mapping for Eurostat FIGARO flat supply and use files. The defaults
match the compact five-column export used by the FACT national IO tables
service. For a direct Eurostat flat CSV export, pass its column names and
delimiter explicitly.
"""
Base.@kwdef struct FIGAROFlatSchema
    row_region::Symbol = :row_country
    row_code::Symbol = :row_code
    column_region::Symbol = :col_country
    column_code::Symbol = :col_code
    value::Symbol = :value_meur
    delimiter::Char = '\t'
    domestic_marker::String = "DOM"
    product_prefix::String = "CPA_"
end

"""
    BEAFlatSchema(; ...)

Column mapping for long-form U.S. Bureau of Economic Analysis (BEA) Make and
Use table exports. The Make table must contain commodity, producing-industry,
and value columns; the Use table must contain commodity, using-account, and
value columns. The source's valuation and adjustment treatment are recorded by
`BEAAdapter` rather than changed by the importer.
"""
Base.@kwdef struct BEAFlatSchema
    commodity::Symbol = :commodity
    industry::Symbol = :industry
    use_account::Symbol = :account
    value::Symbol = :value
    delimiter::Char = ','
end

"""
    BEARelease(reference_year, make_table_id, use_table_id)

Explicit selection of published BEA InputOutput Make and Use tables for one
year. Table identifiers are supplied by the caller because BEA publishes
multiple table families with distinct accounting conventions.
"""
struct BEARelease
    reference_year::Int
    make_table_id::Int
    use_table_id::Int
    function BEARelease(
        reference_year::Int,
        make_table_id::Int,
        use_table_id::Int,
    )
        reference_year > 0 || error("BEA reference_year must be positive.")
        make_table_id > 0 || error("BEA make_table_id must be positive.")
        use_table_id > 0 || error("BEA use_table_id must be positive.")
        return new(reference_year, make_table_id, use_table_id)
    end
end

function BEARelease(
    reference_year::Integer,
    make_table_id::Integer,
    use_table_id::Integer,
)
    return BEARelease(Int(reference_year), Int(make_table_id), Int(use_table_id))
end

"""
    BEANationalAccountsRelease(reference_year, table_name; frequency="A", region="US")

An explicit selection of one published BEA National Income and Product
Accounts (NIPA) table. `table_name` is retained exactly as published by BEA;
the importer does not select a table or infer a SAM account mapping.
"""
struct BEANationalAccountsRelease
    reference_year::Int
    table_name::String
    frequency::String
    region::String
    function BEANationalAccountsRelease(
        reference_year::Int,
        table_name::String,
        frequency::String,
        region::String,
    )
        reference_year > 0 || error("BEA national-accounts reference_year must be positive.")
        occursin(r"^[A-Za-z0-9_]+$", table_name) || error("BEA national-accounts table_name must contain only letters, digits, and underscores.")
        frequency in ("A", "Q", "M") || error("BEA national-accounts frequency must be A, Q, or M.")
        occursin(r"^[A-Za-z0-9_-]+$", region) || error("BEA national-accounts region must contain only letters, digits, underscores, and hyphens.")
        return new(reference_year, table_name, frequency, region)
    end
end

function BEANationalAccountsRelease(
    reference_year::Integer,
    table_name::AbstractString;
    frequency::AbstractString = "A",
    region::AbstractString = "US",
)
    return BEANationalAccountsRelease(
        Int(reference_year), String(table_name), String(frequency), String(region),
    )
end

"""
    FIGARORelease(reference_year; supply_dataset=nothing, use_dataset=nothing,
                  unit="MIO_EUR")

Description of one Eurostat FIGARO release. The importer uses Eurostat's
official dissemination API and writes a local, normalized cache. For 2014--17,
the matching FIGARO dataflows are selected automatically. For other periods,
callers must give both official dataset identifiers explicitly.
"""
struct FIGARORelease
    reference_year::Int
    supply_dataset::String
    use_dataset::String
    unit::String
end

function FIGARORelease(
    reference_year::Integer,
    ;
    supply_dataset::Union{AbstractString, Nothing} = nothing,
    use_dataset::Union{AbstractString, Nothing} = nothing,
    unit::AbstractString = "MIO_EUR",
)
    year = Int(reference_year)
    if isnothing(supply_dataset) != isnothing(use_dataset)
        error("Specify both supply_dataset and use_dataset, or neither.")
    end
    if isnothing(supply_dataset)
        2014 <= year <= 2017 || error(
            "No built-in FIGARO dataflow mapping for $(year). Pass the official supply_dataset and use_dataset identifiers explicitly.",
        )
        supply_dataset = "naio_10_fcp_s2"
        use_dataset = "naio_10_fcp_u2"
    end
    _valid_eurostat_identifier(supply_dataset, "supply_dataset")
    _valid_eurostat_identifier(use_dataset, "use_dataset")
    _valid_eurostat_identifier(unit, "unit")
    return FIGARORelease(year, String(supply_dataset), String(use_dataset), String(unit))
end

"""
    download_figaro(release, directory; regions)

Download one selected regional FIGARO subsystem from Eurostat's official SDMX
API. `regions` is explicit: this function neither chooses a model geography nor
downloads data during model loading. It writes normalized supply and use TSV
files compatible with `EurostatAdapter`, plus a manifest recording every API
query and file checksum. Existing caches are never overwritten.

Only transactions whose origin and destination are both in `regions` are
retrieved. Transactions with other FIGARO regions remain available to a
model-specific preparation workflow through a separately chosen source scope.
"""
function download_figaro(
    release::FIGARORelease,
    directory::AbstractString;
    regions::AbstractVector{<:AbstractString},
)
    selected_regions = _validated_regions(regions)
    mkpath(directory)
    stem = "figaro_$(release.reference_year)"
    supply_path = joinpath(directory, "$(stem)_supply.tsv")
    use_path = joinpath(directory, "$(stem)_use.tsv")
    manifest_path = joinpath(directory, "$(stem)_manifest.toml")
    existing = filter(ispath, [supply_path, use_path, manifest_path])
    isempty(existing) || error("FIGARO cache already exists: $(join(existing, ", ")). Choose another directory or remove it explicitly.")

    mktempdir(directory) do temporary_directory
        temporary_supply = joinpath(temporary_directory, "supply.csv")
        temporary_use = joinpath(temporary_directory, "use.csv")
        supply_urls = _download_figaro_supply(release, selected_regions, temporary_supply, temporary_directory)
        use_urls = _download_figaro_use(release, selected_regions, temporary_use, temporary_directory)
        filesize(temporary_supply) > 0 || error("Downloaded FIGARO supply file is empty.")
        filesize(temporary_use) > 0 || error("Downloaded FIGARO use file is empty.")
        mv(temporary_supply, supply_path)
        mv(temporary_use, use_path)

        manifest = Dict(
            "source" => "Eurostat dissemination API",
            "reference_year" => release.reference_year,
            "unit" => release.unit,
            "regions" => selected_regions,
            "retrieved_at_utc" => string(now(UTC)),
            "supply" => Dict(
                "dataset" => release.supply_dataset,
                "queries" => supply_urls,
                "file" => basename(supply_path),
                "sha256" => bytes2hex(sha256(read(supply_path))),
            ),
            "use" => Dict(
                "dataset" => release.use_dataset,
                "queries" => use_urls,
                "file" => basename(use_path),
                "sha256" => bytes2hex(sha256(read(use_path))),
            ),
        )
        open(manifest_path, "w") do io
            TOML.print(io, manifest)
        end
    end
    return (supply_path = supply_path, use_path = use_path, manifest_path = manifest_path)
end

"""
    download_bea(release, directory; api_key)

Download the explicitly selected BEA InputOutput Make and Use tables through
the official BEA API. The API key is required, is validated before use, and is
never written to the cache manifest. The cache retains the raw API responses,
long-form CSV files compatible with `BEAAdapter`, and checksums for both.
"""
function download_bea(
    release::BEARelease,
    directory::AbstractString;
    api_key::AbstractString,
)
    key = _validated_bea_api_key(api_key)
    mkpath(directory)
    stem = "bea_$(release.reference_year)"
    make_raw_path = joinpath(directory, "$(stem)_make.json")
    use_raw_path = joinpath(directory, "$(stem)_use.json")
    make_path = joinpath(directory, "$(stem)_make.csv")
    use_path = joinpath(directory, "$(stem)_use.csv")
    manifest_path = joinpath(directory, "$(stem)_manifest.toml")
    existing = filter(ispath, [make_raw_path, use_raw_path, make_path, use_path, manifest_path])
    isempty(existing) || error("BEA cache already exists: $(join(existing, ", ")). Choose another directory or remove it explicitly.")

    mktempdir(directory) do temporary_directory
        temporary_make_raw = joinpath(temporary_directory, "make.json")
        temporary_use_raw = joinpath(temporary_directory, "use.json")
        temporary_make = joinpath(temporary_directory, "make.csv")
        temporary_use = joinpath(temporary_directory, "use.csv")
        make_url = _bea_api_url(release, release.make_table_id, key)
        use_url = _bea_api_url(release, release.use_table_id, key)
        Downloads.download(make_url, temporary_make_raw)
        Downloads.download(use_url, temporary_use_raw)
        make_rows = _bea_api_rows(temporary_make_raw, :make)
        use_rows = _bea_api_rows(temporary_use_raw, :use)
        nrow(make_rows) > 0 || error("BEA Make response contains no observations.")
        nrow(use_rows) > 0 || error("BEA Use response contains no observations.")
        CSV.write(temporary_make, make_rows)
        CSV.write(temporary_use, use_rows)
        mv(temporary_make_raw, make_raw_path)
        mv(temporary_use_raw, use_raw_path)
        mv(temporary_make, make_path)
        mv(temporary_use, use_path)
    end

    manifest = Dict(
        "source" => "BEA API",
        "endpoint" => BEA_API_ENDPOINT,
        "dataset" => "InputOutput",
        "method" => "GetData",
        "result_format" => "JSON",
        "reference_year" => release.reference_year,
        "make" => Dict(
            "table_id" => release.make_table_id,
            "raw_file" => basename(make_raw_path),
            "raw_sha256" => bytes2hex(sha256(read(make_raw_path))),
            "file" => basename(make_path),
            "sha256" => bytes2hex(sha256(read(make_path))),
        ),
        "use" => Dict(
            "table_id" => release.use_table_id,
            "raw_file" => basename(use_raw_path),
            "raw_sha256" => bytes2hex(sha256(read(use_raw_path))),
            "file" => basename(use_path),
            "sha256" => bytes2hex(sha256(read(use_path))),
        ),
        "retrieved_at_utc" => string(now(UTC)),
    )
    open(manifest_path, "w") do io
        TOML.print(io, manifest)
    end
    return (
        make_path = make_path,
        use_path = use_path,
        make_raw_path = make_raw_path,
        use_raw_path = use_raw_path,
        manifest_path = manifest_path,
    )
end

"""
    download_bea_national_accounts(release, directory; api_key, lines, metrics)

Download one explicitly selected BEA NIPA table through the official BEA API.
`lines` and `metrics` are published source codes and labels selected by the
caller. The normalized records preserve BEA line, series, description, metric,
unit, and unit multiplier fields for a later model-specific SAM mapping.
"""
function download_bea_national_accounts(
    release::BEANationalAccountsRelease,
    directory::AbstractString;
    api_key::AbstractString,
    lines::AbstractVector{<:AbstractString},
    metrics::AbstractVector{<:AbstractString},
)
    key = _validated_bea_api_key(api_key)
    selected_lines = _bea_national_codes(lines, "BEA national-accounts lines")
    selected_metrics = _bea_national_codes(metrics, "BEA national-accounts metrics")
    mkpath(directory)
    stem = "bea_national_accounts_$(release.table_name)_$(release.reference_year)_$(release.frequency)"
    raw_path = joinpath(directory, "$(stem).json")
    accounts_path = joinpath(directory, "$(stem).csv")
    manifest_path = joinpath(directory, "$(stem)_manifest.toml")
    existing = filter(ispath, [raw_path, accounts_path, manifest_path])
    isempty(existing) || error("BEA national-accounts cache already exists: $(join(existing, ", ")). Choose another directory or remove it explicitly.")

    url = _bea_national_accounts_url(release, key)
    mktempdir(directory) do temporary_directory
        temporary_raw = joinpath(temporary_directory, "national_accounts.json")
        temporary_accounts = joinpath(temporary_directory, "national_accounts.csv")
        Downloads.download(url, temporary_raw)
        accounts = _bea_national_accounts_rows(
            temporary_raw,
            release,
            Set(selected_lines),
            Set(selected_metrics),
        )
        nrow(accounts) > 0 || error("BEA national-accounts response has no observations for the declared line and metric selections.")
        CSV.write(temporary_accounts, accounts)
        mv(temporary_raw, raw_path)
        mv(temporary_accounts, accounts_path)
    end

    manifest = Dict(
        "source" => "BEA National Income and Product Accounts API",
        "endpoint" => BEA_API_ENDPOINT,
        "dataset" => "NIPA",
        "method" => "GetData",
        "result_format" => "JSON",
        "reference_year" => release.reference_year,
        "frequency" => release.frequency,
        "region" => release.region,
        "table_name" => release.table_name,
        "lines" => selected_lines,
        "metrics" => selected_metrics,
        "raw_file" => basename(raw_path),
        "raw_sha256" => bytes2hex(sha256(read(raw_path))),
        "file" => basename(accounts_path),
        "sha256" => bytes2hex(sha256(read(accounts_path))),
        "retrieved_at_utc" => string(now(UTC)),
    )
    open(manifest_path, "w") do io
        TOML.print(io, manifest)
    end
    return (path = accounts_path, raw_path = raw_path, manifest_path = manifest_path)
end

const EUROSTAT_SDMX_API = "https://ec.europa.eu/eurostat/api/dissemination/sdmx/2.1/data"
const BEA_API_ENDPOINT = "https://apps.bea.gov/api/data/"

function _download_figaro_supply(
    release::FIGARORelease,
    regions::Vector{String},
    output_path::String,
    temporary_directory::String,
)
    urls = String[]
    first_write = true
    for region in regions
        key = "A...$(release.unit).$(region)"
        url = _figaro_api_url(release.supply_dataset, key, release.reference_year)
        source_path = joinpath(temporary_directory, "supply_$(region).csv")
        Downloads.download(url, source_path)
        rows = _official_supply_rows(_read_eurostat_csv(source_path))
        _append_flat_rows(output_path, rows, first_write)
        first_write = false
        push!(urls, url)
    end
    return urls
end

function _download_figaro_use(
    release::FIGARORelease,
    regions::Vector{String},
    output_path::String,
    temporary_directory::String,
)
    urls = String[]
    first_write = true
    for destination in regions, origin in regions
        key = "A...$(destination).$(release.unit).$(origin)"
        url = _figaro_api_url(release.use_dataset, key, release.reference_year)
        source_path = joinpath(temporary_directory, "use_$(origin)_$(destination).csv")
        Downloads.download(url, source_path)
        rows = _official_use_rows(_read_eurostat_csv(source_path))
        _append_flat_rows(output_path, rows, first_write)
        first_write = false
        push!(urls, url)
    end
    return urls
end

function _figaro_api_url(dataset::String, key::String, year::Int)
    return "$(EUROSTAT_SDMX_API)/$(dataset)/$(key)?startPeriod=$(year)&endPeriod=$(year)&format=SDMX-CSV&compressed=false"
end

function _bea_api_url(release::BEARelease, table_id::Int, api_key::String)
    return "$(BEA_API_ENDPOINT)?UserID=$(api_key)&method=GetData&datasetname=InputOutput&Year=$(release.reference_year)&TableID=$(table_id)&ResultFormat=JSON"
end

function _bea_national_accounts_url(release::BEANationalAccountsRelease, api_key::String)
    return "$(BEA_API_ENDPOINT)?UserID=$(api_key)&method=GetData&datasetname=NIPA&TableName=$(release.table_name)&Frequency=$(release.frequency)&Year=$(release.reference_year)&ResultFormat=JSON"
end

function _validated_bea_api_key(api_key::AbstractString)
    key = String(strip(String(api_key)))
    isempty(key) && error("A BEA API key is required.")
    occursin(r"^[A-Za-z0-9-]+$", key) || error("BEA API keys must contain only letters, digits, and hyphens.")
    return key
end

function _bea_api_rows(path::String, table_kind::Symbol)
    data = _bea_api_data(path)
    rows = NamedTuple[]
    for observation in data
        _require_bea_observation_fields(observation, table_kind)
        value = string(observation["DataValue"])
        if table_kind === :make
            push!(rows, (
                commodity = string(observation["RowCode"]),
                industry = string(observation["ColCode"]),
                value = value,
            ))
        elseif table_kind === :use
            push!(rows, (
                commodity = string(observation["RowCode"]),
                account = string(observation["ColCode"]),
                value = value,
            ))
        else
            error("Unsupported BEA table kind: $(table_kind).")
        end
    end
    return DataFrame(rows)
end

function _bea_api_data(path::String)
    payload = JSON3.read(read(path, String))
    haskey(payload, "BEAAPI") || error("BEA response at $(path) has no BEAAPI payload.")
    api = payload["BEAAPI"]
    haskey(api, "Results") || error("BEA response at $(path) has no Results payload.")
    results = api["Results"]
    if results isa AbstractVector
        length(results) == 1 || error("BEA response at $(path) has $(length(results)) Results entries; expected one.")
        results = only(results)
    end
    if haskey(results, "Error")
        error_details = results["Error"]
        description = haskey(error_details, "APIErrorDescription") ? string(error_details["APIErrorDescription"]) : string(error_details)
        error("BEA API error: $(description)")
    end
    haskey(results, "Data") || error("BEA response at $(path) has no Data observations.")
    return results["Data"]
end

function _bea_national_accounts_rows(
    path::String,
    release::BEANationalAccountsRelease,
    lines::Set{String},
    metrics::Set{String},
)
    rows = NamedTuple[]
    required = (
        "TableName", "SeriesCode", "LineNumber", "LineDescription", "TimePeriod",
        "METRIC_NAME", "CL_UNIT", "UNIT_MULT", "DataValue",
    )
    for observation in _bea_api_data(path)
        missing = String[field for field in required if !haskey(observation, field)]
        isempty(missing) || error("BEA national-accounts observation is missing fields: $(join(missing, ", ")).")
        String(observation["TableName"]) == release.table_name || error("BEA national-accounts response contains an unexpected table name.")
        String(observation["TimePeriod"]) == string(release.reference_year) || continue
        line = String(observation["LineNumber"])
        metric = String(observation["METRIC_NAME"])
        line in lines || continue
        metric in metrics || continue
        push!(rows, (
            region = release.region,
            table_name = release.table_name,
            line = line,
            series_code = String(observation["SeriesCode"]),
            description = String(observation["LineDescription"]),
            metric = metric,
            unit = String(observation["CL_UNIT"]),
            unit_multiplier = String(observation["UNIT_MULT"]),
            value = _value(observation["DataValue"], "BEA national accounts"),
        ))
    end
    return DataFrame(rows)
end

function _bea_national_codes(values::AbstractVector{<:AbstractString}, name::String)
    codes = String.(strip.(values))
    isempty(codes) && error("Specify at least one $(name).")
    all(!isempty, codes) || error("$(name) cannot contain empty values.")
    length(unique(codes)) == length(codes) || error("$(name) must be unique.")
    return codes
end

function _require_bea_observation_fields(observation, table_kind::Symbol)
    required = ("RowCode", "ColCode", "DataValue")
    missing = String[field for field in required if !haskey(observation, field)]
    isempty(missing) || error("BEA $(table_kind) observation is missing fields: $(join(missing, ", ")).")
    return nothing
end

function _read_eurostat_csv(path::String)
    table = DataFrame(CSV.File(path; normalizenames = false))
    "OBS_VALUE" in names(table) || error("Eurostat response at $(path) is not an SDMX-CSV data table.")
    return table
end

function _official_supply_rows(source::DataFrame)
    _require_eurostat_columns(source, ["nace_r2", "cpa2_1", "geo", "OBS_VALUE"], "supply")
    rows = NamedTuple[]
    for row in eachrow(source)
        value = _value(row["OBS_VALUE"], "supply")
        iszero(value) && continue
        product = string(row["cpa2_1"])
        startswith(product, "CPA_") || continue
        region = string(row["geo"])
        push!(rows, (
            row_country = region,
            row_code = product,
            col_country = region,
            col_code = string(row["nace_r2"]),
            value_meur = value,
        ))
    end
    return DataFrame(rows)
end

function _official_use_rows(source::DataFrame)
    _require_eurostat_columns(source, ["ind_use", "prd_ava", "c_dest", "c_orig", "OBS_VALUE"], "use")
    rows = NamedTuple[]
    for row in eachrow(source)
        value = _value(row["OBS_VALUE"], "use")
        iszero(value) && continue
        product = string(row["prd_ava"])
        startswith(product, "CPA_") || continue
        push!(rows, (
            row_country = string(row["c_orig"]),
            row_code = product,
            col_country = string(row["c_dest"]),
            col_code = string(row["ind_use"]),
            value_meur = value,
        ))
    end
    return DataFrame(rows)
end

function _append_flat_rows(path::String, rows::DataFrame, first_write::Bool)
    if first_write
        if nrow(rows) == 0
            rows = DataFrame(
                row_country = String[],
                row_code = String[],
                col_country = String[],
                col_code = String[],
                value_meur = Float64[],
            )
        end
        CSV.write(path, rows; delim = '\t')
    elseif nrow(rows) > 0
        CSV.write(path, rows; delim = '\t', append = true, writeheader = false)
    end
    return nothing
end

function _require_eurostat_columns(source::DataFrame, required::Vector{String}, table_name::String)
    missing = setdiff(required, names(source))
    isempty(missing) || error("Eurostat FIGARO $(table_name) response is missing columns: $(join(missing, ", ")).")
    return nothing
end

function _valid_eurostat_identifier(value::AbstractString, name::String)
    occursin(r"^[A-Za-z0-9_]+$", value) || error("$(name) must contain only letters, digits, and underscores.")
    return nothing
end

function _validated_regions(regions::AbstractVector{<:AbstractString})
    selected = String.(regions)
    isempty(selected) && error("Specify at least one FIGARO region.")
    all(region -> !isempty(region), selected) || error("FIGARO region codes cannot be empty.")
    all(region -> occursin(r"^[A-Za-z0-9_]+$", region), selected) || error("FIGARO region codes must contain only letters, digits, and underscores.")
    length(unique(selected)) == length(selected) || error("FIGARO region codes must be unique.")
    return selected
end

"""
    EurostatAdapter(supply_path, use_path; schema=FIGAROFlatSchema(), year=nothing)

Read Eurostat FIGARO flat supply and use files. The files remain local inputs;
the adapter neither downloads a particular FIGARO edition nor imposes a region
aggregation or an IO transformation.
"""
struct EurostatAdapter
    supply_path::String
    use_path::String
    schema::FIGAROFlatSchema
    year::Union{Int, Nothing}
end

"""
    BEAAdapter(make_path, use_path; products, activities, final_uses, region,
               valuation, schema=BEAFlatSchema(), year=nothing)

Read local long-form BEA Make and Use exports as a single-region SUT. `products`
and `activities` are explicit so the importer does not infer published totals
or adjustment rows. `final_uses` identifies the retained final-demand accounts.
`valuation` records the selected BEA table basis; the adapter does not reconcile
purchaser prices, producer prices, imports, trade margins, or taxes.
"""
struct BEAAdapter
    make_path::String
    use_path::String
    products::Vector{String}
    activities::Vector{String}
    final_uses::Vector{String}
    region::String
    valuation::String
    schema::BEAFlatSchema
    year::Union{Int, Nothing}
end

function BEAAdapter(
    make_path::AbstractString,
    use_path::AbstractString;
    products::AbstractVector{<:AbstractString},
    activities::AbstractVector{<:AbstractString},
    final_uses::AbstractVector{<:AbstractString},
    region::AbstractString,
    valuation::AbstractString,
    schema::BEAFlatSchema = BEAFlatSchema(),
    year::Union{Int, Nothing} = nothing,
)
    selected_products = String.(products)
    selected_activities = String.(activities)
    selected_final_uses = String.(final_uses)
    isempty(selected_products) && error("Specify at least one BEA commodity code.")
    isempty(selected_activities) && error("Specify at least one BEA industry code.")
    length(unique(selected_products)) == length(selected_products) || error("BEA commodity codes must be unique.")
    length(unique(selected_activities)) == length(selected_activities) || error("BEA industry codes must be unique.")
    length(unique(selected_final_uses)) == length(selected_final_uses) || error("BEA final-use codes must be unique.")
    isempty(intersect(selected_activities, selected_final_uses)) || error("BEA industry and final-use codes must not overlap.")
    isempty(strip(region)) && error("BEA region cannot be empty.")
    isempty(strip(valuation)) && error("Specify the valuation used by the selected BEA tables.")
    return BEAAdapter(
        String(make_path),
        String(use_path),
        selected_products,
        selected_activities,
        selected_final_uses,
        String(region),
        String(valuation),
        schema,
        year,
    )
end

function EurostatAdapter(
    supply_path::AbstractString,
    use_path::AbstractString;
    schema::FIGAROFlatSchema = FIGAROFlatSchema(),
    year::Union{Int, Nothing} = nothing,
)
    return EurostatAdapter(String(supply_path), String(use_path), schema, year)
end

"""
    load_sut(adapter::EurostatAdapter; drop_zeros=true)

Load a multi-region FIGARO SUT. A `DOM` origin in a use table is resolved to
the corresponding use region. Product rows are identified by the configured
`product_prefix`; all remaining use accounts are retained and classified from
the supply activity list rather than hard-coded.
"""
function load_sut(adapter::EurostatAdapter; drop_zeros::Bool = true)
    schema = adapter.schema
    supply_source = _read_flat(adapter.supply_path, schema, "supply")
    use_source = _read_flat(adapter.use_path, schema, "use")
    supply = _normalize_supply(supply_source, schema; drop_zeros)
    use = _normalize_use(use_source, schema; drop_zeros)

    products = sort!(String.(unique(vcat(supply.product, use.product))))
    activities = sort!(String.(unique(supply.activity)))
    final_uses = sort!(String.(setdiff(unique(use.use_account), activities)))
    regions = sort!(String.(unique(vcat(
        supply.product_origin,
        supply.activity_region,
        use.product_origin,
        use.use_region,
    ))))
    provenance = Dict(
        "source" => "Eurostat FIGARO flat supply and use tables",
        "supply_path" => abspath(adapter.supply_path),
        "use_path" => abspath(adapter.use_path),
        "valuation" => "nominal million euro at basic prices",
    )
    adapter.year === nothing || (provenance["year"] = string(adapter.year))
    return MultiRegionSUT(
        regions = regions,
        products = products,
        activities = activities,
        final_uses = final_uses,
        supply = supply,
        use = use,
        source_tables = Dict("supply" => supply_source, "use" => use_source),
        provenance = provenance,
    )
end

function load_sut(adapter::BEAAdapter; drop_zeros::Bool = true)
    schema = adapter.schema
    make_source = _read_bea_flat(
        adapter.make_path,
        [schema.commodity, schema.industry, schema.value],
        schema.delimiter,
        "Make",
    )
    use_source = _read_bea_flat(
        adapter.use_path,
        [schema.commodity, schema.use_account, schema.value],
        schema.delimiter,
        "Use",
    )
    products = Set(adapter.products)
    activities = Set(adapter.activities)
    final_uses = Set(adapter.final_uses)
    supply = _normalize_bea_make(make_source, adapter, products; activities, drop_zeros)
    use = _normalize_bea_use(
        use_source,
        adapter,
        products;
        accounts = union(activities, final_uses),
        drop_zeros,
    )
    missing_products = setdiff(products, Set(supply.product))
    isempty(missing_products) || error("BEA Make table has no non-zero supply for selected commodities: $(join(sort!(collect(missing_products)), ", ")).")
    missing_activities = setdiff(activities, Set(supply.activity))
    isempty(missing_activities) || error("BEA Make table has no non-zero supply for selected industries: $(join(sort!(collect(missing_activities)), ", ")).")

    provenance = Dict(
        "source" => "BEA Make and Use tables",
        "make_path" => abspath(adapter.make_path),
        "use_path" => abspath(adapter.use_path),
        "region" => adapter.region,
        "valuation" => adapter.valuation,
    )
    adapter.year === nothing || (provenance["year"] = string(adapter.year))
    return MultiRegionSUT(
        regions = [adapter.region],
        products = sort!(collect(products)),
        activities = sort!(collect(activities)),
        final_uses = sort!(collect(final_uses)),
        supply = supply,
        use = use,
        source_tables = Dict("make" => make_source, "use" => use_source),
        provenance = provenance,
    )
end

"""
    load_iobundle(adapter::EurostatAdapter)

FIGARO is inherently a multi-region SUT. Use `load_sut` first, then choose the
model-specific region aggregation and SUT-to-IO transformation explicitly.
"""
function load_iobundle(::EurostatAdapter)
    error("FIGARO imports are multi-region SUTs. Use load_sut(EurostatAdapter(...)) first.")
end

function load_iobundle(::BEAAdapter)
    error("BEA Make/Use imports are SUTs. Use load_sut(BEAAdapter(...)) first, then select an explicit SUT-to-IO transformation.")
end

function _read_flat(path::String, schema::FIGAROFlatSchema, table_name::String)
    isfile(path) || error("FIGARO $(table_name) file not found: $(path)")
    table = DataFrame(CSV.File(path; delim = schema.delimiter, normalizenames = false))
    required = [schema.row_region, schema.row_code, schema.column_region, schema.column_code, schema.value]
    available = Set(Symbol.(names(table)))
    missing = [String(name) for name in required if !(name in available)]
    isempty(missing) || error("FIGARO $(table_name) file is missing required columns: $(join(missing, ", ")).")
    return table
end

function _read_bea_flat(
    path::String,
    required::Vector{Symbol},
    delimiter::Char,
    table_name::String,
)
    isfile(path) || error("BEA $(table_name) file not found: $(path)")
    table = DataFrame(CSV.File(path; delim = delimiter, normalizenames = false))
    available = Set(Symbol.(names(table)))
    missing = [String(name) for name in required if !(name in available)]
    isempty(missing) || error("BEA $(table_name) file is missing required columns: $(join(missing, ", ")).")
    return table
end

function _normalize_supply(source::DataFrame, schema::FIGAROFlatSchema; drop_zeros::Bool)
    rows = NamedTuple[]
    for row in eachrow(source)
        value = _value(row[schema.value], "supply")
        drop_zeros && iszero(value) && continue
        activity_region = string(row[schema.column_region])
        product_origin = _resolve_origin(row[schema.row_region], activity_region, schema)
        product = _normalize_code(row[schema.row_code])
        activity = _normalize_code(row[schema.column_code])
        startswith(product, schema.product_prefix) || continue
        push!(rows, (
            product_origin = product_origin,
            product = product,
            activity_region = activity_region,
            activity = activity,
            value = value,
        ))
    end
    return DataFrame(rows)
end

function _normalize_use(source::DataFrame, schema::FIGAROFlatSchema; drop_zeros::Bool)
    rows = NamedTuple[]
    for row in eachrow(source)
        value = _value(row[schema.value], "use")
        drop_zeros && iszero(value) && continue
        use_region = string(row[schema.column_region])
        product_origin = _resolve_origin(row[schema.row_region], use_region, schema)
        product = _normalize_code(row[schema.row_code])
        use_account = _normalize_code(row[schema.column_code])
        startswith(product, schema.product_prefix) || continue
        push!(rows, (
            product_origin = product_origin,
            product = product,
            use_region = use_region,
            use_account = use_account,
            value = value,
        ))
    end
    return DataFrame(rows)
end

function _normalize_bea_make(
    source::DataFrame,
    adapter::BEAAdapter,
    products::Set{String};
    activities::Set{String},
    drop_zeros::Bool,
)
    rows = NamedTuple[]
    schema = adapter.schema
    for row in eachrow(source)
        product = _normalize_code(row[schema.commodity])
        product in products || continue
        activity = _normalize_code(row[schema.industry])
        activity in activities || continue
        value = _value(row[schema.value], "BEA Make")
        drop_zeros && iszero(value) && continue
        push!(rows, (
            product_origin = adapter.region,
            product = product,
            activity_region = adapter.region,
            activity = activity,
            value = value,
        ))
    end
    return DataFrame(rows)
end

function _normalize_bea_use(
    source::DataFrame,
    adapter::BEAAdapter,
    products::Set{String};
    accounts::Set{String},
    drop_zeros::Bool,
)
    rows = NamedTuple[]
    schema = adapter.schema
    for row in eachrow(source)
        product = _normalize_code(row[schema.commodity])
        product in products || continue
        account = _normalize_code(row[schema.use_account])
        account in accounts || continue
        value = _value(row[schema.value], "BEA Use")
        drop_zeros && iszero(value) && continue
        push!(rows, (
            product_origin = adapter.region,
            product = product,
            use_region = adapter.region,
            use_account = account,
            value = value,
        ))
    end
    return DataFrame(rows)
end

function _resolve_origin(origin, destination::AbstractString, schema::FIGAROFlatSchema)
    value = string(origin)
    return value == schema.domestic_marker ? destination : value
end

function _normalize_code(code)
    value = string(code)
    return occursin(':', value) ? split(value, ':'; limit = 2)[2] : value
end

function _value(value, table_name::String)
    ismissing(value) && error("$(table_name) contains a missing value.")
    raw = value isa Number ? value : replace(strip(string(value)), "," => "")
    parsed = raw isa Number ? Float64(raw) : tryparse(Float64, raw)
    isnothing(parsed) && error("$(table_name) contains a non-numeric value: $(value)")
    isfinite(parsed) || error("$(table_name) contains a non-finite value.")
    return parsed
end

end # module
