import Foundation
import TokiSyncProtocol
@testable import TokiAgentCore

extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}

final class FailFirstHeartbeatAgentHubClient: AgentHubClientProtocol {
    private let lock = NSLock()
    private var shouldFailHeartbeat = true
    private var uploads: [UInt64] = []
    private var heartbeatAttemptValues: [UInt64] = []
    private var heartbeatSuccessValues: [UInt64] = []

    var uploadedSequences: [UInt64] {
        lock.withLock { uploads }
    }

    var heartbeatAttempts: [UInt64] {
        lock.withLock { heartbeatAttemptValues }
    }

    var successfulHeartbeats: [UInt64] {
        lock.withLock { heartbeatSuccessValues }
    }

    func upload(_ envelope: EncryptedUsageEnvelope, configuration _: AgentConfiguration) async throws {
        lock.withLock { uploads.append(envelope.sequence) }
    }

    func heartbeat(configuration _: AgentConfiguration, latestSequence: UInt64) async throws {
        let shouldFail = lock.withLock {
            heartbeatAttemptValues.append(latestSequence)
            if shouldFailHeartbeat {
                shouldFailHeartbeat = false
                return true
            }
            heartbeatSuccessValues.append(latestSequence)
            return false
        }
        if shouldFail {
            throw AgentSyncTestError.heartbeatFailed
        }
    }
}
