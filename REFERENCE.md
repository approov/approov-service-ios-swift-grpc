# Reference

This provides a reference for the public methods and properties defined on `ApproovService` and the types exposed by the Approov Service for gRPC-Swift. These are available when you import the module:

```swift
import ApproovGRPC
```

Most methods either throw an `ApproovError` or return the expected result. The error cases to be aware of are:

- `networkingError`: A temporary networking issue; offer a retry.
- `rejectionError`: Attestation rejected; includes ARC and rejection reasons if enabled.
- `permanentError` / `configurationError` / `initializationFailure` / `runtimeError`: Non-retryable in normal flows.

---

## ApproovService

### initialize(config:comment:)
Initializes the SDK with the config obtained using `approov sdk -getConfigString` or in the original onboarding email. In the vast majority of integrations, `initialize` should be called **once** during app startup.

```swift
try ApproovService.initialize(config: "<config-string>")
```

An optional `comment` parameter is forwarded directly to the native SDK. The `comment` should be `nil` unless you are performing an explicit SDK reinitialization (e.g. `"options:no-install-key"` or `"reinit"`).

```swift
try ApproovService.initialize(config: "<config-string>", comment: "options:no-install-key")
```

If an attempt is made to initialize with a **different** non-empty config, an `ApproovError.configurationError` is raised. Passing an empty config string bypasses Approov SDK initialization, operating in bypass mode. Each successful `initialize(...)` resets the active service mutator to the default.

### isInitialized()
Returns whether the service layer has been initialized. Returns `true` even for empty-config bypass mode.

```swift
if ApproovService.isInitialized() { /* ... */ }
```

### isApproovEnabled()
Returns whether Approov protection is enabled — i.e. the layer was initialized with a valid, non-empty config. Returns `false` in bypass mode or when not initialized.

```swift
if ApproovService.isApproovEnabled() { /* ... */ }
```

### proceedOnNetworkFail
**Deprecated and no longer has any effect.** Network-failure handling is now decided by the active `ApproovServiceMutator`. To allow requests to proceed when a token cannot be fetched, install a custom mutator or enable `setUseApproovStatusIfNoToken(shouldUse:)`.

### bindHeader
Sets a binding header that must be present on all requests using the Approov service. A hash of the header value is supplied to Approov so the issued token is bound to the value.

```swift
ApproovService.bindHeader = "authorization"
let header = ApproovService.bindHeader
```

> **Important:** Automatic token binding (via `bindHeader`) and manual token binding (via `setDataHashInToken`) must **not** be mixed. Use one mechanism or the other.

### approovTokenHeaderAndPrefix
Sets the header that the Approov token is added on, as well as an optional prefix String (such as "Bearer "). By default the token is provided on "Approov-Token" with no prefix.

```swift
ApproovService.approovTokenHeaderAndPrefix = (
    approovTokenHeader: "Approov-Token",
    approovTokenPrefix: ""
)
```

### setApproovTraceIDHeader(header:) / getApproovTraceIDHeader()
Sets the header name used to carry the optional Approov trace ID (default `Approov-TraceID`). Pass `nil` to disable emitting the trace-ID header.

```swift
ApproovService.setApproovTraceIDHeader(header: "Approov-TraceID")
```

### setUseApproovStatusIfNoToken(shouldUse:) / getUseApproovStatusIfNoToken()
When enabled, and a request is allowed to proceed without a real token, the Approov fetch status string (e.g. `NO_NETWORK`) is injected into the token header instead, giving the backend visibility into the failure reason.

```swift
ApproovService.setUseApproovStatusIfNoToken(shouldUse: true)
```

