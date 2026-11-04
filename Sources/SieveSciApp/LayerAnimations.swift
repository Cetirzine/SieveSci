import AppKit
import SwiftUI

/// Continuous animations played by Core Animation in the render server.
///
/// A SwiftUI `TimelineView` or `repeatForever` animation invalidates the view graph every frame, and
/// SwiftUI then re-runs layout, hit-testing and tracking areas for the whole window — with a long
/// transcript on screen that is most of a frame's budget. The composer's effort gauge (30 fps, always
/// visible), its "max" label (30 fps), the activity dots (20 fps) and the blinking cursor ran all the
/// time, so the window updated ~80 times a second even when nothing changed, and typing and streaming
/// competed with them. Here each animation is built once as layers and runs with no work in the app;
/// it is rebuilt only when its size, appearance or content changes.
final class AnimationLayerView: NSView {
    var key = ""
    var build: ((CALayer, CGSize, CGFloat) -> Void)?
    private var built = ""

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func layout() { super.layout(); rebuild() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); rebuild(force: true) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); rebuild(force: true) }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); rebuild(force: true) }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); rebuild() }

    func rebuild(force: Bool = false) {
        guard let root = layer, window != nil, bounds.width > 0, bounds.height > 0, !inLiveResize else { return }
        let scale = window?.backingScaleFactor ?? 2
        let sig = "\(key)|\(bounds.size)|\(effectiveAppearance.name.rawValue)|\(scale)"
        guard force || sig != built else { return }
        built = sig
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        effectiveAppearance.performAsCurrentDrawingAppearance { build?(root, bounds.size, scale) }
        CATransaction.commit()
    }
}

/// Hosts an `AnimationLayerView`. `key` names everything the layers depend on besides size and
/// appearance; when it changes, they are rebuilt.
struct LayerAnimation: NSViewRepresentable {
    let key: String
    let build: (CALayer, CGSize, CGFloat) -> Void

    func makeNSView(context: Context) -> AnimationLayerView {
        let v = AnimationLayerView()
        v.wantsLayer = true
        v.layer?.masksToBounds = false
        return v
    }

    func updateNSView(_ v: AnimationLayerView, context: Context) {
        v.build = build
        if v.key != key { v.key = key; v.rebuild(force: true) }
    }

    static func loop(_ a: CAAnimation, duration: CFTimeInterval) -> CAAnimation {
        a.duration = duration
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        return a
    }

    /// The colour as the current drawing appearance resolves it (call inside `build`).
    static func cg(_ c: Color) -> CGColor { NSColor(c).cgColor }

    /// A key that tells colours apart (`Color.description` is the same for every dynamic colour).
    static func key(_ c: Color) -> String {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return c.description }
        return String(format: "%.3f,%.3f,%.3f,%.3f", n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
    }

    /// Whether the current drawing appearance is dark (call inside `build`).
    static var dark: Bool { NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

// MARK: - Sprite loops (SwiftUI drawings played as a flip book)

enum SpriteFrames {
    @MainActor private static var cache: [String: [CGImage]] = [:]

    /// `count` frames of `frame(i)`, each `size` points, rendered once per key, appearance and scale.
    @MainActor static func render<V: View>(_ key: String, count: Int, size: CGSize, scale: CGFloat, dark: Bool,
                                           frame: @escaping (Int) -> V) -> [CGImage] {
        let k = "\(key)|\(size)|\(dark)|\(scale)"
        if let f = cache[k] { return f }
        // One renderer call for the whole strip, then slices: per-frame renderers cost ~1 ms each.
        let strip = VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in frame(i).frame(width: size.width, height: size.height, alignment: .leading) }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: strip)
        r.scale = scale
        r.isOpaque = false
        guard let img = r.cgImage else { return [] }
        let h = Int((size.height * scale).rounded()), w = Int((size.width * scale).rounded())
        let frames = (0..<count).compactMap { img.cropping(to: CGRect(x: 0, y: $0 * h, width: w, height: h)) }
        if cache.count > 24 { cache.removeAll() }
        cache[k] = frames
        return frames
    }

    /// Adds a layer that flips through `frames` over `duration`, forever.
    static func play(_ frames: [CGImage], duration: Double, in root: CALayer, size: CGSize, scale: CGFloat) {
        guard let first = frames.first else { return }
        let l = CALayer()
        l.frame = CGRect(origin: .zero, size: size)
        l.contentsScale = scale
        l.contentsGravity = .resize
        l.contents = first
        if frames.count > 1 {
            let a = CAKeyframeAnimation(keyPath: "contents")
            a.values = frames
            a.calculationMode = .discrete
            l.add(LayerAnimation.loop(a, duration: duration), forKey: "flip")
        }
        root.addSublayer(l)
    }
}

// MARK: - Activity dots and cursor

/// A small dot grid that ripples while an agent works: dots light up as rings spread from the centre,
/// like an instrument's activity lamp. Static (half lit) under Reduce Motion.
struct DotActivity: View {
    var size = 5
    var dot: CGFloat = 3
    var gap: CGFloat = 1.5
    var color: Color = Theme.accent

