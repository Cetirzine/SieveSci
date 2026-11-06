import SieveSciCore
import SwiftUI

/// Reasoning effort as a stepped dot-matrix gauge: three rows of square dots inside a 1 px frame, lit
/// up to a square thumb that drags, snaps and springs between stops. The lit dots run from green to
/// the accent with a band of light flowing through them, faster the higher the effort; at the top
/// stop the gauge turns hot (amber to red) and glitches like a failing signal (see `Glitch`).
/// Still under Reduce Motion. `nil` is the model's default.
struct EffortSlider: View {
    @Binding var effort: Effort?
    var compact = false

    static let stops: [Effort?] = [nil] + Effort.allCases.map { Optional($0) }
    static func name(_ e: Effort?) -> String { e.map { L($0.rawValue) } ?? L("Model default") }
    static var maxLevel: Int { stops.count - 1 }

    @State private var dragX: CGFloat?
    private var index: Int { Self.stops.firstIndex(of: effort) ?? 0 }

    static let thumb: CGFloat = 18
    static let dot: CGFloat = 3
    static let gap: CGFloat = 1.5
    static let rows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            GeometryReader { g in
                let n = CGFloat(Self.maxLevel)
                let half = Self.thumb / 2
                let step = (g.size.width - Self.thumb) / max(n, 1)
                let x = dragX ?? CGFloat(index) * step
                // While dragging, the gauge already shows the stop it will snap to.
                let level = Int((x / max(step, 1)).rounded())
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !Theme.Motion.allowed)) { tl in
                    let t = Theme.Motion.allowed ? tl.date.timeIntervalSinceReferenceDate : 0
                    let hot = level == Self.maxLevel
                    let glitch = hot && Theme.Motion.allowed ? Self.glitch(t) : nil
                    ZStack(alignment: .leading) {
                        Canvas { ctx, size in
                            // Lit up to under the thumb's centre (the canvas starts 4 pt left of the first stop).
                            Self.drawGauge(ctx, size: size, litEdge: x + 4 + 1, level: level, t: t, glitch: glitch)
                        }
                        .frame(height: 16)
                        .overlay(Rectangle().strokeBorder(hot ? Theme.bad.opacity(0.6) : Theme.rule, lineWidth: 1))
                        .overlay { if let glitch { GlitchFrame(glitch: glitch) } }
                        .padding(.horizontal, half - 4)
                        thumbView(level: level, hot: hot, glitch: glitch)
                            .offset(x: x + (glitch?.thumbJitter ?? 0), y: glitch?.thumbLift ?? 0)
                    }
                    .frame(height: 24)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in dragX = min(max(0, v.location.x - half), n * step) }
                    .onEnded { v in
                        let i = Int((min(max(0, v.location.x - half), n * step) / max(step, 1)).rounded())
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { effort = Self.stops[i]; dragX = nil }
                    })
            }
            .frame(height: 24)
            if !compact {
                HStack {
                    ForEach(Array(Self.stops.enumerated()), id: \.offset) { i, s in
                        if i == Self.maxLevel && i == index {
                            GlitchLabel(text: L(s!.rawValue))
                        } else {
                            Text(i == 0 ? L("default") : L(s!.rawValue))
                                .font(Theme.label)
                                .foregroundStyle(i == index ? Theme.accent : .secondary)
                        }
                        if i < Self.stops.count - 1 { Spacer(minLength: 0) }
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L("Reasoning effort"))
        .accessibilityValue(Self.name(effort))
        .accessibilityAdjustableAction { dir in
            let i = dir == .increment ? min(index + 1, Self.maxLevel) : max(index - 1, 0)
            withAnimation(Theme.Motion.settle) { effort = Self.stops[i] }
        }
    }

    /// Square paper thumb with an ink frame and hard shadow; its core shows the level's colour. In a
    /// glitch burst its frame splits into accent and red copies.
    private func thumbView(level: Int, hot: Bool, glitch: Glitch?) -> some View {
        let split = glitch.map { $0.split * $0.intensity } ?? 0
        return Rectangle().fill(Theme.raised)
            .frame(width: Self.thumb, height: Self.thumb)
            .overlay(Rectangle().fill(Self.color(level: level, at: 1)).frame(width: 6, height: 6)
                .offset(x: glitch.map { $0.intensity > 0.6 ? $0.thumbJitter : 0 } ?? 0))
            .overlay(Rectangle().strokeBorder(hot ? Theme.bad : Theme.ink, lineWidth: 1.5))
            .background {
                if split > 0.3 {
                    Rectangle().strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1.5).offset(x: -split)
                    Rectangle().strokeBorder(Theme.bad.opacity(0.8), lineWidth: 1.5).offset(x: split, y: split * 0.4)
                }
            }
            .hardShadow(pressed: dragX != nil, offset: 2)
    }

    /// Lit-dot colour along the gauge (`at` 0…1): green to accent, or amber to red at the top stop.
    static func color(level: Int, at f: Double) -> Color {
        level == maxLevel ? (f < 0.5 ? Theme.warn : Theme.bad) : (f < 0.5 ? Theme.ok : Theme.accent)
    }

    /// One frame of the top stop's signal failure. Calm stretches (a faint colour fringe, the odd lost
    /// dot) alternate with bursts re-rolled every frame: torn row segments slip sideways, colours split
    /// wide, a block of dots turns to static, a row smears into streaks, the frame and thumb ghost.
    struct Glitch {
        struct Tear { var row: Int; var from: Double; var to: Double; var shift: CGFloat }
        var intensity: Double          // 0 calm … 1 burst peak
        var frame: Int
        var tears: [Tear]              // spans as fractions of the gauge width; shift in dots
        var split: CGFloat             // colour fringe at full intensity, in points
        var noise: (from: Double, to: Double, row: Int, rows: Int)?
        var smearRow: Int?
        var thumbJitter: CGFloat
        var thumbLift: CGFloat
    }

    static func glitch(_ t: Double) -> Glitch {
        let window = Int(t * 5)                  // 0.2 s windows decide calm or burst
        let frame = Int(t * 30)
        let burst = hash(window, 11) > 0.5
        // Inside a burst the intensity flickers frame to frame instead of ramping smoothly.
        let intensity = burst ? 0.45 + 0.55 * hash(frame, 3) : 0.12 * hash(frame, 3)
        var tears: [Glitch.Tear] = []
        if burst {
            for k in 0..<(1 + Int(hash(frame, 21) * 3)) {
                let from = hash(frame, 30 + k) * 0.8
                tears.append(.init(row: Int(hash(frame, 40 + k) * Double(rows)) % rows, from: from,
                                   to: min(1, from + 0.12 + hash(frame, 50 + k) * 0.4),
                                   shift: (hash(frame, 60 + k) > 0.5 ? 1 : -1) * CGFloat(1 + Int(hash(frame, 70 + k) * 4))))
            }
        }
        let noise: (Double, Double, Int, Int)? = burst && hash(frame, 80) > 0.55
            ? { let a = hash(frame, 81) * 0.85; return (a, a + 0.06 + hash(frame, 82) * 0.12, Int(hash(frame, 83) * 3) % 3, 1 + Int(hash(frame, 84) * 2)) }()
            : nil
        return Glitch(intensity: intensity, frame: frame, tears: tears,
                      split: 0.8 + CGFloat(hash(frame, 4)) * 2.4,
                      noise: noise,
                      smearRow: burst && hash(frame, 90) > 0.6 ? Int(hash(frame, 91) * 3) % 3 : nil,
                      thumbJitter: burst ? (CGFloat(hash(frame, 5)) - 0.5) * 4 : 0,
                      thumbLift: burst && hash(frame, 6) > 0.8 ? (CGFloat(hash(frame, 7)) - 0.5) * 2 : 0)
    }

    static func hash(_ a: Int, _ b: Int) -> Double {
        Double(UInt32(truncatingIfNeeded: (a &* 73_856_093) ^ (b &* 19_349_663) ^ 0x5bd1e995) % 1024) / 1023
    }

    /// Draws the dot rows; columns starting left of `litEdge` are lit. Shared by the slider and the
    /// composer's mini gauge (smaller dots, same colours, flow and glitch).
    static func drawGauge(_ ctx: GraphicsContext, size: CGSize, litEdge: CGFloat, level: Int, t: Double, glitch: Glitch?,
                          dot: CGFloat = EffortSlider.dot, gap: CGFloat = EffortSlider.gap, inset: CGFloat = 4, rows: Int = EffortSlider.rows) {
        let pitch = dot + gap
        let cols = max(1, Int((size.width - inset * 2 + gap) / pitch))
        let top = (size.height - CGFloat(rows) * pitch + gap) / 2
        let litCols = min(cols, max(0, Int((litEdge - inset) / pitch) + 1))
        // Flow speed grows with the level: the band crosses the gauge in ~3 s at low, well under 1 s at max.
        let speed = 3.0 + Double(level) * 3.2
        let scale = dot / EffortSlider.dot
        for c in 0..<cols {
            let f = Double(c) / Double(max(cols - 1, 1))
            for r in 0..<rows {
                var px = inset + CGFloat(c) * pitch
                let py = top + CGFloat(r) * pitch
                guard c < litCols else {
                    ctx.fill(Path(CGRect(x: px, y: py, width: dot, height: dot)), with: .color(Theme.rule.opacity(0.7)))
                    continue
                }
                var width = dot
                var staticColor: Color?
                if let g = glitch {
                    for tear in g.tears where tear.row % rows == r && f >= tear.from && f <= tear.to { px += tear.shift * pitch }
                    if hash(c &* 31 &+ r, g.frame) > 1 - 0.14 * g.intensity { continue }        // lost dots
                    if let n = g.noise, f >= n.from, f <= n.to, r >= n.row % rows, r < n.row % rows + n.rows {
                        staticColor = hash(c &* 13 &+ r, g.frame) > 0.5 ? Theme.ink : .white
                    }
                    if g.smearRow.map({ $0 % rows == r }) == true, hash(c, g.frame &+ 5) > 0.55 { width = dot + pitch * 2 }
                }
                let wave = (sin(Double(c) * 0.45 - t * speed) + 1) / 2
                let sparkle = hash(c &* 7 &+ r, Int(t * 3) &+ c) > 0.965
                let alpha = sparkle ? 1 : 0.45 + 0.55 * wave * wave
                let rect = CGRect(x: px, y: py, width: width, height: dot)
                if let staticColor {
                    ctx.fill(Path(rect), with: .color(staticColor.opacity(0.9)))
                    continue
                }
                if let g = glitch {
                    // Chromatic fringe: an accent copy to the left, a red one to the right, wider in a burst.
                    let d = (0.5 + g.split * g.intensity) * scale
                    ctx.fill(Path(rect.offsetBy(dx: -d, dy: 0)), with: .color(Theme.accent.opacity(0.55 * alpha)))
                    ctx.fill(Path(rect.offsetBy(dx: d, dy: g.intensity > 0.7 ? 0.5 : 0)), with: .color(Theme.bad.opacity(0.55 * alpha)))
                }
                // Two-stop ramp drawn as a blend: the far colour over the near one, weighted by position.
                ctx.fill(Path(rect), with: .color(color(level: level, at: 0).opacity(alpha * (width > dot ? 0.6 : 1))))
                ctx.fill(Path(rect), with: .color(color(level: level, at: 1).opacity(alpha * f)))
                if sparkle { ctx.fill(Path(rect), with: .color(.white.opacity(0.6))) }
            }
        }
    }
}

