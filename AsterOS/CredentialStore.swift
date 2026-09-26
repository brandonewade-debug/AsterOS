import Foundation
import Security

enum CredentialStore {
    private static let service = "AsterOS.UnraidAPI"
    private static func lookup(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    static func save(_ key: String, for id: UUID) throws {
        var item = lookup(id)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let result = SecItemUpdate(lookup(id) as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
            guard result == errSecSuccess else { throw AppError.message("Unable to update the API key securely.") }
        } else if status != errSecSuccess { throw AppError.message("Unable to save the API key securely.") }
    }
    static func read(_ id: UUID) throws -> String {
        var item = lookup(id)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AppError.message("The saved API key is unavailable. Remove this connection and add it again.")
        }
        return key
    }
    static func remove(_ id: UUID) throws {
        let status = SecItemDelete(lookup(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.message("Unable to remove the API key.") }
    }
}
