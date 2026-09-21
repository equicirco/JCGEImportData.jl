using JCGEImportData
using CSV
using DataFrames
using Test
using TOML
using ZipFile

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

@testset "Eurostat FIGARO flat-SUT adapter" begin
    mktempdir() do dir
        supply_path = joinpath(dir, "supply.tsv")
        use_path = joinpath(dir, "use.tsv")
        CSV.write(supply_path, DataFrame(
            row_country = ["DE", "FR"],
            row_code = ["DE:CPA_G1", "FR:CPA_G1"],
            col_country = ["DE", "FR"],
            col_code = ["DE:A1", "FR:A1"],
            value_meur = [10.0, 8.0],
        ); delim = '\t')
        CSV.write(use_path, DataFrame(
            row_country = ["DOM", "FR", "DOM", "DOM", "DE"],
            row_code = ["DE:CPA_G1", "FR:CPA_G1", "DE:CPA_G1", "FR:CPA_G1", "DE:D1"],
            col_country = ["DE", "DE", "DE", "FR", "DE"],
            col_code = ["DE:A1", "DE:A1", "DE:P3_S14", "FR:P3_S14", "DE:A1"],
            value_meur = [4.0, 2.0, 4.0, 8.0, 3.0],
        ); delim = '\t')

        sut = load_sut(EurostatAdapter(supply_path, use_path; year = 2016))
        @test sut isa MultiRegionSUT
        @test sut.regions == ["DE", "FR"]
        @test sut.products == ["CPA_G1"]
        @test sut.activities == ["A1"]
        @test sut.final_uses == ["P3_S14"]
        @test sut.use.product_origin[1] == "DE"
        @test sut.use.product_origin[2] == "FR"
        @test sut.use.use_account == ["A1", "A1", "P3_S14", "P3_S14"]
        @test sut.provenance["year"] == "2016"
        @test all(check_sut_balance(sut).balanced)
        @test_throws ErrorException load_iobundle(EurostatAdapter(supply_path, use_path))
    end
end

@testset "BEA Make/Use adapter" begin
    mktempdir() do dir
        make_path = joinpath(dir, "make.csv")
        use_path = joinpath(dir, "use.csv")
        CSV.write(make_path, DataFrame(
            commodity = ["P1", "P1", "P2"],
            industry = ["A1", "A2", "A2"],
            value = [6.0, 4.0, 10.0],
        ))
        CSV.write(use_path, DataFrame(
            commodity = ["P1", "P1", "P1", "P2", "P2", "VALUE_ADDED"],
            account = ["A1", "A2", "P3_HH", "A1", "P3_HH", "A1"],
            value = [5.0, 1.0, 4.0, 2.0, 8.0, 3.0],
        ))

        adapter = BEAAdapter(
            make_path,
            use_path;
            products = ["P1", "P2"],
            activities = ["A1", "A2"],
            final_uses = ["P3_HH"],
            region = "US",
            valuation = "producer prices, before redefinitions",
            year = 2022,
        )
        sut = load_sut(adapter)
        @test sut isa MultiRegionSUT
        @test sut.regions == ["US"]
        @test sut.products == ["P1", "P2"]
        @test sut.activities == ["A1", "A2"]
        @test sut.final_uses == ["P3_HH"]
        @test sut.provenance["valuation"] == "producer prices, before redefinitions"
        @test all(check_sut_balance(sut).balanced)

        iot = symmetric_io_model_d(sut)
        diagnostics = check_iot_balance(iot)
        @test all(diagnostics.sales.balanced)
        @test all(diagnostics.industries.balanced)
        @test_throws ErrorException load_iobundle(adapter)
        @test_throws ErrorException BEAAdapter(
            make_path,
            use_path;
            products = String[],
            activities = ["A1"],
            final_uses = String[],
            region = "US",
            valuation = "producer prices",
        )
    end
end

