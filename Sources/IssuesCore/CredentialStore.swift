import Foundation
import Security

public enum CredentialStore {
    private static let service = "com.issues.macos.github"
    private static let account = "personal-access-token"

    public static func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidStoredValue
        }
        return token
    }

    public static func save(_ token: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CredentialStoreError.emptyToken }
        let data = Data(token.utf8)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
    }

    public static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}

public enum CredentialStoreError: Error, LocalizedError, Sendable {
    case emptyToken
    case invalidStoredValue
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "The GitHub token cannot be empty."
        case .invalidStoredValue:
            return "The GitHub token stored in Keychain is invalid."
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "Keychain operation failed: \(detail)"
        }
    }
}
