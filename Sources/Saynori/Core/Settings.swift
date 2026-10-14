import AppKit
import SwiftUI

/// The dictation key: a bare modifier (fn, right ⌥, left ⇧…) or any key with optional modifiers (F5, ⌥Space…).
struct TriggerKey: Hashable, Identifiable {
    /// Virtual key code (flagsChanged for modifiers, keyDown/keyUp otherwise).
    var keyCode: UInt16
    /// ⌘⌥⌃⇧ that must be held with a non-modifier key (CGEventFlags raw value); 0 for modifier triggers.
    var modifiers: UInt64 = 0
    /// Short display name, e.g. "fn", "right ⌥", "⌥Space".
    var short: String

    static let fn = TriggerKey(keyCode: 63, short: "fn")
    static let rightOption = TriggerKey(keyCode: 61, short: "right ⌥")
    static let rightCommand = TriggerKey(keyCode: 54, short: "right ⌘")
    static let rightControl = TriggerKey(keyCode: 62, short: "right ⌃")
    static let presets: [TriggerKey] = [.fn, .rightOption, .rightCommand, .rightControl]

    var id: String { rawValue }
    var isPreset: Bool { Self.presets.contains(self) }
    var label: String {
        switch self {
        case .fn: return "fn / 🌐"
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .rightControl: return "Right ⌃ Control"
        default: return short
        }
    }

    /// The modifier flag a modifier key sets, or nil for an ordinary key.
    static func modifierFlag(_ code: UInt16) -> CGEventFlags? {
        switch code {
        case 63: return .maskSecondaryFn
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 55, 54: return .maskCommand
        case 59, 62: return .maskControl
        default: return nil
        }
    }
    var flag: CGEventFlags? { Self.modifierFlag(keyCode) }
    var isModifier: Bool { flag != nil }
    static let comboMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    /// Stored as "keyCode:modifiers:name"; the old preset names ("fn", "rightOption"…) still load.
    var rawValue: String { "\(keyCode):\(modifiers):\(short)" }
    init(keyCode: UInt16, modifiers: UInt64 = 0, short: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.short = short
    }
    init?(rawValue: String) {
        switch rawValue {
        case "fn": self = .fn; return
        case "rightOption": self = .rightOption; return
        case "rightCommand": self = .rightCommand; return
        case "rightControl": self = .rightControl; return
        default: break
        }
        let parts = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = UInt16(parts[0]), let mods = UInt64(parts[1]), !parts[2].isEmpty else { return nil }
        self.init(keyCode: code, modifiers: mods, short: String(parts[2]))
    }
}

enum PolishStyle: String, CaseIterable, Identifiable {
    case off, clean, professional, casual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Raw"
        case .clean: return "Clean"
        case .professional: return "Formal"
        case .casual: return "Casual"
        }
    }
    var blurb: String {
        switch self {
        case .off: return "Exactly what was heard, with no clean-up."
        case .clean: return "Removes filler words and fixes punctuation. Keeps your wording."
        case .professional: return "Tightens wording for work messages and email."
        case .casual: return "Relaxed and lowercase, for chats with friends."
        }
    }
    var icon: String {
        switch self {
        case .off: return "waveform"
        case .clean: return "sparkles"
        case .professional: return "briefcase.fill"
        case .casual: return "bubble.left.and.bubble.right.fill"
        }
    }
}

enum OutputMode: String, CaseIterable, Identifiable {
    case transcribe, translate, codemix, translit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .transcribe: return "Native script"
        case .translate: return "Translate to English"
        case .codemix: return "Code-mixed (Hinglish)"
        case .translit: return "Romanized"
        }
    }
}

struct Language: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
    static let all: [Language] = [
        .init(code: "unknown", name: "Auto-detect"),
        .init(code: "en-IN", name: "English"),
        .init(code: "hi-IN", name: "हिन्दी Hindi"),
        .init(code: "bn-IN", name: "বাংলা Bengali"),
        .init(code: "ta-IN", name: "தமிழ் Tamil"),
        .init(code: "te-IN", name: "తెలుగు Telugu"),
        .init(code: "kn-IN", name: "ಕನ್ನಡ Kannada"),
        .init(code: "ml-IN", name: "മലയാളം Malayalam"),
        .init(code: "mr-IN", name: "मराठी Marathi"),
        .init(code: "gu-IN", name: "ગુજરાતી Gujarati"),
        .init(code: "pa-IN", name: "ਪੰਜਾਬੀ Punjabi"),
        .init(code: "od-IN", name: "ଓଡ଼ିଆ Odia"),
    ]
    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }
}