@testset "BEA API downloader normalization" begin
    release = BEARelease(2020, 259, 258)
    @test release.reference_year == 2020
    @test release.make_table_id == 259
    @test_throws ErrorException BEARelease(2020, 0, 258)
    @test occursin(
        "datasetname=InputOutput&Year=2020&TableID=259",
        JCGEImportData.Adapters._bea_api_url(release, 259, "test-key"),
    )
    @test_throws ErrorException JCGEImportData.Adapters._validated_bea_api_key("bad key")
    @test JCGEImportData.Adapters._validated_bea_api_key(" test-key ") isa String

    mktempdir() do dir
        make_path = joinpath(dir, "make.json")
        use_path = joinpath(dir, "use.json")
        error_path = joinpath(dir, "error.json")
        write(make_path, """
        {"BEAAPI":{"Results":{"Data":[
          {"RowCode":"P1","ColCode":"A1","DataValue":"1,234.5"}
        ]}}}
        """)
        write(use_path, """
        {"BEAAPI":{"Results":{"Data":[
          {"RowCode":"P1","ColCode":"P3_HH","DataValue":"1,234.5"}
        ]}}}
        """)
        array_results_path = joinpath(dir, "array_results.json")
        write(array_results_path, """
        {"BEAAPI":{"Results":[{"Data":[
          {"RowCode":"P1","ColCode":"A1","DataValue":"1"}
        ]}]}}
        """)
        write(error_path, """
        {"BEAAPI":{"Results":{"Error":{"APIErrorDescription":"invalid table"}}}}
        """)
        make = JCGEImportData.Adapters._bea_api_rows(make_path, :make)
        use = JCGEImportData.Adapters._bea_api_rows(use_path, :use)
        @test make.commodity == ["P1"]
        @test make.industry == ["A1"]
        @test make.value == ["1,234.5"]
        @test use.account == ["P3_HH"]
        @test JCGEImportData.Adapters._bea_api_rows(array_results_path, :make).industry == ["A1"]
        @test_throws ErrorException JCGEImportData.Adapters._bea_api_rows(error_path, :make)
    end

    national = BEANationalAccountsRelease(2016, "T10105")
    @test national.frequency == "A"
    @test national.region == "US"
    @test occursin(
        "datasetname=NIPA&TableName=T10105&Frequency=A&Year=2016",
        JCGEImportData.Adapters._bea_national_accounts_url(national, "test-key"),
    )
    @test_throws ErrorException BEANationalAccountsRelease(2016, "T10.101")
    mktempdir() do dir
        accounts_path = joinpath(dir, "national_accounts.json")
        write(accounts_path, """
        {"BEAAPI":{"Results":{"Data":[
          {"TableName":"T10105","SeriesCode":"A191RC","LineNumber":"1","LineDescription":"Gross domestic product","TimePeriod":"2016","METRIC_NAME":"Current Dollars","CL_UNIT":"Millions of dollars","UNIT_MULT":"0","DataValue":"18,804,913"},
          {"TableName":"T10105","SeriesCode":"A191RL","LineNumber":"1","LineDescription":"Gross domestic product","TimePeriod":"2016","METRIC_NAME":"Fisher Quantity Index","CL_UNIT":"Percent change, annual rate","UNIT_MULT":"0","DataValue":"1.8"}
        ]}}}
        """)
        accounts = JCGEImportData.Adapters._bea_national_accounts_rows(
            accounts_path, national, Set(["1"]), Set(["Current Dollars"]),
        )
        @test nrow(accounts) == 1
        @test accounts.region == ["US"]
        @test accounts.metric == ["Current Dollars"]
        @test accounts.value == [18_804_913.0]
    end
end

