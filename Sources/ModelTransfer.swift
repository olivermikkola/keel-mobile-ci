import Foundation

// Stream directly to an owned file on a serial utility queue. Cancelled or
// disconnected transfers keep their bytes; only a fully verified file is
// installed by ModelLibrary. Catalog URLs are immutable revision pins.
final class ModelTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let model: LocalModel
    private let configuration: URLSessionConfiguration
    private let allowRestart: Bool
    private let report: @Sendable (Int64, Int64) -> Void
    private var handle: FileHandle?
    private var received: Int64
    private var accepted = false
    private var failure: Error?
    private var completed = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var lastReport = Date.distantPast
    // Only cancellation/task installation crosses the delegate queue boundary.
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    private init(model: LocalModel, file: URL, configuration: URLSessionConfiguration, allowRestart: Bool,
                 report: @escaping @Sendable (Int64, Int64) -> Void) throws {
        self.model = model; self.configuration = configuration; self.allowRestart = allowRestart; self.report = report
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                attributes: [.protectionKey: FileProtectionType.complete]) else {
                throw LocalModelError.storage
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= model.bytes else { throw LocalModelError.integrity }
        received = size.int64Value
        handle = try FileHandle(forUpdating: file)
        super.init()
        try handle?.seek(toOffset: UInt64(received))
    }

    deinit { try? handle?.close() }

    static func fetch(_ model: LocalModel, to file: URL,
                      configuration: URLSessionConfiguration = .ephemeral,
                      allowRestart: Bool = true,
                      report: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let transfer = try ModelTransfer(model: model, file: file, configuration: configuration, allowRestart: allowRestart, report: report)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if transfer.received == model.bytes { report(model.bytes, model.bytes); return }
            try await withCheckedThrowingContinuation { transfer.start($0) }
        } onCancel: { transfer.cancel() }
    }

    private func start(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: model.url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        lock.lock(); self.task = task; let stop = cancelled; lock.unlock()
        if stop { task.cancel() }
        task.resume()
    }

    private func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard !accepted, let response = response as? HTTPURLResponse,
                  response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
                throw LocalModelError.http
            }
            let expected: Int64
            switch response.statusCode {
            case 200:
                guard received == 0 || allowRestart else { throw LocalModelError.http }
                expected = model.bytes
            case 206:
                guard let value = response.value(forHTTPHeaderField: "Content-Range"),
                      value == "bytes \(received)-\(model.bytes - 1)/\(model.bytes)" else { throw LocalModelError.http }
                expected = model.bytes - received
            default: throw LocalModelError.http
            }
            guard response.expectedContentLength == -1 || response.expectedContentLength == expected else { throw LocalModelError.http }
            // A server may ignore Range. Restart only after validating its full
            // response, rather than appending a second copy to the saved bytes.
            if response.statusCode == 200 {
                try handle?.truncate(atOffset: 0); try handle?.seek(toOffset: 0); received = 0
            }
            accepted = true; report(received, model.bytes)
            completionHandler(.allow)
        } catch {
            failure = error; completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard accepted, failure == nil else { return }
        guard Int64(data.count) <= model.bytes - received else {
            failure = LocalModelError.integrity; dataTask.cancel(); return
        }
        do {
            try handle?.write(contentsOf: data); received += Int64(data.count)
            if Date().timeIntervalSince(lastReport) >= 0.2 || received == model.bytes {
                lastReport = Date(); report(received, model.bytes)
            }
        } catch { failure = LocalModelError.storage; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !completed else { return }; completed = true
        do { try handle?.synchronize(); try handle?.close(); handle = nil }
        catch { if failure == nil { failure = LocalModelError.storage } }
        lock.lock(); let stopped = cancelled; self.task = nil; lock.unlock()
        var result = failure
        if result == nil {
            if stopped { result = CancellationError() }
            else { result = error }
        }
        if result == nil && (!accepted || received != model.bytes) { result = LocalModelError.http }
        let continuation = self.continuation; self.continuation = nil
        self.session = nil; session.finishTasksAndInvalidate()
        if let result { continuation?.resume(throwing: result) }
        else { continuation?.resume() }
    }
}
