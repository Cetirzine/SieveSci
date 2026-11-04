import AppKit
import SieveSciCore
import SwiftUI

/// Accent colours the user can pick (Settings → General → Appearance).
enum AccentTheme: String, CaseIterable, Identifiable {
    case blue, violet, green, orange, graphite
    var id: String { rawValue }
    static let storageKey = "accentTheme"
    static var current: AccentTheme { UserDefaults.standard.string(forKey: storageKey).flatMap(AccentTheme.init(rawValue:)) ?? .blue }

    var name: String {
        switch self {
        case .blue: return L("Blue")
        case .violet: return L("Violet")
        case .green: return L("Green")
        case .orange: return L("Orange")
        case .graphite: return L("Graphite")
        }
    }

    var color: Color {
        switch self {
        case .blue: return Color(light: 0x4D6BFE, dark: 0x6E8AFF)
        case .violet: return Color(light: 0x7657F2, dark: 0x9B86FF)
        case .green: return Color(light: 0x13906A, dark: 0x3CC28F)
        case .orange: return Color(light: 0xE0702A, dark: 0xF39A5C)
        case .graphite: return Color(light: 0x3F3F46, dark: 0xA1A1AA)
        }
    }
}

/// Design tokens. The look is a specimen sheet: square frames and 1 px rules, monospaced labels and
/// readouts, one accent colour. Lines carry meaning: a solid frame is settled (verified, approved, the
/// user's own), a dashed one is provisional (proposed by an agent, waiting for review or a decision).
/// Colours resolve per appearance.
enum Theme {
    // MARK: Colour

    static var accent: Color { AccentTheme.current.color }
    static var accentSoft: Color { accent.opacity(0.11) }
    static let ok = Color(light: 0x16935C, dark: 0x4CC38A)
    static let warn = Color(light: 0xC27C0E, dark: 0xE8B04B)
    static let bad = Color(light: 0xD93D3D, dark: 0xF06A6A)
    static let info = Color(light: 0x2F80ED, dark: 0x6AA7FF)

    /// Main content background.
    static let canvas = Color(light: 0xFFFFFF, dark: 0x1A1A1D)
    /// Sidebar and settings navigation.
    static let sidebar = Color(light: 0xF7F7F8, dark: 0x202024)
    /// Raised controls: the composer, buttons on the sidebar, the permission prompt.
    static let raised = Color(light: 0xFFFFFF, dark: 0x27272B)
    /// Filled areas: inline code, output blocks.
    static let surface = Color(light: 0xF2F3F5, dark: 0x2C2C31)
    /// Quieter fill for grouped content (reviews, banners).
    static let surfaceSubtle = Color(light: 0xF7F8FA, dark: 0x232327)
    /// Selected row in lists.
    static let selection = Color(light: 0x000000, dark: 0xFFFFFF, alpha: 0.065)
    static let hairline = Color(light: 0x000000, dark: 0xFFFFFF, alpha: 0.08)
    static let separator = Color(light: 0x000000, dark: 0xFFFFFF, alpha: 0.16)
    /// Frame strokes: strong enough to read as drawn lines, not shadows.
    static let rule = Color(light: 0x000000, dark: 0xFFFFFF, alpha: 0.24)
    /// Inverted label tabs (ink on paper, flipped).
    static let ink = Color(light: 0x18181B, dark: 0xECECEE)
    static let paper = Color(light: 0xFFFFFF, dark: 0x1A1A1D)
    static let dim = Color.secondary

    // Kept for callers that still pass the colour scheme.
    static func background(_ scheme: ColorScheme) -> Color { canvas }
    static func panel(_ scheme: ColorScheme) -> Color { surfaceSubtle }
    static func border(_ scheme: ColorScheme) -> Color { separator }

    // MARK: Type

