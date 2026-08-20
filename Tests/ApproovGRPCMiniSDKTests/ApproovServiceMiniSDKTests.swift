import XCTest
import NIOHPACK
@testable import ApproovGRPC
import Approov
import MiniSDKTestSupport

/// Integration tests for the ApproovService gRPC service layer.
/// This is a testing requirement and has no production dependency.
final class ApproovServiceMiniSDKTests: XCTestCase {
    private let validInitialConfig = "#cb-ivol#mAxOF0ekJUOC36J5XWmVmVipOcUoEdMjhPSp2FVtyTo="
    private let targetHost = "grpc.example.com"
    private let targetURLString = "https://grpc.example.com"

    override func setUpWithError() throws {
        try super.setUpWithError()
        MiniSDKAttesterProxyController.reset()
        ApproovService.resetForTesting()
        try initializeService(comment: "reinit-grpc-tests")
    }

    override func tearDown() {
        MiniSDKAttesterProxyController.reset()
        ApproovService.resetForTesting()
        super.tearDown()
    }

    private func initializeService(comment: String?) throws {
        try ApproovService.initialize(config: validInitialConfig, comment: comment)
    }

    private func scenarioJSON(caseName: String, body: String) -> String {
        return "{\n  \"activeCase\": \"\(caseName)\",\n  \"cases\": {\n    \"\(caseName)\": {\n      \(body)\n    }\n  }\n}"
    }

    private func uniqueCaseName(prefix: String) -> String {
        return "\(prefix)-\(UUID().uuidString.lowercased())"
    }

    private func reinitializeService(scenarioJSON: String, comment: String) throws {
        MiniSDKAttesterProxyController.reset()
        MiniSDKAttesterProxyController.loadScenarioJSON(scenarioJSON)
        ApproovService.resetForTesting()
        try ApproovService.initialize(config: validInitialConfig, comment: comment)
    }

    private func decodeJWTBody(_ jwt: String) -> [String: Any]? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 = base64.padding(toLength: base64.count + 4 - remainder, withPad: "=", startingAt: 0)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    // MARK: - §1 Initialization

    func testInitializeIgnoresSameConfigAndRejectsDifferentConfig() throws {
        // §1 Same Config Re-initialization: forwarded to the SDK which returns false (already
        // initialized); the service layer treats this as success and remains fully initialized.
        XCTAssertNoThrow(try ApproovService.initialize(config: validInitialConfig, comment: nil))
        XCTAssertTrue(ApproovService.isInitialized())
        XCTAssertTrue(ApproovService.isApproovEnabled())

        // §1 Different Non-empty Config Re-initialization: forwarded to the SDK which rejects it.
        // The native rejection is surfaced as an initializationFailure and the service-layer state
        // is left completely unchanged (still protected with the original config).
        let differentConfig = "#cb-other#mAxOF0ekJUOC36J5XWmVmVipOcUoEdMjhPSp2FVtyTo="
        XCTAssertThrowsError(try ApproovService.initialize(config: differentConfig, comment: nil)) { error in
            guard case ApproovError.initializationFailure = error else {
                return XCTFail("Expected initializationFailure, got \(error)")
            }
        }
        XCTAssertTrue(ApproovService.isInitialized())
        XCTAssertTrue(ApproovService.isApproovEnabled())
        XCTAssertEqual(ApproovService.approovConfigString, validInitialConfig)
    }

    func testInitializeWithEmptyConfigBypassesTokenInjection() throws {
        MiniSDKAttesterProxyController.reset()
        let domainsJSON = "\"protectedDomains\": [\"\(targetHost)\"]"
        MiniSDKAttesterProxyController.loadScenarioJSON(scenarioJSON(caseName: uniqueCaseName(prefix: "target-host"), body: domainsJSON))
        ApproovService.resetForTesting()
        try ApproovService.initialize(config: "", comment: "reinit-empty-config")

        let headers: HPACKHeaders = [:]
        let updatedHeaders = try ApproovService.updateRequestHeaders(headers: headers, hostname: targetURLString)

        XCTAssertNil(updatedHeaders.first(name: "Approov-Token"))
    }

