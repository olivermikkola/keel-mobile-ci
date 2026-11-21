import XCTest

final class MCPConnectorUITests: XCTestCase {
    /// The service list offers one-tap Connect, and nothing on it asks for an
    /// address or a token.
    func testConnectorsListServicesWithoutAskingForAddressesOrTokens() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark", "--recorded-connector"]
        app.launch()
        app.openFromMenu("connections")

        let link = app.buttons["openMCPConnectors"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.navigationBars["Connectors"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connectService-notion"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connectService-linear"].exists)
        XCTAssertFalse(app.textFields["mcpConnectorEndpoint"].exists)
        XCTAssertFalse(app.secureTextFields["mcpConnectorToken"].exists)

        let listShot = XCTAttachment(screenshot: app.screenshot())
        listShot.name = "Connectors: services with a Connect button"
        listShot.lifetime = .keepAlways
        add(listShot)

        // One tap connects a service that needs no account, through the real
        // handshake and tool list (answered by the recorded transport).
        app.buttons["connectService-notion"].tap()
        let toggle = app.switches["toggleMCPConnector-notion"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["connectService-notion"].exists)

        app.buttons["connectorDetail-notion"].tap()
        XCTAssertTrue(app.buttons["connectorTool-search_notes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connectorTool-create_note"].exists)
        let detailShot = XCTAttachment(screenshot: app.screenshot())
        detailShot.name = "Connector detail: tools in use"
        detailShot.lifetime = .keepAlways
        add(detailShot)
    }

    /// A service that is not listed needs only a name and an address. The
    /// token field stays folded away under Advanced.
    func testCustomConnectorNeedsOnlyNameAndAddress() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark", "--recorded-connector"]
        app.launch()
        app.openFromMenu("connections")
        app.buttons["openMCPConnectors"].tap()

        let custom = app.buttons["openCustomConnector"]
        for _ in 0..<6 where !(custom.exists && custom.isHittable) { app.swipeUp() }
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.tap()
        XCTAssertTrue(app.navigationBars["Custom connector"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["mcpConnectorToken"].exists)

        let nameField = app.textFields["mcpConnectorName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("My notes")
        let endpointField = app.textFields["mcpConnectorEndpoint"]
        endpointField.tap()
        endpointField.typeText("https://mcp.example.com/mcp")

        let connect = app.buttons["saveMCPConnector"]
        XCTAssertTrue(connect.isEnabled)
        connect.tap()

        XCTAssertTrue(app.navigationBars["Connectors"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["toggleMCPConnector-my_notes"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Connectors with a custom connector switched on for this chat"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