@testset "Direct industry-by-industry IO adapters" begin
    mktempdir() do dir
        intermediate_path = joinpath(dir, "intermediate.csv")
        final_demand_path = joinpath(dir, "final_demand.csv")
        output_path = joinpath(dir, "output.csv")
        CSV.write(intermediate_path, DataFrame(
            supplier_region = ["R1", "R1", "R2", "R2"],
            supplier_industry = ["A1", "A1", "A1", "A1"],
            user_region = ["R1", "R2", "R1", "R2"],
            user_industry = ["A1", "A1", "A1", "A1"],
            value = [2.0, 1.0, 3.0, 4.0],
        ))
        CSV.write(final_demand_path, DataFrame(
            supplier_region = ["R1", "R1", "R2", "R2"],
            supplier_industry = ["A1", "A1", "A1", "A1"],
            demand_region = ["R1", "R2", "R1", "R2"],
            final_use = ["HH", "HH", "HH", "HH"],
            value = [7.0, 5.0, 6.0, 8.0],
        ))
        CSV.write(output_path, DataFrame(
            region = ["R1", "R2"], industry = ["A1", "A1"], value = [15.0, 21.0],
        ))

        adapter = IOTAdapter(
            intermediate_path, final_demand_path, output_path;
            regions = ["R1", "R2"], industries = ["A1"], final_uses = ["HH"],
            valuation = "basic prices", year = 2020,
        )
        iot = load_iot(adapter)
        @test iot.products == String[]
        @test nrow(iot.sales_structure) == 0
        @test nrow(iot.intermediate) == 4
        @test all(check_iot_balance(iot).industries.balanced)

        oecd = OECDICIOAdapter(
            intermediate_path, final_demand_path, output_path;
            edition = "2023 edition", regions = ["R1", "R2"], industries = ["A1"],
            final_uses = ["HH"], valuation = "basic prices", year = 2020,
        )
        oecd_iot = load_iot(oecd)
        @test oecd_iot.provenance["source"] == "OECD Inter-Country Input-Output (ICIO) tables"
        @test oecd_iot.provenance["oecd_icio_edition"] == "2023 edition"
    end
end

@testset "Eurostat national SUT and satellite adapters" begin
    mktempdir() do dir
        supply_path = joinpath(dir, "supply.csv")
        use_path = joinpath(dir, "use.csv")
        satellite_path = joinpath(dir, "satellite.csv")
        CSV.write(supply_path, DataFrame(
            product = ["P1", "P2"], activity = ["A1", "A1"], value = [6.0, 4.0],
        ))
        CSV.write(use_path, DataFrame(
            product = ["P1", "P1", "P2", "P2"],
            account = ["A1", "HH", "A1", "HH"], value = [2.0, 4.0, 3.0, 1.0],
        ))
        sut = load_sut(EurostatNationalSUTAdapter(
            supply_path, use_path;
            products = ["P1", "P2"], activities = ["A1"], final_uses = ["HH"],
            region = "DE", valuation = "basic prices", year = 2020,
        ))
        @test sut.regions == ["DE"]
        @test all(check_sut_balance(sut).balanced)

        CSV.write(satellite_path, DataFrame(
            region = ["DE", "DE"], industry = ["A1", "A1"],
            indicator = ["employment", "steel_use"], unit = ["persons", "tonnes"],
            value = [10.0, 25.0],
        ))
        satellite = load_satellite(SatelliteAdapter(
            satellite_path;
            regions = ["DE"], industries = ["A1"],
            indicators = ["employment", "steel_use"], source = "test satellite", year = 2020,
        ))
        @test satellite isa SatelliteTable
        @test satellite.data.unit == ["persons", "tonnes"]
        @test satellite.provenance["year"] == "2020"
    end
end

