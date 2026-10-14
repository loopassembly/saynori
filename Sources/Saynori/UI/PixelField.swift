import AppKit
import MetalKit
import SwiftUI

/// Pixel-grid display for the dictation bar. Crisp square pixels on a device-pixel grid, one
/// language throughout: no glow, no blur. The view is taller and wider than the bar it sits on,
/// so pixels can arrive from the desktop, sparks can rise into the air and letters can lift off.
///
/// listening  → pixels stream in from both sides and lock into the wave; newest sound in the
///              centre, red-hot, cooling as it travels out; loud moments throw sparks upward
/// processing → a scanner: red head, dithered trail, over a faint pixel field
/// done       → a red block cursor types the transcript in pixel type, eating the scanner's
///              noise as it goes; blinks once; then the letters lift off toward the cursor
/// ambient    → a sparse, slow shimmer (dashboard)
enum PixelMode: Equatable { case idle, ambient, listening, processing, done, error }

/// Timings shared by the bar and the paste, so the text lands as the letters leave.
enum PixelTiming {
    /// A beat for the bar to widen before the cursor starts typing.
    static let expand: Float = 0.14
    static let type: Float = 0.34
    static let hold: Float = 0.30
    static let lift: Float = 0.45
    /// Seconds from "done" until the letters start to lift off.
    static var lead: TimeInterval { TimeInterval(expand + type + hold) }
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct U {
    float time; float appear; float think; float form;
    float hold; float burst; float width; float height;
    float cell; float pixel; float cols; float rows;
    float centerRow; float bandRows; float maxH; float visHalf;
    float density; float live; float hasWord; float shadow;
    float wordLeft; float wordRight; float wordTop; float offsetX;
    float offsetY; float ambient; float pad1; float pad2;
};

struct VOut {
    float4 pos [[position]];
    float size [[point_size]];
    float4 color;
};

constant float3 WHITE = float3(0.93, 0.94, 0.96);
constant float3 RED = float3(1.0, 0.36, 0.36);

static float hash1(float n) { return fract(sin(n) * 43758.5453); }

static float bayer4(uint x, uint y) {
    const float m[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
    return (m[(y & 3u) * 4u + (x & 3u)] + 0.5) / 16.0;
}

static float vnoise(float3 p) {
    float3 i = floor(p), f = fract(p);
    float3 w = f * f * (3.0 - 2.0 * f);
    float n = dot(i, float3(1.0, 57.0, 113.0));
    float a = mix(mix(hash1(n), hash1(n + 1.0), w.x), mix(hash1(n + 57.0), hash1(n + 58.0), w.x), w.y);
    float b = mix(mix(hash1(n + 113.0), hash1(n + 114.0), w.x), mix(hash1(n + 170.0), hash1(n + 171.0), w.x), w.y);
    return mix(a, b, w.z);
}

static VOut emit(float2 p, float a, float3 col, constant U &u) {
    VOut o;
    if (u.shadow > 0.5) { p += float2(1.0, 1.0); col = float3(0.0); a *= 0.55; }
    o.pos = float4(p.x / u.width * 2.0 - 1.0, 1.0 - p.y / u.height * 2.0, 0.0, 1.0);
    o.size = a > 0.01 ? u.pixel : 0.0;
    o.color = float4(col, a);
    return o;
}

/// The scanner used while Sarvam works: returns (lit, isHead).
static float2 scanner(float c, float r, float cx, float cy, float bay, constant U &u) {
    float reach = max(u.visHalf - 8.0, 6.0);
    float s = sin(u.time * 3.6);
    float head = cx + s * reach;
    float dir = cos(u.time * 3.6) >= 0.0 ? 1.0 : -1.0;
    float behind = (head - c) * dir;
    float band = abs(r - cy);
    float isHead = step(abs(c - head), 1.0) * step(band, 2.0) * (1.0 - u.ambient);
    float trail = behind > 0.0 && behind < 22.0 ? 1.0 - behind / 22.0 : 0.0;
    float trailLit = step(1.0 - trail, bay) * step(band, 2.5 - behind * 0.06) * (1.0 - u.ambient);
    // A faint field of pixel dust across the band (the whole view in ambient mode).
    float n = vnoise(float3(c * 0.09, r * 0.3, u.time * 0.8));
    float env = 1.0 - smoothstep(reach - 2.0, reach + 6.0, abs(c - cx));
    float inBand = u.ambient > 0.5 ? 1.0 : step(band, 3.0);
    float dust = step(1.0 - u.density, n * 0.55 + bay * 0.5) * inBand * env;
    return float2(max(max(isHead, trailLit), dust), isHead);
}

vertex VOut pixel_vertex(uint vid [[vertex_id]],
                         constant U &u [[buffer(0)]],
                         const device float *heights [[buffer(1)]],
                         const device float *word [[buffer(2)]]) {
    uint cols = uint(u.cols);
    float c = float(vid % cols), r = float(vid / cols);
    float cx = (u.cols - 1.0) * 0.5, cy = u.centerRow;
    float seed = hash1(c * 12.9898 + r * 78.233);
    float bay = bayer4(uint(c), uint(r));
    float side = c < cx ? -1.0 : 1.0;
    float band = abs(r - cy);

    // --- Wave: dithered core with depth, red-hot where the sound is new.
    uint d = uint(abs(c - cx));
    float h = heights[d];
    h += h > 0.0 ? vnoise(float3(c * 0.21, 0.0, u.time * 2.2)) * 0.35 : 0.0;
    float edge = h - band;
    float wave = step(0.0, edge + (bay - 0.5) * 1.4) * step(0.0, h);
    float g = clamp(edge / max(h, 1.0), 0.0, 1.0);
    float waveA = mix(0.3, 1.0, clamp(floor(g * 3.0 + bay) / 3.0, 0.0, 1.0));
    float loud = clamp((heights[d] - 0.45) / max(u.maxH, 1.0), 0.0, 1.0);
    float heat = loud * 2.1 * pow(max(0.0, 1.0 - float(d) / max(u.visHalf, 1.0)), 1.8) * (0.4 + 0.6 * g);
    bool hot = u.live > 0.5 && (heat + (bay - 0.5) * 0.45) > 0.5;

    // --- Scanner (processing), crossfading in middle-out.
    float2 sc = scanner(c, r, cx, cy, bay, u);
    float delay = abs(c - cx) / max(u.visHalf, 1.0) * 0.7 + seed * 0.3;
    float thinking = step(delay, u.think);

    float lit = mix(wave, sc.x, thinking);
    float alpha = mix(waveA, sc.y > 0.5 ? 1.0 : 0.7, thinking);
    float3 col = thinking > 0.5 ? (sc.y > 0.5 ? RED : WHITE) : (hot ? RED : WHITE);

    // --- Typing: a red block cursor writes the words left to right over the scanner.
    if (u.hasWord > 0.5) {
        float caret = floor(mix(u.wordLeft - 2.0, u.wordRight + 2.0, u.form));
        bool inBox = r >= u.wordTop - 1.0 && r <= u.wordTop + 8.0;
        if (c < caret) {
            lit = word[vid];
            alpha = 1.0;
            col = float3(1.0);
        }
        bool blinkOn = u.form < 1.0 || fract(u.hold * 1.6) < 0.55;
        if (inBox && c >= caret && c < caret + 2.0 && blinkOn && u.burst < 0.01) {
            lit = 1.0; alpha = 1.0; col = RED;
        }
        if (u.form >= 1.0 && c > u.wordRight + 3.0) { lit = 0.0; }
    }

    // --- Arrival: pixels stream in from the desktop on both sides and lock to the grid.
    float2 home = float2(u.offsetX + c * u.cell, u.offsetY + r * u.cell);
    float order = abs(c - cx) / max(u.cols * 0.5, 1.0) * 0.45 + seed * 0.3;
    float ea = clamp((u.appear - order) / 0.4, 0.0, 1.0);
    ea = 1.0 - pow(1.0 - ea, 3.0);
    float2 from = home + float2(side * u.width * (0.2 + 0.4 * hash1(seed * 7.1)),
                                -hash1(seed * 3.3) * u.height * 0.8);
    float2 p = ea >= 0.999 ? home : mix(from, home, ea);

    // --- Lift-off: letters rise out of the bar, left to right, and fade.
    float span = max(u.wordRight - u.wordLeft, 1.0);
    float lo = u.hasWord > 0.5 ? clamp((u.burst - (c - u.wordLeft) / span * 0.35 - seed * 0.1) / 0.55, 0.0, 1.0)
                               : clamp((u.burst - seed * 0.3) / 0.7, 0.0, 1.0);
    p += float2((hash1(seed * 5.7) - 0.5) * lo * u.cell * 18.0, -lo * lo * u.height * (0.5 + 0.5 * hash1(seed * 9.1)));
    if (ea < 0.999 || lo > 0.0) { p = floor(p / u.cell + 0.5) * u.cell; }   // move in whole cells

    float a = lit * alpha * ea * (1.0 - lo * lo);
    return emit(p, a, col, u);
}

/// Pixels that break off the wave on loud moments and climb into the air, a cell at a time.
vertex VOut spark_vertex(uint vid [[vertex_id]],
                         constant U &u [[buffer(0)]],
                         const device float *heights [[buffer(1)]]) {
    float k = float(vid);
    float life = 0.8 + hash1(k * 3.7) * 0.6;
    float t = u.time / life + hash1(k * 1.37);
    float phase = fract(t), epoch = floor(t);
    float cx = (u.cols - 1.0) * 0.5;
    float c0 = floor(cx + (hash1(k * 7.13 + epoch * 3.1) - 0.5) * 2.0 * max(u.visHalf - 6.0, 1.0));
    uint d = uint(abs(c0 - cx));
    float h = heights[d];
    float loud = clamp((h - 0.45) / max(u.maxH, 1.0), 0.0, 1.0);
    float show = step(0.28 + hash1(k * 5.3 + epoch) * 0.4, loud) * u.live * step(u.think, 0.01);
    float side = c0 < cx ? -1.0 : 1.0;
    float rise = phase * (4.0 + 22.0 * hash1(k * 2.3 + epoch));
    float row = floor(u.centerRow - h - 1.0 - rise + 0.5);
    float colm = floor(c0 + side * phase * (1.0 + 6.0 * hash1(k * 4.1 + epoch)) + 0.5);
    float2 p = float2(u.offsetX + colm * u.cell, u.offsetY + row * u.cell);
    float a = pow(1.0 - phase, 1.4) * show * u.appear;
    bool red = (1.0 - float(d) / max(u.visHalf, 1.0)) * loud > 0.4;
    return emit(p, a, red ? RED : WHITE, u);
}

fragment float4 pixel_fragment(VOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}
"""

final class PixelRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var time: Float = 0, appear: Float = 0, think: Float = 0, form: Float = 0
        var hold: Float = 0, burst: Float = 0, width: Float = 0, height: Float = 0
        var cell: Float = 0, pixel: Float = 0, cols: Float = 0, rows: Float = 0
        var centerRow: Float = 0, bandRows: Float = 0, maxH: Float = 0, visHalf: Float = 0
        var density: Float = 0, live: Float = 0, hasWord: Float = 0, shadow: Float = 0
        var wordLeft: Float = 0, wordRight: Float = 0, wordTop: Float = 0, offsetX: Float = 0
        var offsetY: Float = 0, ambient: Float = 0, pad1: Float = 0, pad2: Float = 0
    }

    static let device = MTLCreateSystemDefaultDevice()
    private static var pipeline: MTLRenderPipelineState?
    private static var sparkPipeline: MTLRenderPipelineState?
    private static var queue: MTLCommandQueue?

    var mode: PixelMode = .idle
    var cellPoints: CGFloat = 1.5
    var density: Float = 0.3
    /// Width of the bar the pixels live in (the view itself can be wider).
    var visiblePoints: CGFloat = .infinity
    /// Height of that bar, and how far its centre sits above the bottom of the view (-1 = centred).
    var bandPoints: CGFloat = 0
    var centerFromBottom: CGFloat = -1
    var shadows = false
    var levelSource: () -> Float = { 0 }

    private(set) var word: String?
    private var pendingWord: String?
    private var wordBox = (left: Float(0), right: Float(0), top: Float(0))
    private let start = CACurrentMediaTime()
    private var last = CACurrentMediaTime()
    private var appear: Float = 0, think: Float = 0, form: Float = 0, hold: Float = 0, burst: Float = 0
    private var waitLeft: Float = 0
    private var shownHalf: Float = -1
    private var level: Float = 0
    private var history = [Float](repeating: 0, count: 256)
    private var historyTick: Double = 0

    private var cols = 0, rows = 0
    private var centerRow: Float = 0
    private var heights: MTLBuffer?
    private var wordBuffer: MTLBuffer?

    override init() {
        super.init()
        Self.prepare()
    }

    private static func prepare() {
        guard pipeline == nil, let device else { return }
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "pixel_vertex")
            d.fragmentFunction = lib.makeFunction(name: "pixel_fragment")
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: d)
            d.vertexFunction = lib.makeFunction(name: "spark_vertex")
            sparkPipeline = try device.makeRenderPipelineState(descriptor: d)
            queue = device.makeCommandQueue()
        } catch {
            Log.write("pixel shader failed: \(error)")
        }
    }

    func show(word text: String?) {
        guard text != word else { return }
        pendingWord = text
    }

    var isSettled: Bool { (mode == .idle || mode == .error) && appear < 0.01 }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let window = view.window else { view.isPaused = true; return }
        guard window.occlusionState.contains(.visible) else { return }
        let fps = mode == .ambient ? 30 : 60
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }

        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, now - last))
        last = now

        let scale = window.backingScaleFactor
        let size = view.drawableSize
        let cell = max(2, (cellPoints * scale).rounded())
        let newCols = Int(size.width / cell), newRows = Int(size.height / cell)
        if newCols != cols || newRows != rows { resize(cols: newCols, rows: newRows) }
        guard cols > 0, rows > 0 else { return }
        let toCells = scale / cell
        centerRow = centerFromBottom < 0 ? Float(rows - 1) / 2 : (Float(rows) - Float(centerFromBottom * toCells) - 0.5).rounded()
        let bandRows = Float((bandPoints > 0 ? bandPoints : view.bounds.height) * toCells)
        // Follow the bar's width at roughly its spring's pace, so nothing shows outside it mid-resize.
        let targetHalf = Float(min(visiblePoints, view.bounds.width) * toCells / 2)
        if shownHalf < 0 { shownHalf = targetHalf }
        shownHalf += (targetHalf - shownHalf) * min(1, dt * 14)
        let visHalf = shownHalf
        let maxH = bandRows * 0.4

        if let text = pendingWord { layOut(text, bandRows: bandRows, visHalf: targetHalf); pendingWord = nil }

        func toward(_ v: inout Float, _ target: Float, _ seconds: Float) {
            let step = dt / seconds
            v = target > v ? min(target, v + step) : max(target, v - step)
        }
        switch mode {
        case .idle: toward(&appear, 0, 0.2)
        case .ambient: toward(&appear, 1, 1.2); think = 1; form = 0; burst = 0
        case .listening: toward(&appear, 1, 0.5); toward(&think, 0, 0.25); form = 0; hold = 0; burst = 0; word = nil
        case .processing: toward(&appear, 1, 0.3); toward(&think, 1, 0.3)
        case .done:
            think = 1
            if word != nil {
                if waitLeft > 0 { waitLeft -= dt }
                else if form < 1 { toward(&form, 1, PixelTiming.type) }
                else if hold < 1 { toward(&hold, 1, PixelTiming.hold) }
                else { toward(&burst, 1, PixelTiming.lift) }
            } else {
                toward(&burst, 1, PixelTiming.lift)
            }
        case .error: toward(&burst, 1, 0.35)
        }

        // Level history, newest first, sampled at 40 Hz; the wave tapers to a point inside the bar.
        let raw: Float = mode == .listening ? levelSource() : 0
        level += (raw - level) * min(1, dt * (raw > level ? 20 : 7))
        if now - historyTick > 1.0 / 40 {
            historyTick = now
            history.removeLast()
            history.insert(level, at: 0)
        }
        if let heights {
            let half = cols / 2 + 2
            let hp = heights.contents().bindMemory(to: Float.self, capacity: half)
            let reach = max(1, visHalf - 4)
            for d in 0..<half {
                let taper = max(0, 1 - pow(Float(d) / reach, 2))
                let v = history[min(d, history.count - 1)]
                hp[d] = Float(d) > reach ? -1 : (0.45 + pow(v, 1.35) * maxH) * taper
            }
        }

        guard let pipeline = Self.pipeline, let queue = Self.queue,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let gridW = CGFloat(cols) * cell, gridH = CGFloat(rows) * cell
        var u = Uniforms()
        u.time = Float(now - start); u.appear = appear; u.think = think; u.form = form
        u.hold = hold; u.burst = burst; u.width = Float(size.width); u.height = Float(size.height)
        u.cell = Float(cell); u.pixel = Float(cell - 1); u.cols = Float(cols); u.rows = Float(rows)
        u.centerRow = centerRow; u.bandRows = bandRows; u.maxH = maxH; u.visHalf = visHalf
        u.density = density; u.live = mode == .listening ? 1 : 0; u.hasWord = word == nil ? 0 : 1
        u.wordLeft = wordBox.left; u.wordRight = wordBox.right; u.wordTop = wordBox.top
        u.offsetX = Float(((size.width - gridW) / 2).rounded() + (cell - 1) / 2)
        u.offsetY = Float(((size.height - gridH) / 2).rounded() + (cell - 1) / 2)
        u.ambient = mode == .ambient ? 1 : 0

        if appear > 0.001 && burst < 0.999 {
            enc.setVertexBuffer(heights, offset: 0, index: 1)
            enc.setVertexBuffer(wordBuffer, offset: 0, index: 2)
            // Shadow pass first (one device pixel down-right), then the pixels themselves.
            for pass in (shadows ? [1, 0] : [0]) {
                u.shadow = Float(pass)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setRenderPipelineState(pipeline)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: cols * rows)
                if mode == .listening, let sparkPipeline = Self.sparkPipeline {
                    enc.setRenderPipelineState(sparkPipeline)
                    enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 260)
                }
            }
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        if isSettled || ((mode == .done || mode == .error) && burst >= 0.999) { view.isPaused = true }
    }

    private func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        heights = Self.device?.makeBuffer(length: MemoryLayout<Float>.stride * (cols / 2 + 2), options: .storageModeShared)
        wordBuffer = Self.device?.makeBuffer(length: MemoryLayout<Float>.stride * max(1, cols * rows), options: .storageModeShared)
        if let w = word { word = nil; pendingWord = w }
    }

    /// Lays the transcript out on the grid: the pixel font when it covers every character,
    /// otherwise the system font rasterised without smoothing (Hindi and other scripts).
    private func layOut(_ text: String, bandRows: Float, visHalf: Float) {
        guard let wordBuffer, cols > 0, rows > 0 else { return }
        let out = wordBuffer.contents().bindMemory(to: Float.self, capacity: cols * rows)
        for i in 0..<(cols * rows) { out[i] = 0 }
        let maxWidth = Int(visHalf * 2) - 10
        let cx = cols / 2
        let top = Int((centerRow - Float(PixelFont.capHeight) / 2).rounded())

        if PixelFont.supports(text) {
            let fitted = PixelFont.fit(text, maxWidth: maxWidth)
            let w = PixelFont.width(of: fitted)
            var x = cx - w / 2
            let left = x
            for (i, ch) in fitted.enumerated() {
                if i > 0 { x += PixelFont.tracking }
                if ch == " " { x += PixelFont.spaceWidth; continue }
                guard let g = PixelFont.glyph(ch) else { continue }
                for (gc, gr) in g.cells {
                    let c = x + gc, r = top + gr
                    if c >= 0, c < cols, r >= 0, r < rows { out[r * cols + c] = 1 }
                }
                x += g.width
            }
            wordBox = (Float(left), Float(x), Float(top))
        } else {
            let font = NSFont.systemFont(ofSize: CGFloat(bandRows) * 0.62, weight: .bold)
            let fitted = PixelRenderer.fitSystem(text, font: font, width: CGFloat(maxWidth))
            guard let ctx = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setShouldAntialias(false)
            ctx.setAllowsFontSmoothing(false)
            let str = NSAttributedString(string: fitted, attributes: [.font: font, .foregroundColor: NSColor.white])
            let sz = str.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let baseY = CGFloat(rows) - CGFloat(centerRow) - sz.height / 2
            str.draw(at: NSPoint(x: ((CGFloat(cols) - sz.width) / 2).rounded(), y: baseY.rounded()))
            NSGraphicsContext.restoreGraphicsState()
            guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return }
            var minC = cols, maxC = 0, minR = rows
            for r in 0..<rows {
                for c in 0..<cols where data[r * cols * 4 + c * 4 + 3] > 110 {
                    out[r * cols + c] = 1
                    minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r)
                }
            }
            wordBox = (Float(minC), Float(maxC + 1), Float(minR))
        }
        word = text
        form = 0
        hold = 0
        burst = 0
        waitLeft = PixelTiming.expand
    }

    static func fitSystem(_ text: String, font: NSFont, width: CGFloat) -> String {
        let words = text.replacingOccurrences(of: "\n", with: " ").split(separator: " ").map(String.init)
        var out = ""
        for w in words {
            let next = out.isEmpty ? w : out + " " + w
            if NSAttributedString(string: next + "…", attributes: [.font: font]).size().width > width {
                return out.isEmpty ? String(w.prefix(12)) + "…" : out + "…"
            }
            out = next
        }
        return out
    }

    /// Points the fitted transcript will take up, for sizing the bar around it.
    static func wordWidth(_ text: String, band: CGFloat, cell: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let maxCells = Int(maxWidth / cell) - 10
        if PixelFont.supports(text) {
            return CGFloat(PixelFont.width(of: PixelFont.fit(text, maxWidth: maxCells))) * cell
        }
        let font = NSFont.systemFont(ofSize: band / cell * 0.62, weight: .bold)
        let fitted = fitSystem(text, font: font, width: CGFloat(maxCells))
        return NSAttributedString(string: fitted, attributes: [.font: font]).size().width * cell
    }
}

struct PixelFieldView: NSViewRepresentable {
    var mode: PixelMode
    var cell: CGFloat = 1.5
    var density: Float = 0.3
    var visible: CGFloat = .infinity
    var band: CGFloat = 0
    var centerFromBottom: CGFloat = -1
    var shadows = false
    var word: String? = nil
    var level: () -> Float = { 0 }

    func makeCoordinator() -> PixelRenderer { PixelRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let v = PassthroughMTKView(frame: .zero, device: PixelRenderer.device)
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.layer?.isOpaque = false
        v.framebufferOnly = true
        v.enableSetNeedsDisplay = false
        v.delegate = context.coordinator
        v.isPaused = true
        return v
    }

    static func dismantleNSView(_ v: MTKView, coordinator: PixelRenderer) {
        v.isPaused = true
        v.delegate = nil
    }

    func updateNSView(_ v: MTKView, context: Context) {
        let r = context.coordinator
        r.cellPoints = cell
        r.density = density
        r.visiblePoints = visible
        r.bandPoints = band
        r.centerFromBottom = centerFromBottom
        r.shadows = shadows
        r.levelSource = level
        r.mode = mode
        if mode == .done { r.show(word: word) }
        if mode != .idle { v.isPaused = false }
    }
}

/// The pixel layer never takes clicks; whatever is underneath stays usable.
final class PassthroughMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
