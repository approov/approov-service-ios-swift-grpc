# Approov Service for gRPC-Swift

![Swift](https://img.shields.io/badge/Swift-5.8%2B-F05138?logo=swift&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-11%2B-000000?logo=apple&logoColor=white)
![SwiftPM](https://img.shields.io/github/v/tag/approov/approov-service-ios-swift-grpc?logo=swift&logoColor=white&label=SwiftPM&color=F05138)
![Message Signing](https://img.shields.io/badge/Message%20Signing-RFC%209421-1f6feb)
![Build](https://github.com/approov/approov-service-ios-swift-grpc/actions/workflows/build_and_test.yml/badge.svg)

A wrapper for the [Approov SDK](https://github.com/approov/approov-ios-sdk) to enable easy integration when using [`gRPC-Swift`](https://github.com/grpc/grpc-swift) for making the API calls that you wish to protect with Approov. In order to use this you will need a trial or paid [Approov](https://www.approov.io) account.

This page provides the steps for integrating Approov into your app. Additionally, a step-by-step tutorial guide using our [Shapes App Example](https://github.com/approov/quickstart-ios-swift-grpc/blob/master/SHAPES-EXAMPLE.md) is also available.

To follow this guide you should have received an onboarding email for a trial or paid Approov account.

## ADDING APPROOV SERVICE DEPENDENCY
The Approov integration is available via the [Swift Package Manager](https://www.swift.org/package-manager/). This allows inclusion into the project by adding a dependency on the `ApproovGRPC` package in Xcode. In the search box of the add packages dialog, enter the URL of the git repository `https://github.com/approov/approov-service-ios-swift-grpc.git` and choose the version you wish to use.

The `ApproovGRPC` package is an open-source wrapper layer that allows you to easily use Approov with gRPC-Swift. It has a further dependency on the closed-source [`Approov` iOS SDK](https://github.com/approov/approov-ios-sdk).

Once added, import the module wherever you use it:

```swift
import ApproovGRPC
import Approov
```

## INITIALIZING APPROOV SERVICE
In order to use the `ApproovService` you must initialize it when your app is created, before constructing any `ApproovClientConnection`. Initialization can fail (bad config, SDK error) and `initialize(config:)` is a throwing call, so wrap it in `do/catch` and make sure your app survives a failure rather than crashing:

```swift
import ApproovGRPC
import Foundation
import os

let log = Logger(subsystem: "com.yourcompany.yourapp", category: "approov")

// An app-generated id used to correlate this install/session across your own app logs and
// your backend. Use a UUID, or any session/user identifier you already have — it is NOT an
// Approov secret.
let correlationId = UUID().uuidString

do {
    try ApproovService.initialize(config: "<enter-your-config-string-here>")
    // Confirm Approov is actually active before treating it as enabled, then log identifiers
    // for correlation / observability.
    if ApproovService.isApproovEnabled() {
        let deviceID = (try? ApproovService.getDeviceID()) ?? "unknown"
        log.info("Approov initialized; deviceID=\(deviceID, privacy: .public) session=\(correlationId, privacy: .public)")
    } else {
        log.notice("Approov initialized in bypass mode (no protection); session=\(correlationId, privacy: .public)")
    }
} catch {
    // Initialization failed — log it and continue UNPROTECTED so the app still works.
    // Re-initializing with an empty config string enters bypass mode (initialized, but no
    // Approov token injection, pinning, or secret substitution).
    log.error("Approov init failed (session=\(correlationId, privacy: .public)); continuing unprotected: \(String(describing: error), privacy: .public)")
    try? ApproovService.initialize(config: "")
}
```

The `<enter-your-config-string-here>` is a custom string that configures your Approov account access. This will have been provided in your Approov onboarding email.

On success the example logs the Approov **device ID** (`getDeviceID()`) and an **app-generated session/correlation id** (a UUID, or any session/user identifier you use) so a given install can be correlated across your app logs, backend, and the Approov [Live Metrics](https://approov.io/docs/latest/approov-usage-documentation/#metrics-graphs). If initialization fails, the example re-initializes with an empty config so the app keeps working — but those requests go out **without Approov protection**, so treat the backend as the enforcement point.

## USING APPROOV SERVICE
The `ApproovClientConnection` class mimics the interface and functionality of the `ClientConnection` class provided by `gRPC-Swift`, but also sets up TLS pinning and trust verification backed by NIOSSL for the gRPC channel created by an `ApproovClientConnection.Builder`.

The simplest way to use the `ApproovClientConnection` class is to replace `ClientConnection` with `ApproovClientConnection`:

```swift
import ApproovGRPC
import GRPC

// Use ApproovClientConnection to construct the builder
let builder = ApproovClientConnection.usingTLSBackedByNIOSSL(on: group)
```

You can then create secure pinned gRPC channels by using the returned builder instead of the usual `ClientConnection.Builder`:

```swift
let channel = builder.connect(host: hostname, port: port)
```

Approov-enable gRPC clients by adding a `ClientInterceptor` factory. The factory should return an `ApproovClientInterceptor` for any gRPC call that requires Approov protection. The `ApproovClientInterceptor` adds an `Approov-Token` header to a gRPC request and may also substitute header values when using secrets protection.

```swift
// Provide the channel and interceptor factory to the generated client.
client = Your_YourClient(channel: channel, interceptors: ClientInterceptorFactory(hostname: hostname))
```

The required `ClientInterceptorFactory` looks similar to this template and must be implemented specifically to match the code generated by the gRPC `protoc` compiler for your protocol definitions (`.proto` files). In the example below, all types starting with `Your_` would have been automatically generated. Note that an Approov interceptor needs to be returned only for gRPCs that should be protected with an Approov token.

```swift
import ApproovGRPC
import Foundation
import GRPC

class ClientInterceptorFactory: Your_YourClientInterceptorFactoryProtocol {

    // hostname/domain for which to add an Approov token to protected gRPC requests
    let hostname: String

    init(hostname: String) {
        self.hostname = hostname
    }

    /// - Returns: Interceptors to use when invoking a gRPC that does not require Approov protection.
    func makeUnprotectedInterceptors() -> [ClientInterceptor<Your_UnprotectedRequest, Your_UnprotectedReply>] {
        return []
    }

    /// - Returns: Interceptors to use when invoking a gRPC that requires Approov protection.
    func makeProtectedInterceptors() -> [ClientInterceptor<Your_ProtectedRequest, Your_ProtectedReply>] {
        return [ApproovClientInterceptor<Your_ProtectedRequest, Your_ProtectedReply>(hostname: hostname)]
    }
}
```

### Error Messages
The `ApproovService` functions may throw specific errors to provide additional information:

* `permanentError`: Feature is not enabled or a configuration feature is unsupported.
* `rejectionError`: Attestation has been rejected. The `ARC` and `rejectionReasons` may contain specific device information that would help troubleshooting.
* `networkingError`: Generally can be retried since it is a temporary network issue.
* `pinningError`: Certificate pinning validation error.
* `configurationError`: Configuration feature is disabled or wrongly configured (e.g. attempting to initialize with a different configuration from a previous initialization).
* `initializationFailure`: ApproovService failed to initialize.

## CHECKING IT WORKS
Initially you won't have set which API domains to protect, so the interceptor will not add anything. It will have called Approov though and made contact with the Approov cloud service. You will see logging from Approov saying `UNKNOWN_URL`.

Your Approov onboarding email should contain a link allowing you to access [Live Metrics Graphs](https://approov.io/docs/latest/approov-usage-documentation/#metrics-graphs). After you've run your app with Approov integration you should be able to see the results in the live metrics within a minute or so. At this stage you could even release your app to get details of your app population and the attributes of the devices they are running upon.

## NEXT STEPS
To actually protect your APIs and/or secrets there are some further steps. Approov provides two different options for protection:

* [API PROTECTION](https://github.com/approov/quickstart-ios-swift-grpc/blob/master/API-PROTECTION.md): You should use this if you control the backend API(s) being protected and are able to modify them to ensure that a valid Approov token is being passed by the app. An [Approov Token](https://approov.io/docs/latest/approov-usage-documentation/#approov-tokens) is a short-lived cryptographically signed JWT proving the authenticity of the call.

* [SECRETS PROTECTION](https://github.com/approov/quickstart-ios-swift-grpc/blob/master/SECRETS-PROTECTION.md): This allows app secrets, including API keys for 3rd party services, to be protected so that they no longer need to be included in the released app code. These secrets are only made available to valid apps at runtime.

Note that it is possible to use both approaches side-by-side in the same app.

---

## Useful Links

- [Approov SDK](https://github.com/approov/approov-ios-sdk)
- [gRPC-Swift Documentation](https://github.com/grpc/grpc-swift)
- [Approov Website](https://www.approov.io)
- [Quickstart Guide](https://github.com/approov/quickstart-ios-swift-grpc)
- [Shapes App Example](https://github.com/approov/quickstart-ios-swift-grpc/blob/master/SHAPES-EXAMPLE.md)
- [Changelog](CHANGELOG.md)
- [Reference Documentation](REFERENCE.md)
- [Usage Guide](USAGE.md)
