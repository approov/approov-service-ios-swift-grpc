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
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHPACK
import os.log


/**
 * Approov error conditions
 */
public enum ApproovError: Error, LocalizedError {
    case initializationFailure(message: String)
    case configurationError(message: String)
    case pinningError(message: String)
    case networkingError(message: String)
    case permanentError(message: String)
    case rejectionError(message: String, ARC: String, rejectionReasons: String)
    case runtimeError(message: String)
    public var localizedDescription: String {
        get {
            switch self {
            case let .initializationFailure(message),
                let .configurationError(message),
                let .pinningError(message),
                let .networkingError(message),
                let .permanentError(message),
                let .runtimeError(message):
                return message
            case let .rejectionError(message, ARC, rejectionReasons):
                var info: String = ""
                if !ARC.isEmpty {
                    info += ", ARC: " + ARC
                }
                if !rejectionReasons.isEmpty {
                    info += ", reasons: " + rejectionReasons
                }
                return message + info
            }
        }
    }
    public var errorDescription: String? {
        return localizedDescription
    }
}

/**
 * Log level for controlling the verbosity of os_log output from the ApproovService
 */
public enum ApproovLogLevel: Int, Comparable {
    case off = 0
    case error = 1
    case warning = 2
    case info = 3
    case debug = 4
    public static func < (lhs: ApproovLogLevel, rhs: ApproovLogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/** ApproovService provides a mediation layer to the Approov SDK itself */
public class ApproovService {

    /** Private initializer to disallow instantiation as this is a static only class */
    fileprivate init(){}

    /** Lock to manage intialization */
    private static let initLock = NIOLock()

    /** Status of Approov SDK initialisation */
    private static var approovSDKInitialised = false

    /** Current logging level */
    private static var _loggingLevel: ApproovLogLevel = .info

    public static var loggingLevel: ApproovLogLevel {
        get {
            stateLock.withLock { _loggingLevel }
        }
        set {
            stateLock.withLock { _loggingLevel = newValue }
        }
    }

    /**
     * Initializes the ApproovService with an account configuration.
     *
     * Per TESTING_REQUIREMENTS §1 the service layer never short-circuits an initialization call
     * carrying a non-empty config based on its own internal state: every non-empty config (including
     * the same config with a different comment, or a different config) is forwarded directly to the
     * native Approov SDK. If the SDK rejects the call the failure is surfaced and the service-layer
     * state is left completely unchanged. If the SDK confirms success (or we are in empty-config
     * bypass mode), the service-layer state is reset and re-applied — including resetting the custom
     * service mutator to the default. An empty config after a valid config is the only case that is
     * ignored without being forwarded.
     *
     * @param config the configuration string, or empty for no SDK initialization. The configuration string is obtained
     *               using `approov sdk -getConfigString` or through an Approov onboarding email.
     * @param comment is an optional comment to be passed to the SDK.
     */
    public static func initialize(config: String, comment: String? = nil) throws {
        try initLock.withLock {
            let isEnabled = !config.isEmpty

            // §1 Empty Configuration after Valid Configuration: once initialized with a valid
            // non-empty config, a later empty-config init is ignored and NOT forwarded to the SDK.
            if approovSDKInitialised && config.isEmpty && !((approovConfigString ?? "").isEmpty) {
                if loggingLevel >= .info {
                    os_log("ApproovService already initialized with a valid config; ignoring empty configuration", type: .info)
                }
                return
            }

            // §1 Configuration Options and Forwarding Requirement: forward all non-empty configs to
            // the native SDK without any internal short-circuit. State is only modified after the SDK
            // confirms success, preserving the current operating mode (protected or bypass) on failure.
            if isEnabled {
                do {
                    try Approov.initialize(config, updateConfig: "auto", comment: comment)
                    if loggingLevel >= .info {
                        os_log("ApproovService: Approov SDK initialized", type: .info)
                    }
                } catch {
                    let nsError = error as NSError
                    if nsError.code == 0, nsError.domain == "Foundation._GenericObjCError" {
                        // §1 Same Config Re-initialization: the native SDK returned false (already
                        // initialized with the same config). Swift bridges this BOOL=NO into a thrown
                        // Foundation._GenericObjCError(code: 0); treat it as success.
                        if loggingLevel >= .info {
                            os_log("ApproovService: Approov SDK already initialized", type: .info)
                        }
                    } else {
                        // §1 Different Non-empty Config Re-initialization / General Initialization
                        // Failure: surface the failure and leave the service-layer state unchanged.
                        let errorMessage = "Error initializing Approov SDK: \(nsError.localizedDescription)"
                        os_log("ApproovService: %@", type: .error, errorMessage)
                        throw ApproovError.initializationFailure(message: errorMessage)
                    }
                }
            }

            // §1 Service-Layer State Only Updated On Success: now that the platform SDK has
            // confirmed success (or we are in empty-config bypass mode), reset and re-apply the
            // service-layer state. This includes the §1 "Service Mutator Reset" requirement:
            // the custom service mutator is reset to the default on every successful initialization.
            approovSDKInitialised = false
            approovConfigString = config

            stateLock.withLock {
                _proceedOnNetworkFail = false
                _bindHeader = ""
                _approovTokenHeader = "Approov-Token"
                _approovTokenPrefix = ""
                _approovTraceIDHeader = "Approov-TraceID"
                _serviceMutator = ApproovServiceMutatorDefault.shared
                _useApproovStatusIfNoToken = false
                substitutionHeaders = [:]
                exclusionURLRegexs = [:]
            }

            approovSDKInitialised = true
            if isEnabled {
                Approov.setUserProperty("approov-service-grpc/dev")
            }
        }
    }

    /**
     * Resets the ApproovService state for testing.
     * This is a testing requirement and has no production use case.
     */
    static func resetForTesting() {
        initLock.withLock {
            approovSDKInitialised = false
            stateLock.withLock {
                _approovConfigString = nil
                _proceedOnNetworkFail = false
                _bindHeader = ""
                _approovTokenHeader = "Approov-Token"
                _approovTokenPrefix = ""
                _approovTraceIDHeader = "Approov-TraceID"
                _serviceMutator = ApproovServiceMutatorDefault.shared
                _useApproovStatusIfNoToken = false
                substitutionHeaders = [:]
                exclusionURLRegexs = [:]
            }
        }
    }

    /** Lock to manage variable access */
    private static let stateLock = NIOLock()

    /** True if the interceptor should proceed on network failures and not add an Approov token */
    private static var _proceedOnNetworkFail = false;

    /**
     * Sets a flag indicating if the network interceptor should proceed anyway if it is
     * not possible to obtain an Approov token due to a networking failure. If this is set
     * then your backend API can receive calls without the expected Approov token header
     * being added, or without header value substitutions being made. Note that
     * this should be used with caution because it may allow a connection to be established
     * before any dynamic pins have been received via Approov, thus potentially opening the channel to a MitM.
     */
    @available(*, deprecated, message: "No longer used internally. Use setServiceMutator to customize network failure behavior.")
    public static var proceedOnNetworkFail: Bool {
        get {
            var proceedOnNetworkFail = false
            stateLock.withLock {
                proceedOnNetworkFail = _proceedOnNetworkFail
            }
            return proceedOnNetworkFail
        }
        set {
            stateLock.withLock {
                _proceedOnNetworkFail = newValue
            }
        }
    }

    /** Map of names for headers that should have their values substituted for secure strings, mapped to their
     * required prefixes */
    private static var substitutionHeaders: Dictionary<String, String> = [:]

    /** Set of URL regexs that should be excluded from any Approov protection, mapped to the compiled pattern */
    private static var exclusionURLRegexs: Dictionary<String, NSRegularExpression> = [:]

    /** Approov TraceID optional header */
    private static var _approovTraceIDHeader: String? = "Approov-TraceID"

    /** Use Approov fetch status if token is empty */
    private static var _useApproovStatusIfNoToken = false

    /** The mutator instance used to control ApproovService behavior at key points in the flow. */
    private static var _serviceMutator: ApproovServiceMutator = ApproovServiceMutatorDefault.shared

    /** Bind Header string */
    private static var _bindHeader = ""

    /**
     * Sets a binding header that must be present on all requests using the Approov service. A
     * header should be chosen whose value is unchanging for most requests (such as an
     * Authorization header). A hash of the header value is included in the issued Approov tokens
     * to bind them to the value. This may then be verified by the backend API integration. This
     * method should typically only be called once.
     */
    public static var bindHeader: String {
        get {
            var bindHeader = ""
            stateLock.withLock {
                bindHeader = _bindHeader
            }
            return bindHeader
        }
        set {
            stateLock.withLock {
                _bindHeader = newValue
            }
        }
    }

    /** Approov token default header */
    private static var _approovTokenHeader = "Approov-Token"

    /** Approov token custom prefix: any prefix to be added such as "Bearer " */
    private static var _approovTokenPrefix = ""

    /**
     * Sets the header that the Approov token is added on, as well as an optional
     * prefix String (such as "Bearer "). By default the token is provided on
     * "Approov-Token" with no prefix.
     *
     * @param approovTokenHeader is the header to place the Approov token on
     * @param approovTokenPrefix is any prefix String for the Approov token header
     */
    public static var approovTokenHeaderAndPrefix: (approovTokenHeader: String, approovTokenPrefix: String) {
        get {
            var approovTokenHeader = ""
            var approovTokenPrefix = ""
            stateLock.withLock {
                approovTokenHeader = _approovTokenHeader
                approovTokenPrefix = _approovTokenPrefix
            }
            return (approovTokenHeader, approovTokenPrefix)
        }
        set {
            stateLock.withLock {
                (_approovTokenHeader,_approovTokenPrefix) = newValue
            }
        }
    }

    /** Initialization configuration string used for the current initialization. This is committed
     * on every successful init (including same-config reinit and bypass→protected upgrade) so the
     * service-layer state reflects the most recently accepted configuration. */
    private static var _approovConfigString: String?

    // Public setter/getter for configuration
    static var approovConfigString: String? {
        set (newValue) {
            stateLock.withLock {
                _approovConfigString = newValue
            }
        }
        get {
            stateLock.withLock {
                return _approovConfigString
            }
        }
    }

    /**
     * Returns true if Approov is initialized and enabled (i.e. has a valid configuration).
     */
    public static func isApproovEnabled() -> Bool {
        guard approovSDKInitialised else { return false }
        let config = approovConfigString ?? ""
        return !config.isEmpty
    }

    /**
     * Indicates whether the service layer has been initialized. Returns true once initialized,
     * including empty-config bypass mode (i.e. reflects approovSDKInitialised).
     */
    public static func isInitialized() -> Bool {
        initLock.withLock {
            approovSDKInitialised
        }
    }

    /**
     * Sets the header that the optional Approov Trace ID is added on. Pass nil to disable the
     * emission of the Trace ID header. By default the Trace ID is provided on "Approov-TraceID".
     */
    public static func setApproovTraceIDHeader(header: String?) {
        stateLock.withLock {
            _approovTraceIDHeader = header
        }
    }

    public static func getApproovTraceIDHeader() -> String? {
        stateLock.withLock { _approovTraceIDHeader }
    }

    /**
     * When enabled, if an Approov token cannot be fetched the service layer injects the fetch
     * status string into the token header to provide visibility to the backend, unless a custom
     * mutator blocks the request.
     */
    public static func setUseApproovStatusIfNoToken(shouldUse: Bool) {
        stateLock.withLock {
            _useApproovStatusIfNoToken = shouldUse
        }
    }

    public static func getUseApproovStatusIfNoToken() -> Bool {
        stateLock.withLock { _useApproovStatusIfNoToken }
    }

    /**
     * Installs a custom mutator to override the default fail-closed behavior at key points in
     * the service and attestation flows. Pass nil to restore the default mutator.
     */
    public static func setServiceMutator(_ mutator: ApproovServiceMutator?) {
        stateLock.withLock {
            _serviceMutator = mutator ?? ApproovServiceMutatorDefault.shared
        }
    }

    public static func getServiceMutator() -> ApproovServiceMutator {
        stateLock.withLock { _serviceMutator }
    }

    /**
     * Logs that an Approov-dependent method was invoked while the platform SDK is not active,
     * distinguishing "initialized in bypass mode (empty config)" from "service layer not
     * initialized at all" so the two states can be told apart in the logs.
     */
    private static func logApproovUnavailable(_ method: String) {
        guard loggingLevel >= .error else {
            return
        }
        let initialized = isInitialized()
        let enabled = isApproovEnabled()
        if initialized && !enabled {
            os_log("ApproovService: %@: Approov is disabled (initialized in bypass mode); ignoring call",
                   type: .error, method)
        } else {
            os_log("ApproovService: %@: service layer not initialized", type: .error, method)
        }
    }

    /**
     * Runs a throwing operation (typically a service mutator callback) and guarantees that any
     * error escaping is an `ApproovError`. A custom mutator may throw an arbitrary `Error`; this
     * wraps such values as `ApproovError.permanentError` so the documented public throwing
     * contract holds.
     */
    private static func wrappingApproovError<T>(_ context: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ApproovError {
            throw error
        } catch {
            throw ApproovError.permanentError(message: "\(context): \(error.localizedDescription)")
        }
    }

    /**
     * Sets a development key indicating that the app is a development version and it should
     * pass attestation even if the app is not registered or it is running on an emulator. The
     * development key value can be rotated at any point in the account if a version of the app
     * containing the development key is accidentally released. This is primarily
     * used for situations where the app package must be modified or resigned in
     * some way as part of the testing process.
     *
     * @param devKey is the development key to be used
     */
    public static func setDevKey(devKey: String) {
        if !isApproovEnabled() {
            logApproovUnavailable("setDevKey")
            return
        }
        Approov.setDevKey(devKey)
        os_log("ApproovService: setDevKey", type: .debug)
    }

    /**
     * Obsolete. This method is obsolete and no longer has any effect. The platform SDK manages prefetching automatically.
     */
    @available(*, deprecated, message: "Obsolete. The platform SDK manages prefetching automatically.")
    public static func prefetch() {
        os_log("ApproovService: prefetch is obsolete and does nothing", type: .info)
    }

    /**
     * Adds an Approov token and substitutes header values as defined in substitutionHeaders in the headers if present.
     * If no token is added and no substitution is made then the original collection of headers are returned, otherwise
     * a new one is constructed with the updated headers values. If it is not currently possible to fetch a token or
     * secure strings due to networking issues then ApproovError.networkingError is thrown and a user initiated retry of
     * the operation should be allowed. ApproovError.rejectionError may be thrown if the attestation fails and secure
     * strings cannot be obtained. Other ApproovExecptions represent a more permanent error condition.
     *
     * Note this is a blocking function and must not be called from the UI thread!
     *
     * @param headers is the collection of headers to be updated
     * @return headers passed in, or modified by adding an Approov token header and new header values if required
     * @throws ApproovError if it is not possible to obtain secure strings for substitution
     */
    public static func updateRequestHeaders(headers: HPACKHeaders, hostname: String, path: String? = nil) throws -> HPACKHeaders {
        let request = ApproovRequest(hostname: hostname, headers: headers, path: path)
        let response = updateRequestWithApproov(request: request)
        if let error = response.error {
            throw error
        }
        switch response.decision {
        case .ShouldProceed, .ShouldIgnore:
            return response.request.headers
        case .ShouldRetry:
            throw ApproovError.networkingError(message: "Token fetch for \(hostname): \(response.sdkMessage)")
        case .ShouldFail:
            throw ApproovError.permanentError(message: "Token fetch for \(hostname): \(response.sdkMessage)")
        }
    }

    /**
     * Maps an error thrown by a mutator callback (or internal processing) onto a decision and an
     * error on the response. Networking errors map to ShouldRetry; everything else to ShouldFail.
     */
    private static func applyMutatorError(_ error: Error,
                                          response: inout ApproovUpdateResponse,
                                          context: String) {
        if let approovError = error as? ApproovError {
            response.error = approovError
            switch approovError {
            case .networkingError:
                response.decision = .ShouldRetry
            default:
                response.decision = .ShouldFail
            }
        } else {
            response.error = ApproovError.permanentError(message: "\(context): \(error.localizedDescription)")
            response.decision = .ShouldFail
        }
    }

    /**
     * Mutator-integrated request processing. Builds an ApproovRequest, runs the configured
     * service mutator at each decision point (exclusion, token fetch, header substitution and
     * the final processed-request hook) and returns the resulting decision and mutated request.
     *
     * gRPC carries no URL/query/body at the interceptor layer, so only header-based mutation and
     * (hostname-based) exclusion matching are performed.
     */
    public static func updateRequestWithApproov(request: ApproovRequest) -> ApproovUpdateResponse {
        let hostname = request.hostname
        let changes = ApproovRequestMutations()

        if !isApproovEnabled() {
            if loggingLevel >= .info {
                os_log("ApproovService: Approov unavailable, forwarding: %@", type: .info, hostname)
            }
            return ApproovUpdateResponse(request: request, decision: .ShouldIgnore, sdkMessage: "", error: nil)
        }

        let mutator = getServiceMutator()

        // Exclusion check: an excluded request is forwarded without any mutation.
        do {
            if try !mutator.handleInterceptorShouldProcessRequest(request) {
                if loggingLevel >= .info {
                    os_log("ApproovService: excluded, forwarding: %@", type: .info, hostname)
                }
                return ApproovUpdateResponse(request: request, decision: .ShouldIgnore, sdkMessage: "", error: nil)
            }
        } catch {
            var response = ApproovUpdateResponse(request: request, decision: .ShouldFail, sdkMessage: "", error: nil)
            applyMutatorError(error, response: &response, context: "Interceptor should process request")
            return response
        }

        var response = ApproovUpdateResponse(request: request, decision: .ShouldFail, sdkMessage: "", error: nil)
        let allHeaders = request.headers

        // Check if Bind Header is set to a non empty string
        let bindHeaderName = stateLock.withLock { _bindHeader }
        if bindHeaderName != "" {
            if let value = allHeaders.first(name: bindHeaderName) {
                Approov.setDataHashInToken(value)
            }
        }

        // Fetch the Approov token
        let approovResult = Approov.fetchTokenAndWait(hostname)
        if loggingLevel >= .info {
            os_log("ApproovService: update headers %@: %@", type: .info, hostname, approovResult.loggableToken())
        }
        if approovResult.isConfigChanged {
            Approov.fetchConfig()
            if loggingLevel >= .info {
                os_log("ApproovService: dynamic configuration update received")
            }
        }

        response.sdkMessage = Approov.string(from: approovResult.status)

        var setTokenHeaderKey: String?
        var setTokenHeaderValue: String?
        var setTraceIDHeaderKey: String?
        var setTraceIDHeaderValue: String?

        do {
            let shouldAddToken = try mutator.handleInterceptorFetchTokenResult(approovResult, url: hostname)
            response.decision = .ShouldProceed
            if !shouldAddToken {
                // Status such as unprotectedURL / unknownURL / noApproovService: forward unmodified.
                return response
            }
        } catch {
            applyMutatorError(error, response: &response, context: "Approov token fetch")
            return response
        }

        let tokenHeader = stateLock.withLock { _approovTokenHeader }
        let tokenPrefix = stateLock.withLock { _approovTokenPrefix }
        setTokenHeaderKey = tokenHeader
        if approovResult.token.isEmpty && (stateLock.withLock { _useApproovStatusIfNoToken }) {
            // §2 Token Fallback Status: surface the fetch status to the backend in place of a token.
            setTokenHeaderValue = tokenPrefix + response.sdkMessage
        } else {
            setTokenHeaderValue = tokenPrefix + approovResult.token
        }

        // Emit the trace-ID header if a trace-ID header name is configured. §2 Missing Artifacts
        // Fallback: emit it even when the SDK returns an empty trace ID, so the backend still sees
        // evidence that Approov processing occurred (mirrors the token header, always emitted).
        if let traceHeader = stateLock.withLock({ _approovTraceIDHeader }), !traceHeader.isEmpty {
            setTraceIDHeaderKey = traceHeader
            setTraceIDHeaderValue = approovResult.traceID
        }

        // Deal with header substitutions, which may require further fetches but these should be
        // using cached results.
        var setSubstitutionHeaders: [String: String] = [:]
        let subsHeadersCopy = getSubstitutionHeaders()
        for (header, prefix) in subsHeadersCopy {
            if let value = allHeaders.first(name: header) {
                if value.hasPrefix(prefix) && (value.count > prefix.count) {
                    let lookupKey = String(value.dropFirst(prefix.count))
                    let approovResults = Approov.fetchSecureStringAndWait(lookupKey, nil)
                    if loggingLevel >= .info {
                        os_log("ApproovService: Substituting header: %@, %@", type: .info, header,
                               Approov.string(from: approovResults.status))
                    }
                    do {
                        if try mutator.handleInterceptorHeaderSubstitutionResult(approovResults, header: header) {
                            if let secureStringResult = approovResults.secureString {
                                if !secureStringResult.isEmpty {
                                    setSubstitutionHeaders[header] = prefix + secureStringResult
                                }
                            } else {
                                response.decision = .ShouldFail
                                response.error = ApproovError.permanentError(message: "Header substitution: key lookup error")
                                return response
                            }
                        }
                    } catch {
                        applyMutatorError(error, response: &response, context: "Header substitution for \(header)")
                        return response
                    }
                }
            }
        }

        // Apply all of the changes to the request.
        if let tokenHeaderKey = setTokenHeaderKey,
           let tokenHeaderValue = setTokenHeaderValue {
            response.request.headers.replaceOrAdd(name: tokenHeaderKey, value: tokenHeaderValue)
            changes.setTokenHeaderKey(tokenHeaderKey)
        }
        if let traceIDHeaderKey = setTraceIDHeaderKey,
           let traceIDHeaderValue = setTraceIDHeaderValue {
            response.request.headers.replaceOrAdd(name: traceIDHeaderKey, value: traceIDHeaderValue)
            changes.setTraceIDHeaderKey(traceIDHeaderKey)
        }
        if !setSubstitutionHeaders.isEmpty {
            for (header, value) in setSubstitutionHeaders {
                response.request.headers.replaceOrAdd(name: header, value: value)
            }
            changes.setSubstitutionHeaderKeys(Array(setSubstitutionHeaders.keys))
        }

        // Call the processed request callback for any final modifications.
        do {
            response.request = try mutator.handleInterceptorProcessedRequest(response.request, changes: changes)
        } catch {
            applyMutatorError(error, response: &response, context: "Interceptor processed request")
            return response
        }

        return response
    }

    /**
     * Adds the name of a header which should be subject to secure strings substitution. This
     * means that if the header is present then the value will be used as a key to look up a
     * secure string value which will be substituted into the header value instead. This allows
     * easy migration to the use of secure strings. A required prefix may be specified to deal
     * with cases such as the use of "Bearer " prefixed before values in an authorization header.
     *
     * @param header is the header to be marked for substitution
     * @param prefix is any required prefix to the value being substituted or nil if not required
     */
    public static func addSubstitutionHeader(header: String, prefix: String?) {
        if prefix == nil {
            stateLock.withLock {
                substitutionHeaders[header] = ""
            }
        } else {
            stateLock.withLock {
                substitutionHeaders[header] = prefix
            }
        }
    }

    /**
     * Removes the name of a header if it exists from the secure strings substitution dictionary.
     */
    public static func removeSubstitutionHeader(header: String) {
        stateLock.withLock {
            if substitutionHeaders[header] != nil {
                substitutionHeaders.removeValue(forKey: header)
            }
        }
    }

    public static func getSubstitutionHeaders() -> Dictionary<String, String> {
        stateLock.withLock { substitutionHeaders }
    }

    /**
     * Adds an exclusion URL regular expression. Requests whose URL matches any registered
     * exclusion regex are forwarded by the interceptor without Approov request mutation.
     *
     * gRPC has no natural request URL at the interceptor layer, so the regex is matched against
     * the request hostname (or "https://<hostname><path>" if a path is available). This is a
     * limitation of the gRPC adaptation compared to URL-based service layers.
     */
    public static func addExclusionURLRegex(urlRegex: String) {
        stateLock.withLock {
            do {
                let regex = try NSRegularExpression(pattern: urlRegex, options: [])
                exclusionURLRegexs[urlRegex] = regex
                if _loggingLevel >= .debug {
                    os_log("ApproovService: addExclusionURLRegex: %@", type: .debug, urlRegex)
                }
            } catch {
                // The pattern was rejected and no exclusion was registered; surface this at error
                // level so callers are not left believing an invalid regex took effect.
                if _loggingLevel >= .error {
                    os_log("ApproovService: addExclusionURLRegex: %@ rejected, exclusion NOT added: %@",
                           type: .error, urlRegex, error.localizedDescription)
                }
            }
        }
    }

    /**
     * Removes an exclusion URL regular expression previously added using addExclusionURLRegex.
     */
    public static func removeExclusionURLRegex(urlRegex: String) {
        stateLock.withLock {
            if exclusionURLRegexs[urlRegex] != nil {
                exclusionURLRegexs.removeValue(forKey: urlRegex)
                if _loggingLevel >= .debug {
                    os_log("ApproovService: removeExclusionURLRegex: %@", type: .debug, urlRegex)
                }
            }
        }
    }

    public static func getExclusionURLRegexs() -> Dictionary<String, NSRegularExpression> {
        stateLock.withLock { exclusionURLRegexs }
    }

    /**
     * Gets the device ID used by Approov to identify the particular device that the SDK is running on. Note
     * that different Approov apps on the same device will return a different ID. Moreover, the ID may be
     * changed by an uninstall and reinstall of the app.
     *
     * @return String of the device ID
     * @throws ApproovError if there was a problem
     */
    public static func getDeviceID() throws -> String {
        if !isApproovEnabled() {
            logApproovUnavailable("getDeviceID")
            throw ApproovError.permanentError(message: "getDeviceID: SDK not initialized")
        }
        if let deviceID: String = Approov.getDeviceID() {
            os_log("ApproovService: getDeviceID: %@", type: .debug, deviceID)
            return deviceID
        }
        throw ApproovError.runtimeError(message: "getDeviceID: no device ID")
    }

    /**
     * Directly sets the data hash to be included in subsequently fetched Approov tokens. If the hash is
     * different from any previously set value then this will cause the next token fetch operation to
     * fetch a new token with the correct payload data hash. The hash appears in the
     * 'pay' claim of the Approov token as a base64 encoded string of the SHA256 hash of the
     * data. Note that the data is hashed locally and never sent to the Approov cloud service.
     *
     * @param data is the data to be hashed and set in the token
     */
    public static func setDataHashInToken(data: String) {
        if !isApproovEnabled() {
            logApproovUnavailable("setDataHashInToken")
            return
        }
        Approov.setDataHashInToken(data)
        os_log("ApproovService: setDataHashInToken", type: .debug)
    }

    /**
     * Performs an Approov token fetch for the given URL. This should be used in situations where it
     * is not possible to use the networking interception to add the token. This will
     * likely require network access so may take some time to complete. If the attestation fails
     * for any reason then an ApproovError is thrown. This will be ApproovNetworkException for
     * networking issues wher a user initiated retry of the operation should be allowed. Note that
     * the returned token should NEVER be cached by your app, you should call this function when
     * it is needed.
     *
     * @param url is the URL giving the domain for the token fetch
     * @return String of the fetched token
     * @throws ApproovError if there was a problem
     */
    public static func fetchToken(url: String) throws -> String {
        if !isApproovEnabled() {
            logApproovUnavailable("fetchToken")
            throw ApproovError.permanentError(message: "fetchToken: SDK not initialized")
        }
        let result: ApproovTokenFetchResult = Approov.fetchTokenAndWait(url)
        if loggingLevel >= .debug {
            os_log("ApproovService: fetchToken: %@", type: .debug, Approov.string(from: result.status))
        }
        try wrappingApproovError("fetchToken") {
            try getServiceMutator().handleFetchTokenResult(result)
        }
        return result.token
    }

    /**
     * Gets the signature for the given message. This uses an account specific message signing key that is
     * transmitted to the SDK after a successful fetch if the facility is enabled for the account. Note
     * that if the attestation failed then the signing key provided is actually random so that the
     * signature will be incorrect. An Approov token should always be included in the message
     * being signed and sent alongside this signature to prevent replay attacks. If no signature is
     * available, because there has been no prior fetch or the feature is not enabled, then an
     * ApproovError is thrown.
     *
     * @param message is the message whose content is to be signed
     * @return String of the base64 encoded message signature
     * @throws ApproovError if there was a problem
     */
    @available(*, deprecated, message: "Use getAccountMessageSignature or getInstallMessageSignature instead.")
    public static func getMessageSignature(message: String) throws -> String {
        guard let signature = getAccountMessageSignature(message: message) else {
            throw ApproovError.permanentError(message: "getMessageSignature: no signature available")
        }
        return signature
    }

    /**
     * Gets the account message signature for the given message. This uses an account specific
     * message signing key transmitted to the SDK after a successful fetch if the facility is
     * enabled for the account. Returns nil if no signature is available (no prior fetch, the
     * feature is not enabled, or the service layer is in bypass mode).
     */
    public static func getAccountMessageSignature(message: String) -> String? {
        if !isApproovEnabled() {
            logApproovUnavailable("getAccountMessageSignature")
            return nil
        }
        return Approov.getMessageSignature(message)
    }

    /**
     * Gets the install message signature for the given message. This uses an install specific
     * signing key. Returns nil if no signature is available (e.g. key pair generation is not
     * supported on the device) or if the service layer is in bypass mode.
     */
    public static func getInstallMessageSignature(message: String) -> String? {
        if !isApproovEnabled() {
            logApproovUnavailable("getInstallMessageSignature")
            return nil
        }
        return Approov.getInstallMessageSignature(message)
    }

    /**
     * Fetches a secure string with the given key. If newDef is not nil then a secure string for
     * the particular app instance may be defined. In this case the new value is returned as the
     * secure string. Use of an empty string for newDef removes the string entry. Note that this
     * call may require network transaction and thus may block for some time, so should not be called
     * from the UI thread. If the attestation fails for any reason then an exception is raised. Note
     * that the returned string should NEVER be cached by your app, you should call this function when
     * it is needed. If the fetch fails for any reason an exception is thrown with description. Exceptions
     * could be due to the feature not being enabled from the CLI tools (ApproovError.configurationError
     * type raised), a rejection throws an Approov.rejectionError type which might include additional
     * information regarding the failure reason. An ApproovError.networkingError exception should allow a
     * retry operation to be performed and finally if some other error occurs an Approov.permanentError
     * is raised.
     *
     * @param key is the secure string key to be looked up
     * @param newDef is any new definition for the secure string, or nil for lookup only
     * @return secure string (should not be cached by your app) or nil if it was not defined or an error ocurred
     * @throws exception with description of cause
     */
    public static func fetchSecureString(key: String, newDef: String?) throws -> String? {
        if !isApproovEnabled() {
            logApproovUnavailable("fetchSecureString")
            throw ApproovError.permanentError(message: "fetchSecureString: SDK not initialized")
        }
        // Determine the type of operation as the values themselves cannot be logged
        let type = newDef != nil ? "definition" : "lookup"
        let approovResult = Approov.fetchSecureStringAndWait(key, newDef)
        if loggingLevel >= .info {
            os_log("ApproovService: fetchSecureString: %@: %@", type: .info, type, Approov.string(from: approovResult.status))
        }
        try wrappingApproovError("fetchSecureString \(type) for \(key)") {
            try getServiceMutator().handleFetchSecureStringResult(approovResult, operation: type, key: key)
        }
        return approovResult.secureString
    }

    /**
     * Fetches a custom JWT with the given payload. Note that this call will require network
     * transaction and thus will block for some time, so should not be called from the UI thread.
     * If the fetch fails for any reason an exception will be thrown. Exceptions could be due to
     * malformed JSON string provided (then a ApproovError.permanentError is raised), the feature not
     * being enabled from the CLI tools (ApproovError.configurationError type raised), a rejection throws
     * a ApproovError.rejectionError type which might include additional information regarding the failure
     * reason. An Approov.networkingError exception should allow a retry operation to be performed. Finally
     * if some other error occurs an Approov.permanentError is raised.
     *
     * @param payload is the marshaled JSON object for the claims to be included
     * @return custom JWT string
     * @throws exception with description of cause
     */
    public static func fetchCustomJWT(payload: String) throws -> String {
        if !isApproovEnabled() {
            logApproovUnavailable("fetchCustomJWT")
            throw ApproovError.permanentError(message: "fetchCustomJWT: SDK not initialized")
        }
        let approovResult = Approov.fetchCustomJWTAndWait(payload)
        if loggingLevel >= .info {
            os_log("ApproovService: fetchCustomJWT: %@", type: .info, Approov.string(from: approovResult.status))
        }
        try wrappingApproovError("fetchCustomJWT") {
            try getServiceMutator().handleFetchCustomJWTResult(approovResult)
        }
        return approovResult.token
    }

    /**
     * Performs a precheck to determine if the app will pass attestation. This requires secure
     * strings to be enabled for the account, although no strings need to be set up. This will
     * likely require network access so may take some time to complete. It may throw an exception
     * if the precheck fails or if there is some other problem. Exceptions could be due to
     * a rejection (throws a ApproovError.rejectionError) type which might include additional
     * information regarding the rejection reason. An ApproovError.networkingError exception should
     * allow a retry operation to be performed and finally if some other error occurs an
     * ApproovError.permanentError is raised.
     */
    public static func precheck() throws {
        if !isApproovEnabled() {
            logApproovUnavailable("precheck")
            throw ApproovError.permanentError(message: "precheck: SDK not initialized")
        }
        // Try to fetch a non-existent secure string in order to check for a rejection
        let approovResults = Approov.fetchSecureStringAndWait("precheck-dummy-key", nil)
        if loggingLevel >= .debug {
            os_log("ApproovService: precheck: %@", type: .debug, Approov.string(from: approovResults.status))
        }
        try wrappingApproovError("precheck") {
            try getServiceMutator().handlePrecheckResult(approovResults)
        }
    }

    /**
     * Gets the last ARC (Attestation Response Code) code.
     * NOTE: You MUST only call this method upon succesfull attestation completion. Any networking
     * errors returned from the service layer will not return a meaningful ARC code (empty string) if the method is called!!!
     * @return String of the last ARC or empty string if there was none
     */
    public static func getLastARC() -> String {
        if !isApproovEnabled() {
            logApproovUnavailable("getLastARC")
            return ""
        }
        // We have to get the current config and obtain one protected API endpoint at least
        // get the dynamic pins from Approov
        guard let approovPins = Approov.getPins("public-key-sha256") else {
            os_log("ApproovService: no host pinning information available", type: .error)
            return ""
        }
        // The approovPins contains a map of hostnames to pin strings.  We need to skip the '*' entry (Managed Trust Roots),
        // and use another hostname if available.
            if let hostname = approovPins.keys.first(where: { $0 != "*" }) {
                let result = Approov.fetchTokenAndWait(hostname)
                // Check if a token was fetched successfully and return its arc code
                if result.token.count > 0 {
                    return result.arc
                }
            }
        os_log("ApproovService: ARC code unavailable", type: .info)
        return ""
    }

    /**
    * Sets an install attributes token to be sent to the server and associated with this particular
    * app installation for future Approov token fetches. The token must be signed, within its
    * expiry time and bound to the correct device ID for it to be accepted by the server.
    * Calling this method ensures that the next call to fetch an Approov
    * token will not use a cached version, so that this information can be transmitted to the server.
    *
    * @param attrs is the signed JWT holding the new install attributes
    */
    public static func setInstallAttributes(attrs: String) {
        if !isApproovEnabled() {
            logApproovUnavailable("setInstallAttributes")
            return
        }
        Approov.setInstallAttrsInToken(attrs)
        os_log("ApproovService: setInstallAttributes", type: .info)
    }

}
