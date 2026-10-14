import AppKit
import SwiftUI

/// Shown above the bar when a dictation had nowhere to go: the text is already on the
/// clipboard, and the card says so, shows it, and offers Copy in case the clipboard changed.
final class CopyCardPanel: NSPanel {
    static let size = CGSize(width: 380, height: 150)

    init(controller: DictationController) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: CopyCard(controller: controller))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Sits just above the dictation bar.
    func place(above bar: NSRect) {
        setFrameOrigin(NSPoint(x: bar.midX - Self.size.width / 2,
                               y: bar.minY + PillView.bottomInset + PillView.hud.height + 6))
    }
}

struct CopyCard: View {
    @ObservedObject var controller: DictationController
    @State private var copiedAgain = false

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let item = controller.unplaced {
                Group {
                    if let app = item.pastedInto { note(item.text, app: app) } else { card(item.text) }
                }
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .frame(width: CopyCardPanel.size.width, height: CopyCardPanel.size.height)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: controller.unplaced)
        .environment(\.colorScheme, .dark)
    }

    /// The quiet version, after a paste we couldn't verify: one line, one button.
    private func note(_ text: String, app: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.green)
            Text("Pasted into \(app).").foregroundStyle(Theme.secondary)
            Text("Didn't land?").foregroundStyle(Theme.tertiary)
            Spacer(minLength: 4)
            Button { copy(text) } label: {
                Text(copiedAgain ? "Copied" : "Copy")
            }
            .buttonStyle(ActionButtonStyle(prominent: true))
        }
        .font(.system(size: 12))
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 34)
        .frame(width: 300)
        .background(shell)
        .onHover { controller.holdUnplaced($0) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedAgain = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedAgain = false }
    }

    private var shell: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(hex: 0x131315).opacity(0.97))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.06)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }

    private func card(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "text.cursor").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                Text("No text field to type into").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button { controller.dismissUnplaced() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Dismiss")
            }

            Text(text)
                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                .lineLimit(3).lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button { copy(text) } label: {
                    Label(copiedAgain ? "Copied" : "Copy", systemImage: copiedAgain ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(ActionButtonStyle(prominent: true))

                HStack(spacing: 4) {
                    Text("Already copied. Press").foregroundStyle(Theme.tertiary)
                    KeyCap(label: "⌘V")
                    Text("where you want it.").foregroundStyle(Theme.tertiary)
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(12)
        .frame(width: CopyCardPanel.size.width - 20)
        .background(shell)
        .onHover { controller.holdUnplaced($0) }
    }
}
