import Foundation

/// Port of desktop Keel's `EnvironmentCircuitBreaker` (`keel-agent/src/guard.rs`),
/// mapped to what fails on a phone: GitHub and network errors, not shell exits.
/// After `tripThreshold` consecutive failures (desktop default 3) the model is
/// told to stop retrying. Any success resets the count.
public final class CircuitBreaker {
    public enum Failure: Equatable {
        case rateLimited, notFound, unauthorized, network, other(String)

        var advice: String {
            switch self {
            case .rateLimited: return "GitHub's rate limit is reached. Retrying will not help; tell the user and stop."
            case .notFound: return "The paths you are trying do not exist at this commit. List the parent folder once, then choose from what exists."
            case .unauthorized: return "GitHub refused access. A credential problem cannot be fixed by the model; tell the user and stop."
            case .network: return "The network is failing. Tell the user and stop instead of retrying."
            case .other(let detail): return "The same kind of failure keeps happening (\(detail)). Change approach or stop and explain."
            }
        }
    }

    public let tripThreshold: Int
    private(set) public var consecutiveFailures = 0

    public init(tripThreshold: Int = 3) {
        self.tripThreshold = max(1, tripThreshold)
    }

    public func recordSuccess() { consecutiveFailures = 0 }

    /// Returns an advisory to append to the failing tool result once tripped.
    public func recordFailure(_ failure: Failure) -> String? {
        consecutiveFailures += 1
        guard consecutiveFailures >= tripThreshold else { return nil }
        return "\n\n[circuit-breaker] \(consecutiveFailures) tool calls in a row failed. \(failure.advice)"
    }
}
