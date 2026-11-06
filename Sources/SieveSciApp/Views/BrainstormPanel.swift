import SieveSciCore
import SwiftUI

/// Brainstorming mode, watched live. The sieve motif carries the meaning: ideas fall in as dots and
/// thin out column by column (generated → distinct → checked → kept → registered), the stage track
/// fills like an instrument's segment display, and the frame stays dashed while the ideas are
/// speculation. The user sees what the agent is thinking right now and can wrap up or stop.
struct BrainstormPanel: View {
    let state: BrainstormState
    @EnvironmentObject var model: AppModel
    @State private var showThought = false
    @State private var showAll = false

    var live: Bool { state.endedAt == nil }
    /// This brainstorm's ideas (an ended one stays in the conversation, so later brainstorms' are left out).
    var ideas: [Idea] {
        model.ideas.filter { i in
            i.createdAt >= state.startedAt.addingTimeInterval(-1) && (state.endedAt.map { i.createdAt <= $0.addingTimeInterval(5) } ?? true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            StageTrack(state: state)
            IdeaSieve(ideas: ideas)
            if live { thought }
            ideaList
            Text(L("Ideas are speculation: they count only after a novelty check, an independent review and, for findings, blind verification."))
                .font(Theme.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.l)
        .padding(.top, Theme.Space.xs)
        .background(Rectangle().fill(Theme.raised))
        .overlay(FrameStroke(provisional: live, color: live ? Theme.accent.opacity(0.7) : Theme.rule))
        .overlay(alignment: .topLeading) {
            HStack(spacing: Theme.Space.xs) {
                LabelTab(text: L("Brainstorm"), tint: live ? Theme.accent : Theme.ink)
                LabelTab(text: triggerText, tint: Theme.ink.opacity(0.55))
            }
            .offset(x: Theme.Space.l, y: -8)
        }
        .padding(.top, 8)
        .appearPop()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Brainstorm") + ": " + state.topic)
    }

    var triggerText: String {
        switch state.trigger {
        case .auto: return L("Started by the agent")
        case .user: return L("You asked")
        case .dream: return L("Dream")
        }
    }

    var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Group {
                if live { DotActivity(size: 7, dot: 3, gap: 1.5, color: state.wrapUpRequested ? Theme.warn : Theme.accent) }
                else { DotActivity(size: 7, dot: 3, gap: 1.5, color: Theme.rule).opacity(0.6) }
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.topic).font(Theme.bodyStrong).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if !state.reason.isEmpty, live {
                    Text(state.reason).font(Theme.meta).foregroundStyle(.secondary).lineLimit(2)
                } else if let s = state.summary, !s.isEmpty {
                    Text(s).font(Theme.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.m)
            TimelineView(.periodic(from: state.startedAt, by: 1)) { ctx in
                let secs = Int((state.endedAt ?? ctx.date).timeIntervalSince(state.startedAt))
                Text(String(format: "%02d:%02d", secs / 60, secs % 60)).font(Theme.label).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            if live {
                EqualWidthButtons {
                    Button(state.wrapUpRequested ? L("Wrapping up…") : L("Wrap up")) { model.wrapUpBrainstorm() }
                        .buttonStyle(.action)
                        .disabled(state.wrapUpRequested)
                        .help(L("Stop generating and report the best ideas so far"))
                    Button(L("Stop")) { model.interrupt() }
                        .buttonStyle(.action(.destructive))
                        .help(L("Stop the agent now"))
                }
            } else {
                Chip(text: state.stopped ? L("Stopped") : L("Done"), tint: state.stopped ? Theme.warn : Theme.ok)
                    .padding(.top, 3)
            }
        }
    }

    /// The agent's latest thought since the brainstorm began: its reasoning, or its text if it
    /// thinks aloud.
    var latestThought: String {
        let items = (model.streams["main"] ?? []).filter { $0.at >= state.startedAt }
        for item in items.reversed() {
            switch item.kind {
            case .thinking(let t, _, _) where !t.isEmpty: return t
            case .assistant(let t) where !t.isEmpty: return t
            default: continue
            }
        }
        return state.stageNote
    }

    var thought: some View {
        let t = latestThought.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = t.split(separator: "\n").last.map(String.init) ?? ""
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Button { withAnimation(Theme.Motion.allowed ? Theme.Motion.hover : nil) { showThought.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(L("Thinking")).font(Theme.label).textCase(.uppercase).tracking(0.6).foregroundStyle(Theme.accent)
                    if !showThought {
                        Text(last.isEmpty ? L("…") : last).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }
                    BlinkingCursor()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showThought ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            if showThought {
                ScrollView {
                    Text(String(t.suffix(2400))).font(Theme.body).italic().foregroundStyle(.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .threadRule(Theme.accent.opacity(0.5))
            }
            if state.wrapUpRequested {
                Text(L("You asked it to wrap up; it is finishing the checks already running.")).font(Theme.meta).foregroundStyle(Theme.warn)
            }
        }
        .padding(Theme.Space.s)
        .background(Rectangle().fill(Theme.surfaceSubtle))
    }

    var ideaList: some View {
        let ranked = ideas.sorted { a, b in
            if a.isLive != b.isLive { return a.isLive }
            return (a.rank ?? Int.max, a.createdAt) < (b.rank ?? Int.max, b.createdAt)
        }
        let shown = showAll ? ranked : Array(ranked.prefix(6))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { IdeaRow(idea: $0) }
            if ranked.count > 6 {
                Button(showAll ? L("Show fewer") : L10n.f("Show all %d ideas", ranked.count)) { showAll.toggle() }
                    .buttonStyle(.link).font(Theme.caption).padding(.top, Theme.Space.xs)
            }
        }
    }
}

/// The eight stages as segment cells: settled ones filled, the current one rippling, later ones empty.
private struct StageTrack: View {
    let state: BrainstormState

    static func title(_ s: String) -> String {
        switch s {
        case "ground": return L("Ground")
        case "diverge": return L("Diverge")
        case "dedupe": return L("Dedupe")
        case "rank": return L("Rank")
        case "novelty": return L("Novelty")
        case "review": return L("Review")
        case "evolve": return L("Evolve")
        default: return L("Report")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: 3) {
                ForEach(BrainstormState.stages, id: \.self) { s in
                    let current = s == state.stage && state.endedAt == nil
                    let done = state.stagesDone.contains(s) || (state.endedAt != nil && s == state.stage)
                    VStack(alignment: .leading, spacing: 3) {
                        Group {
                            if current { DotActivity(size: 3, dot: 3, gap: 1.5, color: Theme.accent) }
                            else { DotCells(lit: done, color: done ? Theme.ink.opacity(0.7) : Theme.rule) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.title(s)).font(Theme.label).textCase(.uppercase).tracking(0.4).lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(current ? Theme.accent : done ? Color.primary : Color.secondary.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    .overlay(alignment: .top) { Rectangle().fill(current ? Theme.accent : done ? Theme.ink.opacity(0.5) : Theme.hairline).frame(height: current ? 2 : 1) }
                }
            }
            if state.endedAt == nil, !state.stageNote.isEmpty {
                Text(state.stageNote).font(Theme.meta).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .animation(Theme.Motion.allowed ? Theme.Motion.hover : nil, value: state.stage)
    }
}

/// A 3×3 block of square dots.
private struct DotCells: View {
    let lit: Bool
    let color: Color
    var body: some View {
        Canvas { ctx, _ in
            for y in 0..<3 { for x in 0..<3 {
                ctx.fill(Path(CGRect(x: CGFloat(x) * 4.5, y: CGFloat(y) * 4.5, width: 3, height: 3)), with: .color(lit ? color : color.opacity(0.6)))
            } }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// The sieve: one dot per idea, columns thinning out as ideas are merged, found known or set aside.
/// New dots drop in from above, as grains through a sieve.
private struct IdeaSieve: View {
    let ideas: [Idea]

    var columns: [(String, Int, Color)] {
        let distinct = ideas.filter { $0.status != .merged }
        let checked = distinct.filter { $0.novelty != nil }
        let kept = distinct.filter(\.isLive)
        let registered = ideas.filter { $0.status == .promoted }
        return [(L("Generated"), ideas.count, Theme.ink.opacity(0.35)),
                (L("Distinct"), distinct.count, Theme.ink.opacity(0.6)),
                (L("Checked"), checked.count, Theme.accent.opacity(0.65)),
                (L("Kept"), kept.count, Theme.accent),
                (L("Registered"), registered.count, Theme.ok)]
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.m) {
            ForEach(Array(columns.enumerated()), id: \.offset) { i, c in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    DotStack(count: c.1, color: c.2)
                    HStack(spacing: 4) {
                        Text("\(c.1)").font(Theme.label).monospacedDigit().foregroundStyle(.primary)
                        Text(c.0).font(Theme.label).textCase(.uppercase).tracking(0.4).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if i < columns.count - 1 {
                    Text("›").font(Theme.label).foregroundStyle(.tertiary).padding(.bottom, 1)
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(columns.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
    }
}

private struct DotStack: View {
    let count: Int
    let color: Color
    static let perRow = 6, maxRows = 4, dot: CGFloat = 4, gap: CGFloat = 2

    var body: some View {
        let cap = Self.perRow * Self.maxRows
        let shown = min(count, cap)
        let rows = Self.maxRows
        // Bottom-up fill, like grains settling.
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach((0..<rows).reversed(), id: \.self) { r in
                HStack(spacing: Self.gap) {
                    ForEach(0..<Self.perRow, id: \.self) { c in
                        let i = r * Self.perRow + c
                        if i < shown {
                            Rectangle().fill(color).frame(width: Self.dot, height: Self.dot)
                                .transition(Theme.Motion.allowed ? .offset(y: -10).combined(with: .opacity) : .identity)
                        } else {
                            Rectangle().fill(Theme.hairline).frame(width: Self.dot, height: Self.dot)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if count > cap { Text("+\(count - cap)").font(Theme.monoTiny).foregroundStyle(.secondary).offset(x: 18) }
        }
        .animation(Theme.Motion.allowed ? .spring(response: 0.32, dampingFraction: 0.82) : nil, value: shown)
        .accessibilityHidden(true)
    }
}

/// One idea: id, statement, operator and check status. Dashed rule while speculative, solid green
/// once registered as a hypothesis, faded when merged, discarded or already known.
private struct IdeaRow: View {
    let idea: Idea
    @State private var expanded = false

    var tint: Color {
        if idea.status == .promoted { return Theme.ok }
        if !idea.isLive { return Theme.rule }
        return idea.novelty == nil ? Theme.ink.opacity(0.35) : Theme.accent
    }

    var noveltyText: String {
        if idea.status == .merged { return L10n.f("Same as %@", idea.mergedInto ?? "") }
        if idea.status == .promoted { return L10n.f("Hypothesis %@", idea.hypothesisId ?? "") }
        if idea.status == .discarded && idea.novelty != .known { return L("Set aside") }
        switch idea.novelty {
        case .none: return L("Not checked")
        case .notFound: return L("No prior work found")
        case .incremental: return L("Incremental")
        case .known: return L("Already published")
        }
    }

    var body: some View {
        Button { withAnimation(Theme.Motion.allowed ? Theme.Motion.hover : nil) { expanded.toggle() } } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(idea.id).font(Theme.label).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 22, alignment: .leading)
                    Text(idea.statement).font(Theme.body).lineLimit(expanded ? nil : 2)
                        .strikethrough(!idea.isLive && idea.status != .promoted, color: .secondary)
                        .foregroundStyle(idea.isLive || idea.status == .promoted ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Chip(text: idea.op.split(separator: ":").first.map(String.init)?.uppercased() ?? "", tint: .secondary)
                    Chip(text: noveltyText, tint: idea.status == .promoted ? Theme.ok : idea.novelty == .notFound ? Theme.accent : idea.novelty == .known ? Theme.bad : .secondary)
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        if !idea.mechanism.isEmpty { detail(L("Mechanism"), idea.mechanism) }
                        if !idea.test.isEmpty { detail(L("Test"), idea.test) }
                        if !idea.falsifier.isEmpty { detail(L("Refuted if"), idea.falsifier) }
                        if !idea.seeds.isEmpty { detail(L("Seeds"), idea.seeds.joined(separator: ", ")) }
                        if !idea.closestPrior.isEmpty { detail(L("Closest prior work"), idea.closestPrior.joined(separator: ", ")) }
                        if !idea.noveltyReceipts.isEmpty { detail(L("Searches"), idea.noveltyReceipts.joined(separator: " ")) }
                    }
                    .padding(.leading, 22 + Theme.Space.s)
                }
            }
            .padding(.vertical, Theme.Space.xs + 1)
            .padding(.leading, Theme.Space.s)
            .overlay(alignment: .leading) {
                Rectangle().strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: idea.status == .promoted ? [] : [3, 2])).frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(Theme.Motion.allowed ? .opacity.combined(with: .offset(y: -6)) : .identity)
    }

    func detail(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(k).font(Theme.label).textCase(.uppercase).tracking(0.4).foregroundStyle(.tertiary).frame(width: 96, alignment: .leading)
            Text(v).font(Theme.meta).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
