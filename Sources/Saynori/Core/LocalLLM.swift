import Foundation

enum LocalLLMError: LocalizedError {
    case unreachable(String)
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreachable(let endpoint): return "Can't reach the local model at \(endpoint). Is Ollama running?"
        case .http(404, let msg): return "Local model not found: \(msg)"
        case .http(let code, let msg): return "Local model error \(code): \(msg)"
        case .empty: return "The local model returned nothing"
        }
    }
}

/// Talks to a model running on this Mac (Gemma 4 via Ollama by default). Nothing leaves the machine.
enum LocalLLM {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60      // a cold model load can take a few seconds
        return URLSession(configuration: c)
    }()

    /// How long Ollama keeps the model in memory after a request, so dictations stay fast.
    static let keepAlive = "30m"

    static func chat(kind: ChatEngine.LocalKind, endpoint: String, model: String, messages: [[String: Any]],
                     maxTokens: Int, temperature: Double) async throws -> String {
        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let url: URL
        var body: [String: Any] = ["model": model, "messages": messages, "stream": false]
        switch kind {
        case .ollama:
            // Native API: lets us switch Gemma's thinking off and keep the model warm.
            url = URL(string: base + "/api/chat")!
            body["think"] = false
            body["keep_alive"] = keepAlive
            body["options"] = ["temperature": temperature, "num_predict": maxTokens]
        case .openai:
            url = URL(string: base.hasSuffix("/v1") ? base + "/chat/completions" : base + "/v1/chat/completions")!
            body["temperature"] = temperature
            body["max_tokens"] = maxTokens
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw LocalLLMError.unreachable(base) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let msg = json["error"] as? String ?? (json["error"] as? [String: Any])?["message"] as? String ?? "request failed"
            throw LocalLLMError.http(code, String(msg.prefix(160)))
        }
        let content: String?
        switch kind {
        case .ollama: content = (json["message"] as? [String: Any])?["content"] as? String
        case .openai: content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        }
        guard var text = content else { throw LocalLLMError.empty }
        // Drop any reasoning a model emits inline.
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalLLMError.empty }
        return text
    }

    /// Speech-to-text with a local audio model (Gemma 4 E2B/E4B via Ollama). Ollama takes audio in the
    /// `images` field of a message; clips are already split under 30 s upstream.
    static func transcribe(endpoint: String, model: String, wav: Data, keyterms: [String]) async throws -> String {
        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var prompt = "Transcribe this audio exactly as spoken, in the language and script it was spoken in. Do not translate, summarise or answer it. Output only the transcript."
        if !keyterms.isEmpty {
            prompt += " These names and terms may come up; spell them exactly like this: \(keyterms.prefix(50).joined(separator: ", "))."
        }
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "keep_alive": keepAlive,
            "messages": [["role": "user", "content": prompt, "images": [wav.base64EncodedString()]]],
            "options": ["temperature": 0, "num_predict": 1024],
        ]
        var req = URLRequest(url: URL(string: base + "/api/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw LocalLLMError.unreachable(base) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            throw LocalLLMError.http(code, String((json["error"] as? String ?? "request failed").prefix(160)))
        }
        let text = ((json["message"] as? [String: Any])?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalLLMError.empty }
        return text
    }

    /// Loads the model into memory ahead of time (called when you press fn), so the first
    /// formatting call doesn't pay for a cold start.
    static func warmUp(kind: ChatEngine.LocalKind, endpoint: String, model: String) {
        guard kind == .ollama else { return }
        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/api/generate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": keepAlive])
        session.dataTask(with: req).resume()
    }

    /// For the Settings "Check" button: is the server up, and is the model installed?
    static func status(kind: ChatEngine.LocalKind, endpoint: String, model: String) async -> (ok: Bool, message: String) {
        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let path = kind == .ollama ? "/api/tags" : (base.hasSuffix("/v1") ? "/models" : "/v1/models")
        guard let url = URL(string: base + path) else { return (false, "That endpoint isn't a valid URL") }
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            return (false, kind == .ollama ? "Ollama isn't running at \(base)" : "No server at \(base)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let names: [String] = kind == .ollama
            ? (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            : (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let found = names.contains { $0 == model || $0 == model + ":latest" }
        if !found {
            return (false, kind == .ollama ? "\(model) isn't installed. Run: ollama pull \(model)" : "\(model) isn't loaded on the server")
        }
        // A real round trip, so the check also covers load time and response.
        let start = Date()
        do {
            _ = try await chat(kind: kind, endpoint: base, model: model,
                               messages: [["role": "user", "content": "Reply with the single word: ok"]],
                               maxTokens: 8, temperature: 0)
            return (true, "\(model) is ready (\(Int(Date().timeIntervalSince(start) * 1000)) ms)")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
