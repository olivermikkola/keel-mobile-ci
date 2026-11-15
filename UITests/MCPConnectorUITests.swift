import XCTest

final class MCPConnectorUITests: XCTestCase {
    func testConnectionsOpensMCPConnectorsAndSavesPerChatToggle() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark"]
        app.launch()
        app.openFromMenu("connections")

        let link = app.buttons["openMCPConnectors"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()

        XCTAssertTrue(app.navigationBars["MCP connectors"].waitForExistence(timeout: 5))
        let nameField = app.textFields["mcpConnectorName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Notion")

        let endpointField = app.textFields["mcpConnectorEndpoint"]
        XCTAssertTrue(endpointField.exists)
        endpointField.tap()
        endpointField.typeText("https://mcp.example.com/rpc")

        let saveButton = app.buttons["saveMCPConnector"]
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()

        let toggle = app.switches["toggleMCPConnector-notion"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "MCP connectors in Connections with per-chat toggle"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
