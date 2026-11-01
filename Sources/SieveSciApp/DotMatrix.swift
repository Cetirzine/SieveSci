import AppKit
import SwiftUI

/// Dot-matrix graphics: text and activity drawn as a grid of square dots. The motif is the sieve in
/// the name: dots fall into place as if sifted, and a slow scan band passes over them. Everything
/// holds still under Reduce Motion.

/// Which cells of a grid a string covers, sampled from the rendered glyphs (computed once per text).
struct DotBitmap: Equatable {
    let columns: Int
    let rows: Int
    let on: [Bool]

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DotBitmap] = [:]

    /// `rows` sets the resolution: the text is rendered that many cells tall.
    static func text(_ s: String, rows: Int, weight: NSFont.Weight = .heavy) -> DotBitmap {
        let key = "\(s)|\(rows)|\(weight.rawValue)"
        if let hit = cacheLock.withLock({ cache[key] }) { return hit }
        let font = NSFont.systemFont(ofSize: CGFloat(rows) * 0.92, weight: weight)
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = attr.size()
        let cols = max(1, Int(ceil(size.width)))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cols, pixelsHigh: rows, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return DotBitmap(columns: 0, rows: 0, on: []) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.shouldAntialias = true
        attr.draw(at: NSPoint(x: 0, y: (CGFloat(rows) - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        var on = [Bool](repeating: false, count: cols * rows)
        for y in 0..<rows {
            for x in 0..<cols {
                on[y * cols + x] = (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.45
            }
        }
        let b = DotBitmap(columns: cols, rows: rows, on: on)
        cacheLock.withLock { cache[key] = b }
        return b
    }
}

/// A string drawn in dots. On appear the dots sift in (each lands after its own small delay, top rows
/// first); afterwards a soft band of light sweeps across every few seconds.
struct DotMatrixText: View {
    let text: String
    var rows = 22
    var dot: CGFloat = 4
    var gap: CGFloat = 1.5
    var color: Color = Theme.ink
    var accent: Color = Theme.accent

    @State private var start = Date()
    private var animated: Bool { Theme.Motion.allowed }

    var body: some View {
        let bm = DotBitmap.text(text, rows: rows)
        let pitch = dot + gap
        TimelineView(.animation(paused: !animated)) { tl in
            let t = animated ? tl.date.timeIntervalSince(start) : 99
            Canvas { ctx, _ in
                for y in 0..<bm.rows {
                    for x in 0..<bm.columns where bm.on[y * bm.columns + x] {
                        // Sift: a per-dot delay from a cheap hash, biased by row so dots settle top-down.
                        let h = Double((x &* 73_856_093 ^ y &* 19_349_663) & 1023) / 1023
                        let land = 0.35 * h + 0.5 * Double(y) / Double(bm.rows)
                        let p = min(1, max(0, (t - land) / 0.35))
                        guard p > 0 else { continue }
                        let eased = 1 - pow(1 - p, 3)
                        let fall = (1 - eased) * pitch * 3
                        // Scan band: a diagonal sweep every 5 s after the dots have landed.
                        let phase = (t - 1.2).truncatingRemainder(dividingBy: 5) / 5
                        let band = t > 1.2 ? max(0, 1 - abs(Double(x + y / 2) / Double(bm.columns + bm.rows) - phase) * 14) : 0
                        let r = CGRect(x: CGFloat(x) * pitch, y: CGFloat(y) * pitch - fall, width: dot, height: dot)
                        ctx.fill(Path(r), with: .color(band > 0.05 ? accent.opacity(0.55 + 0.45 * band) : color.opacity(eased)))
                    }
                }
            }
        }
        .frame(width: CGFloat(bm.columns) * pitch, height: CGFloat(bm.rows) * pitch)
        .accessibilityElement()
        .accessibilityLabel(text)
        .onAppear { start = Date() }
    }
}

/// A small dot grid that ripples while an agent works: dots light up as rings spread from the centre,
/// like an instrument's activity lamp. Static (half lit) under Reduce Motion.
struct DotActivity: View {
    var size = 5
    var dot: CGFloat = 3
    var gap: CGFloat = 1.5
    var color: Color = Theme.accent

    var body: some View {
        let pitch = dot + gap
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !Theme.Motion.allowed)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                let c = Double(size - 1) / 2
                for y in 0..<size {
                    for x in 0..<size {
                        let d = ((Double(x) - c) * (Double(x) - c) + (Double(y) - c) * (Double(y) - c)).squareRoot()
                        let wave = Theme.Motion.allowed ? (sin(d * 1.6 - t * 5) + 1) / 2 : 0.5
                        let r = CGRect(x: CGFloat(x) * pitch, y: CGFloat(y) * pitch, width: dot, height: dot)
                        ctx.fill(Path(r), with: .color(color.opacity(0.15 + 0.85 * wave * wave)))
                    }
                }
            }
        }
        .frame(width: CGFloat(size) * pitch - gap, height: CGFloat(size) * pitch - gap)
        .accessibilityHidden(true)
    }
}

/// A field of dots that thins out downward, like grains passing through a sieve; the grains drift
/// slowly. Background only (empty states).
struct SieveField: View {
    var pitch: CGFloat = 12
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !Theme.Motion.allowed)) { tl in
            let t = Theme.Motion.allowed ? tl.date.timeIntervalSinceReferenceDate : 0
            Canvas { ctx, size in
                let cols = Int(size.width / pitch) + 1, rows = Int(size.height / pitch) + 1
                for y in 0..<rows {
                    let density = 1 - Double(y) / Double(max(rows, 1))   // dense at the top, sifted below
                    for x in 0..<cols {
                        let h = Double((x &* 2_654_435_761 ^ y &* 40_503) & 4095) / 4095
                        let flicker = (sin(t * 0.8 + h * 12) + 1) / 2
                        guard h < density * 0.85 else { continue }
                        let a = 0.10 + 0.22 * flicker * density
                        ctx.fill(Path(CGRect(x: CGFloat(x) * pitch, y: CGFloat(y) * pitch, width: 2, height: 2)),
                                 with: .color(Theme.ink.opacity(a)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
