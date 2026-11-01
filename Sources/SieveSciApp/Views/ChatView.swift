import AppKit
import MarkdownUI
import SieveSciCore
import SwiftUI

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @State private var searching = false
    @State private var query = ""

    var visible: [TranscriptItem] {
        guard searching, !query.isEmpty else { return model.items }
        return model.items.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
    }

    /// A new, empty task: the composer moves to the middle of the window (see `EmptyChatHero`).
    var isEmptyTask: Bool {
        model.items.isEmpty && !model.running && model.pendingPermission == nil && model.demoAsk == nil && model.lastError == nil
    }

    var body: some View {
        if isEmptyTask { EmptyChatHero() } else { conversation }
    }

    var conversation: some View {
        VStack(spacing: 0) {
            if searching {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("Search this task"), text: $query).textFieldStyle(.plain).font(Theme.body)
                    Text(query.isEmpty ? "" : L10n.f("%d matches", visible.count)).font(Theme.caption).foregroundStyle(.secondary)
                    Button { searching = false; query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(QuietIconButtonStyle())
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .background(.bar)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { item in
                            TranscriptRow(item: item, stream: "main", showThinking: model.config.showThinking).equatable().id(item.id)
                        }
                        Group {
                            if model.config.permissionMode == .plan, !model.plan.steps.isEmpty, !model.running {
                                PlanApprovalBar()
                            }
                            if !model.contested.isEmpty { ContestedBanner() }
                            if model.running { Spinner().id("spinner") }
                            if let req = model.pendingPermission {
                                PermissionPrompt(request: PermissionAsk(req)).id("permission")
                            } else if let ask = model.demoAsk {
                                PermissionPrompt(request: ask).id("permission")
                            }
                        }
                        .padding(.vertical, Theme.Space.s)
                        .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                        Color.clear.frame(height: Theme.Space.s).id("bottom")
                    }
                    .transcriptColumn()
                    .padding(.vertical, Theme.Space.l)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.items.count) { _, _ in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.items.last) { _, _ in if !searching { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.pendingPermission?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let e = model.lastError, model.bench == nil { SessionSetupCard(detail: e) }
                if !model.queued.isEmpty {
                    HStack(spacing: Theme.Space.xs + 2) {
                        Image(systemName: "text.badge.plus").foregroundStyle(.secondary)
                        Text(L("Queued") + ":").foregroundStyle(.secondary)
                        ForEach(Array(model.queued.enumerated()), id: \.offset) { _, q in
                            Text(q.prefix(40)).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Theme.surface))
                        }
                        Spacer()
                    }
                    .font(Theme.meta)
                }
                PromptInput()
                StatsLine()
            }
            .readingColumn()
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.m)
        }
        .background(Theme.canvas)
        .background(
            Button("") { searching.toggle() }.keyboardShortcut("f", modifiers: .command).hidden()
        )
    }
}

extension View {
    /// The transcript spans the window (up to `transcriptWidth`): agents on the left, the user on the right.
    func transcriptColumn() -> some View {
        frame(maxWidth: Theme.transcriptWidth, alignment: .leading)
            .padding(.horizontal, Theme.Space.xl)
            .frame(maxWidth: .infinity)
    }

    /// Centres content in the shared transcript / composer column.
    func readingColumn() -> some View {
        frame(maxWidth: Theme.readingWidth, alignment: .leading)
            .padding(.horizontal, Theme.Space.xl)
            .frame(maxWidth: .infinity)
    }
}

/// Shown above the composer when no session can run: what is missing and the one click that fixes it.
struct SessionSetupCard: View {
    @EnvironmentObject var model: AppModel
    let detail: String

    var body: some View {
        let setup = model.needsModelSetup
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: setup ? "cpu" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(setup ? Theme.accent : Theme.warn)
                .frame(width: 30, height: 30)
                .background(Rectangle().fill(setup ? Theme.accentSoft : Theme.warn.opacity(0.12)))
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(setup ? L("Connect a model to start") : L("The session could not start"))
                    .font(Theme.body.weight(.semibold))
                Text(setup ? L("SieveSci needs one model provider: an API key (DeepSeek, Anthropic, OpenAI, Gemini, GLM …), a relay, or a signed-in Claude Code, Codex or Gemini CLI. What you typed is kept.") : detail)
                    .font(Theme.meta).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                EqualWidthButtons {
                    if setup {
                        Button(L("Set up a provider…")) { model.openSettings(.providers) }.buttonStyle(.primaryAction)
                    }
                    Button(L("Try again")) { model.lastError = nil; model.resumeIfNeeded() }.buttonStyle(.action)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .background(Rectangle().fill(Theme.raised))
        .overlay(FrameStroke(provisional: true))
        .appearPop()
    }
}

/// A new task, laid out like a blank page: the wordmark sifts in as dots, the question in large
/// type, the composer centred, and three starting points of equal width. The composer moves to the
/// bottom once the conversation begins.
struct EmptyChatHero: View {
    @EnvironmentObject var model: AppModel