    var body: some View {
        let pitch = dot + gap
        LayerAnimation(key: "\(size)|\(dot)|\(gap)|" + LayerAnimation.key(color)) { root, _, scale in
            let c = Double(size - 1) / 2
            let period = 2 * Double.pi / 5
            let samples = 24
            let fill = LayerAnimation.cg(color)
            let start = CACurrentMediaTime()
            for y in 0..<size {
                for x in 0..<size {
                    let d = ((Double(x) - c) * (Double(x) - c) + (Double(y) - c) * (Double(y) - c)).squareRoot()
                    func alpha(_ t: Double) -> Float { let w = (sin(d * 1.6 - t * 5) + 1) / 2; return Float(0.15 + 0.85 * w * w) }
                    let l = CALayer()
                    l.frame = CGRect(x: CGFloat(x) * pitch, y: CGFloat(y) * pitch, width: dot, height: dot)
                    l.backgroundColor = fill
                    l.contentsScale = scale
                    l.opacity = Theme.Motion.allowed ? alpha(0) : Float(0.15 + 0.85 * 0.25)
                    if Theme.Motion.allowed {
                        let a = CAKeyframeAnimation(keyPath: "opacity")
                        a.values = (0...samples).map { alpha(period * Double($0) / Double(samples)) }
                        a.beginTime = start
                        l.add(LayerAnimation.loop(a, duration: period), forKey: "ripple")
                    }
                    root.addSublayer(l)
                }
            }
        }
        .frame(width: CGFloat(size) * pitch - gap, height: CGFloat(size) * pitch - gap)
        .accessibilityHidden(true)
    }
}

/// A block cursor that blinks while an agent works (static under Reduce Motion).
struct BlinkingCursor: View {
    var color: Color = Theme.accent
    var body: some View {
        LayerAnimation(key: LayerAnimation.key(color)) { root, size, _ in
            let l = CALayer()
            l.frame = CGRect(origin: .zero, size: size)
            l.backgroundColor = LayerAnimation.cg(color)
            if Theme.Motion.allowed {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1; a.toValue = 0.15
                a.autoreverses = true
                a.timingFunction = CAMediaTimingFunction(name: .linear)
                l.add(LayerAnimation.loop(a, duration: 0.55), forKey: "blink")
            }
            root.addSublayer(l)
        }
        .frame(width: 7, height: 13)
        .accessibilityHidden(true)
    }
}

// MARK: - Background sieve field

/// A field of dots that thins out downward, like grains passing through a sieve; the grains drift
/// slowly. Background only (empty states). The flicker is six phases of the field cross-faded by Core
/// Animation, so an idle empty window does no per-frame work.
struct SieveField: View {
    var pitch: CGFloat = 12
    /// Opacity at the vertical middle (the field fades from opaque at the top to clear at the bottom).
    var fadeMid: Double = 0.25

    var body: some View {
        LayerAnimation(key: "\(pitch)|\(fadeMid)") { root, size, _ in
            let speed = 0.8
            let period = 2 * Double.pi / speed
            let phases = Theme.Motion.allowed ? 6 : 1
            let ink = NSColor(Theme.ink).usingColorSpace(.sRGB) ?? .labelColor
            let cols = Int(size.width / pitch) + 1, rows = Int(size.height / pitch) + 1
            // 1× bitmaps with nearest-neighbour scaling: the dots are 2 pt squares, and six window-sized
            // frames at 2× would hold ~30 MB.
            let w = Int(size.width.rounded(.up)), h = Int(size.height.rounded(.up))
            func frame(_ t: Double) -> CGImage? {
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
                for y in 0..<rows {
                    let density = 1 - Double(y) / Double(max(rows, 1))
                    let fy = Double(y) * Double(pitch) / Double(max(size.height, 1))
                    let fade = fy < 0.5 ? 1 - (1 - fadeMid) * fy * 2 : fadeMid * (1 - (fy - 0.5) * 2)
                    for x in 0..<cols {
                        let hh = Double((x &* 2_654_435_761 ^ y &* 40_503) & 4095) / 4095
                        guard hh < density * 0.85 else { continue }
                        let flicker = (sin(t * speed + hh * 12) + 1) / 2
                        let a = (0.10 + 0.22 * flicker * density) * max(0, fade)
                        ctx.setFillColor(ink.withAlphaComponent(ink.alphaComponent * a).cgColor)
                        ctx.fill(CGRect(x: CGFloat(x) * pitch, y: CGFloat(y) * pitch, width: 2, height: 2))
                    }
                }
                return ctx.makeImage()
            }
            let frames = (0..<phases).compactMap { frame(period * Double($0) / Double(phases)) }
            guard let first = frames.first else { return }
            let l = CALayer()
            l.frame = CGRect(origin: .zero, size: size)
            l.contentsGravity = .resize
            l.contentsScale = 1
            l.magnificationFilter = .nearest
            l.contents = first
            if frames.count > 1 {
                // Linear keyframes on `contents` cross-fade between the phases.
                let a = CAKeyframeAnimation(keyPath: "contents")
                a.values = frames + [first]
                a.calculationMode = .linear
                l.add(LayerAnimation.loop(a, duration: period), forKey: "drift")
            }
            root.addSublayer(l)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
