// MIT License
//
// Copyright (c) 2016-present, Approov Ltd.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files
// (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge,
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR
// ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH
// THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import CommonCrypto
import Foundation
import os.log
import RawStructuredFieldValues
import NIOHPACK

/**
 * Provides a base implementation of HTTP message signing (RFC 9421) for Approov when using gRPC.
 * It installs as an `ApproovServiceMutator` and adds `Signature` / `Signature-Input` headers to the
 * gRPC request metadata once an Approov token has been added.
 *
 * Note: gRPC requests carry no buffered body at the interceptor layer, so body digests
 * (`Content-Digest`) are not produced for gRPC. Signing covers the derived components (`@method`,
 * `@target-uri`, ...), the Approov token / trace-ID headers, and any configured optional headers.
 */
public class ApproovDefaultMessageSigning: ApproovServiceMutator, CustomStringConvertible {

    /**
     * Constant for the SHA-256 digest algorithm (used for body digests).
     */
    public static let DIGEST_SHA256 = "sha-256"

    /**
     * Constant for the SHA-512 digest algorithm (used for body digests).
     */
    public static let DIGEST_SHA512 = "sha-512"

    /**
     * Constant for the ECDSA P-256 with SHA-256 algorithm (used when signing with install private key).
     */
    public static let ALG_ES256 = "ecdsa-p256-sha256"

    /**
     * Constant for the HMAC with SHA-256 algorithm (used when signing with the account signing key).
     */
    public static let ALG_HS256 = "hmac-sha256"

    /**
     * Default factory for generating signature parameters.
     */
    private var defaultFactory: SignatureParametersFactory?

    /**
     * Host-specific factories for generating signature parameters.
     */
    private var hostFactories: [String: SignatureParametersFactory]

    /**
     * Initializer
     */
    public init() {
        hostFactories = [:]
    }

    public var description: String {
        return "ApproovDefaultMessageSigning"
    }

    /**
     * Sets the default factory for generating signature parameters.
     *
     * - Parameter factory: The factory to set as the default.
     * - Returns: The current instance for method chaining.
     */
    public func setDefaultFactory(_ factory: SignatureParametersFactory) -> ApproovDefaultMessageSigning {
        defaultFactory = factory
        return self
    }

    /**
     * Associates a specific host with a factory for generating signature parameters.
     *
     * - Parameters:
     *   - hostName: The host name.
     *   - factory: The factory to associate with the host.
     * - Returns: The current instance for method chaining.
     */
    public func putHostFactory(hostName: String, factory: SignatureParametersFactory) -> ApproovDefaultMessageSigning {
        hostFactories[hostName] = factory
        return self
    }

    /**
     * Builds the signature parameters for a given request.
     *
     * - Parameters:
     *   - provider: The component provider for the request.
     *   - changes: The request mutations to apply.
     * - Returns: The generated `SignatureParameters`, or `nil` if no factory is available.
     */
    private func buildSignatureParameters(provider: ApproovGRPCComponentProvider, changes: ApproovRequestMutations) throws -> SignatureParameters? {
        let factory = hostFactories[provider.getAuthority()] ?? defaultFactory
        return try factory?.buildSignatureParameters(provider: provider, changes: changes)
    }

    /**
     * Processes a request to add message signature headers. Called after the Approov interceptor has
     * applied its token / header mutations.
     *
     * - Parameters:
     *   - request: The Approov gRPC request.
     *   - changes: The request mutations that were applied by the Approov interceptor.
     * - Returns: The processed request with the signature headers added.
     * - Throws: An `ApproovError` for the fail-closed cases (unsupported algorithm or a required body
     *           digest that cannot be generated). All other signing failures are fail-open.
     */
    public func handleInterceptorProcessedRequest(_ request: ApproovRequest,
                                                   changes: ApproovRequestMutations) throws -> ApproovRequest {
        return try processedRequest(request, changes: changes)
    }

