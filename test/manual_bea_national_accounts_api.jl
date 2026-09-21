using CSV
using DataFrames
using JCGEImportData
using Test
using TOML

api_key = get(ENV, "BEA_API_KEY", "")
isempty(api_key) && error("Set BEA_API_KEY before running this manual test.")

release = BEANationalAccountsRelease(2016, "T10105")

mktempdir() do directory
    files = download_bea_national_accounts(
        release,
        directory;
        api_key = api_key,
        lines = ["1"],
        metrics = ["Current Dollars"],
    )
    accounts = CSV.read(files.path, DataFrame)
    manifest = TOML.parsefile(files.manifest_path)

    @test nrow(accounts) == 1
    @test accounts.region == ["US"]
    @test string.(accounts.line) == ["1"]
    @test accounts.metric == ["Current Dollars"]
    @test manifest["source"] == "BEA National Income and Product Accounts API"
    @test manifest["table_name"] == "T10105"
    @test !occursin(api_key, read(files.manifest_path, String))

    println("BEA national-accounts download succeeded: $(nrow(accounts)) observation.")
end
