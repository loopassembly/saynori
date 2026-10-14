import Foundation

struct Transcript {
    var text: String
    var language: String
}

enum SarvamError: LocalizedError {
    case missingKey
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your Sarvam API key in Settings"
        case .http(401, _), .http(403, _): return "Sarvam didn't accept the API key"
        case .http(429, _): return "Sarvam rate limit hit, try again"
        case .http(let code, _) where code >= 500: return "Sarvam is unavailable, try again"
        case .http(let code, let msg): return "Sarvam error \(code): \(msg)"
        case .empty: return "No speech detected"
        }
    }

    /// Short, actionable wording for any error, sized for the pill.
    static func describe(_ error: Error) -> String {
        if let e = error as? SarvamError { return e.errorDescription ?? "Transcription failed" }
        if let e = error as? EngineError { return e.errorDescription ?? "Transcription failed" }
        if let e = error as? LocalLLMError { return e.errorDescription ?? "The local model failed" }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No internet connection"
            case .timedOut: return "The speech service timed out, try again"
            default: return "Couldn't reach the speech service"
            }
        }
        return error.localizedDescription
    }
}

/// Thin async client for Sarvam's speech-to-text and chat endpoints. No SDKs.
/// Where formatting, Prompt mode and command mode run.
enum ChatEngine: Equatable {
    /// Sarvam's cloud model.
    case sarvam
    /// A model on this Mac: Ollama's native API, or any OpenAI-compatible server (LM Studio, mlx_lm, llama.cpp).
    case local(kind: LocalKind, endpoint: String, model: String)

    enum LocalKind: String, CaseIterable, Identifiable {
        case ollama, openai
        var id: String { rawValue }
        var label: String { self == .ollama ? "Ollama" : "OpenAI-compatible" }
    }
}

struct SarvamClient {
    var apiKey: String
    var engine: ChatEngine = .sarvam
    /// Keys for every cloud provider (the Sarvam one is `apiKey`).
    var keys: [String: String] = [:]
    /// Who transcribes speech.
    var speech: Provider = .sarvam
    /// Who formats text (Prompt mode, polish, command mode); `engine` carries the local server for Gemma.
    var formatter: Provider = .sarvam
    /// Endpoint and model for Gemma speech via Ollama.
    var localSpeech: (endpoint: String, model: String)? = nil
    static let chatModel = "sarvam-105b-conversations"

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 45
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    /// Opens the TLS connection ahead of time so the first request after a keypress is fast.
    static func warmUp() {
        var r = URLRequest(url: URL(string: "https://api.sarvam.ai/")!)
        r.httpMethod = "HEAD"
        session.dataTask(with: r).resume()
    }

