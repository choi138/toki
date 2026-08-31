import Combine
import Foundation
import TokiUsageCore

@MainActor
final class UsagePanelSettings: ObservableObject {
    nonisolated static let defaultRefreshIntervalSeconds = 180
    nonisolated static let refreshIntervalChoices = [60, 180, 300, 600]
    nonisolated static let defaultReaderNames = [
        "Claude Code",
        "Codex",
        "Hermes",
        "Cursor",
        "Gemini CLI",
        "GJC",
        "Senpi",
        "Pi",
        "Oh My Pi",
        "Kimchi",
        "OpenCode",
        "OpenClaw",
        "GitHub Copilot CLI",
        "Kimi CLI",
        "Kimi Code",
        "Qwen CLI",
        "Remote Devices",
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
            NotificationCenter.default.post(name: .usagePanelRefreshIntervalDidChange, object: nil)
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

    @Published var autoUpdatesModelPricing: Bool {
        didSet {
            defaults.set(autoUpdatesModelPricing, forKey: Keys.autoUpdatesModelPricing)
        }
    }

    @Published var showsMenuBarCost: Bool {
        didSet {
            defaults.set(showsMenuBarCost, forKey: Keys.showsMenuBarCost)
        }
    }

    @Published private(set) var currentUsageWindow: CurrentUsageWindow

    @Published private(set) var tabOrder: [PanelTab] {
        didSet {
            defaults.set(tabOrder.map(\.rawValue), forKey: Keys.tabOrder)
        }
    }

    private let defaults: UserDefaults
    private let refreshPricingCatalog: (Bool) async -> Bool
    private var pricingCatalogRefreshTask: Task<Void, Never>?
    private var pricingRefreshGeneration = 0

    init(
        defaults: UserDefaults = .standard,
        readerNames: [String] = UsagePanelSettings.defaultReaderNames,
        refreshPricingCatalog: @escaping (Bool) async -> Bool = { isEnabled in
            await RemotePricingCatalogUpdater.shared.refreshIfNeeded(isEnabled: isEnabled)
        }) {
        self.defaults = defaults
        self.refreshPricingCatalog = refreshPricingCatalog

        let storedInterval = defaults.integer(forKey: Keys.refreshIntervalSeconds)
        storedRefreshIntervalSeconds = Self.normalizedRefreshInterval(storedInterval)

        let storedReaderNames = defaults.dictionary(forKey: Keys.enabledReaderNames) as? [String: Bool] ?? [:]
        enabledReaderNames = Self.normalizedReaderSettings(storedReaderNames, readerNames: readerNames)

        if defaults.object(forKey: Keys.showsZeroSourceRows) == nil {
            showsZeroSourceRows = false
        } else {
            showsZeroSourceRows = defaults.bool(forKey: Keys.showsZeroSourceRows)
        }

        autoUpdatesModelPricing = Self.isAutoUpdatePricingEnabled(defaults: defaults)
        showsMenuBarCost = Self.isMenuBarCostEnabled(defaults: defaults)
        currentUsageWindow = Self.currentUsageWindow(defaults: defaults)
        tabOrder = Self.normalizedTabOrder(defaults.stringArray(forKey: Keys.tabOrder) ?? [])
    }

    func isReaderEnabled(_ name: String) -> Bool {
        enabledReaderNames[name] ?? true
    }

    func setReader(_ name: String, isEnabled: Bool) {
        guard enabledReaderNames[name] != isEnabled else { return }
        enabledReaderNames[name] = isEnabled
        NotificationCenter.default.post(name: .usagePanelReaderSettingsDidChange, object: nil)
    }

    func setShowsZeroSourceRows(_ isEnabled: Bool) {
        guard showsZeroSourceRows != isEnabled else { return }
        showsZeroSourceRows = isEnabled
    }

    func setAutoUpdatesModelPricing(_ isEnabled: Bool) {
        guard autoUpdatesModelPricing != isEnabled else { return }
        autoUpdatesModelPricing = isEnabled
        pricingCatalogRefreshTask?.cancel()
        pricingRefreshGeneration += 1
        let generation = pricingRefreshGeneration
        let refreshPricingCatalog = refreshPricingCatalog
        pricingCatalogRefreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let didChangePricing = await refreshPricingCatalog(isEnabled)
            guard let self,
                  !Task.isCancelled,
                  pricingRefreshGeneration == generation,
                  autoUpdatesModelPricing == isEnabled else { return }
            pricingCatalogRefreshTask = nil
            if didChangePricing {
                NotificationCenter.default.post(name: .usagePanelModelPricingDidChange, object: nil)
            }
        }
    }

