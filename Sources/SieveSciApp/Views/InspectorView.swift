import AppKit
import MarkdownUI
import SieveSciCore
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xxs) {
                    ForEach(InspectorTab.side) { t in
                        InspectorTabButton(tab: t, selected: model.inspectorTab == t, badge: badge(t) > 0) {
                            model.inspectorTab = t
                            if t == .jobs { model.markJobsRead() }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.xs + 2)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: Theme.Space.s) {
                Text(model.inspectorTab.title).font(Theme.bodyStrong)
                if badge(model.inspectorTab) > 0 {
                    Text("\(badge(model.inspectorTab))").font(Theme.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accentSoft))
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.xs)
            Group {
                switch model.inspectorTab {
                case .files: FilesPanel()
                case .changes: ChangesPanel()
                case .history: HistoryPanel()
                case .jobs: JobsPanel()
                case .figures: FiguresPanel()
                default:
                    ScrollView {
                        Group {
                            switch model.inspectorTab {
                            case .activity: ActivityPanel()
                            case .plan: PlanPanel()
                            case .claims: ClaimsPanel()
                            case .library: LibraryPanel()
                            case .notebook: NotebookPanel()
                            default: LearningPanel()
                            }
                        }
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            // Split-view panels (History, Changes, Files) size to their content otherwise, leaving a strip.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .task { model.refreshSidePanels() }
    }

    func badge(_ t: InspectorTab) -> Int {
        switch t {
        case .jobs: return model.jobs.values.reduce(0) { $0 + $1.unread }
        case .claims: return model.contested.count + model.claims.filter { $0.status == .verifying }.count
        case .learning: return model.proposals.filter { $0.status == .pending }.count
        default: return 0
        }
    }
}

/// Icon-only tab with hover fill; the active tab's name is shown as the panel title below.
struct InspectorTabButton: View {
    let tab: InspectorTab
    let selected: Bool
    let badge: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.icon)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : (hovering ? .primary : .secondary))
                .frame(width: Theme.Control.icon, height: Theme.Control.icon)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .fill(selected ? Theme.accentSoft : (hovering ? Theme.hairline : .clear)))
                .overlay(alignment: .topTrailing) {
                    if badge { Rectangle().fill(Theme.accent).frame(width: 5, height: 5).offset(x: -4, y: 4) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.title)
    }
}

struct PlanPanel: View {
    @EnvironmentObject var model: AppModel

    func stepIcon(_ status: String) -> (String, Color) {
        switch status {
        case "done": return ("checkmark.circle.fill", Theme.ok)
        case "in_progress": return ("circle.lefthalf.filled", Theme.accent)
        case "failed": return ("xmark.circle.fill", Theme.bad)
        case "skipped": return ("minus.circle", .secondary)
        default: return ("circle", .secondary)
        }
    }

