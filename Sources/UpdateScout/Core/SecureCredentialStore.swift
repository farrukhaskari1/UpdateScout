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

    /// The data-protection keychain is the modern, better-isolated one, but it
    /// requires a `keychain-access-groups` entitlement — which comes from an
    /// embedded provisioning profile, not merely from signing. A locally built
    /// copy has no such profile, so every call returns
    /// `errSecMissingEntitlement` and the legacy file-based keychain is the
    /// only option. Prefer the modern one, drop to legacy the first time the
    /// system refuses, and remember the answer for the process lifetime.
    private var usesDataProtectionKeychain = true

    /// Keychain calls block. On the legacy keychain macOS may put up a
    /// SecurityAgent prompt and wait — potentially minutes — and the Swift
    /// cooperative pool has roughly one thread per core, so blocking one there
    /// can stall unrelated work. Everything runs on this queue instead.
    private static let queue = DispatchQueue(
        label: "com.local.updatescout.keychain",
        qos: .userInitiated
    )

    private static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Query construction
    //
    // Built from Sendable primitives inside the worker closure, so no
    // actor-isolated state crosses onto the queue.

    private static func baseQuery(
        service: String,
        account: String,
        dataProtection: Bool
    ) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }

    /// Runs `body` for the preferred keychain, and once more against the legacy
    /// one if the system says we lack the entitlement.
    private func attempting(
        _ body: @escaping @Sendable (_ dataProtection: Bool) -> OSStatus
    ) async -> OSStatus {
        let preferred = usesDataProtectionKeychain
        let status = await Self.offPool { body(preferred) }
        guard status == errSecMissingEntitlement, preferred else { return status }
        usesDataProtectionKeychain = false
        return await Self.offPool { body(false) }
    }

    // MARK: - Operations

    func save(_ value: String, for credential: Credential) async throws {
        let data = Data(value.utf8)
        let service = self.service
        let account = credential.rawValue

        let addStatus = await attempting { dataProtection in
            var add = Self.baseQuery(
                service: service, account: account, dataProtection: dataProtection
            )
            add[kSecValueData] = data
            // kSecAttrAccessible applies only to the data-protection keychain;
            // the legacy shim ignores it, so don't imply a guarantee we lose.
            if dataProtection {
                add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
            return SecItemAdd(add as CFDictionary, nil)
        }

        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = await attempting { dataProtection in
                SecItemUpdate(
                    Self.baseQuery(
                        service: service, account: account, dataProtection: dataProtection
                    ) as CFDictionary,
                    [kSecValueData: data] as CFDictionary
                )
            }
            guard updateStatus == errSecSuccess else { throw KeychainError(status: updateStatus) }
        default:
            throw KeychainError(status: addStatus)
        }
    }

    func load(_ credential: Credential) async throws -> String? {
        let service = self.service
        let account = credential.rawValue

        // The value is carried back through a box rather than an `inout`
        // capture, because the read happens on another queue.
        let box = ResultBox()
        let status = await attempting { dataProtection in
            var query = Self.baseQuery(
                service: service, account: account, dataProtection: dataProtection
            )
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess { box.data = item as? Data }
            return status
        }

        switch status {
        case errSecSuccess:
            guard let data = box.data,
                  let value = String(data: data, encoding: .utf8)
            else { throw KeychainError(status: errSecParam) }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func delete(_ credential: Credential) async throws {
        let service = self.service
        let account = credential.rawValue

        let status = await attempting { dataProtection in
            SecItemDelete(
                Self.baseQuery(
                    service: service, account: account, dataProtection: dataProtection
                ) as CFDictionary
            )
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// Carries one keychain read back from the worker queue.
///
/// Only ever written on that queue and read after the `await` resumes, so the
/// two accesses are ordered by the continuation.
private final class ResultBox: @unchecked Sendable {
    var data: Data?
}