    static let title = Font.system(size: 24, weight: .semibold)
    /// Large tight headline (welcome, empty states); use with `.tracking(-0.8)`.
    static let display = Font.system(size: 34, weight: .semibold)
    /// Labels on tabs, section heads and readouts.
    static let label = Font.system(size: 10.5, weight: .medium, design: .monospaced)
    static let prose = Font.system(size: 15)
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let meta = Font.system(size: 12)
    static let metaStrong = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11)
    static let mono = Font.system(size: 13, design: .monospaced)
    static let monoSmall = Font.system(size: 12, design: .monospaced)
    static let monoTiny = Font.system(size: 11, design: .monospaced)

    // MARK: Grid

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Nearly square: frames are drawn, not pillowed.
    enum Radius {
        static let s: CGFloat = 2
        static let m: CGFloat = 3
        static let l: CGFloat = 4
    }

    /// One easing for every hover and state change, a short spring for things that appear, a slow
    /// linear blink for "working". Reduce Motion turns the appear and blink off (see `Motion.allowed`).
    enum Motion {
        static let hover = Animation.timingCurve(0.12, 0.23, 0.5, 1, duration: 0.2)
        static let settle = Animation.timingCurve(0.12, 0.23, 0.5, 1, duration: 0.45)
        static let appear = Animation.spring(response: 0.32, dampingFraction: 0.82)
        static var allowed: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }

    /// One size per kind of button, used on every page.
    enum Control {
        /// Square icon buttons (title bar, sidebar, inspector tabs, composer).
        static let icon: CGFloat = 28
        /// Full-width list-row buttons (sidebar, settings navigation).
        static let row: CGFloat = 32
        /// Text buttons (`ActionButtonStyle`): one height everywhere.
        static let button: CGFloat = 28
        /// Width of text buttons that share a column or row, so aligned buttons are equal.
        static let buttonWidth: CGFloat = 112
        /// Text inputs in settings rows.
        static let fieldWidth: CGFloat = 300
    }

    /// Width of the transcript and composer column.
    static let readingWidth: CGFloat = 760
    /// The transcript's width in wide windows; messages inside keep `readingWidth`.
    static let transcriptWidth: CGFloat = 1400
    /// Width of the leading icon column in compact transcript rows.
    static let gutter: CGFloat = 16

    // MARK: Semantics

    static func verdictColor(_ v: String) -> Color {
        switch v {
        case "pass", "verified", "concede", "agree", "withdrawn": return ok
        case "block", "refuted", "contested": return bad
        default: return warn
        }
    }

    static func deliberationColor(_ kind: String) -> Color {
        switch kind {
        case "concede", "agree": return ok
        case "disagree", "maintain": return warn
        default: return accent
        }
    }

    static func roleColor(_ r: AgentRole) -> Color {
        switch r {
        case .main: return accent
        case .checker: return info
        case .verifier: return Color(light: 0x1E8780, dark: 0x4FC3BA)
        case .worker: return Color(light: 0x7D6C57, dark: 0xB8A992)
        }
    }

    /// Names of the built-in tools as people read them (MCP and unknown tools keep their own names).
    static let toolNames: [String: String] = [
        "bash": "Terminal", "python": "Python", "read_file": "Read file", "write_file": "Write file", "edit_file": "Edit file",
        "glob": "Find files", "grep": "Search in files", "web_search": "Web search", "web_fetch": "Open web page",
        "literature_search": "Literature search", "paper_fetch": "Add paper", "paper_read": "Read paper", "paper_code_links": "Paper–code links",
        "paper_graph": "Citation graph", "library_search": "Search library", "bio_db": "Database", "chem_lookup": "Chemical lookup",
        "bio_tool_search": "Biomni tools", "repo_map": "Code map", "update_plan": "Plan", "claim_finding": "Register finding",
        "todo_write": "To-do", "goal": "Goal", "task": "Worker agent", "dispatch": "Batch agents", "skill": "Skill", "skill_env": "Skill environment",
        "receipt": "Receipt", "job_output": "Job output", "job_watch": "Watch job", "respond_review": "Reply to review",
        "verify_citation": "Verify citation", "memory": "Memory", "session_search": "Search past sessions", "skill_manage": "Manage skills",
        "ask_user": "Question for you", "brainstorm": "Brainstorm", "idea": "Ideas", "ideation_seeds": "Idea seeds",
    ]

    static func toolTitle(_ n: String) -> String {
        if let name = toolNames[n] { return L(name) }
        if n.hasPrefix("mcp__") { return n.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: ":") }
        return n.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    static func toolIcon(_ n: String) -> String {
        switch n {
        case "bash": return "terminal"
        case "python": return "chevron.left.forwardslash.chevron.right"
        case "read_file", "glob", "grep", "repo_map": return "doc.text.magnifyingglass"
        case "write_file", "edit_file": return "pencil"
        case "web_search", "web_fetch": return "globe"
        case "literature_search", "paper_fetch", "paper_read", "library_search", "paper_code_links", "paper_graph": return "books.vertical"
        case "bio_db": return "cylinder.split.1x2"
        case "verify_citation": return "checkmark.seal"
        case "update_plan", "todo_write", "goal": return "list.bullet.clipboard"
        case "claim_finding": return "flag"
        case "ask_user": return "questionmark.bubble"
        case "brainstorm", "idea", "ideation_seeds": return "lightbulb"
        case "dispatch", "task": return "person.3"
        case "respond_review": return "arrow.left.arrow.right"
        case "job_output", "job_watch": return "waveform"
        case "chem_lookup": return "atom"
        case "bio_tool_search": return "allergens"
        case "memory", "skill_manage", "session_search", "skill", "skill_env": return "brain"
        default: return n.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    static func roleIcon(_ r: AgentRole) -> String {
        switch r {
        case .main: return "sparkle"
        case .checker: return "eye"
        case .verifier: return "checkmark.shield"
        case .worker: return "hammer"
        }
    }

    static func roleName(_ r: AgentRole) -> String {
        switch r {
        case .main: return L("Research agent")
        case .checker: return L("Checker")
        case .verifier: return L("Blind verifier")
        case .worker: return L("Worker")
        }
    }

    /// "checker-ab12cd" → "Checker ab12cd"; "main" → "Research agent".
    static func agentName(_ id: String) -> String {
        if id == "main" { return roleName(.main) }
        let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
        guard let role = parts.first.flatMap(AgentRole.init(rawValue:)) else { return id }
        return roleName(role) + (parts.count > 1 ? " " + parts[1] : "")
    }

    static func literatureIcon(_ a: LiteratureAction) -> String {
        switch a {
        case .searched: return "magnifyingglass"
        case .added: return "plus.square.on.square"
        case .read: return "book"
        case .verified: return "checkmark.seal"
        case .flagged: return "exclamationmark.triangle"
        }
    }
}

extension Color {
    /// A colour with separate light and dark values (sRGB hex), resolved by the view's appearance.
    init(light: UInt32, dark: UInt32, alpha: CGFloat = 1) {
        func rgb(_ h: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: alpha)
        }
        let l = rgb(light), d = rgb(dark)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        })
    }
}

