import AppKit
import SieveSciCore
import SwiftUI
import WebKit

/// The SieveSci ghost (aurora palette): logo, app icon and loading indicator.
enum Brand {
    /// Static logo, rendered from SVG by AppKit (transparent background, sharp at any size).
    static let logo: NSImage = NSImage(data: Data(BrandSVG.aurora.utf8)) ?? NSImage()

    /// Dock / app switcher icon: the logo with a little breathing room, on a transparent canvas.
    static var appIcon: NSImage {
        let side: CGFloat = 1024
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        logo.draw(in: NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.06, dy: side * 0.06))
        img.unlockFocus()
        return img
    }
}

/// The logo as a SwiftUI view.
struct BrandLogo: View {
    var size: CGFloat
    var body: some View {
        Image(nsImage: Brand.logo)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Animated ghost used wherever SieveSci is working. The animation is SMIL inside the SVG, so it plays in
/// a transparent, non-interactive web view; with Reduce Motion on, the static logo is shown instead.
struct GhostLoader: View {
    var size: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                BrandLogo(size: size)
            } else {
                AnimatedSVGView(svg: BrandSVG.auroraAnimated)
                    .frame(width: size, height: size)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }
}

struct AnimatedSVGView: NSViewRepresentable {
    let svg: String

    final class PassthroughWebView: WKWebView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
    }