    func testInitializeWithEmptyConfigCanLaterEnableApproov() throws {
        MiniSDKAttesterProxyController.reset()
        let domainsJSON = "\"protectedDomains\": [\"\(targetHost)\"]"
        MiniSDKAttesterProxyController.loadScenarioJSON(scenarioJSON(caseName: uniqueCaseName(prefix: "target-host"), body: domainsJSON))
        ApproovService.resetForTesting()
        try ApproovService.initialize(config: "", comment: "reinit-empty-config")

        // Assert the value, not the negation of an inequality: bypass mode must persist the
        // empty config string. Note approovConfigString is String?, so the previous
        // XCTAssertFalse(... != "") did fail on nil - it was unreadable, not permissive.
        XCTAssertEqual(ApproovService.approovConfigString, "")

        let plainHeaders: HPACKHeaders = [:]
        let plainUpdated = try ApproovService.updateRequestHeaders(headers: plainHeaders, hostname: targetURLString)
        XCTAssertNil(plainUpdated.first(name: "Approov-Token"))

        try ApproovService.initialize(config: validInitialConfig, comment: nil)

        let protectedHeaders: HPACKHeaders = [:]
        let protectedUpdated = try ApproovService.updateRequestHeaders(headers: protectedHeaders, hostname: targetURLString)
        XCTAssertNotNil(protectedUpdated.first(name: "Approov-Token"))
    }

    // MARK: - §2 Request Processing & Token Behaviors

    func testPrecheckTreatsUnknownKeyAsSuccess() throws {
        XCTAssertNoThrow(try ApproovService.precheck())
    }

    func testGetDeviceIDReturnsMiniSDKDeviceID() {
        XCTAssertEqual(try? ApproovService.getDeviceID(), "daIvmEWBA2gvZny7a/RC/w==")
    }

    func testUpdateRequestAddsTokenAndSubstitutions() throws {
        try reinitializeService(
            scenarioJSON: scenarioJSON(
                caseName: uniqueCaseName(prefix: "substitutions"),
                body: """
                "protectedDomains": ["\(targetHost)"],
                "initialSecureStrings": {
                  "header-key": "header-secret"
                }
                """
            ),
            comment: "reinit-substitutions"
        )

        ApproovService.bindHeader = "authorization"
        ApproovService.addSubstitutionHeader(header: "api-key", prefix: nil)

        var headers: HPACKHeaders = [:]
        headers.add(name: "authorization", value: "Bearer oauth-token")
        headers.add(name: "api-key", value: "header-key")

        let updatedHeaders = try ApproovService.updateRequestHeaders(headers: headers, hostname: targetURLString)

        let token = updatedHeaders.first(name: "Approov-Token")
        XCTAssertNotNil(token)
        XCTAssertEqual(updatedHeaders.first(name: "api-key"), "header-secret")

        if let tokenStr = token, let payload = decodeJWTBody(tokenStr) {
            XCTAssertEqual(payload["did"] as? String, "daIvmEWBA2gvZny7a/RC/w==")
        }
    }

    func testNoApproovServiceFailsSubstitutionClosed() throws {
        // A protected domain where the SDK cannot produce a token must still apply the substitution
        // policy, which for NO_APPROOV_SERVICE is fail closed (TESTING_REQUIREMENTS.md section 3):
        // the alternative is sending the lookup key as the credential. Before this was fixed, the
        // token-path early return skipped the substitution loop entirely, so the handler's own
        // fail-closed branch was unreachable and the placeholder went out with no error and no log.
        //
        // Both statuses have to be forced: the token fetch and the secure-string fetch are separate
        // SDK calls with independent statuses, and it is the secure-string one the substitution
        // handler judges. A real outage fails both, which is what this reproduces.
        try reinitializeService(
            scenarioJSON: scenarioJSON(
                caseName: uniqueCaseName(prefix: "no-approov-service"),
                body: """
                "protectedDomains": ["\(targetHost)"],
                "fetchApproovToken": [
                  { "urlRegex": ".*", "status": "NO_APPROOV_SERVICE" }
                ],
                "fetchSecureString": [
                  { "key": "header-key", "status": "NO_APPROOV_SERVICE" }
                ],
                "initialSecureStrings": {
                  "header-key": "header-secret"
                }
                """
            ),
            comment: "reinit-no-approov-service"
        )

        ApproovService.addSubstitutionHeader(header: "api-key", prefix: nil)

        var headers: HPACKHeaders = [:]
        headers.add(name: "api-key", value: "header-key")

        XCTAssertThrowsError(
            try ApproovService.updateRequestHeaders(headers: headers, hostname: targetURLString)
        ) { error in
            // Assert the error type, not merely that something threw: a bare assertThrowsError
            // would also pass on an unrelated failure earlier in the pipeline.
            guard case ApproovError.permanentError = error else {
                XCTFail("expected permanentError for a NO_APPROOV_SERVICE substitution, got \(error)")
                return
            }
        }
    }