// MARK: - Shared building blocks

/// Grouped content block: a drawn frame on the canvas. A highlight colour becomes a leading rule; a
/// `provisional` block (waiting for review or a decision) has a dashed frame; a `tab` names who or
/// what produced it, as a label on the frame's top edge.
struct BoxStyle: ViewModifier {
    var highlight: Color? = nil
    var provisional = false
    var tab: String? = nil
    var tabTint: Color = Theme.ink
    func body(content: Content) -> some View {
        content
            .padding(Theme.Space.m)
            .padding(.top, tab == nil ? 0 : Theme.Space.xs)
            .padding(.leading, highlight == nil ? 0 : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceSubtle.opacity(0.6))
            .overlay(alignment: .leading) {
                if let highlight { Rectangle().fill(highlight).frame(width: 3) }
            }
            .overlay(FrameStroke(provisional: provisional))
            .overlay(alignment: .topLeading) {
                if let tab { LabelTab(text: tab, tint: tabTint).offset(x: Theme.Space.m, y: -8) }
            }
            .padding(.top, tab == nil ? 0 : 8)
    }
}

/// The 1 px frame: solid when settled, dashed when provisional.
struct FrameStroke: View {
    var provisional = false
    var color: Color = Theme.rule
    var body: some View {
        Rectangle().strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: provisional ? [4, 3] : []))
    }
}