/// Persistent user preferences. Everything but the API key lives in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let d = UserDefaults.standard

    @Published var trigger: TriggerKey = TriggerKey(rawValue: d.string(forKey: "trigger") ?? "") ?? .fn { didSet { Self.d.set(trigger.rawValue, forKey: "trigger") } }
    /// True while Settings is listening for a new dictation key (the hotkey tap stands aside).
    @Published var recordingTrigger = false
    @Published var language: String = d.string(forKey: "language") ?? "unknown" { didSet { Self.d.set(language, forKey: "language") } }
    @Published var sttModel: String = d.string(forKey: "sttModel") ?? "saaras:v4" { didSet { Self.d.set(sttModel, forKey: "sttModel") } }
    @Published var outputMode: OutputMode = OutputMode(rawValue: d.string(forKey: "outputMode") ?? "") ?? .transcribe { didSet { Self.d.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var polish: PolishStyle = PolishStyle(rawValue: d.string(forKey: "polish") ?? "") ?? .clean { didSet { Self.d.set(polish.rawValue, forKey: "polish") } }
    @Published var contextAware: Bool = d.object(forKey: "contextAware") as? Bool ?? true { didSet { Self.d.set(contextAware, forKey: "contextAware") } }
    /// Where the dictation bar docks along the bottom edge: "left", "center" or "right".
    @Published var barAnchor: String = d.string(forKey: "barAnchor") ?? "center" { didSet { Self.d.set(barAnchor, forKey: "barAnchor") } }
    /// Formatting engine: a `Provider` raw value that can format, or "off". ("local" = Gemma, from older versions.)
    @Published var engine: String = d.string(forKey: "engine") ?? "sarvam" { didSet { Self.d.set(engine, forKey: "engine") } }
    @Published var localKind: String = d.string(forKey: "localKind") ?? "ollama" { didSet { Self.d.set(localKind, forKey: "localKind") } }
    @Published var localEndpoint: String = d.string(forKey: "localEndpoint") ?? "http://localhost:11434" { didSet { Self.d.set(localEndpoint, forKey: "localEndpoint") } }
    @Published var localModel: String = d.string(forKey: "localModel") ?? "gemma4:e4b-it-qat" { didSet { Self.d.set(localModel, forKey: "localModel") } }

    /// Speech engine: a `Provider` raw value. ("local" = Gemma, from older versions.)
    @Published var transcriber: String = d.string(forKey: "transcriber") ?? "sarvam" { didSet { Self.d.set(transcriber, forKey: "transcriber") } }

    var speechProvider: Provider {
        transcriber == "local" ? .gemma : Provider(rawValue: transcriber) ?? .sarvam
    }
    /// nil = formatting off (local clean-up only).
    var formatProvider: Provider? {
        if engine == "off" { return nil }
        if engine == "local" { return .gemma }
        return Provider(rawValue: engine).flatMap { $0.canFormat ? $0 : nil }
    }
    /// Uses `provider` for speech, and for formatting too when it can format (otherwise formatting is off).
    func choose(_ provider: Provider) {
        transcriber = provider.rawValue
        engine = provider.canFormat && provider != .gemma ? provider.rawValue : (provider == .gemma ? "gemma" : "off")
        if provider == .gemma { localKind = "ollama" }
        if provider.isLocal, provider != .gemma { polish = .off } else if polish == .off { polish = .clean }
        setupChosen = provider.rawValue
    }

    var localSpeech: (endpoint: String, model: String)? {
        speechProvider == .gemma && localKind == "ollama" ? (localEndpoint, localModel) : nil
    }
    /// Which setup the user picked in "Choose your setup" ("" until they choose).
    @Published var setupChosen: String = d.string(forKey: "setupChosen") ?? "" { didSet { Self.d.set(setupChosen, forKey: "setupChosen") } }

    /// The first engine in use whose API key is missing, if any.
    var missingKey: Provider? {
        [speechProvider, formatProvider].compactMap { $0 }.first { $0.needsKey && (keys[$0.rawValue] ?? "").isEmpty }
    }
    var engineReady: Bool { missingKey == nil }

    var chatEngine: ChatEngine {
        formatProvider == .gemma
            ? .local(kind: ChatEngine.LocalKind(rawValue: localKind) ?? .ollama, endpoint: localEndpoint, model: localModel)
            : .sarvam
    }

    /// A client wired to the current engines and keys.
    func client() -> SarvamClient {
        var c = SarvamClient(apiKey: apiKey)
        c.keys = keys
        c.speech = speechProvider
        c.formatter = formatProvider ?? .sarvam
        c.engine = chatEngine
        c.localSpeech = localSpeech
        return c
    }

    @Published var promptMode: Bool = d.object(forKey: "promptMode") as? Bool ?? true { didSet { Self.d.set(promptMode, forKey: "promptMode") } }
    @Published var smartFormat: Bool = d.object(forKey: "smartFormat") as? Bool ?? true { didSet { Self.d.set(smartFormat, forKey: "smartFormat") } }
    @Published var particles: Bool = d.object(forKey: "particles") as? Bool ?? true { didSet { Self.d.set(particles, forKey: "particles") } }
    @Published var sounds: Bool = d.object(forKey: "sounds") as? Bool ?? true { didSet { Self.d.set(sounds, forKey: "sounds") } }
    @Published var trailingSpace: Bool = d.object(forKey: "trailingSpace") as? Bool ?? true { didSet { Self.d.set(trailingSpace, forKey: "trailingSpace") } }
    @Published var onboarded: Bool = d.bool(forKey: "onboarded") { didSet { Self.d.set(onboarded, forKey: "onboarded") } }
    @Published var alwaysShowPill: Bool = d.object(forKey: "alwaysShowPill") as? Bool ?? true { didSet { Self.d.set(alwaysShowPill, forKey: "alwaysShowPill") } }

    @Published var keys: [String: String] = [:]
    /// The Sarvam key (kept for Sarvam-specific code paths).
    var apiKey: String { keys["sarvam"] ?? "" }

    private init() {
        keys = KeyStore.load()
    }

    func setKey(_ key: String, for p: Provider) {
        keys[p.rawValue] = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeyStore.save(keys)
    }

    static var supportDir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saynori", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func loadAPIKey() -> String { KeyStore.load()["sarvam"] ?? "" }

    func saveAPIKey(_ key: String) { setKey(key, for: .sarvam) }
}
