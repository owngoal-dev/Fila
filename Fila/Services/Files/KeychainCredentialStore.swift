import FilaBackendKit
import FilaLog
import Foundation
import Security

/// The app's keychain, as backends see it: one generic-password item per
/// key, under this app's own service name, readable after the first unlock.
///
/// A secret never passes through `UserDefaults`, a plist or the log; the
/// only place it is written is here, and the only reader is the backend
/// that owns the key. Removing a profile removes its item, so a deleted
/// share leaves no password behind.
final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String

    init(service: String = "wiki.qaq.fila.credentials") {
        self.service = service
    }

    func secret(for key: String) throws -> String? {
        var query = base(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func setSecret(_ secret: String?, for key: String) throws {
        let query = base(for: key)
        guard let secret else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(secret.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        default:
            throw KeychainError(status: updated)
        }
    }

    private func base(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

struct KeychainError: Error, CustomStringConvertible, LocalizedError {
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "keychain: \(message)"
    }

    var errorDescription: String? {
        String(localized: "Unable to use the saved password. Try entering it again.")
    }
}