    static let starts: [(icon: String, title: String, prompt: String)] = [
        ("books.vertical", "Review the literature", "Review the recent literature on "),
        ("chart.xyaxis.line", "Analyse my data", "Analyse the data in "),
        ("flask", "Design an experiment", "Design an experiment to test whether "),
    ]

    var body: some View {
        ZStack {
            SieveField().mask(LinearGradient(colors: [.black, .black.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Spacer(minLength: Theme.Space.xl)
                HStack(alignment: .bottom, spacing: Theme.Space.m) {
                    DotMatrixText(text: "SieveSci", rows: 18, dot: 4.5, gap: 1.5)
                    LabelTab(text: L("New task")).padding(.bottom, 4)
                }
                Text(L("What should we investigate?"))
                    .font(.system(size: 30, weight: .semibold)).tracking(-0.7)
                Text(L("Ask a research question, paste a GitHub link, or type / for commands"))
                    .font(Theme.prose).foregroundStyle(.secondary)
                PromptInput().padding(.top, Theme.Space.s)
                HStack(spacing: Theme.Space.m) {
                    ForEach(Self.starts, id: \.title) { s in
                        Button { model.draft = L(s.prompt) } label: {
                            VStack(alignment: .leading, spacing: Theme.Space.s) {
                                Image(systemName: s.icon).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.accent)
                                    .frame(width: 20, height: 20, alignment: .leading)
                                Text(L(s.title)).font(Theme.body.weight(.medium)).foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                            .padding(Theme.Space.m)
                        }
                        .buttonStyle(StartCardStyle())
                    }
                }
                StatsLine().opacity(model.meter.session.promptTotal > 0 ? 1 : 0)
                Spacer(minLength: Theme.Space.xl)
            }
            .frame(maxWidth: Theme.readingWidth)
            .padding(.horizontal, Theme.Space.xl)
            .appearPop()
        }
        .background(Theme.canvas)
    }
}

/// A starting-point card: framed, with a hard shadow that it presses into.
struct StartCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(Rectangle().fill(hovering ? Theme.accentSoft : Theme.raised))
                .overlay(Rectangle().strokeBorder(hovering ? Theme.ink : Theme.rule, lineWidth: 1))
                .hardShadow(pressed: configuration.isPressed, offset: hovering ? 4 : 0)
                .contentShape(Rectangle())
                .onHover { h in withAnimation(Theme.Motion.hover) { hovering = h } }
        }
    }
}

// MARK: - Rows

/// The model, for rows that only call its actions. Read through the environment it is not observed,
/// so a row redraws when its own item changes — not on every change anywhere in the app.
final class ModelLink {
    weak var model: AppModel?
    init(_ model: AppModel? = nil) { self.model = model }
}

private struct ModelLinkKey: EnvironmentKey { static let defaultValue = ModelLink() }
extension EnvironmentValues {
    var modelLink: ModelLink {
        get { self[ModelLinkKey.self] }
        set { self[ModelLinkKey.self] = newValue }
    }
}

