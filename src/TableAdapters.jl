"""Adapters for direct IO, national SUT, and satellite tables."""
module TableAdapters

using CSV
using DataFrames
using Dates
using Downloads
using JSON3
using SHA
using TOML
using ZipFile

using ..JCGEImportData: MultiRegionIOT, MultiRegionSUT, SatelliteTable
import ..Adapters: load_sut

export IOTFlatSchema, IOTAdapter, OECDICIOAdapter
export OECDICIORelease, download_oecd_icio, normalize_oecd_icio
export NationalSUTFlatSchema, EurostatNationalSUTAdapter
export EurostatNationalSUTRelease, download_eurostat_national_sut
export SatelliteFlatSchema, SatelliteAdapter
export EurostatSatelliteRelease, download_eurostat_satellite
export EurostatNationalAccountsRelease, download_eurostat_national_accounts
export load_iot, load_satellite

"""Column names for local long-form industry-by-industry IO tables."""
Base.@kwdef struct IOTFlatSchema
    supplier_region::Symbol = :supplier_region
    supplier_industry::Symbol = :supplier_industry
    user_region::Symbol = :user_region
    user_industry::Symbol = :user_industry
    demand_region::Symbol = :demand_region
    final_use::Symbol = :final_use
    output_region::Symbol = :region
    output_industry::Symbol = :industry
    value::Symbol = :value
    delimiter::Char = ','
end

"""
    IOTAdapter(intermediate_path, final_demand_path, output_path; ...)

Read local long-form intermediate, final-demand, and gross-output tables for a
symmetric industry-by-industry IO system. The caller explicitly supplies the
retained regions, industries, final-use accounts, valuation, and source.
"""
struct IOTAdapter
    intermediate_path::String
    final_demand_path::String
    output_path::String
    regions::Vector{String}
    industries::Vector{String}
    final_uses::Vector{String}
    valuation::String
    source::String
    schema::IOTFlatSchema
    year::Union{Int, Nothing}
end

function IOTAdapter(
    intermediate_path::AbstractString,
    final_demand_path::AbstractString,
    output_path::AbstractString;
    regions::AbstractVector{<:AbstractString},
    industries::AbstractVector{<:AbstractString},
    final_uses::AbstractVector{<:AbstractString},
    valuation::AbstractString,
    source::AbstractString = "local industry-by-industry IO table",
    schema::IOTFlatSchema = IOTFlatSchema(),
    year::Union{Int, Nothing} = nothing,
)
    selected_regions = _codes(regions, "IO regions")
    selected_industries = _codes(industries, "IO industries")
    selected_final_uses = _codes(final_uses, "IO final-use accounts"; allow_empty = true)
    isempty(intersect(selected_industries, selected_final_uses)) || error("IO industry and final-use codes must not overlap.")
    _metadata(valuation, "IO valuation")
    _metadata(source, "IO source")
    return IOTAdapter(
        String(intermediate_path), String(final_demand_path), String(output_path),
        selected_regions, selected_industries, selected_final_uses,
        String(valuation), String(source), schema, year,
    )
end

"""
    OECDICIOAdapter(intermediate_path, final_demand_path, output_path; edition, ...)

Read a local long-form extraction of OECD Inter-Country Input-Output (ICIO)
tables using the generic IO layout. The source edition and extraction scope are
always explicit; this adapter does not download or aggregate ICIO data.
"""
struct OECDICIOAdapter
    iot::IOTAdapter
    edition::String
end

function OECDICIOAdapter(
    intermediate_path::AbstractString,
    final_demand_path::AbstractString,
    output_path::AbstractString;
    edition::AbstractString,
    regions::AbstractVector{<:AbstractString},
    industries::AbstractVector{<:AbstractString},
    final_uses::AbstractVector{<:AbstractString},
    valuation::AbstractString,
    schema::IOTFlatSchema = IOTFlatSchema(),
    year::Union{Int, Nothing} = nothing,
)
    _metadata(edition, "OECD ICIO edition")
    return OECDICIOAdapter(
        IOTAdapter(
            intermediate_path, final_demand_path, output_path;
            regions, industries, final_uses, valuation,
            source = "OECD Inter-Country Input-Output (ICIO) tables",
            schema, year,
        ),
        String(edition),
    )
end

"""
    OECDICIORelease(edition, period, archive_url)

Description of one caller-selected official OECD ICIO archive. OECD publishes
ICIO as period archives, so the URL and its edition are explicit rather than
embedded in package code.
"""
struct OECDICIORelease
    edition::String
    period::String
    archive_url::String
    function OECDICIORelease(edition::String, period::String, archive_url::String)
        _metadata(edition, "OECD ICIO edition")
        _metadata(period, "OECD ICIO period")
        _official_url(archive_url, "oecd.org", "OECD ICIO archive URL")
        return new(edition, period, archive_url)
    end
end

function OECDICIORelease(
    edition::AbstractString,
    period::AbstractString,
    archive_url::AbstractString,
)
    return OECDICIORelease(String(edition), String(period), String(archive_url))
end

"""
    download_oecd_icio(release, directory)

Cache a caller-selected official OECD ICIO archive and record its URL, edition,
period, retrieval time, and checksum. It does not select countries or convert
the source matrix; use `OECDICIOAdapter` after an explicit local extraction.
"""
function download_oecd_icio(release::OECDICIORelease, directory::AbstractString)
    return _download_oecd_icio(release, directory, Downloads.download)
end

function _download_oecd_icio(release::OECDICIORelease, directory::AbstractString, downloader::Function)
    mkpath(directory)
    archive_path = joinpath(directory, "oecd_icio_archive.zip")
    manifest_path = joinpath(directory, "oecd_icio_manifest.toml")
    existing = filter(ispath, [archive_path, manifest_path])
    isempty(existing) || error("OECD ICIO cache already exists: $(join(existing, ", ")). Choose another directory or remove it explicitly.")
    mktempdir(directory) do temporary_directory
        temporary_archive = joinpath(temporary_directory, "source.zip")
        downloader(release.archive_url, temporary_archive)
        filesize(temporary_archive) > 0 || error("Downloaded OECD ICIO archive is empty.")
        _verify_zip_archive(temporary_archive, "Downloaded OECD ICIO archive")
        mv(temporary_archive, archive_path)
    end
    manifest = Dict(
        "source" => "OECD Inter-Country Input-Output (ICIO) tables",
        "edition" => release.edition,
        "period" => release.period,
        "archive_url" => release.archive_url,
        "archive_file" => basename(archive_path),
        "archive_sha256" => bytes2hex(sha256(read(archive_path))),
        "retrieved_at_utc" => string(now(UTC)),
    )
    open(manifest_path, "w") do io
        TOML.print(io, manifest)
    end
    return (archive_path = archive_path, manifest_path = manifest_path)
end

