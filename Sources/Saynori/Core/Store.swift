import Foundation

struct Dictation: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var raw: String
    var text: String
    var app: String
    var duration: Double
    var language: String
    var isCommand: Bool = false

    var words: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

struct DayStat: Identifiable {
    var day: Date
    var words: Int
    var id: Date { day }
}

/// Local-only persistence (JSON in Application Support). Nothing leaves the Mac except audio sent to Sarvam.
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var history: [Dictation] = []
    @Published var vocabulary: [String] = [] { didSet { save() } }
    @Published var snippets: [Snippet] = [] { didSet { save() } }

    private struct Disk: Codable {
        var history: [Dictation]
        var vocabulary: [String]
        var snippets: [Snippet]
    }

    private let url = AppSettings.supportDir.appendingPathComponent("library.json")
    private var loading = false

    /// `SAYNORI_DEMO=1` fills the dashboard with sample data (never written to disk).
    private let demo = ProcessInfo.processInfo.environment["SAYNORI_DEMO"] != nil

    private init() {
        loading = true
        if demo {
            history = Self.demoHistory()
            vocabulary = ["Sarvam", "Saynori", "Kubernetes", "Priya", "Q3 roadmap"]
            snippets = [Snippet(trigger: "my signature", expansion: "Cheers,\nSent with my voice via Saynori")]
        } else if let data = try? Data(contentsOf: url), let disk = try? decoder.decode(Disk.self, from: data) {
            history = disk.history
            vocabulary = disk.vocabulary
            snippets = disk.snippets
        } else {
            vocabulary = ["Sarvam", "Saynori"]
            snippets = [Snippet(trigger: "my signature", expansion: "Cheers,\nSent with my voice via Saynori")]
        }
        loading = false
    }

    private var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    func add(_ d: Dictation) {
        history.insert(d, at: 0)
        if history.count > 5000 { history.removeLast(history.count - 5000) }
        save()
    }

    func delete(_ d: Dictation) {
        history.removeAll { $0.id == d.id }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    private func save() {
        guard !loading, !demo else { return }
        let disk = Disk(history: history, vocabulary: vocabulary, snippets: snippets)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let url = self.url
        DispatchQueue.global(qos: .utility).async {
            if let data = try? enc.encode(disk) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Expands a snippet when the whole utterance matches its trigger phrase.
    func expandSnippet(_ text: String) -> String? {
        let norm = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return snippets.first { $0.trigger.lowercased() == norm }?.expansion
    }

    private static func demoHistory() -> [Dictation] {
        let lines: [(String, String, String)] = [
            ("Slack", "um so the deploy went fine uh we can ship friday", "The deploy went fine — we can ship Friday."),
            ("Mail", "hi priya thanks for the notes I'll send the Q3 roadmap by tomorrow", "Hi Priya,\n\nThanks for the notes. I'll send the Q3 roadmap by tomorrow."),
            ("Cursor", "add a retry with exponential backoff to the upload function", "Add a retry with exponential backoff to the upload function"),
            ("Notes", "ideas for the launch video no wait launch post", "Ideas for the launch post"),
            ("Messages", "running ten minutes late see you soon", "Running 10 minutes late, see you soon!"),
            ("Linear", "the pill should expand on hover and show the hotkey hint", "The pill should expand on hover and show the hotkey hint."),
            ("Slack", "मैं कल ऑफिस आऊंगा", "मैं कल ऑफिस आऊंगा।"),
        ]
        var out = [Dictation]()
        let now = Date()
        for day in 0..<14 {
            let n = [3, 5, 8, 2, 6, 9, 4, 7, 1, 5, 10, 6, 3, 8][day]
            for k in 0..<n {
                let l = lines[(day * 3 + k) % lines.count]
                let date = now.addingTimeInterval(-Double(day) * 86_400 - Double(k) * 2_700)
                let reps = 1 + (day + k) % 4
                let text = Array(repeating: l.2, count: reps).joined(separator: " ")
                out.append(Dictation(date: date, raw: l.1, text: text, app: l.0,
                                     duration: Double(text.split(separator: " ").count) / 2.6, language: "en-IN"))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    // MARK: Stats

    var totalWords: Int { history.reduce(0) { $0 + $1.words } }
    var totalSeconds: Double { history.reduce(0) { $0 + $1.duration } }

    var wpm: Int {
        let mins = totalSeconds / 60
        return mins > 0.05 ? Int(Double(totalWords) / mins) : 0
    }

    /// Minutes saved vs. typing at an average 40 wpm.
    var minutesSaved: Double {
        max(0, Double(totalWords) / 40 - totalSeconds / 60)
    }

    var streak: Int {
        let cal = Calendar.current
        let days = Set(history.map { cal.startOfDay(for: $0.date) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(day) { n += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
        return n
    }

    func daily(last n: Int) -> [DayStat] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var buckets = [Date: Int]()
        for d in history { buckets[cal.startOfDay(for: d.date), default: 0] += d.words }
        return (0..<n).reversed().map { i in
            let day = cal.date(byAdding: .day, value: -i, to: today)!
            return DayStat(day: day, words: buckets[day] ?? 0)
        }
    }

    func topApps(_ n: Int) -> [(String, Int)] {
        var c = [String: Int]()
        for d in history where !d.app.isEmpty { c[d.app, default: 0] += d.words }
        return c.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) }
    }

    var wordsToday: Int {
        let cal = Calendar.current
        return history.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.words }
    }
}
