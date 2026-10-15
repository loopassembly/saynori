import AppKit
import ApplicationServices

/// What's around the insertion point, read through the Accessibility API.
/// Used so dictation continues a sentence naturally (spacing and capitalisation).
struct CursorContext {
    /// Up to ~300 characters immediately before the cursor. `nil` when the app doesn't expose it.
    var before: String?
    var appName: String
    var bundleID: String
    /// Caret rectangle in global Cocoa coordinates, when the app reports it.
    var caret: CGRect? = nil
    /// Title of the focused window (e.g. a browser tab's "ChatGPT"), for spotting AI tools.
    var windowTitle: String = ""

    static func capture() -> CursorContext {
        let app = NSWorkspace.shared.frontmostApplication
        var ctx = CursorContext(before: nil, appName: app?.localizedName ?? "", bundleID: app?.bundleIdentifier ?? "")
        guard AXIsProcessTrusted(), let pid = app?.processIdentifier else { return ctx }

        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.12)
        // Electron apps (Slack, Discord, VS Code…) only expose text once asked.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success, let winRef,
           CFGetTypeID(winRef) == AXUIElementGetTypeID() {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(winRef as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success { ctx.windowTitle = t as? String ?? "" }
        }

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return ctx }
        let el = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return ctx }
        var sel = CFRange()
        AXValueGetValue(rangeRef as! AXValue, .cfRange, &sel)
        guard sel.location >= 0 else { return ctx }
        ctx.caret = caretRect(el, sel) ?? elementRect(el)
        if sel.location == 0 { ctx.before = ""; return ctx }

        let start = max(0, sel.location - 300)
        var r = CFRange(location: start, length: sel.location - start)
        if let axRange = AXValueCreate(.cfRange, &r) {
            var strRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, axRange, &strRef) == .success,
               let s = strRef as? String {
                ctx.before = s
                return ctx
            }
        }
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success, let full = valueRef as? String {
            let u = Array(full.utf16)
            let end = min(sel.location, u.count)
            ctx.before = String(decoding: u[max(0, end - 300)..<end], as: UTF16.self)
        }
        return ctx
    }
}

extension CursorContext {
    fileprivate static func bounds(_ el: AXUIElement, _ range: CFRange) -> CGRect? {
        var r = range
        guard let ax = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, ax, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(out as! AXValue, .cgRect, &rect)
        return rect.height > 0 ? rect : nil
    }

    /// AX uses top-left origin on the primary screen; Cocoa uses bottom-left.
    fileprivate static func toCocoa(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    fileprivate static func caretRect(_ el: AXUIElement, _ sel: CFRange) -> CGRect? {
        if let r = bounds(el, CFRange(location: sel.location, length: max(sel.length, 0))), r.minX > 0 || r.minY > 0 {
            return toCocoa(CGRect(x: r.minX, y: r.minY, width: max(r.width, 1), height: r.height))
        }
        if sel.location > 0, let r = bounds(el, CFRange(location: sel.location - 1, length: 1)) {
            return toCocoa(CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height))
        }
        return nil
    }

    fileprivate static func elementRect(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        // Land near the start of the field rather than the middle of a huge text view.
        let h = min(size.height, 22)
        return toCocoa(CGRect(x: pos.x + 12, y: pos.y + min(size.height / 2, 14) - h / 2, width: 1, height: h))
    }
}

/// Deterministic final touches so text drops into the document like it was typed there.
enum SmartJoin {
    static func apply(_ text: String, before: String?, adjustCase: Bool, vocabulary: [String] = []) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let before else { return t }
        guard let last = before.last else { return t } // start of field: keep as is

        if last.isNewline { return t }

        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let endsSentence = trimmed.last.map { ".!?:…".contains($0) || $0.isNewline } ?? true

        if !endsSentence, trimmed.last.map({ $0.isLetter || $0.isNumber || ",;".contains($0) }) == true {
            // With polish on, the model decides names; we only fix plain connective words it capitalised.
            let first = String(t.prefix { $0.isLetter || $0 == "'" || $0 == "’" }).lowercased()
            if commonWords.contains(first) || (adjustCase && !isName(t, vocabulary: vocabulary)) { t = lowercaseFirstWord(t) }
        }
        let opensPair = "([{\"'“‘/@#".contains(last)
        if !last.isWhitespace && !opensPair && !(t.first.map { ",.;:!?)]}".contains($0) } ?? false) {
            t = " " + t
        }
        return t
    }

    private static let commonWords: Set<String> = [
        "and", "but", "or", "so", "then", "because", "which", "that", "who", "when", "where", "while", "if", "though",
        "also", "just", "not", "the", "a", "an", "to", "for", "with", "without", "of", "in", "on", "at", "by", "from",
        "as", "into", "about", "after", "before", "until", "we", "you", "it", "they", "he", "she", "this", "these",
        "those", "there", "my", "our", "your", "their", "his", "her", "its", "is", "are", "was", "were", "be", "can",
        "could", "should", "would", "will", "maybe", "probably", "really", "very", "some", "all", "more", "plus",
    ]

    /// A word that keeps its capital mid-sentence: a Dictionary or known term (Supabase, Saynori), or one macOS only
    /// knows capitalised (Priya, Monday, London). Also code-like starts (Cmd+K, API_KEY, main.swift).
    private static func isName(_ t: String, vocabulary: [String]) -> Bool {
        let word = String(t.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
        guard word.count > 1 else { return false }
        if let next = t.dropFirst(word.count).first, "+_./@:".contains(next) { return true }
        if vocabulary.contains(word) || Terms.isKnownTerm(word) { return true }
        // "monday" and "priya" aren't words in lower case; "tomorrow" and "Great" are.
        return !Terms.isEnglish(word.lowercased())
    }

    private static func lowercaseFirstWord(_ t: String) -> String {
        let word = t.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        guard let first = word.first, first.isUppercase else { return t }
        // Keep "I", acronyms (API, NASA) and names the model capitalised mid-word (iPhone, McDonald).
        let rest = word.dropFirst()
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return t }
        if !rest.isEmpty && rest.allSatisfy({ $0.isUppercase }) { return t }
        if rest.contains(where: { $0.isUppercase }) { return t }
        return first.lowercased() + t.dropFirst()
    }
}

