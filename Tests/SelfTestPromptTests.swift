import XCTest
@testable import KeelMobile

@MainActor
final class SelfTestPromptTests: XCTestCase {
    func testLaunchPromptAsksOnceAndAMissingOneDoesNothing() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("  Say hi  ", forKey: "KeelSelfTestPrompt")
        let inbox = IntentInbox()
        inbox.takeSelfTestPrompt(defaults)
        XCTAssertEqual(inbox.pending, .ask("Say hi"))

        inbox.pending = nil
        inbox.takeSelfTestPrompt(defaults)
        XCTAssertNil(inbox.pending)

        let quiet = IntentInbox()
        quiet.takeSelfTestPrompt(UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertNil(quiet.pending)
    }
}
