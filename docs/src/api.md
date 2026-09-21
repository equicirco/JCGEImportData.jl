# JCGEImportData API

## Core data structures and transformations

```@autodocs
Modules = [JCGEImportData, JCGEImportData.Transformations]
Pages = ["JCGEImportData.jl", "Transformations.jl"]
Order = [:module, :type, :function, :macro, :constant]
```

## BEA

```@docs
JCGEImportData.Adapters.BEAFlatSchema
JCGEImportData.Adapters.BEAAdapter
JCGEImportData.Adapters.BEARelease
JCGEImportData.Adapters.download_bea
JCGEImportData.Adapters.BEANationalAccountsRelease
JCGEImportData.Adapters.download_bea_national_accounts
```

## Eurostat

```@docs
JCGEImportData.Adapters.EurostatAdapter
JCGEImportData.TableAdapters.EurostatNationalSUTRelease
JCGEImportData.TableAdapters.download_eurostat_national_sut
JCGEImportData.TableAdapters.EurostatNationalSUTAdapter
JCGEImportData.TableAdapters.EurostatNationalAccountsRelease
JCGEImportData.TableAdapters.download_eurostat_national_accounts
JCGEImportData.TableAdapters.SatelliteFlatSchema
JCGEImportData.TableAdapters.SatelliteAdapter
JCGEImportData.TableAdapters.EurostatSatelliteRelease
JCGEImportData.TableAdapters.download_eurostat_satellite
```

## FIGARO

```@docs
JCGEImportData.Adapters.FIGAROFlatSchema
JCGEImportData.Adapters.FIGARORelease
JCGEImportData.Adapters.download_figaro
```

## OECD ICIO

```@docs
JCGEImportData.TableAdapters.IOTFlatSchema
JCGEImportData.TableAdapters.IOTAdapter
JCGEImportData.TableAdapters.OECDICIOAdapter
JCGEImportData.TableAdapters.OECDICIORelease
JCGEImportData.TableAdapters.download_oecd_icio
JCGEImportData.TableAdapters.normalize_oecd_icio
```

## Local-table loaders

```@docs
JCGEImportData.Adapters.load_iobundle
JCGEImportData.Adapters.load_sut
JCGEImportData.TableAdapters.load_iot
```
