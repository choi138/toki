import Foundation

/// Supplemental pricing loaded from a remote public catalog. Entries are
/// consulted only after the curated static table misses, so curated values
/// and scheduled price changes always win over remote data.
public enum ModelPricingSupplement {
    public struct PriceVersion {
        public let effectiveFrom: Date
        public let price: ModelPrice?

        public init(effectiveFrom: Date, price: ModelPrice?) {
            self.effectiveFrom = effectiveFrom
            self.price = price
        }
    }

    private static let lock = NSLock()
    private static var priceHistories: [String: [PriceVersion]] = [:]

    /// Replaces the supplemental table atomically. Pass an empty dictionary
    /// to remove all supplemental pricing.
    public static func install(_ prices: [String: ModelPrice]) {
        let priceHistories = prices.mapValues { price in
            [PriceVersion(effectiveFrom: .distantPast, price: price)]
        }
        install(priceHistories: priceHistories)
    }

    /// Replaces each model's supplemental pricing history atomically. A nil
    /// price is a tombstone that removes the model from that timestamp onward.
    public static func install(priceHistories: [String: [PriceVersion]]) {
        lock.lock()
        defer { lock.unlock() }
        self.priceHistories = priceHistories.compactMapValues { versions in
            let normalized = normalizedVersions(versions)
            return normalized.isEmpty ? nil : normalized
        }
    }

    public static var installedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return priceHistories.values.reduce(0) { count, versions in
            count + (versions.last?.price == nil ? 0 : 1)
        }
    }

    static func price(for modelId: String) -> ModelPrice? {
        lock.lock()
        defer { lock.unlock() }
        return priceHistories[modelId]?.last?.price
    }

    static func price(for modelId: String, at timestamp: Date) -> ModelPrice? {
        lock.lock()
        defer { lock.unlock() }
        return priceHistories[modelId]?
            .last(where: { $0.effectiveFrom <= timestamp })?
            .price
    }

    /// Returns whether a model has a price for the complete half-open interval.
    /// This keeps report-level "price known" state aligned with timestamped
    /// event billing when a model is added to or removed from the catalog.
    static func hasPrice(for modelId: String, throughout interval: DateInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let versions = priceHistories[modelId],
              versions.last(where: { $0.effectiveFrom <= interval.start })?.price != nil else {
            return false
        }
        guard interval.duration > 0 else { return true }
        return !versions.contains { version in
            version.effectiveFrom > interval.start
                && version.effectiveFrom < interval.end
                && version.price == nil
        }
    }

    private static func normalizedVersions(_ versions: [PriceVersion]) -> [PriceVersion] {
        let sorted = versions.enumerated().sorted { lhs, rhs in
            if lhs.element.effectiveFrom == rhs.element.effectiveFrom {
                return lhs.offset < rhs.offset
            }
            return lhs.element.effectiveFrom < rhs.element.effectiveFrom
        }

        var result: [PriceVersion] = []
        for item in sorted {
            let version = item.element
            if result.last?.effectiveFrom == version.effectiveFrom {
                result[result.count - 1] = version
            } else {
                result.append(version)
            }
        }
        return result
    }
}
