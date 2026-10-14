import SwiftUI

// MARK: - List row

struct DictationRow: View {
    let d: Dictation
    var compact = false
    @State private var hover = false
    @State private var copied = false
    @State private var showOriginal = false

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 10) {
            Group {
                if d.app.isEmpty { RoundedRectangle(cornerRadius: 4).fill(Theme.raised) } else { AppIcon(name: d.app) }
            }
            .frame(width: 16, height: 16)
            .padding(.top, compact ? 0 : 1)

            VStack(alignment: .leading, spacing: 4) {
                if d.isCommand {
                    Label(d.raw, systemImage: "wand.and.stars").font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Text(display)
                    .foregroundStyle(showOriginal ? Theme.secondary : Theme.text)
                    .lineLimit(compact ? 1 : 6)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showOriginal {
                    Text("Original transcript").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }

            if hover || copied {
                HStack(spacing: 4) {
                    if !compact && d.raw != d.text && !d.isCommand {
                        RowAction(icon: showOriginal ? "text.alignleft" : "waveform", help: showOriginal ? "Show final text" : "Show original transcript") { showOriginal.toggle() }
                    }
                    RowAction(icon: copied ? "checkmark" : "doc.on.doc", help: "Copy") { copy() }
                    if !compact { RowAction(icon: "trash", help: "Delete") { Store.shared.delete(d) } }
                }
            } else {
                Text(meta).font(.system(size: 12)).foregroundStyle(Theme.tertiary).monospacedDigit().lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, compact ? 0 : 10)
        .frame(minHeight: compact ? 38 : 0)
        .background(hover ? Theme.hover.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { copy() }
    }

    private var display: String {
        if showOriginal { return d.raw }
        return compact ? d.text.replacingOccurrences(of: "\n", with: " ") : d.text
    }

    private var meta: String {
        let time = Calendar.current.isDateInToday(d.date)
            ? d.date.formatted(date: .omitted, time: .shortened)
            : d.date.formatted(.dateTime.month(.abbreviated).day())
        return compact ? time : "\(d.words) words   \(time)"
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(d.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

struct RowAction: View {
    let icon: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.borderStrong))
        }
        .buttonStyle(.plain).help(help)
    }
}

// MARK: - History

struct HistoryPage: View {
    @ObservedObject var store: Store
    var query: String
    @State private var confirmClear = false

    private var filtered: [Dictation] {
        guard !query.isEmpty else { return store.history }
        return store.history.filter { $0.text.localizedCaseInsensitiveContains(query) || $0.app.localizedCaseInsensitiveContains(query) }
    }

    private var grouped: [(Date, [Dictation])] {
        let cal = Calendar.current
        return Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if store.history.isEmpty {
                empty("Nothing here yet", "Everything you dictate is kept on this Mac so you can copy it again.")
            } else if filtered.isEmpty {
                empty("No results", "No dictations contain “\(query)”.")
            }
            ForEach(grouped, id: \.0) { day, items in
                VStack(alignment: .leading, spacing: 8) {
                    PanelLabel(title: dayLabel(day), trailing: "\(items.reduce(0) { $0 + $1.words }.formatted()) words")
                    Panel {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, d in
                                if i > 0 { Divider1() }
                                DictationRow(d: d)
                            }
                        }
                    }
                }
            }
            if !store.history.isEmpty {
                Button("Clear history…") { confirmClear = true }.buttonStyle(ActionButtonStyle())
            }
        }
        .confirmationDialog("Delete all dictation history?", isPresented: $confirmClear) {
            Button("Delete history", role: .destructive) { store.clearHistory() }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        Panel(padding: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

// MARK: - Dictionary

struct DictionaryPage: View {
    @ObservedObject var store: Store
    @State private var newWord = ""
    @State private var newTrigger = ""
    @State private var newExpansion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                PanelLabel(title: "Words", trailing: "Always spelled exactly like this")
                Panel(padding: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !store.vocabulary.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(store.vocabulary, id: \.self) { w in
                                    HStack(spacing: 6) {
                                        Text(w).font(.system(size: 12.5))
                                        Button { store.vocabulary.removeAll { $0 == w } } label: {
                                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
                                        }
                                        .buttonStyle(.plain).help("Remove")
                                    }
                                    .padding(.horizontal, 8).frame(height: 24)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raised))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.borderStrong))
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            PlainField(text: $newWord, placeholder: "Add a name or term, like Kubernetes") { addWord() }
                            Button("Add", action: addWord).buttonStyle(ActionButtonStyle())
                                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                PanelLabel(title: "Snippets", trailing: "Say the phrase on its own to insert the text")
                Panel {
                    VStack(spacing: 0) {
                        ForEach(Array($store.snippets.enumerated()), id: \.element.id) { i, $s in
                            if i > 0 { Divider1() }
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(s.trigger).font(.system(size: 12.5, weight: .medium))
                                    .padding(.horizontal, 7).frame(height: 22)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raised))
                                    .frame(width: 170, alignment: .leading)
                                TextField("Text to insert", text: $s.expansion, axis: .vertical).textFieldStyle(.plain)
                                    .lineLimit(1...5)
                                RowAction(icon: "trash", help: "Delete") { store.snippets.removeAll { $0.id == s.id } }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                        }
                        if !store.snippets.isEmpty { Divider1() }
                        HStack(spacing: 8) {
                            PlainField(text: $newTrigger, placeholder: "When I say…").frame(width: 170)
                            PlainField(text: $newExpansion, placeholder: "Type this") { addSnippet() }
                            Button("Add", action: addSnippet).buttonStyle(ActionButtonStyle())
                                .disabled(newTrigger.isEmpty || newExpansion.isEmpty)
                        }
                        .padding(12)
                    }
                }
            }
        }
    }

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !store.vocabulary.contains(w) else { return }
        store.vocabulary.append(w)
        newWord = ""
    }

    private func addSnippet() {
        guard !newTrigger.isEmpty, !newExpansion.isEmpty else { return }
        store.snippets.append(Snippet(trigger: newTrigger.trimmingCharacters(in: .whitespaces), expansion: newExpansion))
        newTrigger = ""; newExpansion = ""
    }
}

