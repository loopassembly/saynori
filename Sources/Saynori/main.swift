import AppKit
import Combine
import SwiftUI

// Bring settings, history and keys over from the app's old name (once).
Migration.run()

// CLI formatting check: `Saynori --format "raw text" [before-cursor] [app] [bundle-id]`.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--format" {
    SelfTest.format(Array(CommandLine.arguments.dropFirst(2)))
}

// Formatter check: `Saynori --score-local [library.json] [N]` runs the instant formatter over saved dictations
// and compares it with what the AI formatter produced (prints N examples).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--score-local" {
    LocalScore.run(Array(CommandLine.arguments.dropFirst(2)))
}

// Formatter tests: `Saynori --test-formatter [cases.json] [--history]` runs the golden cases (exit 1 on any failure)
// and, with --history, audits every saved dictation for idempotence and dropped words.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--test-formatter" {
    FormatterTests.run(Array(CommandLine.arguments.dropFirst(2)))
}

// Instant formatter: `Saynori --format-local "raw text" [bundle-id]` (no network).
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--format-local" {
    let a = CommandLine.arguments
    let ctx = CursorContext(before: nil, appName: "", bundleID: a.count > 3 ? a[3] : "")
    let vocab = Store.shared.vocabulary
    _ = LocalFormatter.format("warm up", context: ctx, vocabulary: vocab)
    let t0 = Date()
    let out = LocalFormatter.format(a[2], context: ctx, vocabulary: vocab)
    print("[\(String(format: "%.2f", Date().timeIntervalSince(t0) * 1000)) ms]\n\(out)")
    exit(0)
}

// Resource check: `Saynori --bench parakeet|whistle clip.wav [N]` loads the engine, transcribes the clip N times and
// prints load time, latency, CPU time and memory (physical footprint, the number Activity Monitor shows).
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--bench" {
    let a = CommandLine.arguments
    Bench.run(engine: a[2], path: a[3], runs: a.count > 4 ? Int(a[4]) ?? 10 : 10)
}

// CLI self-test: `Saynori --selftest file.wav` runs the Sarvam pipeline headlessly.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--selftest" {
    SelfTest.run(path: CommandLine.arguments[2])
}

