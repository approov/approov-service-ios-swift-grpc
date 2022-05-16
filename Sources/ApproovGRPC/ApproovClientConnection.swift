// ApproovService for integrating Approov into apps using GRPC.
//
// MIT License
//
// Copyright (c) 2016-present, Critical Blue Ltd.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation
import GRPC
import Logging
import NIO
import NIOSSL

public class ApproovClientConnection {

    /// Returns an insecure `ClientConnection` builder which is *not configured with TLS*.
    public class func insecure(group: EventLoopGroup) -> ClientConnection.Builder {
        return ClientConnection.insecure(group: group)
    }

    /// Returns a `ClientConnection` builder configured with TLS.
    @available(
        *, deprecated,
        message: "Use one of 'usingPlatformAppropriateTLS(for:)', 'usingTLSBackedByNIOSSL(on:)' or 'usingTLSBackedByNetworkFramework(on:)' or 'usingTLS(on:with:)'"
    )
    public class func secure(approovConfigString: String?, group: EventLoopGroup) -> ApproovClientConnection.Builder
    {
        let builder = ClientConnection.secure(group: group)
        return ApproovClientConnection.Builder(delegate: builder)
    }

    /// Returns a `ClientConnection` builder configured with a TLS backend appropriate for the
    /// given `EventLoopGroup`.
    ///
    /// gRPC Swift offers two TLS 'backends'. The 'NIOSSL' backend is available on Darwin and Linux
    /// platforms and delegates to SwiftNIO SSL. On recent Darwin platforms (macOS 10.14+, iOS 12+,
    /// tvOS 12+, and watchOS 6+) the 'Network.framework' backend is available. The two backends have
    /// a number of incompatible configuration options and users are responsible for selecting the
    /// appropriate APIs. The TLS configuration options on the builder document which backends they
    /// support.
    ///
    /// TLS backends must also be used with an appropriate `EventLoopGroup` implementation. The
    /// 'NIOSSL' backend may be used either a `MultiThreadedEventLoopGroup` or a
    /// `NIOTSEventLoopGroup`. The 'Network.framework' backend may only be used with a
    /// `NIOTSEventLoopGroup`.
    ///
    /// This function returns a builder using the `NIOSSL` backend if a `MultiThreadedEventLoopGroup`
    /// is supplied and a 'Network.framework' backend if a `NIOTSEventLoopGroup` is used.
    public static func usingPlatformAppropriateTLS(approovConfigString: String?,
      for group: EventLoopGroup
    ) -> ApproovClientConnection.Builder {
        let builder = ClientConnection.usingPlatformAppropriateTLS(for: group)
        return ApproovClientConnection.Builder(delegate: builder)
    }

    /// Returns a `ClientConnection` builder configured with the 'NIOSSL' TLS backend.
    ///
    /// This builder may use either a `MultiThreadedEventLoopGroup` or a `NIOTSEventLoopGroup` (or an
    /// `EventLoop` from either group).
    ///
    /// - Parameter group: The `EventLoopGroup` use for the connection.
    /// - Returns: A builder for a connection using the NIOSSL TLS backend.
    public static func usingTLSBackedByNIOSSL(approovConfigString: String?,
        on group: EventLoopGroup
    ) -> ApproovClientConnection.Builder {
        let builder = ClientConnection.usingTLSBackedByNIOSSL(on: group)
        return ApproovClientConnection.Builder(delegate: builder)
    }

    #if canImport(Network)
    /// Returns a `ClientConnection` builder configured with the Network.framework TLS backend.
    ///
    /// This builder must use a `NIOTSEventLoopGroup` (or an `EventLoop` from a
    /// `NIOTSEventLoopGroup`).
    ///
    /// - Parameter group: The `EventLoopGroup` use for the connection.
    /// - Returns: A builder for a connection using the Network.framework TLS backend.
    @available(*, unavailable, message: "Network.framework is not supported by ApproovGRPC. Consider using usingTLSBackedByNIOSSL()")
    public static func usingTLSBackedByNetworkFramework(approovConfigString: String?,
        on group: EventLoopGroup
    ) -> ApproovClientConnection.Builder {
        // Network.framework is not supported by ApproovGRPC
        abort()
        // ensureApproovInitialised(approovConfigString: approovConfigString)
        // let builder = ClientConnection.usingTLSBackedByNetworkFramework(on: group)
        // return ApproovClientConnection.Builder(delegate: builder)
    }
    #endif