struct TranscriptRow: View, Equatable {
    let item: TranscriptItem
    let stream: String
    var showThinking = true
    @Environment(\.modelLink) private var link
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        aligned
            .padding(.vertical, compact ? 1 : Theme.Space.s)
            .onHover { hovering = $0 }
            .contextMenu { actions }
    }

    /// In a wide window your messages sit at the right edge and everything from the agents at the left,
    /// kept to a readable line length.
    @ViewBuilder var aligned: some View {
        if case .user = item.kind {
            content.frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            content.frame(maxWidth: Theme.readingWidth, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Single-line rows sit tight together; messages and grouped blocks get room to breathe.
    var compact: Bool {
        switch item.kind {
        case .user, .assistant, .agent, .review, .error: return false
        default: return true
        }
    }

    static func == (a: TranscriptRow, b: TranscriptRow) -> Bool {
        a.item == b.item && a.stream == b.stream && a.showThinking == b.showThinking
    }

    private var model: AppModel? { link.model }

    @ViewBuilder var actions: some View {
        Button(L("Copy")) { copy(item.searchableText) }
        if case .user = item.kind, stream == "main" {
            Button(L("Rewind to here")) { model?.rewind(to: item, edit: false) }
            Button(L("Edit and resend")) { model?.rewind(to: item, edit: true) }
        }
        if case .assistant(let text) = item.kind {
            Button(L("Quote in reply")) { model?.draft = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") + "\n\n" }
            if stream == "main" { Button(L("Fork task from here")) { model?.fork() } }
        }
        if case .tool(let c) = item.kind {
            Button(L("Copy input")) { copy(c.input.str("code") ?? c.input.str("command") ?? c.input.canonical) }
            if !c.output.isEmpty { Button(L("Copy output")) { copy(c.output) } }
            if let r = c.receipt { Button(L("Show provenance of") + " \(r)") { model?.submit("/trace \(r)", attachments: []) } }
        }
        if stream == "main", let m = model, !m.taskId.isEmpty {
            Divider()
            Button(L("Copy conversation ID")) { m.copyToPasteboard(m.taskId) }
            Button(L("Export Markdown…")) { m.exportTaskMarkdown(m.taskId) }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @ViewBuilder var content: some View {
        switch item.kind {
        case .user(let text, let atts):
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: Theme.Space.xxl * 2)
                VStack(alignment: .trailing, spacing: Theme.Space.xs + 2) {
                    Text(text)
                        .font(Theme.prose)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.s + 2)
                        .background(Rectangle().fill(Theme.accentSoft))
                        // The user's own words: settled, so a solid frame.
                        .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.35)))
                    if !atts.isEmpty {
                        HStack(spacing: Theme.Space.s) {
                            ForEach(Array(atts.enumerated()), id: \.offset) { _, a in
                                Label(a, systemImage: "paperclip").lineLimit(1)
                            }
                        }
                        .font(Theme.caption).foregroundStyle(.secondary)
                    }
                    // Actions sit under the bubble, right-aligned. Their row is always reserved and only
                    // fades in on hover, so the message never shifts sideways.
                    if stream == "main" {
                        HStack(spacing: 0) {
                            Button { model?.rewind(to: item, edit: true) } label: { Image(systemName: "pencil") }
                                .help(L("Edit and resend")).accessibilityLabel(L("Edit and resend"))
                            Button { model?.rewind(to: item, edit: false) } label: { Image(systemName: "arrow.uturn.backward") }
                                .help(L("Rewind to here")).accessibilityLabel(L("Rewind to here"))
                            Button { copy(text) } label: { Image(systemName: "doc.on.doc") }
                                .help(L("Copy")).accessibilityLabel(L("Copy"))
                        }
                        .buttonStyle(QuietIconButtonStyle())
                        .opacity(hovering ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: hovering)
                        .padding(.top, -Theme.Space.xs)
                    }
                }
                .frame(maxWidth: Theme.readingWidth * 0.8, alignment: .trailing)
            }
            .padding(.top, Theme.Space.s)

        case .assistant(let text):
            Markdown(MathMarkdown.prepared(text))
                .markdownTheme(Theme.markdown)
                .markdownMath()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Button { copy(text) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(QuietIconButtonStyle())
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.canvas))
                            .help(L("Copy"))
                            .accessibilityLabel(L("Copy"))
                            .offset(y: -4)
                    }
                }

        case .thinking(let text, let started, let ended):
            if showThinking {
                ThinkingRow(text: text, started: started, ended: ended)
            }

        case .tool(let call):
            ToolRow(call: call)

        case .agent(let id):
            AgentCardView(id: id)

        case .review(let kind, let verdict, let body):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "checkmark.seal").foregroundStyle(Theme.verdictColor(verdict))
                    Text(L10n.f("Independent %@ review", L(kind))).font(Theme.bodyStrong)
                    VerdictChip(verdict: verdict)
                }
                ReviewBody(text: body)
            }
            .box(highlight: Theme.verdictColor(verdict), tab: L(kind), tabTint: Theme.verdictColor(verdict))

        case .deliberation(let thread, let from, let to, let kind, let text):
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "arrow.left.arrow.right").font(Theme.caption).foregroundStyle(Theme.deliberationColor(kind))
                    .frame(width: Theme.gutter).padding(.top, 2)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    HStack(spacing: Theme.Space.xs + 2) {
                        Text(Theme.agentName(from)).font(Theme.metaStrong)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Text(Theme.agentName(to)).font(Theme.metaStrong)
                        Chip(text: L(kind), tint: Theme.deliberationColor(kind))
                        Text(thread).font(Theme.monoTiny).foregroundStyle(.tertiary)
                    }
                    Text(text).font(Theme.body).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(expanded ? nil : 4)
                        .onTapGesture { expanded.toggle() }
                }
            }

        case .literature(let action, let key, let title, let detail):
            HStack(spacing: Theme.Space.s) {
                Image(systemName: Theme.literatureIcon(action)).font(Theme.caption)
                    .foregroundStyle(action == .flagged ? Theme.bad : .secondary).frame(width: Theme.gutter)
                Text(L(action.rawValue)).font(Theme.meta).foregroundStyle(.secondary)
                // A search's "key" is its query, not a citation key.
                if !key.isEmpty, action != .searched { Text("[@\(key)]").font(Theme.monoTiny).foregroundStyle(Theme.accent) }
                Text(title).font(Theme.meta).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(Theme.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
            .padding(.vertical, 3)

        case .fileChange(let path, let diff):
            DiffSummaryRow(path: path, diff: diff)

        case .commit(let hash, let subject, let files):
            Button { model?.show(.history) } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(Theme.caption)
                        .foregroundStyle(.secondary).frame(width: Theme.gutter)
                    Text(String(hash.prefix(8))).font(Theme.monoTiny).foregroundStyle(Theme.accent)
                    Text(subject).font(Theme.meta).lineLimit(1)
                    Text(L10n.f("%d receipts", files)).font(Theme.caption).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)

        case .job(let n):
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: n.kind == .failed ? "exclamationmark.octagon.fill" : n.kind == .stalled ? "hourglass" : n.kind == .matched ? "bell.fill" : "checkmark.circle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(n.kind == .failed ? Theme.bad : n.kind == .exited ? Theme.ok : Theme.warn)
                    .frame(width: Theme.gutter).padding(.top, 2)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(n.text.split(separator: "\n").first.map(String.init) ?? "").font(Theme.metaStrong)
                    if expanded { Text(n.text).font(Theme.monoTiny).foregroundStyle(.secondary).textSelection(.enabled).codeBlock() }
                }
                Spacer()
                Button(L("Log")) { model?.show(.jobs) }
                    .buttonStyle(.borderless).font(Theme.meta)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

        case .signal(let s):
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").font(Theme.caption).foregroundStyle(Theme.warn)
                    .frame(width: Theme.gutter).padding(.top, 2)
                Text(s).font(Theme.meta).textSelection(.enabled)
            }
            .padding(.vertical, 3)
        case .notice(let s):
            Text(s).font(Theme.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.vertical, Theme.Space.xs)
        case .error(let s):
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.bad)
                Text(L("Error") + ": \(s)").font(Theme.body).textSelection(.enabled)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous).fill(Theme.bad.opacity(0.09)))
        }
    }
}

