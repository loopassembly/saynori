import AppKit
import SwiftUI

/// A borderless, non-activating panel that floats above everything (including
/// full-screen apps) without ever stealing focus from the app you're typing in.
final class PillPanel: NSPanel {
    init(controller: DictationController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PillView.size.width, height: PillView.size.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        let host = NSHostingView(rootView: PillView(controller: controller, settings: .shared))
        host.frame = contentRect(forFrameRect: frame)
        contentView = host
        reposition()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Extra height above the usual spot (used by the preview so it never covers the real bar).
    var lift: CGFloat = 0
    /// Distance kept from the screen edge, and how far the side docks sit in from it.
    private static let edge: CGFloat = 12

    private var mouseScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Where the bar's centre sits for a dock position on this screen.
    private func centerX(for anchor: String, in vf: NSRect) -> CGFloat {
        let half = PillView.field / 2
        switch anchor {
        case "left": return vf.minX + Self.edge + half
        case "right": return vf.maxX - Self.edge - half
        default: return vf.midX
        }
    }

    /// Docks the bar on the bottom edge (just above the Dock). If `caret` would sit under the bar —
    /// typing on the last line of a full-height window — it moves to the far side for this dictation.
    func reposition() { reposition(avoiding: nil) }
    @objc private func screensChanged() { reposition(avoiding: nil) }

    func reposition(avoiding caret: CGRect?) {
        guard let vf = mouseScreen?.visibleFrame else { return }
        var anchor = AppSettings.shared.barAnchor
        if let caret, lift == 0 {
            let x = centerX(for: anchor, in: vf)
            let barTop = vf.minY + PillView.bottomInset + PillView.hud.height + 14
            let underBar = caret.minY < barTop && abs(caret.midX - x) < PillView.field / 2 + 24
            if underBar { anchor = caret.midX < vf.midX ? "right" : "left" }
        }
        setFrameOrigin(NSPoint(x: centerX(for: anchor, in: vf) - frame.width / 2, y: vf.minY + lift))
    }

    // MARK: Drag to dock (left, centre or right of the bottom edge, like Wispr Flow's bar)

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, frame.origin) }
        guard let start = dragStart else { return }
        setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y))
    }

    func dragEnded() {
        dragStart = nil
        guard let vf = mouseScreen?.visibleFrame else { return }
        let x = frame.midX
        let anchor = ["left", "center", "right"].min { abs(centerX(for: $0, in: vf) - x) < abs(centerX(for: $1, in: vf) - x) } ?? "center"
        AppSettings.shared.barAnchor = anchor
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrameOrigin(NSPoint(x: centerX(for: anchor, in: vf) - frame.width / 2, y: vf.minY + lift))
        }
    }
}