@testset "OECD and Eurostat national download helpers" begin
    oecd = OECDICIORelease(
        "2025 edition", "2016-2022",
        "https://webfs-sti.oecd.org/files/STI-PIE/ICIO/2025/2016-2022_SML.zip",
    )
    @test oecd.period == "2016-2022"
    @test_throws ErrorException OECDICIORelease("edition", "period", "http://example.org/source.zip")
    mktempdir() do dir
        files = JCGEImportData.TableAdapters._download_oecd_icio(
            oecd,
            dir,
            (_, destination) -> begin
                writer = ZipFile.Writer(destination)
                try
                    entry = ZipFile.addfile(writer, "placeholder.csv")
                    write(entry, "row,DEU_D01\nOUTPUT,1\n")
                finally
                    close(writer)
                end
            end,
        )
        @test isfile(files.archive_path)
        manifest = TOML.parsefile(files.manifest_path)
        @test manifest["edition"] == "2025 edition"
        @test manifest["period"] == "2016-2022"
        @test manifest["archive_url"] == oecd.archive_url
    end

    mktempdir() do dir
        archive_path = joinpath(dir, "source.zip")
        writer = ZipFile.Writer(archive_path)
        try
            entry = ZipFile.addfile(writer, "ICIO2025_2020.csv")
            write(entry, """
            row,DEU_D01,FRA_D01,DEU_HFCE,FRA_HFCE
            DEU_D01,1,2,3,4
            FRA_D01,5,6,7,8
            VALU,0,0,0,0
            OUTPUT,10,26,0,0
            """)
        finally
            close(writer)
        end
        normalized = normalize_oecd_icio(
            oecd,
            archive_path,
            joinpath(dir, "normalized");
            reference_year = 2020,
            regions = ["DEU", "FRA"],
            industries = ["D01"],
            final_uses = ["HFCE"],
        )
        @test all(isfile, (normalized.intermediate_path, normalized.final_demand_path, normalized.output_path, normalized.manifest_path))
        @test nrow(CSV.read(normalized.intermediate_path, DataFrame)) == 4
        @test CSV.read(normalized.output_path, DataFrame).value == [10.0, 26.0]
        @test TOML.parsefile(normalized.manifest_path)["source_member"] == "ICIO2025_2020.csv"
        iot = load_iot(OECDICIOAdapter(
            normalized.intermediate_path,
            normalized.final_demand_path,
            normalized.output_path;
            edition = oecd.edition,
            regions = ["DEU", "FRA"],
            industries = ["D01"],
            final_uses = ["HFCE"],
            valuation = "basic prices",
            year = 2020,
        ))
        @test all(check_iot_balance(iot).industries.balanced)
    end

    release = EurostatNationalSUTRelease(2020, "DE")
    @test release.supply_dataset == "naio_10_cp15"
    @test release.use_dataset == "naio_10_cp16"
    @test occursin("geo=DE&time=2020&unit=MIO_EUR", JCGEImportData.TableAdapters._eurostat_national_url(release.supply_dataset, release))
    @test_throws ErrorException EurostatNationalSUTRelease(2020, "DE;FR")
    satellite_release = EurostatSatelliteRelease(
        2020,
        "nama_10_a64_e";
        unit = "THS_PER",
        industry_dimension = "nace_r2",
        indicator_dimension = "na_item",
        filters = Dict("na_item" => "EMP_DC"),
    )
    @test satellite_release.dataset == "nama_10_a64_e"
    @test occursin("na_item=EMP_DC", JCGEImportData.TableAdapters._eurostat_satellite_url(satellite_release, "DE"))
    aggregate_satellite_release = EurostatSatelliteRelease(
        2020,
        "env_ac_mfa";
        unit = "THS_T",
        industry_dimension = nothing,
        indicator_dimension = "material",
        filters = Dict("indic_env" => "DMC"),
    )
    @test aggregate_satellite_release.industry_dimension === nothing
    national_accounts_release = EurostatNationalAccountsRelease(
        2020,
        "nasa_10_nf_tr";
        unit = "CP_MEUR",
        dimensions = ["direct", "na_item", "sector"],
    )
    national_account_selections = Dict(
        "direct" => ["PAID", "RECV"],
        "na_item" => ["D1"],
        "sector" => ["S1"],
    )
    normalized_national_account_selections = JCGEImportData.TableAdapters._eurostat_national_account_selections(
        national_accounts_release, national_account_selections,
    )
    national_accounts_url = JCGEImportData.TableAdapters._eurostat_national_accounts_url(
        national_accounts_release, "DE", normalized_national_account_selections,
    )
    @test occursin("geo=DE", national_accounts_url)
    @test occursin("freq=A", national_accounts_url)
    @test occursin("direct=PAID", national_accounts_url)
    @test_throws ErrorException JCGEImportData.TableAdapters._eurostat_national_account_selections(
        national_accounts_release, Dict("sector" => ["S1"]),
    )
    mktempdir() do dir
        supply_path = joinpath(dir, "supply.json")
        use_path = joinpath(dir, "use.json")
        write(supply_path, """
        {"id":["unit","ind_impv","prd_amo","geo","time"],"size":[1,2,2,1,1],
        "dimension":{"unit":{"category":{"index":{"MIO_EUR":0}}},
        "ind_impv":{"category":{"index":{"A1":0,"A2":1}}},
        "prd_amo":{"category":{"index":{"P1":0,"P2":1}}},
        "geo":{"category":{"index":{"DE":0}}},"time":{"category":{"index":{"2020":0}}}},
        "value":{"0":10,"3":5}}
        """)
        write(use_path, """
        {"id":["unit","ind_use","stk_flow","prd_ava","geo","time"],"size":[1,2,2,2,1,1],
        "dimension":{"unit":{"category":{"index":{"MIO_EUR":0}}},
        "ind_use":{"category":{"index":{"A1":0,"HH":1}}},
        "stk_flow":{"category":{"index":{"TOTAL":0,"OTHER":1}}},
        "prd_ava":{"category":{"index":{"P1":0,"P2":1}}},
        "geo":{"category":{"index":{"DE":0}}},"time":{"category":{"index":{"2020":0}}}},
        "value":{"0":2,"1":4,"4":4,"7":88}}
        """)
        supply = JCGEImportData.TableAdapters._eurostat_jsonstat_rows(
            supply_path;
            product_dimension = "prd_amo", account_dimension = "ind_impv",
            products = Set(["P1", "P2"]), accounts = Set(["A1", "A2"]),
            account_name = :activity,
        )
        use = JCGEImportData.TableAdapters._eurostat_jsonstat_rows(
            use_path;
            product_dimension = "prd_ava", account_dimension = "ind_use",
            products = Set(["P1", "P2"]), accounts = Set(["A1", "HH"]),
            account_name = :account,
        )
        @test sort(supply.value) == [5, 10]
        @test sort(use.value) == [2, 4, 4]
        @test all(use.value .!= 88)
        @test nrow(JCGEImportData.TableAdapters._eurostat_jsonstat_table(supply_path)) == 2

        national_accounts_path = joinpath(dir, "national_accounts.json")
        write(national_accounts_path, """
        {"id":["freq","unit","direct","na_item","sector","geo","time"],"size":[1,1,2,1,1,1,1],
        "dimension":{"freq":{"category":{"index":{"A":0}}},
        "unit":{"category":{"index":{"CP_MEUR":0}}},
        "direct":{"category":{"index":{"PAID":0,"RECV":1}}},
        "na_item":{"category":{"index":{"D1":0}}},
        "sector":{"category":{"index":{"S1":0}}},
        "geo":{"category":{"index":{"DE":0}}},"time":{"category":{"index":{"2020":0}}}},
        "value":{"0":100,"1":75}}
        """)
        accounts = JCGEImportData.TableAdapters._eurostat_national_accounts_rows(
            JCGEImportData.TableAdapters._eurostat_jsonstat_table(national_accounts_path),
            national_accounts_release,
            "DE",
            normalized_national_account_selections,
            (:region, :direct, :na_item, :sector, :unit, :value),
        )
        accounts_table = DataFrame(accounts)
        @test nrow(accounts_table) == 2
        @test accounts_table.direct == ["PAID", "RECV"]
        @test accounts_table.value == [100.0, 75.0]
    end