    func setShowsMenuBarCost(_ isEnabled: Bool) {
        guard showsMenuBarCost != isEnabled else { return }
        showsMenuBarCost = isEnabled
        NotificationCenter.default.post(name: .usagePanelMenuBarCostSettingDidChange, object: nil)
    }

    func setCurrentUsageWindow(_ window: CurrentUsageWindow) {
        guard currentUsageWindow != window else { return }
        currentUsageWindow = window
        defaults.set(window.rawValue, forKey: Keys.currentUsageWindow)
        NotificationCenter.default.post(name: .usagePanelCurrentUsageWindowDidChange, object: nil)
    }

    func setTabOrder(_ order: [PanelTab]) {
        let normalizedOrder = Self.normalizedTabOrder(order.map(\.rawValue))
        guard tabOrder != normalizedOrder else { return }
        tabOrder = normalizedOrder
    }

    func resetTabOrder() {
        setTabOrder(PanelTab.allCases)
    }

    var isUsingDefaultTabOrder: Bool {
        tabOrder == PanelTab.allCases
    }

    /// Reads the persisted flag without requiring a settings instance so the
    /// app-level refresh loop can consult the latest value.
    nonisolated static func isAutoUpdatePricingEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Keys.autoUpdatesModelPricing) != nil else { return true }
        return defaults.bool(forKey: Keys.autoUpdatesModelPricing)
    }

    /// Reads the persisted flag without requiring a settings instance so the
    /// menu bar summary loop can consult the latest value.
    nonisolated static func isMenuBarCostEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Keys.showsMenuBarCost)
    }

    nonisolated static func currentRefreshIntervalSeconds(defaults: UserDefaults = .standard) -> Int {
        normalizedRefreshInterval(defaults.integer(forKey: Keys.refreshIntervalSeconds))
    }

    nonisolated static func currentUsageWindow(defaults: UserDefaults = .standard) -> CurrentUsageWindow {
        guard let rawValue = defaults.string(forKey: Keys.currentUsageWindow),
              let window = CurrentUsageWindow(rawValue: rawValue) else {
            return .calendarDay
        }
        return window
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
        static let autoUpdatesModelPricing = "usagePanel.autoUpdatesModelPricing"
        static let showsMenuBarCost = "usagePanel.showsMenuBarCost"
        static let currentUsageWindow = "usagePanel.currentUsageWindow"
        static let tabOrder = "usagePanel.tabOrder"
    }

    /// Drops unknown or duplicated raw values and appends any tab the stored
    /// order predates, so a shipped tab is never lost from the tab bar.
    static func normalizedTabOrder(_ stored: [String]) -> [PanelTab] {
        let storedTabs = stored.compactMap(PanelTab.init(rawValue:))
        let uniqueStoredTabs = storedTabs.reduce(into: [PanelTab]()) { result, tab in
            guard !result.contains(tab) else { return }
            result.append(tab)
        }
        let missingTabs = PanelTab.allCases.filter { tab in
            !uniqueStoredTabs.contains(tab)
        }
        return uniqueStoredTabs + missingTabs
    }

    nonisolated static func normalizedRefreshInterval(_ seconds: Int) -> Int {
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

extension Notification.Name {
    static let usagePanelMenuBarCostSettingDidChange =
        Notification.Name("usagePanelMenuBarCostSettingDidChange")
    static let usagePanelCurrentUsageWindowDidChange =
        Notification.Name("usagePanelCurrentUsageWindowDidChange")
    static let usagePanelReaderSettingsDidChange =
        Notification.Name("usagePanelReaderSettingsDidChange")
    static let usagePanelRefreshIntervalDidChange =
        Notification.Name("usagePanelRefreshIntervalDidChange")
    static let usagePanelModelPricingDidChange =
        Notification.Name("usagePanelModelPricingDidChange")
    static let usagePanelRemoteSyncDidChange =
        Notification.Name("usagePanelRemoteSyncDidChange")
}