// Build helpers: `Saynori --render-icon out.png [tile.png]` renders the 1024-px app icon;
// `Saynori --render-menubar character.png outdir` writes the menu-bar template images.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-icon" {
    let a = CommandLine.arguments
    MainActor.assumeIsolated {
        BrandArt.renderIcon(to: URL(fileURLWithPath: a[2]), art: a.count > 3 ? URL(fileURLWithPath: a[3]) : nil)
    }
    exit(0)
}
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--render-menubar" {
    let a = CommandLine.arguments
    exit(BrandArt.renderMenuBar(from: URL(fileURLWithPath: a[2]), to: URL(fileURLWithPath: a[3])) ? 0 : 1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let controller = DictationController()
    private var statusItem: NSStatusItem!
    private var pill: PillPanel!
    private let flight = FlightPanel()
    private var copyCard: CopyCardPanel!
    private var dashboard: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        installMainMenu()
        pill = PillPanel(controller: controller)
        pill.orderFrontRegardless()
        copyCard = CopyCardPanel(controller: controller)
        controller.$unplaced.sink { [weak self] text in
            guard let self else { return }
            if text != nil {
                self.copyCard.place(above: self.pill.frame)
                self.copyCard.orderFrontRegardless()
            } else {
                // Let the fade-out play before hiding the window.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if self.controller.unplaced == nil { self.copyCard.orderOut(nil) }
                }
            }
        }.store(in: &cancellables)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image()
        buildMenu()

        controller.$phase.sink { [weak self] p in
            guard let self else { return }
            if p == .listening { self.pill.reposition(avoiding: self.controller.caretRect) }
            if p == .idle { self.pill.reposition() }
            // The mark tints red while you're dictating, template (auto light/dark) otherwise.
            let active = p == .listening || p == .processing
            let img = MenuBarIcon.image(active: active)
            self.statusItem.button?.image = img
            self.statusItem.button?.contentTintColor = active ? NSColor(hex: 0xFF6363) : nil
        }.store(in: &cancellables)

        controller.onDeliver = { [weak self] ctx in
            guard let self, AppSettings.shared.particles,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return 0 }
            // The words form in the pill first; the paste lands as they dissolve toward the cursor.
            let lead = PixelTiming.lead
            guard let caret = ctx.caret else { return lead }
            let f = self.pill.frame
            let from = CGPoint(x: f.midX,
                               y: f.minY + PillView.bottomInset + PillView.hud.height / 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + lead) { self.flight.launch(from: from, to: caret) }
            return lead + 0.22
        }
        // `SAYNORI_PILL_DEMO=1`: loop the bar's animation with a sample transcript, raised above
        // the real bar. No mic, no hotkey, nothing is pasted — for checking visuals safely.
        if let demo = ProcessInfo.processInfo.environment["SAYNORI_PILL_DEMO"] {
            pill.lift = 160
            pill.reposition()
            if ProcessInfo.processInfo.environment["SAYNORI_CARD_DEMO"] != nil {
                copyCard.setFrameOrigin(NSPoint(x: pill.frame.midX - CopyCardPanel.size.width / 2, y: pill.frame.minY + 200))
                let card = ProcessInfo.processInfo.environment["SAYNORI_CARD_DEMO"] ?? ""
                controller.keepUnplacedPreview("Let's move the design review to Thursday at 4 and loop in Priya on the pricing slide.",
                                               pastedInto: card == "note" ? "Zed" : nil)
                return
            }
            controller.runPillDemo(text: demo.count > 3 ? demo : "The new pixel bar is thin, sharp, and it types my words.")
            return
        }
        // Preview copies (sample data) never listen to the fn key, so they can't double up with the real app.
        if ProcessInfo.processInfo.environment["SAYNORI_DEMO"] == nil { controller.start() }
        // Keep the on-device speech model loaded whenever it's the engine, so dictations never wait for it.
        AppSettings.shared.$transcriber.sink { value in
            if value == "parakeet" { Task { try? await ParakeetEngine.shared.prepare() } }
            if value == "whistle" { Task { try? await WhistleEngine.shared.prepare() } }
        }.store(in: &cancellables)
        // Using fn for dictation means macOS must not also open emoji on it.
        // Onboarding asks for these itself, one step at a time.
        if AppSettings.shared.onboarded {
            if AppSettings.shared.trigger == .fn { FnUsage.setDoNothing(force: false) }
            if !AudioRecorder.hasPermission { AudioRecorder.requestPermission { _ in } }
        }

        // First launch (or missing permissions): show the dashboard so onboarding is visible.
        let s = AppSettings.shared
        if !s.onboarded || !TextInserter.isTrusted || ProcessInfo.processInfo.environment["SAYNORI_DEMO"] != nil {
            showDashboard()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    /// Standard app + Edit menus. Without them ⌘V/⌘C/⌘A do nothing in the app's own windows,
    /// so dictation couldn't paste into the onboarding's practice box.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "Saynori", action: nil, keyEquivalent: "")
        let app = NSMenu()
        app.addItem(withTitle: "Quit Saynori", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Start Hands-free Dictation", action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let again = menu.addItem(withTitle: "Paste Last Dictation", action: #selector(pasteLast), keyEquivalent: "v")
        again.keyEquivalentModifierMask = [.command, .control]
        again.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Saynori", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openDashboard() { showDashboard() }
    @objc private func toggle() { controller.toggleHandsFree() }
    @objc private func pasteLast() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.controller.pasteLast() }
    }

    func showDashboard() {
        if dashboard == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(hex: 0x0F0F11)
            w.appearance = NSAppearance(named: .darkAqua)
            w.minSize = NSSize(width: 860, height: 600)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("SaynoriDashboard")
            dashboard = w
        }
        if dashboard?.contentView is NSHostingView<DashboardView> == false {
            dashboard?.contentView = NSHostingView(rootView: DashboardView(controller: controller))
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Tear down the SwiftUI tree so its animations/timers stop costing CPU while hidden.
        DispatchQueue.main.async { self.dashboard?.contentView = NSView() }
        // Back to a pure menu-bar utility: no Dock icon, minimal footprint.
        NSApp.setActivationPolicy(.accessory)
    }
}

