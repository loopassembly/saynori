import Foundation
import NaturalLanguage

/// Spoken technical notation, written the way it's typed:
///   "192 dot 168 dot zero dot 1 colon 8080" → 192.168.0.1:8080     "main dot swift colon 42" → main.swift:42
///   "slash users slash me" → /users/me                              "tilde slash dot zshrc" → ~/.zshrc
///   "https colon slash slash github dot com slash x" → https://github.com/x
///   "dash dash port" → --port      "commit dash m" → commit -m       "user underscore id" → user_id
///   "a equals equals b" → a == b   "NODE_ENV equals production" → NODE_ENV=production
///   "command shift p" → Cmd+Shift+P   "hash F F 5733" → #FF5733   "plus 91 98765 43210" → +919876543210
/// Notation that could be ordinary speech (paths, flags, identifiers, operators) only applies in code editors,
/// terminals and AI tools; unambiguous forms (IPs, ports, URLs, file names, colours) apply everywhere.
enum DevText {
    /// Notation built from words (names, URLs, paths), done before numbers are written so a number next to
    /// them reads the same on every pass.
    static func beforeNumbers(_ s: String) -> String {
        var t = identifiers(s)
        t = fileNames(t, dev: true)
        t = urls(t)
        t = paths(t)
        return t
    }

    static func apply(_ s: String, dev: Bool) -> String {
        var t = s
        t = spelledLetters(t)
        t = fileNames(t, dev: dev)
        t = ipAddresses(t)
        t = phoneNumbers(t)
        t = urls(t)
        t = hexColors(t)
        t = shortcuts(t)
        if dev {
            t = localhost(t)
            t = paths(t)
            t = flags(t)
            t = operators(t)
            t = sshTargets(t)
        }
        t = ports(t)
        t = versions(t)
        return t
    }

    // MARK: Helpers

    /// Replaces every match (back to front) with `f(groups)`; `nil` keeps the match as it was.
    static func sub(_ re: NSRegularExpression, _ s: String, _ f: ([String]) -> String?) -> String {
        let ns = s as NSString
        var out = s
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            var g: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                g.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            if let rep = f(g) { out = (out as NSString).replacingCharacters(in: m.range, with: rep) }
        }
        return out
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    private static let digitWords: [String: String] = ["zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4",
                                                       "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9"]
    private static let digitWord = "(?:zero|oh|one|two|three|four|five|six|seven|eight|nine)"

