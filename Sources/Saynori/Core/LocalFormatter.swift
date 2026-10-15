import AppKit
import NaturalLanguage

/// Instant on-device formatting. Every step only removes, reorders or re-spells the speaker's own words, so it can
/// never answer, add or reinterpret anything. About a millisecond per dictation.
///
///  1. Spoken commands: "scratch that", "no wait / sorry I mean / or rather" corrections, "new line",
///     "new paragraph", "question mark", "full stop".
///  2. Fillers ("um", "uh", "mmm") and stutters ("I I", "the the"); repeats people mean are kept.
///  3. Terms: Dictionary words always, developer terms in coding/AI tools ("super base" → Supabase,
///     "dot env" → .env), plus fuzzy fixes for words that aren't English ("superbase", "paraket").
///  4. Web addresses and emails ("dietboy dot com", "name at gmail dot com").
///  5. Numbers ("fifty percent" → 50%, "three thirty pm" → 3:30 PM). See `SpokenNumbers`.
///  6. Lists: "first…, second…, third…" in one sentence or across sentences, and spoken series after a cue
///     ("make a list for my groceries? Apple, banana, pineapple").
///  7. "Bro"/"dude" dropped in AI tools; sentence case; tidy punctuation.
enum LocalFormatter {
    static func format(_ raw: String, context: CursorContext?, vocabulary: [String]) -> String {
        var t = Cleanup.dropNoise(raw)
        guard !t.isEmpty else { return t }
        let aiTool = SarvamClient.isAITool(context)
        let dev = isDevContext(context)

        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        // URLs, emails, paths, `code`, snake_case and calls() pass through untouched.
        var kept: [String]
        (t, kept) = Protect.mask(t)
        t = dropFillers(t)
        t = spokenLayout(t, kept: kept)
        t = scratchThat(t)
        t = applyCorrections(t)
        // A correction can bring a spoken command next to a new word ("it comma"): settle those too.
        t = spokenLayout(t, kept: kept)
        t = dropStutters(t)
        t = Terms.apply(t, vocabulary: vocabulary, devTerms: dev)
        t = Web.apply(t)
        // Identifiers first, so "five underscore zero ten" reads the same before and after joining.
        if dev { t = DevText.beforeNumbers(t) }
        t = Homophones.apply(t)
        t = SpokenNumbers.apply(t)
        t = DevText.apply(t, dev: dev)
        if dev { t = DevText.identifiers(t) }
        // Protect what was just written (paths, identifiers, URLs) so the steps below treat it the same on every pass.
        (t, kept) = Protect.mask(t, after: kept)
        t = tidy(t)
        t = Lists.apply(t)
        if aiTool {
            let without = dropAddressWords(t)
            if without.contains(where: { $0.isLetter || $0.isNumber }) { t = without }
        }
        if !t.contains(where: { $0.isLetter || $0.isNumber || Protect.isPlaceholder($0) }) { return Cleanup.dropNoise(Cleanup.local(raw)) }
        t = tidy(t)
        // Put protected spans back before capitalising, so "i.e." or an email next to a word reads the same every time.
        t = Protect.unmask(t, kept)
        t = capitalize(t, vocabulary: vocabulary, terminal: isTerminal(context))
        // Capitals made at sentence starts can complete a spelled-out run ("p I F" → "P I F"); settle it now.
        t = DevText.spelledLetters(t)
        return SarvamClient.tidyLists(t, bullet: SarvamClient.bullet(for: context))
    }

    // MARK: Spoken commands

