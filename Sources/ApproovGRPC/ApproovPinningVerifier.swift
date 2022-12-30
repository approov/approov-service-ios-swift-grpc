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

import Approov
import CommonCrypto
import Foundation
import NIO
import NIOSSL
import os.log

class ApproovPinningVerifier {

    private static let rsa2048SPKIHeader:[UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05,
        0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
    ]
    private static let rsa3072SPKIHeader:[UInt8] = [
        0x30, 0x82, 0x01, 0xa2, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05,
        0x00, 0x03, 0x82, 0x01, 0x8f, 0x00
    ]
    private static let rsa4096SPKIHeader:[UInt8] = [
        0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05,
        0x00, 0x03, 0x82, 0x02, 0x0f, 0x00
    ]
    private static let ecdsaSecp256r1SPKIHeader:[UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48,
        0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
    ]
    private static let ecdsaSecp384r1SPKIHeader:[UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04,
        0x00, 0x22, 0x03, 0x62, 0x00
    ]

    // SPKI headers for both RSA and ECC
    private static let spkiHeaders: [String:[Int:Data]] = [
        kSecAttrKeyTypeRSA as String:[
            2048:Data(rsa2048SPKIHeader),
            3072:Data(rsa3072SPKIHeader),
            4096:Data(rsa4096SPKIHeader)
        ],
        kSecAttrKeyTypeECSECPrimeRandom as String:[
            256:Data(ecdsaSecp256r1SPKIHeader),
            384:Data(ecdsaSecp384r1SPKIHeader)
        ]
    ]

    // Security framework validator used to perform the equivalent of NIOSSL's default validation
    var securityFrameworkValidator: SecurityFrameworkValidator

    // Optional user defined custom verification callback for NIOSSL
    var verificationCallback: NIOSSLCustomVerificationCallback?

    init(securityFrameworkValidator: SecurityFrameworkValidator) {
        self.securityFrameworkValidator = securityFrameworkValidator
    }

    init(securityFrameworkValidator: SecurityFrameworkValidator, verificationCallback: @escaping NIOSSLCustomVerificationCallback) {
        self.securityFrameworkValidator = securityFrameworkValidator
        self.verificationCallback = verificationCallback
    }

    /**
     * Verify pinning by evaluating the optional custom verification callback first before checking Approov pinning.
     * If an optional custom verifier is set, this *must* pass for the overall verification to be sucessful.
     * @param host for which to check pinning
     * @param certChain for which to check whether it contains a pinned certificate
     */
    func verifyPinning(
        certChain: [NIOSSLCertificate],
        promise: EventLoopPromise<NIOSSLVerificationResult>
    ) -> Void {
        if (self.verificationCallback != nil) {
            let internalPromise: EventLoopPromise<NIOSSLVerificationResult> =
                promise.futureResult.eventLoop.makePromise()
            self.verificationCallback!(certChain, internalPromise)
            internalPromise.futureResult.whenSuccess {result in
                switch result {
                case .certificateVerified:
                    self.verifyApproovPinning(certChain: certChain, promise: promise)
                case .failed:
                    promise.succeed(.failed)
                }
            }
            internalPromise.futureResult.whenFailure {error in
                promise.fail(error)
            }
        } else {
            verifyApproovPinning(certChain: certChain, promise: promise)
        }
    }