    /// "one six eight" / "168" / "zero" → "168" / "168" / "0".
    private static func digits(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "-" }).map { digitWords[$0.lowercased()] ?? String($0) }.joined()
    }

    // MARK: Letters and file names

    /// Spelled-out capitals: "S O R U Q" → SORUQ.
    private static let spelled = re(#"(?<![\w'])(?:[A-Z][ \t]+){2,}[A-Z](?![\w'])"#)
    static func spelledLetters(_ s: String) -> String {
        sub(spelled, s) { g in g[0].replacingOccurrences(of: " ", with: "") }
    }

    private static let extensions = "js|ts|tsx|jsx|mjs|cjs|json|jsonc|yaml|yml|toml|md|mdx|txt|csv|tsv|xml|html|htm|css|scss|sass|less|py|rb|rs|java|kt|kts|swift|mm|hpp|cpp|cc|cs|php|bash|zsh|ps1|sql|dart|vue|svelte|astro|lua|ex|exs|hs|scala|ini|cfg|conf|lock|log|plist|gradle|tf|tfvars|proto|graphql|gql|png|jpg|jpeg|gif|svg|webp|ico|pdf|docx|xlsx|pptx|zip|tar|gz|dmg|ipa|apk|mp3|mp4|mov|wav|xcodeproj|xcworkspace|storyboard|xib|entitlements|pbxproj|ipynb|env|go"
    private static let extensionSet = Set(extensions.split(separator: "|").map(String.init)).subtracting(["sh", "in", "co", "io", "ai", "app", "dev", "me"])
    private static let fileName = re(#"(?i)(?<![\w.@/-])([\w-]+(?:\.[\w-]+)*)[ \t]+dot[ \t]+("# + extensions + #")\b"#)
    private static let fileNameDev = re(#"(?<![\w.@/-])([\w-]+(?:\.[\w-]+)*)[ \t]+dot[ \t]+([chmr])\b"#)
    private static let dotFile = re(#"(?i)(?<![\w.])dot[ \t]+(zshrc|bashrc|bash_profile|zprofile|gitignore|gitattributes|gitmodules|npmrc|nvmrc|prettierrc|eslintrc|editorconfig|dockerignore|github|vscode|ssh|swiftlint\.yml|env\.local|env\.example)\b"#)
    private static let jsonHeard = re(#"(?i)\.(?:jun|jason|jayson|jsun|jsan)\b"#)
    private static let envHeard = re(#"(?i)\b(the|a|your|my|our|in|to)\.(?:n|in|end|env)\b"#)

    private static let notAFile: Set<String> = ["the", "a", "an", "in", "to", "my", "your", "our", "this", "that", "it", "is", "of",
                                                "and", "or", "three", "two", "one", "four", "five", "with", "from", "into", "on", "at"]
    /// "main dot swift" → main.swift, "package dot json" → package.json; in code tools also "dot zshrc" → .zshrc.
    static func fileNames(_ s: String, dev: Bool) -> String {
        var t = s
        for _ in 0..<3 {
            let before = t
            t = sub(fileName, t) { g in notAFile.contains(g[1].lowercased()) ? nil : "\(g[1]).\(g[2].lowercased())" }
            if dev { t = sub(fileNameDev, t) { g in notAFile.contains(g[1].lowercased()) ? nil : "\(g[1]).\(g[2])" } }
            if t == before { break }
        }
        if dev {
            t = sub(dotFile, t) { g in ".\(g[1].lowercased())" }
            t = sub(jsonHeard, t) { _ in ".json" }
            t = sub(envHeard, t) { g in "\(g[1]) .env" }
        }
        return t
    }

    // MARK: Addresses

    private static let octet = #"(\d{1,3}|"# + digitWord + #"(?:[\s-]+"# + digitWord + #"){0,2})"#
    private static let ip = re(#"(?i)(?<![\w.])"# + octet + #"[ \t]+dot[ \t]+"# + octet + #"[ \t]+dot[ \t]+"# + octet + #"[ \t]+dot[ \t]+"# + octet + #"(?![\w]|\.\d)"#)

    /// "192 dot 168 dot zero dot one" → 192.168.0.1 (each part 0–255).
    static func ipAddresses(_ s: String) -> String {
        guard s.range(of: #"(?i)\bdot\b"#, options: .regularExpression) != nil else { return s }
        return sub(ip, s) { g in
            let parts = g[1...4].map(digits)
            guard parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return nil }
            return parts.joined(separator: ".")
        }
    }

    private static let localhostHeard = re(#"(?i)\blocal[ \t]*(?:host|only|holes?|lost|post)[ \t]+(colon[ \t]+)"#)
    private static let localhostBare = re(#"(?i)\blocalhost[ \t]+(\d{2,5})\b(?![.,]\d)"#)
    /// "localhost 3000" → localhost:3000, and "local only colon 2560" (misheard) → localhost colon 2560.
    static func localhost(_ s: String) -> String {
        var t = sub(localhostHeard, s) { g in "localhost \(g[1])" }
        t = sub(localhostBare, t) { g in "localhost:\(g[1])" }
        return t
    }

    private static let port = re(#"(?i)(?<![\w.:/-])((?:\d{1,3}\.){3}\d{1,3}|localhost|[a-z0-9_-]+(?:\.[a-z0-9_-]+)+|\d{1,2})[ \t]+colon[ \t]+(\d{1,2},\d{3}|\d{1,5})(?![\w.,]\d)"#)
    /// "192.168.0.136 colon 36161" → 192.168.0.136:36161, "main.swift colon 42" → main.swift:42, "3 colon 30" → 3:30.
    static func ports(_ s: String) -> String {
        guard s.range(of: #"(?i)\bcolon\b"#, options: .regularExpression) != nil else { return s }
        return sub(port, s) { g in "\(g[1]):\(g[2].replacingOccurrences(of: ",", with: ""))" }
    }

    private static let scheme = re(#"(?i)\b(https?|ftp|ssh|wss?)[ \t]+colon[ \t]+slash[ \t]+slash[ \t]+"#)
    private static let urlSegments = re(#"(?i)((?:https?|ftp|ssh|wss?)://\S+?)[ \t]+slash[ \t]+((?:[\w.-]+[ \t]+){0,2}?[\w.-]+)(?=[ \t]+slash\b)"#)
    private static let urlLast = re(#"(?i)((?:https?|ftp|ssh|wss?)://\S+?)[ \t]+slash[ \t]+([\w.-]+)"#)
    /// "https colon slash slash github.com slash loop assembly slash saynori" → https://github.com/loopassembly/saynori.
    static func urls(_ s: String) -> String {
        guard s.range(of: #"(?i)\bcolon[ \t]+slash"#, options: .regularExpression) != nil else { return s }
        var t = sub(scheme, s) { g in "\(g[1].lowercased())://" }
        for _ in 0..<8 {
            let before = t
            t = sub(urlSegments, t) { g in "\(g[1])/\(g[2].replacingOccurrences(of: " ", with: ""))" }
            if t == before { break }
        }
        for _ in 0..<8 {
            let before = t
            t = sub(urlLast, t) { g in "\(g[1])/\(g[2])" }
            if t == before { break }
        }
        // The host part is case-insensitive; write it lower-case.
        return sub(re(#"(?i)\b((?:https?|ftp|ssh|wss?)://)([^/\s]+)"#), t) { g in g[1] + g[2].lowercased() }
    }

    private static let ssh = re(#"(?i)\b([a-z][a-z0-9_-]*)[ \t]+at[ \t]+((?:\d{1,3}\.){3}\d{1,3}|localhost|[a-z0-9-]+(?:\.[a-z0-9-]{2,})+)\b"#)
    /// In an ssh/scp command: "root at 192.168.1.1" → root@192.168.1.1.
    static func sshTargets(_ s: String) -> String {
        guard s.range(of: #"(?i)\b(ssh|scp|sftp|rsync)\b"#, options: .regularExpression) != nil else { return s }
        return sub(ssh, s) { g in
            let user = g[1].lowercased(), host = g[2].lowercased()
            if ["into", "in", "on", "logged", "is", "are", "it", "me", "us"].contains(user) || digitWords[user] != nil
                || ["ten", "eleven", "twelve", "twenty", "thirty", "hundred", "thousand"].contains(user) { return nil }
            // A file (main.swift) isn't a host.
            if let ext = host.split(separator: ".").last, host.contains("."), !host.allSatisfy({ $0.isNumber || $0 == "." }),
               extensionSet.contains(String(ext)) { return nil }
            return "\(g[1])@\(g[2])"
        }
    }

    // MARK: Paths and flags

    /// Words that lead into a path rather than being its first folder: "go to slash users" → "go to /users".
    private static let notAFolder: Set<String> = ["to", "in", "at", "the", "a", "an", "into", "from", "on", "under", "inside", "of",
        "open", "go", "cd", "check", "see", "edit", "run", "use", "is", "are", "file", "folder", "path", "directory", "dir",
        "and", "or", "type", "called", "named", "with", "then", "now", "it", "this", "that", "my", "our", "your", "save", "put",
        "move", "copy", "create", "add", "delete", "remove", "show", "list", "ls", "cat", "under", "within", "via", "for"]
    private static let notAPathSegment: Set<String> = ["the", "a", "an", "this", "that", "it", "them", "my", "our", "your", "their",
        "his", "her", "prices", "price", "costs", "cost", "budget", "command", "commands", "and", "or", "to", "of", "in", "on", "is", "slash"]
    private static let pathRun = re(#"(?i)(?<![\w/~.-])(?:(~|[\w][\w.-]*)[ \t]+)?slash[ \t]+\.?[\w~-](?:[\w.~-]*[\w~-])?(?:[ \t]+slash[ \t]+\.?[\w~-](?:[\w.~-]*[\w~-])?)*"#)
    private static let tilde = re(#"(?i)\btilde[ \t]+slash\b"#)

    /// "slash users slash me slash desktop" → /users/me/desktop, "src slash components" → src/components,
    /// "tilde slash .zshrc" → ~/.zshrc, "the slash compact command" → the /compact command.
    static func paths(_ s: String) -> String {
        guard s.range(of: #"(?i)\bslash\b"#, options: .regularExpression) != nil else { return s }
        var t = s.replacingOccurrences(of: #"(?i)\band[ \t]+slash[ \t]+or\b"#, with: "and/or", options: .regularExpression)
        t = sub(tilde, t) { _ in "~ slash" }
        return sub(pathRun, t) { g in
            // "slash the budget" is a verb, "slash command" the concept: neither is a path.
            let segments = g[0].lowercased().components(separatedBy: "slash").dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if segments.contains(where: { notAPathSegment.contains($0) }) { return nil }
            var lead = g[1]
            var body = String(g[0].dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
            var prefix = ""
            if !lead.isEmpty, notAFolder.contains(lead.lowercased()) { prefix = lead + " "; lead = "" }
            body = body.replacingOccurrences(of: #"(?i)^slash[ \t]+"#, with: "/", options: .regularExpression)
            body = body.replacingOccurrences(of: #"(?i)[ \t]+slash[ \t]+"#, with: "/", options: .regularExpression)
            if lead == "~" { return prefix + "~" + body }
            return prefix + lead + body
        }
    }

    private static let longFlag = re(#"(?i)(?<![\w-])(?:dash[ \t]+dash|double[ \t]+dash)[ \t]+([a-z][\w-]*)"#)
    private static let shortFlag = re(#"(?i)(?<![\w-])(?:dash|minus)[ \t]+([a-z])\b(?!\.\w|['’])"#)
    private static let clusterFlag = re(#"(?i)\b(ls|rm|cp|mv|tar|ps|chmod|chown|grep|du|df|mkdir|kill|unzip|zip|curl|ssh|scp|rsync|top|tail|head|wc|sort|uniq|git[ \t]+\w+)[ \t]+(?:dash|minus)[ \t]+([a-z]{2,4})\b"#)
    private static let gluedFlag = re(#"\b([a-z]{3,})-([a-z])\b(?=[ \t]+[\w./~-])"#)
    private static let commitMessage = re(#"(?i)\b(git[ \t]+commit(?:[ \t]+-a)?[ \t]+-m)[ \t]+(?!["'])([^.!?\n]+?)([.!?]?)(?=[ \t]*$|\n|[.!?]\s)"#)
    private static let flagValue = re(#"(--?[\w-]+)(=|[ \t]+)(\d{1,2},\d{3})\b"#)

    /// "dash dash port" → --port, "commit dash m" → commit -m, "ls dash la" → ls -la, "apply-f file" → apply -f file.
    static func flags(_ s: String) -> String {
        var t = s
        if t.range(of: #"(?i)\b(dash|minus)\b"#, options: .regularExpression) != nil {
            t = sub(longFlag, t) { g in "--\(g[1].lowercased())" }
            t = sub(clusterFlag, t) { g in "\(g[1]) -\(g[2].lowercased())" }
            t = sub(shortFlag, t) { g in "-\(g[1])" }
        }
        t = sub(gluedFlag, t) { g in "\(g[1]) -\(g[2])" }
        // "git commit -m fix the login bug" → git commit -m "fix the login bug"
        t = sub(commitMessage, t) { g in "\(g[1]) \"\(g[2])\"\(g[3])" }
        t = sub(re(#"(?i)\b(npm|pnpm|yarn|bun)[ \t]+rundev\b"#), t) { g in "\(g[1]) run dev" }
        // Numbers after a flag are values, not quantities: "--port 4,000" → "--port 4000".
        t = sub(flagValue, t) { g in g[1] + g[2] + g[3].replacingOccurrences(of: ",", with: "") }
        return t
    }

    // MARK: Identifiers and operators

    private static let notAnIdentifierPart: Set<String> = ["the", "a", "an", "this", "that", "use", "is", "are", "of", "with", "to",
        "in", "on", "for", "by", "or", "character", "characters", "key", "sign", "symbol", "prefix", "suffix", "separator", "instead",
        "an", "add", "type", "put", "single", "double", "leading", "trailing"]
    private static let underscore = re(#"(?i)(?<![\w])((?:underscore[ \t]+)*[A-Za-z0-9]+(?:[ \t]+underscore[ \t]+(?:underscore[ \t]+)*[A-Za-z0-9]+)+(?:[ \t]+underscore)*)(?![\w])"#)
    private static let caseCommand = re(#"(?i)\b(camel|snake|kebab|pascal|screaming snake|constant)[ \t]+case[ \t]+((?:[A-Za-z0-9]+[ \t]*){1,4}?)(?=[,.!?;:](?![\w])|$|[ \t]+(?:please|and|then|to|in|for|with|as|instead|variable|function|field|column)\b)"#)

    /// "user underscore id" → user_id, "API underscore key" → API_KEY, "camel case user id" → userId.
    static func identifiers(_ s: String) -> String {
        var t = s
        if t.range(of: #"(?i)\bunderscore\b"#, options: .regularExpression) != nil {
            // Speech engines hear "underscore env" as "underscore and".
            t = t.replacingOccurrences(of: #"(?i)\bunderscore[ \t]+and\b(?=[ \t]+(?:equals|is|=|to)\b|[.,]|$)"#, with: "underscore env", options: .regularExpression)
            t = sub(underscore, t) { g in
                // "the underscore character" talks about the symbol.
                let parts = g[1].lowercased().components(separatedBy: "underscore").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if let first = parts.first, notAnIdentifierPart.contains(first) { return nil }
                let id = g[1].replacingOccurrences(of: #"(?i)[ \t]*\bunderscore\b[ \t]*"#, with: "_", options: .regularExpression)
                // Led by an acronym or mostly capitals, it's a constant (API_KEY, NODE_ENV); otherwise snake_case (user_id).
                let first = id.split(separator: "_").first.map(String.init) ?? ""
                let letters = id.filter(\.isLetter)
                let upper = letters.filter(\.isUppercase).count
                let constant = (first.count >= 2 && first == first.uppercased() && first.contains(where: \.isLetter)) || upper * 2 > letters.count
                return constant ? id.uppercased() : id.lowercased()
            }
        }
        if t.range(of: #"(?i)\bcase\b"#, options: .regularExpression) != nil {
            t = sub(caseCommand, t) { g in
                let words = g[2].split(separator: " ").map { $0.lowercased() }
                guard !words.isEmpty else { return nil }
                switch g[1].lowercased() {
                case "camel": return words[0] + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
                case "pascal": return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
                case "kebab": return words.joined(separator: "-")
                case "snake": return words.joined(separator: "_")
                default: return words.joined(separator: "_").uppercased()
                }
            }
        }
        return t
    }

    private static let opWords: [(String, String)] = [
        (#"(?i)\bequals[ \t]+equals[ \t]+equals\b"#, "==="), (#"(?i)\b(?:equals[ \t]+equals|double[ \t]+equals)\b"#, "=="),
        (#"(?i)\b(?:not[ \t]+equals|not[ \t]+equal[ \t]+to|bang[ \t]+equals)\b"#, "!="), (#"(?i)\b(?:equals[ \t]+greater[ \t]+than|fat[ \t]+arrow)\b"#, "=>"),
        (#"(?i)\bgreater[ \t]+than[ \t]+or[ \t]+equal[ \t]+to\b"#, ">="), (#"(?i)\bless[ \t]+than[ \t]+or[ \t]+equal[ \t]+to\b"#, "<="),
        (#"(?i)\bdash[ \t]+greater[ \t]+than\b"#, "->"), (#"(?i)\bplus[ \t]+equals\b"#, "+="), (#"(?i)\bminus[ \t]+equals\b"#, "-="),
        (#"(?i)\b(?:double[ \t]+ampersand|and[ \t]+and)\b(?=[ \t]+\w)"#, "&&"), (#"(?i)\b(?:double[ \t]+pipe|pipe[ \t]+pipe)\b"#, "||"),
    ]
    private static let opRegexes = opWords.map { (re($0.0), $0.1) }
    private static let assign = re(#"(?<![\w-])((?:--?)?[A-Z][A-Z0-9_]+|[a-z][a-z0-9]*_[a-z0-9_]+|--[a-z][\w-]*)[ \t]+equals[ \t]+([^\s,;]+)"#)
    private static let parens = re(#"(?i)\bopen[ \t]+(paren(?:thesis)?|(?:square[ \t]+)?bracket|curly[ \t]+(?:brace|bracket)|brace|angle[ \t]+bracket)[ \t]*(.*?)[ \t]*\bclose[ \t]+(?:paren(?:thesis)?|(?:square[ \t]+)?bracket|curly[ \t]+(?:brace|bracket)|brace|angle[ \t]+bracket)\b"#)

    /// "a equals equals b" → a == b, "NODE_ENV equals production" → NODE_ENV=production, "open paren close paren" → ().
    static func operators(_ s: String) -> String {
        var t = s
        for (r, op) in opRegexes { t = sub(r, t) { _ in op } }
        t = sub(assign, t) { g in "\(g[1])=\(g[2])" }
        t = sub(parens, t) { g in
            let kind = g[1].lowercased()
            let (open, close) = kind.hasPrefix("paren") ? ("(", ")") : kind.contains("curly") || kind == "brace" ? ("{", "}")
                : kind.contains("angle") ? ("<", ">") : ("[", "]")
            return open + g[2] + close
        }
        return t
    }

    // MARK: Shortcuts, colours, phone numbers, versions

    private static let modifier = "(?:command|cmd|control|ctrl|option|alt|shift|fn)"
    private static let shortcut = re(#"(?i)(?<![\w+])((?:"# + modifier + #"(?:[ \t]*\+[ \t]*|-(?=\w)|[ \t]+))+)(enter|return|tab|space|escape|esc|delete|backspace|up|down|left|right|f\d{1,2}|[a-z0-9])(?![\w'])"#)
    private static let pressVerbs: Set<String> = ["press", "pressing", "pressed", "hit", "hitting", "hold", "holding", "use", "type",
                                                  "then", "or", "and", "with", "tap", "click", "shortcut", "is", "try"]

    /// "press command k" → Cmd+K, "command shift p" → Cmd+Shift+P. A lone "shift"/"option" needs a second modifier.
    static func shortcuts(_ s: String) -> String {
        guard s.range(of: #"(?i)\b(command|cmd|control|ctrl|option|alt|shift)\b"#, options: .regularExpression) != nil else { return s }
        let ns = s as NSString
        var out = s
        for m in shortcut.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let mods = ns.substring(with: m.range(at: 1)).lowercased().split(whereSeparator: { " +-".contains($0) }).map(String.init)
            let key = ns.substring(with: m.range(at: 2))
            let before = ns.substring(to: m.range.location).split(whereSeparator: { $0 == " " }).last.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
            let strong = mods.contains { ["command", "cmd", "control", "ctrl"].contains($0) }
            guard mods.count >= 2 || (strong && (pressVerbs.contains(before) || before.isEmpty)) else { continue }
            let names = ["command": "Cmd", "cmd": "Cmd", "control": "Ctrl", "ctrl": "Ctrl", "option": "Option", "alt": "Option",
                         "shift": "Shift", "fn": "Fn"]
            var seen: [String] = []
            for mod in mods { if let n = names[mod], !seen.contains(n) { seen.append(n) } }
            let k = key.count == 1 ? key.uppercased() : key.prefix(1).uppercased() + key.dropFirst().lowercased()
            out = (out as NSString).replacingCharacters(in: m.range, with: (seen + [k]).joined(separator: "+"))
        }
        return out
    }

    private static let hexPart = "(?:[0-9a-f]{1,8}|" + digitWord + ")"
    private static let hex = re(#"(?i)\b(?:hash|hex|pound)[ \t]+("# + hexPart + #"(?:[\s-]+"# + hexPart + #"){0,7})(?![\w])"#)
    /// "hash F F 5733" → #FF5733 (3, 6 or 8 hex digits).
    static func hexColors(_ s: String) -> String {
        sub(hex, s) { g in
            let value = digits(g[1].trimmingCharacters(in: .whitespaces)).uppercased()
            guard [3, 6, 8].contains(value.count), value.allSatisfy(\.isHexDigit), value.contains(where: \.isLetter) || value.count == 6 else { return nil }
            let trailing = g[1].hasSuffix(" ") ? " " : ""
            return "#" + value + trailing
        }
    }

    private static let phone = re(#"(?i)\bplus[ \t]+(\d[\d\s-]{7,}\d)\b"#)
    /// "plus 91 98765 43210" → +919876543210.
    static func phoneNumbers(_ s: String) -> String {
        sub(phone, s) { g in "+" + g[1].filter(\.isNumber) }
    }

    private static let version = re(#"\b[vV][ \t]+(\d+(?:\.\d+)+)\b"#)
    /// "v 2.0" → v2.0.
    static func versions(_ s: String) -> String { sub(version, s) { g in "v" + g[1] } }
}

/// Words speech engines swap for numbers: "we need two fix it" → "we need to fix it".
enum Homophones {
    private static let toBefore = try! NSRegularExpression(pattern:
        #"(?i)\b(need|needs|needed|want|wants|wanted|have|has|had|going|trying|try|tries|tried|able|used|decided|plan|planning|like|love|hate|ready|supposed|got|ought|wish|hope|hoping|forgot|remember|start|started|begin|began|continue|seem|seems|seemed|easy|hard|time|way|how|where|what|when)[ \t]+two[ \t]+([a-z]+)\b(?![ \t]+(?:of|more|or|and|times|days|hours|minutes|weeks|months|years|people|things)\b)"#)
    private static let numberWord: Set<String> = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "twenty", "thirty", "forty", "fifty", "hundred", "thousand", "million"]
    private static let tagger = NLTagger(tagSchemes: [.lexicalClass])

    static func apply(_ s: String) -> String {
        guard s.range(of: #"(?i)\btwo\b"#, options: .regularExpression) != nil else { return s }
        return DevText.sub(toBefore, s) { g in
            let next = g[2].lowercased()
            if numberWord.contains(next) { return nil }
            // "need two fixes" stays; "need two fix" (a verb) is "need to fix".
            tagger.string = "I want to \(next) it"
            let tag = tagger.tag(at: tagger.string!.range(of: next)!.lowerBound, unit: .word, scheme: .lexicalClass).0
            guard tag == .verb, !next.hasSuffix("s") || ["focus", "discuss", "pass", "press", "access", "process", "address", "express", "cross", "miss", "toss", "guess"].contains(next) else { return nil }
            return "\(g[1]) to \(g[2])"
        }
    }
}
