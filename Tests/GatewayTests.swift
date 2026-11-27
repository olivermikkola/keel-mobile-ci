import XCTest
@testable import KeelMobile

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var responseHeaders: [String: String]?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: Self.responseHeaders)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class GatewayTests: XCTestCase {
    override func tearDown() { StubProtocol.handler = nil; StubProtocol.responseHeaders = nil; super.tearDown() }

    private func client() throws -> Gateway {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try Gateway(address: "https://gateway.example/", token: "test-pairing-token", configuration: configuration)
    }

    func testRejectsUnsafePairingAddresses() {
        for address in ["http://gateway.example", "https://user:secret@gateway.example",
                        "https://gateway.example/?token=secret", "https://gateway.example/#token=secret",
                        "https://gateway.example/api", "file:///tmp/gateway", "https://"] {
            XCTAssertThrowsError(try Gateway.address(address), address)
        }
        XCTAssertNoThrow(try Gateway.address("https://gateway.example:443"))
    }

    func testAuthenticatedStatusDecodesGatewayContract() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/status")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-pairing-token")
            XCTAssertNil(request.url?.query)
            return (200, Data(#"{"status":"healthy","execution_mode":"local","workspace_path":"/tmp/repo","workspace_safe":true,"approval_policy":"Strict"}"#.utf8))
        }
        let status = try await client().status()
        XCTAssertEqual(status.workspace_path, "/tmp/repo")
        XCTAssertTrue(status.workspace_safe)
    }

    func testApprovalAndDenialSendOnlyTheDecision() async throws {
        let approval = try JSONDecoder().decode(Approval.self, from: Data(#"{"id":"BE351E80-0A3E-407E-8C73-ABC681C403E6","kind":"exec","command":"touch approved.txt","status":"Pending"}"#.utf8))
        for approved in [false, true] {
            StubProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/api/approvals/\(approval.id)/decide")
                // URLSession may turn httpBody into a stream; check the encoded request body in either form.
                let data: Data
                if let body = request.httpBody { data = body }
                else if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var collected = Data()
                    var bytes = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&bytes, maxLength: bytes.count)
                        if count <= 0 { break }
                        collected.append(contentsOf: bytes.prefix(count))
                    }
                    data = collected
                } else { throw NSError(domain: "MissingBody", code: 1) }
                let body = try JSONSerialization.jsonObject(with: data) as! [String: Bool]
                XCTAssertEqual(body, ["approved": approved])
                return (200, Data(#"{"status":"executed","result":{"answered":"allow"}}"#.utf8))
            }
            let reply = try await client().decide(approval, approved: approved)
            XCTAssertEqual(reply.status, "executed")
        }
    }

    func testHTTPFailuresDoNotExposeResponseBodies() async throws {
        StubProtocol.handler = { _ in (401, Data("sensitive server diagnostics".utf8)) }
        do {
            _ = try await client().status()
            XCTFail("Unauthenticated status must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("token rejected"))
            XCTAssertFalse(error.localizedDescription.contains("sensitive"))
        }
    }

    func testCommandReplyPreservesTimeoutAndOutput() throws {
        let reply = try JSONDecoder().decode(ExecutionReply.self, from: Data(#"{"status":"executed","result":{"command":"cargo check","exit_code":null,"stdout":"checking\n","stderr":"stopped\n","timed_out":true}}"#.utf8))
        XCTAssertTrue(try XCTUnwrap(reply.result).display.contains("timed out"))
        XCTAssertEqual(reply.result?.stderr, "stopped\n")
    }
}
