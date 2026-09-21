using CSV
using DataFrames
using JCGEImportData
using Test
using TOML

release = EurostatNationalAccountsRelease(
    2016,
    "nasa_10_nf_tr";
    unit = "CP_MEUR",
    dimensions = ["direct", "na_item", "sector"],
)

mktempdir() do directory
    files = download_eurostat_national_accounts(
        release,
        directory;
        regions = ["DE"],
        selections = Dict(
            "direct" => ["PAID", "RECV"],
            "na_item" => ["D1"],
            "sector" => ["S1"],
        ),
    )
    accounts = CSV.read(files.path, DataFrame)
    manifest = TOML.parsefile(files.manifest_path)

    @test nrow(accounts) == 2
    @test Set(accounts.direct) == Set(["PAID", "RECV"])
    @test Set(accounts.na_item) == Set(["D1"])
    @test manifest["dataset"] == "nasa_10_nf_tr"
    @test manifest["filters"]["freq"] == "A"

    println("Eurostat national-accounts download succeeded: $(nrow(accounts)) observations.")
end