    /**
     * Helper to process the request signature changes.
     */
    public func processedRequest(_ request: ApproovRequest, changes: ApproovRequestMutations) throws -> ApproovRequest {
        // If the request doesn't have an Approov token, we don't need to sign it
        if request.headers.first(name: ApproovService.approovTokenHeaderAndPrefix.approovTokenHeader) != nil {
            // Generate and add a message signature
            let provider = ApproovGRPCComponentProvider(request: request)
            guard let params = try buildSignatureParameters(provider: provider, changes: changes) else {
                // No signature to be added; proceed with the original request
                return request
            }

            // Build the signature base
            let baseBuilder = SignatureBaseBuilder(sigParams: params, ctx: provider)
            let message = try baseBuilder.createSignatureBase()
            // WARNING never log the message as it contains an Approov token which provides access to your API.

            // Generate the signature
            let sigId: String
            let signature: Data
            switch params.getAlg() {
            case ApproovDefaultMessageSigning.ALG_ES256:
                sigId = "install"
                // Message signing is fail-open: if the SDK cannot provide a usable install signature
                // (no signature available, or a value that cannot be base64-decoded) we proceed
                // unsigned and log at error level, rather than aborting the request.
                guard let base64Signature = ApproovService.getInstallMessageSignature(message: message),
                      let decodedSignature = Data(base64Encoded: base64Signature) else {
                    if ApproovService.loggingLevel >= .error {
                        os_log("ApproovService: install message signature unavailable, skipping signing", type: .error)
                    }
                    return provider.getRequest()
                }
                // Decode the signature from ASN.1 DER format. A malformed signature is also treated as
                // fail-open (proceed unsigned + log) rather than aborting the request.
                do {
                    signature = try ApproovDefaultMessageSigning.decodeASN_1_DER_ES256_Signature(decodedSignature)
                } catch {
                    if ApproovService.loggingLevel >= .error {
                        os_log("ApproovService: failed to decode ASN.1 DER install signature, skipping signing: %@",
                               type: .error, error.localizedDescription)
                    }
                    return provider.getRequest()
                }
            case ApproovDefaultMessageSigning.ALG_HS256:
                sigId = "account"
                // Fail-open: if the SDK cannot provide a usable account signature (none available, e.g.
                // no mksid yet, or a value that cannot be base64-decoded) we proceed unsigned and log.
                guard let base64Signature = ApproovService.getAccountMessageSignature(message: message),
                      let decodedSignature = Data(base64Encoded: base64Signature) else {
                    if ApproovService.loggingLevel >= .error {
                        os_log("ApproovService: account message signature unavailable, skipping signing", type: .error)
                    }
                    return provider.getRequest()
                }
                signature = decodedSignature
            default:
                // Unsupported algorithm is a configuration error and is one of the two signing failures
                // (with a required body digest) that fail closed.
                throw ApproovError.permanentError(message: "Unsupported algorithm identifier: \(params.getAlg() ?? "unknown")")
            }

            // Create signature headers
            guard let sigHeader = try SFV.serializeDictionary(key: sigId, data: signature) else {
                throw ApproovError.permanentError(message: "Failed to serialize signature header")
            }
            guard let sigInputHeader = try SFV.serializeDictionary(key: sigId, innerList: params.toComponentValue()) else {
                throw ApproovError.permanentError(message: "Failed to serialize signature input header")
            }

            // Add headers to the request. Use replaceOrAdd so that re-processing an already-signed
            // request does not emit duplicate Signature / Signature-Input header lines.
            var signedRequest = provider.getRequest()
            signedRequest.headers.replaceOrAdd(name: "Signature", value: sigHeader)
            signedRequest.headers.replaceOrAdd(name: "Signature-Input", value: sigInputHeader)

            if params.isDebugMode() {
                let digest = ApproovDefaultMessageSigning.sha256(data: Data(message.utf8))
                if let sigBaseDigestHeader = try SFV.serializeDictionary(key: "sha-256", data: digest) {
                    signedRequest.headers.replaceOrAdd(name: "Signature-Base-Digest", value: sigBaseDigestHeader)
                } else {
                    if ApproovService.loggingLevel >= .debug {
                        os_log("ApproovService: Failed to get digest algorithm - no debug entry", type: .debug)
                    }
                }
            }

            return signedRequest
        }

        return request
    }