/// The gauge frame's ghost in a glitch burst: accent and red copies of the border, offset apart.
struct GlitchFrame: View {
    let glitch: EffortSlider.Glitch
    var body: some View {
        let d = glitch.split * glitch.intensity
        if glitch.intensity > 0.55 {
            ZStack {
                Rectangle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1).offset(x: -d, y: -d * 0.3)
                Rectangle().strokeBorder(Theme.bad.opacity(0.7), lineWidth: 1).offset(x: d, y: d * 0.3)
            }
            .allowsHitTesting(false)
        }
    }
}

/// The "max" label under a glitching gauge: in bursts it flickers through corrupted spellings and
/// splits into accent and red, like the dots above it.
struct GlitchLabel: View {
    let text: String
    /// Slack around the text for the colour fringe, the jitter and wider look-alike glyphs.
    static let margin: CGFloat = 6
    /// The burst pattern is re-rolled every 1/30 s; four seconds of it loop without a visible seam.
    static let loop = 4.0, fps = 30.0

    var body: some View {
        // The static text sizes the control; the glitching copy is a flip book played by Core Animation
        // (a 30 fps TimelineView here re-laid-out the whole window, see `LayerAnimations.swift`).
        Self.face(text, t: nil)
            .opacity(Theme.Motion.allowed ? 0 : 1)
            .overlay {
                if Theme.Motion.allowed {
                    LayerAnimation(key: "glitch|" + text) { root, size, scale in
                        let n = Int(Self.loop * Self.fps)
                        let frames = SpriteFrames.render("glitch|" + text, count: n, size: size, scale: scale, dark: LayerAnimation.dark) { i in
                            Self.face(text, t: Double(i) / Self.fps).fixedSize().padding(.leading, Self.margin)
                        }
                        SpriteFrames.play(frames, duration: Self.loop, in: root, size: size, scale: scale)
                    }
                    .padding(.horizontal, -Self.margin)
                }
            }
    }