struct VerdictChip: View {
    let verdict: String
    var body: some View {
        Chip(text: L(verdict).uppercased(), tint: Theme.verdictColor(verdict))
    }
}

/// Checker/verifier JSON rendered as issues and actions instead of raw JSON.
struct ReviewBody: View {
    let text: String
    @State private var raw = false

    var parsed: JSON? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}") else { return nil }
        return try? JSONCodec.parse(String(text[a...b]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let j = parsed, !raw {
                ForEach(Array((j["issues"]?.arrayValue ?? []).enumerated()), id: \.offset) { i, issue in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text("\(i + 1)").font(Theme.monoTiny).foregroundStyle(.tertiary).frame(width: Theme.gutter, alignment: .trailing)
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            HStack(spacing: Theme.Space.xs + 2) {
                                if let sev = issue.str("severity"), !sev.isEmpty {
                                    Chip(text: L(sev), tint: sev == "high" ? Theme.bad : Theme.warn)
                                }
                                Text(issue.str("what") ?? "").font(Theme.body)
                            }
                            if let e = issue.str("evidence"), !e.isEmpty { Text(e).font(Theme.meta).foregroundStyle(.secondary) }
                        }
                    }
                }
                ForEach(Array((j["required_actions"]?.arrayValue ?? []).compactMap(\.stringValue).enumerated()), id: \.offset) { _, a in
                    Label(a, systemImage: "arrow.right").font(Theme.body).foregroundStyle(Theme.accent)
                }
                ForEach(Array((j["questions"]?.arrayValue ?? []).compactMap(\.stringValue).enumerated()), id: \.offset) { _, q in
                    Label(q, systemImage: "questionmark.circle").font(Theme.body).foregroundStyle(.secondary)
                }
                if let r = j.str("reasoning") ?? j.str("notes") { Text(r).font(Theme.meta).foregroundStyle(.secondary) }
            } else {
                Text(text).font(Theme.monoTiny).textSelection(.enabled)
            }
            Button(raw ? L("formatted") : L("raw")) { raw.toggle() }.buttonStyle(.link).font(Theme.caption)
        }
    }
}

