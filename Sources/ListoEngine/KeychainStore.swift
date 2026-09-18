import Foundation
import Security

/// Stores the user's own LLM API key(s) (spec §05/§09: "trae tu propio LLM,
/// sin costo para la app") in the macOS Keychain rather than in
/// UserDefaults or a plist. Anthropic and OpenRouter keys are kept under
/// separate Keychain entries so switching providers in Settings doesn't
/// clobber the other one's key.
public enum KeychainStore {
    public enum Provider {
        case anthropic
        case openRouter

        var service: String {
            switch self {
            case .anthropic: return "com.listo.app.anthropic-api-key"
            case .openRouter: return "com.listo.app.openrouter-api-key"
            }
        }
    }

    private static let account = "default"

    public static func save(apiKey: String, provider: Provider = .anthropic) {
        let data = Data(apiKey.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public static func loadAPIKey(provider: Provider = .anthropic) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func clear(provider: Provider = .anthropic) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