/// Speech recognisers often add "?" from rising intonation. Keep it only on real questions.
enum QuestionFix {
    private static let starters: Set<String> = [
        "who", "what", "when", "where", "why", "how", "which", "whose", "whom", "is", "are", "am", "was", "were",
        "do", "does", "did", "can", "could", "will", "would", "should", "shall", "may", "might", "must", "have",
        "has", "had", "isn't", "aren't", "wasn't", "weren't", "don't", "doesn't", "didn't", "can't", "couldn't",
        "won't", "wouldn't", "shouldn't", "haven't", "hasn't", "any", "anyone", "anybody", "what's", "where's",
        "who's", "how's", "when's", "why's", "kya", "kyun", "kyon", "kaise", "kab", "kahan", "kaun", "kitna", "kitne",
    ]
    private static let leadIns: Set<String> = ["hey", "hi", "hello", "so", "okay", "ok", "alright", "and", "but", "also", "well",
                                               "now", "bro", "dude", "yeah", "yes", "no", "please", "then", "like", "actually",
                                               "basically", "listen", "look", "wait", "oh", "sir", "guys", "man", "buddy", "yaar",
                                               "bhai", "anyway", "just", "quick", "question", "honestly", "seriously", "um", "uh"]
    private static let tags = ["right?", "okay?", "ok?", "yeah?", "no?", "correct?", "yes?", "huh?", "na?", "hai na?"]

    static func apply(_ text: String) -> String {
        guard text.contains("?") else { return text }
        var out = ""
        var sentence = ""
        for ch in text {
            sentence.append(ch)
            if ".!?\n".contains(ch) {
                out += fix(sentence)
                sentence = ""
            }
        }
        return out + sentence
    }

    private static func fix(_ s: String) -> String {
        guard s.hasSuffix("?") else { return s }
        let lower = s.lowercased()
        if tags.contains(where: { lower.hasSuffix(" " + $0) || lower.hasSuffix("," + $0) }) { return s }
        // Only judge Latin-script sentences; other scripts keep what the model chose.
        guard lower.unicodeScalars.contains(where: { ("a"..."z").contains($0) }) else { return s }
        // A question may start after a lead-in clause ("Sarah, can you…"), so check each clause.
        let clauses = lower.split(whereSeparator: { ",;:—–".contains($0) })
        for clause in clauses {
            // Skip lead-ins before the question word: "Hey can you…", "So what do you think", "Bro is it…".
            let words = clause.split(whereSeparator: { $0 == " " || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'"))) }
            let first = words.first { !leadIns.contains($0) } ?? ""
            if starters.contains(first) { return s }
        }
        if lower.contains(" or not?") { return s }
        // Short rising-tone questions ("The budget is fine?") are usually intentional.
        if lower.split(separator: " ").count <= 6 { return s }
        return String(s.dropLast()) + "."
    }
}

/// Whether the focused thing can take typed text. Deliberately conservative: only `.no` when an
/// app clearly reports focus on something that isn't text (Finder's file list, the Dock, a
/// button). Apps that report nothing useful (Zed says "window", Electron apps say nothing) are
/// `.unknown`, and we paste as usual there.
enum TextTarget {
    case yes, no, unknown

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXImage", "AXRow", "AXCell", "AXColumn",
        "AXMenu", "AXMenuBar", "AXMenuItem", "AXMenuBarItem", "AXDockItem", "AXButton", "AXCheckBox",
        "AXRadioButton", "AXSlider", "AXPopUpButton", "AXDisclosureTriangle", "AXIncrementor",
        "AXTabGroup", "AXToolbar", "AXStaticText", "AXLink",
    ]
    private static let neverTextApps: Set<String> = ["com.apple.dock", "com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]

    static func current() -> TextTarget {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        if let id = app.bundleIdentifier, neverTextApps.contains(id) { return .no }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.12)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
        let el = focused as! AXUIElement

        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success { return .yes }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue { return .yes }
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return .unknown }
        if textRoles.contains(role) { return .yes }
        if nonTextRoles.contains(role) { return .no }
        return .unknown
    }

    /// Whether the frontmost app's own Paste command (the ⌘V menu item) is enabled right now.
    /// Apps disable it when nothing focused can take a paste. `nil` when it can't be read.
    static func pasteMenuEnabled() -> Bool? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.15)
        func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
        }
        guard let barRef = attr(appEl, kAXMenuBarAttribute), CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return nil }
        let bar = barRef as! AXUIElement
        for top in (attr(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
            for menu in (attr(top, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
                for item in (attr(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
                    guard (attr(item, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == "V",
                          (attr(item, kAXMenuItemCmdModifiersAttribute) as? Int) == 0 else { continue }
                    return attr(item, kAXEnabledAttribute) as? Bool
                }
            }
        }
        return nil
    }
}