struct ThinkingRow: View {
    let text: String
    let started: Date
    let ended: Date?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            Button { expanded.toggle() } label: {
                TimelineView(.periodic(from: started, by: 1)) { ctx in
                    let secs = Int((ended ?? ctx.date).timeIntervalSince(started))
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "brain").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: Theme.gutter)
                        Text(ended == nil ? L10n.f("Thinking… %ds", secs) : L10n.f("Thought for %ds", max(1, secs)))
                            .font(Theme.body).foregroundStyle(.primary.opacity(0.75))
                        if !expanded, ended == nil {
                            Text("· " + (text.split(separator: "\n").last.map(String.init) ?? "")).font(Theme.body).lineLimit(1).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text).font(Theme.body).italic().foregroundStyle(.secondary).textSelection(.enabled)
                    .threadRule(Theme.separator)
                    .padding(.leading, Theme.gutter / 2)
            }
        }
    }
}

// MARK: - Tool calls

struct ToolRow: View {
    let call: ToolCallView
    @State private var expanded = false

    var hasOutput: Bool { call.diff == nil && !call.output.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Button { if hasOutput { withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() } } } label: {
                HStack(spacing: Theme.Space.s) {
                    ZStack {
                        if call.running {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: call.isError ? "exclamationmark.circle.fill" : Theme.toolIcon(call.name))
                                .font(.system(size: 12))
                                .foregroundStyle(call.isError ? Theme.bad : .secondary)
                        }
                    }
                    .frame(width: Theme.gutter)
                    Text(Theme.toolTitle(call.name)).font(Theme.body).foregroundStyle(.primary.opacity(0.75))
                    Text("·").font(Theme.body).foregroundStyle(.tertiary)
                    Text(call.summary).font(Theme.body).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: Theme.Space.s)
                    // Only a running call ticks; a finished one shows a fixed duration (a timer per row
                    // redrew every tool row in the transcript once a second).
                    if let ended = call.ended {
                        let secs = ended.timeIntervalSince(call.started)
                        Text(secs < 1 ? "" : String(format: "%.0fs", secs)).font(Theme.caption).monospacedDigit().foregroundStyle(.tertiary)
                    } else {
                        TimelineView(.periodic(from: call.started, by: 1)) { ctx in
                            let secs = ctx.date.timeIntervalSince(call.started)
                            Text(secs < 1 ? "" : String(format: "%.0fs", secs)).font(Theme.caption).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                    if let r = call.receipt {
                        Text(r).font(Theme.monoTiny).foregroundStyle(.tertiary).help(L("Evidence receipt — cite it to prove this result"))
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hasOutput ? 1 : 0)
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 5)
            }
            .buttonStyle(HoverRowStyle())
            .help(hasOutput ? (expanded ? L("Hide output") : L("Show output")) : "")
            .padding(.horizontal, -Theme.Space.s)

            Group {
                if call.running && !call.live.isEmpty {
                    // Live output (streamed while the command runs).
                    Text(call.live.suffix(8).joined(separator: "\n"))
                        .font(Theme.monoTiny).foregroundStyle(.secondary)
                        .codeBlock()
                }
                if let d = call.diff {
                    DiffSummaryRow(path: d.path, diff: d)
                } else if hasOutput {
                    ToolOutputView(call: call, expanded: $expanded)
                }
            }
            .padding(.leading, Theme.gutter + Theme.Space.s)
        }
        .padding(.vertical, 1)
    }
}