    private static let scratchCue = try! NSRegularExpression(pattern:
        #"(?i)[,.;]?\s*\b(?:scratch,? that|scratched that|scratch this|strike that|delete that|scratched at(?!\s+(?:the|a|an|my|his|her|its|their|our|your|me|him|them|it|home|work|first|least)\b))\b[,.!;]?\s*"#)

    /// "…old sentence. Scratch that. New sentence" keeps only the new one.
    static func scratchThat(_ s: String) -> String {
        var t = s
        for _ in 0..<4 {
            let ns = t as NSString
            guard let m = scratchCue.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { break }
            let left = ns.substring(to: m.range.location)
            let right = ns.substring(from: m.range.location + m.range.length)
            var keep = ""
            if let r = left.range(of: #"^[\s\S]*(?:[.!?](?=\s)|\n)"#, options: .regularExpression) { keep = String(left[r]) }
            t = keep.isEmpty ? right : keep + (keep.hasSuffix("\n") ? "" : " ") + right
        }
        return t
    }

    private static let correctionCue = try! NSRegularExpression(pattern:
        #"(?i)(?:[,.;]\s*|\s+)\b(?:no,? wait|wait,? no|sorry,? i mean|i mean,? sorry|or rather)\b[,.?!]?\s+|,\s*(?:i meant(?! to\b)|make that)\s+(?=\w)"#)
    private static let joiners: Set<String> = ["and", "but", "so", "then", "because", "or", "at", "for", "with", "by", "on", "in",
                                               "to", "from", "if", "when"]

    /// Weaker cues that only count when the correction clearly mirrors what it replaces:
    /// "at five, sorry, at six" (same lead word), "on Monday, actually no, Tuesday" (one or two words, end of sentence).
    private static let anchoredCue = try! NSRegularExpression(pattern: #"(?i),\s*(sorry|no|actually no|actually|i mean)\s*,\s*(?=\w)"#)

    /// "meet Tuesday, no wait, Friday" → "meet Friday"; "send it to John, sorry I mean to Sarah" → "send it to Sarah".
    static func applyCorrections(_ s: String) -> String {
        var t = weakCorrections(s)
        var searchFrom = 0
        for _ in 0..<6 {
            let ns = t as NSString
            guard searchFrom < ns.length,
                  let m = correctionCue.firstMatch(in: t, range: NSRange(location: searchFrom, length: ns.length - searchFrom)) else { break }
            let left = ns.substring(to: m.range.location)
            let right = ns.substring(from: m.range.location + m.range.length)
            // The correction is the next few words, up to punctuation or a joining word ("Friday and loop in Priya" → "Friday").
            let fixEnd = right.firstIndex(where: { ",.!?;\n".contains($0) }) ?? right.endIndex
            let span = right[..<fixEnd].split(separator: " ").map(String.init)
            let cut = span.indices.dropFirst().first { joiners.contains(span[$0].lowercased()) } ?? span.count
            let fix = Array(span[..<cut])
            // Only replace inside the clause the correction belongs to.
            let clauseStart = left.lastIndex(where: { ",.!?;:\n".contains($0) }).map { left.index(after: $0) } ?? left.startIndex
            var clause = left[clauseStart...].split(separator: " ").map(String.init)
            guard !fix.isEmpty, !clause.isEmpty else { searchFrom = m.range.location + m.range.length; continue }
            // Anchor on the correction's first word if the clause has it ("to John … to Sarah"), else replace as many words.
            if let anchor = clause.lastIndex(where: { $0.lowercased() == fix[0].lowercased() }), clause.count - anchor <= fix.count + 2 {
                clause.removeSubrange(anchor...)
            } else {
                clause.removeLast(min(fix.count, clause.count))
            }
            let head = String(left[..<clauseStart])
            let rebuilt = (clause + span).joined(separator: " ")
            t = head + (head.isEmpty || head.hasSuffix(" ") || head.hasSuffix("\n") ? "" : " ") + rebuilt + right[fixEnd...]
            searchFrom = 0
        }
        return squeeze(t)
    }

    static func weakCorrections(_ s: String) -> String {
        var t = s
        var searchFrom = 0
        for _ in 0..<4 {
            let ns = t as NSString
            guard searchFrom < ns.length,
                  let m = anchoredCue.firstMatch(in: t, range: NSRange(location: searchFrom, length: ns.length - searchFrom)) else { break }
            let cue = ns.substring(with: m.range(at: 1)).lowercased()
            let left = ns.substring(to: m.range.location)
            let right = ns.substring(from: m.range.location + m.range.length)
            let fixEnd = right.firstIndex(where: { ",.!?;\n".contains($0) }) ?? right.endIndex
            let fix = right[..<fixEnd].split(separator: " ").map(String.init)
            let endsSentence = fixEnd == right.endIndex || ".!?\n".contains(right[fixEnd])
            let clauseStart = left.lastIndex(where: { ",.!?;:\n".contains($0) }).map { left.index(after: $0) } ?? left.startIndex
            var clause = left[clauseStart...].split(separator: " ").map(String.init)
            searchFrom = m.range.location + m.range.length
            guard !fix.isEmpty, clause.count >= 3 else { continue }
            let pronouns: Set<String> = ["i", "it", "we", "you", "they", "he", "she", "this", "that", "there"]
            if fix.count <= 3, !pronouns.contains(fix[0].lowercased()),
               let anchor = clause.lastIndex(where: { $0.lowercased() == fix[0].lowercased() }), clause.count - anchor <= fix.count + 1,
               anchor > 0 {
                clause.removeSubrange(anchor...)
            } else if cue == "actually no", fix.count <= 2, endsSentence {
                clause.removeLast(min(fix.count, clause.count - 1))
            } else { continue }
            let head = String(left[..<clauseStart])
            t = head + (head.isEmpty || head.hasSuffix(" ") ? "" : " ") + (clause + fix).joined(separator: " ") + right[fixEnd...]
            searchFrom = 0
        }
        return t
    }

    private static let layoutCue = try! NSRegularExpression(pattern:
        #"(?i)\b(new paragraph|new line|question mark|exclamation mark|exclamation point|full stop|comma)\b"#)
    /// Words around "new line" / "question mark" that mean the speaker is talking *about* it, not saying it.
    private static let literalBefore: Set<String> = ["a", "an", "the", "add", "adds", "print", "prints", "insert", "inserts", "every",
                                                     "each", "per", "with", "this", "that", "of", "no", "any", "remove", "trailing"]
    private static let literalAfter: Set<String> = ["character", "characters", "char", "chars", "symbol", "sign", "at", "in", "after",
                                                    "before", "between", "button", "icon", "key", "to", "on", "inside", "from"]

    /// "new paragraph" → blank line, "new line" → line break, "question mark" → "?", "full stop" → ".".
    static func spokenLayout(_ s: String, kept: [String] = []) -> String {
        // Quotes first, so a spoken "comma" inside one is handled the same as anywhere else.
        var t = quotes(s)
        let ns = t as NSString
        for m in layoutCue.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
            // The last word before the command (letters only: "/no", "two_the", "x=that" → no, the, that).
            // Skipping punctuation-only tokens (". comma" still follows "oh").
            let before = Protect.unmask(ns.substring(to: m.range.location), kept).split(whereSeparator: { $0 == " " || $0 == "\n" })
                .last(where: { $0.contains(where: { $0.isLetter || $0.isNumber }) })
                .map { String($0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).last ?? "") } ?? ""
            let after = Protect.unmask(ns.substring(from: m.range.location + m.range.length), kept)
            let next = after.split(whereSeparator: { $0 == " " || $0 == "\n" }).first
                .map { String($0.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).first ?? "") } ?? ""
            if literalBefore.contains(before.trimmingCharacters(in: .punctuationCharacters)) || literalAfter.contains(next) { continue }
            // Punctuation needs a word to follow; "comma" as the very first word is just a word.
            if before.isEmpty, !["new paragraph", "new line"].contains(ns.substring(with: m.range).lowercased()) { continue }
            // Swallow the punctuation and spaces the speech engine put around the command.
            var start = m.range.location, end = m.range.location + m.range.length
            let cur = t as NSString
            // (The speech engine often adds its own "?" or "." after a spoken command; that goes too.)
            while start > 0, " ,.".contains(Character(cur.substring(with: NSRange(location: start - 1, length: 1)))) {
                // Keep the dot that ends an abbreviation ("i.e.", "a.m.", "etc.").
                if cur.substring(with: NSRange(location: start - 1, length: 1)) == ".",
                   cur.substring(to: start - 1).range(of: #"(?i)(\b\w\.\w|\betc|\bvs|\bapprox|\bmr|\bdr|\bms|\bmrs)$"#, options: .regularExpression) != nil { break }
                start -= 1
            }
            while end < cur.length, " ,.?!".contains(Character(cur.substring(with: NSRange(location: end, length: 1)))) { end += 1 }
            let word = ns.substring(with: m.range).lowercased()
            let rep: String
            switch word {
            case "new paragraph": rep = "\n\n"
            case "new line": rep = "\n"
            case "question mark": rep = end < cur.length ? "? " : "?"
            case "full stop": rep = end < cur.length ? ". " : "."
            case "comma": rep = end < cur.length ? ", " : ","
            default: rep = end < cur.length ? "! " : "!"
            }
            t = cur.replacingCharacters(in: NSRange(location: start, length: end - start), with: rep)
        }
        return t
    }

    private static let quoteRun = try! NSRegularExpression(pattern:
        #"(?i)\b(?:open\s+)?quote,?\s+(.+?),?\s+(?:end|close|and|un)\s*quote\b[.,]?"#)
    /// "quote this is a test end quote" → "this is a test".
    static func quotes(_ s: String) -> String {
        guard s.range(of: #"(?i)\bquote\b"#, options: .regularExpression) != nil else { return s }
        return DevText.sub(quoteRun, s) { g in "\"" + g[1].trimmingCharacters(in: .whitespaces) + "\"" }
    }

    // MARK: Fillers and stutters

    static func dropFillers(_ s: String) -> String {
        var t = s
        // "um", "uh", "erm", "hmm", "mmm" anywhere, with the comma that usually follows them.
        t = t.replacingOccurrences(of: #"(?i)(^|[\s,])(u+m+|u+h+m*|e+r+m+|e+r+|a+h+|h+m+|m{3,}|mm(?=,)|m+h+m+)(?=[\s,.!?]|$),?"#, with: "$1", options: .regularExpression)
        // "you know" / "I mean" only when set off by commas (a real "I mean it" stays).
        t = t.replacingOccurrences(of: #"(?i),\s*(you know|i mean)\s*,\s*"#, with: " ", options: .regularExpression)
        return squeeze(t)
    }

    /// "and and", "the the", "I, I", "we are we are" → one. Repeated content words ("failing, failing") are kept.
    static func dropStutters(_ s: String) -> String {
        var t = s
        for re in [stutter1, stutter2] {
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                let word = ns.substring(with: m.range(at: 1))
                let lead = word.split(separator: " ").first.map { $0.lowercased() } ?? ""
                if !stutterWords.contains(lead) { continue }
                t = (t as NSString).replacingCharacters(in: m.range, with: word)
            }
        }
        return t
    }
    // Whole words only: the "I" in "I'm" is not a repeat of "I".
    // Same line only: a line break between two words was said on purpose.
    private static let stutter1 = try! NSRegularExpression(pattern: #"(?i)(?<![\w'])([a-z']+)(?:,?[ \t]+\1(?![\w']))+"#)
    private static let stutter2 = try! NSRegularExpression(pattern: #"(?i)(?<![\w'])([a-z']+[ \t]+[a-z']+)(?:[ \t]+\1(?![\w']))+"#)
    private static let stutterWords: Set<String> = ["i", "i'm", "we", "you", "he", "she", "it", "it's", "they", "the", "a", "an", "and",
                                                    "but", "or", "to", "of", "in", "on", "for", "with", "is", "are", "was", "were", "can",
                                                    "could", "will", "would", "should", "my", "our", "your", "if", "what", "how",
                                                    "when", "where", "why", "just", "like", "there", "there's", "then"]

    /// "Bro, …", "…, dude." — filler ways of addressing the listener, which mean nothing to an AI tool.
    static func dropAddressWords(_ s: String) -> String {
        var t = s
        // Repeat so "Bro, bro, I need…" loses both.
        for _ in 0..<3 {
            let before = t
            t = t.replacingOccurrences(of: #"(?i)(^|[.!?]\s+|\n)(bro|dude|yaar|bhai)\b[,!]?\s*"#, with: "$1", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(?i),\s*(bro|dude|yaar|bhai)\b(?=[,.!?])"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(?i),\s*(bro|dude|yaar|bhai),"#, with: ",", options: .regularExpression)
            if t == before { break }
        }
        return t
    }

    // MARK: Punctuation and case

    static func squeeze(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #" +([,.!?;:])(?![\w])"#, with: "$1", options: .regularExpression)
        return t
    }

    private static let endRun = try! NSRegularExpression(pattern: #"[.!?]*[!?][.!?]*\.[.!?]*|[.!?]*\.[.!?]*[!?][.!?]*|[!?]{2,}"#)

    static func tidy(_ s: String) -> String {
        var t = squeeze(s)
        t = t.replacingOccurrences(of: #"^(?:[\s,;:]|\.(?![\w]))+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n(?:[ \t,;]|\.(?![\w]))+"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #",\s*([.!?])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([,;])(?=[^\s\d"'”’)\]])"#, with: "$1 ", options: .regularExpression)
        t = t.replacingOccurrences(of: #",{2,}"#, with: ",", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<!\.)\.\.(?!\.)"#, with: ".", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([?!])\.(?=\s|$)"#, with: "$1", options: .regularExpression)
        // A run of mixed end marks becomes one: "?" wins over "!", which wins over "."; "...." becomes "...".
        do {
            let ns = t as NSString
            for m in endRun.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                let run = ns.substring(with: m.range)
                var mark = run.contains("?") ? "?" : run.contains("!") ? "!" : "."
                // "a.m. !" keeps the abbreviation's dot: "a.m.!".
                if run.hasPrefix("."), mark != ".", ns.substring(to: m.range.location).range(of: #"(?i)(\b\w\.\w|\betc|\bvs)$"#, options: .regularExpression) != nil { mark = "." + mark }
                t = (t as NSString).replacingCharacters(in: m.range, with: mark)
            }
        }
        t = t.replacingOccurrences(of: #"\.{4,}"#, with: "...", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[,;]\s*$"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let editors = ["com.apple.dt.xcode", "com.jetbrains", "com.sublimetext", "com.panic.nova", "com.google.android.studio",
                                  "com.microsoft.vscodeinsiders", "com.vscodium", "com.postmanlabs", "com.github.githubclient",
                                  "com.sublimemerge", "com.git-tower", "com.fournova"]
    /// Code editors, terminals and AI tools: where spoken notation ("dash dash port", "slash users") means code.
    static func isDevContext(_ c: CursorContext?) -> Bool {
        if SarvamClient.isAITool(c) { return true }
        guard let id = c?.bundleID.lowercased() else { return false }
        return editors.contains(where: id.hasPrefix)
    }

    private static let terminals = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
                                    "com.github.wez.wezterm", "co.zeit.hyper"]
    static func isTerminal(_ c: CursorContext?) -> Bool {
        guard let id = c?.bundleID.lowercased() else { return false }
        return terminals.contains(where: id.hasPrefix)
    }
    /// Commands typed at a shell prompt start lower-case: "git status", "python main.py", "docker compose up".
    private static let cliTools: Set<String> = ["git", "gh", "npm", "npx", "pnpm", "yarn", "bun", "node", "deno", "python", "python3", "pip",
        "pip3", "uv", "docker", "kubectl", "brew", "cd", "ls", "cat", "curl", "wget", "ssh", "scp", "make", "cargo", "go", "swift",
        "xcodebuild", "claude", "codex", "cursor", "code", "vim", "nvim", "nano", "rm", "mv", "cp", "mkdir", "touch", "grep", "find",
        "sudo", "open", "echo", "export", "source", "chmod", "chown", "tail", "head", "less", "ps", "kill", "pkill", "top", "htop",
        "flutter", "dart", "terraform", "aws", "gcloud", "firebase", "vercel", "supabase", "ollama", "ffmpeg", "tmux", "zsh", "bash"]

    /// Sentence starts, lines and list items start upper-case; a lone "i" is "I".
    static func capitalize(_ s: String, vocabulary: [String] = [], terminal: Bool = false) -> String {
        var t = s.replacingOccurrences(of: #"\bi\b(?=('m|'ve|'ll|'d|\s|[,!?]|\.(?![a-z])|$))"#, with: "I", options: .regularExpression)
        let re = try! NSRegularExpression(pattern: #"(^|[.!?]\s+|\n\s*(?:\d+\.\s+|[-•]\s+)?)([a-z])"#)
        let ns = t as NSString
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
            let r = m.range(at: 2)
            // Keep lower-case identifiers (npm, gh, useEffect, .env, example.com, a@b.com) as written.
            let word = (t as NSString).substring(from: r.location).prefix { $0.isLetter || $0.isNumber || "._@-/".contains($0) }
            if word.contains(where: { "._@/".contains($0) }) && word.dropLast().contains(where: { "._@/".contains($0) }) { continue }
            if (t as NSString).substring(from: r.location).prefix(while: { !$0.isWhitespace }).contains("_") { continue }
            let bare = String(word.prefix { $0.isLetter || $0.isNumber })
            if Terms.keepsLowercase(bare, vocabulary: vocabulary) { continue }
            if terminal, cliTools.contains(bare) { continue }
            // "i.e. this", "e.g. that", "vs. them" don't start a sentence.
            let before = (t as NSString).substring(to: r.location).trimmingCharacters(in: .whitespaces).lowercased()
            if ["i.e.", "e.g.", "etc.", "vs.", "approx.", "...", "a.m.", "p.m."].contains(where: { before.hasSuffix($0) }) { continue }
            t = (t as NSString).replacingCharacters(in: r, with: (t as NSString).substring(with: r).uppercased())
        }
        return t
    }
}

// MARK: - Lists

enum Lists {
    static func apply(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map { p in
            // Already a list (or the user's own line layout): leave it.
            if p.contains("\n") { return p }
            if let l = bulletList(p) { return l }
            if let l = sentenceList(p) { return l }
            if let l = inlineList(p) { return l }
            if let l = seriesList(p) { return l }
            return p
        }.joined(separator: "\n\n")
    }

    // MARK: Ordinal words

    private static let ordinalValue: [String: Int] = [
        "first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3, "fourth": 4, "fourthly": 4,
        "fifth": 5, "fifthly": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "finally": 99, "lastly": 99, "last": 99,
        "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9, "10": 10,
    ]
    /// "first year", "second time", "third party": the ordinal describes a noun instead of counting points.
    private static let adjectiveUse: Set<String> = ["year", "years", "time", "times", "half", "floor", "place", "day", "days", "week",
        "month", "semester", "sem", "class", "grade", "option", "party", "person", "hand", "round", "level", "page", "line", "row",
        "column", "tab", "screen", "version", "attempt", "try", "call", "phase", "batch", "slide", "half", "gen", "generation",
        "century", "quarter", "rank", "position", "prize", "draft", "edition", "season", "episode", "chapter", "grader", "graders",
        "year's", "years'", "hour", "minute", "row", "language", "name", "login", "impression", "date", "order", "degree", "cousin",
        "hand", "rate", "world", "base", "nature", "glance", "sight", "aid", "class", "and", "or", "to", "of", "than"]

    /// Sentence-level marker: "First, …", "Second one is …", "The third thing is …", "Number two, …", "Step three …",
    /// "Finally, …". Returns the number (99 = finally) and how much of the sentence the marker takes.
    private static let markerRegex = try! NSRegularExpression(pattern:
        #"(?i)^(?:(?:and|so|also|then|now|okay|ok|alright|the|my)\s+)*(?:(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|firstly|secondly|thirdly|fourthly|fifthly|finally|lastly|last)|(?:number|step|point|item)\s+(one|two|three|four|five|six|seven|eight|nine|ten|10|[1-9]))\b(?:\s+of\s+all)?(?:\s+but\s+not\s+least)?((?:\s+(?:one|thing|point|step|item|case|issue|problem|task|requirement|change|bug|feature|question|priority))?)(?:\s+(?:is|was|would be|will be|should be))?(?:\s*[,:\-–]\s*|\s+|(?=[.!?]?$))"#)

    private static func marker(_ sentence: String) -> (Int, Int)? {
        let ns = sentence as NSString
        guard let m = markerRegex.firstMatch(in: sentence, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let wordRange = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
        let word = ns.substring(with: wordRange).lowercased()
        guard let n = ordinalValue[word] else { return nil }
        if word == "last", m.range(at: 3).length == 0 { return nil }   // "last" needs "last one/thing"
        // The word right after the ordinal: "first year", "second time" aren't list markers.
        let after = ns.substring(from: wordRange.location + wordRange.length).trimmingCharacters(in: .whitespaces)
        let next = after.prefix { $0.isLetter || $0 == "'" }.lowercased()
        if adjectiveUse.contains(next), !after.lowercased().hasPrefix("of all") { return nil }
        return (n, m.range.location + m.range.length)
    }

    private struct Item { var text: String }

    private static let bulletMarker = try! NSRegularExpression(pattern:
        #"(?i)^(?:(?:and|then|next|also)\s+)?(?:bullet\s+points?|bullet|next\s+bullet)(?:\s+(?:one|two|three|four|five|six|seven|eight|nine|ten|\d{1,2}))?\b[,:.\-–]?\s*"#)

    /// "Bullet point one, fix the navbar. Bullet point two, fix the footer." → a bulleted list.
    static func bulletList(_ p: String) -> String? {
        let sentences = Prose.sentences(p)
        let marks: [Int?] = sentences.map { s in
            bulletMarker.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map { $0.range.length }
        }
        let idxs = marks.indices.filter { marks[$0] != nil }
        guard idxs.count >= 2 else { return nil }
        var items: [String] = []
        for (k, i) in idxs.enumerated() {
            var body = (sentences[i] as NSString).substring(from: marks[i]!)
            let next = k + 1 < idxs.count ? idxs[k + 1] : i + 1
            if next > i + 1 { body += " " + sentences[(i + 1)..<next].joined(separator: " ") }
            guard body.contains(where: \.isLetter) else { return nil }
            items.append("- " + Prose.itemText(body))
        }
        let tail = sentences[(idxs.last! + 1)...].joined(separator: " ")
        return Prose.assemble(lead: sentences[..<idxs[0]].joined(separator: " "), items: items, tail: tail)
    }

    /// Sentences that start with "First…", "Second…", "Third…" (or "Finally…") become a numbered list.
    static func sentenceList(_ p: String) -> String? {
        let sentences = Prose.sentences(p)
        guard sentences.count >= 3 else { return nil }
        let markers = sentences.map(marker)
        guard let start = markers.firstIndex(where: { $0?.0 == 1 }) else { return nil }
        var chain = [start]
        var expect = 2
        for i in (start + 1)..<sentences.count {
            guard let (n, _) = markers[i] else { continue }
            if n == expect { chain.append(i); expect += 1 }
            else if n == 99, expect >= 3 { chain.append(i); break }
            else if n == 1 { break }
        }
        guard chain.count >= 3 else { return nil }

        var leadSentences = Array(sentences[..<start])
        var items: [String] = []
        var lastUsed = chain.last!
        let labels: Set<String> = ["case", "thing", "point", "one", "item", "step", "issue", "problem", "task"]
        for (k, idx) in chain.enumerated() {
            let s = sentences[idx]
            var body = String((s as NSString).substring(from: markers[idx]!.1)).trimmingCharacters(in: .whitespaces)
            let words = body.trimmingCharacters(in: .punctuationCharacters).split(separator: " ")
            var from = idx + 1
            let next = k < chain.count - 1 ? chain[k + 1] : sentences.count
            if words.isEmpty, from < next, k > 0 || leadSentences.isEmpty {
                // "Step 3. Start the app." — the item is the sentence after the marker.
                body = sentences[from]; from += 1
                if k == chain.count - 1 { lastUsed = from - 1 }
            } else if k == 0, words.count <= 1, words.isEmpty || labels.contains(words[0].lowercased()) {
                // "A system that can hold millions of users. First case." — the marker labels the sentence before it.
                guard let previous = leadSentences.popLast() else { return nil }
                body = previous
            }
            if k < chain.count - 1, from < next {
                // Sentences between two markers belong to the earlier item.
                body += " " + sentences[from..<next].joined(separator: " ")
            }
            guard body.contains(where: \.isLetter) else { return nil }
            items.append(Prose.itemText(body))
        }
        let tail = sentences[(lastUsed + 1)...].joined(separator: " ")
        return Prose.assemble(lead: leadSentences.joined(separator: " "), items: items.enumerated().map { "\($0.offset + 1). \($0.element)" }, tail: tail)
    }

    private static let inlineRegex = try! NSRegularExpression(
        pattern: #"(?i)(^|[,.;:!?]\s*|\s(?:and|then|and then)\s+|\s)\b(firstly|first|secondly|second|thirdly|third|fourthly|fourth|fifth|sixth|finally|lastly)\b,?\s+"#)

    /// "To set it up, first clone the repo, second run npm install, and third start the server" → numbered list.
    static func inlineList(_ p: String) -> String? {
        let ns = p as NSString
        let matches = inlineRegex.matches(in: p, range: NSRange(location: 0, length: ns.length))
        var picked: [NSTextCheckingResult] = []
        var expect = 1
        for m in matches {
            let word = ns.substring(with: m.range(at: 2)).lowercased()
            let lead = ns.substring(with: m.range(at: 1))
            // Plain "first"/"second" must start a clause; "firstly", "finally" are markers anywhere.
            if lead.trimmingCharacters(in: .whitespaces).isEmpty, !lead.isEmpty, !word.hasSuffix("ly") { continue }
            let after = ns.substring(from: m.range.location + m.range.length).lowercased()
            let next = after.prefix { $0.isLetter || $0 == "'" }
            if adjectiveUse.contains(String(next)) || after.hasPrefix("of all") { continue }
            let n = ordinalValue[word] ?? 0
            if n == expect || (n == 99 && expect >= 3) { picked.append(m); expect = n == 99 ? 100 : expect + 1 }
        }
        let numbered = picked.filter { (ordinalValue[ns.substring(with: $0.range(at: 2)).lowercased()] ?? 0) != 99 }.count
        guard numbered >= 2, picked.count >= 3 else { return nil }

        let lead = ns.substring(to: picked[0].range.location + picked[0].range(at: 1).length)
        var items: [String] = []
        var tail = ""
        for (i, m) in picked.enumerated() {
            let start = m.range.location + m.range.length
            let end = i + 1 < picked.count ? picked[i + 1].range.location + picked[i + 1].range(at: 1).length : ns.length
            var item = ns.substring(with: NSRange(location: start, length: end - start))
            if i == picked.count - 1, let stop = item.range(of: #"[.!?]\s+"#, options: .regularExpression) {
                tail = String(item[stop.upperBound...])
                item = String(item[..<stop.lowerBound])
            }
            item = item.replacingOccurrences(of: #"(?i)[\s,]+(and|and then|then)\s*$"#, with: "", options: .regularExpression)
            item = item.replacingOccurrences(of: #"(?i)^(one|thing)\s+(is\s+)?"#, with: "", options: .regularExpression)
            // Each item is part of one sentence and a few words long; "second, third and fourth year" is not a list.
            guard item.split(separator: " ").count >= 1,
                  i == picked.count - 1 || item.range(of: #"[.!?]\s"#, options: .regularExpression) == nil else { return nil }
            items.append(Prose.itemText(item))
        }
        var leadText = lead.trimmingCharacters(in: CharacterSet(charactersIn: " ,;").union(.whitespacesAndNewlines))
        leadText = leadText.replacingOccurrences(of: #"(?i)[\s,]+(and|then|and then)$"#, with: "", options: .regularExpression)
        return Prose.assemble(lead: leadText, items: items.enumerated().map { "\($0.offset + 1). \($0.element)" }, tail: tail)
    }

    // MARK: Spoken series

    private static let cueRegex = try! NSRegularExpression(pattern:
        #"(?i)\b(lists?|groceries|grocery|shopping|to-?dos?|checklist|ingredients|agenda|bullet points?|bullets|the following|things to (?:buy|get|pack|do|bring)|packing|need to (?:buy|get|pack|bring))\b"#)
    private static let inlineCue = try! NSRegularExpression(pattern:
        #"(?i)^(.*?\b(?:list(?: is| are| of)?|the following(?: items| things)?(?: are| is)?|groceries(?: are)?|items(?: are)?|ingredients(?: are)?|to-?dos?(?: are)?|agenda(?: is)?|requirements(?: are)?|features(?: are)?|steps(?: are)?|here (?:are|is) (?:the |my |our |some |a few |all the )?[\w-]+(?: [\w-]+)?|(?:two|three|four|five|six|seven|eight|nine|ten|\d+) (?:things|items|steps|points|issues|bugs|changes|features|requirements|tasks|options|reasons|problems)))\s*[,:]?\s+(.+)$"#)

    /// "Can you make a list for my groceries? Apple, banana, pineapple" → bulleted list.
    /// "We need eggs, milk and bread." stays a sentence.
    static func seriesList(_ p: String) -> String? {
        let sentences = Prose.sentences(p)
        for (i, s) in sentences.enumerated() {
            let body = s.trimmingCharacters(in: CharacterSet(charactersIn: ".!?").union(.whitespaces))
            var lead: String? = nil
            var seriesText = body
            if let colon = body.firstIndex(of: ":"), body[body.index(after: colon)...].contains(",") {
                lead = String(body[...colon]); seriesText = String(body[body.index(after: colon)...])
            } else if let m = inlineCue.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)),
                      (body as NSString).substring(with: m.range(at: 2)).contains(",") {
                lead = (body as NSString).substring(with: m.range(at: 1))
                    .replacingOccurrences(of: #"(?i)\s+(is|are)$"#, with: "", options: .regularExpression) + ":"
                seriesText = (body as NSString).substring(with: m.range(at: 2))
            }
            guard let items = Prose.series(seriesText), items.count >= 3 else { continue }
            let previous = i > 0 ? sentences[i - 1] : ""
            // Only after a cue ("make a list…", "groceries:", "my to-do list is…"); "We need eggs, milk and bread" stays a sentence.
            let cued = lead != nil || cueRegex.firstMatch(in: previous, range: NSRange(location: 0, length: (previous as NSString).length)) != nil
            guard cued else { continue }
            // Items are short phrases ("password reset", "buy milk"); a clause like "I think we're done" isn't an item.
            guard items.allSatisfy({ $0.split(separator: " ").count <= 6 && !Prose.isClause($0) }) else { continue }
            var head = Array(sentences[..<i])
            if let lead { head.append(lead.trimmingCharacters(in: .whitespaces)) }
            var leadText = head.joined(separator: " ")
            if lead == nil, leadText.hasSuffix(".") { leadText = String(leadText.dropLast()) + ":" }
            let tail = sentences[(i + 1)...].joined(separator: " ")
            let rest = tail.isEmpty ? "" : (seriesList(tail) ?? tail)
            return Prose.assemble(lead: leadText, items: items.map { "- " + Prose.itemText($0) }, tail: rest)
        }
        return nil
    }
}

// MARK: - Text helpers

enum Prose {
    /// Splits a paragraph into sentences, keeping their end punctuation. "e.g.", "2.5" and "dietboy.com" don't end one.
    static func sentences(_ p: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(p)
        for (i, c) in chars.enumerated() {
            cur.append(c)
            guard ".!?".contains(c) else { continue }
            let next: Character = i + 1 < chars.count ? chars[i + 1] : " "
            guard next == " " || next == "\n" else { continue }
            let lower = " " + cur.lowercased()
            if [" e.g.", " i.e.", " etc.", " vs.", " mr.", " dr.", " ms.", " mrs."].contains(where: { lower.hasSuffix($0) }) { continue }
            out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
        }
        let rest = cur.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// "apple, banana and pineapple" → ["apple", "banana", "pineapple"]; nil if it isn't a series.
    static func series(_ s: String) -> [String]? {
        var parts = s.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, var last = parts.popLast() else { return nil }
        for joiner in [" and ", " or ", " & "] {
            if let r = last.range(of: joiner, options: [.caseInsensitive, .backwards]) {
                let a = String(last[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !a.isEmpty { parts.append(a) }
                last = String(last[r.upperBound...])
                break
            }
        }
        parts.append(last.trimmingCharacters(in: .whitespaces))
        parts = parts.map { $0.replacingOccurrences(of: #"(?i)^(and|or)\s+"#, with: "", options: .regularExpression) }
        guard parts.allSatisfy({ !$0.isEmpty && $0.contains(where: \.isLetter) }) else { return nil }
        return parts
    }

    static func itemText(_ s: String) -> String {
        var t = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,;").union(.whitespacesAndNewlines))
        if t.hasSuffix("."), !t.hasSuffix("..") { t.removeLast() }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    static func assemble(lead: String, items: [String], tail: String) -> String {
        var l = lead.trimmingCharacters(in: CharacterSet(charactersIn: " ,;").union(.whitespacesAndNewlines))
        // The lead-in introduces the list: "To set it up:", "We need three things:"; a question keeps its "?".
        if l.hasSuffix(".") { l = String(l.dropLast()) + ":" }
        else if let last = l.last, last.isLetter || last.isNumber || last == ")" { l += ":" }
        var out = l.isEmpty ? "" : l + "\n\n"
        out += items.joined(separator: "\n")
        let t = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out += "\n\n" + t }
        return out
    }

    private static let clauseWords: Set<String> = ["i", "we", "you", "they", "he", "she", "it", "this", "that", "there", "i'm", "we're",
        "you're", "they're", "it's", "that's", "there's", "is", "are", "was", "were", "will", "would", "can", "could", "should",
        "have", "has", "had", "do", "does", "did", "think", "guess", "am"]
    /// A piece with a subject or a finite verb ("I think we're done", "it is broken") rather than a list item.
    static func isClause(_ s: String) -> Bool {
        let words = s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard let first = words.first else { return false }
        if ["i", "we", "you", "they", "he", "she", "it", "this", "that", "there", "i'm", "we're", "you're", "they're", "it's", "that's", "there's", "so", "okay", "ok"].contains(first) { return true }
        return words.dropFirst().contains { clauseWords.contains($0) }
    }

    private static let tagger = NLTagger(tagSchemes: [.lexicalClass])
    static func startsWithVerb(_ s: String) -> Bool {
        tagger.string = s
        var first: NLTag?
        tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            first = tag; return false
        }
        return first == .verb
    }
    static func hasVerb(_ s: String) -> Bool {
        tagger.string = s
        var found = false
        tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if tag == .verb { found = true; return false }
            return true
        }
        return found
    }
}

// MARK: - Protected spans

/// Things that must come out exactly as they went in. Each is swapped for one private-use character while the
/// formatter runs (no step treats those as letters, words or punctuation), then put back.
enum Protect {
    private static let base: UInt32 = 0xF0000
    private static let pattern = try! NSRegularExpression(pattern:
        #"(?i)\b(?:https?|ftp)://[^\s]+|\bwww\.[\w-]+\.[\w-]+[^\s]*|[\w.+-]+@[\w-]+(?:\.[\w-]+)+|`[^`\n]+`|(?<![\w/.])(?:~|\.{1,2})?/[\w.\-/]+[\w/]|(?<![\w.,])[A-Za-z]\w*_\w+(?:\([^)\n]*\))?|\b[A-Za-z]\w*\([^)\n]*\)"#)

    static func mask(_ s: String, after existing: [String] = []) -> (String, [String]) {
        let ns = s as NSString
        let matches = pattern.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (s, existing) }
        var kept: [String] = existing
        var out = ""
        var cursor = 0
        for m in matches {
            var r = m.range
            // A sentence's own punctuation after a URL isn't part of it.
            while r.length > 1, ".,!?;:".contains(Character(ns.substring(with: NSRange(location: r.location + r.length - 1, length: 1)))) { r.length -= 1 }
            guard r.location >= cursor else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            out.unicodeScalars.append(UnicodeScalar(base + UInt32(kept.count))!)
            kept.append(ns.substring(with: r))
            cursor = r.location + r.length
        }
        out += ns.substring(from: cursor)
        return (out, kept)
    }

    static func unmask(_ s: String, _ kept: [String]) -> String {
        guard !kept.isEmpty else { return s }
        var out = ""
        for scalar in s.unicodeScalars {
            let i = Int(scalar.value) - Int(base)
            if i >= 0, i < kept.count { out += kept[i] } else { out.unicodeScalars.append(scalar) }
        }
        return out
    }

    static func isPlaceholder(_ c: Character) -> Bool {
        c.unicodeScalars.first.map { $0.value >= base && $0.value < base + 0x10000 } ?? false
    }
}

// MARK: - Web addresses

enum Web {
    private static let tld = "com|in|io|ai|org|net|dev|app|co|me|xyz|so|gg|tv|us|uk|edu|gov|world|tech|cloud|sh|ly|to|info|biz|site|online|store"
    private static let notAName: Set<String> = ["dot", "dots", "in", "to", "the", "a", "an", "from", "into", "on", "at", "and", "or", "of", "is",
                                                "i'm", "me", "we", "us", "them", "him", "her", "are", "was", "am", "be", "it", "that",
                                                "this", "there", "here", "look", "check", "live", "work", "mail", "email", "message", "with"]
    private static let domain = try! NSRegularExpression(pattern: #"(?i)\b([a-z0-9][a-z0-9-]*)[ \t]+dot[ \t]+((?:[a-z0-9-]+\.)*(?:"# + tld + #"))\b"#)
    private static let email = try! NSRegularExpression(pattern:
        #"(?i)\b([a-z0-9][a-z0-9._-]*(?:[ \t]+dot[ \t]+[a-z0-9_-]+)*)[ \t]+at[ \t]+((?:gmail|googlemail|yahoo|outlook|hotmail|icloud|proton|protonmail|rediffmail|zoho)\.[a-z.]+)\b"#)
    private static let atTheRate = try! NSRegularExpression(pattern: #"(?i)\b([a-z0-9][a-z0-9._-]*)[ \t]+at the rate(?: of)?[ \t]*([a-z0-9-]+(?:\.[a-z0-9-]+)+)\b"#)

    private static let spokenIP = try! NSRegularExpression(pattern:
        #"(?i)(?<![\d.])(\d{1,3})[ \t]+dot[ \t]+(\d{1,3})[ \t]+dot[ \t]+(\d{1,3})[ \t]+dot[ \t]+(\d{1,3})(?![\d.])"#)
    private static let spokenColon = try! NSRegularExpression(pattern:
        #"(?i)(?<![\w.:/-])((?:\d{1,3}\.){3}\d{1,3}|localhost|[a-z0-9_-]+(?:\.[a-z0-9_-]+)+|\d{1,2})[ \t]+colon[ \t]+(\d{1,2},\d{3}|\d{1,5})(?![\w.,]\d)"#)

    /// "192 dot 168 dot 0 dot 1" → 192.168.0.1; "192.168.0.136 colon 36161" → 192.168.0.136:36161,
    /// "localhost colon 3000" → localhost:3000, "main.swift colon 42" → main.swift:42, "3 colon 30" → 3:30.
    static func addresses(_ s: String) -> String {
        guard s.range(of: #"(?i)\b(colon|dot)\b"#, options: .regularExpression) != nil else { return s }
        var t = spokenIP.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1.$2.$3.$4")
        t = replace(spokenColon, in: t) { host, port in "\(host):\(port.replacingOccurrences(of: ",", with: ""))" }
        return t
    }

    /// "dietboy dot com" → dietboy.com, "api dot campus dot in" → api.campus.in, "john at gmail dot com" → john@gmail.com.
    static func apply(_ s: String) -> String {
        guard s.range(of: #"(?i)\b(dot|at)\b"#, options: .regularExpression) != nil else { return s }
        // Spoken ellipsis.
        var t = s.replacingOccurrences(of: #"(?i)[ \t]*\bdot[ \t]+dot[ \t]+dot\b"#, with: "...", options: .regularExpression)
        for _ in 0..<4 {
            let before = t
            t = replace(domain, in: t) { name, rest in notAName.contains(name.lowercased()) ? nil : "\(name).\(rest)" }
            if t == before { break }
        }
        t = replace(atTheRate, in: t) { name, host in notAName.contains(name.lowercased()) ? nil : "\(name)@\(host)".lowercased() }
        t = replace(email, in: t) { name, host in
            let first = name.split(separator: " ").first.map { $0.lowercased() } ?? ""
            guard !notAName.contains(first), host.contains(".") else { return nil }
            return (name.replacingOccurrences(of: #"(?i)[ \t]+dot[ \t]+"#, with: ".", options: .regularExpression) + "@" + host).lowercased()
        }
        return t
    }

    private static func replace(_ re: NSRegularExpression, in s: String, _ f: (String, String) -> String?) -> String {
        var t = s
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let rep = f(ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2))) else { continue }
            t = (t as NSString).replacingCharacters(in: m.range, with: rep)
        }
        return t
    }
}

// MARK: - Terms

/// Spells known terms the way they're written. Speech engines hear "use effect", "super base", "git hub", "dot env";
/// this turns them into useEffect, Supabase, GitHub, .env. Dictionary words always apply; developer terms only in
/// coding and AI tools. Words that aren't English and sound like a known term are fixed too ("superbase", "paraket").
enum Terms {
    /// Developer terms for formatting (a superset of what's sent to Sarvam as keyterms).
    static let dev: [String] = SarvamClient.devTerms + [
        "Python", "pip", "Rust", "Kotlin", "Flutter", "Firebase", "MongoDB", "MySQL", "PostgreSQL", "AWS", "GCP", "Azure",
        "Terraform", "Nginx", "Linux", "Ubuntu", "macOS", "iOS", "Android", "Homebrew", "curl", "sudo", "chmod", "grep", "regex",
        "webhook", "Stripe", "Twilio", "Jira", "Figma", "Netlify", "Cloudflare", "Drizzle", "tRPC", "Zod", "Redux", "Zustand",
        "Vue", "Svelte", "Angular", "Nuxt", "Webpack", "ESLint", "Prettier", "Vitest", "Playwright", "Cypress", "pytest",
        "Flask", "Laravel", "Kafka", "RabbitMQ", "Elasticsearch", "gRPC", "WebSocket", "TOML", "CSV", "SQL", "NoSQL", "LLM",
        "GPT", "ChatGPT", "OpenAI", "Anthropic", "Gemini", "Ollama", "Hugging Face", "PyTorch", "TensorFlow", "CUDA",
        "GitHub Actions", "GitLab", "Bitbucket", "yarn", "Deno", "React Native", "UIKit", "Core ML", "MLX", "Postman",
        "Windsurf", "Copilot", "MCP", "SDK", "UI", "UX", "URL", "HTTP", "HTTPS", "DNS", "SSL", "SSH", "SSO", "README",
        "navbar", "frontend", "backend", "BrowserStack", "Sentry", "Grafana", "Datadog", "Parakeet", "Whisper", "TestFlight",
        "App Store", "Play Store", "Xcode", "CocoaPods", "ffmpeg", "tsconfig",
    ]
    /// Extra ways people say (or engines hear) a term, beyond the automatic ones.
    private static let heard: [String: [String]] = [
        "Supabase": ["super base", "supa base", "soupa base", "super bass", "superbase", "super based", "soupabase", "superbass", "supabass"],
        "Postgres": ["post gres", "postgress", "post grace", "postgre", "post gray", "postgray", "post grey", "post-gres"],
        "PostgreSQL": ["postgre sql", "postgres sql", "post gres sql", "postgres q l"],
        "Vercel": ["versel", "vercell", "ver cell", "versal", "vercal", "vursel"],
        "Claude Code": ["cloud code", "clawed code", "claud code"],
        "kubectl": ["kube control", "cube ctl", "kube cuttle", "cube control", "kube c t l", "kobe control", "coupe control", "kubectl's"],
        "ffmpeg": ["f f m peg", "ff mpeg", "fempeg", "f f mpeg", "ef ef em peg", "ffmpg", "ff peg"],
        "Saynori": ["sanori", "say nori", "sai nori", "saynory", "sainori", "sayonari", "say no ri"],
        "shadcn": ["shad cn", "shad c n", "shadcn ui", "shad c and", "shad sea and"],
        "Next.js": ["nextjs", "next js", "next dot js", "next j s"],
        "Node.js": ["nodejs", "node js", "node dot js", "node j s"],
        "Xcode": ["x code", "ex code"],
        "useEffect": ["use effect", "use affect"],
        "useState": ["use state"],
        "OAuth": ["o auth", "oh auth"],
        "GitHub CLI": ["github cli", "git hub cli", "github c l i", "github cell", "git hub cell"],
        ".env": ["dot env", "dot e n v", "dotenv"],
        "localhost": ["local host"],
        "pnpm": ["p n p m", "pn pm"],
        "npm": ["n p m", "npim", "n pm", "en pm"],
        "gh": ["g h"],
        "SQLite": ["sequel lite", "sql lite", "s q lite", "sequel light"],
        "GraphQL": ["graph ql", "graph q l", "graph cue l"],
        "FastAPI": ["fast api", "fast a p i"],
        "TypeScript": ["type script"],
        "JavaScript": ["java script"],
        "Tailwind": ["tail wind"],
        "SwiftUI": ["swift ui", "swift u i"],
        "VS Code": ["vs code", "v s code", "vscode"],
        "GitHub": ["git hub", "github"],
        "MongoDB": ["mongo db", "mongo d b"],
        "MySQL": ["my sql", "my sequel", "my s q l"],
        "Firebase": ["fire base"],
        "GitLab": ["git lab"],
        "WebSocket": ["web socket", "web sockets"],
        "BrowserStack": ["browser stack"],
        "ESLint": ["es lint", "e s lint"],
        "tRPC": ["t r p c", "t rpc"],
        "ChatGPT": ["chat gpt", "chat g p t", "chatgpt"],
        "OpenAI": ["open ai", "open a i"],
        "Ollama": ["o llama", "olama"],
        "PyTorch": ["pie torch", "pi torch", "py torch"],
        "TensorFlow": ["tensor flow"],
        "Hugging Face": ["hugging fizz", "hugging phase", "hugging fees", "hugging face"],
        "Homebrew": ["home brew"],
        "navbar": ["nav bar", "nap bar", "nerve bar", "naw bar"],
        "frontend": ["front end", "front-end"],
        "backend": ["back end", "back-end"],
        "README": ["read me", "readme"],
        "Core ML": ["coreml", "core m l"],
        "macOS": ["mac os", "mac o s", "macos"],
        "iOS": ["i o s", "ios"],
        "TestFlight": ["test flight"],
        "CocoaPods": ["cocoa pods"],
        "API": ["a p i"], "CLI": ["c l i"], "JWT": ["j w t"], "JSON": ["j s o n", "j son"], "YAML": ["yamel"], "PR": ["p r"],
    ]
    /// Every word of every spoken variant (used by the test audit to recognise re-spelled terms).
    static var heardWords: Set<String> {
        var words = Set<String>()
        for variants in heard.values { for v in variants { for w in v.split(separator: " ") { words.insert(String(w)) } } }
        return words
    }
    /// Real English words that are also product names: never re-cased on their own.
    private static let ambiguous: Set<String> = ["react", "cursor", "bun", "codex", "redis", "vite", "zed", "prisma", "django",
        "async", "await", "refactor", "endpoint", "schema", "repo", "claude", "go", "swift", "rust", "dart", "expo", "jest", "helm",
        "flask", "notion", "cargo", "angular", "stripe", "sentry", "copilot", "gemini", "whisper", "parakeet", "drizzle", "linear",
        "windsurf", "postman", "deno", "vue", "kafka", "python", "docker", "linux", "android", "pip", "yarn", "curl", "grep", "sudo",
        "zod", "nuxt", "regex", "webhook", "navbar", "frontend", "backend", "kotlin", "flutter", "firebase", "netlify", "terraform"]

    private struct Rule { let regex: NSRegularExpression; let term: String; let firstWord: String }
    private static var cache: [String: [Rule]] = [:]
    private static let lock = NSLock()

    static func apply(_ text: String, vocabulary: [String], devTerms: Bool) -> String {
        var t = text
        if devTerms { t = dotEnv(t) }
        var present = wordSet(t)
        for rule in rules(vocabulary: vocabulary, devTerms: devTerms) {
            // Cheap pre-check before running the pattern: its first word must be in the text.
            guard present.contains(rule.firstWord) else { continue }
            var changed = false
            let ns = t as NSString
            for m in rule.regex.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                let found = ns.substring(with: m.range)
                if found == rule.term { continue }
                // A shell command ("python main.py", "docker compose up") keeps the tool's lower-case name.
                let after = ns.substring(from: m.range.location + m.range.length)
                if found.lowercased() == rule.term.lowercased(), after.range(of: #"^ [\w$-]*[./$-][\w/~]"#, options: .regularExpression) != nil { continue }
                t = (t as NSString).replacingCharacters(in: m.range, with: rule.term)
                changed = true
            }
            if changed { present = wordSet(t) }
        }
        return fuzzy(t, candidates: vocabulary + (devTerms ? dev : []))
    }

    private static func firstToken(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.prefix { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
    private static func wordSet(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    /// Speech engines hear "dot env" as "dot in" / "dot n" after "in/to/the/your…".
    private static func dotEnv(_ s: String) -> String {
        s.replacingOccurrences(of: #"(?i)\b(in|to|the|from|into|your|my|our|of|a|inside|and|with)\s+dot\s+(?:env|n|in|end|ian|ends|and|e n v)\b(?=\s*(?:file\b|[.,!?;]|$))"#,
                               with: "$1 .env", options: .regularExpression)
    }

    /// A product or developer term written with capitals (Supabase, GitHub, Saynori).
    static func isKnownTerm(_ word: String) -> Bool { knownTerms.contains(word) }
    private static let knownTerms: Set<String> = Set((dev + Array(heard.keys) + ["Saynori"]).filter { $0.first?.isUppercase == true })

    /// Lower-case identifiers that shouldn't be capitalised at a sentence start.
    static func keepsLowercase(_ word: String, vocabulary: [String]) -> Bool {
        if word.isEmpty { return false }
        if word.dropFirst().contains(where: \.isUppercase) { return true }   // useEffect, iPhone, macOS
        return (lowercaseTerms.contains(word) || vocabulary.contains(word)) && word.first?.isLowercase == true
    }
    private static let lowercaseTerms: Set<String> = Set((dev + Array(heard.keys)).filter { $0.first?.isLowercase == true }).subtracting(["async", "await", "refactor", "endpoint", "schema", "repo", "webhook", "regex", "navbar", "frontend", "backend", "yarn"])

    private static func rules(vocabulary: [String], devTerms: Bool) -> [Rule] {
        let key = "\(devTerms)|" + vocabulary.joined(separator: "\u{1}")
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        var pairs: [(String, String)] = []   // (spoken pattern, written term)
        let terms = vocabulary + ["Saynori"] + (devTerms ? dev + Array(heard.keys) : [])
        for term in Set(terms) where term.count > 1 {
            for v in variants(of: term, isVocabulary: vocabulary.contains(term)) { pairs.append((v, term)) }
        }
        // Longest first, so "GitHub CLI" wins over "GitHub".
        pairs.sort { $0.0.count > $1.0.count }
        let built = pairs.compactMap { spoken, term -> Rule? in
            let words = spoken.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let body = words.joined(separator: #"[\s-]+"#)
            guard let re = try? NSRegularExpression(pattern: #"(?i)(?<![\w.@/-])"# + body + #"(?![\w@]|\.\w)"#) else { return nil }
            return Rule(regex: re, term: term, firstWord: wordSet(spoken).isEmpty ? "" : firstToken(spoken))
        }
        if cache.count > 16 { cache.removeAll() }
        cache[key] = built
        return built
    }

    /// Spoken forms of a term: split at case changes and dots, spaced-out acronyms, plus the `heard` list.
    static func variants(of term: String, isVocabulary: Bool = false) -> [String] {
        var out = Set(heard[term] ?? [])
        let lower = term.lowercased()
        let hasShape = term != lower || term.contains(".") || term.contains(" ")
        // Re-case the plain lower-case spelling ("github" → GitHub), except for real English words ("react").
        if hasShape, isVocabulary || !ambiguous.contains(lower) { out.insert(lower) }
        // useEffect → use effect, TypeScript → type script, SwiftUI → swift ui
        let split = term.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Z]+)([A-Z][a-z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: ".", with: " ").lowercased().trimmingCharacters(in: .whitespaces)
        if split != lower, split.contains(" "), !ambiguousSplit.contains(split) { out.insert(split) }
        // API → a p i
        if term.count <= 5, term == term.uppercased(), term.allSatisfy(\.isLetter) {
            out.insert(term.lowercased().map(String.init).joined(separator: " "))
        }
        return out.filter { !$0.isEmpty && $0 != term }
    }
    /// Splits that are ordinary phrases ("i os" is fine, but "use state" in prose should stay? no: only these).
    private static let ambiguousSplit: Set<String> = ["mac os", "web hook", "read me", "core ml", "test flight", "play store", "app store"]

    // MARK: Fuzzy

    private struct Candidate { let term: String; let lower: String; let key: String }
    private static var candidateCache: (String, [Candidate]) = ("", [])

    /// Fixes a word that isn't English but sounds like a known term ("superbase" → Supabase, "paraket" → Parakeet).
    static func fuzzy(_ text: String, candidates terms: [String]) -> String {
        let cands = candidates(terms)
        guard !cands.isEmpty else { return text }
        var t = text
        let ns = text as NSString
        let words = try! NSRegularExpression(pattern: #"(?<![\w.@/-])[A-Za-z][a-z']{3,}(?![\w@]|\.\w)"#)
        for m in words.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let w = ns.substring(with: m.range)
            let lw = w.lowercased()
            if cands.contains(where: { $0.lower == lw }) { continue }
            let key = skeleton(lw)
            guard let best = cands.first(where: { c in
                abs(c.lower.count - lw.count) <= 2 && c.key.first == key.first
                    && distance(c.key, key) <= (c.key.count >= 4 ? 1 : 0)
                    && distance(c.lower, lw) <= max(1, c.lower.count / 4)
            }) else { continue }
            guard !isEnglish(lw) else { continue }
            t = (t as NSString).replacingCharacters(in: m.range, with: best.term)
        }
        return t
    }

    private static func candidates(_ terms: [String]) -> [Candidate] {
        let id = terms.joined(separator: "\u{1}")
        lock.lock(); defer { lock.unlock() }
        if candidateCache.0 == id { return candidateCache.1 }
        let list = Set(terms).filter { $0.count >= 5 && $0.allSatisfy(\.isLetter) && $0 != $0.uppercased() }
            .map { Candidate(term: $0, lower: $0.lowercased(), key: skeleton($0.lowercased())) }
        candidateCache = (id, list)
        return list
    }

    /// Rough sound-alike key: consonants only, similar sounds merged ("superbase" → "sprbs", "supabase" → "spbs").
    static func skeleton(_ w: String) -> String {
        var s = w
        for (a, b) in [("ph", "f"), ("ck", "k"), ("qu", "kw"), ("x", "ks"), ("c", "k"), ("q", "k"), ("z", "s"), ("v", "w"), ("y", "i")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0, "aeiouh'".contains(ch) { continue }
            if out.last == ch { continue }
            out.append(ch)
        }
        return out
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Whether macOS's spell checker knows the word (including words the user taught it).
    static func isEnglish(_ w: String) -> Bool {
        let check = { NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                                                          inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound }
        if Thread.isMainThread { return check() }
        return DispatchQueue.main.sync(execute: check)
    }
}
