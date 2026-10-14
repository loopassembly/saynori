import SwiftUI

/// One way to run Saynori, with what it costs: time per dictation, disk, memory, privacy, languages.
struct SetupOption: Identifiable {
    let id: String
    let title: String
    let detail: String
    let speech: String
    let formatting: String
    /// Seconds for a 7.5 s dictation, measured on an Apple M4 (24 GB).
    let speechTime: Double
    let formatTime: Double
    let disk: String
    let memory: String
    let privacy: String
    let languages: String
    let needsGemma: Bool
    let needsKey: Bool
    var recommended = false

    var total: Double { speechTime + formatTime }

    func apply(to s: AppSettings) {
        switch id {
        case "fastest":
            s.transcriber = "parakeet"; s.engine = "off"; s.polish = .off
        case "tiny":
            s.transcriber = "whistle"; s.engine = "off"; s.polish = .off
        case "private":
            s.transcriber = "parakeet"; s.engine = "gemma"; s.localKind = "ollama"
            s.localModel = "gemma4:e4b-it-qat"; if s.polish == .off { s.polish = .clean }
        case "gemma":
            s.transcriber = "gemma"; s.engine = "gemma"; s.localKind = "ollama"
            s.localModel = "gemma4:e4b-it-qat"; if s.polish == .off { s.polish = .clean }
        default:
            s.transcriber = "sarvam"; s.engine = "sarvam"; if s.polish == .off { s.polish = .clean }
        }
        s.setupChosen = id
    }

    static let all: [SetupOption] = [
        SetupOption(id: "fastest", title: "Fastest", detail: "Clean text, lists, numbers and tech terms in a blink. Nothing leaves this Mac.",
                    speech: "Parakeet", formatting: "Instant", speechTime: 0.08, formatTime: 0,
                    disk: "485 MB", memory: "60 MB", privacy: "Private", languages: "English + 24",
                    needsGemma: false, needsKey: false),
        SetupOption(id: "tiny", title: "Tiny", detail: "Same as Fastest with a 17 MB model on the CPU. Fewer languages.",
                    speech: "Whistle", formatting: "Instant", speechTime: 0.05, formatTime: 0,
                    disk: "17 MB", memory: "80 MB", privacy: "Private", languages: "English + 6",
                    needsGemma: false, needsKey: false),
        SetupOption(id: "private", title: "Smart and private", detail: "Clean text, lists and prompts for AI tools. Everything stays on this Mac.",
                    speech: "Parakeet", formatting: "Gemma 4 E4B", speechTime: 0.08, formatTime: 0.9,
                    disk: "7.2 GB", memory: "≈5 GB", privacy: "Private", languages: "English + 24",
                    needsGemma: true, needsKey: false, recommended: true),
        SetupOption(id: "gemma", title: "All Gemma", detail: "One local model for both. Slower, but understands more languages.",
                    speech: "Gemma 4 E4B", formatting: "Gemma 4 E4B", speechTime: 2.1, formatTime: 1.4,
                    disk: "6.7 GB", memory: "≈5 GB", privacy: "Private", languages: "Multilingual",
                    needsGemma: true, needsKey: false),
        SetupOption(id: "cloud", title: "Cloud", detail: "Sarvam for both. Best for Hindi and other Indian languages.",
                    speech: "Sarvam", formatting: "Sarvam", speechTime: 0.47, formatTime: 0.45,
                    disk: "15 MB", memory: "50 MB", privacy: "Cloud", languages: "Indian languages",
                    needsGemma: false, needsKey: true),
    ]
}

/// Compares the setups side by side on a shared time scale and applies the one you pick.
struct SetupChooser: View {
    @ObservedObject var settings: AppSettings
    var onDone: (() -> Void)? = nil
    @State private var selected = "private"
    @State private var gemmaInstalled: Bool?

    private let scaleMax = 4.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                PanelLabel(title: "Choose your setup")
                legend
            }
            Panel {
                VStack(spacing: 0) {
                    ForEach(Array(SetupOption.all.enumerated()), id: \.element.id) { i, option in
                        if i > 0 { Divider1() }
                        row(option)
                    }
                    Divider1()
                    footer
                }
            }
        }
        .onAppear {
            selected = settings.setupChosen.isEmpty ? "private" : settings.setupChosen
            Task {
                let r = await LocalLLM.status(kind: .ollama, endpoint: "http://localhost:11434", model: "gemma4:e4b-it-qat")
                await MainActor.run { gemmaInstalled = r.ok }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendDot(Theme.text.opacity(0.85), "Speech")
            legendDot(Theme.accent, "Formatting")
        }
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
    }

    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) { RoundedRectangle(cornerRadius: 1.5).fill(c).frame(width: 10, height: 6); Text(label) }
    }

    private func row(_ o: SetupOption) -> some View {
        Button { selected = o.id } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected == o.id ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14)).foregroundStyle(selected == o.id ? Theme.accent : Theme.tertiary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(o.title).font(.system(size: 13, weight: .semibold))
                        if o.recommended { tag("Recommended", Theme.accent) }
                        if o.needsGemma, gemmaInstalled == false { tag("Needs Gemma download", Theme.yellow) }
                        if o.needsKey, settings.apiKey.isEmpty { tag("Needs Sarvam key", Theme.yellow) }
                    }
                    Text(o.detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Text("Speech: \(o.speech)   Formatting: \(o.formatting)")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                    bar(o)
                    HStack(spacing: 6) {
                        chip("internaldrive", o.disk)
                        chip("memorychip", o.memory)
                        chip(o.privacy == "Private" ? "lock.fill" : "cloud", o.privacy)
                        chip("globe", o.languages)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.seconds(o.total)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    Text("per dictation").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .background(selected == o.id ? Theme.hover.opacity(0.55) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Stacked bar on a shared 0–4 s scale: speech then formatting.
    private func bar(_ o: SetupOption) -> some View {
        GeometryReader { g in
            let w = g.size.width
            let speechW = max(3, w * o.speechTime / scaleMax)
            let formatW = w * o.formatTime / scaleMax
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.raised)
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.text.opacity(0.85)).frame(width: speechW)
                    if o.formatTime > 0 {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.accent).frame(width: formatW)
                    }
                }
            }
        }
        .frame(height: 8)
        .frame(maxWidth: 360)
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 7).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raised))
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
    }

    private var footer: some View {
        let option = SetupOption.all.first { $0.id == selected }!
        return HStack(spacing: 10) {
            Text("Times for a 7.5-second dictation on a MacBook with Apple M4 (24 GB). Change this any time in Settings.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if option.needsGemma, gemmaInstalled == false {
                Button("Copy install command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("ollama pull gemma4:e4b-it-qat", forType: .string)
                }
                .buttonStyle(ActionButtonStyle())
                .help("Install Ollama from ollama.com, then run: ollama pull gemma4:e4b-it-qat")
            }
            Button("Use \(option.title)") {
                option.apply(to: settings)
                if option.speech == "Parakeet" { Task { try? await ParakeetEngine.shared.prepare() } }
                if option.speech == "Whistle" { Task { try? await WhistleEngine.shared.prepare() } }
                onDone?()
            }
            .buttonStyle(ActionButtonStyle(prominent: true))
        }
        .padding(14)
    }

    static func seconds(_ t: Double) -> String {
        t < 0.95 ? String(format: "%.1f s", max(0.1, t)) : String(format: "%.1f s", t)
    }
}
