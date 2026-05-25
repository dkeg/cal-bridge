import Foundation
import Security

struct KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    // MARK: - Keys
    static let googleRefreshToken = "com.calnotion.googleRefreshToken"
    static let notionAPIKey = "com.calnotion.notionAPIKey"
    static let googleAccessToken = "com.calnotion.googleAccessToken"

    // MARK: - Save
    @discardableResult
    func save(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Load
    func load(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    // MARK: - Delete
    @discardableResult
    func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    // MARK: - Convenience
    var hasCredentials: Bool {
        load(KeychainHelper.googleRefreshToken) != nil &&
        load(KeychainHelper.notionAPIKey) != nil
    }

    func clearAll() {
        delete(KeychainHelper.googleRefreshToken)
        delete(KeychainHelper.notionAPIKey)
        delete(KeychainHelper.googleAccessToken)
    }
}
