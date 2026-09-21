"""
JCGEImportData provides IO/SAM helpers to normalize external data sources into
the canonical CSV schema used by JCGECalibrate.
"""
module JCGEImportData

using CSV
using DataFrames

export IOBundle
export LabeledMatrix
export MultiRegionSUT
export MultiRegionIOT
export SatelliteTable
export EurostatAdapter
export BEAAdapter
export IOTAdapter
export OECDICIOAdapter
export EurostatNationalSUTAdapter
export SatelliteAdapter
export FIGAROFlatSchema
export BEAFlatSchema
export IOTFlatSchema
export NationalSUTFlatSchema
export SatelliteFlatSchema
export OECDICIORelease
export download_oecd_icio
export normalize_oecd_icio
export EurostatNationalSUTRelease
export download_eurostat_national_sut
export EurostatSatelliteRelease
export download_eurostat_satellite
export EurostatNationalAccountsRelease
export download_eurostat_national_accounts
export FIGARORelease
export download_figaro
export BEARelease
export download_bea
export BEANationalAccountsRelease
export download_bea_national_accounts
export load_iobundle
export load_sut
export load_iot
export load_satellite
export check_sam_balance
export check_io_balance
export check_sut_balance
export check_iot_balance
export symmetric_io_model_d
export labeled_matrix_from_dataframe
export sam_from_io
export sets_from_bundle
export to_dataframe
export write_canonical_dataset

"""
Default tax account labels used when none are provided.
"""
const DEFAULT_TAX_ACCOUNTS = ["TAX"]

"""
Default external account labels used when none are provided.
"""
const DEFAULT_EXT_ACCOUNTS = ["EXT"]

"""
    LabeledMatrix(row_labels, col_labels, values)

Matrix wrapper with explicit row/column labels.
"""
struct LabeledMatrix
    row_labels::Vector{String}
    col_labels::Vector{String}
    values::Matrix{Float64}
end

"""
    LabeledMatrix(row_labels, col_labels, values)

Construct a labeled matrix with size checks and float conversion.
"""
function LabeledMatrix(row_labels::Vector{String}, col_labels::Vector{String}, values::AbstractMatrix)
    if size(values, 1) != length(row_labels) || size(values, 2) != length(col_labels)
        error("LabeledMatrix size mismatch: expected $(length(row_labels))x$(length(col_labels)), got $(size(values, 1))x$(size(values, 2)).")
    end
    return LabeledMatrix(row_labels, col_labels, Matrix{Float64}(values))
end

"""
    labeled_matrix_from_dataframe(df; row_label_col="label")

Build a `LabeledMatrix` from a DataFrame whose first column is a row label.
"""
function labeled_matrix_from_dataframe(df::DataFrame; row_label_col::AbstractString = "label")
    if !(row_label_col in names(df))
        error("Row label column '$row_label_col' not found in DataFrame.")
    end
    row_labels = string.(df[:, row_label_col])
    col_names = filter(n -> n != row_label_col, names(df))
    col_labels = string.(col_names)
    values = Matrix{Float64}(df[:, col_names])
    return LabeledMatrix(row_labels, col_labels, values)
end

"""
    to_dataframe(mat; row_label_col="label")

Convert a `LabeledMatrix` to a DataFrame with a label column.
"""
function to_dataframe(mat::LabeledMatrix; row_label_col::AbstractString = "label")
    df = DataFrame()
    df[!, row_label_col] = mat.row_labels
    for (idx, col) in enumerate(mat.col_labels)
        df[!, col] = mat.values[:, idx]
    end
    return df
end

"""
    IOBundle

Container for IO tables and account labels used to construct a SAM.
"""
struct IOBundle
    goods::Vector{String}
    activities::Vector{String}
    factors::Vector{String}
    institutions::Vector{String}
    tax_accounts::Vector{String}
    ext_accounts::Vector{String}
    use::LabeledMatrix
    supply::LabeledMatrix
    value_added::LabeledMatrix
    final_demand::LabeledMatrix
    taxes::Union{LabeledMatrix, Nothing}
    imports::Union{LabeledMatrix, Nothing}
    exports::Union{LabeledMatrix, Nothing}
    factor_income::Union{LabeledMatrix, Nothing}
end

