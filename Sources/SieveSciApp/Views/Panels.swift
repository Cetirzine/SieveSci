import AppKit
import Quartz
import SieveSciCore
import SwiftUI

// MARK: - Activity: who did what, what was read, what was checked

struct ActivityPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var filter = 0
    /// Rows drawn so far, newest first. A long project's audit log holds tens of thousands of events;
    /// drawing them all at once froze the window, so older ones come in pages.
    @State private var limit = ActivityPanel.page

    static let page = 200

    /// From the audit log, so the trace is complete after a restart and for CLI agents, whose tool
    /// calls are not tool blocks in the saved transcript.
    var events: [TraceEvent] {
        switch filter {
        case 1: return model.trace.filter { $0.category == .literature }
        case 2: return model.trace.filter { $0.category == .agents }
        default: return model.trace
        }
    }

    static func icon(_ e: TraceEvent) -> String {
        switch e.kind {
        case "review": return "checkmark.seal"
        case "signal", "gate": return "exclamationmark.triangle"
        case "deliberation": return "arrow.left.arrow.right"
        case "commit": return "clock.arrow.circlepath"
        case "permission": return "hand.raised"
        case "error": return "xmark.octagon"
        case "compaction": return "rectangle.compress.vertical"
        case "user": return "person"
        default: return Theme.toolIcon(e.kind)
        }
    }

    var body: some View {
        let all = events
        let shown = all.suffix(limit).reversed()
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Picker("", selection: $filter) {
                Text(L("All")).tag(0)
                Text(L("Literature")).tag(1)
                Text(L("Agents & checks")).tag(2)
            }.pickerStyle(.segmented).labelsHidden()
            .onChange(of: filter) { _, _ in limit = Self.page }
            let agents = model.cards.values.sorted { $0.started > $1.started }
            if !agents.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionLabel(L("Agents"))
                    ForEach(agents, id: \.id) { c in
                        HStack(spacing: Theme.Space.s) {
                            RoleGhostBadge(role: c.role, working: c.ended == nil, size: 24)
                            Text(Theme.agentName(c.id)).font(Theme.metaStrong)
                            Text(c.purpose).font(Theme.meta).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            if c.ended != nil { Image(systemName: "checkmark").font(Theme.caption).foregroundStyle(Theme.ok) }
                        }
                    }
                }
                Divider()
            }
            if all.isEmpty {
                Text(L("Nothing yet.")).font(Theme.body).foregroundStyle(.secondary)
            } else {
                SectionLabel(L("Events") + " · \(all.count)")
            }
            LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(shown, id: \.id) { e in TraceRow(event: e).equatable() }
            }
            if all.count > limit {
                Button(L10n.f("Show older (%d more)", all.count - limit)) { limit += Self.page * 2 }
                    .buttonStyle(.action)
            }
        }
    }
}

/// One audit event. Equatable, so a refresh that appends events leaves the existing rows alone.
struct TraceRow: View, Equatable {
    let event: TraceEvent

    var body: some View {
        let e = event
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: ActivityPanel.icon(e)).font(Theme.caption)
                .foregroundStyle(e.isError ? (e.kind == "signal" || e.kind == "gate" ? Theme.warn : Theme.bad) : .secondary)
                .frame(width: Theme.gutter).padding(.top, 2)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                HStack(spacing: Theme.Space.xs + 2) {
                    Text(e.actor == "host" ? L("Host") : e.actor == "user" ? L("You") : e.actor == "git" ? "git" : Theme.agentName(e.actor))
                        .font(Theme.metaStrong)
                    Text(e.at, format: .dateTime.hour().minute()).font(Theme.monoTiny).foregroundStyle(.tertiary)
                }
                Text((Theme.toolNames[e.kind].map { L($0) + " " } ?? "") + e.text)
                    .font(Theme.meta).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Changes: per-file diff since the task started, with revert

struct ChangesPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?
    @State private var diff: FileDiff?
    @State private var confirmRevert = false

