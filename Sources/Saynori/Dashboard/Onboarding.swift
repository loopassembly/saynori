import AppKit
import SwiftUI

/// First-run flow: engine → download → microphone → accessibility → dictation key → try it → Home.
struct OnboardingView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var perms: Permissions
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: Store

    enum Step: Int, CaseIterable {
        case engine, download, microphone, accessibility, key, tryIt
        var title: String {
            switch self {
            case .engine: return "Choose an engine"
            case .download: return "Get it ready"
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .key: return "Dictation key"
            case .tryIt: return "Try it out"
            }
        }
    }

    @State private var step: Step = .engine
    @State private var keyVerified: Set<String> = []
    @StateObject private var loader = ModelLoader()
    @StateObject private var formatLoader = ModelLoader()

    var body: some View {
        HStack(spacing: 0) {
            rail.frame(width: 232)
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(spacing: 0) {
                ScrollView {
                    content
                        .padding(.horizontal, 36).padding(.top, 52).padding(.bottom, 24)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                Divider1()
                footer
            }
            .background(Theme.canvas)
        }
        .foregroundStyle(Theme.text)
        .font(.system(size: 13))
        .tint(Theme.accent)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                BrandMark(size: 22)
                Text("Saynori").font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.top, 46).padding(.bottom, 18)
            ForEach(Step.allCases, id: \.self) { s in
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(s.rawValue < step.rawValue ? Theme.green.opacity(0.18) : (s == step ? Theme.accent : Theme.raised))
                        if s.rawValue < step.rawValue {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.green)
                        } else {
                            Text("\(s.rawValue + 1)").font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(s == step ? Color.white : Theme.tertiary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(s.title).foregroundStyle(s == step ? Theme.text : (s.rawValue < step.rawValue ? Theme.secondary : Theme.tertiary))
                    Spacer()
                }
                .padding(.horizontal, 8).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(s == step ? Theme.hover : .clear))
            }
            Spacer()
            Text("Everything here can be changed later in Settings.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).padding(8)
        }
        .padding(.horizontal, 10).padding(.bottom, 12)
        .background(Theme.sidebar)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .engine {
                Button("Back") { go(Step(rawValue: step.rawValue - 1)!) }.buttonStyle(ActionButtonStyle())
            }
            Spacer()
            if let hint = blocker {
                Text(hint).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            if step == .tryIt {
                Button("Finish") { finish() }.buttonStyle(ActionButtonStyle(prominent: true))
            } else {
                Button("Continue") { go(Step(rawValue: step.rawValue + 1)!) }
                    .buttonStyle(ActionButtonStyle(prominent: true))
                    .disabled(blocker != nil)
            }
        }
        .padding(.horizontal, 24).frame(height: 60)
        .background(Theme.canvas)
    }

    /// Why Continue is disabled on this step, if it is.
    private var blocker: String? {
        switch step {
        case .engine:
            if let p = settings.missingKey { return "Add your \(p.name) key" }
            let speech = settings.speechProvider
            if speech.needsKey, !keyVerified.contains(speech.rawValue) { return "Check the key first" }
            if let f = settings.formatProvider, f.needsKey, !keyVerified.contains(f.rawValue) { return "Check the \(f.name) key first" }
            return nil
        case .download:
            if !loader.isReady { return "Waiting for \(settings.speechProvider.name)" }
            if settings.formatProvider == .gemma, settings.speechProvider != .gemma, !formatLoader.isReady { return "Waiting for Gemma" }
            return nil
        case .microphone: return perms.mic ? nil : "Allow the microphone to continue"
        case .accessibility: return perms.accessibility ? nil : "Turn on Accessibility to continue"
        case .key: return perms.fnReady ? nil : "Stop fn opening the emoji picker"
        case .tryIt: return nil
        }
    }

    private func go(_ s: Step) {
        step = s
        if s == .download { prepareDownload() }
    }

    private func prepareDownload() {
        loader.load(settings.speechProvider, settings: settings)
        if settings.formatProvider == .gemma, settings.speechProvider != .gemma { formatLoader.load(.gemma, settings: settings) }
    }

    private func finish() {
        settings.onboarded = true
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .engine: engineStep
        case .download: downloadStep
        case .microphone: microphoneStep
        case .accessibility: accessibilityStep
        case .key: keyStep
        case .tryIt: TryItStep(controller: controller, settings: settings, store: store)
        }
    }

    private func header(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("How should Saynori hear you?",
                   "Pick a cloud provider with your own API key, or a model that runs entirely on this Mac.")
            group("On this Mac", "Private, free, works offline", Provider.local)
            group("Cloud", "Your own API key. Audio goes to the provider you pick", Provider.cloud)

            let speech = settings.speechProvider
            if speech.needsKey {
                Panel {
                    ProviderKeyField(provider: speech, settings: settings) { ok in
                        if ok { keyVerified.insert(speech.rawValue) } else { keyVerified.remove(speech.rawValue) }
                    }
                }
            }
            Panel {
                VStack(spacing: 0) {
                    SettingRow(title: "Formatting", detail: formatDetail) { FormatEnginePicker(settings: settings) }
                    if let f = settings.formatProvider, f.needsKey, f != speech {
                        Divider1()
                        ProviderKeyField(provider: f, settings: settings) { ok in
                            if ok { keyVerified.insert(f.rawValue) } else { keyVerified.remove(f.rawValue) }
                        }
                    }
                }
            }
        }
    }

    private var formatDetail: String {
        guard let f = settings.formatProvider else {
            return "Off: you get exactly what you said, lightly tidied. Pick an engine for clean text, lists, Prompt mode and command mode."
        }
        return f == .gemma ? "Gemma formats on this Mac (needs Ollama)." : "\(f.name) cleans up text, makes lists and writes prompts for AI tools."
    }

    private func group(_ title: String, _ detail: String, _ providers: [Provider]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(providers) { card($0) }
            }
        }
    }

    private func card(_ p: Provider) -> some View {
        let on = settings.speechProvider == p
        return Button { settings.choose(p) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(p.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: on ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(on ? Theme.accent : Theme.tertiary)
                }
                Text(p.blurb).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    chip("Speech")
                    if p.canFormat { chip("Formatting") }
                    if let d = p.download { chip(d) }
                }
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(on ? Theme.hover : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(on ? Theme.accent.opacity(0.7) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 6).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.raised))
    }

    private var downloadStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(settings.speechProvider.isLocal ? "Downloading \(settings.speechProvider.name)" : "Connected to \(settings.speechProvider.name)",
                   settings.speechProvider.isLocal
                       ? "The model is saved on this Mac and loaded once. After this, dictation works offline."
                       : "Your key works and there's nothing to download.")
            Panel(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    loaderRow(settings.speechProvider, loader)
                    if settings.formatProvider == .gemma, settings.speechProvider != .gemma {
                        Divider1()
                        loaderRow(.gemma, formatLoader)
                    }
                }
            }
        }
        .onAppear(perform: prepareDownload)
    }

    private func loaderRow(_ p: Provider, _ l: ModelLoader) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(p.name).font(.system(size: 13, weight: .semibold))
                if let d = p.download { Text(d).font(.system(size: 12)).foregroundStyle(Theme.tertiary) }
                Spacer()
                if l.state.isFailure {
                    Button("Retry") { l.retry(p, settings: settings) }.buttonStyle(ActionButtonStyle())
                }
            }
            ModelLoaderStatus(loader: l)
            if p == .gemma, l.state.isFailure {
                HStack(spacing: 8) {
                    Text("Install Ollama from ollama.com, then run `ollama pull \(settings.localModel)`")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("ollama pull \(settings.localModel)", forType: .string)
                    }
                    .buttonStyle(ActionButtonStyle())
                }
            }
        }
    }

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Let Saynori hear you", "The microphone is only on while you hold the dictation key. Nothing is recorded otherwise.")
            permissionCard(granted: perms.mic, icon: "mic.fill", title: "Microphone",
                           action: "Allow microphone") { perms.requestMic() }
        }
        .onChange(of: perms.mic) { _, ok in if ok { go(.accessibility) } }
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Let Saynori type for you",
                   "Accessibility lets the app notice the dictation key in any app and paste text at your cursor. Turn on Saynori in the list that opens.")
            permissionCard(granted: perms.accessibility, icon: "accessibility", title: "Accessibility",
                           action: "Open System Settings") { perms.requestAccessibility() }
        }
        .onChange(of: perms.accessibility) { _, ok in
            if ok {
                NSApp.activate(ignoringOtherApps: true)
                go(.key)
            }
        }
    }

    private func permissionCard(granted: Bool, icon: String, title: String, action: String, perform: @escaping () -> Void) -> some View {
        Panel(padding: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if granted {
                    Label("Allowed", systemImage: "checkmark").foregroundStyle(Theme.green)
                } else {
                    Button(action, action: perform).buttonStyle(ActionButtonStyle(prominent: true))
                }
            }
        }
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Pick your dictation key",
                   "Hold it to talk, double-press it for hands-free. Choose one you can reach without looking, or record your own.")
            Panel {
                VStack(spacing: 0) {
                    ForEach(Array(TriggerKey.presets.enumerated()), id: \.element) { i, t in
                        if i > 0 { Divider1() }
                        keyRow(t)
                    }
                    if !settings.trigger.isPreset {
                        Divider1()
                        keyRow(settings.trigger)
                    }
                    Divider1()
                    SettingRow(title: "Something else", detail: "A single modifier, a function key, or a shortcut like ⌥Space") {
                        TriggerRecorder(settings: settings)
                    }
                }
            }
            if settings.trigger == .fn, !perms.fnReady {
                Panel(padding: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("fn opens the emoji picker")
                            Text("Sets “Press 🌐 key to” to Do Nothing, the same switch System Settings uses.")
                                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        }
                        Spacer()
                        Button("Fix it", action: perms.fixFnKey).buttonStyle(ActionButtonStyle(prominent: true))
                    }
                }
            }
        }
    }

    private func keyRow(_ t: TriggerKey) -> some View {
        Button { settings.trigger = t } label: {
            HStack(spacing: 12) {
                Image(systemName: settings.trigger == t ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(settings.trigger == t ? Theme.accent : Theme.tertiary)
                Text(t.label)
                Spacer()
                KeyCap(label: t.short)
            }
            .padding(.horizontal, 12).frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Last step: real dictations into a box on this page, one per feature.
struct TryItStep: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: Store
    @State private var text = ""
    @State private var held = false
    @State private var handsFree = false
    @State private var command = false
    @State private var sawHandsFree = false
    @FocusState private var focused: Bool

    var body: some View {
        let key = settings.trigger.short
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Try it here").font(.system(size: 22, weight: .semibold))
                Text("Click in the box, then use your key. Each task ticks off when it works.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            .padding(.bottom, 6)

            Panel {
                VStack(spacing: 0) {
                    task(held, "Hold to talk", "Hold \(key), say a sentence, let go.", [key])
                    Divider1()
                    task(handsFree, "Hands-free", "Double-press \(key), talk, then press \(key) once more.", [key, key])
                    Divider1()
                    task(command, "Command mode",
                         settings.formatProvider == nil
                             ? "Needs a formatting engine. Turn one on in Settings to use it."
                             : "Select your text, hold \(key) + ⌃ and say “make this more formal”.",
                         [key, "⌃"])
                        .opacity(settings.formatProvider == nil ? 0.5 : 1)
                }
            }

            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(10)
                .frame(minHeight: 150)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.border))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Your words land here…").foregroundStyle(Theme.tertiary).padding(15).allowsHitTesting(false)
                    }
                }

            if case .error(let m) = controller.phase {
                Label(m, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.yellow)
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true } }
        .onChange(of: controller.handsFree) { _, on in if on { sawHandsFree = true } }
        .onChange(of: store.history.first?.date) { _, _ in
            guard let d = store.history.first else { return }
            if d.isCommand { command = true }
            else if sawHandsFree { handsFree = true; sawHandsFree = false }
            else { held = true }
        }
    }

    private func task(_ done: Bool, _ title: String, _ detail: String, _ keys: [String]) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15)).foregroundStyle(done ? Theme.green : Theme.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            HStack(spacing: 4) { ForEach(Array(keys.enumerated()), id: \.offset) { KeyCap(label: $0.element) } }
        }
        .padding(.horizontal, 12).frame(minHeight: 50)
    }
}