    /// One frame of the label at time `t` (nil: the calm, static label).
    static func face(_ text: String, t: Double?) -> some View {
        let g = t.map { EffortSlider.glitch($0) }
        let shown = g.map { $0.intensity > 0.6 ? Self.corrupt(text, $0.frame) : text } ?? text
        let d = g.map { $0.split * $0.intensity * 0.6 } ?? 0
        return Text(shown)
            .font(Theme.label)
            .foregroundStyle(Theme.bad)
            .background {
                if d > 0.4 {
                    Text(shown).font(Theme.label).foregroundStyle(Theme.accent.opacity(0.7)).offset(x: -d)
                    Text(shown).font(Theme.label).foregroundStyle(Theme.bad.opacity(0.5)).offset(x: d, y: 0.5)
                }
            }
            .offset(x: g.map { $0.intensity > 0.85 ? $0.thumbJitter * 0.5 : 0 } ?? 0)
    }

    /// Swaps a character or two for look-alikes and block glyphs; the length stays, so nothing reflows.
    static func corrupt(_ s: String, _ frame: Int) -> String {
        let swaps: [Character: [Character]] = ["a": ["4", "@", "▚"], "x": ["×", "%", "▞"], "m": ["M", "rn", "▙"].map { $0.first! },
                                                "i": ["1", "!", "▌"], "g": ["9", "6", "▟"], "h": ["#", "H", "▜"]]
        return String(s.enumerated().map { i, ch in
            guard EffortSlider.hash(i, frame &* 3) > 0.72, let opts = swaps[Character(ch.lowercased())] else {
                return EffortSlider.hash(i, frame) > 0.8 ? Character(ch.uppercased()) : ch
            }
            return opts[Int(EffortSlider.hash(i &+ 9, frame) * Double(opts.count)) % opts.count]
        })
    }
}

