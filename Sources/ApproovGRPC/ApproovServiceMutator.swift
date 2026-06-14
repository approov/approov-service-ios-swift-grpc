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

import Approov
import Foundation
import NIOHPACK

/**
 * ApproovRequest stores information about a gRPC request being processed for Approov.
 *
 * gRPC requests carry no URL, query string or body at the interceptor layer; only the
 * target hostname and the metadata `HPACKHeaders` are available. An optional `path` is
 * carried for future signing use but is nil in the current flow.
 */
public struct ApproovRequest {
    public var hostname: String
    public var headers: HPACKHeaders
    public var path: String?

    public init(hostname: String, headers: HPACKHeaders, path: String? = nil) {
        self.hostname = hostname
        self.headers = headers
        self.path = path
    }
}

/**
 * ApproovFetchDecision defines the possible results from an Approov request update.
 */
public enum ApproovFetchDecision {
    case ShouldProceed      // Proceed with request
    case ShouldRetry        // User can retry request
    case ShouldFail         // Request should not be made
    case ShouldIgnore       // Do not process request
}

/**
 * ApproovUpdateResponse contains the result of adding Approov protection to a request.
 */
public struct ApproovUpdateResponse {
    public internal(set) var request: ApproovRequest
    public internal(set) var decision: ApproovFetchDecision
    public internal(set) var sdkMessage: String
    public internal(set) var error: Error?
}

/**
 * ApproovRequestMutations stores information about changes made to a gRPC request
 * during Approov processing, such as token headers and substituted headers.
 *
 * gRPC has no query parameter substitution, so only header-based mutations are tracked.
 */
public class ApproovRequestMutations {
    private var tokenHeaderKey: String?
    private var traceIDHeaderKey: String?
    private var substitutionHeaderKeys: [String] = []

    public init() {}

    public func getTokenHeaderKey() -> String? {
        return tokenHeaderKey
    }

    public func setTokenHeaderKey(_ tokenHeaderKey: String) {
        self.tokenHeaderKey = tokenHeaderKey
    }

    public func getTraceIDHeaderKey() -> String? {
        return traceIDHeaderKey
    }

    public func setTraceIDHeaderKey(_ traceIDHeaderKey: String?) {
        self.traceIDHeaderKey = traceIDHeaderKey
    }

    public func getSubstitutionHeaderKeys() -> [String] {
        return substitutionHeaderKeys
    }

    public func setSubstitutionHeaderKeys(_ substitutionHeaderKeys: [String]) {
        self.substitutionHeaderKeys = substitutionHeaderKeys
    }
}

/**
 * ApproovServiceMutator provides an interface for modifying the behavior of
 * the ApproovService class by overriding the default implementations of the
 * defined callbacks. Opportunities to modify behavior are offered at key
 * points in the service and attestation flows.
 *
 * This is the gRPC form of the mutator: it omits query-parameter substitution
 * (which gRPC does not support) and operates on `HPACKHeaders` rather than URLs.
 */
public protocol ApproovServiceMutator {
    /**
     * Decides how to handle the token fetch result from an
     * ApproovService.precheck() operation.
     */
    func handlePrecheckResult(_ approovResults: ApproovTokenFetchResult) throws

    /**
     * Decides how to handle the token fetch result from an
     * ApproovService.fetchToken() operation.
     */
    func handleFetchTokenResult(_ approovResults: ApproovTokenFetchResult) throws

    /**
     * Decides how to handle the token fetch result from an
     * ApproovService.fetchSecureString() operation.
     */
    func handleFetchSecureStringResult(_ approovResults: ApproovTokenFetchResult,
                                       operation: String,
                                       key: String) throws

    /**
     * Decides how to handle the token fetch result from an
     * ApproovService.fetchCustomJWT() operation.
     */
    func handleFetchCustomJWTResult(_ approovResults: ApproovTokenFetchResult) throws

    /**
     * Decides whether a request should be processed in the interceptor or not.
     * Called at the start of the ApproovService interceptor processing.
     */
    func handleInterceptorShouldProcessRequest(_ request: ApproovRequest) throws -> Bool

    /**
     * Decides how to handle the token fetch result from a call to
     * Approov.fetchTokenAndWait() from within the interceptor.
     */
    func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult,
                                           url: String) throws -> Bool

    /**
     * Decides how to handle the token fetch result while substituting headers
     * from within the interceptor.
     */
    func handleInterceptorHeaderSubstitutionResult(_ approovResults: ApproovTokenFetchResult,
                                                   header: String) throws -> Bool

    /**
     * Called after Approov has processed a network request, allowing further
     * modifications.
     */
    func handleInterceptorProcessedRequest(_ request: ApproovRequest,
                                           changes: ApproovRequestMutations) throws -> ApproovRequest

    /**
     * Decides whether certificate pinning should be applied to a hostname or not.
     */
    func handlePinningShouldProcessRequest(hostname: String) -> Bool
}

