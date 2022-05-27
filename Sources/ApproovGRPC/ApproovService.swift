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

/** ApproovService provides a mediation layer to the Approov SDK itself */
public class ApproovService {

    /** Private initializer to disallow instantiation as this is a static only class */
    fileprivate init(){}

    /** Lock to manage intialization */
    private static let initLock = Lock()

    /** Status of Approov SDK initialisation */
    private static var approovSDKInitialised = false

    /**
     * Initializes the ApproovService with an account configuration.
     *
     * Note the initializer function should only ever be called once. Subsequent calls will be ignored since the
     * Approov SDK can only be intialized once; if however, an attempt is made to initialize with a different
     * configuration we throw an `ApproovError.configurationError`. If the Approov SDK fails to be initialized for some
     * other reason, an `ApproovError.initializationFailure` is raised.
     *
     * @param config the configuration string, or empty for no SDK initialization. The configuration string is obtained
     *               using `approov sdk -getConfigString` or through an Approov onboarding email.
     */
    public static func initialize(config: String) throws {
        if config.isEmpty {
            return
        }
        try initLock.withLock {
            // Check if we attempt to use a different configString
            if (approovSDKInitialised) {
                if (config != approovConfigString) {
                    // Throw exception indicating we are attempting to use different config
                    let errorMessage = "Attempting to initialize with different configuration"
                    os_log("ApproovService: %@", type: .error, errorMessage)
                    throw ApproovError.configurationError(message: errorMessage)
                }
                return
            }
            // Initialize Approov SDK
            do {
                try Approov.initialize(config, updateConfig: "auto", comment: nil)
                approovConfigString = config
                approovSDKInitialised = true
                Approov.setUserProperty("approov-service-grpc")
            } catch let error {
                // Log error and throw exception
                let errorMessage = "Error initializing Approov SDK: \(error.localizedDescription)"
                os_log("ApproovService: %@", type: .error, errorMessage)
                throw ApproovError.initializationFailure(message: errorMessage)
            }
        }
    }

    /** Lock to manage variable access */
    private static let stateLock = Lock()

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

    /** Initialization configuration string. NOTE this must only ever be written to ONCE since Approov SDK can only
     * be initialized once */
    private static var _approovConfigString: String?

    // Public setter/getter for configuration
    static var approovConfigString: String? {
        set (newValue) {
            stateLock.withLock {
                if (_approovConfigString == nil) {
                    _approovConfigString = newValue
                }
            }
        }
        get {
            stateLock.withLock {
                return _approovConfigString
            }
        }
    }

