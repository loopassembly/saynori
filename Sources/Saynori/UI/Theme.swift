import AppKit
import SwiftUI

/// Raycast/Linear-style dark system: layered greys, 1 px borders, 13 pt type, red as the only signal.
enum Theme {
    static let canvas = Color(hex: 0x0F0F11)
    static let sidebar = Color(hex: 0x131315)
    static let panel = Color(hex: 0x17171A)
    static let raised = Color(hex: 0x1E1E22)
    static let hover = Color(hex: 0x222226)
    static let border = Color(hex: 0x26262B)
    static let borderStrong = Color(hex: 0x323238)
    static let text = Color(hex: 0xEDEDEF)
    static let secondary = Color(hex: 0xA1A1AA)
    static let tertiary = Color(hex: 0x6E6E78)
    static let accent = Color(hex: 0xFF625F)   // Saynori coral
    static let green = Color(hex: 0x59D499)
    static let yellow = Color(hex: 0xF5C451)

    static let radius: CGFloat = 10
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

/// Bordered surface used for every grouped block.
struct Panel<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
    }
}

struct Divider1: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1) }
}

struct KeyCap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.borderStrong))
    }
}

/// Primary action: raised surface with a hairline, like Raycast's action buttons.
struct ActionButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Theme.text)
            .padding(.horizontal, 10).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(prominent ? Theme.accent.opacity(configuration.isPressed ? 0.8 : 1)
                                : (configuration.isPressed ? Theme.hover : Theme.raised)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(prominent ? Color.clear : Theme.borderStrong))
            .opacity(enabled ? 1 : 0.4)
    }
}

/// Saynori app icon: the brand tile (coral character on dark charcoal) on the macOS icon grid, an 824-pt
/// squircle centred in a 1024 canvas, with a hairline edge and the standard soft shadow.
struct AppIconArt: View {
    var art: NSImage?
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            if let art {
                Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Color(hex: 0x0C1016))
            }
        }
        .frame(width: 824, height: 824)
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.02)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 3))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
        .frame(width: 1024, height: 1024)
    }
}

/// The Saynori character in brand coral, for the app's own windows (sidebar, onboarding).
struct BrandMark: View {
    var size: CGFloat = 22
    var body: some View {
        if let mark = NSImage(named: "SaynoriMark") {
            Image(nsImage: mark).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            // Development builds run outside the app bundle.
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: size, height: size)
        }
    }
}

/// Menu-bar icon: the Saynori character as a template silhouette (eyes cut out), so macOS tints it for light and
/// dark menu bars; coral while you're dictating. Rendered at build time into the app's Resources.
enum MenuBarIcon {
    static func image(active: Bool = false) -> NSImage {
        guard let base = NSImage(named: "MenuBarIcon")?.copy() as? NSImage else { return fallback(active: active) }
        base.size = NSSize(width: 18, height: 18)
        guard active else { base.isTemplate = true; return base }
        let coral = NSColor(srgbRed: 1, green: 0x62 / 255.0, blue: 0x5F / 255.0, alpha: 1)
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            coral.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    /// Used when running outside the app bundle (development builds): a plain coral-free dot.
    private static func fallback(active: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            return true
        }
        img.isTemplate = !active
        return img
    }
}

