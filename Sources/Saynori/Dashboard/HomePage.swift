import Charts
import SwiftUI

struct HomePage: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var perms: Permissions
    @ObservedObject var store: Store
    @ObservedObject var settings: AppSettings
    var go: (Page) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !perms.allGood {
                SetupPanel(perms: perms, settings: settings, go: go)
            }
            Hero(controller: controller, settings: settings)
            if store.history.count < 5 {
                TryIt(trigger: settings.trigger.short)
            }
            if !store.history.isEmpty {
                Metrics(store: store)
                ActivityPanel(store: store)
                RecentPanel(store: store, go: go)
            }
        }
    }
}

// MARK: - Hero

/// The one expressive element: a live nebula that mirrors your voice, with the controls as keycaps.
struct Hero: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack {
                Spacer()
                PixelFieldView(mode: mode, cell: 2.5, density: 0.3, level: { [weak controller] in Float(controller?.levels.last ?? 0) })
                    .frame(width: 380)
                    .padding(.vertical, 18).padding(.trailing, 18)
            }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text("Works in every app. Text goes where your cursor is.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        hint([settings.trigger.short], "Hold to talk")
                        hint([settings.trigger.short, settings.trigger.short], "Double-press for hands-free")
                    }
                    HStack(spacing: 14) {
                        hint([settings.trigger.short, "⌃"], "Command")
                        hint(["esc"], "Cancel")
                    }
                }
            }
            .padding(20)
        }
        .frame(height: 168)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var mode: PixelMode {
        switch controller.phase {
        case .listening: return .listening
        case .processing: return .processing
        default: return .ambient
        }
    }

    private var title: String {
        switch controller.phase {
        case .listening: return "Listening…"
        case .processing: return "Writing…"
        default: return "Hold \(settings.trigger.short) and speak"
        }
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { KeyCap(label: $0.element) }
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(.leading, 2)
        }
    }
}

// MARK: - Setup

struct SetupPanel: View {
    @ObservedObject var perms: Permissions
    @ObservedObject var settings: AppSettings
    var go: (Page) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(title: "Finish setup", trailing: "\(done) of 4")
            Panel {
                VStack(spacing: 0) {
                    row(settings.engineReady, "key", "Engine: \(settings.speechProvider.name)",
                        settings.missingKey.map { "Add your \($0.name) API key" } ?? "Ready", "Add key") { go(.settings) }
                    Divider1()
                    row(perms.mic, "mic", "Microphone", "Only on while you dictate", "Allow") { perms.requestMic() }
                    Divider1()
                    row(perms.accessibility, "accessibility", "Accessibility", "For the dictation key and pasting at your cursor", "Open Settings") { perms.requestAccessibility() }
                    Divider1()
                    row(perms.fnReady, "globe", "fn key", "Stop fn from opening the emoji picker", "Fix") { perms.fixFnKey() }
                }
            }
        }
    }

    private var done: Int { [settings.engineReady, perms.mic, perms.accessibility, perms.fnReady].filter { $0 }.count }

    private func row(_ ok: Bool, _ icon: String, _ title: String, _ detail: String, _ action: String, _ perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(ok ? Theme.tertiary : Theme.text)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(ok ? Theme.secondary : Theme.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            if ok {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.green)
            } else {
                Button(action, action: perform).buttonStyle(ActionButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 12).frame(height: 52)
    }
}

// MARK: - Try it

struct TryIt: View {
    let trigger: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(title: "Try it")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(10)
                if text.isEmpty {
                    Text("Click here, hold \(trigger) and say “Let's meet Thursday at 3, no actually Friday.”")
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 88)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(focused ? Theme.borderStrong : Theme.border))
        }
    }
}

// MARK: - Metrics

struct Metrics: View {
    @ObservedObject var store: Store

    var body: some View {
        Panel {
            HStack(spacing: 0) {
                cell("Words", store.totalWords.formatted())
                sep
                cell("Words per minute", "\(store.wpm)")
                sep
                cell("Time saved", Self.duration(store.minutesSaved))
                sep
                cell("Streak", "\(store.streak) \(store.streak == 1 ? "day" : "days")")
            }
        }
    }

    private var sep: some View { Rectangle().fill(Theme.border).frame(width: 1) }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    static func duration(_ minutes: Double) -> String {
        if minutes < 1 { return "\(Int(minutes * 60))s" }
        if minutes < 60 { return "\(Int(minutes.rounded()))m" }
        return String(format: "%.1fh", minutes / 60)
    }
}

// MARK: - Activity

struct ActivityPanel: View {
    @ObservedObject var store: Store
    @State private var selected: Date?

    var body: some View {
        let data = store.daily(last: 14)
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(title: "Activity", trailing: caption(data))
            Panel(padding: 14) {
                Chart(data) { d in
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Words", d.words), width: .ratio(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .foregroundStyle(color(d))
                }
                .chartXSelection(value: $selected)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 1)) { v in
                        if let date = v.as(Date.self) {
                            AxisValueLabel(centered: true) {
                                Text(date.formatted(.dateTime.weekday(.narrow)))
                                    .foregroundStyle(Calendar.current.isDateInToday(date) ? Theme.text : Theme.tertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Theme.border)
                        AxisValueLabel().foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(height: 120)
            }
        }
    }

    private func caption(_ data: [DayStat]) -> String {
        if let s = selected, let d = data.first(where: { Calendar.current.isDate($0.day, inSameDayAs: s) }) {
            return "\(d.words.formatted()) words, \(d.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
        }
        return "Last 14 days"
    }

    private func color(_ d: DayStat) -> Color {
        if let s = selected, Calendar.current.isDate(s, inSameDayAs: d.day) { return Theme.text }
        return Calendar.current.isDateInToday(d.day) ? Theme.accent : Color(hex: 0x3A3A41)
    }
}

// MARK: - Recent

struct RecentPanel: View {
    @ObservedObject var store: Store
    var go: (Page) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PanelLabel(title: "Recent")
                Button { go(.history) } label: {
                    HStack(spacing: 4) {
                        Text("All history").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        KeyCap(label: "⌘2")
                    }
                }
                .buttonStyle(.plain)
            }
            Panel {
                VStack(spacing: 0) {
                    ForEach(Array(store.history.prefix(7).enumerated()), id: \.element.id) { i, d in
                        if i > 0 { Divider1() }
                        DictationRow(d: d, compact: true)
                    }
                }
            }
        }
    }
}

/// Resolves an app's icon by name (running apps first, then /Applications).
struct AppIcon: View {
    let name: String
    private static var cache = [String: NSImage]()

    var body: some View {
        if let icon = Self.icon(for: name) {
            Image(nsImage: icon).resizable()
        } else {
            RoundedRectangle(cornerRadius: 4).fill(Theme.raised)
        }
    }

    static func icon(for name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        var img = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.icon
        if img == nil {
            let paths = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                         NSHomeDirectory() + "/Applications"].map { "\($0)/\(name).app" }
            if let p = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                img = NSWorkspace.shared.icon(forFile: p)
            }
        }
        if let img { cache[name] = img }
        return img
    }
}