enum SelfTest {
    static func run(path: String) -> Never {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let url = URL(fileURLWithPath: path)
                let data = try Data(contentsOf: url)
                // Pull PCM16 samples out of a 16 kHz mono WAV (skip the 44-byte header).
                let pcm = data.dropFirst(44)
                let samples: [Int16] = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                let key = AppSettings.loadAPIKey()
                print("key: \(key.isEmpty ? "MISSING" : "found (\(key.prefix(4))…)")")
                print("audio: \(String(format: "%.2f", Double(samples.count) / 16000)) s, chunks: \(WAV.chunks(samples).count), silent: \(WAV.isSilent(samples))")
                var client = SarvamClient(apiKey: key)
                client.keys = KeyStore.load()
                // TLM_SPEECH / TLM_ENGINE pick any provider ("local" = Gemma via Ollama; TLM_LOCAL_MODEL overrides it).
                let env = ProcessInfo.processInfo.environment
                func provider(_ v: String?) -> Provider { v == "local" ? .gemma : Provider(rawValue: v ?? "") ?? .sarvam }
                client.speech = provider(env["TLM_SPEECH"])
                client.formatter = provider(env["TLM_ENGINE"])
                print("speech: \(client.speech.name), formatting: \(client.formatter.name)")
                if client.speech == .parakeet { let t = Date(); try await ParakeetEngine.shared.prepare(); print("parakeet load: \(ms(t))") }
                if client.speech == .whistle { let t = Date(); try await WhistleEngine.shared.prepare(); print("whistle load: \(ms(t))") }
                client.localSpeech = (env["TLM_LOCAL_ENDPOINT"] ?? "http://localhost:11434", env["TLM_LOCAL_MODEL"] ?? "gemma4:e4b-it-qat")
                client.engine = .local(kind: .ollama, endpoint: env["TLM_LOCAL_ENDPOINT"] ?? "http://localhost:11434", model: env["TLM_LOCAL_MODEL"] ?? "gemma4:e4b-it-qat")
                var t0 = Date()
                let t = try await client.transcribe(samples: samples, model: "saaras:v3", language: "unknown", mode: .transcribe)
                print("stt  [\(ms(t0))]: \(t.text)  (\(t.language))")
                t0 = Date()
                let p = try await client.polish(t.text, style: .clean, context: CursorContext(before: nil, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap"), vocabulary: ["Saynori"])
                print("polish [\(ms(t0))]: \(p)")
                print("local fallback: \(Cleanup.local(t.text))")
                print("SELFTEST OK")
                exit(0)
            } catch {
                print("SELFTEST FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
        sem.wait()
        exit(0)
    }

    static func format(_ a: [String]) -> Never {
        Task.detached {
            let ctx = CursorContext(before: a.count > 1 && a[1] != "-" ? a[1] : nil, appName: a.count > 2 ? a[2] : "", bundleID: a.count > 3 ? a[3] : "")
            var client = SarvamClient(apiKey: AppSettings.loadAPIKey())
            client.keys = KeyStore.load()
            // TLM_ENGINE picks the formatter ("local" = Gemma; TLM_LOCAL_MODEL / TLM_LOCAL_ENDPOINT override the defaults).
            let env = ProcessInfo.processInfo.environment
            client.formatter = env["TLM_ENGINE"] == "local" ? .gemma : Provider(rawValue: env["TLM_ENGINE"] ?? "") ?? .sarvam
            if client.formatter == .gemma {
                client.engine = .local(kind: .ollama, endpoint: env["TLM_LOCAL_ENDPOINT"] ?? "http://localhost:11434",
                                       model: env["TLM_LOCAL_MODEL"] ?? "gemma4:e4b-it-qat")
            }
            do {
                let t0 = Date()
                let p = SarvamClient.isAITool(ctx)
                    ? try await client.promptify(a[0], context: ctx, vocabulary: Store.shared.vocabulary)
                    : try await client.polish(a[0], style: .clean, context: ctx, vocabulary: Store.shared.vocabulary)
                let joined = SmartJoin.apply(QuestionFix.apply(p), before: ctx.before, adjustCase: false)
                print("[\(ms(t0))] \((ctx.before ?? "") + joined)")
            } catch { print("ERR \(error)") }
            exit(0)
        }
        while true { RunLoop.main.run() }
    }

    static func ms(_ d: Date) -> String { "\(Int(Date().timeIntervalSince(d) * 1000)) ms" }
}

enum LocalScore {
    static let bundles = ["Terminal": "com.apple.Terminal", "Zed": "dev.zed.Zed", "ChatGPT": "com.openai.chat",
                          "\u{200e}WhatsApp": "net.whatsapp.WhatsApp", "Slack": "com.tinyspeck.slackmacgap",
                          "Notes": "com.apple.Notes", "TextEdit": "com.apple.TextEdit", "Arc": "company.thebrowser.Browser"]

    static func run(_ a: [String]) -> Never {
        let path = a.first ?? AppSettings.supportDir.appendingPathComponent("library.json").path
        let show = a.count > 1 ? Int(a[1]) ?? 0 : 0
        struct Lib: Decodable { let history: [Dictation] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let lib = try? dec.decode(Lib.self, from: Data(contentsOf: URL(fileURLWithPath: path))) else { print("can't read \(path)"); exit(1) }
        let items = lib.history.filter { !$0.isCommand && !$0.raw.isEmpty }
        var rawSim = 0.0, outSim = 0.0, rawExact = 0, outExact = 0, better = 0, worse = 0
        var worst: [(Double, Dictation, String)] = []
        let t0 = Date()
        var outputs: [String] = []
        for d in items {
            let ctx = CursorContext(before: nil, appName: d.app, bundleID: bundles[d.app] ?? "")
            outputs.append(LocalFormatter.format(d.raw, context: ctx, vocabulary: Store.shared.vocabulary))
        }
        let elapsed = Date().timeIntervalSince(t0)
        for (d, out) in zip(items, outputs) {
            let target = words(d.text), r = sim(words(d.raw), target), o = sim(words(out), target)
            rawSim += r; outSim += o
            if words(d.raw) == target { rawExact += 1 }
            if words(out) == target { outExact += 1 }
            if o > r + 0.001 { better += 1 } else if o < r - 0.001 { worse += 1; worst.append((r - o, d, out)) }
        }
        let n = Double(items.count)
        print("dictations: \(items.count)   time: \(String(format: "%.1f", elapsed * 1000)) ms total, \(String(format: "%.3f", elapsed * 1000 / n)) ms each")
        print(String(format: "word match with AI formatter:  raw %.1f%%  ->  instant %.1f%%", rawSim / n * 100, outSim / n * 100))
        print(String(format: "identical words to AI output:  raw %.1f%%  ->  instant %.1f%%", Double(rawExact) / n * 100, Double(outExact) / n * 100))
        print("closer to AI: \(better)   further from AI: \(worse)   unchanged: \(items.count - better - worse)")
        for (loss, d, out) in worst.sorted(by: { $0.0 > $1.0 }).prefix(show) {
            print("\n--- worse by \(String(format: "%.2f", loss)) [\(d.app)]\nRAW: \(d.raw)\nNEW: \(out)\nAI:  \(d.text)")
        }
        exit(0)
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted).filter { !$0.isEmpty }
    }

    /// Word-level similarity: 2 × LCS / (a + b).
    static func sim(_ a: [String], _ b: [String]) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        var prev = [Int](repeating: 0, count: b.count + 1), cur = prev
        for x in a {
            for (j, y) in b.enumerated() { cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j]) }
            swap(&prev, &cur)
        }
        return 2 * Double(prev[b.count]) / Double(a.count + b.count)
    }
}

