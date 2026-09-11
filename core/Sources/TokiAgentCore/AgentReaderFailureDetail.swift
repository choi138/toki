import Foundation

/// Turns a reader failure into one log-safe sentence.
///
/// Only a reader's own `errorDescription` is forwarded. A Foundation error's message can
/// quote the source path it failed on, which must not reach the Agent's logs, so those
/// errors are reduced to their domain and code.
enum AgentReaderFailureDetail {
    static func describe(_ error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription {
            return description
        }
        let error = error as NSError
        return "\(error.domain) (code \(error.code))"
    }
}
