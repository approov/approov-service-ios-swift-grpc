# Changelog

All notable changes to this package will be documented in this file.

The format is based on Keep a Changelog and this project adheres to Semantic Versioning.

## [3.5.4] - 2026-06-14

### Added
- **`ApproovServiceMutator`** — a request-mutator / decision-override system that lets callers customize the per-status fail-closed behaviour, the Approov token header value, header substitution, and post-processing of a request. `setServiceMutator(_:)` / `getServiceMutator()` install and read the active mutator (pass `nil` to restore the default). The default mutator is fail-closed for all fetch statuses except `SUCCESS` and `NO_APPROOV_SERVICE` / `UNKNOWN_URL` / `UNPROTECTED_URL`.
- **HTTP message signing (RFC 9421)** via `ApproovDefaultMessageSigning`, installable as a service mutator. It adds `Signature` / `Signature-Input` headers (RFC 8941 byte-sequence form) over the gRPC derived components (`@method`, `@target-uri`, ...), the Approov token and trace-ID headers, and any configured optional headers. Body digest is **not** applicable to gRPC and is not generated. Signing is **fail-open**: only an unsupported algorithm (or a *required* body digest, which gRPC cannot produce) fails closed; every other signing failure proceeds unsigned and logs at error level.
- Common service-interface methods to match the other Approov service layers: `isInitialized()`, `setApproovTraceIDHeader(header:)` / `getApproovTraceIDHeader()`, `setUseApproovStatusIfNoToken(shouldUse:)` / `getUseApproovStatusIfNoToken()`, `getAccountMessageSignature(message:)` / `getInstallMessageSignature(message:)`, `addExclusionURLRegex(urlRegex:)` / `removeExclusionURLRegex(urlRegex:)`, and `ApproovLogLevel` + `loggingLevel`.
- `updateRequestHeaders(headers:hostname:path:)` now accepts the RPC path so message signing can include the `@path` / `@target-uri` derived components; `ApproovClientInterceptor` forwards `context.path` automatically.
- Added `README.md`, `USAGE.md`, and `REFERENCE.md` documentation files for the service layer.

### Changed
- Decoupled `approov-ios-sdk` as a direct Swift Package Manager package dependency instead of using a local binary target, removing the need for a SHA256 checksum and preventing target conflicts when using multiple Approov service layers.
- Modified `ApproovService.initialize(config:comment:)` to accept and forward the optional `comment` parameter to the native SDK, enabling re-initialization (with `"reinit"` prefix) and initialization options.
- Updated `initialize` error handling to catch and ignore Swift-bridged `Foundation._GenericObjCError` exceptions from native SDK same-config re-initialization.
- Modified `setInstallAttributes` to invoke `Approov.setInstallAttrsInToken(attrs)` on the platform SDK.
- Request processing now routes through the active `ApproovServiceMutator` (token decision, header substitution, processed-request hook). Network-failure handling follows the default mutator and `setUseApproovStatusIfNoToken` rather than `proceedOnNetworkFail`.
- The active service mutator is reset to the default on every successful `initialize(...)`.
- Added a dependency on `swift-http-structured-headers` (`RawStructuredFieldValues`) for the RFC 9421 structured-field serialization used by message signing.

### Deprecated
- `proceedOnNetworkFail` is now a no-op retained only for source compatibility. Use a custom `ApproovServiceMutator` and/or `setUseApproovStatusIfNoToken(shouldUse:)` instead.
- `getMessageSignature(message:)` is retained as an alias for `getAccountMessageSignature(message:)`; prefer the explicit account / install accessors.

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