enum FormatterTests {
    static let apps = ["plain": "com.apple.TextEdit", "zed": "dev.zed.Zed", "terminal": "com.apple.Terminal", "chatgpt": "com.openai.chat",
                       "mail": "com.apple.mail", "slack": "com.tinyspeck.slackmacgap", "notes": "com.apple.Notes"]
    struct Case: Decodable { let app: String; let input: String; let expect: String; let note: String }

    /// The same steps the app runs after speech when no AI formatter is used.
    static func pipeline(_ raw: String, bundle: String, appName: String = "", vocabulary: [String] = []) -> String {
        let ctx = CursorContext(before: nil, appName: appName, bundleID: bundle)
        return QuestionFix.apply(LocalFormatter.format(raw, context: ctx, vocabulary: vocabulary))
    }

    static func run(_ args: [String]) -> Never {
        let path = args.first { !$0.hasPrefix("--") } ?? "Tests/formatter-cases.json"
        guard let data = FileManager.default.contents(atPath: path), let cases = try? JSONDecoder().decode([Case].self, from: data) else {
            print("can't read \(path)"); exit(2)
        }
        func show(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "⏎") }
        var failed = 0
        let t0 = Date()
        for c in cases {
            let bundle = apps[c.app] ?? c.app
            let out = pipeline(c.input, bundle: bundle)
            let again = pipeline(out, bundle: bundle)
            if out != c.expect || again != out {
                failed += 1
                print("✗ [\(c.app)] \(c.note)\n    in:     \(show(c.input))\n    expect: \(show(c.expect))\n    got:    \(show(out))")
                if again != out { print("    again:  \(show(again))   (not idempotent)") }
            }
        }
        let ms = Date().timeIntervalSince(t0) * 1000 / Double(max(cases.count, 1)) / 2
        print("\(cases.count - failed)/\(cases.count) cases pass  (\(String(format: "%.2f", ms)) ms per dictation)")

