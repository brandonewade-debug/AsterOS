import Foundation
import Security

enum VPNKeychain {
    private static let service = "com.asterlinelabs.asteros.vpn"
    static func save(_ text: String) throws -> Data {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "VPNKeychainGroup") as? String, !group.contains("$(") else {
            throw VPNConfigurationError.keychain(errSecMissingEntitlement)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: UUID().uuidString,
            kSecAttrAccessGroup as String: group,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(text.utf8),
            kSecReturnPersistentRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &result)
        guard status == errSecSuccess, let reference = result as? Data else { throw VPNConfigurationError.keychain(status) }
        return reference
    }
    static func read(_ reference: Data) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecValuePersistentRef as String: reference,
                                  kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw VPNConfigurationError.keychain(status) }
        return text
    }
    static func remove(_ reference: Data) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecValuePersistentRef as String: reference] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VPNConfigurationError.keychain(status) }
    }
}
