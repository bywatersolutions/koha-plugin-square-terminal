# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- [#2] Extract inline JS from intranet_js to a separate static file

### Fixed
- [#3] Add idempotency guard to finalize_checkout to prevent double-charging
- [#4] Add x-koha-authorization (updatecharges permission) to API endpoints

## [0.1.0] - 2026-07-15

### Added
- [#1] Align CI/CD with Rapido ILL release workflow
  - Automated version management via npm version (package.json)
  - Local KPZ builds via gulp (gulpfile.js)
  - Changelog automation scripts (stamp-changelog.pl, open-next-changelog.pl)
  - Docker-based KPZ builder in CI
  - Branch safety check (only release from main)
  - Upgrade path testing
  - JUnit test reporting
  - .editorconfig for consistent formatting

### Fixed
- [#1] Fix 00-load.t to scan from plugin root directory

## [0.0.3] - 2026-07-10

### Added
- Real-time payment status polling
- POS integration (auto-submits Koha POS form on success)
- Square Terminal device mapping via YAML configuration

## [0.0.0] - 2023-08-21

### Added
- This plugin, initial commit ;)
