import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, history, dictionary, style, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .style: return "Style"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .style: return "textformat"
        case .settings: return "gearshape"
        }
    }
    var shortcut: KeyEquivalent { KeyEquivalent(Character("\(Page.allCases.firstIndex(of: self)! + 1)")) }
}

struct DashboardView: View {
    @ObservedObject var controller: DictationController
    @StateObject private var perms = Permissions()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = Store.shared
    @State private var page: Page = .home
    @State private var query = ""

    var body: some View {
        if !settings.onboarded {
            OnboardingView(controller: controller, perms: perms, settings: settings, store: store)
        } else {
            dashboard
        }
    }

    private var dashboard: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page, controller: controller)
                .frame(width: 216)
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(spacing: 0) {
                header
                Divider1()
                ScrollView {
                    Group {
                        switch page {
                        case .home: HomePage(controller: controller, perms: perms, store: store, settings: settings, go: { page = $0 })
                        case .history: HistoryPage(store: store, query: query)
                        case .dictionary: DictionaryPage(store: store)
                        case .style: StylePage(settings: settings)
                        case .settings: SettingsPage(settings: settings, perms: perms)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 880, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.automatic)
            }
            .background(Theme.canvas)
        }
        .foregroundStyle(Theme.text)
        .font(.system(size: 13))
        .tint(Theme.accent)
        .environment(\.colorScheme, .dark)
        .background(pageShortcuts)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: page.icon).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            Text(page.title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if page == .history {
                SearchField(text: $query, placeholder: "Search dictations").frame(width: 260)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Theme.canvas)
    }

    /// ⌘1…⌘5 switch pages, Raycast-style.
    private var pageShortcuts: some View {
        ZStack {
            ForEach(Page.allCases) { p in
                Button("") { page = p }.keyboardShortcut(p.shortcut, modifiers: .command).opacity(0)
            }
        }
        .frame(width: 0, height: 0)
    }
}

struct Sidebar: View {
    @Binding var page: Page
    @ObservedObject var controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                BrandMark(size: 22)
                Text("Saynori").font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.top, 46).padding(.bottom, 14)

            ForEach(Page.allCases) { p in
                Button { page = p } label: {
                    HStack(spacing: 9) {
                        Image(systemName: p.icon).font(.system(size: 12.5)).frame(width: 16)
                            .foregroundStyle(page == p ? Theme.text : Theme.tertiary)
                        Text(p.title).foregroundStyle(page == p ? Theme.text : Theme.secondary)
                        Spacer()
                        Text("⌘\(Page.allCases.firstIndex(of: p)! + 1)").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            .opacity(page == p ? 1 : 0.6)
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(page == p ? Theme.hover : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
            LiveCard(controller: controller)
        }
        .padding(.horizontal, 10).padding(.bottom, 12)
        .background(Theme.sidebar)
    }
}

/// Small live status card at the bottom of the sidebar; its nebula mirrors the pill.
struct LiveCard: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PixelFieldView(mode: mode, cell: 2, density: 0.26, level: { [weak controller] in Float(controller?.levels.last ?? 0) })
                .frame(height: 46)
            Divider1()
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(status).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer()
                KeyCap(label: settings.trigger.short)
            }
            .padding(.horizontal, 10).frame(height: 32)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var mode: PixelMode {
        switch controller.phase {
        case .listening: return .listening
        case .processing: return .processing
        default: return .ambient
        }
    }

    private var dot: Color {
        switch controller.phase {
        case .listening: return Theme.accent
        case .processing: return Theme.yellow
        case .error: return Theme.yellow
        default: return Theme.green
        }
    }

    private var status: String {
        switch controller.phase {
        case .listening: return controller.handsFree ? "Listening, hands-free" : "Listening"
        case .processing: return "Writing"
        case .error(let m): return m
        default: return "Ready"
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let placeholder: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12.5))
            if text.isEmpty {
                KeyCap(label: "⌘F")
            } else {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
    }
}

/// Small grey label above a panel.
struct PanelLabel: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(Theme.tertiary) }
        }
        .padding(.horizontal, 2)
    }
}
