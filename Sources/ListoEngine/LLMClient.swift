import Foundation

public enum LLMError: Error {
    /// No API key configured, or the request couldn't reach the network.
    /// Callers should log `ListoDiffer.unresolvedChangeEvent` instead of
    /// failing (spec §05).
    case unavailable
    case badResponse(String)
}

/// The two jobs an LLM does in Listo, both opt-in and both requiring the
/// user's own API key (spec §05, §09): interpreting an ambiguous Modo Libre
/// diff, and reconciling a real Modo App/Modo Libre hand-off conflict.
public protocol LLMClient {
    func interpretDiff(fileName: String, oldText: String, newText: String) async throws -> [LogEvent]
    /// Reconciles a conflict where the file changed on disk while the user
    /// was mid-edit in Modo Libre. Returns the merged full document text.
    func mergeConflict(base: String, local: String, external: String) async throws -> String
}

/// Used when no API key is configured or the network is unreachable —
/// every call throws `.unavailable` so the caller falls back to logging an
/// `unresolved` event rather than guessing or failing outright.
public struct UnavailableLLMClient: LLMClient {
    public init() {}
    public func interpretDiff(fileName: String, oldText: String, newText: String) async throws -> [LogEvent] {
        throw LLMError.unavailable
    }
    public func mergeConflict(base: String, local: String, external: String) async throws -> String {
        throw LLMError.unavailable
    }
}

/// The two prompts both `LLMClient` implementations send — the task is
/// provider-agnostic, only how the response gets there (and back) differs.
private enum LLMPrompts {
    static func interpretDiff(oldText: String, newText: String) -> String {
        """
        Sos el motor de interpretación de cambios de Listo, una app de tareas \
        que guarda todo como markdown plano. Te paso el contenido de un archivo \
        antes y después de una edición libre. Decime qué eventos ocurrieron.

        Devolvé ÚNICAMENTE un array JSON (sin texto extra, sin markdown fences), \
        donde cada elemento tiene:
        {"event": "created"|"completed"|"reopened"|"edited"|"moved_section"|"reindented"|"note_updated"|"deleted",
         "text": "texto actual de la tarea",
         "section_path": ["seccion", "subseccion"] | null,
         "section_path_from": ["seccion"] | null,
         "section_path_to": ["seccion"] | null}

        Usá section_path_from/section_path_to solo para "moved_section"; \
        section_path para todos los demás. Distinguí una tarea "movida" de \
        "borrada + creada" comparando el texto: si el texto es el mismo o muy \
        similar en ambas versiones, es la misma tarea.

        ANTES:
        \(oldText)

        DESPUÉS:
        \(newText)
        """
    }

    static func mergeConflict(base: String, local: String, external: String) -> String {
        """
        Sos el resolutor de conflictos de Listo. El archivo cambió por fuera \
        mientras el usuario editaba en Modo Libre. Fusioná ambas versiones \
        preservando toda la intención de cada una (tareas agregadas, \
        completadas, editadas o movidas en cualquiera de las dos). Si algo \
        realmente choca, preferí conservar ambos cambios antes que descartar \
        uno.

        Devolvé ÚNICAMENTE el markdown fusionado final, sin explicaciones ni \
        fences de código.

        VERSIÓN BASE (antes de que empezaran a divergir):
        \(base)

        VERSIÓN LOCAL (lo que el usuario estaba escribiendo):
        \(local)

        VERSIÓN EXTERNA (lo que cambió en disco):
        \(external)
        """
    }
}

/// Both clients' responses are free-form text that should contain nothing
/// but a JSON array; this pulls just that array out in case the model adds
/// stray commentary or code fences despite being told not to.
private func extractJSONArray(from text: String) -> String? {
    guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]") else { return nil }
    return String(text[start...end])
}

