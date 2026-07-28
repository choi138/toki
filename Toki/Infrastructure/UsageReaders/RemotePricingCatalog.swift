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

    var fetchedAt: Date
    var prices: [String: Entry]

    var modelPrices: [String: ModelPrice] {
        prices.mapValues { entry in
            ModelPrice(
                inputPerMillion: entry.inputPerMillion,
                outputPerMillion: entry.outputPerMillion,
                cacheReadPerMillion: entry.cacheReadPerMillion,
                cacheWritePerMillion: entry.cacheWritePerMillion)
        }
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

        var bareKeyed: [String: RemotePricingCatalogSnapshot.Entry] = [:]
        var providerKeyed: [String: RemotePricingCatalogSnapshot.Entry] = [:]
        for key in root.keys.sorted() {
            let isSpecDocumentation = key == "sample_spec"
            if isSpecDocumentation { continue }
            guard let rawEntry = root[key] as? [String: Any],
                  let entry = entry(from: rawEntry) else { continue }

            if let bareKey = bareModelKey(from: key) {
                if providerKeyed[bareKey] == nil {
                    providerKeyed[bareKey] = entry
                }
            } else {
                bareKeyed[key] = entry
            }
        }

        // Provider-prefixed keys (e.g. "gemini/gemini-x") supply a bare alias
        // only when no top-level bare key already defines the model.
        return providerKeyed.merging(bareKeyed) { _, bareEntry in bareEntry }
    }

    private static func entry(from rawEntry: [String: Any]) -> RemotePricingCatalogSnapshot.Entry? {
        let mode = rawEntry["mode"] as? String ?? ""
        guard allowedModes.contains(mode),
              let inputPerToken = rawEntry["input_cost_per_token"] as? Double,
              let outputPerToken = rawEntry["output_cost_per_token"] as? Double,
              inputPerToken >= 0, outputPerToken >= 0 else {
            return nil
        }

        let million = 1_000_000.0
        let cacheReadPerToken = rawEntry["cache_read_input_token_cost"] as? Double ?? 0
        let cacheWritePerToken = rawEntry["cache_creation_input_token_cost"] as? Double ?? 0
        return RemotePricingCatalogSnapshot.Entry(
            inputPerMillion: inputPerToken * million,
            outputPerMillion: outputPerToken * million,
            cacheReadPerMillion: max(0, cacheReadPerToken) * million,
            cacheWritePerMillion: max(0, cacheWritePerToken) * million)
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
    private var isRefreshing = false

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

    func refreshIfNeeded(isEnabled: Bool) async {
        guard isEnabled else {
            hasInstalledCachedCatalog = false
            ModelPricingSupplement.install([:])
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let cached = store.load()
        if !hasInstalledCachedCatalog, let cached {
            ModelPricingSupplement.install(cached.modelPrices)
            hasInstalledCachedCatalog = true
        }

        let isCacheFresh = cached.map { now().timeIntervalSince($0.fetchedAt) < Self.refreshInterval } ?? false
        guard !isCacheFresh else { return }

        guard let data = try? await fetch(Self.catalogURL) else { return }
        let prices = RemotePricingCatalogParser.parse(data)
        guard !prices.isEmpty else { return }

        let snapshot = RemotePricingCatalogSnapshot(fetchedAt: now(), prices: prices)
        store.save(snapshot)
        ModelPricingSupplement.install(snapshot.modelPrices)
        hasInstalledCachedCatalog = true
    }
}
