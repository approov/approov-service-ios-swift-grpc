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

// Initialize the Approov service
try! ApproovService.initialize(config: "<config-string>")

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

## Proceed on Network Failure

By default, if the service layer cannot fetch an Approov token due to network issues (such as `noNetwork` or `poorNetwork`), the request is blocked and an `ApproovError.networkingError` is thrown. You can allow requests to proceed anyway (without the token header) by setting `proceedOnNetworkFail`:

```swift
// Proceed even if token fetch fails due to network issues
ApproovService.proceedOnNetworkFail = true
```

> [!WARNING]
> Use this with caution, as proceeding on network failures might allow connections before dynamic pins have been received, potentially opening the channel to a Man-in-the-Middle (MITM) attack.