    /**
     * Allows token prefetch operation to be performed as early as possible. This permits a token to be available while
     * an application might be loading resources or is awaiting user input. Since the initial token fetch is the most
     * expensive the prefetch can hide the most latency.
     */
    public static func prefetch() {
        initLock.withLock {
            if approovSDKInitialised {
                // We succeeded initializing Approov SDK, fetch a token
                Approov.fetchToken({(approovResult: ApproovTokenFetchResult) in
                    // Prefetch done, no need to process response
                }, "approov.io")
            }
        }
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
    public static func updateRequestHeaders(headers: HPACKHeaders, hostname: String) throws -> HPACKHeaders {

        // Check if Bind Header is set to a non empty string
        if bindHeader != "" {
            if let aValue = headers.first(name: bindHeader) {
                // Add the Bind Header as a data hash to Approov token
                Approov.setDataHashInToken(aValue)
            }
        }
        // Fetch the Approov token
        let result: ApproovTokenFetchResult = Approov.fetchTokenAndWait(hostname)
        os_log("ApproovService: update headers %@: %@", type: .info, hostname, result.loggableToken())

        var updatedHeaders: HPACKHeaders = [:]
        switch result.status {
        case .success:
            // Can go ahead and make the API call with the provided request object
            // Set Approov-Token header
            updatedHeaders.add(name: approovTokenHeaderAndPrefix.approovTokenHeader,
                value: approovTokenHeaderAndPrefix.approovTokenPrefix + result.token)
            break
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            // We are unable to get an Approov token due to network conditions so - unless this is overridden - we must
            // not proceed with the network request. The request can be retried by the user later.
            if !proceedOnNetworkFail {
                throw ApproovError.networkingError(message: "Token fetch for " + hostname + ": " +
                    Approov.string(from: result.status))
            }
        case .unprotectedURL,
             .unknownURL,
             .noApproovService:
            // We do NOT add the Approov-Token header to the request headers and proceed
            break
        default:
            // We have failed to get an Approov token with a more serious permanent error
            throw ApproovError.permanentError(message: "Token fetch for " + hostname + ": " +
                Approov.string(from: result.status))
        }

        // We only continue additional processing if we had a valid status from Approov, to prevent additional delays
        // by trying to fetch from Approov again and this also protects against header substitutions in domains not
        // protected by Approov and therefore are potentially subject to a MitM.
        if (result.status != .success) && (result.status != .unprotectedURL) {
            return updatedHeaders;
        }

        // Deal with any header substitutions, which may require further fetches but these should be using cached
        // results
        for headerIndex in headers.indices {
            let headerName = headers[headerIndex].name
            var headerValue = headers[headerIndex].value
            // Check whether header is eligible for substitution
            var substHeaderValuePrefix: String?
            stateLock.withLock {
                substHeaderValuePrefix = substitutionHeaders[headerName]
            }
            if substHeaderValuePrefix != nil {
                // We need to check whether there is a substitution available in Approov
                // Remove prefix from header value before lookup
                if (substHeaderValuePrefix!.count > 0 && headerValue.hasPrefix(substHeaderValuePrefix!)) {
                    headerValue.removeFirst(substHeaderValuePrefix!.count)
                }
                // Look up header value in Approov
                let approovResults = Approov.fetchSecureStringAndWait(String(headerValue), nil)
                os_log("ApproovService: Substituting header: %@, %@", type: .info, headerName,
                    Approov.string(from: approovResults.status))
                // Process the result of the secure string fetch operation
                switch approovResults.status {
                case .success:
                    // Add the modified header to the updated headers
                    if let secureStringResult = approovResults.secureString {
                        updatedHeaders.add(name: headerName,
                                           value: substHeaderValuePrefix! + secureStringResult)
                    } else {
                        // Secure string is nil
                        throw ApproovError.permanentError(message: "Header substitution: key lookup error")
                    }
                case .rejected:
                    // If the request is rejected then we provide a special exception with additional information
                    throw ApproovError.rejectionError(message: "Header substitution: rejected",
                        ARC: approovResults.arc, rejectionReasons: approovResults.rejectionReasons)
                case .noNetwork,
                     .poorNetwork,
                     .mitmDetected:
                    // We are unable to get the secure string due to network conditions, so - unless this is overridden
                    // - we mustnot proceed. The request can be retried by the user later.
                    if !proceedOnNetworkFail {
                        throw ApproovError.networkingError(message: "Header substitution: network issue, retry needed")
                    }
                case .unknownKey:
                    // We have failed to get a secure string with a more serious permanent error
                    throw ApproovError.permanentError(message: "Header substitution: " +
                        Approov.string(from: approovResults.status))
                default:
                    // Add the original header to the updated headers
                    updatedHeaders.add(name: headerName, value: substHeaderValuePrefix! + headerValue)
                }
            } else {
                // No substitution defined, copy original header
                updatedHeaders.add(name: headerName, value: headerValue)
            }
        }
        return updatedHeaders
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

    /**
     * Gets the device ID used by Approov to identify the particular device that the SDK is running on. Note
     * that different Approov apps on the same device will return a different ID. Moreover, the ID may be
     * changed by an uninstall and reinstall of the app.
     *
     * @return String of the device ID
     * @throws ApproovError if there was a problem
     */
    public static func getDeviceID() throws -> String {
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
        Approov.setDataHashInToken(data);
        os_log("ApproovService: setDataHashInToken", type: .debug);
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
        // Fetch the Approov token
        let result: ApproovTokenFetchResult = Approov.fetchTokenAndWait(url)
        os_log("ApproovService: fetchToken: %@", type: .debug, Approov.string(from: result.status))

        // Process the status
        switch result.status {
        case .success:
            // Provide the Approov token result
            return result.token
        case .noNetwork,
             .poorNetwork,
             .mitmDetected:
            // We are unable to get an Approov token due to network conditions
            throw ApproovError.networkingError(message: "fetchToken: " + Approov.string(from: result.status))
        default:
            // We have failed to get an Approov token due to a more permanent error
            throw ApproovError.permanentError(message: "fetchToken: " + Approov.string(from: result.status))
        }
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
    public static func getMessageSignature(message: String) throws -> String {
        if let signature: String = Approov.getMessageSignature(message) {
            os_log("ApproovService: getMessageSignature", type: .debug);
            return signature
        }
        throw ApproovError.permanentError(message: "getMessageSignature: no signature available");
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
        // Determine the type of operation as the values themselves cannot be logged
        var type = "lookup"
        if newDef == nil {
            type = "definition"
        }
        // Fetch the secure string
        let approovResult = Approov.fetchSecureStringAndWait(key, newDef)
        os_log("ApproovService: fetchSecureString: %@: %@", type: .info, type, Approov.string(from: approovResult.status))
        // Process the returned Approov status
        switch approovResult.status {
        case .success,
            .unknownKey:
            break
        case .disabled:
            throw ApproovError.configurationError(message: "fetchSecureString: secure string feature disabled")
        case .badKey:
            throw ApproovError.permanentError(message: "fetchSecureString: secure string unknown key")
        case .rejected:
            // If the request is rejected then we provide a special exception with additional information
            throw ApproovError.rejectionError(message: "fetchSecureString: rejected", ARC: approovResult.arc,
                rejectionReasons: approovResult.rejectionReasons)
        case .noNetwork,
            .poorNetwork,
            .mitmDetected:
            // We are unable to get the secure string due to network conditions so the request can
            // be retried by the user later
            throw ApproovError.networkingError(message: "fetchSecureString: network issue, retry needed")
        default:
            // We are unable to get the secure string due to a more permanent error
            throw ApproovError.permanentError(message: "fetchSecureString: " +
                Approov.string(from: approovResult.status))

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
     * @return custom JWT string or nil if an error occurred
     * @throws exception with description of cause
     */
    public static func fetchCustomJWT(payload: String) throws -> String? {
        // Fetch the custom JWT
        let approovResult = Approov.fetchCustomJWTAndWait(payload)
        // Log result of token fetch operation but do not log the value
        os_log("ApproovService: fetchCustomJWT: %@", type: .info, Approov.string(from: approovResult.status))
        // Process the returned Approov status
        switch approovResult.status {
        case .success:
            break
        case .badPayload:
            throw ApproovError.permanentError(message: "fetchCustomJWT: malformed JSON")
        case .disabled:
            throw ApproovError.configurationError(message: "fetchCustomJWT: feature not enabled")
        case .rejected:
            // If the request is rejected then we provide a special exception with additional information
            throw ApproovError.rejectionError(message: "fetchCustomJWT: rejected", ARC: approovResult.arc,
                rejectionReasons: approovResult.rejectionReasons)
        case .noNetwork,
            .poorNetwork,
            .mitmDetected:
            // We are unable to get the custom JWT due to network conditions so the request can
            // be retried by the user later
            throw ApproovError.networkingError(message: "fetchCustomJWT: network issue, retry needed")
        default:
            // We are unable to get the custom JWT due to a more permanent error
            throw ApproovError.permanentError(message: "fetchCustomJWT: " + Approov.string(from: approovResult.status))
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
        // Try to fetch a non-existent secure string in order to check for a rejection
        let approovResults = Approov.fetchSecureStringAndWait("precheck-dummy-key", nil)
        // Process the returned Approov status
        switch approovResults.status {
        case .success,
            .unknownKey:
            break
        case .rejected:
            // If the request is rejected then we provide a special exception with additional information
            throw ApproovError.rejectionError(message: "precheck: rejected", ARC: approovResults.arc,
                rejectionReasons: approovResults.rejectionReasons)
        case .noNetwork,
            .poorNetwork,
            .mitmDetected:
            // We are unable to get the secure string due to network conditions so the request can
            // be retried by the user later
            throw ApproovError.networkingError(message: "precheck: network issue, retry needed")
        default:
            // We are unable to get the secure string due to a more permanent error
            throw ApproovError.permanentError(message: "precheck: " + Approov.string(from: approovResults.status))
        }
    }

}