### setServiceMutator(_:) / getServiceMutator()
Installs the active `ApproovServiceMutator` used to override the default request-processing decisions (see [ApproovServiceMutator](#approovservicemutator)). Pass `nil` to restore the default mutator. The mutator is also reset to the default by `initialize(...)`.

```swift
ApproovService.setServiceMutator(myMutator)   // or nil to reset
```

### addExclusionURLRegex(urlRegex:) / removeExclusionURLRegex(urlRegex:)
Registers (or removes) a regular expression; requests whose target (matched against `https://<hostname><path>`) matches an exclusion regex are forwarded **without** Approov mutation. Note that gRPC pinning still applies to excluded hosts.

```swift
ApproovService.addExclusionURLRegex(urlRegex: ".*/health/.*")
```

### loggingLevel
Controls the verbosity of the service layer's `os_log` output (`.off`, `.error`, `.warning`, `.info`, `.debug`).

```swift
ApproovService.loggingLevel = .debug
```

### setDevKey(devKey:)
Sets a development key indicating that the app is a development version.

```swift
ApproovService.setDevKey(devKey: "<dev-key>")
```

### prefetch()
Permits a token to be prefetched as early as possible (e.g. at startup) to hide initial fetch latency.

```swift
ApproovService.prefetch()
```

### updateRequestHeaders(headers:hostname:path:)
Updates a set of `HPACKHeaders` with Approov protection (token header, optional trace-ID header), secure string substitutions, and any mutator-driven processing (including message signing). This is a synchronous blocking method and must not be called from the UI thread. The optional `path` is the RPC path (e.g. `"/package.Service/Method"`); `ApproovClientInterceptor` supplies it automatically from `context.path` so that message signing can include the `@path` / `@target-uri` components.

```swift
let updatedHeaders = try ApproovService.updateRequestHeaders(headers: headers, hostname: "api.example.com")
```

### addSubstitutionHeader(header:prefix:)
Adds a header name to be subject to secure string substitution.

```swift
ApproovService.addSubstitutionHeader(header: "Api-Key", prefix: nil)
```

### removeSubstitutionHeader(header:)
Removes a header previously added for substitution.

```swift
ApproovService.removeSubstitutionHeader(header: "Api-Key")
```

### getDeviceID()
Gets the device ID used by Approov.

```swift
let deviceId = try ApproovService.getDeviceID()
```

### setDataHashInToken(data:)
Directly sets the data hash for subsequently fetched Approov tokens. This is the manual alternative to `bindHeader`; the two must not be mixed.

```swift
ApproovService.setDataHashInToken(data: "<data-to-hash>")
```

### fetchToken(url:)
Performs a token fetch for the given URL. Throws `ApproovError` if the fetch fails.

```swift
let token = try ApproovService.fetchToken(url: "https://example.com/api")
```

### getAccountMessageSignature(message:) / getInstallMessageSignature(message:)
Returns a base64-encoded message signature, or `nil` if no signature is available (no prior fetch, the feature is not enabled, or the layer is in bypass mode). `getAccountMessageSignature` uses the account-specific HMAC-SHA256 key; `getInstallMessageSignature` uses the device install key (ECDSA P-256, ASN.1 DER). An Approov token should always be included in the signed message to prevent replay.

```swift
let accountSig = ApproovService.getAccountMessageSignature(message: "message")
let installSig = ApproovService.getInstallMessageSignature(message: "message")
```

### getMessageSignature(message:)
*Deprecated.* Alias for `getAccountMessageSignature(message:)` that throws `ApproovError` if no signature is available. Prefer the explicit account / install accessors above.

```swift
let signature = try ApproovService.getMessageSignature(message: "message")
```

### fetchSecureString(key:newDef:)
Fetches a secure string with the given key.

```swift
let value = try ApproovService.fetchSecureString(key: "api_key", newDef: nil)
```

### fetchCustomJWT(payload:)
Fetches a custom JWT with the given payload.

```swift
let jwt = try ApproovService.fetchCustomJWT(payload: "{\"claims\":{}}")
```

### precheck()
Performs a precheck to verify if the app will pass attestation. Internally this performs a secure string fetch with an `UNKNOWN_KEY`. Throws `ApproovError` (e.g. `rejectionError` if the app fails attestation).

```swift
try ApproovService.precheck()
```

### getLastARC()
Gets the last Attestation Response Code.

```swift
let arc = ApproovService.getLastARC()
```

### setInstallAttributes(attrs:)
Sets installation-specific attributes in the token.

```swift
ApproovService.setInstallAttributes(attrs: "my-attributes")
```

---

## ApproovServiceMutator

`ApproovServiceMutator` is a protocol that lets you override the default decisions made while processing a request and the direct attestation helpers. All methods have default implementations, so you only override the ones you need. Install one with `ApproovService.setServiceMutator(_:)`.

The **default** behaviour is fail-closed: any non-success token-fetch status fails the request, except `NO_APPROOV_SERVICE` / `UNKNOWN_URL` / `UNPROTECTED_URL`, which proceed without a token.

```swift
public protocol ApproovServiceMutator {
    // Direct-fetch result handlers (precheck / fetchToken / fetchSecureString / fetchCustomJWT)
    func handlePrecheckResult(_ approovResults: ApproovTokenFetchResult) throws
    func handleFetchTokenResult(_ approovResults: ApproovTokenFetchResult) throws
    func handleFetchSecureStringResult(_ approovResults: ApproovTokenFetchResult, operation: String, key: String) throws
    func handleFetchCustomJWTResult(_ approovResults: ApproovTokenFetchResult) throws

    // Interceptor hooks
    func handleInterceptorShouldProcessRequest(_ request: ApproovRequest) throws -> Bool
    func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult, url: String) throws -> Bool
    func handleInterceptorHeaderSubstitutionResult(_ approovResults: ApproovTokenFetchResult, header: String) throws -> Bool
    func handleInterceptorProcessedRequest(_ request: ApproovRequest, changes: ApproovRequestMutations) throws -> ApproovRequest

    // Pinning
    func handlePinningShouldProcessRequest(hostname: String) -> Bool
}
```

Supporting types: `ApproovRequest` (`hostname`, `headers: HPACKHeaders`, optional `path`), `ApproovUpdateResponse`, `ApproovFetchDecision` (`ShouldProceed` / `ShouldRetry` / `ShouldFail` / `ShouldIgnore`), and `ApproovRequestMutations`. `ApproovServiceMutatorDefault.shared` is the default. Note that gRPC has no query-parameter substitution or request body, so those hooks are not present.

```swift
ApproovService.setServiceMutator(MyMutator())
```

## ApproovDefaultMessageSigning

`ApproovDefaultMessageSigning` is an `ApproovServiceMutator` that adds RFC 9421 HTTP message signing to Approov-processed gRPC requests. Install it as the service mutator:

```swift
let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
ApproovService.setServiceMutator(signer)
```

It adds `Signature` and `Signature-Input` headers (RFC 8941 byte-sequence form, e.g. `install=:<base64>:`) over the configured components. The default factory signs `@method`, `@target-uri`, the Approov token and trace-ID headers, and the `Authorization` header when present, using install (ECDSA P-256) signing.

- **No body digest:** gRPC carries no buffered body at the interceptor layer, so `Content-Digest` is never generated. (`setBodyDigestConfig` exists for API parity; a *required* digest would fail closed.)
- **Fail-open:** if the SDK cannot provide a signature, or a returned signature cannot be base64/ASN.1-decoded, the request proceeds **unsigned** and the reason is logged at error level. The only fail-closed cases are an unsupported algorithm and a required body digest.

Configuration via `SignatureParametersFactory`: `setBaseParameters`, `setUseInstallMessageSigning` / `setUseAccountMessageSigning`, `setAddCreated`, `setExpiresLifetime`, `setAddApproovTokenHeader`, `setAddApproovTraceIDHeader`, `addOptionalHeaders`. Per-host factories can be registered with `putHostFactory(hostName:factory:)`.

Useful constants: `ALG_ES256`, `ALG_HS256`, `DIGEST_SHA256`, `DIGEST_SHA512`.

---

## ApproovClientConnection

`ApproovClientConnection` provides factory functions that return a `ClientConnection.Builder` pre-configured to use the `ApproovPinningVerifier` for certificate trust evaluation.

### usingTLSBackedByNIOSSL(on:)
Creates a gRPC connection builder configured to use TLS backed by NIOSSL with Approov pinning.

```swift
let builder = ApproovClientConnection.usingTLSBackedByNIOSSL(on: eventLoopGroup)
```

---

## ApproovClientInterceptor

An interceptor that automatically mutates request metadata to inject Approov tokens, emit the trace-ID header, perform secure string substitutions, and apply any configured message signing. It forwards the RPC path (`context.path`) into request processing so message signing can include the `@path` / `@target-uri` components.

```swift
let interceptor = ApproovClientInterceptor<Request, Reply>(hostname: "api.example.com")
```