/// An inverted monospaced label sitting on a frame's edge: which agent, tool or record this is.
struct LabelTab: View {
    let text: String
    var tint: Color = Theme.ink
    var body: some View {
        Text(text)
            .font(Theme.label)
            .textCase(.uppercase)
            .tracking(0.6)
            .lineLimit(1)
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(Rectangle().fill(tint))
    }
}

/// Crop marks at the four corners, as on a print proof (welcome, empty states).
struct CropMarks: View {
    var length: CGFloat = 10
    var inset: CGFloat = -14
    var body: some View {
        GeometryReader { g in
            Path { p in
                let r = g.frame(in: .local).insetBy(dx: inset, dy: inset)
                for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
                    p.move(to: CGPoint(x: x + dx * length, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy * length))
                }
            }
            .stroke(Theme.rule, lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A faint dot grid, like a slide's counting grid (welcome and empty states only).
struct DotGrid: View {
    var spacing: CGFloat = 14
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(Theme.separator))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}


/// A hard offset shadow with no blur. The shadow stays where it is; a pressed control moves into it,
/// abruptly, like a physical key.
struct HardShadow: ViewModifier {
    var pressed = false
    var offset: CGFloat = 3
    var color: Color = Theme.ink
    func body(content: Content) -> some View {
        content
            .offset(x: pressed ? offset : 0, y: pressed ? offset : 0)
            .background(Rectangle().fill(color).offset(x: offset, y: offset))
            .animation(.linear(duration: 0.06), value: pressed)
    }
}

/// Pops a view in when it appears (scale 0.96 → 1, fade), once.
struct AppearPop: ViewModifier {
    @State private var shown = !Theme.Motion.allowed
    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.96, anchor: .topLeading)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(Theme.Motion.appear) { shown = true } }
    }
}

/// Nested thread: content indented behind a thin vertical rule (agent streams, reviews, quotes).
struct ThreadRule: ViewModifier {
    var color: Color
    var width: CGFloat = 2
    func body(content: Content) -> some View {
        content
            .padding(.leading, Theme.Space.m)
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(color).frame(width: width) }
    }
}

/// Code / output block.
struct CodeBlockStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Rectangle().fill(Theme.surface))
            .overlay(alignment: .leading) { Rectangle().fill(Theme.rule).frame(width: 1) }
    }
}

extension View {
    func box(highlight: Color? = nil, provisional: Bool = false, tab: String? = nil, tabTint: Color = Theme.ink) -> some View {
        modifier(BoxStyle(highlight: highlight, provisional: provisional, tab: tab, tabTint: tabTint))
    }
    func appearPop() -> some View { modifier(AppearPop()) }
    func hardShadow(pressed: Bool = false, offset: CGFloat = 3, color: Color = Theme.ink) -> some View {
        modifier(HardShadow(pressed: pressed, offset: offset, color: color))
    }
    func threadRule(_ color: Color, width: CGFloat = 2) -> some View { modifier(ThreadRule(color: color, width: width)) }
    func codeBlock() -> some View { modifier(CodeBlockStyle()) }
}

/// Small monospaced uppercase heading for groups, led by a short rule: "── WORKSPACE".
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Theme.rule).frame(width: 10, height: 1)
            Text(text)
                .font(Theme.label)
                .textCase(.uppercase)
                .tracking(0.8)
        }
        .foregroundStyle(.secondary)
    }
}

