using CSV
using DataFrames
using JCGEImportData
using Test
using TOML

# This is intentionally a manual live-API test. It is not included by
# test/runtests.jl and therefore never runs in CI.
release = EurostatSatelliteRelease(
    2020,
    "nama_10_a64_e";
    unit = "THS_PER",
    industry_dimension = "nace_r2",
    indicator_dimension = "na_item",
    filters = Dict("na_item" => "EMP_DC"),
)

mktempdir() do directory
    files = download_eurostat_satellite(
        release,
        directory;
        regions = ["DE"],
        industries = ["C26", "C27"],
        indicators = ["EMP_DC"],
    )
    @test isfile(files.path)
    @test all(isfile, files.raw_paths)
    @test isfile(files.manifest_path)
    data = CSV.read(files.path, DataFrame)
    @test data.region == ["DE", "DE"]
    @test data.industry == ["C26", "C27"]
    @test data.indicator == ["EMP_DC", "EMP_DC"]
    @test all(data.unit .== "THS_PER")
    manifest = TOML.parsefile(files.manifest_path)
    @test manifest["dataset"] == "nama_10_a64_e"
    @test manifest["regions"] == ["DE"]
    println("Eurostat employment satellite download succeeded: $(nrow(data)) observations.")
end