/// Talks to the Anthropic Messages API directly with the user's own key.
public final class AnthropicLLMClient: LLMClient {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(apiKey: String, model: String = "claude-sonnet-5", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// Convenience initializer that reads the key from the Keychain;
    /// returns `nil` (use `UnavailableLLMClient` instead) if none is set.
    public convenience init?(model: String = "claude-sonnet-5") {
        guard let key = KeychainStore.loadAPIKey(provider: .anthropic), !key.isEmpty else { return nil }
        self.init(apiKey: key, model: model)
    }

    public func interpretDiff(fileName: String, oldText: String, newText: String) async throws -> [LogEvent] {
        let prompt = LLMPrompts.interpretDiff(oldText: oldText, newText: newText)
        let text = try await sendMessage(prompt: prompt)
        guard let jsonData = extractJSONArray(from: text)?.data(using: .utf8) else {
            throw LLMError.badResponse("No JSON array found in LLM response")
        }
        let dtos = try JSONDecoder().decode([LLMEventDTO].self, from: jsonData)
        return dtos.compactMap { $0.toLogEvent(fileName: fileName) }
    }

    public func mergeConflict(base: String, local: String, external: String) async throws -> String {
        let prompt = LLMPrompts.mergeConflict(base: base, local: local, external: external)
        return try await sendMessage(prompt: prompt)
    }

    private func sendMessage(prompt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.badResponse(body)
        }
        struct MessagesResponse: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw LLMError.badResponse("No text block in response")
        }
        return text
    }
}

/// Talks to OpenRouter's OpenAI-compatible chat completions API with the
/// user's own OpenRouter key — an alternative to `AnthropicLLMClient` that
/// lets the user pick any model OpenRouter hosts, including free ones.
public final class OpenRouterLLMClient: LLMClient {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(apiKey: String, model: String = "qwen/qwen3.8-27b:free", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// Convenience initializer that reads the key from the Keychain;
    /// returns `nil` (use `UnavailableLLMClient` instead) if none is set.
    public convenience init?(model: String = "qwen/qwen3.8-27b:free") {
        guard let key = KeychainStore.loadAPIKey(provider: .openRouter), !key.isEmpty else { return nil }
        self.init(apiKey: key, model: model)
    }

    public func interpretDiff(fileName: String, oldText: String, newText: String) async throws -> [LogEvent] {
        let prompt = LLMPrompts.interpretDiff(oldText: oldText, newText: newText)
        let text = try await sendMessage(prompt: prompt)
        guard let jsonData = extractJSONArray(from: text)?.data(using: .utf8) else {
            throw LLMError.badResponse("No JSON array found in LLM response")
        }
        let dtos = try JSONDecoder().decode([LLMEventDTO].self, from: jsonData)
        return dtos.compactMap { $0.toLogEvent(fileName: fileName) }
    }

    public func mergeConflict(base: String, local: String, external: String) async throws -> String {
        let prompt = LLMPrompts.mergeConflict(base: base, local: local, external: external)
        return try await sendMessage(prompt: prompt)
    }

    private func sendMessage(prompt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/sergiorivas/listo", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Listo", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.badResponse(body)
        }
        struct ChatCompletionsResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content else {
            throw LLMError.badResponse("No message content in response")
        }
        return text
    }
}

private struct LLMEventDTO: Decodable {
    let event: String
    let text: String
    let section_path: [String]?
    let section_path_from: [String]?
    let section_path_to: [String]?

    func toLogEvent(fileName: String) -> LogEvent? {
        guard let kind = LogEvent.Kind(rawValue: event) else { return nil }
        let path: LogEvent.SectionPath?
        if let from = section_path_from, let to = section_path_to {
            path = .move(from: from, to: to)
        } else if let plain = section_path {
            path = .path(plain)
        } else {
            path = nil
        }
        let taskID = "t_" + UUID().uuidString.prefix(4).lowercased()
        return LogEvent(
            file: fileName, event: kind, taskID: taskID, sectionPath: path,
            text: text, source: .freeEdit, interpretedBy: .llm
        )
    }
}
