import XCTest
@testable import KeelMobile

private final class ChunkedHTTPProtocol: URLProtocol {
    static var serve: ((ChunkedHTTPProtocol) -> Void)?
    static var onStop: (() -> Void)?
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.serve?(self) }
    override func stopLoading() {
        lock.lock(); stopped = true; lock.unlock()
        Self.onStop?()
    }

    func respond(headers: [String: String] = [:], chunks: [Data],
                 onChunk: @escaping () -> Void = {}) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        emit(chunks, index: 0, onChunk: onChunk)
    }

    private func emit(_ chunks: [Data], index: Int, onChunk: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(20)) {
            self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
            guard !stopped else { return }
            guard index < chunks.count else {
                self.client?.urlProtocolDidFinishLoading(self); return
            }
            onChunk()
            self.client?.urlProtocol(self, didLoad: chunks[index])
            self.emit(chunks, index: index + 1, onChunk: onChunk)
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
        configuration.timeoutIntervalForResource = 3
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

    func testOversizedContentLengthCancelsBeforeBodyDelivery() async throws {
        let stopped = expectation(description: "oversized declared response cancelled")
        let noBody = expectation(description: "body must not be collected"); noBody.isInverted = true
        ChunkedHTTPProtocol.onStop = { stopped.fulfill() }
        ChunkedHTTPProtocol.serve = {
            $0.respond(headers: ["Content-Length": "1048576"], chunks: [Data(repeating: 65, count: 16)]) {
                noBody.fulfill()
            }
        }
        do {
            _ = try await fetch(limit: 16)
            XCTFail("Reject a declared response larger than the budget")
        } catch let error as RepositoryError { XCTAssertEqual(error, .tooLarge) }
        await fulfillment(of: [stopped, noBody], timeout: 0.2)
    }

    func testUnknownLengthOverflowStopsBeforeRemainingChunks() async throws {
        let stopped = expectation(description: "chunk overflow cancelled")
        let extra = expectation(description: "remaining oversized body must not load"); extra.isInverted = true
        let lock = NSLock()
        var delivered = 0
        ChunkedHTTPProtocol.onStop = { stopped.fulfill() }
        ChunkedHTTPProtocol.serve = {
            $0.respond(chunks: [Data(repeating: 65, count: 512), Data(repeating: 66, count: 600),
                                Data(repeating: 67, count: 512)]) {
                lock.lock(); delivered += 1; let count = delivered; lock.unlock()
                if count > 2 { extra.fulfill() }
            }
        }
        do {
            _ = try await fetch(limit: 1024)
            XCTFail("The oversized chunk cannot be appended")
        } catch let error as RepositoryError { XCTAssertEqual(error, .tooLarge) }
        await fulfillment(of: [stopped, extra], timeout: 0.2)
    }

    func testCancellationStopsAnInFlightRequestWithoutWaitingForTimeout() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request cancelled")
        ChunkedHTTPProtocol.onStop = { stopped.fulfill() }
        // Deliberately never finish or return a body. Only cancellation can
        // complete this request before the resource timeout.
        ChunkedHTTPProtocol.serve = { _ in started.fulfill() }
        let operation = Task { try await self.fetch(limit: 16) }
        await fulfillment(of: [started], timeout: 1)
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("A cancelled transfer cannot return content")
        } catch is CancellationError { }
        await fulfillment(of: [stopped], timeout: 1)
    }
}