"""
    MultiRegionSUT

Source-neutral representation of a multi-region supply-use table. `supply`
contains `product_origin`, `product`, `activity_region`, `activity`, and
`value`; `use` contains `product_origin`, `product`, `use_region`,
`use_account`, and `value`.

This represents data only. It does not choose a symmetric IO transformation,
regional aggregation, institutional closure, or model specification.
"""
struct MultiRegionSUT
    regions::Vector{String}
    products::Vector{String}
    activities::Vector{String}
    final_uses::Vector{String}
    supply::DataFrame
    use::DataFrame
    source_tables::Dict{String, DataFrame}
    provenance::Dict{String, String}
end

"""
    MultiRegionIOT

Source-neutral sparse, multi-region, industry-by-industry IO representation.
`sales_structure` records the Model-D allocation of each product to its
producing industries; `intermediate` and `final_demand` record the resulting
industry sales. For a source table that is already industry-by-industry,
`products` and `sales_structure` are empty. It does not impose factor,
institution, tax, or closure accounts.
"""
struct MultiRegionIOT
    regions::Vector{String}
    products::Vector{String}
    industries::Vector{String}
    final_uses::Vector{String}
    sales_structure::DataFrame
    intermediate::DataFrame
    final_demand::DataFrame
    industry_output::DataFrame
    provenance::Dict{String, String}
end

"""
    SatelliteTable(; regions, industries, indicators, data, provenance=Dict())

Source-neutral satellite observations keyed by region, industry, and indicator.
Each observation carries its source unit, so physical, environmental, and
socioeconomic quantities remain separate from monetary IO tables.
"""
struct SatelliteTable
    regions::Vector{String}
    industries::Vector{String}
    indicators::Vector{String}
    data::DataFrame
    provenance::Dict{String, String}
end

function SatelliteTable(
    ;
    regions::Vector{String},
    industries::Vector{String},
    indicators::Vector{String},
    data::DataFrame,
    provenance::Dict{String, String} = Dict{String, String}(),
)
    length(unique(regions)) == length(regions) || error("Satellite regions must be unique.")
    length(unique(industries)) == length(industries) || error("Satellite industries must be unique.")
    length(unique(indicators)) == length(indicators) || error("Satellite indicators must be unique.")
    required = ["region", "industry", "indicator", "unit", "value"]
    missing = setdiff(required, string.(names(data)))
    isempty(missing) || error("Satellite data is missing required columns: $(join(missing, ", ")).")
    normalized = DataFrame(
        region = string.(data[!, "region"]),
        industry = string.(data[!, "industry"]),
        indicator = string.(data[!, "indicator"]),
        unit = string.(data[!, "unit"]),
        value = Float64.(data[!, "value"]),
    )
    all(isfinite, normalized.value) || error("Satellite values must be finite.")
    all(in(Set(regions)), normalized.region) || error("Satellite regions must be declared.")
    all(in(Set(industries)), normalized.industry) || error("Satellite industries must be declared.")
    all(in(Set(indicators)), normalized.indicator) || error("Satellite indicators must be declared.")
    all(unit -> !isempty(strip(unit)), normalized.unit) || error("Satellite units cannot be empty.")
    return SatelliteTable(regions, industries, indicators, normalized, provenance)
end