    func testFetchTokenReturnsSignedTokenWithExpectedClaims() throws {
        MiniSDKAttesterProxyController.reset()
        let domainsJSON = "\"protectedDomains\": [\"\(targetHost)\"]"
        MiniSDKAttesterProxyController.loadScenarioJSON(scenarioJSON(caseName: uniqueCaseName(prefix: "target-host"), body: domainsJSON))
        ApproovService.resetForTesting()
        try ApproovService.initialize(config: validInitialConfig, comment: "reinit-fetch-token")

        let token = try ApproovService.fetchToken(url: targetURLString)
        let payload = decodeJWTBody(token)

        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?["did"] as? String, "daIvmEWBA2gvZny7a/RC/w==")
    }

    // MARK: - §5 Message Signing

    /// Reinitializes with the target host marked as protected so token fetches succeed.
    private func reinitializeServiceWithTargetHost() throws {
        try reinitializeService(
            scenarioJSON: scenarioJSON(
                caseName: uniqueCaseName(prefix: "target-host"),
                body: "\"protectedDomains\": [\"\(targetHost)\"]"
            ),
            comment: "reinit-signing"
        )
    }

    func testInstallMessageSigningAddsSignatureHeaders() throws {
        try reinitializeServiceWithTargetHost()

        let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setUseInstallMessageSigning()
        let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
        ApproovService.setServiceMutator(signer)

        let updated = try ApproovService.updateRequestHeaders(
            headers: [:], hostname: targetURLString, path: "/echo.Echo/Get")

        XCTAssertNotNil(updated.first(name: "Approov-Token"))
        let signature = try XCTUnwrap(updated.first(name: "Signature"))
        let signatureInput = try XCTUnwrap(updated.first(name: "Signature-Input"))
        // Byte-sequence form per RFC 9421: install=:base64:
        XCTAssertTrue(signature.contains("install=:"), "Signature: \(signature)")
        XCTAssertTrue(signatureInput.contains("install=("), "Signature-Input: \(signatureInput)")
        XCTAssertFalse(signatureInput.contains("account="))
        // The signed components should include the derived components and the Approov token header.
        XCTAssertTrue(signatureInput.contains("\"@method\""))
        XCTAssertTrue(signatureInput.contains("\"@target-uri\""))
        XCTAssertTrue(signatureInput.lowercased().contains("\"approov-token\""))
    }

    func testAccountMessageSigningAddsSignatureHeaders() throws {
        try reinitializeServiceWithTargetHost()

        let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
            .setUseAccountMessageSigning()
        let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
        ApproovService.setServiceMutator(signer)

        let updated = try ApproovService.updateRequestHeaders(
            headers: [:], hostname: targetURLString, path: "/echo.Echo/Get")

        XCTAssertNotNil(updated.first(name: "Approov-Token"))
        let signature = try XCTUnwrap(updated.first(name: "Signature"))
        XCTAssertTrue(signature.contains("account=:"), "Signature: \(signature)")
        XCTAssertTrue(try XCTUnwrap(updated.first(name: "Signature-Input")).contains("account=("))
    }

    func testSigningSkippedForUnprotectedRequest() throws {
        try reinitializeServiceWithTargetHost()

        let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
        let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
        ApproovService.setServiceMutator(signer)

        // A host that is not in the protected domains yields no Approov token, so there is nothing to
        // sign and no Signature header must be added.
        let updated = try ApproovService.updateRequestHeaders(
            headers: [:], hostname: "https://unprotected.example.com", path: "/echo.Echo/Get")

        XCTAssertNil(updated.first(name: "Approov-Token"))
        XCTAssertNil(updated.first(name: "Signature"))
        XCTAssertNil(updated.first(name: "Signature-Input"))
    }

    func testUnsupportedSigningAlgorithmFailsClosed() throws {
        try reinitializeServiceWithTargetHost()

        final class UnsupportedAlgFactory: SignatureParametersFactory {
            override func buildSignatureParameters(provider: ApproovGRPCComponentProvider,
                                                   changes: ApproovRequestMutations) throws -> SignatureParameters {
                let params = try super.buildSignatureParameters(provider: provider, changes: changes)
                params.setAlg("unsupported-alg")
                return params
            }
        }

        let factory = UnsupportedAlgFactory().setUseInstallMessageSigning()
        let signer = ApproovDefaultMessageSigning().setDefaultFactory(factory)
        ApproovService.setServiceMutator(signer)

        // An unsupported algorithm is one of the two fail-closed cases: the request must be aborted.
        XCTAssertThrowsError(try ApproovService.updateRequestHeaders(
            headers: [:], hostname: targetURLString, path: "/echo.Echo/Get"))
    }
}