/// The composer's effort readout: the slider's gauge in miniature (2 pt dots, one cell per stop's
/// share), flowing faster with the level and glitching at the top stop.
struct EffortMiniGauge: View {
    let effort: Effort?
    var level: Int { EffortSlider.stops.firstIndex(of: effort) ?? 0 }

    var body: some View {
        let hot = level == EffortSlider.maxLevel
        Group {
            if Theme.Motion.allowed {
                // Always on screen, so it must cost nothing per frame: a flip book of one seamless loop of
                // the flow, played by Core Animation (see `LayerAnimations.swift`).
                LayerAnimation(key: "gauge|\(level)") { root, size, scale in
                    let (count, duration) = Self.loop(level: level)
                    let frames = SpriteFrames.render("gauge|\(level)", count: count, size: size, scale: scale, dark: LayerAnimation.dark) { i in
                        Self.canvas(level: level, t: duration * Double(i) / Double(count), glitch: hot)
                    }
                    SpriteFrames.play(frames, duration: duration, in: root, size: size, scale: scale)
                }
            } else {
                Self.canvas(level: level, t: 0, glitch: false)
            }
        }
        .frame(width: 44, height: 13)
        .overlay(Rectangle().strokeBorder(hot ? Theme.bad.opacity(0.6) : Theme.rule, lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// Frames and length of one loop: a whole number of flow periods (the band's speed grows with the
    /// level), about three seconds, sampled at 30 fps.
    static func loop(level: Int) -> (count: Int, duration: Double) {
        let period = 2 * Double.pi / (3.0 + Double(level) * 3.2)
        let duration = max(1, (3 / period).rounded()) * period
        return (max(1, Int((duration * 30).rounded())), duration)
    }

    static func canvas(level: Int, t: Double, glitch: Bool) -> some View {
        Canvas { ctx, size in
            // The default level still lights one column, so the gauge never reads as off.
            let edge = 2 + (size.width - 4) * CGFloat(max(level, 0)) / CGFloat(EffortSlider.maxLevel)
            EffortSlider.drawGauge(ctx, size: size, litEdge: max(edge, 3), level: level, t: t,
                                   glitch: glitch ? EffortSlider.glitch(t) : nil, dot: 2, gap: 1, inset: 2, rows: 3)
        }
    }
}

/// Composer control: the bars and the level; click opens the slider.
struct EffortMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                EffortMiniGauge(effort: model.config.effort)
                if model.config.effort == EffortSlider.stops.last! {
                    GlitchLabel(text: EffortSlider.name(model.config.effort))
                } else {
                    Text(EffortSlider.name(model.config.effort)).font(Theme.monoTiny).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6).frame(height: Theme.Control.icon)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Reasoning effort"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(L("Reasoning effort"))
                EffortSlider(effort: $model.config.effort)
            }
            .padding(Theme.Space.l)
            .frame(width: 340)
        }
    }
}