/// Build helpers that turn the brand artwork into the app's icon files.
enum BrandArt {
    /// `--render-icon out.png [tile.png]`: the 1024-px app icon.
    @MainActor static func renderIcon(to out: URL, art: URL?) {
        let image = art.flatMap { NSImage(contentsOf: $0) }
        let r = ImageRenderer(content: AppIconArt(art: image).frame(width: 1024, height: 1024))
        r.scale = 1
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: out)
        }
    }

    /// `--render-menubar character.png outdir`: from the transparent character, writes
    ///  - MenuBarIcon.png / @2x (18 / 36 px): black template silhouette with the eyes cut out, a little padded;
    ///  - SaynoriMark.png / @2x / @3x (32 / 64 / 96 px): the coral character, cropped tight, eyes cut out, for the app's UI.
    /// Stray specks around the character are removed.
    static func renderMenuBar(from source: URL, to dir: URL) -> Bool {
        guard let (mask, bounds) = silhouette(source) else { return false }
        let coral = CGColor(srgbRed: 1, green: 0x62 / 255.0, blue: 0x5F / 255.0, alpha: 1)
        let outputs: [(Int, String, CGColor, Double)] = [
            (18, "MenuBarIcon.png", CGColor(gray: 0, alpha: 1), 1.08), (36, "MenuBarIcon@2x.png", CGColor(gray: 0, alpha: 1), 1.08),
            (32, "SaynoriMark.png", coral, 1.0), (64, "SaynoriMark@2x.png", coral, 1.0), (96, "SaynoriMark@3x.png", coral, 1.0),
        ]
        for (size, name, color, pad) in outputs {
            guard let img = export(mask, bounds: bounds, size: size, color: color, pad: pad),
                  let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return false }
            do { try png.write(to: dir.appendingPathComponent(name)) } catch { return false }
        }
        return true
    }

    /// Black-with-alpha silhouette of the coral body (eyes and outside transparent, specks dropped) and its bounds
    /// in top-down pixel coordinates.
    private static func silhouette(_ source: URL) -> (CGImage, CGRect)? {
        guard let src = NSImage(contentsOf: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = src.width, h = src.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))

        // How much of each pixel is coral body: 1 for coral, 0 for the dark eyes and the transparent outside.
        var cover = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(px[i * 4]), a = Float(px[i * 4 + 3]) / 255
            cover[i] = max(0, min(1, (r - 12 * a) / 243))
        }
        // Keep only the character itself (the largest solid region), plus a 2-px fringe for its antialiased edge.
        var label = [Int32](repeating: -1, count: w * h)
        var best = (id: Int32(-1), size: 0)
        var next: Int32 = 0
        var stack: [Int] = []
        for start in 0..<(w * h) where cover[start] > 0.5 && label[start] < 0 {
            var size = 0
            stack.append(start); label[start] = next
            while let p = stack.popLast() {
                size += 1
                let x = p % w, y = p / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let q = ny * w + nx
                    if cover[q] > 0.5 && label[q] < 0 { label[q] = next; stack.append(q) }
                }
            }
            if size > best.size { best = (next, size) }
            next += 1
        }
        guard best.id >= 0 else { return nil }
        var keep = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where label[i] == best.id { keep[i] = true }
        for _ in 0..<2 {
            var grown = keep
            for i in 0..<(w * h) where !keep[i] {
                let x = i % w, y = i / w
                if (x > 0 && keep[i - 1]) || (x < w - 1 && keep[i + 1]) || (y > 0 && keep[i - w]) || (y < h - 1 && keep[i + w]) { grown[i] = true }
            }
            keep = grown
        }
        var minX = w, minY = h, maxX = 0, maxY = 0
        var mask = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where keep[i] && cover[i] > 0.01 {
            mask[i * 4 + 3] = UInt8(cover[i] * 255)   // black, premultiplied: colour channels stay 0
            let x = i % w, y = i / w
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        guard let mctx = CGContext(data: &mask, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let full = mctx.makeImage() else { return nil }
        return (full, CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    /// The silhouette cropped to a square around `bounds` (times `pad`), scaled to `size` px and filled with `color`.
    private static func export(_ full: CGImage, bounds: CGRect, size: Int, color: CGColor, pad: Double) -> CGImage? {
        let w = full.width, h = full.height
        let side = Double(max(bounds.width, bounds.height)) * pad
        let crop = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        // Halve in steps for a clean downscale, then draw at the final size.
        var img = full
        var scale = 1.0
        while side * scale / 2 > Double(size) * 2 {
            scale /= 2
            let cw = Int(Double(w) * scale), ch = Int(Double(h) * scale)
            guard let c = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            c.interpolationQuality = .high
            c.draw(img, in: CGRect(x: 0, y: 0, width: cw, height: ch))
            guard let smaller = c.makeImage() else { return nil }
            img = smaller
        }
        guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        // Map the crop square (top-down pixels of the full image) onto the output; CG's origin is bottom-left.
        let k = Double(size) / side
        c.draw(img, in: CGRect(x: -crop.minX * k, y: -(Double(h) - crop.maxY) * k, width: Double(w) * k, height: Double(h) * k))
        c.setBlendMode(.sourceIn)
        c.setFillColor(color)
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return c.makeImage()
    }
}