        if args.contains("--history") { audit() }
        exit(failed == 0 ? 0 : 1)
    }

    /// Every saved dictation: formatting twice must change nothing, and no real word may disappear.
    static func audit() {
        struct Lib: Decodable { let history: [Dictation] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let url = AppSettings.supportDir.appendingPathComponent("library.json")
        guard let lib = try? dec.decode(Lib.self, from: Data(contentsOf: url)) else { print("no history"); return }
        let vocab = Store.shared.vocabulary
        let allowed: Set<String> = ["um", "uh", "umm", "uhh", "erm", "er", "ah", "hmm", "mmm", "mm", "uhm", "bro", "dude", "yaar", "bhai",
                                    "new", "line", "paragraph", "question", "mark", "exclamation", "point", "full", "stop", "dot", "at",
                                    "the", "rate", "of", "you", "know", "i", "mean", "and", "then", "one", "is", "thing", "first", "second",
                                    "third", "fourth", "fifth", "sixth", "firstly", "secondly", "thirdly", "finally", "lastly", "percent",
                                    "dollars", "rupees", "per", "cent", "k", "x", "a", "p", "m", "am", "pm"]
        let numberWords: Set<String> = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                                        "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
                                        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
                                        "thousand", "million", "billion", "point", "oh", "and"]
        let cue = try! NSRegularExpression(pattern: #"(?i)\b(scratch(ed)? (that|at|this)|strike that|delete that|no,? wait|wait,? no|sorry,? i mean|i mean,? sorry|or rather|i meant|make that)\b"#)
        let heardWords = Terms.heardWords
        var notIdempotent = 0, dropping = 0, checked = 0
        var examples: [String] = []
        for d in lib.history where !d.isCommand && !d.raw.isEmpty {
            let bundle = LocalScore.bundles[d.app] ?? ""
            let out = pipeline(d.raw, bundle: bundle, appName: d.app, vocabulary: vocab)
            checked += 1
            let again = pipeline(out, bundle: bundle, appName: d.app, vocabulary: vocab)
            if again != out {
                notIdempotent += 1
                let a = Array(out), b = Array(again)
                let p = zip(a, b).prefix { $0 == $1 }.count
                if examples.count < 12 { examples.append("NOT IDEMPOTENT [\(d.app)] at …\(String(a[max(0, p - 60)..<min(a.count, p + 40)]))\n   second pass: …\(String(b[max(0, p - 60)..<min(b.count, p + 40)]))") }
            }
            if cue.firstMatch(in: d.raw, range: NSRange(location: 0, length: (d.raw as NSString).length)) != nil { continue }
            let have = LocalScore.words(out)
            let haveSet = Set(have)
            let digits = out.contains(where: \.isNumber)
            let gone = Set(LocalScore.words(d.raw)).filter { w in
                if haveSet.contains(w) || allowed.contains(w) || heardWords.contains(w) { return false }
                if digits && numberWords.contains(w) { return false }
                // Re-spelled terms ("superbase" → "supabase", "use" + "effect" → "useeffect").
                return !have.contains { $0.contains(w) || (w.count >= 4 && Terms.distance($0, w) <= 2) }
            }
            if !gone.isEmpty {
                dropping += 1
                if examples.count < 24 { examples.append("DROPPED \(gone.sorted()) [\(d.app)]\n  RAW: \(d.raw)\n  OUT: \(out)") }
            }
        }
        print("history: \(checked) dictations, \(notIdempotent) not idempotent, \(dropping) dropped a word")
        for e in examples { print(e) }
    }
}

