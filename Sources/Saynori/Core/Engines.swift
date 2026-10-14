import Foundation

/// Every engine Saynori can run on: cloud providers (API key) and models on this Mac.
/// Speech recognition and formatting are chosen separately; a provider can do one or both.
enum Provider: String, CaseIterable, Identifiable {
    case sarvam, openai, gemini, groq, deepgram, elevenlabs, cartesia
    case parakeet, whistle, gemma

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sarvam: return "Sarvam"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .deepgram: return "Deepgram"
        case .elevenlabs: return "ElevenLabs"
        case .cartesia: return "Cartesia"
        case .parakeet: return "Parakeet"
        case .whistle: return "Whistle"
        case .gemma: return "Gemma 4"
        }
    }

    var blurb: String {
        switch self {
        case .sarvam: return "Best for Hindi, Indian languages and code-mixing"
        case .openai: return "gpt-4o-mini-transcribe; formats with GPT"
        case .gemini: return "Gemini Flash hears audio and formats text"
        case .groq: return "Whisper large v3 turbo, very fast; formats with Llama"
        case .deepgram: return "Nova-3, fast and accurate in English"
        case .elevenlabs: return "Scribe, 99 languages"
        case .cartesia: return "Ink-Whisper, low latency"
        case .parakeet: return "NVIDIA Parakeet v3 on the Neural Engine. English + 24"
        case .whistle: return "Cactus Whistle, 17 MB, CPU only. English + 6"
        case .gemma: return "Gemma 4 via Ollama. Multilingual, slower"
        }
    }

    var isLocal: Bool { [.parakeet, .whistle, .gemma].contains(self) }
    var needsKey: Bool { !isLocal }
    /// Can it also rewrite text (formatting, Prompt mode, command mode)?
    var canFormat: Bool { [.sarvam, .openai, .gemini, .groq, .gemma].contains(self) }

    var keyURL: String {
        switch self {
        case .sarvam: return "https://dashboard.sarvam.ai"
        case .openai: return "https://platform.openai.com/api-keys"
        case .gemini: return "https://aistudio.google.com/apikey"
        case .groq: return "https://console.groq.com/keys"
        case .deepgram: return "https://console.deepgram.com"
        case .elevenlabs: return "https://elevenlabs.io/app/settings/api-keys"
        case .cartesia: return "https://play.cartesia.ai/keys"
        default: return ""
        }
    }

    /// What has to be on disk before the first dictation, for the onboarding's download step.
    var download: String? {
        switch self {
        case .parakeet: return "469 MB"
        case .whistle: return "17 MB"
        case .gemma: return "≈6.7 GB via Ollama"
        default: return nil
        }
    }

    static var cloud: [Provider] { allCases.filter { !$0.isLocal } }
    static var local: [Provider] { allCases.filter(\.isLocal) }
    static var formatters: [Provider] { allCases.filter(\.canFormat) }

    /// Default speech model per provider.
    var speechModel: String {
        switch self {
        case .sarvam: return "saaras:v4"
        case .openai: return "gpt-4o-mini-transcribe"
        case .gemini: return "gemini-flash-latest"
        case .groq: return "whisper-large-v3-turbo"
        case .deepgram: return "nova-3"
        case .elevenlabs: return "scribe_v1"
        case .cartesia: return "ink-whisper"
        default: return ""
        }
    }

    /// Default chat model per provider, for formatting.
    var chatModel: String {
        switch self {
        case .sarvam: return SarvamClient.chatModel
        case .openai: return "gpt-4.1-mini"
        case .gemini: return "gemini-flash-latest"
        case .groq: return "llama-3.3-70b-versatile"
        default: return ""
        }
    }

    /// OpenAI-compatible chat endpoint (Sarvam, Gemini and Groq all speak the same format).
    var chatURL: URL? {
        switch self {
        case .sarvam: return URL(string: "https://api.sarvam.ai/v1/chat/completions")
        case .openai: return URL(string: "https://api.openai.com/v1/chat/completions")
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        case .groq: return URL(string: "https://api.groq.com/openai/v1/chat/completions")
        default: return nil
        }
    }

    func authorize(_ req: inout URLRequest, key: String) {
        switch self {
        case .sarvam: req.setValue(key, forHTTPHeaderField: "api-subscription-key")
        case .deepgram: req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        case .elevenlabs: req.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .gemini: req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .cartesia:
            req.setValue(key, forHTTPHeaderField: "X-API-Key")
            req.setValue("2025-04-16", forHTTPHeaderField: "Cartesia-Version")
        default: req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }
}