end

@testset "Model-D symmetric multi-region IO transformation" begin
    sut = MultiRegionSUT(
        regions = ["R1", "R2"],
        products = ["P1", "P2"],
        activities = ["A1", "A2"],
        final_uses = ["F"],
        supply = DataFrame(
            product_origin = ["R1", "R1", "R1", "R2"],
            product = ["P1", "P1", "P2", "P1"],
            activity_region = ["R1", "R1", "R1", "R2"],
            activity = ["A1", "A2", "A2", "A1"],
            value = [6.0, 4.0, 10.0, 8.0],
        ),
        use = DataFrame(
            product_origin = ["R1", "R1", "R1", "R1", "R1", "R2", "R2"],
            product = ["P1", "P1", "P1", "P2", "P2", "P1", "P1"],
            use_region = ["R1", "R2", "R1", "R1", "R1", "R1", "R2"],
            use_account = ["A1", "A1", "F", "A1", "F", "A1", "F"],
            value = [5.0, 1.0, 4.0, 2.0, 8.0, 3.0, 5.0],
        ),
    )

    iot = symmetric_io_model_d(sut)
    @test iot isa MultiRegionIOT
    @test iot.industries == ["A1", "A2"]
    @test iot.final_uses == ["F"]
    @test sum(iot.intermediate.value) == 11.0
    @test sum(iot.final_demand.value) == 17.0
    @test only(filter(
        row -> row.supplier_region == "R1" && row.supplier_industry == "A1" &&
               row.user_region == "R1" && row.user_industry == "A1",
        iot.intermediate,
    ).value) == 3.0
    @test only(filter(
        row -> row.supplier_region == "R1" && row.supplier_industry == "A2" &&
               row.demand_region == "R1" && row.final_use == "F",
        iot.final_demand,
    ).value) == 9.6
    diagnostics = check_iot_balance(iot)
    @test all(diagnostics.sales.balanced)
    @test all(diagnostics.industries.balanced)