/// SF Symbol on a soft tinted square (agent roles, prompt headers).
struct IconBadge: View {
    let systemName: String
    var tint: Color = Theme.accent
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Rectangle().fill(tint.opacity(0.12)))
            .overlay(Rectangle().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

/// A keyboard key hint ("1", "⌘↩").
struct Keycap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 2)
            .background(Rectangle().fill(Theme.surface))
            .overlay(Rectangle().strokeBorder(Theme.rule))
    }
}

/// Small square label (verdicts, stages, modes), monospaced like a specimen tag.
struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(text)
        }
        .font(Theme.label)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(Rectangle().fill(tint.opacity(0.12)))
        .overlay(Rectangle().strokeBorder(tint.opacity(0.4), lineWidth: 1))
    }
}

/// Borderless icon button with a hover fill, for row actions.
struct QuietIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: Theme.Control.icon, height: Theme.Control.icon)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.s).fill(configuration.isPressed ? Theme.separator : (hovering ? Theme.hairline : .clear)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Full-width row that fills on hover (tool rows, options, list-like buttons).
struct HoverRowStyle: ButtonStyle {
    var radius: CGFloat = Theme.Radius.s
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, radius: radius) }

    private struct Styled: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovering = false
        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(configuration.isPressed ? Theme.separator : (hovering ? Theme.hairline : .clear)))
                .onHover { hovering = $0 }
        }
    }
}


/// Text buttons. One height, square corners, 1 px frame; `primary` is filled with the accent. Inside
/// an `EqualWidthHStack`, or with `fixedWidth`, buttons that sit together are the same width.
struct ActionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .secondary
    /// `Theme.Control.buttonWidth` for buttons aligned in a column; nil sizes to the label (or the layout).
    var fixedWidth: CGFloat? = nil
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, kind: kind, fixedWidth: fixedWidth) }

    private struct Styled: View {
        let configuration: Configuration
        let kind: Kind
        let fixedWidth: CGFloat?
        @Environment(\.isEnabled) private var enabled
        @Environment(\.actionButtonFills) private var fills
        @State private var hovering = false

        var fill: Color {
            switch kind {
            case .primary: return Theme.accent.opacity(configuration.isPressed ? 0.8 : (hovering ? 0.9 : 1))
            case .secondary, .destructive: return configuration.isPressed ? Theme.separator : (hovering ? Theme.hairline : Theme.raised)
            }
        }
        var stroke: Color {
            switch kind {
            case .primary: return Theme.ink
            case .secondary: return hovering ? Theme.ink.opacity(0.55) : Theme.rule
            case .destructive: return Theme.bad.opacity(hovering ? 0.9 : 0.5)
            }
        }
        var text: Color {
            switch kind {
            case .primary: return .white
            case .secondary: return .primary
            case .destructive: return Theme.bad
            }
        }

        var body: some View {
            configuration.label
                .font(Theme.body.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(text)
                .padding(.horizontal, Theme.Space.m + 2)
                .frame(maxWidth: fills ? .infinity : nil)
                // A column width is a minimum: a longer translation widens its button instead of truncating.
                .frame(minWidth: fixedWidth, minHeight: Theme.Control.button, maxHeight: Theme.Control.button)
                .background(Rectangle().fill(fill))
                .overlay(Rectangle().strokeBorder(stroke, lineWidth: kind == .primary ? 1.5 : 1))
                .modifier(HardShadow(pressed: configuration.isPressed, offset: kind == .primary && enabled ? 3 : 0))
                .scaleEffect(configuration.isPressed && kind != .primary ? 0.985 : 1)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { h in withAnimation(Theme.Motion.hover) { hovering = h } }
        }
    }
}

