using CSV
using DataFrames
using JCGEImportData
using Test
using TOML

# This is intentionally a manual live-API test. It is not included by
# test/runtests.jl and therefore never runs in CI.
api_key = get(ENV, "BEA_API_KEY", "")
isempty(api_key) && error("Set BEA_API_KEY before running this manual test.")

# These published 2020 tables are used only to verify API retrieval and
# normalization. Choosing a table family for a CGE dataset remains explicit in
# the calling workflow.
release = BEARelease(2020, 259, 258)

mktempdir() do directory
    files = download_bea(release, directory; api_key = api_key)

    @test all(isfile, (
        files.make_raw_path,
        files.use_raw_path,
        files.make_path,
        files.use_path,
        files.manifest_path,
    ))
    @test all(path -> filesize(path) > 0, (
        files.make_raw_path,
        files.use_raw_path,
        files.make_path,
        files.use_path,
    ))

    manifest = TOML.parsefile(files.manifest_path)
    @test manifest["source"] == "BEA API"
    @test manifest["reference_year"] == 2020
    @test manifest["make"]["table_id"] == 259
    @test manifest["use"]["table_id"] == 258
    @test !occursin("UserID", read(files.manifest_path, String))

    make = CSV.read(files.make_path, DataFrame)
    use = CSV.read(files.use_path, DataFrame)
    @test names(make) == ["commodity", "industry", "value"]
    @test names(use) == ["commodity", "account", "value"]
    @test nrow(make) > 0
    @test nrow(use) > 0

    println("BEA live download and normalization succeeded: $(nrow(make)) Make rows; $(nrow(use)) Use rows.")
end
