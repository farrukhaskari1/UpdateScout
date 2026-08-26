import Foundation
import Security

/// API credentials are user-supplied and never belong in preferences or files.
actor SecureCredentialStore {
    static let shared = SecureCredentialStore()

    enum Credential: String, Sendable {
        case openAIAPIKey
        case googleAPIKey
        case anthropicAPIKey
        case customAIAPIKey
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain error \(status)"
        }
    }

    private let service = "com.local.updatescout.lookup"

    func save(_ value: String, for credential: Credential) throws {
        let data = Data(value.utf8)
        let base = baseQuery(for: credential)
        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                base as CFDictionary,
                [kSecValueData: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else { throw KeychainError(status: updateStatus) }
        case errSecInteractionNotAllowed:
            throw KeychainError(status: addStatus)
        default:
            throw KeychainError(status: addStatus)
        }
    }

    func load(_ credential: Credential) throws -> String? {
        var query = baseQuery(for: credential)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else { throw KeychainError(status: errSecParam) }
            return value
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw KeychainError(status: status)
        default:
            throw KeychainError(status: status)
        }
    }

    func delete(_ credential: Credential) throws {
        let status = SecItemDelete(baseQuery(for: credential) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(for credential: Credential) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: credential.rawValue,
            kSecUseDataProtectionKeychain: true
        ]
    }
}