    var body: some View {
        let p = model.plan
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                Text(L("Stage")).font(Theme.meta).foregroundStyle(.secondary)
                Chip(text: L(p.stage.rawValue), tint: Theme.accent)
                Spacer()
                if let g = model.bench?.services.research.hasGrounding() {
                    HStack(spacing: Theme.Space.s) {
                        Label(L("web"), systemImage: g.web ? "checkmark.circle.fill" : "circle").foregroundStyle(g.web ? Theme.ok : .secondary)
                        Label(L("literature"), systemImage: g.literature ? "checkmark.circle.fill" : "circle").foregroundStyle(g.literature ? Theme.ok : .secondary)
                    }
                    .font(Theme.caption)
                    .help(L("Grounding gate: both searches must succeed before planning, claims and checkpoints"))
                }
            }
            if p.goal.isEmpty {
                Text(L("No plan yet. The agent searches first, then writes a plan with hypotheses and checkpoints.")).font(Theme.body).foregroundStyle(.secondary)
            } else {
                Text(p.goal).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if !p.hypotheses.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        SectionLabel(L("Hypotheses"))
                        ForEach(p.hypotheses) { h in
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                HStack(spacing: Theme.Space.xs + 2) {
                                    Text(h.id).font(Theme.monoTiny).foregroundStyle(.secondary)
                                    Chip(text: L(h.status), tint: Theme.accent)
                                }
                                Text(h.statement).font(Theme.body)
                                Text(L("falsified if:") + " \(h.falsification)").font(Theme.meta).foregroundStyle(.secondary)
                            }
                            .threadRule(Theme.separator)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
                    SectionLabel(L("Steps"))
                    ForEach(p.steps) { s in
                        let (icon, color) = stepIcon(s.status)
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: Theme.gutter)
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                HStack(spacing: Theme.Space.xs + 2) {
                                    Text(s.title).font(Theme.body)
                                        .foregroundStyle(s.status == "skipped" ? .secondary : .primary)
                                        .strikethrough(s.status == "skipped")
                                    if s.checkpoint { Chip(text: L("checkpoint"), tint: Theme.accent, icon: "flag.fill") }
                                }
                                if !s.evidence.isEmpty {
                                    Text(L("evidence:") + " " + s.evidence.joined(separator: ", ")).font(Theme.monoTiny).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                if p.revisions.count > 1 {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionLabel(L("Revisions"))
                        ForEach(Array(p.revisions.enumerated()), id: \.offset) { _, r in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Image(systemName: r.afterResults ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                                    .font(Theme.caption).foregroundStyle(r.afterResults ? Theme.warn : .secondary).frame(width: Theme.gutter)
                                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                    Text(r.rationale).font(Theme.meta)
                                    if r.afterResults { Text(L("criteria changed after results")).font(Theme.caption).foregroundStyle(Theme.warn) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ClaimsPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if model.claims.isEmpty && model.contested.isEmpty {
                Text(L("No claims. Significant findings are registered with claim_finding and verified blind by an independent agent."))
                    .font(Theme.body).foregroundStyle(.secondary)
            }
            if !model.contested.isEmpty {
                SectionLabel(L("Contested between agents"))
                ForEach(Array(model.contested.enumerated()), id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack(spacing: Theme.Space.xs + 2) {
                            Text(c.thread).font(Theme.monoTiny).foregroundStyle(.secondary)
                            VerdictChip(verdict: "contested")
                            Text(L(c.kind)).font(Theme.caption).foregroundStyle(.secondary)
                        }
                        Text(c.issue).font(Theme.body)
                        Text(c.reason).font(Theme.meta).foregroundStyle(.secondary)
                    }
                    .box(highlight: Theme.warn, provisional: true)
                }
            }
            ForEach(Array(model.claims.enumerated()), id: \.element.id) { i, c in
                if i > 0 || !model.contested.isEmpty { Divider() }
                VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                    HStack(spacing: Theme.Space.xs + 2) {
                        Text(c.id).font(Theme.monoTiny).foregroundStyle(.secondary)
                        VerdictChip(verdict: c.status.rawValue)
                    }
                    Text(c.statement).font(Theme.body).fixedSize(horizontal: false, vertical: true)
                    Text(L("criteria:") + " \(c.successCriteria)").font(Theme.meta).foregroundStyle(.secondary)
                    if let v = c.verdict { Text(v).font(Theme.meta).foregroundStyle(.secondary).lineLimit(6).threadRule(Theme.verdictColor(c.status.rawValue).opacity(0.6)) }
                }
            }
        }
    }
}

struct LibraryPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var links: [CodePaperLink] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(L10n.f("%d papers", model.library.count)).font(Theme.meta).foregroundStyle(.secondary)
                Spacer()
                if let dir = model.bench?.services.library.dir {
                    EqualWidthButtons {
                        Button(L("BibTeX")) { NSWorkspace.shared.open(dir.appendingPathComponent("references.bib")) }.buttonStyle(.action)
                        Button(L("Folder")) { NSWorkspace.shared.open(dir) }.buttonStyle(.action)
                    }
                }
            }
            ForEach(model.library) { r in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("[@\(r.key)]").font(Theme.monoTiny).foregroundStyle(Theme.accent)
                    Text(r.title).font(Theme.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Text("\(r.authors.prefix(3).joined(separator: ", "))\(r.authors.count > 3 ? " et al." : "") · \(r.year.map(String.init) ?? "n.d.") · \(r.venue ?? r.source)")
                        .font(Theme.meta).foregroundStyle(.secondary)
                    HStack(spacing: Theme.Space.m) {
                        if let d = r.doi, let u = URL(string: "https://doi.org/\(d)") { Link("DOI", destination: u).font(.caption) }
                        if let p = r.pdfPath, let dir = model.bench?.services.library.dir {
                            Button("PDF") { NSWorkspace.shared.open(dir.appendingPathComponent(p)) }.buttonStyle(.link).font(.caption)
                        }
                        let impl = links.filter { $0.paperKey == r.key }
                        if !impl.isEmpty {
                            Menu(L10n.f("Implemented in %d places", impl.count)) {
                                ForEach(Array(impl.enumerated()), id: \.offset) { _, l in
                                    Button("\(l.file):\(l.line)\(l.locator.map { " \($0)" } ?? "")") {
                                        if let ws = model.workspace { NSWorkspace.shared.open(ws.appendingPathComponent(l.file)) }
                                    }
                                }
                            }.font(.caption).fixedSize()
                        }
                    }
                }
                Divider()
            }
        }
        .task(id: model.library.count) {
            guard let ws = model.workspace, let lib = model.bench?.services.library else { return }
            let found = await Task.detached { CodePaperLinker.scan(workspace: ws, library: lib) }.value
            links = found
        }
    }
}