/// Output under a tool row: hidden until opened, except figures and the first lines of an error.
struct ToolOutputView: View {
    let call: ToolCallView
    @Binding var expanded: Bool

    var lines: [Substring] { call.output.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !expanded, let img = imagePath, let ns = NSImage(contentsOfFile: img) {
                Image(nsImage: ns).resizable().scaledToFit().frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).strokeBorder(Theme.hairline))
            }
            if expanded {
                Text(call.output)
                    .font(Theme.monoTiny)
                    .foregroundStyle(call.isError ? Theme.bad : .secondary)
                    .textSelection(.enabled)
                    .codeBlock()
            } else if call.isError {
                Text(lines.prefix(2).joined(separator: "\n"))
                    .font(Theme.monoTiny).foregroundStyle(Theme.bad).lineLimit(2)
            }
        }
    }

    /// Figures written by the call are previewed inline.
    var imagePath: String? {
        guard call.name == "python" || call.name == "bash" || call.name == "read_file" else { return nil }
        for m in Grounding.matches(#"([\w./\-]+\.(?:png|jpg|jpeg))"#, in: call.output, group: 1) {
            if FileManager.default.fileExists(atPath: m) { return m }
        }
        return nil
    }
}

// MARK: - Diffs (red removed, green added)

struct DiffSummaryRow: View {
    let path: String
    let diff: FileDiff
    @State private var open = false
    @Environment(\.modelLink) private var link

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: diff.isNewFile ? "doc.badge.plus" : "pencil.line").font(Theme.caption)
                    .foregroundStyle(.secondary).frame(width: Theme.gutter)
                Text(path).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
                Text("+\(diff.added)").font(Theme.monoTiny).foregroundStyle(Theme.ok)
                Text("−\(diff.removed)").font(Theme.monoTiny).foregroundStyle(Theme.bad)
                Spacer(minLength: Theme.Space.s)
                Button(open ? L("hide") : L("show diff")) { open.toggle() }
                Button(L("Changes")) { link.model?.show(.changes) }
            }
            .buttonStyle(.borderless)
            .font(Theme.meta)
            .padding(.vertical, 3)
            if open { DiffView(diff: diff, maxLines: 400) }
        }
    }
}

struct DiffView: View {
    let diff: FileDiff
    var maxLines = 2000

    var body: some View {
        if diff.isBinaryOrLarge {
            Text(L("File too large or binary to diff.")).font(Theme.meta).foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, h in
                        Text(h.header).font(Theme.monoTiny).foregroundStyle(Theme.info)
                            .padding(.horizontal, Theme.Space.s).padding(.vertical, 3)
                        ForEach(Array(h.lines.prefix(maxLines).enumerated()), id: \.offset) { _, l in
                            DiffLineView(line: l)
                        }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
            }
            .background(Theme.surfaceSubtle)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}

struct DiffLineView: View {
    let line: FileDiff.Line
    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map { String($0) } ?? "").frame(width: 36, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.newNumber.map { String($0) } ?? "").frame(width: 36, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.kind == .added ? "  + " : line.kind == .removed ? "  − " : "    ")
                .foregroundStyle(line.kind == .added ? Theme.ok : line.kind == .removed ? Theme.bad : .secondary)
            Text(line.text.isEmpty ? " " : line.text).fixedSize()
                .padding(.trailing, Theme.Space.s)
        }
        .font(Theme.monoTiny)
        .padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .added ? Theme.ok.opacity(0.13) : line.kind == .removed ? Theme.bad.opacity(0.13) : .clear)
    }
}

// MARK: - Agent threads (who talked to whom, live)

struct AgentCardView: View {
    let id: String
    @EnvironmentObject var model: AppModel
    @State private var expanded = false

