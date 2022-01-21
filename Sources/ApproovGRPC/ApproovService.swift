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
import Approov

/*
 * Approov error conditions
 */
public enum ApproovError: Error {
    case initializationFailure(message: String)
    case configurationFailure(message: String)
    case networkError(message: String)
    case runtimeError(message: String)
    var localizedDescription: String? {
        switch self {
        case let .initializationFailure(message), let .configurationFailure(message), let .networkError(message), let .runtimeError(message):
            return message
        }
    }
}

// ApproovService provides a mediation layer to the Approov SDK itself
public class ApproovService {

    /* Dynamic configuration string key in user default database */
    public static let kApproovDynamicKey = "approov-dynamic"

    /* Initial configuration string/filename for Approov SDK */
    public static let kApproovInitialKey = "approov-initial"

    /* Initial configuration file extention for Approov SDK */
    public static let kConfigFileExtension = "config"

    /* Private initializer */
    fileprivate init(){}

    /* Status of Approov SDK initialisation */
    private static var approovSDKInitialised = false

    /* Singleton: configString is obtained using `approov sdk -getConfigString` */
    static let sharedInstance: ApproovService? = {
        let instance = ApproovService()
        var initialConfigString: String?
        // If configString is not set during session initialization read the initial config file
        if ApproovService.approovConfigString == nil {
            initialConfigString = readInitialApproovConfig()
        } else {
            initialConfigString = ApproovService.approovConfigString
        }
        /* Read initial config */
        if initialConfigString != nil {
            /* Read dynamic config  */
            let dynamicConfigString = readDynamicApproovConfig()
            /* Initialise Approov SDK */
            do {
                try Approov.initialize(initialConfigString!, updateConfig: dynamicConfigString, comment: nil)
                approovSDKInitialised = true
                /* Save updated SDK config if this is the first ever app launch */
                if dynamicConfigString == nil {
                    storeDynamicConfig(newConfig: Approov.fetchConfig()!)
                }
            } catch let error {
                print("Error initilizing Approov SDK: \(error.localizedDescription)")
            }
        } else {
            print("FATAL: Unable to initialize Approov SDK")
        }
        return instance
    }()

    // Dispatch queue to manage concurrent access to bindHeader variable
    private static let bindHeaderQueue = DispatchQueue(label: "ApproovService.bindHeader", qos: .default, attributes: .concurrent, autoreleaseFrequency: .never, target: DispatchQueue.global())

    // Bind Header string
    private static var _bindHeader = ""

    // Public setter/getter for bind header
    public static var bindHeader: String {
        get {
            var bindHeader = ""
            bindHeaderQueue.sync {
                bindHeader = _bindHeader
            }
            return bindHeader
        }
        set {
            bindHeaderQueue.async(group: nil, qos: .default, flags: .barrier, execute: {self._bindHeader = newValue})
        }
    }

    // Dispatch queue to manage concurrent access to approovTokenHeader variable
    private static let approovTokenHeaderAndPrefixQueue = DispatchQueue(label: "ApproovService.approovTokenHeader",
        qos: .default, attributes: .concurrent, autoreleaseFrequency: .never, target: DispatchQueue.global())

    /* Approov token default header */
    private static var _approovTokenHeader = "Approov-Token"

    /* Approov token custom prefix: any prefix to be added such as "Bearer " */
    private static var _approovTokenPrefix = ""

    // Approov Token Header String
    public static var approovTokenHeaderAndPrefix: (approovTokenHeader: String, approovTokenPrefix: String) {
        get {
            var approovTokenHeader = ""
            var approovTokenPrefix = ""
            approovTokenHeaderAndPrefixQueue.sync {
                approovTokenHeader = _approovTokenHeader
                approovTokenPrefix = _approovTokenPrefix
            }
            return (approovTokenHeader,approovTokenPrefix)
        }
        set {
            approovTokenHeaderAndPrefixQueue.async(group: nil, qos: .default, flags: .barrier, execute: {(_approovTokenHeader,_approovTokenPrefix) = newValue})
        }
    }

    // Initialization configuration string: NOTE this can only ever be written to ONCE since Approov SDK can only
    // ever be initialized once
    private static var _approovConfigString: String?

    // Public setter/getter for configuration
    static var approovConfigString: String? {
        set (newValue) {
            if (_approovConfigString == nil) {
                _approovConfigString = newValue
            }
        }
        get {
            return _approovConfigString
        }
    }

    /**
     * Reads any previously-saved dynamic configuration for the Approov SDK. May return 'nil' if a
     * dynamic configuration has not yet been saved by calling saveApproovDynamicConfig().
     */
    static public func readDynamicApproovConfig() -> String? {
        return UserDefaults.standard.object(forKey: kApproovDynamicKey) as? String
    }

    /**
     *  Reads the initial configuration file for the Approov SDK
     *  The file defined as kApproovInitialKey.kConfigFileExtension
     *  is read from the app bundle main directory
     */
    static public func readInitialApproovConfig() -> String? {
        // Attempt to load the initial config from the app bundle directory
        guard let originalFileURL = Bundle.main.url(forResource: kApproovInitialKey, withExtension: kConfigFileExtension) else {
            /*  This is fatal since we can not load the initial configuration file */
            print("FATAL: unable to load Approov SDK config file from app bundle directories")
            return nil
        }

        // Read file contents
        do {
            let fileExists = try originalFileURL.checkResourceIsReachable()
            if !fileExists {
                print("FATAL: No initial Approov SDK config file available")
                return nil
            }
            let configString = try String(contentsOf: originalFileURL)
            return configString
        } catch let error {
            print("FATAL: Error attempting to read inital configuration for Approov SDK from \(originalFileURL): \(error)")
            return nil
        }
    }

    /**
     * Saves the Approov dynamic configuration to the user defaults database which is persisted
     * between app launches. This should be called after every Approov token fetch where
     * isConfigChanged is set. It saves a new configuration received from the Approov server to
     * the user defaults database so that it is available on app startup on the next launch.
     */
    static public func storeDynamicConfig(newConfig: String) {
        if let updateConfig = Approov.fetchConfig() {
            UserDefaults.standard.set(updateConfig, forKey: kApproovDynamicKey)
        }
    }

    /**
     *  Allows token prefetch operation to be performed as early as possible. This
     *  permits a token to be available while an application might be loading resources
     *  or is awaiting user input. Since the initial token fetch is the most
     *  expensive the prefetch seems reasonable.
     */
    public static func prefetchApproovToken() {
        let _ = ApproovService.sharedInstance
        if approovSDKInitialised {
            // We succeeded initializing Approov SDK, fetch a token
            Approov.fetchToken({(approovResult: ApproovTokenFetchResult) in
                // Prefetch done, no need to process response
            }, "approov.io")
        }
    }

}
