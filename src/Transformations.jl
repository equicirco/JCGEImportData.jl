"""
Source-neutral supply-use transformations.
"""
module Transformations

using DataFrames

using ..JCGEImportData: MultiRegionIOT, MultiRegionSUT

export check_iot_balance
export symmetric_io_model_d

"""
    symmetric_io_model_d(sut; atol=1e-12)

Construct a sparse, multi-region, industry-by-industry IO representation from
`sut` using the fixed-product sales structure convention known as Eurostat
Model D. For every product origin, each use is allocated to producing
industries according to their recorded shares of that product's supply.

Only product rows are transformed. Non-product source rows, such as factor and
tax entries, remain available in `sut.source_tables` for an explicit later
mapping by the consuming model.
"""
function symmetric_io_model_d(sut::MultiRegionSUT; atol::Float64 = 1e-12)
    atol >= 0.0 || error("atol must be non-negative.")
    product_output = Dict{Tuple{String, String}, Float64}()
    industry_output = Dict{Tuple{String, String}, Float64}()
    make = Dict{NTuple{4, String}, Float64}()

    for row in eachrow(sut.supply)
        value = Float64(row.value)
        value < -atol && error("Model D requires non-negative supply entries; found $(value) for $(row.product_origin)/$(row.product).")
        abs(value) <= atol && continue
        product_key = (String(row.product_origin), String(row.product))
        industry_key = (String(row.activity_region), String(row.activity))
        make_key = (product_key[1], product_key[2], industry_key[1], industry_key[2])
        product_output[product_key] = get(product_output, product_key, 0.0) + value
        industry_output[industry_key] = get(industry_output, industry_key, 0.0) + value
        make[make_key] = get(make, make_key, 0.0) + value
    end

    sales_by_product = Dict{Tuple{String, String}, Vector{NamedTuple{(:supplier_region, :supplier_industry, :share), Tuple{String, String, Float64}}}}()
    sales_rows = NamedTuple[]
    for key in sort!(collect(keys(make)))
        product_key = (key[1], key[2])
        output = product_output[product_key]
        output > atol || error("Model D cannot allocate product $(key[1])/$(key[2]) with non-positive supply.")
        share = make[key] / output
        push!(get!(sales_by_product, product_key, NamedTuple{(:supplier_region, :supplier_industry, :share), Tuple{String, String, Float64}}[]), (
            supplier_region = key[3],
            supplier_industry = key[4],
            share = share,
        ))
        push!(sales_rows, (
            product_origin = key[1],
            product = key[2],
            supplier_region = key[3],
            supplier_industry = key[4],
            supply_value = make[key],
            product_output = output,
            sales_share = share,
        ))
    end

    intermediate = Dict{NTuple{4, String}, Float64}()
    final_demand = Dict{NTuple{4, String}, Float64}()
    industries = Set(sut.activities)
    for row in eachrow(sut.use)
        value = Float64(row.value)
        abs(value) <= atol && continue
        product_key = (String(row.product_origin), String(row.product))
        suppliers = get(sales_by_product, product_key, nothing)
        suppliers === nothing && error("Model D has no supply structure for product $(product_key[1])/$(product_key[2]) used by $(row.use_region)/$(row.use_account).")
        if row.use_account in industries
            for supplier in suppliers
                key = (supplier.supplier_region, supplier.supplier_industry, String(row.use_region), String(row.use_account))
                intermediate[key] = get(intermediate, key, 0.0) + supplier.share * value
            end
        else
            for supplier in suppliers
                key = (supplier.supplier_region, supplier.supplier_industry, String(row.use_region), String(row.use_account))
                final_demand[key] = get(final_demand, key, 0.0) + supplier.share * value
            end
        end
    end

    intermediate_df = DataFrame(
        supplier_region = String[key[1] for key in sort!(collect(keys(intermediate)))],
        supplier_industry = String[key[2] for key in sort!(collect(keys(intermediate)))],
        user_region = String[key[3] for key in sort!(collect(keys(intermediate)))],
        user_industry = String[key[4] for key in sort!(collect(keys(intermediate)))],
        value = Float64[intermediate[key] for key in sort!(collect(keys(intermediate)))],
    )
    final_demand_df = DataFrame(
        supplier_region = String[key[1] for key in sort!(collect(keys(final_demand)))],
        supplier_industry = String[key[2] for key in sort!(collect(keys(final_demand)))],
        demand_region = String[key[3] for key in sort!(collect(keys(final_demand)))],
        final_use = String[key[4] for key in sort!(collect(keys(final_demand)))],
        value = Float64[final_demand[key] for key in sort!(collect(keys(final_demand)))],
    )
    industry_output_df = DataFrame(
        region = String[key[1] for key in sort!(collect(keys(industry_output)))],
        industry = String[key[2] for key in sort!(collect(keys(industry_output)))],
        value = Float64[industry_output[key] for key in sort!(collect(keys(industry_output)))],
    )

    return MultiRegionIOT(
        regions = copy(sut.regions),
        products = copy(sut.products),
        industries = copy(sut.activities),
        final_uses = copy(sut.final_uses),
        sales_structure = DataFrame(sales_rows),
        intermediate = intermediate_df,
        final_demand = final_demand_df,
        industry_output = industry_output_df,
        provenance = Dict(
            "source" => "Model-D transformation of normalized multi-region SUT",
            "method" => "fixed-product sales structure",
        ),
    )
end

"""
    check_iot_balance(iot; atol=1e-6)

Report the applicable sales-share sums and the difference between each
industry's recorded output and its intermediate plus final sales. Sales-share
diagnostics apply only to IO tables constructed from an SUT; direct
industry-by-industry imports have no product sales structure. A non-zero
industry difference reflects an imbalance already present in source data; this
function does not alter the IO data.
"""
function check_iot_balance(iot::MultiRegionIOT; atol::Float64 = 1e-6)
    atol >= 0.0 || error("atol must be non-negative.")
    share_totals = Dict{Tuple{String, String}, Float64}()
    for row in eachrow(iot.sales_structure)
        key = (String(row.product_origin), String(row.product))
        share_totals[key] = get(share_totals, key, 0.0) + Float64(row.sales_share)
    end
    sales = DataFrame(
        product_origin = String[key[1] for key in sort!(collect(keys(share_totals)))],
        product = String[key[2] for key in sort!(collect(keys(share_totals)))],
        sales_share_sum = Float64[share_totals[key] for key in sort!(collect(keys(share_totals)))],
    )
    sales.share_gap = sales.sales_share_sum .- 1.0
    sales.balanced = abs.(sales.share_gap) .<= atol

    allocated = Dict{Tuple{String, String}, Float64}()
    for table in (iot.intermediate, iot.final_demand)
        for row in eachrow(table)
            key = (String(row.supplier_region), String(row.supplier_industry))
            allocated[key] = get(allocated, key, 0.0) + Float64(row.value)
        end
    end
    output = Dict{Tuple{String, String}, Float64}()
    for row in eachrow(iot.industry_output)
        key = (String(row.region), String(row.industry))
        output[key] = get(output, key, 0.0) + Float64(row.value)
    end
    industry_keys = sort!(collect(union(keys(allocated), keys(output))))
    industries = DataFrame(
        region = String[key[1] for key in industry_keys],
        industry = String[key[2] for key in industry_keys],
        output = Float64[get(output, key, 0.0) for key in industry_keys],
        allocated_sales = Float64[get(allocated, key, 0.0) for key in industry_keys],
    )
    industries.imbalance = industries.output .- industries.allocated_sales
    industries.balanced = abs.(industries.imbalance) .<= atol
    return (sales = sales, industries = industries)
end

end # module