    func makeNSView(context: Context) -> WKWebView {
        let v = PassthroughWebView(frame: .zero, configuration: WKWebViewConfiguration())
        v.setValue(false, forKey: "drawsBackground")
        v.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;padding:0;background:transparent;overflow:hidden;width:100%;height:100%}
        svg{display:block;width:100%;height:100%}
        </style></head><body>\(svg)</body></html>
        """, baseURL: nil)
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {}
}

// MARK: - Role ghosts (research agent, worker, checker, blind verifier)

/// Each agent role's ghost: a full-colour logo, a monoline icon for icon slots, and a "working" animation.
/// Artwork comes from design/role-ghosts (embedded by scripts/embed-role-ghosts.py); a role without
/// artwork falls back to its SF Symbol.
enum RoleGhost {
    static func svg(_ role: AgentRole, _ kind: String) -> String {
        let all: [String: String]
        switch role {
        case .main: all = ["logo": RoleGhostSVG.main_logo, "line": RoleGhostSVG.main_line, "working": RoleGhostSVG.main_working,
                           "base": RoleGhostSVG.main_base, "prop": RoleGhostSVG.main_prop]
        case .worker: all = ["logo": RoleGhostSVG.worker_logo, "line": RoleGhostSVG.worker_line, "working": RoleGhostSVG.worker_working,
                             "base": RoleGhostSVG.worker_base, "prop": RoleGhostSVG.worker_prop]
        case .checker: all = ["logo": RoleGhostSVG.checker_logo, "line": RoleGhostSVG.checker_line, "working": RoleGhostSVG.checker_working,
                              "base": RoleGhostSVG.checker_base, "prop": RoleGhostSVG.checker_prop]
        case .verifier: all = ["logo": RoleGhostSVG.verifier_logo, "line": RoleGhostSVG.verifier_line, "working": RoleGhostSVG.verifier_working,
                               "base": RoleGhostSVG.verifier_base, "prop": RoleGhostSVG.verifier_prop]
        }
        return all[kind] ?? ""
    }

    private static var cache: [String: NSImage] = [:]

    /// Static image of a role's artwork; the line icon is a template image so it takes the tint.
    static func image(_ role: AgentRole, _ kind: String) -> NSImage? {
        let key = role.rawValue + kind
        if let i = cache[key] { return i }
        let src = svg(role, kind)
        guard !src.isEmpty, let img = NSImage(data: Data(src.utf8)) else { return nil }
        img.isTemplate = kind == "line"
        cache[key] = img
        return img
    }

    /// A bitmap of the artwork, drawn once: animating a bitmap is a cheap layer transform, while an
    /// SVG image would be re-rendered every frame.
    static func raster(_ role: AgentRole, _ kind: String, pixels: Int = 192) -> NSImage? {
        let key = role.rawValue + kind + "@\(pixels)"
        if let i = cache[key] { return i }
        guard let src = image(role, kind),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: pixels / 2, height: pixels / 2))
        out.addRepresentation(rep)
        cache[key] = out
        return out
    }
}

/// Monoline role icon for 14–24 pt slots, tinted (falls back to the role's SF Symbol).
struct RoleGhostIcon: View {
    let role: AgentRole
    var size: CGFloat = 16
    var tint: Color? = nil

    var body: some View {
        Group {
            if let img = RoleGhost.image(role, "line") {
                Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: Theme.roleIcon(role)).resizable().scaledToFit()
            }
        }
        .foregroundStyle(tint ?? Theme.roleColor(role))
        .frame(width: size, height: size)
        .accessibilityLabel(Theme.roleName(role))
    }
}

/// Full-colour role ghost; animated while the agent works (static with Reduce Motion).
struct RoleGhostBadge: View {
    let role: AgentRole
    var working = false
    var size: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if working && !reduceMotion, let base = RoleGhost.raster(role, "base") {
                animated(base)
            } else if let logo = RoleGhost.image(role, "logo") {
                Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
            } else {
                IconBadge(systemName: Theme.roleIcon(role), tint: Theme.roleColor(role), size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Theme.roleName(role) + (working ? " · " + L("working") : ""))
    }

    /// The working animation, run by Core Animation in the render server: no per-frame work in the app
    /// (a SwiftUI animation here re-ran hit-testing and tracking areas for the whole window each frame).
    func animated(_ base: NSImage) -> some View {
        GhostLayers(role: role, base: base, prop: RoleGhost.raster(role, "prop")).allowsHitTesting(false)
    }

}

/// The ghost floats (the brand logo's rig) while its role prop moves: the worker's gear turns, the
/// checker's glasses scan, the researcher's sparkles twinkle, the verifier sends sonar rings. Points
/// are in the artwork's 1254-unit canvas, top-left origin.
struct GhostLayers: NSViewRepresentable {
    let role: AgentRole
    let base: NSImage
    let prop: NSImage?

    final class LayerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isFlipped: Bool { true }
    }

    func makeNSView(context: Context) -> LayerView {
        let v = LayerView()
        v.wantsLayer = true
        v.layer?.masksToBounds = false
        return v
    }

    func updateNSView(_ v: LayerView, context: Context) {
        DispatchQueue.main.async { build(in: v) }
    }

    private func cg(_ i: NSImage) -> CGImage? { i.cgImage(forProposedRect: nil, context: nil, hints: nil) }

    private func build(in v: LayerView) {
        guard let root = v.layer else { return }
        let size = v.bounds.size
        guard size.width > 0, root.sublayers?.first?.frame.size != size else { return }
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        let scale = v.window?.backingScaleFactor ?? 2
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: size.width * x / 1254, y: size.height * y / 1254) }
        func loop(_ a: CAAnimation, _ d: CFTimeInterval, reverse: Bool = true) -> CAAnimation {
            a.duration = d; a.repeatCount = .infinity; a.autoreverses = reverse; a.isRemovedOnCompletion = false
            a.timingFunction = CAMediaTimingFunction(name: reverse ? .easeInEaseOut : .linear)
            return a
        }

        // The whole ghost: float and tilt around its bottom edge.
        let rig = CALayer()
        rig.frame = CGRect(origin: .zero, size: size)
        rig.anchorPoint = CGPoint(x: 0.5, y: 1)
        rig.position = CGPoint(x: size.width / 2, y: size.height)
        root.addSublayer(rig)
        let tilt = CABasicAnimation(keyPath: "transform.rotation.z")
        tilt.fromValue = -2.5 * .pi / 180; tilt.toValue = 2.5 * .pi / 180
        rig.add(loop(tilt, 2.1), forKey: "tilt")
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = size.height * 0.02; bob.toValue = -size.height * 0.035
        rig.add(loop(bob, 2.1), forKey: "bob")

        if role == .verifier {
            let c = point(705, 535), r = size.width * 0.24
            for i in 0..<2 {
                let ring = CAShapeLayer()
                ring.frame = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r), transform: nil)
                ring.fillColor = nil
                ring.strokeColor = NSColor(red: 0.13, green: 0.75, blue: 0.93, alpha: 1).cgColor
                ring.lineWidth = size.width * 0.035
                ring.opacity = 0
                let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 1; grow.toValue = 1.6
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.55; fade.toValue = 0
                let g = CAAnimationGroup(); g.animations = [grow, fade]
                g.duration = 2.1; g.repeatCount = .infinity; g.timingFunction = CAMediaTimingFunction(name: .easeOut)
                g.beginTime = CACurrentMediaTime() + Double(i) * 1.05; g.fillMode = .backwards
                ring.add(g, forKey: "pulse")
                rig.addSublayer(ring)
            }
        }

        let body = CALayer()
        body.frame = CGRect(origin: .zero, size: size)
        body.contents = cg(base); body.contentsScale = scale; body.contentsGravity = .resizeAspect
        rig.addSublayer(body)

        guard let prop, let image = cg(prop) else { return }
        let layer = CALayer()
        layer.contents = image; layer.contentsScale = scale; layer.contentsGravity = .resizeAspect
        let pivot: CGPoint
        switch role {
        case .worker: pivot = point(1092, 300)
        case .checker: pivot = point(810, 570)
        default: pivot = point(1000, 260)
        }
        // Rotate/scale around the prop's own centre: anchor there, keep the image where it was drawn.
        layer.anchorPoint = CGPoint(x: pivot.x / size.width, y: pivot.y / size.height)
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = pivot
        rig.addSublayer(layer)
        switch role {
        case .worker:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z"); spin.fromValue = 0; spin.toValue = 2 * Double.pi
            layer.add(loop(spin, 8.4, reverse: false), forKey: "spin")
        case .checker:
            let scan = CABasicAnimation(keyPath: "transform.translation.x")
            scan.fromValue = -size.width * 0.025; scan.toValue = size.width * 0.025
            layer.add(loop(scan, 1.05), forKey: "scan")
        default:
            let twinkle = CABasicAnimation(keyPath: "opacity"); twinkle.fromValue = 0.35; twinkle.toValue = 1
            layer.add(loop(twinkle, 0.7), forKey: "twinkle")
            let pop = CABasicAnimation(keyPath: "transform.scale"); pop.fromValue = 0.9; pop.toValue = 1.06
            layer.add(loop(pop, 0.7), forKey: "pop")
        }
    }
}

/// Authorship, shown on the welcome page, in About and in Settings → General.
enum Credits {
    static var line: String { L("Independently developed by 王鹤年, 2026") }

    static func showAboutPanel() {
        let credits = NSAttributedString(string: line + "\nhttps://github.com/Cetirzine/SieveSci",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "SieveSci", .applicationVersion: SieveSci.version,
                                                     .credits: credits, NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 王鹤年"])
        NSApp.activate(ignoringOtherApps: true)
    }
}
