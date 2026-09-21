using CSV
using DataFrames
using JCGEImportData
using Test
using TOML

# This is intentionally a manual live-API test. It is not included by
# test/runtests.jl and therefore never runs in CI.
release = EurostatNationalSUTRelease(2020, "DE")

mktempdir() do directory
    files = download_eurostat_national_sut(
        release,
        directory;
        products = ["CPA_C26", "CPA_C27"],
        activities = ["C26", "C27"],
        final_uses = ["P3_S14"],
    )
    @test all(isfile, (
        files.supply_raw_path,
        files.use_raw_path,
        files.supply_path,
        files.use_path,
        files.manifest_path,
    ))
    @test nrow(CSV.read(files.supply_path, DataFrame)) > 0
    @test nrow(CSV.read(files.use_path, DataFrame)) > 0
    manifest = TOML.parsefile(files.manifest_path)
    @test manifest["region"] == "DE"
    @test manifest["reference_year"] == 2020

    sut = load_sut(EurostatNationalSUTAdapter(
        files.supply_path,
        files.use_path;
        products = ["CPA_C26", "CPA_C27"],
        activities = ["C26", "C27"],
        final_uses = ["P3_S14"],
        region = "DE",
        valuation = "published supply at basic prices and use at purchasers' prices",
        year = 2020,
    ))
    @test sut.regions == ["DE"]
    @test nrow(sut.supply) > 0
    @test nrow(sut.use) > 0
    println("Eurostat national SUT download and normalization succeeded: $(nrow(sut.supply)) supply rows; $(nrow(sut.use)) use rows.")
end
