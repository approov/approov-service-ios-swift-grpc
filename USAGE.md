# Usage

This document describes the features and functionality of the Approov Service for gRPC-Swift. It explains how to initialize the service, use the `ApproovClientConnection` and `ApproovClientInterceptor` for protected gRPC requests, and configure optional features such as token binding, secure string substitution, custom headers, and other SDK helper methods. For a basic integration example, please refer to the [Quickstart guide](README.md).

## Swift Package Manager Import

```swift
import ApproovGRPC
```

## Basic Integration

For most integrations, you initialize `ApproovService` once at app startup, build an `ApproovClientConnection` channel, and configure your generated gRPC clients with the `ApproovClientInterceptor`.

```swift
import ApproovGRPC
import GRPC
import NIO

// Initialize the Approov service. Initialization can fail (bad config / SDK error), so guard it
// and fall back to bypass mode (empty config) rather than letting the app crash. See the README
// "INITIALIZING APPROOV SERVICE" section for the full pattern (device-ID + session correlation logging).
do {
    try ApproovService.initialize(config: "<config-string>")
} catch {
    // Continue UNPROTECTED — requests go out without Approov protection; the backend stays the enforcement point.
    try? ApproovService.initialize(config: "")
}

// Create an EventLoopGroup
let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

// Use ApproovClientConnection to construct the builder with TLS backed by NIOSSL
let builder = ApproovClientConnection.usingTLSBackedByNIOSSL(on: group)

// Create the channel
let channel = builder.connect(host: "api.example.com", port: 443)

// Provide the channel and interceptors to the generated client
let client = Your_YourClient(
    channel: channel,
    interceptors: ClientInterceptorFactory(hostname: "api.example.com")
)
```

---

## Empty Config Initialization

You can initialize the `ApproovService` with an empty configuration string if you want to use the service layer without active Approov protection. This is useful when you want to bypass Approov processing (e.g., during development or testing against local staging environments).

```swift
// Initialize with an empty string to operate in bypass mode
try? ApproovService.initialize(config: "")
```

When initialized with an empty configuration, the service layer operates as a plain pass-through. It will not perform token injection or secure string substitution, and dynamic pinning is skipped (though standard host certificate validation is still enforced by NIOSSL).

---

## Token Binding

Token Binding allows you to bind the Approov token to a specific piece of data, such as an authorization header or access token.

```swift
// Bind the Approov token to the Authorization header
ApproovService.bindHeader = "authorization"
```

If the value of the binding header is present in the request metadata, the SDK hashes the value and includes it in the `pay` claim of the issued Approov token. If the binding value changes, the SDK automatically fetches a new token with the updated binding on the next request.

---

## Custom Token Headers and Prefixes

By default, the Approov token is added to the `Approov-Token` header with no prefix. You can customize the header name and prepend an optional prefix (such as `"Bearer "`) using `approovTokenHeaderAndPrefix`:

```swift
// Customize token header and prefix
ApproovService.approovTokenHeaderAndPrefix = (approovTokenHeader: "authorization", approovTokenPrefix: "Bearer ")
```

---

## Secure String Substitution

You can use Approov to protect app secrets (such as API keys) by storing them securely in the Approov cloud and substituting them into headers at runtime.

First, register the header name and optional prefix (e.g. `"Bearer "`) that should be substituted:

```swift
// Register the authorization header for substitution
ApproovService.addSubstitutionHeader(header: "authorization", prefix: "Bearer ")
```

When a request is sent containing that header, the service layer uses the original header value (excluding the prefix) as a lookup key to retrieve the secure string from Approov. If successful, it substitutes the secure string value back into the header.

To remove a registered substitution header:

```swift
ApproovService.removeSubstitutionHeader(header: "authorization")
```

---

## Network Failure Behaviour and Fallback Status

By default, if the service layer cannot fetch an Approov token due to network issues (`noNetwork`, `poorNetwork`, `mitmDetected`), the request is blocked and an `ApproovError.networkingError` is thrown so it can be retried. This is the default `ApproovServiceMutator` behaviour.

If you need a request to proceed even when a real token is unavailable, enable `setUseApproovStatusIfNoToken`. The Approov fetch status string (e.g. `NO_NETWORK`) is then sent on the token header instead of a token, giving your backend visibility into why no token was supplied:

```swift
ApproovService.setUseApproovStatusIfNoToken(shouldUse: true)
```

> [!WARNING]
> Allowing requests to proceed without a valid token may permit a connection before dynamic pins have been received, potentially opening the channel to a Man-in-the-Middle (MITM) attack. Use with caution.

> [!NOTE]
> `proceedOnNetworkFail` is **deprecated** and no longer has any effect. Use `setUseApproovStatusIfNoToken(shouldUse:)` or a custom `ApproovServiceMutator` (below) instead.

---

## Custom Service Mutator

The `ApproovServiceMutator` protocol lets you override how the service layer reacts at key decision points — for example, to proceed on a specific fetch status, exclude certain RPCs, or force a particular token-header value. All protocol methods have default (fail-closed) implementations, so you override only what you need, then install your mutator:

```swift
final class MyMutator: ApproovServiceMutator {
    // e.g. proceed without a token when the SDK reports it is not available
    func handleInterceptorFetchTokenResult(_ results: ApproovTokenFetchResult, url: String) throws -> Bool {
        if results.status == .noApproovService { return false }   // forward unmodified
        return try ApproovServiceMutatorDefault.shared.handleInterceptorFetchTokenResult(results, url: url)
    }
}

ApproovService.setServiceMutator(MyMutator())
// Restore the default behaviour at any time:
ApproovService.setServiceMutator(nil)
```

You can also exclude specific RPCs from Approov mutation (pinning still applies) using exclusion regexes, which are matched against `https://<hostname><path>`:

```swift
ApproovService.addExclusionURLRegex(urlRegex: ".*/HealthCheck/.*")
```

---

## HTTP Message Signing

The service layer can add an RFC 9421 HTTP message signature to each protected request by installing the `ApproovDefaultMessageSigning` mutator. The signature binds the Approov token and selected request components together so the backend can verify integrity.

```swift
let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
ApproovService.setServiceMutator(signer)
```

The default configuration uses **install** (device-key, ECDSA P-256) signing and signs `@method`, `@target-uri`, the Approov token and trace-ID headers, and the `Authorization` header when present. To use **account** (HMAC-SHA256) signing instead:

```swift
let factory = ApproovDefaultMessageSigning
    .generateDefaultSignatureParametersFactory()
    .setUseAccountMessageSigning()
```

Two `Signature` / `Signature-Input` headers are added to the request metadata. Notes specific to gRPC:

- **No body digest.** gRPC carries no buffered request body at the interceptor layer, so a `Content-Digest` is never generated.
- **Fail-open.** If the SDK cannot provide a signature (e.g. the install key pair is unavailable, or no account key has been provisioned), or a returned signature cannot be decoded, the request proceeds **unsigned** and the reason is logged at error level. Only an unsupported algorithm (or a required body digest, which gRPC cannot produce) fails the request. Your backend decides whether to accept an unsigned request.
