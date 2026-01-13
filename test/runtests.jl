using JCGEImportData
using Test

@testset "JCGEImportData" begin
    bundle = IOBundle(
        goods = ["G1", "G2"],
        activities = ["A1", "A2"],
        factors = ["K", "L"],
        institutions = ["HOH", "GOV", "INV"],
        tax_accounts = ["IDT", "TRF"],
        ext_accounts = ["ROW", "CAP"],
        use = LabeledMatrix(["G1", "G2"], ["A1", "A2"], [1 2; 3 4]),
        supply = LabeledMatrix(["A1", "A2"], ["G1", "G2"], [5 6; 7 8]),
        value_added = LabeledMatrix(["K", "L"], ["A1", "A2"], [2 1; 3 4]),
        final_demand = LabeledMatrix(["G1", "G2"], ["HOH", "GOV", "INV"], [1 0 2; 2 1 0]),
        taxes = LabeledMatrix(["IDT", "TRF"], ["A1", "A2"], [0.5 0.0; 0.0 0.25]),
        imports = LabeledMatrix(["G1", "G2"], ["ROW", "CAP"], [0.1 0.2; 0.3 0.4]),
        exports = LabeledMatrix(["G1", "G2"], ["ROW", "CAP"], [0.5 0.6; 0.7 0.8]),
        factor_income = LabeledMatrix(["HOH", "GOV", "INV"], ["K", "L"], [5 6; 0 0; 0 0]),
    )

    sam = sam_from_io(bundle)
    row_idx = Dict(sam.label .=> eachindex(sam.label))
    col_idx = Dict(string.(names(sam)[2:end]) .=> 2:size(sam, 2))

    @test sam[row_idx["G1"], col_idx["A1"]] == 1.0
    @test sam[row_idx["A1"], col_idx["G2"]] == 6.0
    @test sam[row_idx["K"], col_idx["A1"]] == 2.0
    @test sam[row_idx["G2"], col_idx["GOV"]] == 1.0
    @test sam[row_idx["IDT"], col_idx["A1"]] == 0.5
    @test sam[row_idx["G1"], col_idx["ROW"]] == 0.5
    @test sam[row_idx["ROW"], col_idx["G1"]] == 0.1
    @test sam[row_idx["HOH"], col_idx["K"]] == 5.0

    sam_balance = check_sam_balance(sam)
    @test "account" in names(sam_balance)
    io_balance = check_io_balance(bundle)
    @test "good" in names(io_balance.goods)
    @test "activity" in names(io_balance.activities)

    mktempdir() do dir
        write_canonical_dataset(dir, bundle)
        @test isfile(joinpath(dir, "sam.csv"))
        @test isfile(joinpath(dir, "sets.csv"))
    end
end
