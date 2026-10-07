import Foundation

/// Conservative estimates include collection slack and count shared strings more than once.
/// The cache budget bounds retained parsed results, rather than unrelated transcript bytes.
enum PiCompatibleCacheMemory {
    static func stringBytes(_ value: String?) -> Int {
        guard let value else { return 0 }
        return 32 + value.utf8.count * 2
    }

    static func keyBytes(_ key: PiCompatibleDeduplicationKey) -> Int {
        switch key {
        case let .message(message):
            stringBytes(message)
        case let .sessionMessage(session, message):
            stringBytes(session) + stringBytes(message)
        case let .sessionResponse(session, provider, response):
            stringBytes(session) + stringBytes(provider) + stringBytes(response)
        case let .legacySessionResponse(session, response):
            stringBytes(session) + stringBytes(response)
        case let .legacyRecord(identity):
            stringBytes(identity.provider) + stringBytes(identity.model) + stringBytes(identity.location)
        case let .record(stream, _):
            stringBytes(stream)
        }
    }

    static func aliasBytes(_ alias: PiCompatibleMergeAlias) -> Int {
        switch alias {
        case let .sessionMessage(session, message):
            stringBytes(session) + stringBytes(message)
        case let .sessionResponse(session, response, usage):
            stringBytes(session) + stringBytes(response) + stringBytes(usage)
        case let .responseCopy(id, digest), let .messageCopy(id, digest):
            stringBytes(id) + stringBytes(digest)
        case let .legacyResponseCopy(identity):
            stringBytes(identity.responseID) + stringBytes(identity.payloadDigest)
        }
    }
}

extension PiCompatibleUsageRecord {
    var estimatedCacheMemoryBytes: Int {
        // Array growth, set buckets and the three fixed-size revision digests need headroom.
        MemoryLayout<Self>.stride * 2 + 512
            + PiCompatibleCacheMemory.keyBytes(deduplicationKey)
            + PiCompatibleCacheMemory.stringBytes(model)
            + PiCompatibleCacheMemory.stringBytes(provider)
            + PiCompatibleCacheMemory.stringBytes(agentName)
            + PiCompatibleCacheMemory.stringBytes(replicaScope)
            + PiCompatibleCacheMemory.stringBytes(attribution.projectPath)
            + PiCompatibleCacheMemory.stringBytes(attribution.projectName)
            + PiCompatibleCacheMemory.stringBytes(attribution.sessionID)
            + PiCompatibleCacheMemory.stringBytes(attribution.sessionLabel)
            + mergeAliases.reduce(0) { $0 + 128 + PiCompatibleCacheMemory.aliasBytes($1) }
    }
}
