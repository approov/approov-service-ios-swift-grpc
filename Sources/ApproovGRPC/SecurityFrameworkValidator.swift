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

import CommonCrypto
import Foundation
import NIO
import NIOSSL
import os.log


class SecurityFrameworkValidator {

    /// The trust roots to use to validate certificates. This only needs to be provided if you intend to validate
    /// certificates.
    ///
    /// - NOTE: If certificate validation is enabled and `trustRoots` is `nil` then the system default root of
    /// trust is used (as if `trustRoots` had been explicitly set to `.default`).
    var trustRoots: NIOSSLTrustRoots? = nil

    /// Additional trust roots to use to validate certificates, used in addition to `trustRoots`.
    var additionalTrustRoots: [NIOSSLAdditionalTrustRoots] = []

    // Expected hostname, set at initialisation of this instance
    var expectedHostname: String

    init(trustRoots: NIOSSLTrustRoots?, additionalTrustRoots: [NIOSSLAdditionalTrustRoots], hostname: String) {
        self.trustRoots = trustRoots
        self.additionalTrustRoots = additionalTrustRoots
        expectedHostname = hostname
    }

    // Perform the same check as the function performSecurityFrameworkValidation() in file
    // SecurityFrameworkCertificateVerification.swift of the SwiftNIO SSL package
    // (https://github.com/apple/swift-nio-ssl).
    // The code is derived from this release: https://github.com/apple/swift-nio-ssl/archive/refs/tags/2.16.3.zip
    func validateSecurityFramework(certChain: [NIOSSLCertificate]) -> Bool {
        do {
            // Create the list of peer certificates
            var peerCertificates: [SecCertificate] = []
            for cert in certChain {
                let data = try Data(cert.toDERBytes())
                let newCert: SecCertificate = SecCertificateCreateWithData(nil, data as CFData)!
                peerCertificates.append(newCert)
            }

            // Code derived from performSecurityFrameworkValidation() starts here
            guard case .default = trustRoots ?? .default else {
                preconditionFailure("This callback should only be used if we are using the system-default trust.")
            }

            // This force-unwrap is safe as we must have decided if we're a client or a server before validation.
            var trust: SecTrust? = nil
            var result: OSStatus
            // This is only for TLS clients, so role is always .client, i.e. SSLConnection.role! == .client --> true
            let policy = SecPolicyCreateSSL(true, expectedHostname as CFString?)
            result = SecTrustCreateWithCertificates(peerCertificates as CFArray, policy, &trust)
            guard result == errSecSuccess, let actualTrust = trust else {
                throw NIOSSLError.unableToValidateCertificate
            }

            // If there are additional trust roots then we need to add them to the SecTrust as anchors.
            let additionalAnchorCertificates: [SecCertificate] = try additionalTrustRoots.flatMap { trustRoots -> [NIOSSLCertificate] in
                guard case .certificates(let certs) = trustRoots else {
                    preconditionFailure("This callback happens on the request path, file-based additional trust roots should be pre-loaded when creating the SSLContext.")
                }
                return certs
            }.map {
                guard let secCert = SecCertificateCreateWithData(nil, Data(try $0.toDERBytes()) as CFData) else {
                    throw NIOSSLError.failedToLoadCertificate
                }
                return secCert
            }
            if !additionalAnchorCertificates.isEmpty {
                // To use additional anchors _and_ the built-in ones we must reenable the built-in ones expicitly.
                guard SecTrustSetAnchorCertificatesOnly(actualTrust, false) == errSecSuccess else {
                    throw NIOSSLError.failedToLoadCertificate
                }
                guard SecTrustSetAnchorCertificates(actualTrust, additionalAnchorCertificates as CFArray) == errSecSuccess else {
                    throw NIOSSLError.failedToLoadCertificate
                }
            }

            // Evaluate the trust
            if #available(iOS 12, macOS 10.14, tvOS 13, watchOS 6, *) {
                if SecTrustEvaluateWithError(actualTrust, nil) {
                    return true
                }
            } else {
                var result = SecTrustResultType.invalid
                if SecTrustEvaluate(actualTrust, &result) != errSecSuccess {
                    throw NIOSSLError.unableToValidateCertificate
                }
                if result == .proceed || result == .unspecified {
                    return true
                }
            }
        } catch {
            os_log("Approov: Security framework validation error: %@", type: .error, error.localizedDescription)
            return false
        }
        return false
    }

}
