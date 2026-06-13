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

If an attempt is made to initialize with a **different** non-empty config, an `ApproovError.configurationError` is raised. Passing an empty config string bypasses Approov SDK initialization, operating in bypass mode.

### proceedOnNetworkFail
Controls whether network calls should proceed when Approov cannot fetch due to network errors.

```swift
ApproovService.proceedOnNetworkFail = true
let proceed = ApproovService.proceedOnNetworkFail
```

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

### updateRequestHeaders(headers:hostname:)
Updates a set of `HPACKHeaders` with Approov protection and secure string substitutions. This is a synchronous blocking method and must not be called from the UI thread.

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

### getMessageSignature(message:)
Gets the signature for the given message using the account-specific HMAC-SHA256 signing key.

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

## ApproovClientConnection

`ApproovClientConnection` provides factory functions that return a `ClientConnection.Builder` pre-configured to use the `ApproovPinningVerifier` for certificate trust evaluation.

### usingTLSBackedByNIOSSL(on:)
Creates a gRPC connection builder configured to use TLS backed by NIOSSL with Approov pinning.

```swift
let builder = ApproovClientConnection.usingTLSBackedByNIOSSL(on: eventLoopGroup)
```

---

## ApproovClientInterceptor

An interceptor that automatically mutates request metadata to inject Approov tokens and perform secure string substitutions.

```swift
let interceptor = ApproovClientInterceptor<Request, Reply>(hostname: "api.example.com")
```