struct PlainField: View {
    @Binding var text: String
    let placeholder: String
    var secure = false
    var onSubmit: () -> Void = {}
    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain).font(.system(size: 12.5))
        .onSubmit(onSubmit)
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.borderStrong))
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

// MARK: - Style

struct StylePage: View {
    @ObservedObject var settings: AppSettings

    private let heard = "um so I think we should uh ship it tomorrow no wait friday and loop in priya"
    private func typed(_ s: PolishStyle) -> String {
        switch s {
        case .off: return "Um so I think we should uh ship it tomorrow no wait Friday and loop in Priya"
        case .clean: return "I think we should ship it Friday and loop in Priya."
        case .professional: return "I suggest we ship on Friday and loop in Priya."
        case .casual: return "i think we should ship it friday and loop in priya"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                PanelLabel(title: "Writing style")
                Panel {
                    VStack(spacing: 0) {
                        ForEach(Array(PolishStyle.allCases.enumerated()), id: \.element) { i, s in
                            if i > 0 { Divider1() }
                            Button { settings.polish = s } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: s.icon).font(.system(size: 12)).frame(width: 26, height: 26)
                                        .foregroundStyle(settings.polish == s ? Theme.text : Theme.tertiary)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(s.label)
                                        Text(s.blurb).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                                    }
                                    Spacer()
                                    if settings.polish == s {
                                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                                    }
                                }
                                .padding(.horizontal, 12).frame(height: 50)
                                .background(settings.polish == s ? Theme.hover.opacity(0.5) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                PanelLabel(title: "Preview")
                Panel {
                    HStack(alignment: .top, spacing: 0) {
                        column("Heard", heard, Theme.tertiary)
                        Rectangle().fill(Theme.border).frame(width: 1)
                        column("Typed", typed(settings.polish), Theme.text)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                PanelLabel(title: "Options")
                Panel {
                    VStack(spacing: 0) {
                        SettingRow(title: "Prompt mode for AI tools", detail: "In Claude Code, Codex, Cursor, Zed, VS Code, ChatGPT and Claude, rewrites what you say into a clear, structured prompt: goal first, then numbered tasks and constraints, with code terms in backticks") {
                            Toggle("", isOn: $settings.promptMode).toggleStyle(.switch).labelsHidden().controlSize(.small)
                        }
                        Divider1()
                        SettingRow(title: "Smart formatting", detail: "Turns lists into bullet points, steps into numbered lists, and long thoughts into paragraphs") {
                            Toggle("", isOn: $settings.smartFormat).toggleStyle(.switch).labelsHidden().controlSize(.small)
                        }
                        Divider1()
                        SettingRow(title: "Match the app you're in", detail: "Email paragraphs in Mail, short messages in chat, exact code and commands in editors") {
                            Toggle("", isOn: $settings.contextAware).toggleStyle(.switch).labelsHidden().controlSize(.small)
                        }
                        Divider1()
                        SettingRow(title: "Indian languages", detail: "How Hindi, Tamil, Bengali and others are written") {
                            Picker("", selection: $settings.outputMode) {
                                ForEach(OutputMode.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                }
            }
        }
    }

    private func column(_ label: String, _ text: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            Text(text).foregroundStyle(color).lineSpacing(2)
                .animation(.easeOut(duration: 0.12), value: text)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(14)
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var perms: Permissions
    @State private var localStatus: (ok: Bool, text: String)?
    @State private var showSetups = false
    @StateObject private var loader = ModelLoader()
    @State private var localChecking = false

    private func checkLocal() {
        localChecking = true
        localStatus = nil
        let kind = ChatEngine.LocalKind(rawValue: settings.localKind) ?? .ollama
        let endpoint = settings.localEndpoint, model = settings.localModel
        Task {
            let r = await LocalLLM.status(kind: kind, endpoint: endpoint, model: model)
            await MainActor.run { localStatus = (r.ok, r.message); localChecking = false }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Engines") {
                SettingRow(title: "Speech recognition", detail: settings.speechProvider.blurb) {
                    SpeechEnginePicker(settings: settings)
                }
                if settings.speechProvider.needsKey {
                    Divider1()
                    ProviderKeyField(provider: settings.speechProvider, settings: settings)
                } else if settings.speechProvider != .gemma {
                    ModelLoaderStatus(loader: loader)
                        .padding(.horizontal, 12).padding(.bottom, 12)
                        .task(id: settings.transcriber) { loader.load(settings.speechProvider, settings: settings) }
                }
                Divider1()
                SettingRow(title: "Formatting", detail: settings.formatProvider == nil
                           ? "Instant, on this Mac: removes fillers and stutters, applies \"no wait\" and \"scratch that\", makes lists, writes numbers, emails and tech terms properly, in a few milliseconds. Prompt mode and command mode need an AI engine."
                           : settings.formatProvider == .gemma
                           ? "Formats and writes prompts on this Mac. Nothing is sent anywhere for this step."
                           : "\(settings.formatProvider!.name) formats your text, writes prompts and runs command mode.") {
                    FormatEnginePicker(settings: settings)
                }
                if let f = settings.formatProvider, f.needsKey, f != settings.speechProvider {
                    Divider1()
                    ProviderKeyField(provider: f, settings: settings)
                }
                if settings.formatProvider == .gemma || settings.speechProvider == .gemma {
                    Divider1()
                    SettingRow(title: "Server", detail: "Ollama by default. LM Studio, mlx_lm and llama.cpp work as OpenAI-compatible.") {
                        Picker("", selection: $settings.localKind) {
                            ForEach(ChatEngine.LocalKind.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Divider1()
                    HStack(spacing: 8) {
                        PlainField(text: $settings.localEndpoint, placeholder: "http://localhost:11434")
                        PlainField(text: $settings.localModel, placeholder: "gemma4:e4b-it-qat").frame(width: 150)
                        Button(localChecking ? "Checking…" : "Check", action: checkLocal).buttonStyle(ActionButtonStyle())
                            .disabled(localChecking)
                    }
                    .padding(12)
                    if let localStatus {
                        Label(localStatus.text, systemImage: localStatus.ok ? "checkmark" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(localStatus.ok ? Theme.green : Theme.yellow)
                            .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                }
                Divider1()
                SettingRow(title: "Language", detail: "Auto-detect works with every engine. Indian languages need Sarvam, Gemini or ElevenLabs") {
                    Picker("", selection: $settings.language) {
                        ForEach(Language.all) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden().fixedSize()
                }
                if settings.speechProvider == .sarvam {
                    Divider1()
                    SettingRow(title: "Sarvam speech model", detail: "saaras:v4 hears your Dictionary words and coding terms best") {
                        Picker("", selection: $settings.sttModel) {
                            Text("saaras:v4").tag("saaras:v4")
                            Text("saaras:v3").tag("saaras:v3")
                            Text("saarika:v2.5").tag("saarika:v2.5")
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if showSetups {
                    SetupChooser(settings: settings) { showSetups = false }
                } else {
                    Button { showSetups = true } label: {
                        Label("Compare on-device setups and speeds", systemImage: "gauge.with.dots.needle.67percent")
                    }
                    .buttonStyle(ActionButtonStyle())
                }
            }

            section("Keyboard") {
                SettingRow(title: "Dictation key", detail: "Hold to talk. Double-press for hands-free, then press once to finish. Add ⌃ for a command, esc to cancel") {
                    HStack(spacing: 8) {
                        Picker("", selection: $settings.trigger) {
                            ForEach(TriggerKey.presets) { Text($0.label).tag($0) }
                            if !settings.trigger.isPreset { Text(settings.trigger.label).tag(settings.trigger) }
                        }
                        .labelsHidden().fixedSize()
                        TriggerRecorder(settings: settings)
                    }
                }
                if settings.trigger == .fn {
                    Divider1()
                    SettingRow(title: "Stop fn opening emoji", detail: "Sets “Press 🌐 key to” to Do Nothing and applies it right away") {
                        Button("Apply", action: perms.fixFnKey).buttonStyle(ActionButtonStyle())
                    }
                }
            }

            section("General") {
                SettingRow(title: "Particle effects", detail: "The nebula in the dictation bar and the flight to your cursor") {
                    Toggle("", isOn: $settings.particles).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                Divider1()
                SettingRow(title: "Show dictation bar when idle", detail: "A short line at the bottom of the screen") {
                    Toggle("", isOn: $settings.alwaysShowPill).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                Divider1()
                SettingRow(title: "Sounds", detail: "A soft click when recording starts and stops") {
                    Toggle("", isOn: $settings.sounds).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                Divider1()
                SettingRow(title: "Open at login") {
                    Toggle("", isOn: Binding(get: { perms.launchAtLogin }, set: { perms.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }

            section("Permissions") {
                SettingRow(title: "Microphone", detail: "Only on while you dictate") {
                    permission(perms.mic, "Allow") { perms.requestMic() }
                }
                Divider1()
                SettingRow(title: "Accessibility", detail: "For the dictation key and pasting at your cursor") {
                    permission(perms.accessibility, "Open Settings") { perms.requestAccessibility() }
                }
            }

            section("Troubleshooting") {
                SettingRow(title: "Diagnostics log", detail: "Key presses, timings and errors. Never your API key") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Logs/TypeLikeMe.log")])
                    }
                    .buttonStyle(ActionButtonStyle())
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(title: title)
            Panel { VStack(spacing: 0) { content() } }
        }
    }

    @ViewBuilder private func permission(_ granted: Bool, _ action: String, _ perform: @escaping () -> Void) -> some View {
        if granted {
            Text("Allowed").font(.system(size: 12)).foregroundStyle(Theme.green)
        } else {
            Button(action, action: perform).buttonStyle(ActionButtonStyle(prominent: true))
        }
    }
}