    /**
     * SHA256 of given input bytes.
     *
     * @param data is the input data
     * @return the hash data
     */
    static func sha256(data: Data) -> Data {
        var hash = [UInt8](repeating: 0,  count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }

    // Decode ASN.1 DER encoded ES256 signature into "raw" signature format
    static func decodeASN_1_DER_ES256_Signature(_ signature: Data) throws -> Data {
        var offset = 0

        // Ensure signature has at least 2 bytes (tag and length)
        guard signature.count >= 2 else {
            throw ApproovError.permanentError(message: "ASN.1 DER signature too short")
        }

        // Ensure the signature starts with a valid ASN.1 sequence
        guard signature[offset] == 0x30 else {
            throw ApproovError.permanentError(message: "Invalid ASN.1 DER sequence")
        }
        offset += 1

        // Read the total length of the sequence
        let sequenceLength = Int(signature[offset])
        offset += 1

        guard sequenceLength == signature.count - 2 else {
            throw ApproovError.permanentError(message: "Invalid ASN.1 DER sequence length")
        }

        // Ensure there are at least 2 more bytes for r's tag and length
        guard offset + 2 <= signature.count else {
            throw ApproovError.permanentError(message: "Truncated ASN.1 DER signature reading r")
        }

        // Decode the first integer (r)
        guard signature[offset] == 0x02 else {
            throw ApproovError.permanentError(message: "Invalid ASN.1 DER integer for r")
        }
        offset += 1

        let rLength = Int(signature[offset])
        offset += 1

        // Ensure we can read rBytes
        guard offset + rLength <= signature.count else {
            throw ApproovError.permanentError(message: "Truncated ASN.1 DER signature reading r value")
        }

        let rBytes = signature[offset..<(offset + rLength)]
        offset += rLength

        // Ensure there are at least 2 more bytes for s's tag and length
        guard offset + 2 <= signature.count else {
            throw ApproovError.permanentError(message: "Truncated ASN.1 DER signature reading s")
        }

        // Decode the second integer (s)
        guard signature[offset] == 0x02 else {
            throw ApproovError.permanentError(message: "Invalid ASN.1 DER integer for s")
        }
        offset += 1

        let sLength = Int(signature[offset])
        offset += 1

        // Ensure we can read sBytes
        guard offset + sLength <= signature.count else {
            throw ApproovError.permanentError(message: "Truncated ASN.1 DER signature reading s value")
        }

        let sBytes = signature[offset..<(offset + sLength)]
        offset += sLength

        // Ensure the entire signature has been processed
        guard offset == signature.count else {
            throw ApproovError.permanentError(message: "Extra data in ASN.1 DER signature")
        }

        return try to32ByteData(bytes: rBytes) + to32ByteData(bytes: sBytes)
    }

    private static func to32ByteData(bytes: Data) throws -> Data {
        if bytes.count < 32 {
            let padding = Data(repeating: 0, count: 32 - bytes.count)
            return padding + bytes
        } else if bytes.count == 32 {
            // Return as-is if the byte array is exactly 32 bytes
            return bytes
        } else if bytes.count == 33 && bytes.first == 0 {
            // Remove the leading zero if the byte array is 33 bytes and starts with 0
            return bytes.dropFirst()
        } else {
            // Throw an error if the byte array cannot be represented as 32 bytes
            throw ApproovError.permanentError(message: "Not an ASN.1 DER ES256 signature part")
        }
    }

    /**
     * Generates a default `SignatureParametersFactory` with predefined settings and optional base
     * parameters. The default signs `@method` and `@target-uri`, the Approov token and trace-ID
     * headers, and the `Authorization` header when present. No body digest is configured (gRPC has no
     * accessible body at the interceptor layer).
     *
     * - Parameter baseParametersOverride: The base parameters to override, or `nil` to use defaults.
     * - Returns: A new instance of `SignatureParametersFactory`.
     */
    public static func generateDefaultSignatureParametersFactory(baseParametersOverride: SignatureParameters? = nil) -> SignatureParametersFactory {
        let defaultExpiresLifetime: Int64 = 15
        let baseParameters: SignatureParameters

        if let override = baseParametersOverride {
            baseParameters = override
        } else {
            baseParameters = SignatureParameters()
                .addComponentIdentifier(ApproovGRPCComponentProvider.DC_METHOD)
                .addComponentIdentifier(ApproovGRPCComponentProvider.DC_TARGET_URI)
        }

        // Note: no body digest is configured for gRPC.
        return SignatureParametersFactory()
            .setBaseParameters(baseParameters)
            .setUseInstallMessageSigning()
            .setAddCreated(true)
            .setExpiresLifetime(defaultExpiresLifetime)
            .setAddApproovTokenHeader(true)
            .setAddApproovTraceIDHeader(true)
            .addOptionalHeaders(["Authorization"])
    }
}

/**
 * Factory class for creating pre-request `SignatureParameters` with configurable settings.
 */
public class SignatureParametersFactory {
    private var baseParameters: SignatureParameters?
    private var bodyDigestAlgorithm: String?
    private var bodyDigestRequired: Bool = false
    private var useAccountMessageSigning: Bool = false
    private var addCreated: Bool = false
    private var expiresLifetime: Int64 = 0
    private var addApproovTokenHeader: Bool = false
    private var addApproovTraceIDHeader: Bool = false
    private var optionalHeaders: [String] = []