enum EngineError: LocalizedError {
    case missingKey(Provider)
    case http(Provider, Int, String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "Add your \(p.name) API key in Settings"
        case .http(let p, 401, _), .http(let p, 403, _): return "\(p.name) didn't accept the API key"
        case .http(let p, 429, _): return "\(p.name) rate limit hit, try again"
        case .http(let p, let code, _) where code >= 500: return "\(p.name) is unavailable, try again"
        case .http(let p, let code, let msg): return "\(p.name) error \(code): \(msg)"
        }
    }
}

/// Per-provider API keys, kept in Application Support/Saynori/config.json (mode 600).
enum KeyStore {
    private static var url: URL { AppSettings.supportDir.appendingPathComponent("config.json") }

    static func load() -> [String: String] {
        var keys = [String: String]()
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            keys = obj["keys"] as? [String: String] ?? [:]
            // Older installs stored only the Sarvam key.
            if let s = obj["sarvamApiKey"] as? String, !s.isEmpty, keys["sarvam"] == nil { keys["sarvam"] = s }
        }
        let env = ProcessInfo.processInfo.environment
        for p in Provider.cloud where keys[p.rawValue] == nil {
            if let v = env["\(p.rawValue.uppercased())_API_KEY"], !v.isEmpty { keys[p.rawValue] = v }
        }
        return keys
    }

    static func save(_ keys: [String: String]) {
        let clean = keys.filter { !$0.value.isEmpty }
        guard let data = try? JSONSerialization.data(withJSONObject: ["keys": clean], options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Cloud speech-to-text. Each call takes one WAV chunk (16 kHz mono, under 30 s).
enum CloudSpeech {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 45
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    static func transcribe(_ p: Provider, key: String, wav: Data, language: String, keyterms: [String]) async throws -> String {
        guard !key.isEmpty else { throw EngineError.missingKey(p) }
        // ISO-639-1 from the app's setting ("hi-IN" → "hi"); nil means detect.
        let lang: String? = language == "unknown" ? nil : String(language.prefix(2))
        let terms = Array(keyterms.filter { $0.count <= 64 }.prefix(50))
        var req: URLRequest
        switch p {
        case .openai, .groq:
            let url = p == .openai ? "https://api.openai.com/v1/audio/transcriptions" : "https://api.groq.com/openai/v1/audio/transcriptions"
            var form = Multipart()
            form.file("file", "audio.wav", "audio/wav", wav)
            form.field("model", p.speechModel)
            form.field("response_format", "json")
            if let lang { form.field("language", lang) }
            if !terms.isEmpty { form.field("prompt", "Vocabulary: " + terms.joined(separator: ", ")) }
            req = form.request(URL(string: url)!)
        case .elevenlabs:
            var form = Multipart()
            form.file("file", "audio.wav", "audio/wav", wav)
            form.field("model_id", p.speechModel)
            form.field("tag_audio_events", "false")
            if let lang { form.field("language_code", lang) }
            req = form.request(URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        case .cartesia:
            var form = Multipart()
            form.file("file", "audio.wav", "audio/wav", wav)
            form.field("model", p.speechModel)
            form.field("language", lang ?? "en")
            req = form.request(URL(string: "https://api.cartesia.ai/stt")!)
        case .deepgram:
            var c = URLComponents(string: "https://api.deepgram.com/v1/listen")!
            c.queryItems = [.init(name: "model", value: p.speechModel), .init(name: "smart_format", value: "true"),
                            .init(name: "punctuate", value: "true"), .init(name: "language", value: lang ?? "multi")]
            c.queryItems! += terms.map { .init(name: "keyterm", value: $0) }
            req = URLRequest(url: c.url!)
            req.httpMethod = "POST"
            req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            req.httpBody = wav
        case .gemini:
            var prompt = "Transcribe this audio exactly as spoken, in the language and script it was spoken in. Do not translate, summarise or answer it. Output only the transcript, or nothing if there is no speech."
            if !terms.isEmpty { prompt += " Spell these names and terms exactly: \(terms.joined(separator: ", "))." }
            let body: [String: Any] = [
                "contents": [["parts": [["text": prompt], ["inline_data": ["mime_type": "audio/wav", "data": wav.base64EncodedString()]]]]],
                "generationConfig": ["temperature": 0, "thinkingConfig": ["thinkingBudget": 0]],
            ]
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(p.speechModel):generateContent")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        default:
            fatalError("\(p) isn't a cloud speech provider")
        }
        p.authorize(&req, key: key)
        let json = try await send(req, p)
        let text: String
        switch p {
        case .deepgram:
            let ch = ((json["results"] as? [String: Any])?["channels"] as? [[String: Any]])?.first
            text = ((ch?["alternatives"] as? [[String: Any]])?.first?["transcript"] as? String) ?? ""
        case .gemini:
            let parts = (((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            text = parts.compactMap { $0["text"] as? String }.joined()
        default:
            text = json["text"] as? String ?? ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// OpenAI-style chat completion for formatting.
    static func chat(_ p: Provider, key: String, messages: [[String: Any]], maxTokens: Int, temperature: Double,
                     model: String? = nil, reasoning: String? = nil) async throws -> String {
        guard !key.isEmpty else { throw EngineError.missingKey(p) }
        guard let url = p.chatURL else { fatalError("\(p) can't format") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Gemini's OpenAI-compatible endpoint takes a Bearer token, unlike its native API.
        if p == .gemini { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") } else { p.authorize(&req, key: key) }
        var payload: [String: Any] = ["model": model ?? p.chatModel, "temperature": temperature, "messages": messages]
        payload[p == .openai ? "max_completion_tokens" : "max_tokens"] = maxTokens + (reasoning == nil ? 0 : 1500)
        if let reasoning { payload["reasoning_effort"] = reasoning }
        if p == .gemini { payload["reasoning_effort"] = "none" }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let json = try await send(req, p)
        guard let msg = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]),
              var content = msg["content"] as? String else { throw SarvamError.empty }
        if let r = content.range(of: "</think>") { content = String(content[r.upperBound...]) }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw SarvamError.empty }
        return content
    }

    /// Proves the key works with a real request (half a second of silence), the same path dictation uses.
    static func check(_ p: Provider, key: String) async -> (ok: Bool, message: String) {
        let start = Date()
        do {
            let wav = WAV.encode(ArraySlice(Array(repeating: Int16(0), count: 8000)))
            if p == .sarvam {
                _ = try await SarvamClient(apiKey: key).transcribe(wav: wav, model: "saaras:v3", language: "unknown", mode: .transcribe)
            } else {
                _ = try await transcribe(p, key: key, wav: wav, language: "unknown", keyterms: [])
            }
            return (true, "Key works (\(Int(Date().timeIntervalSince(start) * 1000)) ms)")
        } catch {
            return (false, SarvamError.describe(error))
        }
    }

    private static func send(_ req: URLRequest, _ p: Provider) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let any = try? JSONSerialization.jsonObject(with: data)
        let json = any as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let err = (json["error"] as? [String: Any])?["message"] as? String
                ?? (json["detail"] as? [String: Any])?["message"] as? String
                ?? json["detail"] as? String ?? json["err_msg"] as? String ?? json["message"] as? String
                ?? ((any as? [[String: Any]])?.first?["error"] as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8) ?? "request failed"
            // Gemini reports a bad key as 400.
            let badKey = code == 400 && err.lowercased().contains("api key")
            throw EngineError.http(p, badKey ? 401 : code, String(err.prefix(160)))
        }
        return json
    }
}

struct Multipart {
    let boundary = "tlm-\(UUID().uuidString)"
    var body = Data()

    mutating func field(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }

    mutating func file(_ name: String, _ filename: String, _ type: String, _ data: Data) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var b = body
        b.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = b
        return req
    }
}
