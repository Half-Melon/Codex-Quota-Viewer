import Foundation
import Security

protocol CredentialStore {
    func contains(account: String) throws -> Bool
    func read(account: String) throws -> Data
    func upsert(data: Data, account: String) throws
    func delete(account: String) throws
}

enum CredentialStoreError: LocalizedError, Equatable {
    case itemNotFound
    case invalidStoredData
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "找不到账号凭据。"
        case .invalidStoredData:
            return "Keychain 凭据数据已损坏。"
        case .keychainError(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain 错误：\(message)"
            }
            return "Keychain 错误：\(status)"
        }
    }
}

struct KeychainCredentialStore: CredentialStore {
    let service: String

    func contains(account: String) throws -> Bool {
        let query = baseQuery(account: account)
        let status = SecItemCopyMatching(query as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw CredentialStoreError.keychainError(status)
        }
    }

    func read(account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw CredentialStoreError.keychainError(errSecInternalComponent)
            }
            return data
        case errSecItemNotFound:
            throw CredentialStoreError.itemNotFound
        default:
            throw CredentialStoreError.keychainError(status)
        }
    }

    func upsert(data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw CredentialStoreError.keychainError(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychainError(addStatus)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainError(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