    @discardableResult
    public func setBaseParameters(_ baseParameters: SignatureParameters) -> SignatureParametersFactory {
        self.baseParameters = baseParameters
        return self
    }

    /**
     * Configures body digest generation. NOTE: gRPC has no buffered body at the interceptor layer, so
     * a body digest can never actually be generated; configuring one with `required: true` will cause
     * signing to fail closed (per the spec's fail-closed rule for an unavailable required digest).
     */
    @discardableResult
    public func setBodyDigestConfig(_ bodyDigestAlgorithm: String?, required: Bool) throws -> SignatureParametersFactory {
        if let algorithm = bodyDigestAlgorithm {
            guard algorithm == ApproovDefaultMessageSigning.DIGEST_SHA256 ||
                  algorithm == ApproovDefaultMessageSigning.DIGEST_SHA512 else {
                throw ApproovError.permanentError(message: "Unsupported body digest algorithm: \(algorithm)")
            }
            self.bodyDigestAlgorithm = algorithm
            self.bodyDigestRequired = required
        } else {
            // Passing a nil algorithm disables body digest generation entirely.
            self.bodyDigestAlgorithm = nil
            self.bodyDigestRequired = false
        }
        return self
    }

    @discardableResult
    public func setUseInstallMessageSigning() -> SignatureParametersFactory {
        self.useAccountMessageSigning = false
        return self
    }

    @discardableResult
    public func setUseAccountMessageSigning() -> SignatureParametersFactory {
        self.useAccountMessageSigning = true
        return self
    }

    @discardableResult
    public func setAddCreated(_ addCreated: Bool) -> SignatureParametersFactory {
        self.addCreated = addCreated
        return self
    }

    @discardableResult
    public func setExpiresLifetime(_ expiresLifetime: Int64) -> SignatureParametersFactory {
        self.expiresLifetime = expiresLifetime
        return self
    }

    @discardableResult
    public func setAddApproovTokenHeader(_ addApproovTokenHeader: Bool) -> SignatureParametersFactory {
        self.addApproovTokenHeader = addApproovTokenHeader
        return self
    }

