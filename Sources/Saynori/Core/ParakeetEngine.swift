import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT v3 running on this Mac (Core ML / Neural Engine) via FluidAudio.
/// Very fast; English plus 24 other European languages (no Hindi or other Indian languages).
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    /// Downloads the model on first use (cached afterwards) and keeps it loaded.
    @discardableResult
    func prepare() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let task = Task { () throws -> AsrManager in
            let start = Date()
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            Log.write("parakeet ready in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            return m
        }
        loading = task
        do {
            let m = try await task.value
            manager = m
            loading = nil
            return m
        } catch {
            loading = nil
            Log.write("parakeet failed to load: \(error)")
            throw error
        }
    }

    var isReady: Bool { manager != nil }

    func transcribe(_ samples: [Int16]) async throws -> String {
        let m = try await prepare()
        let floats = samples.map { Float($0) / 32768 }
        var state = TdtDecoderState.make()
        let result = try await m.transcribe(floats, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
