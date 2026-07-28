import Foundation
import TokiUsageReaders

// MARK: - Snapshot

struct RemotePricingCatalogSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheReadPerMillion: Double
        let cacheWritePerMillion: Double
    }

    struct PriceVersion: Codable, Equatable {
        let effectiveFrom: Date
        let price: Entry?
    }

    private struct CatalogVersion: Codable {
        let effectiveFrom: Date
        let prices: [String: Entry]
    }

    var fetchedAt: Date
    var priceHistories: [String: [PriceVersion]]

    init(fetchedAt: Date, prices: [String: Entry]) {
        self.fetchedAt = fetchedAt
        priceHistories = prices.mapValues { price in
            [PriceVersion(effectiveFrom: fetchedAt, price: price)]
        }
    }

    private init(fetchedAt: Date, priceHistories: [String: [PriceVersion]]) {
        self.fetchedAt = fetchedAt
        self.priceHistories = Self.normalizedPriceHistories(priceHistories)
    }

    var prices: [String: Entry] {
        priceHistories.compactMapValues { $0.last?.price }
    }

    var modelPriceHistories: [String: [ModelPricingSupplement.PriceVersion]] {
        priceHistories.compactMapValues { versions in
            let mapped = versions.map { version in
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: version.effectiveFrom,
                    price: version.price?.modelPrice)
            }
            return mapped.isEmpty ? nil : mapped
        }
    }

    func updating(fetchedAt: Date, prices: [String: Entry]) -> RemotePricingCatalogSnapshot {
        let previousPrices = self.prices
        guard previousPrices != prices else {
            return RemotePricingCatalogSnapshot(fetchedAt: fetchedAt, priceHistories: priceHistories)
        }

        var updatedHistories = priceHistories
        let modelIDs = Set(previousPrices.keys).union(prices.keys)
        for modelID in modelIDs where previousPrices[modelID] != prices[modelID] {
            updatedHistories[modelID, default: []].append(
                PriceVersion(effectiveFrom: fetchedAt, price: prices[modelID]))
        }
        return RemotePricingCatalogSnapshot(fetchedAt: fetchedAt, priceHistories: updatedHistories)
    }

    private enum CodingKeys: String, CodingKey {
        case fetchedAt
        case priceHistories
        case prices
        case versions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        if let priceHistories = try container.decodeIfPresent(
            [String: [PriceVersion]].self,
            forKey: .priceHistories),
            !priceHistories.isEmpty {
            self.priceHistories = Self.normalizedPriceHistories(priceHistories)
            return
        }
        if let versions = try container.decodeIfPresent([CatalogVersion].self, forKey: .versions),
           !versions.isEmpty {
            priceHistories = Self.priceHistories(from: versions)
            return
        }
        let prices = try container.decodeIfPresent([String: Entry].self, forKey: .prices) ?? [:]
        let legacyEffectiveFrom = fetchedAt
        priceHistories = prices.mapValues { price in
            [PriceVersion(effectiveFrom: legacyEffectiveFrom, price: price)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(priceHistories, forKey: .priceHistories)
    }

    private static func priceHistories(from versions: [CatalogVersion]) -> [String: [PriceVersion]] {
        let sortedVersions = versions.enumerated().sorted { lhs, rhs in
            if lhs.element.effectiveFrom == rhs.element.effectiveFrom {
                return lhs.offset < rhs.offset
            }
            return lhs.element.effectiveFrom < rhs.element.effectiveFrom
        }
        var currentPrices: [String: Entry] = [:]
        var histories: [String: [PriceVersion]] = [:]

        for item in sortedVersions {
            let version = item.element
            let modelIDs = Set(currentPrices.keys).union(version.prices.keys)
            for modelID in modelIDs where currentPrices[modelID] != version.prices[modelID] {
                histories[modelID, default: []].append(
                    PriceVersion(effectiveFrom: version.effectiveFrom, price: version.prices[modelID]))
            }
            currentPrices = version.prices
        }
        return normalizedPriceHistories(histories)
    }

    private static func normalizedPriceHistories(
        _ histories: [String: [PriceVersion]]) -> [String: [PriceVersion]] {
        histories.compactMapValues { versions in
            let sortedVersions = versions.enumerated().sorted { lhs, rhs in
                if lhs.element.effectiveFrom == rhs.element.effectiveFrom {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.effectiveFrom < rhs.element.effectiveFrom
            }
            var result: [PriceVersion] = []
            for item in sortedVersions {
                let version = item.element
                if result.last?.effectiveFrom == version.effectiveFrom {
                    result[result.count - 1] = version
                } else if result.last?.price != version.price {
                    result.append(version)
                }
            }
            return result.isEmpty ? nil : result
        }
    }
}

private extension RemotePricingCatalogSnapshot.Entry {
    var modelPrice: ModelPrice {
        ModelPrice(
            inputPerMillion: inputPerMillion,
            outputPerMillion: outputPerMillion,
            cacheReadPerMillion: cacheReadPerMillion,
            cacheWritePerMillion: cacheWritePerMillion)
    }
}

// MARK: - Parser

/// Parses the public LiteLLM model pricing catalog
/// (`model_prices_and_context_window.json`) into per-million-token prices.
enum RemotePricingCatalogParser {
    private static let allowedModes: Set = ["chat", "responses", "completion"]

    static func parse(_ data: Data) -> [String: RemotePricingCatalogSnapshot.Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var canonicalPrices: [String: RemotePricingCatalogSnapshot.Entry] = [:]
        var aliasCandidates: [String: RemotePricingCatalogSnapshot.Entry] = [:]
        var ambiguousAliases = Set<String>()

        var aliasOwners: [String: String] = [:]

        func registerAlias(
            _ rawAlias: String,
            canonicalKey: String,
            entry: RemotePricingCatalogSnapshot.Entry) {
            let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !alias.isEmpty else { return }
            if let existingOwner = aliasOwners[alias], existingOwner != canonicalKey {
                ambiguousAliases.insert(alias)
            } else {
                aliasOwners[alias] = canonicalKey
                aliasCandidates[alias] = entry
            }
        }

        for key in root.keys.sorted() {
            let isSpecDocumentation = key == "sample_spec"
            if isSpecDocumentation { continue }
            guard let rawEntry = root[key] as? [String: Any],
                  let entry = entry(from: rawEntry) else { continue }

            canonicalPrices[key] = entry
            if let bareKey = bareModelKey(from: key) {
                registerAlias(bareKey, canonicalKey: key, entry: entry)
            }
            for case let alias as String in rawEntry["aliases"] as? [Any] ?? [] {
                registerAlias(alias, canonicalKey: key, entry: entry)
            }
        }

        for alias in ambiguousAliases {
            aliasCandidates.removeValue(forKey: alias)
        }

        // Canonical catalog keys always win. Provider-derived and explicit
        // aliases are included only when they identify one unambiguous price.
        return aliasCandidates.merging(canonicalPrices) { _, canonicalEntry in canonicalEntry }
    }

    private static func entry(from rawEntry: [String: Any]) -> RemotePricingCatalogSnapshot.Entry? {
        let mode = rawEntry["mode"] as? String ?? ""
        guard allowedModes.contains(mode),
              let inputPerToken = validPerTokenCost(rawEntry["input_cost_per_token"]),
              let outputPerToken = validPerTokenCost(rawEntry["output_cost_per_token"]),
              let cacheReadPerToken = validOptionalPerTokenCost(
                  rawEntry["cache_read_input_token_cost"],
                  fallback: inputPerToken),
              let cacheWritePerToken = validOptionalPerTokenCost(
                  rawEntry["cache_creation_input_token_cost"],
                  fallback: inputPerToken),
              let inputPerMillion = perMillionCost(inputPerToken),
              let outputPerMillion = perMillionCost(outputPerToken),
              let cacheReadPerMillion = perMillionCost(cacheReadPerToken),
              let cacheWritePerMillion = perMillionCost(cacheWritePerToken) else {
            return nil
        }

        return RemotePricingCatalogSnapshot.Entry(
            inputPerMillion: inputPerMillion,
            outputPerMillion: outputPerMillion,
            cacheReadPerMillion: cacheReadPerMillion,
            cacheWritePerMillion: cacheWritePerMillion)
    }

    private static func validPerTokenCost(_ rawValue: Any?) -> Double? {
        guard let value = rawValue as? Double,
              value.isFinite,
              value >= 0 else { return nil }
        return value
    }

    private static func validOptionalPerTokenCost(_ rawValue: Any?, fallback: Double) -> Double? {
        guard let rawValue, !(rawValue is NSNull) else { return fallback }
        return validPerTokenCost(rawValue)
    }

    private static func perMillionCost(_ perTokenCost: Double) -> Double? {
        let value = perTokenCost * 1_000_000
        return value.isFinite ? value : nil
    }

    private static func bareModelKey(from key: String) -> String? {
        guard key.contains("/") else { return nil }
        let suffix = key.split(separator: "/").last.map(String.init) ?? ""
        return suffix.isEmpty ? nil : suffix
    }
}

// MARK: - Store

struct RemotePricingCatalogStore {
    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = RemotePricingCatalogStore.defaultCatalogURL(),
        fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() -> RemotePricingCatalogSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RemotePricingCatalogSnapshot.self, from: data)
    }

    func save(_ snapshot: RemotePricingCatalogSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    static func defaultCatalogURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Toki", isDirectory: true)
            .appendingPathComponent("RemotePricingCatalog.json")
    }
}

