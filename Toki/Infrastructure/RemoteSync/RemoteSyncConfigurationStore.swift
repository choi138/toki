import Foundation
import Security
import TokiSyncProtocol

struct RemoteHubConfiguration: Equatable {
    let hubURL: URL
    let ownerToken: String

    init(hubURL: URL, ownerToken: String) throws {
        guard TokiSyncValidation.isAllowedHubURL(hubURL) else {
            throw RemoteSyncConfigurationError.insecureHubURL
        }
        guard TokiSyncValidation.isSafeCredential(ownerToken) else {
            throw RemoteSyncConfigurationError.invalidOwnerToken
        }
        self.hubURL = hubURL
        self.ownerToken = ownerToken
    }

    var snapshotCacheIdentifier: String {
        SnapshotCipher.digest("toki-hub-origin-v1\0\(hubURL.absoluteString)")
    }
}

protocol RemoteSyncConfigurationProviding {
    func load() throws -> RemoteHubConfiguration?
    func encryptionKey(for deviceID: String) throws -> String?
}

protocol RemoteSyncConfigurationStoring: RemoteSyncConfigurationProviding {
    func save(_ configuration: RemoteHubConfiguration) throws
    func saveEncryptionKey(_ encryptionKey: String, for deviceID: String) throws
    func deleteEncryptionKey(for deviceID: String) throws
    func hasEncryptionKey(for deviceID: String) -> Bool
    func clear() throws
}

final class RemoteSyncConfigurationStore: RemoteSyncConfigurationStoring {
    private static let maximumEncodedEncryptionKeyBytes = 128

    private enum Keys {
        static let hubConfiguration = "hub-configuration-v2"
        static let legacyHubURL = "remoteSync.hubURL"
        static let legacyOwnerToken = "owner-token"
        static let deviceKeyIDs = "remoteSync.deviceKeyIDs"
        static let deviceKeyPrefix = "device-key:"
    }

    private let defaults: UserDefaults
    private let keychain: any KeychainCredentialStoring

