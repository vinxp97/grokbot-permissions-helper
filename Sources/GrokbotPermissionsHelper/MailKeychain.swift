import Foundation
import Security

/// IMAP + webhook credentials. Stored only in the macOS Keychain.
/// Service name is fixed so docs stay stable; it is independent of the app bundle id.
enum MailKeychain {
    static let service = "com.grokbot.permissionshelper.mail"
    static let account = "imap"

    struct Config: Codable {
        var host: String
        var port: Int
        var username: String
        var password: String
        var webhookURL: String?
        var bearerToken: String?
    }

    enum KeychainError: LocalizedError {
        case saveFailed
        case notFound
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .saveFailed: return "Could not save mail settings to Keychain"
            case .notFound: return "No mail settings in Keychain. Run --mail-setup first."
            case .decodeFailed: return "Mail Keychain item could not be decoded"
            }
        }
    }

    static func save(_ config: Config) throws {
        let data = try JSONEncoder().encode(config)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updated: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, updated as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.saveFailed }
        } else if status != errSecSuccess {
            throw KeychainError.saveFailed
        }
    }

    static func load() throws -> Config {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.notFound
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw KeychainError.decodeFailed
        }
    }

    /// Merge a form submission with any existing item so blank password/bearer keep the old secret.
    static func mergedFromForm(
        host: String,
        port: Int,
        username: String,
        password: String,
        webhookURL: String,
        bearerToken: String
    ) throws -> Config {
        let existing = try? load()
        let pass: String
        if password.isEmpty {
            guard let old = existing?.password, !old.isEmpty else {
                throw KeychainError.saveFailed
            }
            pass = old
        } else {
            pass = password
        }
        let bearer: String?
        if bearerToken.isEmpty {
            bearer = existing?.bearerToken
        } else {
            bearer = bearerToken
        }
        let hook = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return Config(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port > 0 ? port : 993,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: pass,
            webhookURL: hook.isEmpty ? nil : hook,
            bearerToken: (bearer?.isEmpty == false) ? bearer : nil
        )
    }
}