struct NotebookPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(L("Written automatically from the provenance log")).font(Theme.meta).foregroundStyle(.secondary)
                Spacer()
                EqualWidthButtons {
                    if let url = model.bench?.services.notebook.url {
                        Button(L("Open")) { NSWorkspace.shared.open(url) }.buttonStyle(.action)
                    }
                    Button(L("Verify chain")) { model.submit("/audit", attachments: []) }.buttonStyle(.action)
                }
            }
            Markdown(MathMarkdown.prepared(text)).markdownTheme(Theme.markdown).markdownMath().textSelection(.enabled)
        }
        .task(id: model.items.count + model.history.count) {
            if let url = model.bench?.services.notebook.url { text = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        }
    }
}

struct LearningPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L("Every role learns, through governed proposals: screened for integrity, grounded in receipts, independently reviewed; reviewer and verifier learning needs your approval."))
                .font(Theme.meta).foregroundStyle(.secondary)
            ForEach(model.proposals) { p in
                Divider()
                VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                    HStack(spacing: Theme.Space.xs + 2) {
                        Text(p.role.rawValue).font(Theme.monoTiny).foregroundStyle(Theme.accent)
                        Text("\(p.kind.rawValue) · \(p.target) · \(p.operation)").font(Theme.monoTiny).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Chip(text: L(p.status.rawValue), tint: p.status == .accepted ? Theme.ok : (p.status == .rejected ? Theme.bad : Theme.warn))
                    }
                    Text(p.content).font(Theme.body).lineLimit(6)
                    Text(p.reason).font(Theme.meta).foregroundStyle(.secondary).lineLimit(4)
                    if p.status == .pending, let s = model.bench?.services {
                        EqualWidthButtons {
                            Button(L("Approve")) { _ = s.governor.decide(p.id, approve: true, services: s); model.refreshSidePanels() }
                                .buttonStyle(.primaryAction)
                            Button(L("Reject")) { _ = s.governor.decide(p.id, approve: false, services: s); model.refreshSidePanels() }
                                .buttonStyle(.action(.destructive))
                        }
                    } else if p.status == .accepted, let s = model.bench?.services {
                        Button(L("Revert")) { _ = s.governor.revert(p.id, services: s); model.refreshSidePanels() }.buttonStyle(.action)
                    }
                }
            }
        }
    }
}
