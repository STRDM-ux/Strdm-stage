import Foundation
import Security

/// Minimal Anthropic Messages API client with tool use.
enum ClaudeClient {
    static let models: [(id: String, label: String)] = [
        ("claude-sonnet-5-5", "Sonnet 5.5 — fast, best value"),
        ("claude-opus-5-5", "Opus 5.5 — deepest thinking"),
        ("claude-haiku-5-5", "Haiku 5.5 — cheapest")
    ]
    static var model: String {
        get { UserDefaults.standard.string(forKey: "STRDMStage.aiModel") ?? models[0].id }
        set { UserDefaults.standard.set(newValue, forKey: "STRDMStage.aiModel") }
    }

    struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// One request. `messages` / `tools` are raw JSON-compatible dictionaries. Returns the response JSON.
    static func send(system: String, messages: [[String: Any]], tools: [[String: Any]], maxTokens: Int = 4096) async throws -> [String: Any] {
        guard let key = Keychain.apiKey, !key.isEmpty else { throw APIError(message: "Add your Anthropic API key in AI Crew → Settings.") }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = ["model": model, "max_tokens": maxTokens, "system": system, "messages": messages, "tools": tools]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw APIError(message: "Claude API \(http.statusCode): \(msg)")
        }
        return json
    }
}

/// API key kept in the macOS Keychain (never in the show file).
enum Keychain {
    private static let service = "io.strdm.stage.anthropic"
    static var apiKey: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(base as CFDictionary)
            guard let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(v.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