"""
    MultiRegionIOT(; regions, products, industries, final_uses,
                   sales_structure, intermediate, final_demand, industry_output,
                   provenance=Dict())

Create and validate a normalized multi-region industry-by-industry IO table.
"""
function MultiRegionIOT(
    ;
    regions::Vector{String},
    products::Vector{String},
    industries::Vector{String},
    final_uses::Vector{String},
    sales_structure::DataFrame,
    intermediate::DataFrame,
    final_demand::DataFrame,
    industry_output::DataFrame,
    provenance::Dict{String, String} = Dict{String, String}(),
)
    length(unique(regions)) == length(regions) || error("Region labels must be unique.")
    length(unique(products)) == length(products) || error("Product labels must be unique.")
    length(unique(industries)) == length(industries) || error("Industry labels must be unique.")
    length(unique(final_uses)) == length(final_uses) || error("Final-use labels must be unique.")
    required = Dict(
        "sales_structure" => ["product_origin", "product", "supplier_region", "supplier_industry", "supply_value", "product_output", "sales_share"],
        "intermediate" => ["supplier_region", "supplier_industry", "user_region", "user_industry", "value"],
        "final_demand" => ["supplier_region", "supplier_industry", "demand_region", "final_use", "value"],
        "industry_output" => ["region", "industry", "value"],
    )
    tables = Dict(
        "sales_structure" => sales_structure,
        "intermediate" => intermediate,
        "final_demand" => final_demand,
        "industry_output" => industry_output,
    )
    for (name, columns) in required
        missing = setdiff(columns, string.(names(tables[name])))
        isempty(missing) || error("$(name) is missing required columns: $(join(missing, ", ")).")
    end
    for name in ("intermediate", "final_demand", "industry_output")
        table = tables[name]
        values = Float64.(table[!, "value"])
        all(isfinite, values) || error("$(name) values must be finite.")
    end
    for column in ("supply_value", "product_output", "sales_share")
        values = Float64.(sales_structure[!, column])
        all(isfinite, values) || error("sales_structure $(column) values must be finite.")
    end
    return MultiRegionIOT(
        regions,
        products,
        industries,
        final_uses,
        DataFrame(sales_structure),
        DataFrame(intermediate),
        DataFrame(final_demand),
        DataFrame(industry_output),
        provenance,
    )
end

"""
    MultiRegionSUT(; regions, products, activities, final_uses, supply, use,
                   source_tables=Dict(), provenance=Dict())

Create a normalized multi-region SUT and validate its required columns and
account labels.
"""
function MultiRegionSUT(
    ;
    regions::Vector{String},
    products::Vector{String},
    activities::Vector{String},
    final_uses::Vector{String},
    supply::DataFrame,
    use::DataFrame,
    source_tables::Dict{String, DataFrame} = Dict{String, DataFrame}(),
    provenance::Dict{String, String} = Dict{String, String}(),
)
    length(unique(regions)) == length(regions) || error("Region labels must be unique.")
    length(unique(products)) == length(products) || error("Product labels must be unique.")
    length(unique(activities)) == length(activities) || error("Activity labels must be unique.")
    length(unique(final_uses)) == length(final_uses) || error("Final-use labels must be unique.")
    supply_columns = ["product_origin", "product", "activity_region", "activity", "value"]
    use_columns = ["product_origin", "product", "use_region", "use_account", "value"]
    missing_supply = setdiff(supply_columns, string.(names(supply)))
    missing_use = setdiff(use_columns, string.(names(use)))
    isempty(missing_supply) || error("Supply table is missing required columns: $(join(missing_supply, ", ")).")
    isempty(missing_use) || error("Use table is missing required columns: $(join(missing_use, ", ")).")

    normalized_supply = DataFrame(
        product_origin = string.(supply[!, "product_origin"]),
        product = string.(supply[!, "product"]),
        activity_region = string.(supply[!, "activity_region"]),
        activity = string.(supply[!, "activity"]),
        value = Float64.(supply[!, "value"]),
    )
    normalized_use = DataFrame(
        product_origin = string.(use[!, "product_origin"]),
        product = string.(use[!, "product"]),
        use_region = string.(use[!, "use_region"]),
        use_account = string.(use[!, "use_account"]),
        value = Float64.(use[!, "value"]),
    )
    all(isfinite, normalized_supply.value) || error("Supply values must be finite.")
    all(isfinite, normalized_use.value) || error("Use values must be finite.")
    region_set = Set(regions)
    product_set = Set(products)
    activity_set = Set(activities)
    account_set = union(activity_set, Set(final_uses))
    all(in(region_set), normalized_supply.product_origin) || error("Supply product origins must be declared regions.")
    all(in(region_set), normalized_supply.activity_region) || error("Supply activity regions must be declared regions.")
    all(in(region_set), normalized_use.product_origin) || error("Use product origins must be declared regions.")
    all(in(region_set), normalized_use.use_region) || error("Use regions must be declared regions.")
    all(in(product_set), normalized_supply.product) || error("Supply products must be declared products.")
    all(in(product_set), normalized_use.product) || error("Use products must be declared products.")
    all(in(activity_set), normalized_supply.activity) || error("Supply activities must be declared activities.")
    all(in(account_set), normalized_use.use_account) || error("Use accounts must be activities or final-use accounts.")
    return MultiRegionSUT(regions, products, activities, final_uses, normalized_supply, normalized_use, source_tables, provenance)
