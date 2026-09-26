import Foundation
import Security

enum CredentialStore {
    private static let service = "AsterOS.UnraidAPI"
    private static func lookup(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    private static func failure(_ operation: String, status: OSStatus) -> AppError {
        if status == errSecMissingEntitlement {
            return .message("This build is missing its Keychain signing entitlement. Install a correctly signed AsterOS build, then retry saving the connection. (\(status))")
        }
        if status == errSecInteractionNotAllowed {
            return .message("Keychain is locked. Unlock this device and try again. (\(status))")
        }
        return .message("Unable to \(operation) the credential securely. Keychain error \(status).")
    }
    static func save(_ key: String, for id: UUID) throws {
        var item = lookup(id)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let result = SecItemUpdate(lookup(id) as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
            guard result == errSecSuccess else { throw failure("update", status: result) }
        } else if status != errSecSuccess { throw failure("save", status: status) }
    }
    static func read(_ id: UUID) throws -> String {
        var item = lookup(id)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AppError.message("The saved credential is unavailable. Remove this connection and add it again.")
        }
        return key
    }
    static func remove(_ id: UUID) throws {
        let status = SecItemDelete(lookup(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("remove", status: status) }
    }
}
