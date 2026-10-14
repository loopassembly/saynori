import AppKit
import Combine

/// Orchestrates hotkey → record → Sarvam → format → paste, and exposes UI state for the pill.
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case processing
        case done(String)
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var handsFree = false
    @Published private(set) var commandMode = false
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 24)
    @Published private(set) var startedAt: Date?
    /// True once the text has actually been pasted (it lands after the words form in the pill).
    @Published private(set) var pasted = false
    /// A dictation the card is showing: either it had nowhere to go (and is on the clipboard),
    /// or it was pasted somewhere we couldn't verify (the card offers Copy just in case).
    struct Unplaced: Equatable {
        var text: String
        var pastedInto: String?   // nil = not pasted
    }
    @Published private(set) var unplaced: Unplaced?
    private var unplacedWork: DispatchWorkItem?

    let settings = AppSettings.shared
    let store = Store.shared
    let hotkeys = HotkeyMonitor()
    private let recorder = AudioRecorder()

    private var downAt = Date.distantPast
    private var lastVoiceAt = Date()
    private var heardVoice = false
    private var context: CursorContext?
    private var resetWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var currentTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Called just before text is pasted, so the UI can fly particles to the caret.
    /// Returns how long to wait before pasting (0 when there's nothing to animate).
    var onDeliver: ((CursorContext) -> TimeInterval)?

    /// Presses shorter than this are taps (toggle hands-free); longer is push-to-talk.
    private let tapThreshold: TimeInterval = 0.28
    /// How long after a quick press we wait for the second press of a double-press.
    private let doubleTapWindow: TimeInterval = 0.35
    private var awaitingSecondTap = false
    private var tapTimer: Timer?

    init() {
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            if level > 0.3 { self.lastVoiceAt = Date(); self.heardVoice = true }
            let last = self.levels.last ?? 0
            let v = level > last ? last * 0.3 + level * 0.7 : last * 0.55 + level * 0.45
            self.levels.removeFirst()
            self.levels.append(v)
        }
        hotkeys.trigger = settings.trigger
        hotkeys.onEvent = { [weak self] e in
            DispatchQueue.main.async { self?.handle(e) }
        }
        settings.$trigger.sink { [weak self] t in self?.hotkeys.trigger = t }.store(in: &cancellables)
        settings.$recordingTrigger.sink { [weak self] r in self?.hotkeys.paused = r }.store(in: &cancellables)
    }

    func start() {
        hotkeys.start()
        SarvamClient.warmUp()
        Log.write("launch trusted=\(TextInserter.isTrusted) mic=\(AudioRecorder.hasPermission) trigger=\(settings.trigger.rawValue) fnUsage=\(Permissions.readFnUsage())")
    }

    var isListening: Bool { phase == .listening }
    /// Where the text cursor was when this dictation started (global Cocoa coordinates).
    var caretRect: CGRect? { context?.caret }
    var isProcessing: Bool { phase == .processing }

    // MARK: Hotkey
    //  hold trigger          → push-to-talk, release to paste
    //  single quick press    → nothing (so a stray press never starts hands-free)
    //  double-press trigger  → hands-free; press once more to paste
    //  + ⌃ control while on  → command mode (rewrite the selection, or write something new)
    //  esc                   → cancel

    private func handle(_ e: HotkeyMonitor.Event) {
        switch e {
        case .triggerDown:
            Log.write("trigger down phase=\(phase) handsFree=\(handsFree)")
            if isListening {
                if awaitingSecondTap {
                    // Second press of a double-press: hands-free. Recording has been running since the first.
                    awaitingSecondTap = false
                    tapTimer?.invalidate()
                    handsFree = true
                    Log.write("double-press → hands-free")
                } else if handsFree {
                    finish(reason: "press in hands-free")
                }
            } else if !isProcessing {
                downAt = Date()
                begin()
            }
        case .triggerUp:
            guard isListening, !handsFree, !awaitingSecondTap else { return }
            let held = Date().timeIntervalSince(downAt)
            if held < tapThreshold {
                // A quick press: only counts if a second one follows (double-press = hands-free).
                awaitingSecondTap = true
                tapTimer?.invalidate()
                tapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.awaitingSecondTap else { return }
                        self.awaitingSecondTap = false
                        Log.write("single quick press: ignored (hold to talk, double-press for hands-free)")
                        self.cancel(silent: true)
                    }
                }
            } else {
                finish(reason: "release after \(String(format: "%.2f", held))s")
            }
        case .controlPressed:
            if isListening { commandMode = true }
        case .escape:
            if isListening || isProcessing { cancel(silent: false) }
        case .pasteLast:
            pasteLast()
        case .userPaste:
            // They pasted it themselves; the card has done its job.
            if unplaced != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.dismissUnplaced() } }
        case .otherKey:
            // Typing again means the paste landed; the soft note isn't needed.
            if unplaced?.pastedInto != nil, !isListening { dismissUnplaced() }
            // The trigger was used as a normal modifier (fn+←, fn+delete…): stay out of the way.
            if isListening, !handsFree, Date().timeIntervalSince(downAt) < 1.0 {
                Log.write("chord detected, cancelling")
                cancel(silent: true)
            }
        }
    }

    /// From the menu bar or a click on the pill.
    func toggleHandsFree() {
        if isListening { finish(reason: "click"); return }
        guard !isProcessing else { return }
        downAt = Date()
        begin()
        if isListening { handsFree = true }
    }

    // MARK: Nowhere to paste

    /// Copies the text to the clipboard (and leaves it there) and shows the card.
    func keepUnplaced(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(clean, forType: .string)
        pasted = true
        unplaced = Unplaced(text: clean, pastedInto: nil)
        Log.write("no text field focused: kept \(clean.split(separator: " ").count) words on the clipboard")
        unplacedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissUnplaced() }
        unplacedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: work)
    }

    /// After a paste we couldn't verify: a quiet "didn't land?" note with Copy. Clipboard untouched.
    func offerCopy(_ text: String, pastedInto app: String) {
        unplaced = Unplaced(text: text.trimmingCharacters(in: .whitespacesAndNewlines), pastedInto: app.isEmpty ? "the app" : app)
        unplacedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissUnplaced() }
        unplacedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// Preview only: shows the card without touching the clipboard.
    func keepUnplacedPreview(_ text: String, pastedInto: String? = nil) {
        unplaced = Unplaced(text: text, pastedInto: pastedInto)
    }

    func dismissUnplaced() {
        unplacedWork?.cancel()
        unplaced = nil
    }

    /// Keeps the card up while the pointer is on it.
    func holdUnplaced(_ hovering: Bool) {
        unplacedWork?.cancel()
        guard !hovering, unplaced != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismissUnplaced() }
        unplacedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// ⌃⌘V: put the last dictation where the cursor is now (or back on the card if there's no field).
    func pasteLast() {
        guard !isListening, !isProcessing, let last = store.history.first else { return }
        Log.write("paste last dictation (⌃⌘V)")
        if TextTarget.current() == .no || (TextTarget.current() == .unknown && TextTarget.pasteMenuEnabled() == false) {
            keepUnplaced(last.text)
        } else {
            dismissUnplaced()
            TextInserter.insert(last.text)
        }
    }

    // MARK: Preview (visual check only: no mic, no hotkey, never pastes)

    private var demoTimer: Timer?

    func runPillDemo(text: String) {
        phase = .listening
        startedAt = Date()
        let t0 = Date()
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let t = Date().timeIntervalSince(t0)
                if t < 3.0 {
                    // Speech-like envelope: syllables riding on phrases.
                    let v = max(0, sin(t * 2.1) * 0.5 + 0.35) * (0.55 + 0.45 * abs(sin(t * 11.0)))
                    self.levels.removeFirst(); self.levels.append(Float(min(1, v)))
                } else if t < 3.9 {
                    if self.phase != .processing { self.phase = .processing }
                } else if t < 3.9 + PixelTiming.lead + Double(PixelTiming.lift) {
                    if case .done = self.phase {} else { self.pasted = false; self.phase = .done(text) }
                } else if t < 6.5 {
                    if self.phase != .idle { self.phase = .idle }
                } else {
                    self.demoTimer?.invalidate()
                    self.runPillDemo(text: text)
                }
            }
        }
    }

    // MARK: Pipeline

    private func begin() {
        guard AudioRecorder.hasPermission else {
            AudioRecorder.requestPermission { _ in }
            flash(.error("Allow microphone access in Settings"))
            return
        }
        if let p = settings.missingKey {
            flash(.error("Add your \(p.name) API key in Settings"))
            return
        }
        resetWork?.cancel()
        handsFree = false
        commandMode = false
        heardVoice = false
        lastVoiceAt = Date()
        levels = Array(repeating: 0, count: levels.count)
        do {
            try recorder.start()
        } catch {
            Log.write("recorder failed: \(error)")
            flash(.error("Microphone unavailable"))
            return
        }
        startedAt = Date()
        // Read the cursor context first, while the target app is still focused (the bar uses the caret to dodge it).
        context = CursorContext.capture()
        phase = .listening
        Sound.play(.start)
        if settings.speechProvider == .sarvam || settings.formatProvider == .sarvam { SarvamClient.warmUp() }
        // Load the local model while you talk, so formatting doesn't wait for a cold start.
        if case let .local(kind, endpoint, model) = settings.chatEngine { LocalLLM.warmUp(kind: kind, endpoint: endpoint, model: model) }
        else if let speech = settings.localSpeech { LocalLLM.warmUp(kind: .ollama, endpoint: speech.endpoint, model: speech.model) }
        Log.write("listening in \(context?.appName ?? "?") before=\(context?.before.map { "\($0.count) chars" } ?? "n/a")")

        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Auto-stops forgotten hands-free sessions and very long takes.
    private func tick() {
        guard isListening, let startedAt else { return }
        let silence = Date().timeIntervalSince(lastVoiceAt)
        if handsFree && !heardVoice && silence > 8 { cancel(silent: false, message: "No speech detected"); return }
        if handsFree && heardVoice && silence > 45 { finish(reason: "silence"); return }
        if Date().timeIntervalSince(startedAt) > 600 { finish(reason: "10 min limit") }
    }

    func cancel(silent: Bool, message: String = "Cancelled") {
        watchdog?.invalidate()
        awaitingSecondTap = false
        tapTimer?.invalidate()
        recorder.stop()
        currentTask?.cancel()
        handsFree = false
        commandMode = false
        startedAt = nil
        Log.write("cancel: \(message)")
        if silent { phase = .idle } else { Sound.play(.cancel); flash(.error(message)) }
    }

    private func finish(reason: String) {
        watchdog?.invalidate()
        awaitingSecondTap = false
        tapTimer?.invalidate()
        let samples = recorder.stop()
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        let isCommand = commandMode
        handsFree = false
        startedAt = nil
        Log.write("finish (\(reason)) duration=\(String(format: "%.2f", duration))s")

        guard duration >= 0.3, !WAV.isSilent(samples) else {
            flash(.error("No speech detected"))
            return
        }
        phase = .processing
        Sound.play(.stop)

        let client = settings.client()
        let canFormat = settings.formatProvider != nil
        let s = settings
        let ctx = context ?? CursorContext(before: nil, appName: "", bundleID: "")
        let vocab = store.vocabulary
        let t0 = Date()

        currentTask = Task { [weak self] in
            do {
                // v4 hears names and jargon better (keyterms); translate/romanised output needs v3.
                let model = s.outputMode == .transcribe ? s.sttModel : "saaras:v3"
                let terms = vocab + (SarvamClient.isAITool(ctx) ? SarvamClient.devTerms : [])
                let t = try await client.transcribe(samples: samples, model: model, language: s.language, mode: s.outputMode, keyterms: terms)
                guard !Task.isCancelled else { return }
                let raw = Cleanup.dropNoise(t.text)
                guard !raw.isEmpty else { throw SarvamError.empty }
                let sttMs = Int(Date().timeIntervalSince(t0) * 1000)

                var output: String
                if isCommand {
                    guard canFormat else {
                        throw NSError(domain: "TypeLikeMe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Command mode needs a formatting engine"])
                    }
                    let selection = await TextInserter.copySelection()
                    output = try await client.command(instruction: raw, selection: selection)
                } else if let expansion = self?.store.expandSnippet(raw) {
                    output = expansion
                } else if canFormat, s.promptMode, SarvamClient.isAITool(ctx), raw.split(separator: " ").count > 2 {
                    do {
                        output = try await client.promptify(raw, context: ctx, vocabulary: vocab)
                        Log.write("prompt mode (\(ctx.appName))")
                    } catch {
                        Log.write("prompt mode failed: \(error)")
                        output = LocalFormatter.format(raw, context: ctx, vocabulary: vocab)
                    }
                } else if canFormat, s.polish != .off, raw.split(separator: " ").count > 2 {
                    do {
                        output = try await client.polish(raw, style: s.polish, context: s.contextAware ? ctx : CursorContext(before: ctx.before, appName: "", bundleID: ""), vocabulary: vocab, smart: s.smartFormat)
                    } catch {
                        Log.write("polish failed: \(error)")
                        output = LocalFormatter.format(raw, context: ctx, vocabulary: vocab)
                    }
                } else {
                    output = LocalFormatter.format(raw, context: ctx, vocabulary: vocab)
                }
                guard !Task.isCancelled else { return }
                if !isCommand {
                    output = QuestionFix.apply(output)
                    output = SmartJoin.apply(output, before: ctx.before, adjustCase: s.polish == .off)
                }
                let final = output
                Log.write("done speech=\(s.speechProvider.rawValue) format=\(s.formatProvider?.rawValue ?? "off") stt=\(sttMs)ms total=\(Int(Date().timeIntervalSince(t0) * 1000))ms words=\(final.split(separator: " ").count)")

                await MainActor.run {
                    guard let self else { return }
                    self.pasted = false
                    // Nothing to type into (Finder, the Dock, a list, or the app says Paste is disabled):
                    // keep the text safe instead of pasting into nowhere.
                    let target = TextTarget.current()
                    let pasteEnabled = target == .unknown ? TextTarget.pasteMenuEnabled() : nil
                    Log.write("delivery target=\(target) pasteMenu=\(pasteEnabled.map { "\($0)" } ?? "n/a") app=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                    if target == .no || pasteEnabled == false {
                        let wait = s.particles ? PixelTiming.lead : 0
                        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.keepUnplaced(final) }
                        self.store.add(Dictation(date: Date(), raw: t.text, text: final.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 app: ctx.appName, duration: duration, language: t.language, isCommand: isCommand))
                        self.flash(.done(final.trimmingCharacters(in: .whitespacesAndNewlines)))
                        return
                    }
                    let wait = self.onDeliver?(ctx) ?? 0
                    // Only when neither the focused element nor the app's Paste command could be read
                    // do we have no idea where it went; an enabled Paste command means it lands.
                    let unverified = target == .unknown && pasteEnabled == nil
                    let deliver = {
                        TextInserter.insert(final)
                        self.pasted = true
                        // We couldn't confirm there's a text field: offer Copy for a moment, just in case.
                        if unverified { self.offerCopy(final, pastedInto: ctx.appName) }
                    }
                    if wait > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: deliver)
                    } else {
                        deliver()
                    }
                    self.store.add(Dictation(date: Date(), raw: t.text, text: final.trimmingCharacters(in: .whitespacesAndNewlines),
                                             app: ctx.appName, duration: duration, language: t.language, isCommand: isCommand))
                    self.flash(.done(final.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            } catch {
                guard !Task.isCancelled else { return }
                Log.write("pipeline error: \(error)")
                await MainActor.run {
                    Sound.play(.cancel)
                    self?.flash(.error(SarvamError.describe(error)))
                }
            }
        }
    }

    private func flash(_ p: Phase) {
        phase = p
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isListening, !self.isProcessing else { return }
            self.phase = .idle
        }
        resetWork = work
        let delay: Double = {
            if case .error = p { return 2.6 }
            // With the pixel sequence, close as soon as the letters have lifted off.
            if case .done = p, settings.particles { return PixelTiming.lead + Double(PixelTiming.lift) + 0.08 }
            return 1.6
        }()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

enum Cleanup {
    /// Offline fallback when the LLM polish is unavailable.
    static func local(_ s: String) -> String {
        var t = dropNoise(s)
        let fillers = #"(?i)\b(um+|uh+|erm|er|ah|hmm+)\b[,.]?\s*"#
        t = t.replacingOccurrences(of: fillers, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = t.first, f.isLowercase { t = f.uppercased() + t.dropFirst() }
        return t
    }

    /// Strips transcripts that are only noise markers or stray punctuation.
    static func dropNoise(_ s: String) -> String {
        let t = s.replacingOccurrences(of: #"\[(noise|music|silence|inaudible)\]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.allSatisfy { $0.isPunctuation || $0.isWhitespace } ? "" : t
    }
}

enum Sound {
    enum Kind { case start, stop, cancel }
    static func play(_ k: Kind) {
        guard AppSettings.shared.sounds else { return }
        let name: String
        switch k {
        case .start: name = "Tink"
        case .stop: name = "Pop"
        case .cancel: name = "Funk"
        }
        guard let s = NSSound(named: name)?.copy() as? NSSound else { return }
        s.volume = 0.22
        s.play()
    }
}
