import AppKit
import SwiftUI

/// API key entry for one provider: paste, save, and prove it works with a real request.
struct ProviderKeyField: View {
    let provider: Provider
    @ObservedObject var settings: AppSettings
    /// Called with the result of every check.
    var onCheck: (Bool) -> Void = { _ in }
    @State private var draft = ""
    @State private var status: (ok: Bool, text: String)?
    @State private var checking = false

    private var saved: String { settings.keys[provider.rawValue] ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(provider.name) API key")
                Spacer()
                Button("Get a key") { NSWorkspace.shared.open(URL(string: provider.keyURL)!) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
            HStack(spacing: 8) {
                PlainField(text: $draft, placeholder: saved.isEmpty ? "Paste your key" : "Saved key ending in \(saved.suffix(4))", secure: true) { save() }
                Button(checking ? "Checking…" : (draft.isEmpty ? "Check" : "Save & check")) { draft.isEmpty ? check() : save() }
                    .buttonStyle(ActionButtonStyle(prominent: !draft.isEmpty))
                    .disabled(checking || (draft.isEmpty && saved.isEmpty))
            }
            if let status {
                Label(status.text, systemImage: status.ok ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(status.ok ? Theme.green : Theme.yellow)
            }
        }
        .padding(12)
        .onChange(of: provider) { _, _ in draft = ""; status = nil }
    }

    private func save() {
        guard !draft.isEmpty else { return }
        settings.setKey(draft, for: provider)
        draft = ""
        check()
    }

    private func check() {
        checking = true
        status = nil
        let p = provider, key = saved
        Task {
            let r = await CloudSpeech.check(p, key: key)
            await MainActor.run {
                status = (r.ok, r.message)
                checking = false
                onCheck(r.ok)
            }
        }
    }
}

/// Gets an on-device engine ready: downloads and loads Parakeet or Whistle, or checks Ollama has Gemma.
@MainActor
final class ModelLoader: ObservableObject {
    enum State: Equatable { case idle, working(String), ready(String), failed(String) }
    @Published var state: State = .idle
    private var current: Provider?

    var isReady: Bool { if case .ready = state { return true } else { return false } }

    func load(_ p: Provider, settings: AppSettings) {
        if current == p, state != .idle, !(state.isFailure) { return }
        current = p
        switch p {
        case .parakeet:
            state = .working("Downloading Parakeet (469 MB the first time)…")
            Task {
                do { try await ParakeetEngine.shared.prepare(); finish(p, .ready("Parakeet is ready on this Mac")) }
                catch { finish(p, .failed("Parakeet couldn't load: \(error.localizedDescription)")) }
            }
        case .whistle:
            state = .working("Downloading Whistle (17 MB the first time)…")
            Task {
                do { try await WhistleEngine.shared.prepare(); finish(p, .ready("Whistle is ready on this Mac")) }
                catch { finish(p, .failed("Whistle couldn't load: \(error.localizedDescription)")) }
            }
        case .gemma:
            state = .working("Checking Ollama for \(settings.localModel)…")
            let endpoint = settings.localEndpoint, model = settings.localModel
            Task {
                let r = await LocalLLM.status(kind: .ollama, endpoint: endpoint, model: model)
                finish(p, r.ok ? .ready(r.message) : .failed(r.message))
            }
        default:
            state = .ready("Nothing to download: \(p.name) runs in the cloud")
        }
    }

    func retry(_ p: Provider, settings: AppSettings) {
        current = nil
        load(p, settings: settings)
    }

    private func finish(_ p: Provider, _ s: State) {
        guard current == p else { return }
        state = s
    }
}

extension ModelLoader.State {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}

struct ModelLoaderStatus: View {
    @ObservedObject var loader: ModelLoader
    var body: some View {
        switch loader.state {
        case .idle: EmptyView()
        case .working(let t):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(t).foregroundStyle(Theme.secondary) }
                .font(.system(size: 12))
        case .ready(let t):
            Label(t, systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.green)
        case .failed(let t):
            Label(t, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.yellow)
        }
    }
}

/// Speech engine picker grouped into cloud and on-device.
struct SpeechEnginePicker: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        Picker("", selection: Binding(get: { settings.speechProvider }, set: { settings.transcriber = $0.rawValue })) {
            Section("Cloud (API key)") { ForEach(Provider.cloud) { Text($0.name).tag($0) } }
            Section("On this Mac") { ForEach(Provider.local) { Text($0.name).tag($0) } }
        }
        .labelsHidden().fixedSize()
    }
}

struct FormatEnginePicker: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        Picker("", selection: Binding(get: { settings.formatProvider?.rawValue ?? "off" }, set: { settings.engine = $0 })) {
            Text("Instant (on this Mac, no AI)").tag("off")
            Section("Cloud (API key)") { ForEach(Provider.formatters.filter { !$0.isLocal }) { Text($0.name).tag($0.rawValue) } }
            Section("On this Mac") { Text("Gemma 4 (Ollama)").tag(Provider.gemma.rawValue) }
        }
        .labelsHidden().fixedSize()
    }
}