    /// Returns a `ClientConnection` builder configured with the TLS backend appropriate for the
    /// provided configuration and `EventLoopGroup`.
    ///
    /// - Important: The caller is responsible for ensuring the provided `configuration` may be used
    ///   the the `group`.
    public static func usingTLS(approovConfigString: String?,
        with configuration: GRPCTLSConfiguration,
        on group: EventLoopGroup
    ) -> ApproovClientConnection.Builder {
        let builder = ClientConnection.usingTLS(with: configuration, on: group)
        return ApproovClientConnection.Builder(delegate: builder)
    }

}

extension ApproovClientConnection {

    public class Builder {

        // Wrapped secure connection builder
        private var delegate: ClientConnection.Builder.Secure

        init(delegate: ClientConnection.Builder.Secure) {
            self.delegate = delegate
        }

        // Optional user defined custom verification callback
        private var niosslVerificationCallback: NIOSSLCustomVerificationCallback?

        // Name of the remote host of the connection
        private var hostname: String?

        /// Connect to `host` on `port`.
        public func connect(host: String, port: Int) -> ClientConnection {
            let securityFrameworkValidator = SecurityFrameworkValidator(trustRoots: .default, additionalTrustRoots: [], hostname: host)
            let pinningVerifier = ApproovPinningVerifier(securityFrameworkValidator: securityFrameworkValidator)
            delegate.withTLSCustomVerificationCallback(pinningVerifier.verifyPinning)
            hostname = host
            return delegate.connect(host: host, port: port)
        }

        /// Connect to `host` on port 443.
        public func connect(host: String) -> ClientConnection {
            return connect(host: host, port: 443)
        }

    }

}

extension ApproovClientConnection.Builder {

  /// Sets the initial connection backoff. That is, the initial time to wait before re-attempting to
  /// establish a connection. Jitter will *not* be applied to the initial backoff. Defaults to
  /// 1 second if not set.
  @discardableResult
  public func withConnectionBackoff(initial amount: TimeAmount) -> Self {
    delegate.withConnectionBackoff(initial: amount)
    return self
  }

  /// Set the maximum connection backoff. That is, the maximum amount of time to wait before
  /// re-attempting to establish a connection. Note that this time amount represents the maximum
  /// backoff *before* jitter is applied. Defaults to 120 seconds if not set.
  @discardableResult
  public func withConnectionBackoff(maximum amount: TimeAmount) -> Self {
    delegate.withConnectionBackoff(maximum: amount)
    return self
  }

  /// Backoff is 'jittered' to randomise the amount of time to wait before re-attempting to
  /// establish a connection. The jittered backoff will be no more than `jitter ⨯ unjitteredBackoff`
  /// from `unjitteredBackoff`. Defaults to 0.2 if not set.
  ///
  /// - Precondition: `0 <= jitter <= 1`
  @discardableResult
  public func withConnectionBackoff(jitter: Double) -> Self {
    delegate.withConnectionBackoff(jitter: jitter)
    return self
  }

  /// The multiplier for scaling the unjittered backoff between attempts to establish a connection.
  /// Defaults to 1.6 if not set.
  @discardableResult
  public func withConnectionBackoff(multiplier: Double) -> Self {
    delegate.withConnectionBackoff(multiplier: multiplier)
    return self
  }

  /// The minimum timeout to use when attempting to establishing a connection. The connection
  /// timeout for each attempt is the larger of the jittered backoff and the minimum connection
  /// timeout. Defaults to 20 seconds if not set.
  @discardableResult
  public func withConnectionTimeout(minimum amount: TimeAmount) -> Self {
    delegate.withConnectionTimeout(minimum: amount)
    return self
  }

  /// Sets the initial and maximum backoff to given amount. Disables jitter and sets the backoff
  /// multiplier to 1.0.
  @discardableResult
  public func withConnectionBackoff(fixed amount: TimeAmount) -> Self {
    delegate.withConnectionBackoff(fixed: amount)
    return self
  }