private struct ActionButtonFillsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Set by `EqualWidthButtons`: action buttons fill the width the group gives them.
    var actionButtonFills: Bool {
        get { self[ActionButtonFillsKey.self] }
        set { self[ActionButtonFillsKey.self] = newValue }
    }
}

/// A row of buttons that belong together, all the width of the widest.
struct EqualWidthButtons<Content: View>: View {
    var spacing: CGFloat = Theme.Space.s
    var minWidth: CGFloat = 88
    @ViewBuilder var content: () -> Content
    var body: some View {
        EqualWidthHStack(spacing: spacing, minWidth: minWidth) { content() }
            .environment(\.actionButtonFills, true)
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    static var action: ActionButtonStyle { ActionButtonStyle() }
    static var primaryAction: ActionButtonStyle { ActionButtonStyle(kind: .primary) }
    static func action(_ kind: ActionButtonStyle.Kind = .secondary, width: CGFloat? = nil) -> ActionButtonStyle { ActionButtonStyle(kind: kind, fixedWidth: width) }
    /// A button in the trailing action column of a settings row (`Theme.Control.buttonWidth`).
    static func column(_ kind: ActionButtonStyle.Kind = .secondary) -> ActionButtonStyle { ActionButtonStyle(kind: kind, fixedWidth: Theme.Control.buttonWidth) }
}

/// Text input drawn like the rest of the sheet: square corners, a 1 px frame that turns accent (1.5 px)
/// while focused, and a grey example inside saying what goes there. With a `title` it is a settings row
/// (title left, field right); without one it fills the space it is given.
struct SpecField: View {
    var title: String? = nil
    @Binding var text: String
    var prompt: String = ""
    var secure = false
    var mono = false
    var multiline = false
    var width: CGFloat? = nil
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        if let title {
            // Not LabeledContent: a grouped form pins its label to the first baseline, which sits above a
            // framed field's text; here both centre on one row.
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text(title)
                Spacer(minLength: Theme.Space.m)
                field.frame(width: width ?? Theme.Control.fieldWidth)
            }
        } else {
            field.frame(width: width)
        }
    }

    private var field: some View {
        Group {
            if secure {
                SecureField(title ?? prompt, text: $text, prompt: Text(prompt))
            } else if multiline {
                TextField(title ?? prompt, text: $text, prompt: Text(prompt), axis: .vertical).lineLimit(3...6)
            } else {
                TextField(title ?? prompt, text: $text, prompt: Text(prompt))
            }
        }
        .labelsHidden()
        .textFieldStyle(.plain)
        .multilineTextAlignment(.leading)   // grouped forms right-align row values otherwise
        .font(mono ? Theme.monoSmall : Theme.body)
        .focused($focused)
        .onSubmit(onSubmit)
        .padding(.horizontal, Theme.Space.s + 1)
        .padding(.vertical, multiline ? Theme.Space.s : 0)
        .frame(maxWidth: .infinity, minHeight: Theme.Control.button, alignment: .leading)
        .background(Rectangle().fill(Theme.canvas))
        .overlay(Rectangle().strokeBorder(focused ? Theme.accent : Theme.rule, lineWidth: focused ? 1.5 : 1))
        .animation(Theme.Motion.allowed ? Theme.Motion.hover : nil, value: focused)
    }
}

/// A settings row: what it is (and a line of detail) on the left, its actions on the right in the
/// shared button column, so every page's buttons line up at one width.
struct ActionRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.m)
            trailing()
        }
    }
}

/// Lays children out in a row, all as wide as the widest (and at least `minWidth`), so buttons that
/// belong together line up as equals.
struct EqualWidthHStack: Layout {
    var spacing: CGFloat = Theme.Space.s
    var minWidth: CGFloat = 88

    func width(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.max().map { max($0, minWidth) } ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let w = width(subviews)
        let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
        return CGSize(width: w * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = width(subviews)
        var x = bounds.minX
        for v in subviews {
            v.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}
