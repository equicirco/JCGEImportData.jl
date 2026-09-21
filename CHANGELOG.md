# JCGEImportData Changelog
All notable changes to this project will be documented in this file.
Releases use semantic versioning as in 'MAJOR.MINOR.PATCH'.

## Change entries
Added: For new features that have been added.
Changed: For changes in existing functionality.
Deprecated: For once-stable features removed in upcoming releases.
Removed: For features removed in this release.
Fixed: For any bug fixes.
Security: For vulnerabilities.

## [0.1.1] - 2026-09-21
### Added
- Source adapters and cached downloads for Eurostat FIGARO and national SUTs,
  BEA Make/Use and national accounts, OECD ICIO archives, Eurostat national
  accounts, and selected Eurostat satellite accounts.
- Direct industry-by-industry IO imports, Model-D SUT-to-IO transformation,
  balance diagnostics, and canonical dataset writing for JCGECalibrate.
- Source manifests with declared selections, raw-response retention, and
  SHA-256 checksums, plus automated and manual live-source tests.

### Changed
- Documentation now gives an explicit preparation path from source accounts to
  the canonical files read by JCGECalibrate.

## [0.1.0] - 2026-01-16
### Added
- Project layout and package boundaries.
- Data import helpers for JCGE input datasets.
- CSV/DataFrames-based ingestion and validation pipeline.
- Integration points with JCGECore and JCGECalibrate.
- Documentation scaffolding and package docs.
