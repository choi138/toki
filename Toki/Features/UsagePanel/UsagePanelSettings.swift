import Combine
import Foundation

@MainActor
final class UsagePanelSettings: ObservableObject {
    nonisolated static let defaultRefreshIntervalSeconds = 180
    nonisolated static let refreshIntervalChoices = [60, 180, 300, 600]
    nonisolated static let defaultReaderNames = [
        "Claude Code",
        "Codex",
        "Cursor",
        "Gemini CLI",
        "OpenCode",
        "OpenClaw",
    ]

    @Published private var storedRefreshIntervalSeconds: Int

    var refreshIntervalSeconds: Int {
        get {
            storedRefreshIntervalSeconds
        }
        set {
            let normalizedValue = Self.normalizedRefreshInterval(newValue)
            guard storedRefreshIntervalSeconds != normalizedValue else { return }
            storedRefreshIntervalSeconds = normalizedValue
            defaults.set(normalizedValue, forKey: Keys.refreshIntervalSeconds)
        }
    }

    var refreshIntervalPublisher: AnyPublisher<Int, Never> {
        $storedRefreshIntervalSeconds
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    @Published var enabledReaderNames: [String: Bool] {
        didSet {
            defaults.set(enabledReaderNames, forKey: Keys.enabledReaderNames)
        }
    }

    @Published var showsZeroSourceRows: Bool {
        didSet {
            defaults.set(showsZeroSourceRows, forKey: Keys.showsZeroSourceRows)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, readerNames: [String] = UsagePanelSettings.defaultReaderNames) {
        self.defaults = defaults

        let storedInterval = defaults.integer(forKey: Keys.refreshIntervalSeconds)
        storedRefreshIntervalSeconds = Self.normalizedRefreshInterval(storedInterval)

        let storedReaderNames = defaults.dictionary(forKey: Keys.enabledReaderNames) as? [String: Bool] ?? [:]
        enabledReaderNames = Self.normalizedReaderSettings(storedReaderNames, readerNames: readerNames)

        if defaults.object(forKey: Keys.showsZeroSourceRows) == nil {
            showsZeroSourceRows = false
        } else {
            showsZeroSourceRows = defaults.bool(forKey: Keys.showsZeroSourceRows)
        }
    }

    func isReaderEnabled(_ name: String) -> Bool {
        enabledReaderNames[name] ?? true
    }

    func setReader(_ name: String, isEnabled: Bool) {
        guard enabledReaderNames[name] != isEnabled else { return }
        enabledReaderNames[name] = isEnabled
    }

    func setShowsZeroSourceRows(_ isEnabled: Bool) {
        guard showsZeroSourceRows != isEnabled else { return }
        showsZeroSourceRows = isEnabled
    }

    func enabledReaders(from readers: [any TokenReader]) -> [any TokenReader] {
        readers.filter { isReaderEnabled($0.name) }
    }

    func normalizedReaderSettings(for readerNames: [String]) -> [String: Bool] {
        Self.normalizedReaderSettings(enabledReaderNames, readerNames: readerNames)
    }
}

private extension UsagePanelSettings {
    enum Keys {
        static let refreshIntervalSeconds = "usagePanel.refreshIntervalSeconds"
        static let enabledReaderNames = "usagePanel.enabledReaderNames"
        static let showsZeroSourceRows = "usagePanel.showsZeroSourceRows"
    }

    static func normalizedRefreshInterval(_ seconds: Int) -> Int {
        guard refreshIntervalChoices.contains(seconds) else {
            return defaultRefreshIntervalSeconds
        }
        return seconds
    }

    static func normalizedReaderSettings(_ stored: [String: Bool], readerNames: [String]) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: readerNames.map { name in
            (name, stored[name] ?? true)
        })
    }
}
