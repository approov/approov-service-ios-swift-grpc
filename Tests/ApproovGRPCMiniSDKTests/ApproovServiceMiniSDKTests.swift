import XCTest
import NIOHPACK
@testable import ApproovGRPCSession
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
        XCTAssertNoThrow(try ApproovService.initialize(config: validInitialConfig, comment: nil))

        let differentConfig = "#cb-other#mAxOF0ekJUOC36J5XWmVmVipOcUoEdMjhPSp2FVtyTo="
        XCTAssertThrowsError(try ApproovService.initialize(config: differentConfig, comment: nil)) { error in
            guard case let ApproovError.configurationError(message) = error else {
                return XCTFail("Expected configurationError, got \(error)")
            }
            XCTAssertTrue(message.contains("Attempting to initialize with different configuration"),
                          "Unexpected message: \(message)")
        }
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

        XCTAssertFalse(ApproovService.approovConfigString != "")

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
}