// MARK: - Updater

/// Keeps the supplemental pricing table fresh from the public LiteLLM
/// catalog. Downloads public pricing metadata only — no local usage data is
/// ever sent. Curated static prices always take precedence over the
/// supplement (see `ModelPricingSupplement`).
actor RemotePricingCatalogUpdater {
    static let shared = RemotePricingCatalogUpdater()

    static let catalogURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    private let store: RemotePricingCatalogStore
    private let fetch: (URL) async throws -> Data
    private let now: () -> Date
    private var hasInstalledCachedCatalog = false
    private var isCatalogEnabled = false
    private var isRefreshing = false
    private var refreshGeneration = 0
    private var shouldRefreshAfterCurrentRun = false

    init(
        store: RemotePricingCatalogStore = RemotePricingCatalogStore(),
        fetch: ((URL) async throws -> Data)? = nil,
        now: @escaping () -> Date = Date.init) {
        self.store = store
        self.fetch = fetch ?? { url in
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
        self.now = now
    }

    @discardableResult
    func refreshIfNeeded(isEnabled: Bool) async -> Bool {
        let didChangeEnabledState = isCatalogEnabled != isEnabled
        if didChangeEnabledState {
            isCatalogEnabled = isEnabled
            refreshGeneration &+= 1
        }

        guard isEnabled else {
            shouldRefreshAfterCurrentRun = false
            let didClearPricing = ModelPricingSupplement.installedCount > 0
            hasInstalledCachedCatalog = false
            ModelPricingSupplement.install([:])
            return didClearPricing
        }

        guard !isRefreshing else {
            if didChangeEnabledState {
                shouldRefreshAfterCurrentRun = true
            }
            return false
        }

        isRefreshing = true
        defer { isRefreshing = false }

        var didChangePricing = false
        repeat {
            shouldRefreshAfterCurrentRun = false
            let generation = refreshGeneration
            if await refreshOnce(generation: generation) {
                didChangePricing = true
            }
        } while isCatalogEnabled && shouldRefreshAfterCurrentRun

        return didChangePricing
    }

    private func refreshOnce(generation: Int) async -> Bool {
        var didChangePricing = false

        let cached = store.load()
        if !hasInstalledCachedCatalog, let cached {
            ModelPricingSupplement.install(priceHistories: cached.modelPriceHistories)
            hasInstalledCachedCatalog = true
            didChangePricing = true
        }

        let isCacheFresh = cached.map { now().timeIntervalSince($0.fetchedAt) < Self.refreshInterval } ?? false
        guard !isCacheFresh else { return didChangePricing }

        guard let data = try? await fetch(Self.catalogURL) else { return didChangePricing }
        guard isCatalogEnabled, refreshGeneration == generation else { return didChangePricing }
        let prices = RemotePricingCatalogParser.parse(data)
        guard !prices.isEmpty else { return didChangePricing }

        let fetchedAt = now()
        let snapshot = cached?.updating(fetchedAt: fetchedAt, prices: prices)
            ?? RemotePricingCatalogSnapshot(fetchedAt: fetchedAt, prices: prices)
        store.save(snapshot)
        if cached?.prices != prices || !hasInstalledCachedCatalog {
            ModelPricingSupplement.install(priceHistories: snapshot.modelPriceHistories)
            hasInstalledCachedCatalog = true
            didChangePricing = true
        }
        return didChangePricing
    }
}
