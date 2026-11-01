import AppKit
import Foundation
import SieveSciCore
import SwiftUI

/// Side panels, task stages ("Needs you"), history and quotas.
extension AppModel {
    // MARK: Side panels

    static func isFigure(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "svg", "pdf", "tif", "tiff", "gif", "webp"].contains((path as NSString).pathExtension.lowercased())
    }

    func addFigure(_ url: URL) {
        figures.removeAll { $0 == url }
        figures.insert(url, at: 0)
    }

    // MARK: Attention

    func stageFacts(_ b: Workbench, id: String) -> TaskStage.Facts {
        var f = TaskStage.Facts()
        let s = b.services
        f.permissionAsk = id == taskId ? pendingPermission.map { "\($0.tool): \($0.summary)" } : backgroundAsks[id].map { "\($0.0.tool): \($0.0.summary)" }
        f.goal = s.goal.current
        f.planMode = s.permissions.mode == .plan
        f.planHasSteps = !s.research.snapshot.steps.isEmpty
        f.contested = s.deliberation.contested.first.map { $0.issue }
        f.lastError = turnFailures[id]
        f.running = b.isRunning
        f.runningJobs = s.jobs.runningCount
        return f
    }

    /// Recomputes a live task's stage; entering a person stage notifies (only then: quiet by default).
    func refreshStage(_ id: String, notify: Bool = true) {
        let b = id == taskId ? bench : background[id]
        guard let b else { return }
        let stage = TaskStage.of(stageFacts(b, id: id))
        let ws = id == taskId ? (workspace?.standardizedFileURL.path ?? "") : (backgroundWorkspaces[id] ?? attention[id]?.workspace ?? "")
        let old = attention[id]?.stage
        guard old != stage || attention[id]?.workspace != ws else { return }
        attention[id] = Attention(stage: stage, workspace: ws)
        if notify, stage.needsPerson, old?.needsPerson != true {
            notifier.post(title: L("SieveSci needs you") + " · " + stage.label, body: title(of: id) + (stage.detail.isEmpty ? "" : " — " + String(stage.detail.prefix(140))), id: "attn-\(id)")
        }
    }

    /// Tasks that wait for the user, the open workspace's first.
    var needsYou: [(id: String, attention: Attention)] {
        let here = workspace?.standardizedFileURL.path
        return attention.filter { $0.value.stage.needsPerson }
            .sorted { ($0.value.workspace == here ? 0 : 1, $0.key) < ($1.value.workspace == here ? 0 : 1, $1.key) }
            .map { ($0.key, $0.value) }
    }

    /// Opens a task from the "Needs you" list, switching workspace when needed.
    func openAttention(_ id: String) {
        showSettingsPage = false
        mainTab = .chat
        guard let a = attention[id] else { return }
        if a.workspace != workspace?.standardizedFileURL.path, !a.workspace.isEmpty {
            open(workspace: URL(fileURLWithPath: a.workspace), task: id)
        } else if id != taskId {
            startSession(task: id)
        }
    }

    /// Assigns only real changes: every assignment to a `@Published` property re-renders the window,
    /// and this runs on appear and after each turn.
    private func update<T: Equatable>(_ kp: ReferenceWritableKeyPath<AppModel, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    func refreshSidePanels() {
        guard let s = bench?.services else { return }
        refreshTrace()
        update(\.plan, s.research.snapshot)
        update(\.claims, s.claims.snapshot)
        update(\.library, s.library.records)
        update(\.proposals, s.governor.proposals.reversed())
        let c = s.deliberation.contested
        if c.map(\.issue) != contested.map(\.issue) || c.map(\.thread) != contested.map(\.thread) { contested = c }
        var files = changedFiles
        for f in s.changes.changedFiles {
            let rel = f.hasPrefix(s.workspace.path + "/") ? String(f.dropFirst(s.workspace.path.count + 1)) : f
            if !files.contains(rel) { files.append(rel) }
        }
        update(\.changedFiles, files)
        // Figures any tool wrote (scripts, kernels), not only file edits.
        var figs = figures
        for r in s.ledger.all.reversed() {
            for path in r.filesWritten.keys where Self.isFigure(path) {
                let u = path.hasPrefix("/") ? URL(fileURLWithPath: path) : s.workspace.appendingPathComponent(path)
                if !figs.contains(u), FileManager.default.fileExists(atPath: u.path) { figs.append(u) }
            }
        }
        update(\.figures, figs)
        update(\.queued, bench?.queuedPrompts ?? [])
    }

    func markJobsRead() {
        for (k, j) in jobs where j.unread > 0 { jobs[k]?.unread = 0 }
    }

    /// Absolute path of a workspace-relative file (ChangeTracker keys are absolute).
    func absolute(_ rel: String) -> String {
        rel.hasPrefix("/") ? rel : (workspace?.appendingPathComponent(rel).path ?? rel)
    }

    func refreshHistory() async {
        guard let git = bench?.services.git else { return }
        let log = await git.log(limit: 200)
        await MainActor.run { self.history = log }
    }

    func refreshQuota(_ p: ProviderProfile) async {
        let q = await QuotaService.shared.refresh(p, secrets: secrets)
        await MainActor.run { self.quotas[p.id] = q }
    }

    func refreshQuotas() async {
        var seen = Set<String>()
        for p in usableProviders where seen.insert(p.id).inserted {
            let q = await QuotaService.shared.refresh(p, secrets: secrets)
            await MainActor.run { self.quotas[p.id] = q }
        }
    }
}