    init(
        defaults: UserDefaults = .standard,
        keychain: any KeychainCredentialStoring = KeychainCredentialStore()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    func load() throws -> RemoteHubConfiguration? {
        guard let encodedRecord = try keychain.read(account: Keys.hubConfiguration) else {
            let hasLegacyURL = defaults.string(forKey: Keys.legacyHubURL) != nil
            let hasLegacyOwnerToken = try keychain.read(account: Keys.legacyOwnerToken) != nil
            if hasLegacyURL || hasLegacyOwnerToken {
                throw RemoteSyncConfigurationError.incompleteCredentials
            }
            return nil
        }
        do {
            guard encodedRecord.utf8.count <= TokiSyncLimits.maximumConfigurationFileBytes,
                  let data = Data(base64Encoded: encodedRecord),
                  data.count <= TokiSyncLimits.maximumConfigurationFileBytes else {
                throw RemoteSyncConfigurationError.invalidStoredConfiguration
            }
            let record = try JSONDecoder().decode(RemoteHubCredentialRecord.self, from: data)
            return try RemoteHubConfiguration(hubURL: record.hubURL, ownerToken: record.ownerToken)
        } catch let error as RemoteSyncConfigurationError {
            throw error
        } catch {
            throw RemoteSyncConfigurationError.invalidStoredConfiguration
        }
    }

    func save(_ configuration: RemoteHubConfiguration) throws {
        let record = RemoteHubCredentialRecord(
            hubURL: configuration.hubURL,
            ownerToken: configuration.ownerToken)
        let encodedRecord = try JSONEncoder().encode(record).base64EncodedString()
        try keychain.save(encodedRecord, account: Keys.hubConfiguration)
        try keychain.delete(account: Keys.legacyOwnerToken)
        defaults.removeObject(forKey: Keys.legacyHubURL)
    }

    func encryptionKey(for deviceID: String) throws -> String? {
        guard TokiSyncValidation.isSafeDeviceID(deviceID) else {
            throw RemoteSyncConfigurationError.invalidDeviceID
        }
        guard let encryptionKey = try keychain.read(account: deviceKeyAccount(for: deviceID)) else {
            return nil
        }
        guard encryptionKey.utf8.count <= Self.maximumEncodedEncryptionKeyBytes else {
            throw RemoteSyncConfigurationError.invalidStoredEncryptionKey
        }
        do {
            _ = try SnapshotCipher.opaqueIdentifier(for: "configuration-check", key: encryptionKey)
            return encryptionKey
        } catch {
            throw RemoteSyncConfigurationError.invalidStoredEncryptionKey
        }
    }

    func saveEncryptionKey(_ encryptionKey: String, for deviceID: String) throws {
        guard TokiSyncValidation.isSafeDeviceID(deviceID) else {
            throw RemoteSyncConfigurationError.invalidDeviceID
        }
        _ = try SnapshotCipher.opaqueIdentifier(for: "configuration-check", key: encryptionKey)
        try keychain.save(encryptionKey, account: deviceKeyAccount(for: deviceID))
        var deviceKeyIDs = storedDeviceKeyIDs
        deviceKeyIDs.insert(deviceID)
        defaults.set(Array(deviceKeyIDs).sorted(), forKey: Keys.deviceKeyIDs)
    }

    func deleteEncryptionKey(for deviceID: String) throws {
        guard TokiSyncValidation.isSafeDeviceID(deviceID) else {
            throw RemoteSyncConfigurationError.invalidDeviceID
        }
        try keychain.delete(account: deviceKeyAccount(for: deviceID))
        var deviceKeyIDs = storedDeviceKeyIDs
        deviceKeyIDs.remove(deviceID)
        defaults.set(Array(deviceKeyIDs).sorted(), forKey: Keys.deviceKeyIDs)
    }

    func hasEncryptionKey(for deviceID: String) -> Bool {
        (try? encryptionKey(for: deviceID)) != nil
    }

    func clear() throws {
        let indexedAccounts = Set(storedDeviceKeyIDs.map(deviceKeyAccount))
        let keychainAccounts = try Set(keychain.accounts(withPrefix: Keys.deviceKeyPrefix))
        for account in indexedAccounts.union(keychainAccounts).sorted() {
            try keychain.delete(account: account)
        }
        // Delete the current Hub credential record last so a partial Keychain
        // failure leaves a loadable configuration that can retry cleanup.
        try keychain.delete(account: Keys.legacyOwnerToken)
        try keychain.delete(account: Keys.hubConfiguration)
        defaults.removeObject(forKey: Keys.legacyHubURL)
        defaults.removeObject(forKey: Keys.deviceKeyIDs)
    }

    private var storedDeviceKeyIDs: Set<String> {
        Set((defaults.stringArray(forKey: Keys.deviceKeyIDs) ?? []).filter(TokiSyncValidation.isSafeDeviceID))
    }

    private func deviceKeyAccount(for deviceID: String) -> String {
        "\(Keys.deviceKeyPrefix)\(deviceID)"
    }
}

private struct RemoteHubCredentialRecord: Codable {
    let hubURL: URL
    let ownerToken: String
}

protocol KeychainCredentialStoring {
    func save(_ value: String, account: String) throws
    func read(account: String) throws -> String?
    func delete(account: String) throws
    func accounts(withPrefix prefix: String) throws -> [String]
}

struct KeychainCredentialStore: KeychainCredentialStoring {
    private let service = "com.toki.app.remote-sync"

    func save(_ value: String, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw RemoteSyncConfigurationError.keychain(updateStatus)
        }

        let addQuery = baseQuery.merging(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RemoteSyncConfigurationError.keychain(addStatus)
        }
    }

    func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw RemoteSyncConfigurationError.keychain(status)
        }
        return value
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteSyncConfigurationError.keychain(status)
        }
    }

    func accounts(withPrefix prefix: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw RemoteSyncConfigurationError.keychain(status)
        }

        let items: [[String: Any]]
        if let values = result as? [[String: Any]] {
            items = values
        } else if let value = result as? [String: Any] {
            items = [value]
        } else {
            throw RemoteSyncConfigurationError.keychain(errSecDecode)
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
    }
}

enum RemoteSyncConfigurationError: LocalizedError {
    case insecureHubURL
    case invalidOwnerToken
    case invalidDeviceID
    case incompleteCredentials
    case invalidStoredConfiguration
    case invalidStoredEncryptionKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .insecureHubURL:
            "The Hub URL must be a valid HTTPS origin no longer than 2048 bytes. " +
                "Plain HTTP is allowed only for localhost."
        case .invalidOwnerToken:
            "The Hub owner token must contain 32 to 512 printable ASCII bytes without spaces."
        case .invalidDeviceID:
            "The remote device identifier is invalid."
        case .incompleteCredentials:
            "Remote sync credentials are incomplete. Disconnect and connect the Hub again."
        case .invalidStoredConfiguration:
            "Remote sync credentials in Keychain are invalid. Disconnect and connect the Hub again."
        case .invalidStoredEncryptionKey:
            "A remote device encryption key in Keychain is invalid. Revoke and pair that device again."
        case let .keychain(status):
            "Keychain operation failed with status \(status)."
        }
    }
}