end


"""
    IOBundle(; goods, activities, factors, institutions, tax_accounts, ext_accounts,
             use, supply, value_added, final_demand, taxes=nothing, imports=nothing,
             exports=nothing, factor_income=nothing)

Create an IO bundle with label validation across tables.
"""
function IOBundle(;
    goods::Vector{String},
    activities::Vector{String},
    factors::Vector{String},
    institutions::Vector{String},
    tax_accounts::Vector{String} = String[],
    ext_accounts::Vector{String} = String[],
    use::LabeledMatrix,
    supply::LabeledMatrix,
    value_added::LabeledMatrix,
    final_demand::LabeledMatrix,
    taxes::Union{LabeledMatrix, Nothing} = nothing,
    imports::Union{LabeledMatrix, Nothing} = nothing,
    exports::Union{LabeledMatrix, Nothing} = nothing,
    factor_income::Union{LabeledMatrix, Nothing} = nothing,
)
    tax_accounts = isempty(tax_accounts) ? copy(DEFAULT_TAX_ACCOUNTS) : tax_accounts
    ext_accounts = isempty(ext_accounts) ? copy(DEFAULT_EXT_ACCOUNTS) : ext_accounts
    _assert_labels(use, goods, activities, "use")
    _assert_labels(supply, activities, goods, "supply")
    _assert_labels(value_added, factors, activities, "value_added")
    _assert_labels(final_demand, goods, institutions, "final_demand")
    if taxes !== nothing
        _assert_subset_labels(taxes.row_labels, tax_accounts, "taxes rows")
        _assert_subset_labels(taxes.col_labels, _all_accounts(goods, activities, factors, institutions, tax_accounts, ext_accounts), "taxes columns")
    end
    if imports !== nothing
        _assert_labels(imports, goods, ext_accounts, "imports")
    end
    if exports !== nothing
        _assert_labels(exports, goods, ext_accounts, "exports")
    end
    if factor_income !== nothing
        _assert_labels(factor_income, institutions, factors, "factor_income")
    end
    return IOBundle(
        goods,
        activities,
        factors,
        institutions,
        tax_accounts,
        ext_accounts,
        use,
        supply,
        value_added,
        final_demand,
        taxes,
        imports,
        exports,
        factor_income,
    )
end

"""
    sam_from_io(bundle)

Assemble a SAM DataFrame from an IO bundle.
"""
function sam_from_io(bundle::IOBundle)
    accounts = _all_accounts(
        bundle.goods,
        bundle.activities,
        bundle.factors,
        bundle.institutions,
        bundle.tax_accounts,
        bundle.ext_accounts,
    )
    index = Dict{String, Int}()
    for (i, name) in enumerate(accounts)
        index[name] = i
    end
    sam = zeros(Float64, length(accounts), length(accounts))

    _add_block!(sam, index, bundle.use)
    _add_block!(sam, index, bundle.supply)
    _add_block!(sam, index, bundle.value_added)
    _add_block!(sam, index, bundle.final_demand)

    if bundle.taxes !== nothing
        _add_block!(sam, index, bundle.taxes)
    end
    if bundle.exports !== nothing
        _add_block!(sam, index, bundle.exports; row_accounts = bundle.goods, col_accounts = bundle.ext_accounts)
    end
    if bundle.imports !== nothing
        _add_block!(sam, index, bundle.imports; row_accounts = bundle.ext_accounts, col_accounts = bundle.goods, transpose = true)
    end
    _apply_factor_income!(sam, index, bundle)

    df = DataFrame()
    df[!, "label"] = accounts
    for (i, col) in enumerate(accounts)
        df[!, col] = sam[:, i]
    end
    return df
end

"""
    sets_from_bundle(bundle)

Create a `sets.csv` DataFrame from bundle labels.
"""
function sets_from_bundle(bundle::IOBundle)
    set_names = String[]
    items = String[]
    _append_set!(set_names, items, "goods", bundle.goods)
    _append_set!(set_names, items, "activities", bundle.activities)
    _append_set!(set_names, items, "factors", bundle.factors)
    _append_set!(set_names, items, "institutions", bundle.institutions)
    _append_set!(set_names, items, "taxes", bundle.tax_accounts)
    _append_set!(set_names, items, "externals", bundle.ext_accounts)
    return DataFrame(set = set_names, item = items)
