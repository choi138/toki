struct CodexRolloutUsageCacheFile: Codable {
    let entries: [String: CodexRolloutUsageCacheEntry]
}

struct CodexRolloutUsageCacheUpdates: Codable {
    let changes: [String: CodexRolloutUsageCacheChange]
}

struct CodexRolloutUsageCacheChange: Codable {
    let entry: CodexRolloutUsageCacheEntry?
}