"""
    normalize_oecd_icio(release, archive_path, directory; reference_year, regions,
                        industries, final_uses)

Read one year from a regular OECD ICIO CSV archive and write the selected
intermediate, final-demand, and gross-output tables in the local long-form IO
layout accepted by `OECDICIOAdapter`. Regions, industries, and final-demand
categories are source codes and must be selected explicitly. The function
preserves the source's industry-by-industry structure; aggregation, treatment
of value added, and SAM construction remain outside this importer.
"""
function normalize_oecd_icio(
    release::OECDICIORelease,
    archive_path::AbstractString,
    directory::AbstractString;
    reference_year::Integer,
    regions::AbstractVector{<:AbstractString},
    industries::AbstractVector{<:AbstractString},
    final_uses::AbstractVector{<:AbstractString},
)
    isfile(archive_path) || error("OECD ICIO archive not found: $(archive_path)")
    year = Int(reference_year)
    year > 0 || error("OECD ICIO reference_year must be positive.")
    selected_regions = _codes(regions, "OECD ICIO regions")
    selected_industries = _codes(industries, "OECD ICIO industries")
    selected_final_uses = _codes(final_uses, "OECD ICIO final-use accounts"; allow_empty = true)
    isempty(intersect(selected_industries, selected_final_uses)) || error("OECD ICIO industry and final-use codes must not overlap.")
    _verify_zip_archive(String(archive_path), "OECD ICIO archive")

    mkpath(directory)
    stem = "oecd_icio_$(year)"
    intermediate_path = joinpath(directory, "$(stem)_intermediate.csv")
    final_demand_path = joinpath(directory, "$(stem)_final_demand.csv")
    output_path = joinpath(directory, "$(stem)_output.csv")
    manifest_path = joinpath(directory, "$(stem)_manifest.toml")
    existing = filter(ispath, [intermediate_path, final_demand_path, output_path, manifest_path])
    isempty(existing) || error("OECD ICIO normalized output already exists: $(join(existing, ", ")). Choose another directory or remove it explicitly.")

    source_member, source = _oecd_icio_archive_matrix(String(archive_path), year)
    intermediate, final_demand, output = _oecd_icio_long_tables(
        source,
        selected_regions,
        selected_industries,
        selected_final_uses,
    )
    mktempdir(directory) do temporary_directory
        temporary_intermediate = joinpath(temporary_directory, "intermediate.csv")
        temporary_final_demand = joinpath(temporary_directory, "final_demand.csv")
        temporary_output = joinpath(temporary_directory, "output.csv")
        CSV.write(temporary_intermediate, intermediate)
        CSV.write(temporary_final_demand, final_demand)
        CSV.write(temporary_output, output)
        mv(temporary_intermediate, intermediate_path)
        mv(temporary_final_demand, final_demand_path)
        mv(temporary_output, output_path)
    end
    manifest = Dict(
        "source" => "OECD Inter-Country Input-Output (ICIO) tables",
        "edition" => release.edition,
        "period" => release.period,
        "reference_year" => year,
        "archive_path" => abspath(archive_path),
        "archive_sha256" => bytes2hex(sha256(read(archive_path))),
        "source_member" => source_member,
        "regions" => selected_regions,
        "industries" => selected_industries,
        "final_uses" => selected_final_uses,
        "intermediate" => Dict("file" => basename(intermediate_path), "sha256" => bytes2hex(sha256(read(intermediate_path)))),
        "final_demand" => Dict("file" => basename(final_demand_path), "sha256" => bytes2hex(sha256(read(final_demand_path)))),
        "output" => Dict("file" => basename(output_path), "sha256" => bytes2hex(sha256(read(output_path)))),
        "created_at_utc" => string(now(UTC)),
    )
    open(manifest_path, "w") do io
        TOML.print(io, manifest)
    end
    return (
        intermediate_path = intermediate_path,
        final_demand_path = final_demand_path,
        output_path = output_path,
        manifest_path = manifest_path,
    )
end

const EUROSTAT_STATISTICS_API = "https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0/data"

"""
    EurostatNationalSUTRelease(reference_year, region; ...)

Description of the published Eurostat national supply and use tables selected
for one country and year. Defaults identify Eurostat's current-price supply
table (`naio_10_cp15`) and annual use table at purchasers' prices
(`naio_10_cp16`); callers can replace
both identifiers explicitly when another published table pair is intended.
"""
struct EurostatNationalSUTRelease
    reference_year::Int
    region::String
    unit::String
    supply_dataset::String
    use_dataset::String
    function EurostatNationalSUTRelease(
        reference_year::Int,
        region::String,
        unit::String,
        supply_dataset::String,
        use_dataset::String,
    )
        reference_year > 0 || error("Eurostat national SUT reference_year must be positive.")
        _identifier(region, "Eurostat national SUT region")
        _identifier(unit, "Eurostat national SUT unit")
        _identifier(supply_dataset, "Eurostat national supply dataset")
        _identifier(use_dataset, "Eurostat national use dataset")
        return new(reference_year, region, unit, supply_dataset, use_dataset)
    end
end

function EurostatNationalSUTRelease(
    reference_year::Integer,
    region::AbstractString;
    unit::AbstractString = "MIO_EUR",
    supply_dataset::AbstractString = "naio_10_cp15",
    use_dataset::AbstractString = "naio_10_cp16",
)
    year = Int(reference_year)
    return EurostatNationalSUTRelease(year, String(region), String(unit), String(supply_dataset), String(use_dataset))
end