    @discardableResult
    public func setAddApproovTraceIDHeader(_ addApproovTraceIDHeader: Bool) -> SignatureParametersFactory {
        self.addApproovTraceIDHeader = addApproovTraceIDHeader
        return self
    }

    @discardableResult
    public func addOptionalHeaders(_ headers: [String]) -> SignatureParametersFactory {
        self.optionalHeaders.append(contentsOf: headers)
        return self
    }

    func buildSignatureParameters(provider: ApproovGRPCComponentProvider, changes: ApproovRequestMutations) throws -> SignatureParameters {
        var requestParameters: SignatureParameters
        if baseParameters == nil {
            requestParameters = SignatureParameters()
        } else {
            requestParameters = SignatureParameters(base: baseParameters!)
        }
        requestParameters.setAlg(useAccountMessageSigning ? ApproovDefaultMessageSigning.ALG_HS256 : ApproovDefaultMessageSigning.ALG_ES256)

        if addCreated || expiresLifetime > 0 {
            let currentTime = Int64(Date().timeIntervalSince1970)
            if addCreated {
                requestParameters.setCreated(currentTime)
            }
            if expiresLifetime > 0 {
                requestParameters.setExpires(currentTime + expiresLifetime)
            }
        }

        if addApproovTokenHeader, let tokenHeaderKey = changes.getTokenHeaderKey() {
            requestParameters.addComponentIdentifier(tokenHeaderKey)
        }

        if addApproovTraceIDHeader, let traceIDHeaderKey = changes.getTraceIDHeaderKey() {
            requestParameters.addComponentIdentifier(traceIDHeaderKey)
        }

        for headerName in optionalHeaders {
            if provider.hasField(name: headerName) {
                requestParameters.addComponentIdentifier(headerName)
            }
        }

        if bodyDigestAlgorithm != nil {
            // gRPC has no accessible body, so a digest can never be generated.
            let bodyDigestCreated = generateBodyDigest()
            if !bodyDigestCreated && bodyDigestRequired {
                throw ApproovError.permanentError(message: "Failed to create required body digest")
            }
        }

        return requestParameters
    }

    /**
     * gRPC requests carry no buffered body at the interceptor layer, so a Content-Digest cannot be
     * generated. Always returns false; a required digest therefore fails closed in
     * `buildSignatureParameters`.
     */
    private func generateBodyDigest() -> Bool {
        return false
    }
}

/**
 * ApproovGRPCComponentProvider implements the ComponentProvider protocol for gRPC requests. gRPC
 * requests are always `POST` over `https`; the authority is the target hostname, and the path (when
 * available from the interceptor) is the RPC path `/package.Service/Method`. There is no query and no
 * accessible body. Fields are read from the request metadata (`HPACKHeaders`).
 */
class ApproovGRPCComponentProvider: ComponentProvider {

    private var request: ApproovRequest

    init(request: ApproovRequest) {
        self.request = request
    }

    public func getRequest() -> ApproovRequest {
        return request
    }

    public func setRequest(_ newRequest: ApproovRequest) {
        self.request = newRequest
    }

    public func getMethod() -> String {
        return "POST"
    }

    public func getAuthority() -> String {
        return request.hostname
    }

    public func getScheme() -> String {
        return "https"
    }

    public func getTargetUri() -> String {
        return "https://" + request.hostname + (request.path ?? "")
    }

    public func getRequestTarget() -> String {
        return request.path ?? ""
    }

    public func getPath() -> String {
        return request.path ?? ""
    }

    public func getQuery() -> String {
        return ""
    }

    public func getQueryParam(name: String) -> String? {
        return nil
    }

    public func hasField(name: String) -> Bool {
        return request.headers.first(name: name) != nil
    }

    public func getField(name: String) -> String? {
        let values = request.headers[name]
        guard !values.isEmpty else {
            return nil
        }
        return ApproovGRPCComponentProvider.combineFieldValues(fields: values)
    }

    public func hasBody() -> Bool {
        return false
    }
}
