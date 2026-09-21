# JCGEImportData API

## Core data structures and transformations

```@autodocs
Modules = [JCGEImportData, JCGEImportData.Transformations]
Pages = ["JCGEImportData.jl", "Transformations.jl"]
Order = [:module, :type, :function, :macro, :constant]
```

## BEA

```@docs
JCGEImportData.BEAFlatSchema
JCGEImportData.BEAAdapter
JCGEImportData.BEARelease
JCGEImportData.download_bea
JCGEImportData.BEANationalAccountsRelease
JCGEImportData.download_bea_national_accounts
```

## Eurostat

```@docs
JCGEImportData.EurostatAdapter
JCGEImportData.EurostatNationalSUTRelease
JCGEImportData.download_eurostat_national_sut
JCGEImportData.EurostatNationalSUTAdapter
JCGEImportData.EurostatNationalAccountsRelease
JCGEImportData.download_eurostat_national_accounts
JCGEImportData.SatelliteFlatSchema
JCGEImportData.SatelliteAdapter
JCGEImportData.EurostatSatelliteRelease
JCGEImportData.download_eurostat_satellite
```

## FIGARO

```@docs
JCGEImportData.FIGAROFlatSchema
JCGEImportData.FIGARORelease
JCGEImportData.download_figaro
```

## OECD ICIO

```@docs
JCGEImportData.IOTFlatSchema
JCGEImportData.IOTAdapter
JCGEImportData.OECDICIOAdapter
JCGEImportData.OECDICIORelease
JCGEImportData.download_oecd_icio
JCGEImportData.normalize_oecd_icio
```

## Local-table loaders

```@docs
JCGEImportData.load_iobundle
JCGEImportData.load_sut
JCGEImportData.load_iot
JCGEImportData.load_satellite
```
