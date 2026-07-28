import Foundation

/// Supplemental pricing loaded from a remote public catalog. Entries are
/// consulted only after the curated static table misses, so curated values
/// and scheduled price changes always win over remote data.
public enum ModelPricingSupplement {
    private static let lock = NSLock()
    private static var table: [String: ModelPrice] = [:]

    /// Replaces the supplemental table atomically. Pass an empty dictionary
    /// to remove all supplemental pricing.
    public static func install(_ prices: [String: ModelPrice]) {
        lock.lock()
        defer { lock.unlock() }
        table = prices
    }

    public static var installedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return table.count
    }

    static func price(for modelId: String) -> ModelPrice? {
        lock.lock()
        defer { lock.unlock() }
        return table[modelId]
    }
}