end

@testset "Eurostat FIGARO API normalization" begin
    release = FIGARORelease(2016)
    @test release.supply_dataset == "naio_10_fcp_s2"
    @test release.use_dataset == "naio_10_fcp_u2"
    @test_throws ErrorException FIGARORelease(2024)
    @test occursin(
        "/naio_10_fcp_u2/A...DE.MIO_EUR.DE?startPeriod=2016",
        JCGEImportData.Adapters._figaro_api_url(release.use_dataset, "A...DE.MIO_EUR.DE", 2016),
    )

    mktempdir() do directory
        supply_path = joinpath(directory, "supply.csv")
        use_path = joinpath(directory, "use.csv")
        write(supply_path, "DATAFLOW,LAST UPDATE,freq,nace_r2,cpa2_1,unit,geo,TIME_PERIOD,OBS_VALUE,OBS_FLAG,CONF_STATUS\n" *
            "ESTAT:NAIO_10_FCP_S2(1.0),18/07/26 11:00:00,A,A01,CPA_A01,MIO_EUR,DE,2016,46145.022,,\n" *
            "ESTAT:NAIO_10_FCP_S2(1.0),18/07/26 11:00:00,A,A01,CPA_A02,MIO_EUR,DE,2016,0,,\n")
        write(use_path, "DATAFLOW,LAST UPDATE,freq,ind_use,prd_ava,c_dest,unit,c_orig,TIME_PERIOD,OBS_VALUE,OBS_FLAG,CONF_STATUS\n" *
            "ESTAT:NAIO_10_FCP_U2(1.0),18/07/26 11:00:00,A,A01,CPA_A01,DE,MIO_EUR,DE,2016,2972.127,,\n" *
            "ESTAT:NAIO_10_FCP_U2(1.0),18/07/26 11:00:00,A,P3_S14,CPA_A01,DE,MIO_EUR,DE,2016,0,,\n")

        supply = JCGEImportData.Adapters._official_supply_rows(
            JCGEImportData.Adapters._read_eurostat_csv(supply_path),
        )
        use = JCGEImportData.Adapters._official_use_rows(
            JCGEImportData.Adapters._read_eurostat_csv(use_path),
        )
        @test nrow(supply) == 1
        @test supply.row_code == ["CPA_A01"]
        @test supply.col_code == ["A01"]
        @test nrow(use) == 1
        @test use.row_country == ["DE"]
        @test use.col_code == ["A01"]

        flat_supply_path = joinpath(directory, "figaro_supply.tsv")
        flat_use_path = joinpath(directory, "figaro_use.tsv")
        CSV.write(flat_supply_path, supply; delim = '\t')
        CSV.write(flat_use_path, use; delim = '\t')
        sut = load_sut(EurostatAdapter(flat_supply_path, flat_use_path; year = 2016))
        iot = symmetric_io_model_d(sut)
        diagnostics = check_iot_balance(iot)
        @test sut.products == ["CPA_A01"]
        @test iot.industries == ["A01"]
        @test nrow(iot.intermediate) == 1
        @test maximum(abs.(diagnostics.sales.share_gap)) <= 1e-12
    end
end