    /**
     * Verify Approov pinning. This includes a validation of the security framework as NIOSSL would perform in the
     * absence of a custom verification callback.
     * @param host for which to check pinning
     * @param certChain in which to look for a match to an Approov pin
     */
    func verifyApproovPinning(
        certChain: [NIOSSLCertificate],
        promise: EventLoopPromise<NIOSSLVerificationResult>
    ) -> Void {
        // We create a DispatchQueue here to be called back on, as this validation may perform network activity.
        let callbackQueue = DispatchQueue(label: "io.approov.pinningCallbackQueue")
        callbackQueue.async {
            let isValidated: Bool
            if self.securityFrameworkValidator.trustRoots == nil ||
                self.securityFrameworkValidator.trustRoots == .default {
                do {
                    // This must not be called if different trust roots are set
                    isValidated = try self.securityFrameworkValidator.validateSecurityFramework(certChain: certChain)
                } catch {
                    promise.fail(ApproovError.pinningError(
                        message: "Error during security framework validation for host " +
                        self.securityFrameworkValidator.expectedHostname + ": " + error.localizedDescription))
                    isValidated = false
                }
            } else {
                do {
                    // Create a server trust from the peer certificates
                    var peerCertificates: [SecCertificate] = []
                    for cert in certChain {
                        let data = try Data(cert.toDERBytes())
                        let newCert: SecCertificate = SecCertificateCreateWithData(nil, data as CFData)!
                        peerCertificates.append(newCert)
                    }
                    let policy = SecPolicyCreateSSL(true, self.securityFrameworkValidator.expectedHostname as CFString?)
                    var serverTrust: SecTrust? = nil
                    let result = SecTrustCreateWithCertificates(peerCertificates as CFArray, policy, &serverTrust)
                    if (result != errSecSuccess) {
                        promise.fail(ApproovError.pinningError(
                            message: "Error during certificate trust creation for host " +
                                self.securityFrameworkValidator.expectedHostname))
                        isValidated = false
                    } else {
                        // Check the server trust
                        var trustType = SecTrustResultType.invalid
                        if (SecTrustEvaluate(serverTrust!, &trustType) != errSecSuccess) {
                            promise.fail(ApproovError.pinningError(
                                message: "Error during certificate trust evaluation for host " +
                                    self.securityFrameworkValidator.expectedHostname))
                            isValidated = false
                        } else if (trustType != SecTrustResultType.proceed) &&
                            (trustType != SecTrustResultType.unspecified) {
                            promise.fail(ApproovError.pinningError(
                                message: "Certificate Trust Evaluation failure for host " +
                                    self.securityFrameworkValidator.expectedHostname))
                            isValidated = false
                        } else {
                            isValidated = true
                        }
                    }
                } catch {
                    promise.fail(ApproovError.pinningError(
                        message: "Error in server certificate chain check: \(error.localizedDescription)"))
                    isValidated = false
                }
            }
            if isValidated {
                do {
                    let isVerified = try self.hasApproovPinMatch(host: self.securityFrameworkValidator.expectedHostname,
                        certChain: certChain)
                    if isVerified {
                        promise.succeed(.certificateVerified)
                    } else {
                        promise.succeed(.failed)
                    }
                } catch {
                    promise.fail(error)
                }
            }
        }
    }

    /**
     * Checks whether a certificate chain contains a match to an Approov pin
     *
     * @param host for which to check pinning
     * @param certChain in which to look for a match to an Approov pin
     */
    func hasApproovPinMatch(host: String, certChain: [NIOSSLCertificate]) throws -> Bool {
        // Ensure pins are refreshed eventually
        ApproovService.prefetch()
        
        // Get the certificate chain count
        for cert in certChain {
            // Get the current certificate from the chain
            let data = try Data(cert.toDERBytes())
            let newCert: SecCertificate = SecCertificateCreateWithData(nil, data as CFData)!
            if let publicKeyInfo = publicKeyInfoOfCertificate(certificate: newCert) {
                // Compute the SHA-256 hash of the public key info
                let publicKeyHash = sha256(data: publicKeyInfo)

                // Check that the hash is the same as at least one of the pins
                guard let approovCertHashes = Approov.getPins("public-key-sha256") else {
                    throw ApproovError.pinningError(message: "Approov SDK getPins() call failed")
                }
                
                // Get the receivers host
                if var certHashesBase64 = approovCertHashes[host] {
                    // Check whether we have pins defined for this host
                    if certHashesBase64.count == 0 {
                        // There are no pins defined for this host, check for managed trust roots
                        if let managedTrustRootHashesBase64 = approovCertHashes["*"] {
                            // Managed trust roots are available, so use these
                            certHashesBase64 = managedTrustRootHashesBase64
                        } else {
                            // There are no managed trust roots either, accept connection. We do not pin connections
                            // where no pins are explicitly set for the host.
                            os_log("ApproovService: Pin verification %@ empty pins", host)
                            return true
                        }
                    }

                    // We have one or more cert hashes matching the receiver's host, compare them
                    for certHashBase64 in certHashesBase64 {
                        let certHash = Data(base64Encoded: certHashBase64)
                        if publicKeyHash == certHash {
                            os_log("ApproovService: Matched pin %@ for %@ from %d pins", certHashBase64, host, certHashesBase64.count)
                            return true
                        }
                    }
                } else {
                    // Host is not pinned
                    os_log("ApproovService: Pin verification %@ unpinned", host)
                    return true
                }
            } else {
                os_log("ApproovService: Skipping pin checking for unknown certificate type")
            }
        }
        
        // No match in current set of pins from Approov SDK and certificate chain seen during TLS handshake
        os_log("ApproovService: Pinning rejection for %@", type: .error, host)
        return false
    }

