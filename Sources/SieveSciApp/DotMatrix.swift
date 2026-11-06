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
    /// The dots have landed and the scan band has crossed once: the wordmark stays still from then on
    /// (an endless TimelineView re-laid-out the whole window every frame while the empty task was open).
    @State private var settled = false
    private var animated: Bool { Theme.Motion.allowed && !settled }
    /// Landing (~1.2 s) plus one full sweep of the scan band (5 s).
    static let playTime = 6.2

    var body: some View {
        let bm = DotBitmap.text(text, rows: rows)
        let pitch = dot + gap
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { tl in
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
                        let band = t > 1.2 && t < Self.playTime ? max(0, 1 - abs(Double(x + y / 2) / Double(bm.columns + bm.rows) - phase) * 14) : 0
                        let r = CGRect(x: CGFloat(x) * pitch, y: CGFloat(y) * pitch - fall, width: dot, height: dot)
                        ctx.fill(Path(r), with: .color(band > 0.05 ? accent.opacity(0.55 + 0.45 * band) : color.opacity(eased)))
                    }
                }
            }
        }
        .frame(width: CGFloat(bm.columns) * pitch, height: CGFloat(bm.rows) * pitch)
        .accessibilityElement()
        .accessibilityLabel(text)
        .onAppear { start = Date(); settled = false }
        .task {
            try? await Task.sleep(nanoseconds: UInt64(Self.playTime * 1_000_000_000))
            settled = true
        }
    }
}


/// Progress as a row of square dots filling from the left, the lit edge easing forward (downloads).
struct DotProgress: View {
    var value: Double
    var count = 20
    var dot: CGFloat = 3
    var gap: CGFloat = 1.5
    var color: Color = Theme.accent

    var body: some View {
        let lit = Int((min(max(value, 0), 1) * Double(count)).rounded(.down))
        HStack(spacing: gap) {
            ForEach(0..<count, id: \.self) { i in
                Rectangle()
                    .fill(i < lit ? color : Theme.rule)
                    .frame(width: dot, height: dot)
            }
        }
        .animation(Theme.Motion.allowed ? Theme.Motion.hover : nil, value: lit)
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100))%")
    }
}