end

"""
    write_canonical_dataset(dir, bundle; sam=nothing, sets=nothing, subsets=nothing,
                             labels=nothing, mappings=nothing, params=nothing)

Write the canonical CSV dataset to `dir`.
"""
function write_canonical_dataset(
    dir::AbstractString,
    bundle::IOBundle;
    sam::Union{DataFrame, Nothing} = nothing,
    sets::Union{DataFrame, Nothing} = nothing,
    subsets::Union{DataFrame, Nothing} = nothing,
    labels::Union{DataFrame, Nothing} = nothing,
    mappings::Union{DataFrame, Nothing} = nothing,
    params::Union{DataFrame, Nothing} = nothing,
)
    mkpath(dir)
    if sam === nothing
        sam = sam_from_io(bundle)
    end
    if sets === nothing
        sets = sets_from_bundle(bundle)
    end
    CSV.write(joinpath(dir, "sam.csv"), sam)
    CSV.write(joinpath(dir, "sets.csv"), sets)
    if subsets !== nothing
        CSV.write(joinpath(dir, "subsets.csv"), subsets)
    end
    if labels !== nothing
        CSV.write(joinpath(dir, "labels.csv"), labels)
    end
    if mappings !== nothing
        CSV.write(joinpath(dir, "mappings.csv"), mappings)
    end
    if params !== nothing
        CSV.write(joinpath(dir, "params.csv"), params)
    end
    return nothing
end

"""
    check_sam_balance(sam; atol=1e-6)

Check row/column balance for a SAM DataFrame and report imbalances.
"""
function check_sam_balance(sam::DataFrame; atol::Float64 = 1e-6)
    labels = sam.label
    cols = names(sam)[2:end]
    row_totals = Vector{Float64}(undef, length(labels))
    col_totals = Vector{Float64}(undef, length(cols))
    for (idx, label) in enumerate(labels)
        row_totals[idx] = sum(skipmissing(sam[idx, 2:end]))
    end
    for (idx, col) in enumerate(cols)
        col_totals[idx] = sum(skipmissing(sam[:, col]))
    end
    imbalance = row_totals .- col_totals
    return DataFrame(
        account = string.(labels),
        row_total = row_totals,
        col_total = col_totals,
        imbalance = imbalance,
        balanced = abs.(imbalance) .<= atol,
    )
end

"""
    check_io_balance(bundle; atol=1e-6)

Check IO balance for goods and activities based on a bundle.
"""
function check_io_balance(bundle::IOBundle; atol::Float64 = 1e-6)
    goods = bundle.goods
    activities = bundle.activities
    ext = bundle.ext_accounts
    supply = bundle.supply.values
    use = bundle.use.values
    final = bundle.final_demand.values
    exports = bundle.exports === nothing ? zeros(length(goods), length(ext)) : bundle.exports.values
    imports = bundle.imports === nothing ? zeros(length(goods), length(ext)) : bundle.imports.values

    output_by_good = vec(sum(supply; dims = 1))
    use_by_good = vec(sum(use; dims = 2))
    final_by_good = vec(sum(final; dims = 2))
    export_by_good = vec(sum(exports; dims = 2))
    import_by_good = vec(sum(imports; dims = 2))

    supply_imb = output_by_good .- (use_by_good .+ final_by_good .+ export_by_good .- import_by_good)
    supply_df = DataFrame(
        good = goods,
        output = output_by_good,
        use = use_by_good,
        final = final_by_good,
        exports = export_by_good,
        imports = import_by_good,
        imbalance = supply_imb,
        balanced = abs.(supply_imb) .<= atol,
    )

    output_by_act = vec(sum(supply; dims = 2))
    int_by_act = vec(sum(use; dims = 1))
    va_by_act = vec(sum(bundle.value_added.values; dims = 1))
    activity_imb = output_by_act .- (int_by_act .+ va_by_act)
    activity_df = DataFrame(
        activity = activities,
        output = output_by_act,
        intermediate = int_by_act,
        value_added = va_by_act,
        imbalance = activity_imb,
        balanced = abs.(activity_imb) .<= atol,
    )

    return (goods = supply_df, activities = activity_df)
