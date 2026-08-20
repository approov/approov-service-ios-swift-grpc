# Changelog

All notable changes to this package will be documented in this file.

The format is based on Keep a Changelog and this project adheres to Semantic Versioning.

## [3.5.4] - 2026-06-14

### Added
- **`ApproovServiceMutator`** — a request-mutator / decision-override system that lets callers customize the per-status fail-closed behaviour, the Approov token header value, header substitution, and post-processing of a request. `setServiceMutator(_:)` / `getServiceMutator()` install and read the active mutator (pass `nil` to restore the default). The default mutator is fail-closed for all fetch statuses except, per operation: `SUCCESS` everywhere; `NO_APPROOV_SERVICE` / `UNKNOWN_URL` / `UNPROTECTED_URL` on the **token fetch**, where proceeding without a token is a coherent degraded state; and `UNKNOWN_KEY` on the **secure-string** operations, where the key is simply not defined for the account. `NO_APPROOV_SERVICE` is deliberately *not* an exception on secure-string substitution: with no secret resolvable the only alternative to failing is sending the lookup key as the credential, so it fails closed (`TESTING_REQUIREMENTS.md` §3).
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

### Fixed
- Secure-string substitution now runs even when the token fetch produced no token for a *protected* domain (in practice `NO_APPROOV_SERVICE`), so the substitution handler's own policy applies and fails the request closed rather than forwarding the lookup key as the credential. Domains the SDK reports as `UNKNOWN_URL` / `UNPROTECTED_URL` are still forwarded entirely unmodified, because resolving a placeholder for a host Approov neither tokenizes nor pins is the exposure `TESTING_REQUIREMENTS.md` §2 forbids.
- `isApproovEnabled()` reads the initialization flag under the initialization lock. It was an unsynchronised read of a `static var` from NIO event loops, the pinning callback queue and application threads, and `initialize()` clears the flag before resetting state and setting it again — so a request landing in that window was forwarded without a token, and a handshake in that window skipped Approov pinning.
- The client interceptor logs at error when a request is rejected before send. grpc-swift's own invocation path passes `promise: nil`, so `promise?.fail(error)` is a no-op there and the `ApproovError` — including a rejection ARC — was otherwise discarded, leaving the caller only a cancelled RPC.
- Message signing now fully conforms to the cross-layer fail-open policy (core-project-approov#564): a signature-base build failure and a `Signature`/`Signature-Input` serialization failure now log at error level and proceed **unsigned** instead of aborting the request, matching the existing install/account/base64/ASN.1 fail-open paths. Only an unsupported algorithm still fails closed (gRPC produces no body digest).
- `ApproovClientInterceptor.send(_:promise:context:)` no longer completes the same `EventLoopPromise` twice on a request-mutation failure. It previously called `promise?.fail(error)` and then `context.cancel(promise: promise)` with the already-failed promise, which traps in SwiftNIO and could crash the client on a token-fetch/attestation failure; it now cancels with a fresh (`nil`) promise.
- The trace-ID header is now emitted with an empty value (rather than omitted) when the SDK returns an empty trace ID on a protected request, providing backend evidence that Approov processing occurred (matches the token-header behaviour).

### Security
- TLS pinning is applied by `ApproovPinningVerifier`, new in this release: pin matching reads the current live Approov pins via `Approov.getPins`, and no blocking `prefetch()` is performed inside the handshake. Approov pin matching is skipped, with full OS certificate-chain validation still applied by NIOSSL, in two cases: empty-config **bypass mode**, logged at info because it is a configuration choice; and while the service layer is **not initialized**, logged at **error** because a channel built before `initialize()` completes handshakes without Approov pinning for its lifetime. The handshake is deliberately not failed in the second case, since that would break applications that build channels during startup — see USAGE.md "Initialize before creating channels". Pins are enforced at handshake time, so a tightened pin set takes effect on the next (re)connection; long-lived channels are not forcibly torn down.

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
