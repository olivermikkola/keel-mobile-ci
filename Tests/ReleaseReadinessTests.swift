import XCTest
@testable import KeelMobile

@MainActor
final class ReleaseReadinessTests: XCTestCase {
    func testPrivacyManifestDeclaresAllRequiredReasonAPIsUsedByApp() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                                "PrivacyInfo.xcprivacy must be bundled in the app")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)

        let entries = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasonsByType: [String: Set<String>] = [:]
        for entry in entries {
            if let type = entry["NSPrivacyAccessedAPIType"] as? String,
               let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] {
                reasonsByType[type] = Set(reasons)
            }
        }
        XCTAssertEqual(reasonsByType["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasonsByType["NSPrivacyAccessedAPICategoryDiskSpace"], ["E174.1"])
        XCTAssertEqual(reasonsByType["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
    }

    func testBundledLicenseDocumentsLoadAndCoverShippedRuntimesAndModels() throws {
        let notices = try XCTUnwrap(AboutView.bundledText(named: "ThirdPartyNotices"))
        for required in ["llama.cpp", "MLX Swift", "StableDiffusionCore", "EmbeddingGemma", "Stable Diffusion 2.1", "DreamShaper 8 LCM", "Qwen3 0.6B", "Kokoro", "d1 2B", "Bonsai 2", "LFM3", "MiniCPM5"] {
            XCTAssertTrue(notices.contains(required), "ThirdPartyNotices.txt is missing \(required)")
        }
        let lfm = try XCTUnwrap(AboutView.bundledText(named: "LFMOpenLicense"))
        XCTAssertTrue(lfm.contains("LFM"))
        let apache = try XCTUnwrap(AboutView.bundledText(named: "BonsaiChatTemplateLicense"))
        XCTAssertTrue(apache.contains("Apache License"))
    }

    func testAboutVersionStringIncludesShortVersionAndBuild() {
        let version = AboutView.appVersion()
        XCTAssertTrue(version.hasPrefix("Version "), version)
        XCTAssertTrue(version.contains("(build "), version)
    }

    func testColdStartPrefersAppleOnDeviceOnPhysicalHardwareWhenAvailable() {
        XCTAssertEqual(ModelLibrary.initialSelection(saved: nil, hasSystemModel: true, preferSystemDefault: true, fallback: "4B"), "apple")
        XCTAssertEqual(ModelLibrary.initialSelection(saved: nil, hasSystemModel: false, preferSystemDefault: true, fallback: "4B"), "4B")
        XCTAssertEqual(ModelLibrary.initialSelection(saved: nil, hasSystemModel: true, preferSystemDefault: false, fallback: "4B"), "4B")
        XCTAssertEqual(ModelLibrary.initialSelection(saved: "lfm3", hasSystemModel: true, preferSystemDefault: true, fallback: "4B"), "lfm3")
    }
}
