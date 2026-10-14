import CNeedle
import Foundation

/// Cactus Whistle running on this Mac's CPU via the Needle engine (statically linked).
/// A 16.9 MB model; English, German, French, Spanish, Italian, Dutch and Polish (no Hindi).
actor WhistleEngine {
    static let shared = WhistleEngine()

    static let modelURL = URL(string: "https://huggingface.co/Cactus-Compute/whistle/resolve/main/whistle.cact")!
    static var modelFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saynori/whistle.cact")
    }
    private static let languages: Set<String> = ["en", "de", "fr", "es", "it", "nl", "pl"]

    /// The engine keeps a pointer into the weights, so they stay alive for the whole process.
    private var weights: Data?
    private var loading: Task<Data, Error>?

    struct LoadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Downloads the model on first use (cached afterwards) and keeps it loaded.
    func prepare() async throws {
        if weights != nil { return }
        if let loading { _ = try await loading.value; return }
        let task = Task { () throws -> Data in
            let start = Date()
            let file = Self.modelFile
            if !FileManager.default.fileExists(atPath: file.path) {
                let (tmp, response) = try await URLSession.shared.download(from: Self.modelURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw LoadError(message: "download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: tmp, to: file)
            }
            let data = try Data(contentsOf: file, options: .alwaysMapped)
            let rc = data.withUnsafeBytes { needle_load($0.bindMemory(to: UInt8.self).baseAddress, UInt64($0.count)) }
            guard rc >= 0 else { throw LoadError(message: String(cString: needle_last_error())) }
            Log.write("whistle ready in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            return data
        }
        loading = task
        do {
            weights = try await task.value
            loading = nil
        } catch {
            loading = nil
            Log.write("whistle failed to load: \(error)")
            throw error
        }
    }

    var isReady: Bool { weights != nil }

    /// `language` is the app's setting ("en-IN", "unknown", …); unsupported ones fall back to detection.
    func transcribe(_ samples: [Int16], language: String, keyterms: [String]) async throws -> String {
        try await prepare()
        let floats = samples.map { Float($0) / 32768 }
        let code = String(language.prefix(2))
        let lang: String? = Self.languages.contains(code) ? code : nil
        let keywords: String? = keyterms.isEmpty ? nil : keyterms.joined(separator: "\n")
        var out = [CChar](repeating: 0, count: 64 * 1024)
        let rc = floats.withUnsafeBufferPointer { pcm in
            needle_transcribe(pcm.baseAddress, Int32(pcm.count), lang, keywords, 0, &out, Int32(out.count))
        }
        guard rc >= 0 else { throw LoadError(message: String(cString: needle_last_error())) }
        let json = Data(String(cString: out).utf8)
        let text = (try? JSONSerialization.jsonObject(with: json) as? [String: Any])?["text"] as? String ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