    var body: some View {
        VSplitView {
            List(selection: $selected) {
                if model.changedFiles.isEmpty { Text(L("No files changed in this task yet.")).font(Theme.body).foregroundStyle(.secondary) }
                ForEach(model.changedFiles, id: \.self) { f in
                    let d = model.bench.map { $0.services.changes.diff(model.absolute(f), workspace: $0.services.workspace) }
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: d?.isNewFile == true ? "doc.badge.plus" : "doc.text").font(Theme.caption).foregroundStyle(.secondary)
                        Text(f).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let d {
                            Text("+\(d.added)").foregroundStyle(Theme.ok).font(Theme.monoTiny)
                            Text("−\(d.removed)").foregroundStyle(Theme.bad).font(Theme.monoTiny)
                        }
                    }.tag(f)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, minHeight: 120)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let f = selected, let d = diff {
                    HStack {
                        Text(f).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        EqualWidthButtons {
                            Button(L("Open")) { if let ws = model.workspace { NSWorkspace.shared.open(ws.appendingPathComponent(f)) } }.buttonStyle(.action)
                            Button(L("Revert"), role: .destructive) { confirmRevert = true }.buttonStyle(.action(.destructive))
                        }
                    }
                    
                    ScrollView { DiffView(diff: d).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    Text(L("Select a file to see what changed (red removed, green added).")).font(Theme.body).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selected) { _, f in load(f) }
        .confirmationDialog(L("Revert this file to its state before the task?"), isPresented: $confirmRevert) {
            Button(L("Revert"), role: .destructive) {
                if let f = selected, let s = model.bench?.services, s.changes.revert(model.absolute(f)) {
                    s.log("revert_file", actor: "user", ["path": .string(f)])
                    load(f)
                }
            }
        }
    }

    func load(_ f: String?) {
        guard let f, let s = model.bench?.services else { diff = nil; return }
        diff = s.changes.diff(model.absolute(f), workspace: s.workspace)
    }
}

// MARK: - History: shadow-git commits with diffs and restore

struct HistoryPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?
    @State private var diffs: [FileDiff] = []
    @State private var confirmRestore = false