  /// Sets the limit on the number of times to attempt to re-establish a connection. Defaults
  /// to `.unlimited` if not set.
  @discardableResult
  public func withConnectionBackoff(retries: ConnectionBackoff.Retries) -> Self {
    delegate.withConnectionBackoff(retries: retries)
    return self
  }

  /// Sets whether the connection should be re-established automatically if it is dropped. Defaults
  /// to `true` if not set.
  @discardableResult
  public func withConnectionReestablishment(enabled: Bool) -> Self {
    delegate.withConnectionReestablishment(enabled: enabled)
    return self
  }

  /// Sets a custom configuration for keepalive
  /// The defaults for client and server are determined by the gRPC keepalive
  /// [documentation] (https://github.com/grpc/grpc/blob/master/doc/keepalive.md).
  @discardableResult
  public func withKeepalive(_ keepalive: ClientConnectionKeepalive) -> Self {
    delegate.withKeepalive(keepalive)
    return self
  }

  /// The amount of time to wait before closing the connection. The idle timeout will start only
  /// if there are no RPCs in progress and will be cancelled as soon as any RPCs start. If a
  /// connection becomes idle, starting a new RPC will automatically create a new connection.
  /// Defaults to 30 minutes if not set.
  @discardableResult
  public func withConnectionIdleTimeout(_ timeout: TimeAmount) -> Self {
    delegate.withConnectionIdleTimeout(timeout)
    return self
  }

  /// The behavior used to determine when an RPC should start. That is, whether it should wait for
  /// an active connection or fail quickly if no connection is currently available. Calls will
  /// use `.waitsForConnectivity` by default.
  @discardableResult
  public func withCallStartBehavior(_ behavior: CallStartBehavior) -> Self {
    delegate.withCallStartBehavior(behavior)
    return self
  }

  /// Sets the client error delegate.
  @discardableResult
  public func withErrorDelegate(_ delegate: ClientErrorDelegate?) -> Self {
    self.delegate.withErrorDelegate(delegate)
    return self
  }

  /// Sets the client connectivity state delegate and the `DispatchQueue` on which the delegate
  /// should be called. If no `queue` is provided then gRPC will create a `DispatchQueue` on which
  /// to run the delegate.
  @discardableResult
  public func withConnectivityStateDelegate(
    _ delegate: ConnectivityStateDelegate?,
    executingOn queue: DispatchQueue? = nil
  ) -> Self {
    self.delegate.withConnectivityStateDelegate(delegate)
    return self
  }

// MARK: - Common TLS options

  /// Sets a server hostname override to be used for the TLS Server Name Indication (SNI) extension.
  /// The hostname from `connect(host:port)` is for TLS SNI if this value is not set and hostname
  /// verification is enabled.
  ///
  /// - Note: May be used with the 'NIOSSL' and 'Network.framework' TLS backend.
  /// - Note: `serverHostnameOverride` may not be `nil` when using the 'Network.framework' backend.
  @discardableResult
  public func withTLS(serverHostnameOverride: String?) -> Self {
    delegate.withTLS(serverHostnameOverride: serverHostnameOverride)
    return self
  }

// MARK: - NIOSSL TLS backend options

  /// Sets the sources of certificates to offer during negotiation. No certificates are offered
  /// during negotiation by default.
  ///
  /// - Note: May only be used with the 'NIOSSL' TLS backend.
  @discardableResult
  public func withTLS(certificateChain: [NIOSSLCertificate]) -> Self {
    delegate.withTLS(certificateChain: certificateChain)
    return self
  }

  /// Sets the private key associated with the leaf certificate.
  ///
  /// - Note: May only be used with the 'NIOSSL' TLS backend.
  @discardableResult
  public func withTLS(privateKey: NIOSSLPrivateKey) -> Self {
    delegate.withTLS(privateKey: privateKey)
    return self
  }

  /// Sets the trust roots to use to validate certificates. This only needs to be provided if you
  /// intend to validate certificates. Defaults to the system provided trust store (`.default`) if
  /// not set.
  ///
  /// - Note: May only be used with the 'NIOSSL' TLS backend.
  @discardableResult
  public func withTLS(trustRoots: NIOSSLTrustRoots) -> Self {
    delegate.withTLS(trustRoots: trustRoots)
    return self
  }

