import Foundation

// Collect URLSession's data chunks with a limit enforced before every append.
// data(for:) buffers the entire response before returning, so checking its
// result's size does not bound memory while the request is in flight.
final class BoundedHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private var data = Data()
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var completed = false
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    // Data and completion state belong to the serial delegate queue. Only
    // task installation and cancellation cross that queue's boundary.
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    private init(limit: Int) { self.limit = limit }

    static func fetch(_ request: URLRequest, configuration: URLSessionConfiguration,
                      limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard limit >= 0 else { throw RepositoryError.tooLarge }
        let transfer = BoundedHTTPTransfer(limit: limit)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                transfer.start(request, configuration: configuration, continuation: $0)
            }
        } onCancel: { transfer.cancel() }
    }

    private func start(_ request: URLRequest, configuration: URLSessionConfiguration,
                       continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        self.continuation = continuation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        lock.lock(); self.task = task; let stopped = cancelled; lock.unlock()
        if stopped { task.cancel() }
        task.resume()
    }

    private func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard self.response == nil, let response = response as? HTTPURLResponse else {
            failure = RepositoryError.response; completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            failure = RepositoryError.tooLarge; completionHandler(.cancel); return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard response != nil, failure == nil else { return }
        guard data.count <= limit - self.data.count else {
            failure = RepositoryError.tooLarge; dataTask.cancel(); return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !completed else { return }; completed = true
        lock.lock(); let stopped = cancelled; self.task = nil; lock.unlock()
        let failure = self.failure ?? (stopped ? CancellationError() : error)
        let continuation = self.continuation; self.continuation = nil
        self.session = nil; session.finishTasksAndInvalidate()
        if let failure { continuation?.resume(throwing: failure) }
        else if let response { continuation?.resume(returning: (data, response)) }
        else { continuation?.resume(throwing: RepositoryError.response) }
    }
}