enum Bench {
    static func run(engine: String, path: String, runs: Int) -> Never {
        Task.detached {
            guard let samples = wav(path) else { print("can't read 16 kHz mono 16-bit WAV at \(path)"); exit(1) }
            let audio = Double(samples.count) / 16_000
            let base = footprint(), c0 = cpuTime(), t0 = Date()
            do {
                switch engine {
                case "parakeet": try await ParakeetEngine.shared.prepare()
                case "whistle": try await WhistleEngine.shared.prepare()
                default: print("engine: parakeet | whistle"); exit(2)
                }
            } catch { print("load failed: \(error)"); exit(1) }
            let loadTime = Date().timeIntervalSince(t0), loadCPU = cpuTime() - c0, loaded = footprint()

            var text = ""
            let c1 = cpuTime(), t1 = Date()
            for _ in 0..<runs {
                text = (try? await (engine == "parakeet"
                    ? ParakeetEngine.shared.transcribe(samples)
                    : WhistleEngine.shared.transcribe(samples, language: "en", keyterms: []))) ?? ""
            }
            let wall = Date().timeIntervalSince(t1) / Double(runs), cpu = (cpuTime() - c1) / Double(runs)
            let working = footprint(), peak = peakFootprint()

            let ctx = CursorContext(before: nil, appName: "Zed", bundleID: "dev.zed.Zed")
            _ = LocalFormatter.format(text, context: ctx, vocabulary: [])
            let c2 = cpuTime(), t2 = Date()
            for _ in 0..<100 { _ = LocalFormatter.format(text, context: ctx, vocabulary: []) }
            let fmtWall = Date().timeIntervalSince(t2) / 100, fmtCPU = (cpuTime() - c2) / 100

            func mb(_ v: Double) -> String { String(format: "%.0f MB", v) }
            func ms(_ v: Double) -> String { String(format: "%.0f ms", v * 1000) }
            print("engine            \(engine)   (\(String(format: "%.1f", audio)) s of speech, \(runs) runs)")
            print("load              \(ms(loadTime)) wall, \(ms(loadCPU)) CPU")
            print("per dictation     \(ms(wall)) wall, \(ms(cpu)) CPU  (\(String(format: "%.0f", cpu / wall * 100))% of one core while it runs)")
            print("instant format    \(String(format: "%.2f", fmtWall * 1000)) ms wall, \(String(format: "%.2f", fmtCPU * 1000)) ms CPU")
            print("memory            before load \(mb(base)), loaded \(mb(loaded)), after runs \(mb(working)), peak \(mb(peak))")
            print("engine adds       \(mb(working - base)) resident")
            print("text              \(text)")
            exit(0)
        }
        while true { RunLoop.main.run() }
    }

    /// 16-bit mono PCM samples from a WAV file (any chunk layout).
    static func wav(_ path: String) -> [Int16]? {
        guard let d = FileManager.default.contents(atPath: path), d.count > 12 else { return nil }
        var i = 12
        while i + 8 <= d.count {
            let id = String(decoding: d[i..<i + 4], as: UTF8.self)
            let size = Int(d[i + 4]) | Int(d[i + 5]) << 8 | Int(d[i + 6]) << 16 | Int(d[i + 7]) << 24
            if id == "data" {
                let body = d[(i + 8)..<min(d.count, i + 8 + size)]
                return body.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            }
            i += 8 + size + (size & 1)
        }
        return nil
    }

    static func cpuTime() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info : nil
    }
    static func footprint() -> Double { Double(vmInfo()?.phys_footprint ?? 0) / 1_048_576 }
    static func peakFootprint() -> Double { Double(vmInfo()?.ledger_phys_footprint_peak ?? 0) / 1_048_576 }
}
