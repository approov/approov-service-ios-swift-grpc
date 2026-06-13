# Changelog

All notable changes to this package will be documented in this file.

The format is based on Keep a Changelog and this project adheres to Semantic Versioning.

## [3.5.4] - 2026-06-13

### Changed
- Decoupled `approov-ios-sdk` as a direct Swift Package Manager package dependency instead of using a local binary target, removing the need for a SHA256 checksum and preventing target conflicts when using multiple Approov service layers.
- Modified `ApproovService.initialize(config:comment:)` to accept and forward the optional `comment` parameter to the native SDK, enabling re-initialization (with `"reinit"` prefix) and initialization options.
- Updated `initialize` error handling to catch and ignore Swift-bridged `Foundation._GenericObjCError` exceptions from native SDK same-config re-initialization.
- Modified `setInstallAttributes` to invoke `Approov.setInstallAttrsInToken(attrs)` on the platform SDK.

### Added
- Added `README.md`, `USAGE.md`, and `REFERENCE.md` documentation files for the service layer.

## [3.5.3] - 2026-01-15

### Added
- Added `getLastARC` method to expose the last Attestation Response Code.
- Exposed application install attributes to the service layer.
- Updated underlying Approov iOS SDK to version 3.5.3.

## [3.5.0] - 2025-11-20

### Changed
- Updated underlying Approov iOS SDK dependency to version 3.5.0.

## [3.3.0] - 2025-06-10

### Changed
- Updated underlying Approov iOS SDK dependency to version 3.3.0.
