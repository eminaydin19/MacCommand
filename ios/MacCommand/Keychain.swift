import Foundation
import Security

struct PairingStore {
    private let query: [String: Any]
    init(account: String = "pairing-v3") {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.eminaydin.maccommand", kSecAttrAccount as String: account]
        if let group = Bundle.main.object(forInfoDictionaryKey: "MacCommandKeychainGroup") as? String, !group.isEmpty {
            query[kSecAttrAccessGroup as String] = group
        }
        self.query = query
    }
    private func data() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw error(status) }
        return data
    }
    func load() throws -> Pairing? {
        guard let data = try data() else { return nil }
        return try Pairing.parse(String(decoding: data, as: UTF8.self))
    }
    func legacyFavoritesID() throws -> String? {
        struct Legacy: Decodable { let gist_id: String }
        guard let data = try data(), data.count < 4096 else { return nil }
        let id = try JSONDecoder().decode(Legacy.self, from: data).gist_id
        return id.range(of: #"\A[a-fA-F0-9]{20,64}\z"#, options: .regularExpression) == nil ? nil : id
    }
    func save(_ pairing: Pairing) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(pairing),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw error(status) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    private func error(_ status: OSStatus) -> NSError {
        NSError(domain: "MacCommand.Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey:
            "Pairing could not be read from or saved to secure storage. Unlock your iPhone and try again."])
    }
}