    var body: some View {
        if let card = model.cards[id] {
            let items = model.streams[id] ?? []
            let tint = Theme.roleColor(card.role)
            let steps = items.filter { if case .tool = $0.kind { return true }; return false }.count
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Button { withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() } } label: {
                    HStack(alignment: .center, spacing: Theme.Space.s + 2) {
                        RoleGhostBadge(role: card.role, working: card.ended == nil, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: Theme.Space.xs + 2) {
                                Text(Theme.agentName(id)).font(Theme.bodyStrong)
                                Text("← " + Theme.agentName(card.parent)).font(Theme.caption).foregroundStyle(.tertiary)
                            }
                            Text(card.purpose).font(Theme.meta).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: Theme.Space.s)
                        TimelineView(.periodic(from: card.started, by: 1)) { ctx in
                            Text(String(format: "%.0fs", (card.ended ?? ctx.date).timeIntervalSince(card.started)))
                                .font(Theme.caption).monospacedDigit().foregroundStyle(.tertiary)
                        }
                        Text(L10n.f("%d steps", steps)).font(Theme.caption).foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .padding(.vertical, Theme.Space.xs)
                    .padding(.horizontal, Theme.Space.s)
                }
                .buttonStyle(HoverRowStyle())
                .padding(.horizontal, -Theme.Space.s)

                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { TranscriptRow(item: $0, stream: id, showThinking: model.config.showThinking).equatable() }
                    }
                } else if card.ended == nil, let last = items.last(where: { if case .tool = $0.kind { return true }; return false }),
                          case .tool(let c) = last.kind {
                    HStack(spacing: Theme.Space.xs + 2) {
                        Image(systemName: Theme.toolIcon(c.name)).font(Theme.caption)
                        Text(Theme.toolTitle(c.name)).font(Theme.metaStrong)
                        Text(c.summary).font(Theme.monoTiny).lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
                if let r = card.result, !expanded {
                    Text(r.prefix(300)).font(Theme.meta).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .threadRule(tint.opacity(card.ended == nil ? 0.9 : 0.35))
        }
    }
}

// MARK: - Banners and prompts

struct PlanApprovalBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconBadge(systemName: "list.bullet.clipboard", tint: Theme.accent, size: 26)
            Text(L("Plan ready for review.")).font(Theme.bodyStrong)
            Spacer()
            EqualWidthButtons {
                Button(L("Open plan")) { model.show(.plan) }.buttonStyle(.action)
                Button(L("Approve and run")) { model.approvePlan() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.primaryAction)
            }
        }
        .box(provisional: true)
        .appearPop()
    }
}

struct ContestedBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(L("Unresolved disagreements between agents — your call"), systemImage: "exclamationmark.bubble.fill")
                .font(Theme.bodyStrong).foregroundStyle(Theme.warn)
            ForEach(Array(model.contested.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    HStack(spacing: Theme.Space.xs + 2) {
                        Text(c.thread).font(Theme.monoTiny).foregroundStyle(.tertiary)
                        Chip(text: L(c.kind), tint: Theme.warn)
                    }
                    Text(String(c.issue.prefix(160))).font(Theme.body)
                    Text(String(c.reason.prefix(120))).font(Theme.meta).foregroundStyle(.secondary)
                }
            }
        }
        .box(highlight: Theme.warn, provisional: true)
        .appearPop()
    }
}

struct Spinner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            // The research agent's own ghost while it works (the brand ghost when no role art exists).
            if RoleGhost.svg(.main, "working").isEmpty { GhostLoader(size: 26).padding(.leading, -5) }
            else { RoleGhostBadge(role: .main, working: true, size: 28).padding(.leading, -5) }
            DotActivity()
            Text(L(model.spinnerVerb) + "…").font(Theme.body.weight(.medium)).foregroundStyle(Theme.accent)
            BlinkingCursor()
            // An instrument readout: monospaced, so the numbers do not jitter as they change.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(L10n.f("%ds · ↑ %@ tokens · esc to interrupt", Int(Date().timeIntervalSince(model.runStarted)), model.meter.lastPromptTokens.formatted()))
                    .font(Theme.monoTiny).foregroundStyle(.tertiary)
            }
            let running = model.jobs.values.filter(\.running).count
            if running > 0 {
                Text("· " + L10n.f("%d jobs running", running)).font(Theme.monoTiny).foregroundStyle(.tertiary)
            }
        }
    }
}

/// What the permission prompt needs, independent of where the request came from.
struct PermissionAsk {
    var tool: String
    var summary: String
    var input: JSON
    var effect: ToolEffect
    var rememberPattern: String

    init(_ r: PermissionRequest) {
        tool = r.tool; summary = r.summary; input = r.input; effect = r.effect; rememberPattern = r.rememberPattern
    }

    init(tool: String, summary: String, input: JSON, effect: ToolEffect, rememberPattern: String) {
        self.tool = tool; self.summary = summary; self.input = input; self.effect = effect; self.rememberPattern = rememberPattern
    }
}