/// Raycast-style HUD. One fixed-size panel for listening → writing → pasted, so nothing jumps;
/// the nebula inside does the talking.
struct PillView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: AppSettings
    @State private var hovering = false

    static let size = CGSize(width: 520, height: 96)
    static let bottomInset: CGFloat = 3
    static let hud = CGSize(width: 320, height: 26)

    private var motion: Bool { settings.particles && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if controller.phase == .idle { idle } else { hud }
            }
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in (NSApp.windows.first { $0 is PillPanel } as? PillPanel)?.dragChanged() }
                .onEnded { _ in (NSApp.windows.first { $0 is PillPanel } as? PillPanel)?.dragEnded() })
            .padding(.bottom, Self.bottomInset)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: controller.phase == .idle)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    // MARK: Idle

    @ViewBuilder private var idle: some View {
        if hovering {
            HStack(spacing: 6) {
                Text("Hold").foregroundStyle(Theme.secondary)
                KeyCap(label: settings.trigger.short)
                Text("to dictate").foregroundStyle(Theme.secondary)
                Rectangle().fill(Theme.border).frame(width: 1, height: 12).padding(.horizontal, 2)
                Text("Double-press for hands-free").foregroundStyle(Theme.tertiary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).frame(height: 26)
            .background(shell)
            .onTapGesture { controller.toggleHandsFree() }
            .transition(.opacity)
        } else {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color(hex: 0x17171A).opacity(settings.alwaysShowPill ? 0.85 : 0.001))
                .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(Color.white.opacity(settings.alwaysShowPill ? 0.28 : 0), lineWidth: 0.5))
                .frame(width: 44, height: 5)
                .padding(.top, 12).padding(.bottom, 1).padding(.horizontal, 40)
                .contentShape(Rectangle())
                .transition(.opacity)
        }
    }

    // MARK: Active HUD

    private var hud: some View {
        ZStack(alignment: .bottom) {
            // The bar itself: thin, dark, quiet.
            ZStack {
                if case .error(let msg) = controller.phase {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5)).foregroundStyle(Theme.yellow)
                        Text(msg).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    }
                    .fixedSize()
                } else if !motion {
                    Bars(levels: controller.levels).padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
            .frame(width: panelWidth, height: Self.hud.height)
            .background(shell)
            .overlay(alignment: .trailing) {
                if controller.handsFree && controller.phase == .listening {
                    Button { controller.toggleHandsFree() } label: {
                        RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 6, height: 6)
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain).help("Stop and paste (or press \(settings.trigger.short))")
                    .padding(.trailing, 4)
                    .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.82), value: panelWidth)

            // The pixels live in a larger, click-through layer so they can leave the bar.
            if motion {
                PixelFieldView(mode: pixelMode, cell: 1.5, density: 0.22,
                               visible: panelWidth - (handsFreeActive ? Self.stopWidth : 0),
                               band: Self.hud.height, centerFromBottom: Self.hud.height / 2, shadows: true,
                               word: formedWord, level: { [weak controller] in Float(controller?.levels.last ?? 0) })
                    .frame(width: Self.fieldSize.width, height: Self.fieldSize.height)
                    .offset(x: handsFreeActive ? -Self.stopWidth / 2 : 0)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Self.fieldSize.width, height: Self.fieldSize.height, alignment: .bottom)
        .transition(.opacity)
    }

    private var handsFreeActive: Bool { controller.handsFree && controller.phase == .listening }

    /// Resting width while listening/writing, the widest the bar gets, and the stop button.
    static let compact: CGFloat = 156
    static let field: CGFloat = 320
    static let stopWidth: CGFloat = 24
    /// The pixel layer: wider than the bar, with headroom above it.
    static let fieldSize = CGSize(width: 480, height: 78)

    /// Grows to fit the words (or an error), otherwise stays small.
    private var panelWidth: CGFloat {
        switch controller.phase {
        case .done(let text) where motion:
            return min(Self.field, max(Self.compact, PixelRenderer.wordWidth(text, band: Self.hud.height, cell: 1.5, maxWidth: Self.field) + 30))
        case .error(let msg):
            let w = NSAttributedString(string: msg, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).size().width
            return min(Self.field, w + 50)
        case .listening where controller.handsFree:
            return Self.compact + Self.stopWidth
        default:
            return Self.compact
        }
    }

    /// The transcript the pixels spell out (the renderer fits it to the grid).
    private var formedWord: String? {
        guard case .done(let text) = controller.phase else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var pixelMode: PixelMode {
        switch controller.phase {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return .processing
        case .done: return .done
        case .error: return .error
        }
    }

    private var shell: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(hex: 0x131315).opacity(0.97))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.06)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Reduce-motion fallback: plain level bars.
struct Bars: View {
    var levels: [Float]
    var body: some View {
        Canvas { g, size in
            let n = levels.count
            let gap: CGFloat = 2
            let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            for (i, l) in levels.enumerated() {
                let h = max(2, CGFloat(l) * size.height)
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                g.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .color(.white.opacity(0.35 + Double(l) * 0.65)))
            }
        }
    }
}