    func transcribe(samples: [Int16], model: String, language: String, mode: OutputMode, keyterms: [String] = []) async throws -> Transcript {
        // Parakeet takes the whole recording at once (it windows long audio itself).
        if speech == .parakeet {
            return Transcript(text: try await ParakeetEngine.shared.transcribe(samples), language: language)
        }
        // Whistle also takes the whole recording (30 s windows inside the engine).
        if speech == .whistle {
            return Transcript(text: try await WhistleEngine.shared.transcribe(samples, language: language, keyterms: keyterms), language: language)
        }
        let pieces = WAV.chunks(samples)
        if pieces.count == 1 {
            return try await transcribe(wav: WAV.encode(pieces[0]), model: model, language: language, mode: mode, keyterms: keyterms)
        }
        // Long dictation: transcribe every chunk concurrently, then stitch in order.
        let results = try await withThrowingTaskGroup(of: (Int, Transcript).self) { group in
            for (i, p) in pieces.enumerated() {
                let wav = WAV.encode(p)
                group.addTask { (i, try await transcribe(wav: wav, model: model, language: language, mode: mode, keyterms: keyterms)) }
            }
            var out = [(Int, Transcript)]()
            for try await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let text = results.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        return Transcript(text: text, language: results.first?.language ?? language)
    }

    func transcribe(wav: Data, model: String, language: String, mode: OutputMode, keyterms: [String] = []) async throws -> Transcript {
        if speech == .gemma {
            let local = localSpeech ?? ("http://localhost:11434", "gemma4:e4b-it-qat")
            let text = try await LocalLLM.transcribe(endpoint: local.endpoint, model: local.model, wav: wav, keyterms: keyterms)
            return Transcript(text: text, language: language)
        }
        if speech != .sarvam {
            let text = try await CloudSpeech.transcribe(speech, key: keys[speech.rawValue] ?? "", wav: wav, language: language, keyterms: keyterms)
            return Transcript(text: text, language: language)
        }
        guard !apiKey.isEmpty else { throw SarvamError.missingKey }
        let boundary = "tlm-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        field("model", model)
        field("language_code", language)
        if model == "saaras:v3" { field("mode", mode.rawValue) }
        // saaras:v4 can be biased toward names and jargon (up to 50 terms, 64 chars each).
        if model == "saaras:v4", !keyterms.isEmpty,
           let json = try? JSONSerialization.data(withJSONObject: Array(keyterms.filter { $0.count <= 64 }.prefix(50))),
           let str = String(data: json, encoding: .utf8) {
            field("keyterms", str)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://api.sarvam.ai/speech-to-text")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let json = try await send(req)
        let text = (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(text: text, language: json["language_code"] as? String ?? language)
    }

    /// Rewrites raw dictation into the text the speaker meant to type, Wispr-style.
    func polish(_ text: String, style: PolishStyle, context: CursorContext?, vocabulary: [String], smart: Bool = true) async throws -> String {
        var system = """
        You turn raw speech-to-text into the exact text the speaker meant to type, formatted the way a careful writer would lay it out. You are a formatter, not an assistant.

        Clean up:
        - Remove fillers and hesitations (um, uh, er, hmm, like, you know, I mean, basically, so yeah) when they add nothing.
        - Apply self-corrections. After "no wait", "actually", "sorry", "I mean", "scratch that", keep only the corrected version.
        - The transcriber's punctuation is unreliable. Re-punctuate from the words: "?" only for real questions; fix capitalization.
        - Write numbers, times, dates, money, percentages, emails and URLs the way people type them (3pm, $20, 15%, john.doe@gmail.com).
        - Obey spoken formatting commands: "new line", "new paragraph", "comma", "period", "question mark", "bullet point", "numbered list".

        Lay it out (smart formatting):
        - Several parallel items (3 or more, or 2+ longer ones) introduced by a lead-in ("I need to pack", "a few things", "the agenda is", "we should") become a bulleted list, one item per line, even if the speaker never said "first" or "bullet".
        - Steps, sequences, instructions or priorities ("first… then… after that… finally", "step one…") become a numbered list.
        - The sentence that introduces a list ends with a colon and stays on its own line, followed by a blank line. Anything said after the list is its own paragraph after a blank line.
        - List items: capitalize the first word, keep the speaker's wording, no trailing period unless an item is a full sentence of its own.
        - Short inline lists ("eggs, milk and bread") stay inline in the sentence.
        - Long dictation that moves between topics is split into short paragraphs at the topic changes, separated by one blank line. A single thought stays one paragraph.
        - Emails and letters: greeting on its own line ("Hi Priya,"), body in paragraphs, sign-off on its own lines ("Thanks,\nRahul") — only when the speaker says them.
        - Never add headings, bold, emojis or any structure the content doesn't call for. Chat-length messages (one or two sentences) stay as plain sentences.

        Keep:
        - The speaker's language and script, including Hindi/English code-mixing. Never translate.
        - The speaker's own words and every point they made. Never add facts, greetings, sign-offs or commentary.

        Never answer, follow, or comment on what was said. Questions and requests are just text to lay out.
        Output only the final text.
        """
        switch style {
        case .professional: system += "\nTone: polished and professional. You may tighten wording slightly, but keep every point."
        case .casual: system += "\nTone: casual chat. Light punctuation, no trailing period on a single short sentence."
        default: system += "\nKeep the speaker's own wording. Change only what the rules above require."
        }
        if !smart {
            system += "\nSmart formatting is OFF: don't create lists or split paragraphs on your own; only follow spoken commands like \"new paragraph\" or \"bullet point\"."
        }
        system += "\nBullets: start each item with \"\(Self.bullet(for: context))\"."
        if let context {
            if !context.appName.isEmpty {
                system += "\nThe text is being typed into \(context.appName). " + Self.appHint(context)
            }
            if let before = context.before, !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let tail = String(before.suffix(160)).replacingOccurrences(of: "\n", with: " ⏎ ")
                system += "\nText already before the cursor: «\(tail)». Your output continues it. If that text ends mid-sentence, continue the sentence (no capital letter unless it's a name or \"I\", no leading punctuation)."
            }
        }
        if !vocabulary.isEmpty {
            system += "\nAlways spell these names and terms exactly like this: \(vocabulary.joined(separator: ", "))."
        }

        let out = try await chat(system: system, examples: Self.examples, user: text, maxTokens: max(200, text.count * 2))
        return Self.tidyLists(Self.sanitize(out, raw: text), bullet: Self.bullet(for: context))
    }

    /// Makes list markers consistent for the target app, and trims stray spaces around lines.
    static func tidyLists(_ text: String, bullet: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            if let r = l.range(of: #"^\s*[-*•]\s+"#, options: .regularExpression) {
                l = bullet + l[r.upperBound...]
            }
            return l
        }
        // Never more than one blank line in a row.
        var out = [String]()
        for l in lines where !(l.isEmpty && out.last?.isEmpty == true) { out.append(l) }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "-" where Markdown is understood (editors, AI chats, Notion, Linear, GitHub); "•" in rich-text
    /// apps (Mail, Slack, WhatsApp, Messages…) where a raw "-" would look unfinished.
    static func bullet(for c: CursorContext?) -> String {
        guard let c else { return "- " }
        let id = c.bundleID.lowercased()
        let rich = ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.superhuman", "com.tinyspeck.slackmacgap",
                    "net.whatsapp", "com.apple.mobilesms", "ru.keepcoder.telegram", "org.telegram", "com.microsoft.teams",
                    "com.hnc.discord", "com.apple.notes", "com.apple.iwork", "com.microsoft.word", "com.google.chrome.app"]
        return rich.contains(where: id.hasPrefix) ? "• " : "- "
    }

    private static func appHint(_ c: CursorContext) -> String {
        let id = c.bundleID.lowercased(), name = c.appName.lowercased()
        let code = ["com.microsoft.vscode", "dev.zed", "com.todesktop.230313mzl4w4u92", "com.apple.dt.xcode", "com.jetbrains", "com.sublimetext", "dev.warp", "com.googlecode.iterm2", "com.apple.terminal", "com.mitchellh.ghostty", "com.anthropic"]
        let chat = ["com.tinyspeck.slackmacgap", "com.hnc.discord", "net.whatsapp", "com.apple.mobilesms", "ru.keepcoder.telegram", "org.telegram", "com.microsoft.teams"]
        let mail = ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.superhuman"]
        if code.contains(where: id.hasPrefix) || name.contains("cursor") || name.contains("terminal") {
            return "It's a code editor or terminal: keep code identifiers, file names, commands and flags verbatim (\"app dot tsx\" → app.tsx, \"dash dash help\" → --help); no trailing period after a command."
        }
        if chat.contains(where: id.hasPrefix) { return "It's a chat app: keep it natural and concise; use a list only for a genuine list of items." }
        if mail.contains(where: id.hasPrefix) { return "It's an email client: greeting and sign-off on their own lines if spoken, body in short paragraphs, lists where the speaker lists things." }
        return ""
    }

    // MARK: Prompt mode

    /// Terms developers say out loud that speech recognition tends to mangle.
    static let devTerms = [
        "useEffect", "useState", "React", "Next.js", "TypeScript", "JavaScript", "Tailwind", "Supabase", "Postgres",
        "SQLite", "Prisma", "Vercel", "Docker", "Kubernetes", "kubectl", "npm", "pnpm", "Bun", "Node.js", "FastAPI",
        "Django", "SwiftUI", "Xcode", "GitHub", "OAuth", "JWT", "Redis", "GraphQL", "Claude Code", "Codex", "Cursor",
        "Zed", "VS Code", ".env", "localhost", "async", "await", "refactor", "endpoint", "schema", "repo", "PR",
        "API", "JSON", "YAML", "CLI", "Vite", "shadcn", "GitHub CLI", "gh", "personal access token",
    ]

    /// Rewrites spoken instructions into a clean, structured prompt for an AI coding agent.
    func promptify(_ text: String, context: CursorContext?, vocabulary: [String]) async throws -> String {
        var system = """
        You clean up a developer's dictation before it's sent to an AI coding agent (Claude Code, Codex, Cursor). \
        You are a faithful editor, not the agent and not a rewriter: never answer, never solve, never add anything.

        Faithfulness comes first:
        - Keep exactly what the speaker meant, including the kind of utterance. A question stays a question, an \
        answer stays an answer, a complaint stays a complaint, feedback stays feedback. Never turn a question or a \
        reply into an instruction or a statement of need.
        - Keep who is who: "I"/"we" is the speaker, "you" is the agent. Never swap them.
        - Keep every fact, detail, name, number, step and preference. Drop nothing, invent nothing, add no steps or \
        labels the speaker didn't say.
        - Keep the speaker's own words and tone, including swearing. Never soften, censor or formalise them.

        Clean up:
        - Fix grammar and turn broken spoken phrasing into clear, natural written sentences (e.g. "you exactly what?" → \
        "What exactly do you mean?"; "then we scroll down, then we find X, when you click it we get Y" → a clean \
        sequence). Drop fillers, false starts, repetition, self-corrections \
        (keep the corrected version) and filler address words ("bro", "dude", "yaar").
        - Fix technical terms the speech recognizer misheard, using context ("GitHub cell"/"GitHub C L I" → GitHub \
        CLI, "GH" → gh, "super base" → Supabase, "use effect" → useEffect).
        - Wrap code identifiers, file names, paths, commands, flags, env vars and error messages in backticks.
        - Spoken UI navigation stays in order, e.g. "Settings → Developer settings → Personal access tokens", with \
        only the steps the speaker said.

        Structure only when it helps:
        - Conversation (questions, answers, replies, feedback, one or two requests) stays as plain sentences. No lists.
        - Three or more separate asks or requirements always become a list, even when spoken as one question: keep the \
        speaker's lead-in ("Can you:" / "I want to:") on its own line, then the items. The question form is kept by \
        the lead-in.
        - When the speaker specifies a task with several separate requirements, steps or constraints, state the goal \
        first, then list them after a blank line: numbered when order matters, "- " otherwise, one idea per item. \
        Background they gave stays as a normal sentence next to the goal.
        - No headings, no labels like "Context:", no bold, no emojis.

        If the speech is itself a shell command ("git status", "npm run dev"), output only the command.
        Output only the cleaned-up text.
        """
        if !vocabulary.isEmpty {
            system += "\nAlways spell these names and terms exactly like this: \(vocabulary.joined(separator: ", "))."
        }
        // Env override for comparing models from the CLI.
        let env = ProcessInfo.processInfo.environment
        func run(_ user: String) async throws -> String {
            let out = try await chat(system: system, examples: Self.promptExamples, user: user, maxTokens: max(300, text.count * 2),
                                     model: env["TLM_PROMPT_MODEL"] ?? Self.chatModel, reasoning: env["TLM_PROMPT_REASONING"],
                                     temperature: 0.05)
            return Self.dropAddressWords(Self.dropRedundantContext(Self.tidyLists(Self.sanitize(out, raw: text), bullet: "- ")))
        }
        var result = try await run(text)
        // Faithfulness check: if a real part of what was said went missing, retry once and name what was dropped.
        let missing = Self.missingWords(raw: text, out: result)
        if !missing.isEmpty {
            Log.write("prompt mode dropped \(missing.count) words; retrying")
            let retry = try await run(text + "\n\n(Your previous version dropped these words the speaker said: \(missing.joined(separator: ", ")). Keep everything the speaker said.)")
            if Self.missingWords(raw: text, out: retry).count < missing.count { result = retry }
        }
        return result
    }

    /// Content words of the dictation that don't appear in the output (ignoring fillers and small words).
    static func missingWords(raw: String, out: String) -> [String] {
        let ignore: Set<String> = ["bro", "dude", "yaar", "bhai", "like", "basically", "actually", "okay", "yeah", "just",
                                   "really", "some", "thing", "things", "there", "then", "when", "what", "that", "this", "with",
                                   "they", "them", "have", "will", "would", "could", "should", "about", "which", "where", "your",
                                   "from", "into", "over", "here", "also", "exactly", "know", "mean", "gonna", "wanna", "kind"]
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 3 && !ignore.contains($0) }
        }
        let have = Set(words(out))
        let said = Array(NSOrderedSet(array: words(raw))) as? [String] ?? []
        let gone = said.filter { w in !have.contains(w) && !have.contains { $0.hasPrefix(String(w.prefix(5))) } }
        // A few rephrasings are fine; a run of real content is not.
        return Double(gone.count) / Double(max(said.count, 1)) > 0.12 && gone.count >= 3 ? gone : []
    }

    /// Filler ways of addressing the listener ("bro", "dude"…) add nothing for an agent.
    static func dropAddressWords(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"(?i)(^|[.!?]\s+|\n)(bro|dude|yaar|bhai|man)\b[,!]?\s*"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i),\s*(bro|dude|yaar|bhai)\b(?=[,.!?])"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i),\s*(bro|dude|yaar|bhai),"#, with: ",", options: .regularExpression)
        // Re-capitalise sentence starts that lost their first word.
        let pattern = try! NSRegularExpression(pattern: #"(^|[.!?]\s+|\n)([a-z])"#)
        let ns = t as NSString
        var result = t
        for m in pattern.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
            let r = m.range(at: 2)
            result = (result as NSString).replacingCharacters(in: r, with: ns.substring(with: r).uppercased())
        }
        return result
    }

    /// Labels like "Context:" aren't wanted. A closing "Context:" paragraph that only repeats what the text
    /// already says is dropped; otherwise it's kept as a plain sentence without the label.
    static func dropRedundantContext(_ text: String) -> String {
        var blocks = text.components(separatedBy: "\n\n")
        guard blocks.count > 1, let last = blocks.last, last.lowercased().hasPrefix("context:") else { return text }
        let body = last.dropFirst("context:".count).trimmingCharacters(in: .whitespaces)
        let stop: Set<String> = ["context", "using", "with", "were", "that", "this", "from", "have", "into", "also", "stack", "built", "running"]
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".")).inverted)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                .filter { $0.count > 3 && !stop.contains($0) }
        }
        let earlier = Set(words(blocks.dropLast().joined(separator: " ")))
        let mine = words(body)
        let known = mine.filter { w in earlier.contains(w) || earlier.contains { $0.hasPrefix(w) || w.hasPrefix($0) } }
        if mine.isEmpty || Double(known.count) / Double(mine.count) >= 0.75 {
            blocks.removeLast()
        } else {
            blocks[blocks.count - 1] = body.prefix(1).uppercased() + body.dropFirst()
        }
        return blocks.joined(separator: "\n\n")
    }

    static let promptExamples: [(String, String)] = [
        ("can you uh check why the login button doesn't do anything", "Can you check why the login button doesn't do anything?"),
        ("wait bro what do you mean by the staging key, like the one in the vercel dashboard under environment variables or the one in our dot env file",
         "Wait, what do you mean by the staging key? The one in the Vercel dashboard under Environment Variables, or the one in our `.env` file?"),
        ("bro what api key, you mean which one exactly, like the one in stripe where we go to developers then api keys and then you reveal the secret key, you need that one or the publishable one",
         "What API key? Which one exactly do you mean? The one in Stripe, under Developers → API keys, where you reveal the secret key? Do you need that one, or the publishable one?"),
        ("no no don't use npm we use pnpm here, I already have it installed globally so just run pnpm install",
         "No, don't use npm. We use pnpm here, and I already have it installed globally, so just run `pnpm install`."),
        ("okay so um I want an export button on the invoices table we're on django with htmx so first add the button next to the filters then uh when you click it it should download a csv of whatever rows are currently filtered and include the tax column oh and don't export the internal notes field",
         "I want an export button on the invoices table. We're on Django with htmx.\n\n1. Add the button next to the filters.\n2. On click, download a CSV of the rows currently filtered, including the tax column.\n\n- Don't export the `internal_notes` field."),
        ("so the settings page is slow, I think it's the avatar images, can you lazy load them, cache the user query and uh also add a loading skeleton while it fetches",
         "The settings page is slow. I think it's the avatar images. Can you:\n\n1. Lazy-load the avatar images.\n2. Cache the user query.\n3. Add a loading skeleton while it fetches."),
        ("the build is failing with cannot find module at slash lib slash utils I think it's the path alias in the ts config can you fix it and then run the tests",
         "The build is failing with `Cannot find module '@/lib/utils'`. I think it's the path alias in `tsconfig.json`. Can you fix it and then run the tests?"),
        ("git status", "git status"),
    ]

    /// AI coding tools, where dictation is almost always a prompt for an agent.
    static func isAITool(_ c: CursorContext?) -> Bool {
        guard let c else { return false }
        let id = c.bundleID.lowercased()
        let tools = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp", "com.mitchellh.ghostty", "dev.zed", "com.todesktop.230313mzl4w4u92",
                     "com.microsoft.vscode", "com.exafunction.windsurf", "com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop",
                     "com.anthropic", "co.zeit.hyper", "net.kovidgoyal.kitty", "com.github.wez.wezterm"]
        if tools.contains(where: id.hasPrefix) { return true }
        let title = c.windowTitle.lowercased()
        return ["chatgpt", "claude", "gemini", "perplexity", "v0", "lovable", "bolt.new", "cursor"].contains { title.contains($0) }
    }

    /// Few-shot pairs: (raw dictation, formatted text).
    static let examples: [(String, String)] = [
        ("um so I was thinking we could uh meet tomorrow no actually thursday at like three", "I was thinking we could meet Thursday at 3."),
        ("can you send me the q3 report by end of day", "Can you send me the Q3 report by end of day?"),
        ("Sounds good, but we should wait till Monday?", "Sounds good, but we should wait till Monday."),
        ("okay so for the trip I need to pack my passport the laptop charger some snacks for the flight and the printed tickets",
         "For the trip I need to pack:\n\n- My passport\n- The laptop charger\n- Some snacks for the flight\n- The printed tickets"),
        ("to get it running first clone the repo then run npm install after that copy the env example file to dot env and finally start the dev server with npm run dev",
         "To get it running:\n\n1. Clone the repo\n2. Run npm install\n3. Copy the .env.example file to .env\n4. Start the dev server with npm run dev"),
        ("we need eggs milk and bread", "We need eggs, milk and bread."),
        ("hi priya thanks for sending the deck over I had a couple of thoughts the pricing slide feels crowded and we should add the q3 numbers to the summary also can we move the review to thursday thanks rahul",
         "Hi Priya,\n\nThanks for sending the deck over. I had a couple of thoughts:\n\n- The pricing slide feels crowded\n- We should add the Q3 numbers to the summary\n\nAlso, can we move the review to Thursday?\n\nThanks,\nRahul"),
        ("so the launch went pretty well we got around two thousand signups on day one which is way above target um on the other hand the onboarding flow is still confusing a lot of people dropped off at the permissions step so next week I want us to focus on fixing that before we spend anything on marketing",
         "The launch went pretty well. We got around 2,000 signups on day one, which is way above target.\n\nOn the other hand, the onboarding flow is still confusing. A lot of people dropped off at the permissions step.\n\nNext week I want us to focus on fixing that before we spend anything on marketing."),
        ("kal ke liye teen kaam hain client ko call karna invoice bhejna aur deck finalize karna",
         "Kal ke liye teen kaam hain:\n\n- Client ko call karna\n- Invoice bhejna\n- Deck finalize karna"),
        ("email me at john dot doe at gmail dot com it's about twenty percent off", "Email me at john.doe@gmail.com. It's about 20% off."),
    ]

    /// Guards against the model answering instead of formatting, or wrapping output in quotes.
    static func sanitize(_ out: String, raw: String) -> String {
        var t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("«", "»")] where t.hasPrefix(open) && t.hasSuffix(close) && t.count > 2 {
            t = String(t.dropFirst().dropLast())
        }
        let rawWords = raw.split(whereSeparator: \.isWhitespace).count
        let outWords = t.split(whereSeparator: \.isWhitespace).count
        let chatty = ["sure", "here is", "here's", "certainly", "i'm sorry", "as an ai"].contains { t.lowercased().hasPrefix($0) }
            && !["sure", "here", "certainly", "i'm sorry", "as an"].contains { raw.lowercased().hasPrefix($0) }
        if t.isEmpty || chatty || outWords > rawWords * 2 + 8 {
            Log.write("polish rejected (words \(rawWords)->\(outWords), chatty=\(chatty)); using local cleanup")
            return LocalFormatter.format(raw, context: nil, vocabulary: [])
        }
        return t
    }

    /// Command mode: apply a spoken instruction to selected text (or generate text when nothing is selected).
    func command(instruction: String, selection: String?) async throws -> String {
        let system = """
        You are a writing assistant embedded in the user's keyboard. Apply the user's spoken instruction. \
        If selected text is provided, transform it accordingly. If not, write the requested text. \
        Output ONLY the resulting text that should be inserted — no explanations, no quotes, no markdown fences.
        """
        let user = selection.map { "Instruction: \(instruction)\n\nSelected text:\n\($0)" } ?? "Instruction: \(instruction)"
        return try await chat(system: system, examples: [], user: user, maxTokens: 1500)
    }

    func chat(system: String, examples: [(String, String)], user: String, maxTokens: Int,
              model: String = SarvamClient.chatModel, reasoning: String? = nil, temperature: Double = 0.2) async throws -> String {
        let messages: [[String: Any]] = [["role": "system", "content": system]]
            + examples.flatMap { [["role": "user", "content": $0.0], ["role": "assistant", "content": $0.1]] }
            + [["role": "user", "content": user]]
        if formatter == .gemma, case let .local(kind, endpoint, localModel) = engine {
            return try await LocalLLM.chat(kind: kind, endpoint: endpoint, model: localModel, messages: messages,
                                           maxTokens: maxTokens, temperature: temperature)
        }
        if formatter != .sarvam {
            return try await CloudSpeech.chat(formatter, key: keys[formatter.rawValue] ?? "", messages: messages, maxTokens: maxTokens,
                                              temperature: temperature, model: model == Self.chatModel ? nil : model, reasoning: reasoning)
        }
        guard !apiKey.isEmpty else { throw SarvamError.missingKey }
        var req = URLRequest(url: URL(string: "https://api.sarvam.ai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "max_tokens": maxTokens + (reasoning == nil ? 0 : 1500),
            "messages": messages,
        ]
        if let reasoning { payload["reasoning_effort"] = reasoning }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let json = try await send(req)
        guard let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              var content = msg["content"] as? String else { throw SarvamError.empty }
        if let r = content.range(of: "</think>") { content = String(content[r.upperBound...]) }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw SarvamError.empty }
        return content
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await Self.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let err = (json["error"] as? [String: Any])?["message"] as? String
                ?? json["detail"] as? String
                ?? String(data: data, encoding: .utf8) ?? "request failed"
            throw SarvamError.http(code, String(err.prefix(160)))
        }
        return json
    }
}