struct PermissionPrompt: View {
    let request: PermissionAsk
    @EnvironmentObject var model: AppModel
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                IconBadge(systemName: request.effect == .writesFiles ? "pencil" : Theme.toolIcon(request.tool), tint: Theme.accent, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Theme.toolTitle(request.tool) + " " + (request.effect == .writesFiles ? L("wants to edit files")
                        : ["dispatch", "task", "claim_finding"].contains(request.tool) ? L("wants to start independent agents")
                        : request.effect == .external ? L("wants to contact an external service") : L("wants to run code")))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("Do you want to proceed?")).font(Theme.meta).foregroundStyle(.secondary)
                }
            }
            Text(request.summary).font(Theme.monoSmall).textSelection(.enabled).codeBlock()
            if request.effect == .writesFiles, let path = request.input.str("path"), let new = request.input.str("content") ?? request.input.str("new_string") {
                let old = request.input.str("old_string") ?? model.workspace.flatMap { try? String(contentsOf: $0.appendingPathComponent(path), encoding: .utf8) }
                DiffView(diff: FileDiff.make(path: path, old: old, new: new), maxLines: 120)
                    .frame(maxHeight: 240)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                option("1", L("Yes"), prominent: true) { model.answerPermission(.allowOnce) }
                    .keyboardShortcut("1", modifiers: [])
                option("2", L("Yes, and don't ask again for") + " \(request.rememberPattern)") { model.answerPermission(.allowAlways) }
                    .keyboardShortcut("2", modifiers: [])
                HStack(spacing: Theme.Space.s) {
                    option("3", L("No, and tell SieveSci what to do differently")) { model.answerPermission(.deny(feedback)) }
                        .keyboardShortcut("3", modifiers: [])
                    TextField(L("(optional)"), text: $feedback)
                        .textFieldStyle(.plain).font(Theme.body).frame(maxWidth: 240)
                        .padding(.vertical, 3)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                }
            }
        }
        .padding(Theme.Space.l)
        .padding(.top, Theme.Space.xs)
        .background(Rectangle().fill(Theme.raised))
        // Waiting for the user's decision: a provisional (dashed) frame, labelled with the tool asking.
        .overlay(FrameStroke(provisional: true, color: Theme.accent.opacity(0.7)))
        .overlay(alignment: .topLeading) { LabelTab(text: Theme.toolTitle(request.tool), tint: Theme.accent).offset(x: Theme.Space.l, y: -8) }
        .padding(.top, 8)
        .appearPop()
    }

    func option(_ key: String, _ label: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s + 2) {
                Keycap(key)
                Text(label).font(prominent ? Theme.bodyStrong : Theme.body).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs + 2)
        }
        .buttonStyle(HoverRowStyle())
    }
}

// MARK: - Markdown

extension Theme {
    /// Assistant prose: SF Pro at reading size, filled code blocks, hairline tables.
    static var markdown: MarkdownUI.Theme {
        MarkdownUI.Theme.basic
        .text { FontSize(15) }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            BackgroundColor(Theme.surface)
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(Theme.accent) }
        .heading1 { c in
            c.label.markdownMargin(top: .em(1.2), bottom: .em(0.5))
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.4)) }
        }
        .heading2 { c in
            c.label.markdownMargin(top: .em(1.1), bottom: .em(0.45))
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.2)) }
        }
        .heading3 { c in
            c.label.markdownMargin(top: .em(1), bottom: .em(0.4))
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.05)) }
        }
        .paragraph { c in
            c.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.25))
                .markdownMargin(top: .zero, bottom: .em(0.8))
        }
        .codeBlock { c in
            ScrollView(.horizontal) {
                c.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.86))
                    }
                    .padding(Theme.Space.m)
            }
            .background(Theme.surfaceSubtle)
            .overlay(Rectangle().strokeBorder(Theme.separator))
            .overlay(alignment: .leading) { Rectangle().fill(Theme.rule).frame(width: 2) }
            .markdownMargin(top: .em(0.2), bottom: .em(0.9))
        }
        .blockquote { c in
            c.label
                .markdownTextStyle { ForegroundColor(.secondary) }
                .threadRule(Theme.separator, width: 3)
        }
        .table { c in
            c.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(.horizontalBorders, color: Theme.separator))
                .markdownMargin(top: .zero, bottom: .em(0.9))
        }
    }
}