    /**
     * Gets a certificate's subject public key info (SPKI).
     *
     *@param certiificate is the SecCertificate being verified
     *@return the public key for the cerrtificate ot nil if there was a problem
     */
    func publicKeyInfoOfCertificate(certificate: SecCertificate) -> Data? {
        // get the public key of the certificate
        var publicKey: SecKey?
        if #available(iOS 12.0, *) {
            publicKey = SecCertificateCopyKey(certificate)
        } else {
            // Fallback on earlier versions
            // from TrustKit https://github.com/datatheorem/TrustKit/blob/master/TrustKit/Pinning/TSKSPKIHashCache.m
            // lines 221-234:
            // Create an X509 trust using the certificate
            let secPolicy = SecPolicyCreateBasicX509()
            var secTrust:SecTrust?
            if SecTrustCreateWithCertificates(certificate, secPolicy, &secTrust) != errSecSuccess {
                return nil
            }
            
            // get a public key reference for the certificate from the trust
            var secTrustResultType = SecTrustResultType.invalid
            if SecTrustEvaluate(secTrust!, &secTrustResultType) != errSecSuccess {
                return nil
            }
            publicKey = SecTrustCopyPublicKey(secTrust!)
        }
        if publicKey == nil {
            return nil
        }
        
        // get the SPKI header depending on the public key's type and size
        guard var spkiHeader = publicKeyInfoHeaderForKey(publicKey: publicKey!) else {
            return nil
        }
        
        // combine the public key header and the public key data to form the public key info
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey!, nil) else {
            return nil
        }
        spkiHeader.append(publicKeyData as Data)
        return spkiHeader
    }

    /**
     * Gets the subject public key info (SPKI) header depending on a public key's type and size.
     *
     *@param publicKey is the public key whose SPKI header is being obtained
     *@return SPKI header data or nil if there was a problem
     */
    func publicKeyInfoHeaderForKey(publicKey: SecKey) -> Data? {
        guard let publicKeyAttributes = SecKeyCopyAttributes(publicKey) else {
            return nil
        }
        if let keyType = (publicKeyAttributes as NSDictionary).value(forKey: kSecAttrKeyType as String) {
            if let keyLength = (publicKeyAttributes as NSDictionary).value(forKey: kSecAttrKeySizeInBits as String) {
                // Find the SPKI header
                if let spkiHeader:Data = ApproovPinningVerifier.spkiHeaders[keyType as! String]?[keyLength as! Int] {
                    return spkiHeader
                }
            }
        }
        return nil
    }

    /**
     * SHA256 of given input bytes.
     *
     *@param data to be hashed
     *@return the SHA256 of the data
     */
    func sha256(data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }
}