    var body: some View {
        VSplitView {
            List(selection: $selected) {
                if model.history.isEmpty { Text(L("No history yet. Every turn that changes files is committed to a private history (.sievesci/history.git).")).font(Theme.body).foregroundStyle(.secondary) }
                ForEach(model.history, id: \.hash) { c in
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text(c.subject).font(Theme.body).lineLimit(2)
                        HStack(spacing: Theme.Space.s) {
                            Text(String(c.hash.prefix(8))).font(Theme.monoTiny).foregroundStyle(Theme.accent)
                            Text(String(c.date.prefix(16))).font(Theme.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Text(L10n.f("%d files", c.files)).font(Theme.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, Theme.Space.xxs)
                    .tag(c.hash)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, minHeight: 140)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let h = selected {
                    HStack {
                        Text(String(h.prefix(10))).font(Theme.monoSmall)
                        Spacer()
                        Button(L("Restore files to this point"), role: .destructive) { confirmRestore = true }.buttonStyle(.action(.destructive))
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            ForEach(Array(diffs.enumerated()), id: \.offset) { _, d in
                                HStack(spacing: Theme.Space.s) {
                                    Text(d.path).font(Theme.monoSmall.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                    Text("+\(d.added)").font(Theme.monoTiny).foregroundStyle(Theme.ok)
                                    Text("−\(d.removed)").font(Theme.monoTiny).foregroundStyle(Theme.bad)
                                }
                                DiffView(diff: d, maxLines: 600)
                            }
                        }
                    }
                } else {
                    Text(L("Select a commit to see its changes.")).font(Theme.body).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.refreshHistory() }
        .onChange(of: selected) { _, h in
            guard let h, let git = model.bench?.services.git else { return }
            Task { let d = await git.diffs(of: h); await MainActor.run { diffs = d } }
        }
        .confirmationDialog(L("Restore all workspace files to this commit? Current state is committed first, so this can be undone."), isPresented: $confirmRestore) {
            Button(L("Restore"), role: .destructive) {
                guard let h = selected, let s = model.bench?.services else { return }
                Task {
                    _ = await s.git.snapshot(subject: "before restore to \(h.prefix(10))", trailers: ["SieveSci-Task": s.taskId])
                    let ok = await s.git.restore(h)
                    s.log("git_restore", actor: "user", ["commit": .string(h), "ok": .bool(ok)])
                    await model.refreshHistory()
                }
            }
        }
    }
}

// MARK: - Jobs: live logs of background processes and tailed files

struct JobsPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?
    @State private var follow = true

    var body: some View {
        VSplitView {
            List(selection: $selected) {
                if model.jobOrder.isEmpty {
                    Text(L("No background jobs. Long commands run as streaming jobs; you and the agent are notified when they finish, fail, match a pattern or stall.")).font(Theme.body).foregroundStyle(.secondary)
                }
                ForEach(model.jobOrder.reversed(), id: \.self) { id in
                    if let j = model.jobs[id] {
                        HStack(spacing: Theme.Space.s) {
                            ZStack {
                                if j.running { ProgressView().controlSize(.mini) } else {
                                    Image(systemName: j.exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill").font(Theme.caption)
                                        .foregroundStyle(j.exitCode == 0 ? Theme.ok : Theme.bad)
                                }
                            }
                            .frame(width: Theme.gutter)
                            Text(j.id).font(Theme.monoTiny).foregroundStyle(.secondary)
                            Text(j.label).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let s = j.seconds { Text("\(s)s").font(Theme.caption).monospacedDigit().foregroundStyle(.tertiary) }
                        }.tag(id)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, minHeight: 100)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let id = selected ?? model.jobOrder.last, let j = model.jobs[id] {
                    HStack {
                        Chip(text: j.running ? L("running") : L10n.f("exit %d", Int(j.exitCode ?? -1)),
                             tint: j.running ? Theme.accent : (j.exitCode == 0 ? Theme.ok : Theme.bad))
                        Text(L10n.f("%d lines", j.lines.count)).font(Theme.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Toggle(L("Follow"), isOn: $follow).toggleStyle(.checkbox)
                        EqualWidthButtons {
                            if j.running {
                                Button(L("Stop"), role: .destructive) { _ = model.bench?.services.jobs.stop(id) }.buttonStyle(.action(.destructive))
                            }
                            if let path = model.bench?.services.jobs.all.first(where: { $0.id == id })?.logPath {
                                Button(L("Open log")) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.buttonStyle(.action)
                            }
                        }
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(j.lines.enumerated()), id: \.offset) { i, l in
                                    Text(l.isEmpty ? " " : l)
                                        .font(Theme.monoTiny)
                                        .foregroundStyle(JobsPanel.looksLikeError(l) ? Theme.bad : .primary)
                                        .textSelection(.enabled)
                                        .id(i)
                                }
                            }
                            .padding(Theme.Space.s + 2)
                        }
                        .background(Theme.surfaceSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous).strokeBorder(Theme.hairline))
                        .onChange(of: j.lines.count) { _, n in if follow { proxy.scrollTo(n - 1, anchor: .bottom) } }
                    }
                } else {
                    Spacer()
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { model.markJobsRead() }
    }

    static func looksLikeError(_ l: String) -> Bool {
        l.range(of: JobMonitor.defaultErrorPattern, options: .regularExpression) != nil
    }
}

// MARK: - Figures

struct FiguresPanel: View {
    @EnvironmentObject var model: AppModel
    let columns = [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.m)]

    var body: some View {
        ScrollView {
            if model.figures.isEmpty {
                Text(L("Figures written during this task appear here.")).font(Theme.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.l)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.l) {
                ForEach(model.figures, id: \.self) { url in
                    FigureTile(url: url)
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                        .contextMenu {
                            Button(L("Open")) { NSWorkspace.shared.open(url) }
                            Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Button(L("Ask the checker to review this figure")) {
                                model.submit("/review " + L("figure") + " " + url.lastPathComponent, attachments: [])
                            }
                        }
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
        }
        .task { model.refreshSidePanels() }
    }
}

/// Figure thumbnail on a white mat (plots are drawn for white paper, in either appearance).
struct FigureTile: View {
    let url: URL
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            Group {
                if let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().scaledToFit().padding(Theme.Space.s)
                } else {
                    Image(systemName: "doc.richtext").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous)
                .strokeBorder(hovering ? Theme.accent.opacity(0.6) : Theme.separator))
            Text(url.lastPathComponent).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .onHover { hovering = $0 }
        .help(url.lastPathComponent)
    }
}

// MARK: - Files: workspace browser with Quick Look preview

final class FileNode: Identifiable, Hashable {
    let url: URL
    let isDir: Bool
    var id: URL { url }
    init(url: URL, isDir: Bool) { self.url = url; self.isDir = isDir }
    static func == (a: FileNode, b: FileNode) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }

    static let skipped: Set<String> = [".git", ".sievesci", ".build", "node_modules", "__pycache__", ".venv", "venv", ".DS_Store", ".ipynb_checkpoints"]

    private var listed: [FileNode]?

    /// Read from disk once per node: the panel rebuilds its root (and so re-reads) only on reload.
    var children: [FileNode]? {
        guard isDir else { return nil }
        if let listed { return listed }
        let list = Self.list(url)
        listed = list
        return list
    }

    private static func list(_ url: URL) -> [FileNode] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return urls.filter { !Self.skipped.contains($0.lastPathComponent) }
            .map { FileNode(url: $0, isDir: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
            .sorted { ($0.isDir ? 0 : 1, $0.url.lastPathComponent.lowercased()) < ($1.isDir ? 0 : 1, $1.url.lastPathComponent.lowercased()) }
            .prefix(2000).map { $0 }
    }
}

struct FilesPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: URL?
    @State private var reload = 0
    @State private var root: (url: URL, reload: Int, node: FileNode)?

    /// The tree's root, rebuilt only when the workspace changes or the panel reloads — not on every
    /// redraw (the body runs whenever anything in the model changes).
    func rootChildren(_ ws: URL) -> [FileNode] {
        if let r = root, r.url == ws, r.reload == reload { return r.node.children ?? [] }
        let node = FileNode(url: ws, isDir: true)
        DispatchQueue.main.async { root = (ws, reload, node) }
        return node.children ?? []
    }

    var body: some View {
        VSplitView {
            if let ws = model.workspace {
                List(selection: $selected) {
                    OutlineGroup(rootChildren(ws), children: \.children) { node in
                        HStack(spacing: Theme.Space.xs + 2) {
                            Image(systemName: node.isDir ? "folder.fill" : FilesPanel.icon(node.url)).font(Theme.caption)
                                .foregroundStyle(node.isDir ? Theme.info.opacity(0.85) : .secondary).frame(width: Theme.gutter)
                            Text(node.url.lastPathComponent).font(Theme.meta).lineLimit(1)
                            if model.changedFiles.contains(String(node.url.path.dropFirst(ws.path.count + 1))) {
                                Circle().fill(Theme.warn).frame(width: 5, height: 5).help(L("Changed in this task"))
                            }
                        }
                        .tag(node.url)
                        .contextMenu {
                            Button(L("Open")) { NSWorkspace.shared.open(node.url) }
                            Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                            Button(L("Mention in prompt")) { model.draft = "@" + String(node.url.path.dropFirst(ws.path.count + 1)) + " " }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .id(reload)
                .frame(maxWidth: .infinity, minHeight: 160)
            }
            Group {
                if let u = selected {
                    QuickLookPreview(url: u)
                } else {
                    Text(L("Select a file to preview it.")).font(Theme.body).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { }
        .onChange(of: model.changedFiles.count) { _, _ in reload += 1 }
    }

    static func icon(_ u: URL) -> String {
        switch u.pathExtension.lowercased() {
        case "py", "r", "sh", "swift", "jl", "ipynb": return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "svg", "tif", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "csv", "tsv", "xlsx", "parquet", "h5ad": return "tablecells"
        case "fasta", "fa", "fastq", "gb", "pdb", "cif", "sdf", "mol2", "bam", "vcf": return "atom"
        case "md", "txt", "bib": return "doc.text"
        default: return "doc"
        }
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .compact)!
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }
}
