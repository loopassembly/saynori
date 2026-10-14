import AppKit
import SwiftUI

/// Full-screen, click-through layer that flies particles from the pill to the text cursor
/// when a dictation is delivered. It's only on screen for under a second.
@MainActor
final class FlightPanel: NSPanel {
    private let model = FlightModel()
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: FlightView(model: model))
    }

    override var canBecomeKey: Bool { false }

    /// `from` and `to` are in global Cocoa screen coordinates (origin bottom-left).
    func launch(from: CGPoint, to: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(from) }) ?? NSScreen.main else { return }
        setFrame(screen.frame, display: false)
        let f = screen.frame
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - f.minX, y: f.maxY - p.y) }
        let target = CGPoint(x: to.midX, y: to.midY)
        model.start(from: local(from), to: local(target), caretHeight: max(12, to.height))
        orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.orderOut(nil)
            self?.model.active = false
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}

final class FlightModel: ObservableObject {
    struct Comet {
        var p0: CGPoint, p1: CGPoint, p2: CGPoint
        var delay: Double, duration: Double
        var size: CGFloat, red: Bool
    }

    @Published var active = false
    private(set) var comets: [Comet] = []
    private(set) var startTime: Double = 0
    private(set) var target: CGPoint = .zero
    private(set) var caretHeight: CGFloat = 16
    private(set) var arrival: Double = 0

    func start(from: CGPoint, to: CGPoint, caretHeight: CGFloat) {
        target = to
        self.caretHeight = caretHeight
        startTime = Date.timeIntervalSinceReferenceDate
        let dist = hypot(to.x - from.x, to.y - from.y)
        comets = (0..<120).map { _ in
            let start = CGPoint(x: from.x + CGFloat.random(in: -80...80), y: from.y + CGFloat.random(in: -10...10))
            // Arc upward and sideways so the stream reads as flowing, not a straight shot.
            let mid = CGPoint(x: (start.x + to.x) / 2 + CGFloat.random(in: -0.25...0.25) * dist,
                              y: min(start.y, to.y) - dist * CGFloat.random(in: 0.12...0.35))
            return Comet(p0: start, p1: mid, p2: CGPoint(x: to.x + CGFloat.random(in: -2...2), y: to.y + CGFloat.random(in: -3...3)),
                         delay: Double.random(in: 0...0.16), duration: Double.random(in: 0.28...0.42),
                         size: [1.5, 2, 2, 2.5].randomElement()!, red: Double.random(in: 0...1) < 0.12)
        }
        arrival = comets.map { $0.delay + $0.duration }.min() ?? 0.3
        active = true
    }

    static func point(_ c: Comet, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * c.p0.x + 2 * u * t * c.p1.x + t * t * c.p2.x,
                       y: u * u * c.p0.y + 2 * u * t * c.p1.y + t * t * c.p2.y)
    }
}

struct FlightView: View {
    @ObservedObject var model: FlightModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !model.active)) { ctx in
            Canvas { gc, _ in
                guard model.active else { return }
                let now = ctx.date.timeIntervalSinceReferenceDate - model.startTime
                let red = Theme.accent
                // Square pixels on a 1 pt grid, each with a one-pixel dark shadow, like the bar.
                for c in model.comets {
                    let raw = (now - c.delay) / c.duration
                    guard raw > 0, raw < 1 else { continue }
                    let t = CGFloat(easeInOut(raw))
                    for k in stride(from: 3, through: 0, by: -1) {
                        let p = FlightModel.point(c, max(0, t - CGFloat(k) * 0.045))
                        let s = k == 0 ? c.size : max(1, c.size - CGFloat(k) * 0.5)
                        let rect = CGRect(x: p.x.rounded(), y: p.y.rounded(), width: s, height: s)
                        let fade = 1 - Double(k) / 4
                        gc.fill(Path(rect.offsetBy(dx: 0.5, dy: 0.5)), with: .color(.black.opacity(0.45 * fade)))
                        gc.fill(Path(rect), with: .color((c.red ? red : Color(hex: 0xEDEEF2)).opacity(fade)))
                    }
                }
                // Landing: a red block caret blinks twice where the text appears.
                let since = now - model.arrival
                if since > 0, since < 0.42, Int(since / 0.105) % 2 == 0 {
                    let h = max(12, model.caretHeight)
                    let rect = CGRect(x: model.target.x.rounded(), y: (model.target.y - h / 2).rounded(), width: 2, height: h)
                    gc.fill(Path(rect.offsetBy(dx: 0.5, dy: 0.5)), with: .color(.black.opacity(0.35)))
                    gc.fill(Path(rect), with: .color(red))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
}
