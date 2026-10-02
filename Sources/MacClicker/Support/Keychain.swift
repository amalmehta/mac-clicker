import Foundation
import Security

/// Stores the Anthropic API key in the login keychain.
///
/// Access is left at the macOS default: **only this application can read the item**,
/// and anything else has to ask you first. That default is only workable because the
/// app is signed with a stable identity — an ad-hoc signature changes on every
/// rebuild, which makes macOS treat each build as a stranger and prompt for the login
/// password. If you ever go back to ad-hoc signing, `reclaimAccess()` is the repair.
///
/// Two supporting choices:
///
///  * The value is cached in memory after the first successful read. macOS authorises
///    per reading process, so reading once per launch instead of once per request is
///    the difference between one prompt and a prompt on every hotkey press.
///  * Writes always delete and recreate the item rather than updating in place. An
///    item's access list is fixed when it is created, so recreating is the only way to
///    hand ownership to the binary running right now.
@MainActor
enum Keychain {
    private static let service = "com.amalmehta.MacClicker"
    private static let account = "anthropic-api-key"

    private static var cached: String?

    static func readAPIKey() -> String? {
        if let cached { return cached }

        var query: [String: Any] = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }

        cached = key
        return key
    }

    /// True when a key is stored, whether or not *this* build is allowed to read it.
    ///
    /// Asks for attributes rather than the secret itself, which needs no
    /// authorisation — so checking never triggers the login-password dialog.
    static var hasStoredItem: Bool {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    @discardableResult
    static func writeAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        cached = nil
        guard !trimmed.isEmpty else { return deleteAPIKey() }

        // Delete and recreate so the access list belongs to the running binary.
        // No kSecAttrAccess, so the item gets the default: this app only.
        SecItemDelete(baseQuery() as CFDictionary)

        var insert = baseQuery()
        insert[kSecValueData as String] = Data(trimmed.utf8)

        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { return false }
        cached = trimmed
        return true
    }

    @discardableResult
    static func deleteAPIKey() -> Bool {
        cached = nil
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Recreates the stored item so the binary running right now owns it.
    ///
    /// Needed once after the app's code signature changes — otherwise macOS sees an
    /// unfamiliar app asking for a familiar secret, and prompts for the login
    /// password on every read. Reading may itself prompt once; the rewrite that
    /// follows is what stops it recurring.
    @discardableResult
    static func reclaimAccess() -> Bool {
        guard let key = readAPIKey() else { return false }
        return writeAPIKey(key)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