public extension ApproovServiceMutator {
    func handlePrecheckResult(_ approovResults: ApproovTokenFetchResult) throws {
        let status = approovResults.status
        switch status {
        case .rejected:
            throw ApproovError.rejectionError(message: "precheck: rejected",
                                              ARC: approovResults.arc,
                                              rejectionReasons: approovResults.rejectionReasons)
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            throw ApproovError.networkingError(message: "precheck network error: " + Approov.string(from: status))
        case .success,
             .unknownKey:
            return
        default:
            throw ApproovError.permanentError(message: "precheck: " + Approov.string(from: status))
        }
    }

    func handleFetchTokenResult(_ approovResults: ApproovTokenFetchResult) throws {
        let status = approovResults.status
        switch status {
        case .success:
            return
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            throw ApproovError.networkingError(message: "fetchToken network error: " + Approov.string(from: status))
        default:
            throw ApproovError.permanentError(message: "fetchToken: " + Approov.string(from: status))
        }
    }

    func handleFetchSecureStringResult(_ approovResults: ApproovTokenFetchResult,
                                       operation: String,
                                       key: String) throws {
        let status = approovResults.status
        switch status {
        case .rejected:
            throw ApproovError.rejectionError(message: "fetchSecureString \(operation) for \(key): rejected",
                                              ARC: approovResults.arc,
                                              rejectionReasons: approovResults.rejectionReasons)
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            throw ApproovError.networkingError(message: "fetchSecureString \(operation) for \(key): " +
                                               Approov.string(from: status))
        case .success,
             .unknownKey:
            return
        default:
            throw ApproovError.permanentError(message: "fetchSecureString \(operation) for \(key): " +
                                              Approov.string(from: status))
        }
    }

    func handleFetchCustomJWTResult(_ approovResults: ApproovTokenFetchResult) throws {
        let status = approovResults.status
        switch status {
        case .rejected:
            throw ApproovError.rejectionError(message: "fetchCustomJWT: rejected",
                                              ARC: approovResults.arc,
                                              rejectionReasons: approovResults.rejectionReasons)
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            throw ApproovError.networkingError(message: "fetchCustomJWT network error: " + Approov.string(from: status))
        case .success:
            return
        default:
            throw ApproovError.permanentError(message: "fetchCustomJWT: " + Approov.string(from: status))
        }
    }

    func handleInterceptorShouldProcessRequest(_ request: ApproovRequest) throws -> Bool {
        // gRPC has no natural request URL at the interceptor layer, so exclusion regexes are
        // matched against the request URL string we can reconstruct: the path if present is
        // appended to "https://<hostname>", otherwise the hostname (normalized with https:// scheme if missing) is used.
        let hostname = request.hostname
        let lowerHostname = hostname.lowercased()
        let baseHostname = lowerHostname.hasPrefix("http://") || lowerHostname.hasPrefix("https://")
            ? hostname
            : "https://" + hostname

        let urlString: String
        if let path = request.path, !path.isEmpty {
            urlString = baseHostname + path
        } else {
            urlString = baseHostname
        }
        let urlStringRange = NSRange(urlString.startIndex..<urlString.endIndex, in: urlString)
        for (_, regex) in ApproovService.getExclusionURLRegexs() {
            if regex.firstMatch(in: urlString, options: [], range: urlStringRange) != nil {
                return false
            }
        }
        return true
    }

    func handleInterceptorFetchTokenResult(_ approovResults: ApproovTokenFetchResult,
                                           url: String) throws -> Bool {
        let status = approovResults.status
        switch status {
        case .success:
            return true
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            throw ApproovError.networkingError(message: "Approov token fetch for \(url): " +
                                               Approov.string(from: status))
        case .noApproovService,
             .unknownURL,
             .unprotectedURL:
            return false
        default:
            throw ApproovError.permanentError(message: "Approov token fetch for \(url): " +
                                              Approov.string(from: status))
        }
    }

    func handleInterceptorHeaderSubstitutionResult(_ approovResults: ApproovTokenFetchResult,
                                                   header: String) throws -> Bool {
        let status = approovResults.status
        switch status {
        case .success:
            return true
        case .rejected:
            throw ApproovError.rejectionError(message: "Header substitution for \(header): rejected",
                                              ARC: approovResults.arc,
                                              rejectionReasons: approovResults.rejectionReasons)
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            throw ApproovError.networkingError(message: "Header substitution for \(header): " +
                                               Approov.string(from: status))
        case .unknownKey:
            return false
        default:
            throw ApproovError.permanentError(message: "Header substitution for \(header): " +
                                              Approov.string(from: status))
        }
    }

    func handleInterceptorProcessedRequest(_ request: ApproovRequest,
                                           changes: ApproovRequestMutations) throws -> ApproovRequest {
        return request
    }

    func handlePinningShouldProcessRequest(hostname: String) -> Bool {
        return true
    }
}

/**
 * The default ApproovServiceMutator implementation. It applies the fail-closed semantics
 * described in the cross-platform spec: fail-closed for all statuses except SUCCESS and
 * NO_APPROOV_SERVICE / UNKNOWN_URL / UNPROTECTED_URL.
 */
public struct ApproovServiceMutatorDefault: ApproovServiceMutator, CustomStringConvertible {
    public static let shared = ApproovServiceMutatorDefault()

    public var description: String {
        return "ApproovServiceMutator.DEFAULT"
    }

    private init() {}
}