  /// Whether to verify remote certificates. Defaults to `.fullVerification` if not otherwise
  /// configured.
  ///
  /// - Note: May only be used with the 'NIOSSL' TLS backend.
  @discardableResult
  public func withTLS(certificateVerification: CertificateVerification) -> Self {
    delegate.withTLS(certificateVerification: certificateVerification)
    return self
  }

  /// A custom verification callback that allows completely overriding the certificate verification logic.
  ///
  /// - Note: May only be used with the 'NIOSSL' TLS backend.
  /// - Note: The `callback` will be called from the ApproovPinningVerifier before performing its own verification
  @discardableResult
  public func withTLSCustomVerificationCallback(
    _ callback: @escaping NIOSSLCustomVerificationCallback
  ) -> Self {
    self.niosslVerificationCallback = callback
    return self
  }

// MARK: - Network.framework TLS backend options

#if canImport(Network)
  /// Update the local identity.
  ///
  /// - Note: May only be used with the 'Network.framework' TLS backend.
  @discardableResult
  @available(*, unavailable, message: "Network.framework is not supported by ApproovGRPC. Consider using NIOSSL.")
  public func withTLS(localIdentity: SecIdentity) -> Self {
    // Network.framework is not supported by ApproovGRPC
    abort()
    // delegate.withTLS(localIdentity: localIdentity)
    // return self
  }

  /// Update the callback used to verify a trust object during a TLS handshake.
  ///
  /// - Note: May only be used with the 'Network.framework' TLS backend.
  @discardableResult
  @available(*, unavailable, message: "Network.framework is not supported by ApproovGRPC. Consider using NIOSSL.")
  public func withTLSHandshakeVerificationCallback(
    on queue: DispatchQueue,
    verificationCallback callback: @escaping sec_protocol_verify_t
  ) -> Self {
    // Network.framework is not supported by ApproovGRPC
    abort()
    // self.networkFrameworkVerificationCallback = callback
    // return self
  }
#endif

  /// Sets the HTTP/2 flow control target window size. Defaults to 8MB if not explicitly set.
  /// Values are clamped between 1 and 2^31-1 inclusive.
  @discardableResult
  public func withHTTPTargetWindowSize(_ httpTargetWindowSize: Int) -> Self {
    delegate.withHTTPTargetWindowSize(httpTargetWindowSize)
    return self
  }

  /// Sets the maximum size of an HTTP/2 frame in bytes which the client is willing to receive from
  /// the server. Defaults to 16384. Value are clamped between 2^14 and 2^24-1 octets inclusive
  /// (the minimum and maximum permitted values per RFC 7540 § 4.2).
  ///
  /// Raising this value may lower CPU usage for large message at the cost of increasing head of
  /// line blocking for small messages.
  @discardableResult
  public func withHTTPMaxFrameSize(_ httpMaxFrameSize: Int) -> Self {
    delegate.withHTTPMaxFrameSize(httpMaxFrameSize)
    return self
  }

  /// Sets the maximum message size the client is permitted to receive in bytes.
  ///
  /// - Precondition: `limit` must not be negative.
  @discardableResult
  public func withMaximumReceiveMessageLength(_ limit: Int) -> Self {
    delegate.withMaximumReceiveMessageLength(limit)
    return self
  }

  /// Sets a logger to be used for background activity such as connection state changes. Defaults
  /// to a no-op logger if not explicitly set.
  ///
  /// Note that individual RPCs will use the logger from `CallOptions`, not the logger specified
  /// here.
  @discardableResult
  public func withBackgroundActivityLogger(_ logger: Logger) -> Self {
    delegate.withBackgroundActivityLogger(logger)
    return self
  }

  /// A channel initializer which will be run after gRPC has initialized each channel. This may be
  /// used to add additional handlers to the pipeline and is intended for debugging.
  ///
  /// - Warning: The initializer closure may be invoked *multiple times*.
  @discardableResult
  public func withDebugChannelInitializer(
    _ debugChannelInitializer: @escaping (Channel) -> EventLoopFuture<Void>
  ) -> Self {
    delegate.withDebugChannelInitializer(debugChannelInitializer)
    return self
  }
}