"""
    download_eurostat_national_sut(release, directory; products, activities, final_uses)

Download the caller-selected official Eurostat national supply and use tables
once, retain raw JSON-stat responses, and write local long-form supply/use CSV
files for `EurostatNationalSUTAdapter`. Product, industry, and final-use codes
are explicit. The function filters `stk_flow` to `TOTAL` where that dimension
is present; valuation and any subsequent balancing remain model decisions.
"""
function download_eurostat_national_sut(
    release::EurostatNationalSUTRelease,
    directory::AbstractString;
    products::AbstractVector{<:AbstractString},
    activities::AbstractVector{<:AbstractString},
    final_uses::AbstractVector{<:AbstractString},
)
    selected_products = _codes(products, "Eurostat national SUT products")
    selected_activities = _codes(activities, "Eurostat national SUT activities")
    selected_final_uses = _codes(final_uses, "Eurostat national SUT final-use accounts"; allow_empty = true)
    isempty(intersect(selected_activities, selected_final_uses)) || error("Eurostat national SUT activity and final-use codes must not overlap.")
    mkpath(directory)
    stem = "eurostat_national_$(release.region)_$(release.reference_year)"
    supply_raw_path = joinpath(directory, "$(stem)_supply.json")
    use_raw_path = joinpath(directory, "$(stem)_use.json")
    supply_path = joinpath(directory, "$(stem)_supply.csv")
    use_path = joinpath(directory, "$(stem)_use.csv")
    manifest_path = joinpath(directory, "$(stem)_manifest.toml")
    existing = filter(ispath, [supply_raw_path, use_raw_path, supply_path, use_path, manifest_path])
    isempty(existing) || error("Eurostat national SUT cache already exists: $(join(existing, ", ")). Choose another directory or remove it explicitly.")
    supply_url = _eurostat_national_url(release.supply_dataset, release)
    use_url = _eurostat_national_url(release.use_dataset, release)
    mktempdir(directory) do temporary_directory
        temporary_supply_raw = joinpath(temporary_directory, "supply.json")
        temporary_use_raw = joinpath(temporary_directory, "use.json")
        temporary_supply = joinpath(temporary_directory, "supply.csv")
        temporary_use = joinpath(temporary_directory, "use.csv")
        Downloads.download(supply_url, temporary_supply_raw)
        Downloads.download(use_url, temporary_use_raw)
        supply = _eurostat_jsonstat_rows(
            temporary_supply_raw;
            product_dimension = "prd_amo",
            account_dimension = "ind_impv",
            products = Set(selected_products),
            accounts = Set(selected_activities),
            account_name = :activity,
        )
        use = _eurostat_jsonstat_rows(
            temporary_use_raw;
            product_dimension = "prd_ava",
            account_dimension = "ind_use",
            products = Set(selected_products),
            accounts = union(Set(selected_activities), Set(selected_final_uses)),
            account_name = :account,
        )
        nrow(supply) > 0 || error("Eurostat national supply response has no observations for the selected products and activities.")
        nrow(use) > 0 || error("Eurostat national use response has no observations for the selected products and accounts.")
        CSV.write(temporary_supply, supply)
        CSV.write(temporary_use, use)
        mv(temporary_supply_raw, supply_raw_path)
        mv(temporary_use_raw, use_raw_path)
        mv(temporary_supply, supply_path)
        mv(temporary_use, use_path)
    end
    manifest = Dict(
        "source" => "Eurostat dissemination API",
        "reference_year" => release.reference_year,
        "region" => release.region,
        "unit" => release.unit,
        "supply" => Dict(
            "dataset" => release.supply_dataset,
            "query" => supply_url,
            "raw_file" => basename(supply_raw_path),
            "raw_sha256" => bytes2hex(sha256(read(supply_raw_path))),
            "file" => basename(supply_path),
            "sha256" => bytes2hex(sha256(read(supply_path))),
        ),
        "use" => Dict(
            "dataset" => release.use_dataset,
            "query" => use_url,
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
    return (supply_path = supply_path, use_path = use_path, supply_raw_path = supply_raw_path, use_raw_path = use_raw_path, manifest_path = manifest_path)
end

"""
    EurostatNationalAccountsRelease(reference_year, dataset; unit, dimensions,
                                    region_dimension="geo", filters=Dict("freq" => "A"))

Description of one selected Eurostat national-accounts dataflow. `dimensions`
are the published dimensions that the calling workflow will select explicitly,
for example `("sector", "na_item", "direct")` for annual institutional-sector
transactions. The resulting local table preserves these source dimensions; it
does not map them to SAM accounts.
"""
struct EurostatNationalAccountsRelease
    reference_year::Int
    dataset::String
    unit::String
    region_dimension::String
    dimensions::Vector{String}
    filters::Dict{String, String}
    function EurostatNationalAccountsRelease(
        reference_year::Int,
        dataset::String,
        unit::String,
        region_dimension::String,
        dimensions::Vector{String},
        filters::Dict{String, String},
    )
        reference_year > 0 || error("Eurostat national-accounts reference_year must be positive.")
        _identifier(dataset, "Eurostat national-accounts dataset")
        _identifier(unit, "Eurostat national-accounts unit")
        _identifier(region_dimension, "Eurostat national-accounts region dimension")
        isempty(dimensions) && error("Specify at least one Eurostat national-accounts source dimension.")
        length(unique(dimensions)) == length(dimensions) || error("Eurostat national-accounts source dimensions must be unique.")
        for dimension in dimensions
            _identifier(dimension, "Eurostat national-accounts source dimension")
            dimension in ("time", "unit", region_dimension) && error("Eurostat national-accounts source dimensions cannot include $(dimension).")
            haskey(filters, dimension) && error("Eurostat national-accounts dimension $(dimension) cannot also be a fixed filter.")
        end
        for (dimension, value) in filters
            _identifier(dimension, "Eurostat national-accounts filter dimension")
            _identifier(value, "Eurostat national-accounts filter value")
        end
        return new(reference_year, dataset, unit, region_dimension, dimensions, filters)
    end
end

function EurostatNationalAccountsRelease(
    reference_year::Integer,
    dataset::AbstractString;
    unit::AbstractString,
    dimensions::AbstractVector{<:AbstractString},
    region_dimension::AbstractString = "geo",
    filters::AbstractDict{<:AbstractString, <:AbstractString} = Dict("freq" => "A"),
)
    return EurostatNationalAccountsRelease(
        Int(reference_year), String(dataset), String(unit), String(region_dimension),
        String.(dimensions), Dict(String(dimension) => String(value) for (dimension, value) in filters),
    )
end

"""
    download_eurostat_national_accounts(release, directory; regions, selections)

Download one explicitly selected Eurostat national-accounts table through the
official dissemination API. `selections` must specify every dimension declared
by `release`. The returned CSV has `region`, the declared source-dimension
columns, `unit`, and `value`; it is a source cache for a later explicit SAM
mapping, not a SAM construction routine.
"""
function download_eurostat_national_accounts(
    release::EurostatNationalAccountsRelease,
    directory::AbstractString;
    regions::AbstractVector{<:AbstractString},
    selections::AbstractDict,
)
    selected_regions = _codes(regions, "Eurostat national-accounts regions")
    selected = _eurostat_national_account_selections(release, selections)
    mkpath(directory)
    stem = "eurostat_national_accounts_$(release.dataset)_$(release.reference_year)"
    accounts_path = joinpath(directory, "$(stem).csv")
    manifest_path = joinpath(directory, "$(stem)_manifest.toml")
    raw_paths = [joinpath(directory, "$(stem)_$(region).json") for region in selected_regions]
    existing = filter(ispath, [accounts_path, manifest_path, raw_paths...])
    isempty(existing) || error("Eurostat national-accounts cache already exists: $(join(existing, ", ")). Choose another directory or remove it explicitly.")

    rows = NamedTuple[]
    urls = String[]
    output_names = Tuple([:region; Symbol.(release.dimensions); :unit; :value])
    mktempdir(directory) do temporary_directory
        temporary_raw_paths = String[]
        for region in selected_regions
            url = _eurostat_national_accounts_url(release, region, selected)
            push!(urls, url)
            temporary_raw = joinpath(temporary_directory, "$(region).json")
            push!(temporary_raw_paths, temporary_raw)
            Downloads.download(url, temporary_raw)
            append!(rows, _eurostat_national_accounts_rows(
                _eurostat_jsonstat_table(temporary_raw), release, region, selected, output_names,
            ))
        end
        isempty(rows) && error("Eurostat national-accounts responses have no observations for the declared selection.")
        temporary_accounts = joinpath(temporary_directory, "national_accounts.csv")
        CSV.write(temporary_accounts, DataFrame(rows))
        for (temporary_raw, raw_path) in zip(temporary_raw_paths, raw_paths)
            mv(temporary_raw, raw_path)
        end
        mv(temporary_accounts, accounts_path)
    end
    manifest = Dict(
        "source" => "Eurostat dissemination API",
        "dataset" => release.dataset,
        "reference_year" => release.reference_year,
        "unit" => release.unit,
        "region_dimension" => release.region_dimension,
        "dimensions" => release.dimensions,
        "filters" => release.filters,
        "regions" => selected_regions,
        "selections" => selected,
        "queries" => urls,
        "raw_files" => [
            Dict("file" => basename(path), "sha256" => bytes2hex(sha256(read(path)))) for path in raw_paths
        ],
        "file" => basename(accounts_path),
        "sha256" => bytes2hex(sha256(read(accounts_path))),
        "retrieved_at_utc" => string(now(UTC)),
    )
    open(manifest_path, "w") do io
        TOML.print(io, manifest)
    end
    return (path = accounts_path, raw_paths = raw_paths, manifest_path = manifest_path)
end

"""
    EurostatSatelliteRelease(reference_year, dataset; ...)

Explicit description of a Eurostat dataset that can be normalized into the
unit-preserving `SatelliteAdapter` layout. The caller specifies the source
dimensions that identify regions, industries, and indicators. Set
`industry_dimension = nothing` for an economy-wide source and provide an
explicit `aggregate_industry` when downloading it.
"""
struct EurostatSatelliteRelease
    reference_year::Int
    dataset::String
    unit::String
    region_dimension::String
    industry_dimension::Union{String, Nothing}
    indicator_dimension::String
    filters::Dict{String, String}
    function EurostatSatelliteRelease(
        reference_year::Int,
        dataset::String,
        unit::String,
        region_dimension::String,
        industry_dimension::Union{String, Nothing},
        indicator_dimension::String,
        filters::Dict{String, String},
    )
        reference_year > 0 || error("Eurostat satellite reference_year must be positive.")
        _identifier(dataset, "Eurostat satellite dataset")
        _identifier(unit, "Eurostat satellite unit")
        _identifier(region_dimension, "Eurostat satellite region dimension")
        isnothing(industry_dimension) || _identifier(industry_dimension, "Eurostat satellite industry dimension")
        _identifier(indicator_dimension, "Eurostat satellite indicator dimension")
        for (dimension, value) in filters
            _identifier(dimension, "Eurostat satellite filter dimension")
            _identifier(value, "Eurostat satellite filter value")
        end
        return new(reference_year, dataset, unit, region_dimension, industry_dimension, indicator_dimension, filters)
    end
end

function EurostatSatelliteRelease(
    reference_year::Integer,
    dataset::AbstractString;
    unit::AbstractString,
    region_dimension::AbstractString = "geo",
    industry_dimension::Union{AbstractString, Nothing},
    indicator_dimension::AbstractString,
    filters::AbstractDict{<:AbstractString, <:AbstractString} = Dict{String, String}(),
)
    return EurostatSatelliteRelease(
        Int(reference_year),
        String(dataset),
        String(unit),
        String(region_dimension),
        isnothing(industry_dimension) ? nothing : String(industry_dimension),
        String(indicator_dimension),
        Dict(String(dimension) => String(value) for (dimension, value) in filters),
    )
end

"""
    download_eurostat_satellite(release, directory; regions, industries, indicators,
                                aggregate_industry=nothing)

Download an explicitly selected Eurostat satellite source and normalize it to
`region`, `industry`, `indicator`, `unit`, `value` records. It keeps raw
JSON-stat responses and a checksum manifest. For an industry-resolved source,
provide `industries`; for an economy-wide source, set
`release.industry_dimension = nothing` and explicitly supply the account label
to use as `aggregate_industry`.
"""
function download_eurostat_satellite(
    release::EurostatSatelliteRelease,
    directory::AbstractString;
    regions::AbstractVector{<:AbstractString},
    industries::AbstractVector{<:AbstractString} = String[],
    indicators::AbstractVector{<:AbstractString},
    aggregate_industry::Union{AbstractString, Nothing} = nothing,
)
    selected_regions = _codes(regions, "Eurostat satellite regions")
    selected_industries = _codes(industries, "Eurostat satellite industries"; allow_empty = true)
    selected_indicators = _codes(indicators, "Eurostat satellite indicators")
    if isnothing(release.industry_dimension)
        isempty(selected_industries) || error("Eurostat satellite industries cannot be supplied when industry_dimension is nothing.")
        isnothing(aggregate_industry) && error("Specify aggregate_industry for an economy-wide Eurostat satellite source.")
        _metadata(aggregate_industry, "Eurostat satellite aggregate_industry")
    else
        isempty(selected_industries) && error("Specify at least one Eurostat satellite industry.")
        isnothing(aggregate_industry) || error("aggregate_industry is only valid when industry_dimension is nothing.")
    end

    mkpath(directory)
    stem = "eurostat_satellite_$(release.dataset)_$(release.reference_year)"
    satellite_path = joinpath(directory, "$(stem).csv")
    manifest_path = joinpath(directory, "$(stem)_manifest.toml")
    raw_paths = [joinpath(directory, "$(stem)_$(region).json") for region in selected_regions]
    existing = filter(ispath, [satellite_path, manifest_path, raw_paths...])
    isempty(existing) || error("Eurostat satellite cache already exists: $(join(existing, ", ")). Choose another directory or remove it explicitly.")

    rows = DataFrame(
        region = String[], industry = String[], indicator = String[],
        unit = String[], value = Float64[],
    )
    urls = String[]
    mktempdir(directory) do temporary_directory
        temporary_raw_paths = String[]
        for region in selected_regions
            url = _eurostat_satellite_url(release, region)
            push!(urls, url)
            temporary_raw = joinpath(temporary_directory, "$(region).json")
            push!(temporary_raw_paths, temporary_raw)
            Downloads.download(url, temporary_raw)
            observations = _eurostat_jsonstat_table(temporary_raw)
            required_dimensions = String[
                release.region_dimension,
                release.indicator_dimension,
                "unit",
            ]
            isnothing(release.industry_dimension) || push!(required_dimensions, release.industry_dimension)
            append!(required_dimensions, keys(release.filters))
            missing_dimensions = filter(dimension -> !(Symbol(dimension) in propertynames(observations)), required_dimensions)
            isempty(missing_dimensions) || error("Eurostat satellite response has no required dimensions: $(join(missing_dimensions, ", ")).")
            for observation in eachrow(observations)
                String(observation[Symbol(release.region_dimension)]) == region || continue
                String(observation[:unit]) == release.unit || continue
                indicator = String(observation[Symbol(release.indicator_dimension)])
                indicator in selected_indicators || continue
                all(String(observation[Symbol(dimension)]) == value for (dimension, value) in release.filters) || continue
                industry = isnothing(release.industry_dimension) ? String(aggregate_industry) : String(observation[Symbol(release.industry_dimension)])
                isnothing(release.industry_dimension) || industry in selected_industries || continue
                push!(rows, (region = region, industry = industry, indicator = indicator, unit = release.unit, value = _value(observation[:value], "Eurostat satellite")))
            end
        end
        nrow(rows) > 0 || error("Eurostat satellite responses have no observations for the declared selection.")
        temporary_satellite = joinpath(temporary_directory, "satellite.csv")
        CSV.write(temporary_satellite, rows)
        for (temporary_raw, raw_path) in zip(temporary_raw_paths, raw_paths)
            mv(temporary_raw, raw_path)
        end
        mv(temporary_satellite, satellite_path)
    end
    manifest = Dict(
        "source" => "Eurostat dissemination API",
        "dataset" => release.dataset,
        "reference_year" => release.reference_year,
        "unit" => release.unit,
        "region_dimension" => release.region_dimension,
        "industry_dimension" => something(release.industry_dimension, ""),
        "indicator_dimension" => release.indicator_dimension,
        "filters" => release.filters,
        "regions" => selected_regions,
        "industries" => isnothing(release.industry_dimension) ? [String(aggregate_industry)] : selected_industries,
        "indicators" => selected_indicators,
        "queries" => urls,
        "raw_files" => [
            Dict(
                "file" => basename(path),
                "sha256" => bytes2hex(sha256(read(path))),
            ) for path in raw_paths
        ],
        "file" => basename(satellite_path),
        "sha256" => bytes2hex(sha256(read(satellite_path))),
        "retrieved_at_utc" => string(now(UTC)),
    )
    open(manifest_path, "w") do io
        TOML.print(io, manifest)
    end
    return (path = satellite_path, raw_paths = raw_paths, manifest_path = manifest_path)
end

"""Column names for local long-form national supply and use exports."""
Base.@kwdef struct NationalSUTFlatSchema
    product::Symbol = :product
    supply_activity::Symbol = :activity
    use_account::Symbol = :account
    value::Symbol = :value
    delimiter::Char = ','
end

"""
    EurostatNationalSUTAdapter(supply_path, use_path; ...)

Read a local long-form export of Eurostat national supply and use data. The
caller chooses the source valuation and treatment of imports, margins, and
taxes before import; this adapter only normalizes that selection.
"""
struct EurostatNationalSUTAdapter
    supply_path::String
    use_path::String
    products::Vector{String}
    activities::Vector{String}
    final_uses::Vector{String}
    region::String
    valuation::String
    schema::NationalSUTFlatSchema
    year::Union{Int, Nothing}
end

function EurostatNationalSUTAdapter(
    supply_path::AbstractString,
    use_path::AbstractString;
    products::AbstractVector{<:AbstractString},
    activities::AbstractVector{<:AbstractString},
    final_uses::AbstractVector{<:AbstractString},
    region::AbstractString,
    valuation::AbstractString,
    schema::NationalSUTFlatSchema = NationalSUTFlatSchema(),
    year::Union{Int, Nothing} = nothing,
)
    selected_products = _codes(products, "Eurostat national SUT products")
    selected_activities = _codes(activities, "Eurostat national SUT activities")
    selected_final_uses = _codes(final_uses, "Eurostat national SUT final-use accounts"; allow_empty = true)
    isempty(intersect(selected_activities, selected_final_uses)) || error("Eurostat national SUT activity and final-use codes must not overlap.")
    _metadata(region, "Eurostat national SUT region")
    _metadata(valuation, "Eurostat national SUT valuation")
    return EurostatNationalSUTAdapter(
        String(supply_path), String(use_path), selected_products,
        selected_activities, selected_final_uses, String(region),
        String(valuation), schema, year,
    )
end

"""Column names for local long-form satellite observations."""
Base.@kwdef struct SatelliteFlatSchema
    region::Symbol = :region
    industry::Symbol = :industry
    indicator::Symbol = :indicator
    unit::Symbol = :unit
    value::Symbol = :value
    delimiter::Char = ','
end

"""
    SatelliteAdapter(path; regions, industries, indicators, source, ...)

Read a unit-preserving local satellite table. It keeps physical,
environmental, and socioeconomic observations outside monetary IO accounts.
"""
struct SatelliteAdapter
    path::String
    regions::Vector{String}
    industries::Vector{String}
    indicators::Vector{String}
    source::String
    schema::SatelliteFlatSchema
    year::Union{Int, Nothing}
end

function SatelliteAdapter(
    path::AbstractString;
    regions::AbstractVector{<:AbstractString},
    industries::AbstractVector{<:AbstractString},
    indicators::AbstractVector{<:AbstractString},
    source::AbstractString,
    schema::SatelliteFlatSchema = SatelliteFlatSchema(),
    year::Union{Int, Nothing} = nothing,
)
    _metadata(source, "Satellite source")
    return SatelliteAdapter(
        String(path), _codes(regions, "Satellite regions"),
        _codes(industries, "Satellite industries"),
        _codes(indicators, "Satellite indicators"), String(source), schema, year,
    )
end

"""
    load_iot(adapter; drop_zeros=true)

Load a direct industry-by-industry IO table. It retains no product sales
structure because one is neither observed nor needed for a direct IO source.
"""
function load_iot(adapter::IOTAdapter; drop_zeros::Bool = true)
    schema = adapter.schema
    intermediate_source = _read_table(
        adapter.intermediate_path,
        [schema.supplier_region, schema.supplier_industry, schema.user_region, schema.user_industry, schema.value],
        schema.delimiter, "IO intermediate",
    )
    final_demand_source = _read_table(
        adapter.final_demand_path,
        [schema.supplier_region, schema.supplier_industry, schema.demand_region, schema.final_use, schema.value],
        schema.delimiter, "IO final demand",
    )
    output_source = _read_table(
        adapter.output_path,
        [schema.output_region, schema.output_industry, schema.value],
        schema.delimiter, "IO output",
    )
    intermediate = _iot_intermediate(intermediate_source, adapter; drop_zeros)
    final_demand = _iot_final_demand(final_demand_source, adapter; drop_zeros)
    industry_output = _iot_output(output_source, adapter; drop_zeros)
    _require_iot_coverage(industry_output, adapter)
    provenance = Dict(
        "source" => adapter.source,
        "intermediate_path" => abspath(adapter.intermediate_path),
        "final_demand_path" => abspath(adapter.final_demand_path),
        "output_path" => abspath(adapter.output_path),
        "valuation" => adapter.valuation,
    )
    adapter.year === nothing || (provenance["year"] = string(adapter.year))
    return MultiRegionIOT(
        regions = copy(adapter.regions),
        products = String[],
        industries = copy(adapter.industries),
        final_uses = copy(adapter.final_uses),
        sales_structure = _empty_sales_structure(),
        intermediate = intermediate,
        final_demand = final_demand,
        industry_output = industry_output,
        provenance = provenance,
    )
end

function load_iot(adapter::OECDICIOAdapter; drop_zeros::Bool = true)
    iot = load_iot(adapter.iot; drop_zeros)
    provenance = copy(iot.provenance)
    provenance["oecd_icio_edition"] = adapter.edition
    return MultiRegionIOT(
        regions = iot.regions,
        products = iot.products,
        industries = iot.industries,
        final_uses = iot.final_uses,
        sales_structure = iot.sales_structure,
        intermediate = iot.intermediate,
        final_demand = iot.final_demand,
        industry_output = iot.industry_output,
        provenance = provenance,
    )
end

function load_sut(adapter::EurostatNationalSUTAdapter; drop_zeros::Bool = true)
    schema = adapter.schema
    supply_source = _read_table(
        adapter.supply_path,
        [schema.product, schema.supply_activity, schema.value],
        schema.delimiter, "Eurostat national supply",
    )
    use_source = _read_table(
        adapter.use_path,
        [schema.product, schema.use_account, schema.value],
        schema.delimiter, "Eurostat national use",
    )
    products = Set(adapter.products)
    activities = Set(adapter.activities)
    accounts = union(activities, Set(adapter.final_uses))
    supply = _national_supply(supply_source, adapter, products, activities; drop_zeros)
    use = _national_use(use_source, adapter, products, accounts; drop_zeros)
    observed_products = Set(String.(supply.product))
    missing_products = sort!(collect(setdiff(products, observed_products)))
    isempty(missing_products) || error("Eurostat national supply table has no non-zero supply for selected products: $(join(missing_products, ", ")).")
    provenance = Dict(
        "source" => "Eurostat national supply and use tables",
        "supply_path" => abspath(adapter.supply_path),
        "use_path" => abspath(adapter.use_path),
        "region" => adapter.region,
        "valuation" => adapter.valuation,
    )
    adapter.year === nothing || (provenance["year"] = string(adapter.year))
    return MultiRegionSUT(
        regions = [adapter.region],
        products = copy(adapter.products),
        activities = copy(adapter.activities),
        final_uses = copy(adapter.final_uses),
        supply = supply,
        use = use,
        source_tables = Dict("supply" => supply_source, "use" => use_source),
        provenance = provenance,
    )
end

function load_satellite(adapter::SatelliteAdapter; drop_zeros::Bool = true)
    schema = adapter.schema
    source = _read_table(
        adapter.path,
        [schema.region, schema.industry, schema.indicator, schema.unit, schema.value],
        schema.delimiter, "Satellite",
    )
    regions = Set(adapter.regions)
    industries = Set(adapter.industries)
    indicators = Set(adapter.indicators)
    rows = NamedTuple[]
    for row in eachrow(source)
        region = _code(row[schema.region])
        industry = _code(row[schema.industry])
        indicator = _code(row[schema.indicator])
        region in regions || error("Satellite table contains undeclared region: $(region).")
        industry in industries || error("Satellite table contains undeclared industry: $(industry).")
        indicator in indicators || error("Satellite table contains undeclared indicator: $(indicator).")
        unit = _code(row[schema.unit])
        isempty(unit) && error("Satellite table contains an empty unit.")
        value = _value(row[schema.value], "Satellite")
        drop_zeros && iszero(value) && continue
        push!(rows, (region = region, industry = industry, indicator = indicator, unit = unit, value = value))
    end
    provenance = Dict("source" => adapter.source, "path" => abspath(adapter.path))
    adapter.year === nothing || (provenance["year"] = string(adapter.year))
    return SatelliteTable(
        regions = copy(adapter.regions),
        industries = copy(adapter.industries),
        indicators = copy(adapter.indicators),
        data = DataFrame(rows),
        provenance = provenance,
    )
end

function _iot_intermediate(source::DataFrame, adapter::IOTAdapter; drop_zeros::Bool)
    schema = adapter.schema
    regions = Set(adapter.regions)
    industries = Set(adapter.industries)
    rows = NamedTuple[]
    for row in eachrow(source)
        supplier_region = _code(row[schema.supplier_region])
        supplier_industry = _code(row[schema.supplier_industry])
        user_region = _code(row[schema.user_region])
        user_industry = _code(row[schema.user_industry])
        supplier_region in regions || error("IO intermediate table contains undeclared supplier region: $(supplier_region).")
        user_region in regions || error("IO intermediate table contains undeclared user region: $(user_region).")
        supplier_industry in industries || error("IO intermediate table contains undeclared supplier industry: $(supplier_industry).")
        user_industry in industries || error("IO intermediate table contains undeclared user industry: $(user_industry).")
        value = _value(row[schema.value], "IO intermediate")
        drop_zeros && iszero(value) && continue
        push!(rows, (supplier_region = supplier_region, supplier_industry = supplier_industry, user_region = user_region, user_industry = user_industry, value = value))
    end
    return DataFrame(rows)
end

function _iot_final_demand(source::DataFrame, adapter::IOTAdapter; drop_zeros::Bool)
    schema = adapter.schema
    regions = Set(adapter.regions)
    industries = Set(adapter.industries)
    final_uses = Set(adapter.final_uses)
    rows = NamedTuple[]
    for row in eachrow(source)
        supplier_region = _code(row[schema.supplier_region])
        supplier_industry = _code(row[schema.supplier_industry])
        demand_region = _code(row[schema.demand_region])
        final_use = _code(row[schema.final_use])
        supplier_region in regions || error("IO final-demand table contains undeclared supplier region: $(supplier_region).")
        demand_region in regions || error("IO final-demand table contains undeclared demand region: $(demand_region).")
        supplier_industry in industries || error("IO final-demand table contains undeclared supplier industry: $(supplier_industry).")
        final_use in final_uses || error("IO final-demand table contains undeclared final-use account: $(final_use).")
        value = _value(row[schema.value], "IO final demand")
        drop_zeros && iszero(value) && continue
        push!(rows, (supplier_region = supplier_region, supplier_industry = supplier_industry, demand_region = demand_region, final_use = final_use, value = value))
    end
    return DataFrame(rows)
end

function _iot_output(source::DataFrame, adapter::IOTAdapter; drop_zeros::Bool)
    schema = adapter.schema
    regions = Set(adapter.regions)
    industries = Set(adapter.industries)
    rows = NamedTuple[]
    for row in eachrow(source)
        region = _code(row[schema.output_region])
        industry = _code(row[schema.output_industry])
        region in regions || error("IO output table contains undeclared region: $(region).")
        industry in industries || error("IO output table contains undeclared industry: $(industry).")
        value = _value(row[schema.value], "IO output")
        drop_zeros && iszero(value) && continue
        push!(rows, (region = region, industry = industry, value = value))
    end
    return DataFrame(rows)
end

function _national_supply(source::DataFrame, adapter::EurostatNationalSUTAdapter, products::Set{String}, activities::Set{String}; drop_zeros::Bool)
    schema = adapter.schema
    rows = NamedTuple[]
    for row in eachrow(source)
        product = _code(row[schema.product])
        activity = _code(row[schema.supply_activity])
        product in products || error("Eurostat national supply table contains undeclared product: $(product).")
        activity in activities || error("Eurostat national supply table contains undeclared activity: $(activity).")
        value = _value(row[schema.value], "Eurostat national supply")
        drop_zeros && iszero(value) && continue
        push!(rows, (product_origin = adapter.region, product = product, activity_region = adapter.region, activity = activity, value = value))
    end
    return DataFrame(rows)
end

function _national_use(source::DataFrame, adapter::EurostatNationalSUTAdapter, products::Set{String}, accounts::Set{String}; drop_zeros::Bool)
    schema = adapter.schema
    rows = NamedTuple[]
    for row in eachrow(source)
        product = _code(row[schema.product])
        account = _code(row[schema.use_account])
        product in products || error("Eurostat national use table contains undeclared product: $(product).")
        account in accounts || error("Eurostat national use table contains undeclared account: $(account).")
        value = _value(row[schema.value], "Eurostat national use")
        drop_zeros && iszero(value) && continue
        push!(rows, (product_origin = adapter.region, product = product, use_region = adapter.region, use_account = account, value = value))
    end
    return DataFrame(rows)
end

function _require_iot_coverage(output::DataFrame, adapter::IOTAdapter)
    observed = Set((String(row.region), String(row.industry)) for row in eachrow(output))
    required = Set((region, industry) for region in adapter.regions for industry in adapter.industries)
    missing = sort!(collect(setdiff(required, observed)))
    isempty(missing) || error("IO output table has no row for declared region/industry pairs: $(join(["$(region)/$(industry)" for (region, industry) in missing], ", ")).")
    return nothing
end

function _read_table(path::String, required::Vector{Symbol}, delimiter::Char, name::String)
    isfile(path) || error("$(name) file not found: $(path)")
    table = DataFrame(CSV.File(path; delim = delimiter, normalizenames = false))
    available = Set(Symbol.(names(table)))
    missing = [String(column) for column in required if !(column in available)]
    isempty(missing) || error("$(name) file is missing required columns: $(join(missing, ", ")).")
    return table
end

function _empty_sales_structure()
    return DataFrame(
        product_origin = String[], product = String[], supplier_region = String[],
        supplier_industry = String[], supply_value = Float64[],
        product_output = Float64[], sales_share = Float64[],
    )
end

function _codes(values::AbstractVector{<:AbstractString}, name::String; allow_empty::Bool = false)
    codes = String.(_code.(values))
    allow_empty || isempty(codes) && error("Specify at least one $(name).")
    all(code -> !isempty(code), codes) || error("$(name) cannot contain empty codes.")
    length(unique(codes)) == length(codes) || error("$(name) must be unique.")
    return codes
end

function _metadata(value::AbstractString, name::String)
    isempty(strip(value)) && error("$(name) cannot be empty.")
    return nothing
end

function _code(value)
    ismissing(value) && error("Source code is missing.")
    return strip(string(value))
end

function _value(value, name::String)
    ismissing(value) && error("$(name) contains a missing value.")
    raw = value isa Number ? value : replace(strip(string(value)), "," => "")
    parsed = raw isa Number ? Float64(raw) : tryparse(Float64, raw)
    isnothing(parsed) && error("$(name) contains a non-numeric value: $(value)")
    isfinite(parsed) || error("$(name) contains a non-finite value.")
    return parsed
end

function _eurostat_national_url(dataset::String, release::EurostatNationalSUTRelease)
    return _eurostat_statistics_url(
        dataset,
        ["geo" => release.region, "time" => string(release.reference_year), "unit" => release.unit],
    )
end

function _eurostat_national_account_selections(
    release::EurostatNationalAccountsRelease,
    selections::AbstractDict,
)
    selected = Dict{String, Vector{String}}()
    for (dimension, values) in selections
        dimension isa AbstractString || error("Eurostat national-accounts selection dimensions must be strings.")
        values isa AbstractVector || error("Eurostat national-accounts selection for $(dimension) must be a vector of source codes.")
        all(value -> value isa AbstractString, values) || error("Eurostat national-accounts selection for $(dimension) must contain source-code strings.")
        selected[String(dimension)] = _codes(String.(values), "Eurostat national-accounts selection $(dimension)")
    end
    Set(keys(selected)) == Set(release.dimensions) || error(
        "Eurostat national-accounts selections must specify exactly: $(join(release.dimensions, ", ")).",
    )
    return selected
end

function _eurostat_national_accounts_rows(
    observations::DataFrame,
    release::EurostatNationalAccountsRelease,
    region::String,
    selections::Dict{String, Vector{String}},
    output_names::Tuple,
)
    required = [release.region_dimension, "unit", release.dimensions..., collect(keys(release.filters))...]
    missing = filter(dimension -> !(Symbol(dimension) in propertynames(observations)), required)
    isempty(missing) || error("Eurostat national-accounts response has no required dimensions: $(join(missing, ", ")).")
    rows = NamedTuple[]
    for observation in eachrow(observations)
        String(observation[Symbol(release.region_dimension)]) == region || continue
        String(observation[:unit]) == release.unit || continue
        all(String(observation[Symbol(dimension)]) == value for (dimension, value) in release.filters) || continue
        all(String(observation[Symbol(dimension)]) in selections[dimension] for dimension in release.dimensions) || continue
        values = (
            region,
            (String(observation[Symbol(dimension)]) for dimension in release.dimensions)...,
            release.unit,
            _value(observation[:value], "Eurostat national accounts"),
        )
        push!(rows, NamedTuple{output_names}(values))
    end
    return rows
end

function _eurostat_national_accounts_url(
    release::EurostatNationalAccountsRelease,
    region::String,
    selections::Dict{String, Vector{String}},
)
    filters = Pair{String, String}[
        release.region_dimension => region,
        "time" => string(release.reference_year),
        "unit" => release.unit,
    ]
    append!(filters, collect(release.filters))
    for dimension in release.dimensions
        append!(filters, [dimension => code for code in selections[dimension]])
    end
    return _eurostat_statistics_url(release.dataset, filters)
end

function _eurostat_satellite_url(release::EurostatSatelliteRelease, region::String)
    filters = Pair{String, String}[
        release.region_dimension => region,
        "time" => string(release.reference_year),
        "unit" => release.unit,
    ]
    append!(filters, collect(release.filters))
    return _eurostat_statistics_url(release.dataset, filters)
end

function _eurostat_statistics_url(dataset::String, filters::AbstractVector{<:Pair{String, String}})
    query = join(["$(dimension)=$(value)" for (dimension, value) in filters], "&")
    return "$(EUROSTAT_STATISTICS_API)/$(dataset)?$(query)"
end

function _eurostat_jsonstat_table(path::String)
    payload = JSON3.read(read(path, String))
    haskey(payload, "id") || error("Eurostat response at $(path) has no dimension identifiers.")
    haskey(payload, "size") || error("Eurostat response at $(path) has no dimension sizes.")
    haskey(payload, "dimension") || error("Eurostat response at $(path) has no dimension metadata.")
    haskey(payload, "value") || error("Eurostat response at $(path) has no observations.")
    ids = String.(payload["id"])
    sizes = Int.(payload["size"])
    length(ids) == length(sizes) || error("Eurostat response at $(path) has inconsistent dimensions.")
    length(unique(ids)) == length(ids) || error("Eurostat response at $(path) has duplicate dimension identifiers.")
    codes = Dict{String, Vector{String}}()
    for (dimension, size) in zip(ids, sizes)
        metadata = payload["dimension"][dimension]
        haskey(metadata, "category") || error("Eurostat response at $(path) has no category metadata for $(dimension).")
        index = metadata["category"]["index"]
        values = fill("", size)
        for (code, position) in pairs(index)
            position_int = Int(position) + 1
            1 <= position_int <= size || error("Eurostat response at $(path) has an invalid category index for $(dimension).")
            values[position_int] = String(code)
        end
        all(value -> !isempty(value), values) || error("Eurostat response at $(path) has incomplete category indices for $(dimension).")
        codes[dimension] = values
    end
    table = DataFrame()
    for dimension in ids
        table[!, Symbol(dimension)] = String[]
    end
    table[!, :value] = Float64[]
    for (flat, observed_value) in pairs(payload["value"])
        isnothing(observed_value) && continue
        position = tryparse(Int, String(flat))
        isnothing(position) && error("Eurostat response at $(path) has a non-integer observation index: $(flat)")
        dimensions = _jsonstat_observation(ids, sizes, codes, position)
        for dimension in ids
            push!(table[!, Symbol(dimension)], dimensions[dimension])
        end
        push!(table[!, :value], _value(observed_value, "Eurostat"))
    end
    return table
end

function _eurostat_jsonstat_rows(
    path::String;
    product_dimension::String,
    account_dimension::String,
    products::Set{String},
    accounts::Set{String},
    account_name::Symbol,
)
    observations = _eurostat_jsonstat_table(path)
    product_column = Symbol(product_dimension)
    account_column = Symbol(account_dimension)
    product_column in propertynames(observations) || error("Eurostat response at $(path) has no $(product_dimension) dimension.")
    account_column in propertynames(observations) || error("Eurostat response at $(path) has no $(account_dimension) dimension.")
    rows = NamedTuple[]
    for observation in eachrow(observations)
        :stk_flow in propertynames(observations) && String(observation[:stk_flow]) != "TOTAL" && continue
        product = String(observation[product_column])
        account = String(observation[account_column])
        product in products || continue
        account in accounts || continue
        value = _value(observation[:value], "Eurostat")
        iszero(value) && continue
        if account_name === :activity
            push!(rows, (product = product, activity = account, value = value))
        elseif account_name === :account
            push!(rows, (product = product, account = account, value = value))
        else
            error("Unsupported Eurostat account output name: $(account_name).")
        end
    end
    return DataFrame(rows)
end

function _jsonstat_observation(
    ids::Vector{String},
    sizes::Vector{Int},
    codes::Dict{String, Vector{String}},
    flat_index::Int,
)
    flat_index >= 0 || error("Eurostat observation indices cannot be negative.")
    remainder = flat_index
    positions = Vector{Int}(undef, length(ids))
    # Eurostat JSON-stat observation indices make the final declared
    # dimension vary fastest. Decode the sparse flat index in reverse order.
    for index in reverse(eachindex(ids))
        positions[index] = mod(remainder, sizes[index]) + 1
        remainder = fld(remainder, sizes[index])
    end
    remainder == 0 || error("Eurostat observation index $(flat_index) exceeds declared dimensions.")
    return Dict(ids[index] => codes[ids[index]][positions[index]] for index in eachindex(ids))
end

function _verify_zip_archive(path::String, name::String)
    isfile(path) || error("$(name) not found: $(path)")
    reader = try
        ZipFile.Reader(path)
    catch exception
        error("$(name) is not a readable ZIP archive: $(sprint(showerror, exception))")
    end
    try
        isempty(reader.files) && error("$(name) contains no files.")
    finally
        close(reader)
    end
    return nothing
end

function _oecd_icio_archive_matrix(archive_path::String, reference_year::Int)
    reader = ZipFile.Reader(archive_path)
    try
        year_pattern = Regex("(?<!\\d)$(reference_year)(?!\\d)")
        candidates = filter(reader.files) do file
            filename = basename(file.name)
            endswith(lowercase(filename), ".csv") && occursin(year_pattern, filename)
        end
        length(candidates) == 1 || error(
            "Expected exactly one OECD ICIO CSV member for $(reference_year), found $(length(candidates)): $(join([file.name for file in candidates], ", ")).",
        )
        member = only(candidates)
        source = CSV.read(IOBuffer(read(member)), DataFrame; normalizenames = false)
        ncol(source) >= 2 || error("OECD ICIO source member $(member.name) has no matrix columns.")
        nrow(source) >= 2 || error("OECD ICIO source member $(member.name) has no matrix rows.")
        return (member.name, source)
    finally
        close(reader)
    end
end

function _oecd_icio_long_tables(
    source::DataFrame,
    regions::Vector{String},
    industries::Vector{String},
    final_uses::Vector{String},
)
    row_column = first(names(source))
    row_labels = String.(_code.(source[!, row_column]))
    row_index = Dict{String, Int}()
    for (index, label) in enumerate(row_labels)
        haskey(row_index, label) && error("OECD ICIO source contains duplicate row label: $(label)")
        row_index[label] = index
    end
    column_index = Dict{String, String}()
    for column in names(source)[2:end]
        label = String(column)
        haskey(column_index, label) && error("OECD ICIO source contains duplicate column label: $(label)")
        column_index[label] = column
    end

    industry_labels = [(region, industry, "$(region)_$(industry)") for region in regions for industry in industries]
    missing_rows = [label for (_, _, label) in industry_labels if !haskey(row_index, label)]
    missing_columns = [label for (_, _, label) in industry_labels if !haskey(column_index, label)]
    isempty(missing_rows) || error("OECD ICIO source is missing selected industry rows: $(join(missing_rows, ", ")).")
    isempty(missing_columns) || error("OECD ICIO source is missing selected industry columns: $(join(missing_columns, ", ")).")

    intermediate = DataFrame(
        supplier_region = String[], supplier_industry = String[],
        user_region = String[], user_industry = String[], value = Float64[],
    )
    for (supplier_region, supplier_industry, supplier_label) in industry_labels
        source_row = row_index[supplier_label]
        for (user_region, user_industry, user_label) in industry_labels
            push!(intermediate, (
                supplier_region = supplier_region,
                supplier_industry = supplier_industry,
                user_region = user_region,
                user_industry = user_industry,
                value = _value(source[source_row, column_index[user_label]], "OECD ICIO intermediate cell"),
            ))
        end
    end

    final_demand = DataFrame(
        supplier_region = String[], supplier_industry = String[],
        demand_region = String[], final_use = String[], value = Float64[],
    )
    final_labels = [(region, final_use, "$(region)_$(final_use)") for region in regions for final_use in final_uses]
    missing_final_columns = [label for (_, _, label) in final_labels if !haskey(column_index, label)]
    isempty(missing_final_columns) || error("OECD ICIO source is missing selected final-demand columns: $(join(missing_final_columns, ", ")).")
    for (supplier_region, supplier_industry, supplier_label) in industry_labels
        source_row = row_index[supplier_label]
        for (demand_region, final_use, final_label) in final_labels
            push!(final_demand, (
                supplier_region = supplier_region,
                supplier_industry = supplier_industry,
                demand_region = demand_region,
                final_use = final_use,
                value = _value(source[source_row, column_index[final_label]], "OECD ICIO final-demand cell"),
            ))
        end
    end

    output_label = if haskey(row_index, "OUTPUT")
        "OUTPUT"
    elseif haskey(row_index, "OUT")
        "OUT"
    else
        error("OECD ICIO source has no OUTPUT row for gross output.")
    end
    output_row = row_index[output_label]
    output = DataFrame(region = String[], industry = String[], value = Float64[])
    for (region, industry, label) in industry_labels
        push!(output, (
            region = region,
            industry = industry,
            value = _value(source[output_row, column_index[label]], "OECD ICIO gross-output cell"),
        ))
    end
    return intermediate, final_demand, output
end

function _official_url(value::AbstractString, suffix::String, name::String)
    url = strip(String(value))
    startswith(url, "https://") || error("$(name) must use HTTPS.")
    host = split(split(url, "://"; limit = 2)[2], '/'; limit = 2)[1]
    (host == suffix || endswith(host, ".$(suffix)")) || error("$(name) must point to an official $(suffix) host.")
    return nothing
end

function _identifier(value::AbstractString, name::String)
    code = strip(String(value))
    occursin(r"^[A-Za-z0-9_-]+$", code) || error("$(name) must contain only letters, digits, underscores, and hyphens.")
    return nothing
end

end # module