end

"""
    check_sut_balance(sut; atol=1e-6)

Report global supply and use totals for each product in a `MultiRegionSUT`.
The check is descriptive: it does not alter the source data.
"""
function check_sut_balance(sut::MultiRegionSUT; atol::Float64 = 1e-6)
    rows = NamedTuple[]
    for product in sut.products
        supply = sum(row.value for row in eachrow(sut.supply) if row.product == product)
        use = sum(row.value for row in eachrow(sut.use) if row.product == product)
        push!(rows, (
            product = product,
            supply = supply,
            use = use,
            imbalance = supply - use,
            balanced = abs(supply - use) <= atol,
        ))
    end
    return DataFrame(rows)
end

include("Transformations.jl")
using .Transformations

"""
    _assert_labels(mat, rows, cols, name)

Internal: ensure labeled matrix rows/cols match expected ordering.
"""
function _assert_labels(mat::LabeledMatrix, rows::Vector{String}, cols::Vector{String}, name::AbstractString)
    if mat.row_labels != rows
        error("Row labels for $name do not match expected order.")
    end
    if mat.col_labels != cols
        error("Column labels for $name do not match expected order.")
    end
    return nothing
end

"""
    _assert_subset_labels(labels, universe, name)

Internal: ensure labels are a subset of a known universe.
"""
function _assert_subset_labels(labels::Vector{String}, universe::Vector{String}, name::AbstractString)
    for label in labels
        if !(label in universe)
            error("Label '$label' in $name is not present in the account list.")
        end
    end
    return nothing
end

"""
    _all_accounts(goods, activities, factors, institutions, tax_accounts, ext_accounts)

Internal: build the ordered list of SAM accounts.
"""
function _all_accounts(goods, activities, factors, institutions, tax_accounts, ext_accounts)
    return vcat(goods, activities, factors, institutions, tax_accounts, ext_accounts)
end

"""
    _add_block!(sam, index, mat; row_accounts=nothing, col_accounts=nothing, transpose=false)

Internal: add a labeled matrix into the SAM by account index.
"""
function _add_block!(
    sam::Matrix{Float64},
    index::Dict{String, Int},
    mat::LabeledMatrix;
    row_accounts::Union{Vector{String}, Nothing} = nothing,
    col_accounts::Union{Vector{String}, Nothing} = nothing,
    transpose::Bool = false,
)
    rows = row_accounts === nothing ? mat.row_labels : row_accounts
    cols = col_accounts === nothing ? mat.col_labels : col_accounts
    for (r_idx, r) in enumerate(rows)
        for (c_idx, c) in enumerate(cols)
            row_key = rows[r_idx]
            col_key = cols[c_idx]
            val = transpose ? mat.values[c_idx, r_idx] : mat.values[r_idx, c_idx]
            sam[index[row_key], index[col_key]] += val
        end
    end
    return nothing
end

"""
    _apply_factor_income!(sam, index, bundle)

Internal: inject factor income flows into the SAM, using a default institution
when explicit factor income is not provided.
"""
function _apply_factor_income!(sam::Matrix{Float64}, index::Dict{String, Int}, bundle::IOBundle)
    factor_income = bundle.factor_income
    if factor_income !== nothing
        _add_block!(sam, index, factor_income)
        return nothing
    end
    if isempty(bundle.institutions) || isempty(bundle.factors)
        return nothing
    end
    default_inst = bundle.institutions[1]
    for (f_idx, factor) in enumerate(bundle.factors)
        total_income = sum(bundle.value_added.values[f_idx, :])
        sam[index[default_inst], index[factor]] += total_income
    end
    return nothing
end

"""
    _append_set!(set_names, items, set_name, entries)

Internal: append a set name and its items to the flat sets table.
"""
function _append_set!(set_names::Vector{String}, items::Vector{String}, set_name::String, entries::Vector{String})
    for entry in entries
        push!(set_names, set_name)
        push!(items, entry)
    end
    return nothing
end

include("Adapters.jl")
using .Adapters

include("TableAdapters.jl")
using .TableAdapters

end # module
