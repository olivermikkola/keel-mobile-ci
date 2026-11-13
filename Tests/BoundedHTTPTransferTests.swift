import XCTest
@testable import KeelMobile

private final class ChunkedHTTPProtocol: URLProtocol {
    static var serve: ((ChunkedHTTPProtocol) -> Void)?
    static var onStop: (() -> Void)?
    private let lock = NSLock()
    private var stopped = false
    private var onStopHandler: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        lock.lock(); onStopHandler = Self.onStop; lock.unlock()
        Self.serve?(self)
    }
    override func stopLoading() {
        lock.lock()
        stopped = true
        let handler = onStopHandler
        onStopHandler = nil
        lock.unlock()
        handler?()
    }

    // finish: false keeps the response open after the last chunk, like a
    // server still sending. Only the transfer's own limit can then end it
    // before the resource timeout.
    func respond(headers: [String: String] = [:], chunks: [Data], finish: Bool = true) {
        // GitHub's API always declares JSON. Without a Content-Type, URLSession
        // holds the response back for MIME sniffing until body bytes arrive.
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json; charset=utf-8"]
                                           .merging(headers) { _, given in given })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        emit(chunks, index: 0, finish: finish)
    }

    private func emit(_ chunks: [Data], index: Int, finish: Bool) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(20)) {
            self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
            guard !stopped else { return }
            guard index < chunks.count else {
                if finish { self.client?.urlProtocolDidFinishLoading(self) }
                return
            }
            self.client?.urlProtocol(self, didLoad: chunks[index])
            self.emit(chunks, index: index + 1, finish: finish)
        }
    }
}

final class BoundedHTTPTransferTests: XCTestCase {
    override func tearDown() {
        ChunkedHTTPProtocol.serve = nil; ChunkedHTTPProtocol.onStop = nil
        super.tearDown()
    }

    private func fetch(limit: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedHTTPProtocol.self]
        configuration.timeoutIntervalForResource = 10
        return try await BoundedHTTPTransfer.fetch(
            URLRequest(url: URL(string: "https://api.github.com/fixture")!),
            configuration: configuration, limit: limit)
    }

    func testCollectsUnknownLengthChunksUpToExactLimit() async throws {
        ChunkedHTTPProtocol.serve = {
            $0.respond(chunks: [Data("abc".utf8), Data("def".utf8)])
        }
        let (data, response) = try await fetch(limit: 6)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("abcdef".utf8))
    }

    // URLProtocol's stopLoading timing belongs to Foundation, so these tests
    // do not race it. The fixture never finishes the response: a transfer that
    // kept reading would end in the 10 s resource timeout, not tooLarge.
    func testOversizedContentLengthCancelsBeforeBodyDelivery() async throws {
        let stopped = expectation(description: "oversized declared response cancelled")
        ChunkedHTTPProtocol.onStop = { stopped.fulfill() }
        ChunkedHTTPProtocol.serve = {
            $0.respond(headers: ["Content-Length": "1048576"], chunks: [], finish: false)
        }
        let start = Date()
        do {
            _ = try await fetch(limit: 16)
            XCTFail("Reject a declared response larger than the budget")
        } catch let error as RepositoryError { XCTAssertEqual(error, .tooLarge) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "Rejected from the header, without waiting for a body")
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testUnknownLengthOverflowStopsBeforeRemainingChunks() async throws {
        let stopped = expectation(description: "chunk overflow cancelled")
        ChunkedHTTPProtocol.onStop = { stopped.fulfill() }
        ChunkedHTTPProtocol.serve = {
            $0.respond(chunks: [Data(repeating: 65, count: 512), Data(repeating: 66, count: 600)], finish: false)
        }
        let start = Date()
        do {
            _ = try await fetch(limit: 1024)
            XCTFail("The oversized chunk cannot be appended")
        } catch let error as RepositoryError { XCTAssertEqual(error, .tooLarge) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "Stopped at the overflowing chunk, not at the end")
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testCancellationStopsAnInFlightRequestWithoutWaitingForTimeout() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request cancelled")
        ChunkedHTTPProtocol.onStop = { stopped.fulfill() }
        // Deliberately never finish or return a body. Only cancellation can
        // complete this request before the resource timeout.
        ChunkedHTTPProtocol.serve = { _ in started.fulfill() }
        let operation = Task { try await self.fetch(limit: 16) }
        await fulfillment(of: [started], timeout: 3)
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("A cancelled transfer cannot return content")
        } catch is CancellationError { }
        await fulfillment(of: [stopped], timeout: 3)
    }
}
