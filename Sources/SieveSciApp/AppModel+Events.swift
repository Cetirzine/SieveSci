import AppKit
import Foundation
import SieveSciCore
import SwiftUI

/// Agent events → the visible activity: delta batching, routing between the open task and
/// background ones, and the transcript streams.
extension AppModel {
    /// Re-reads the audit log into `trace`, at most every 1.5 s while events stream in.
    func refreshTrace(soon: Bool = false) {
        guard let url = bench?.services.audit.url else { trace = []; return }
        if soon {
            guard !traceRefreshPending else { return }
            traceRefreshPending = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.traceRefreshPending = false
                self.refreshTrace()
            }
            return
        }
        // Only the lines appended since the last refresh are decoded.
        let cache = traceCache?.url == url ? traceCache! : (url: url, offset: 0, entries: [])
        Task.detached(priority: .utility) {
            let (new, offset) = AuditLog.readNew(url, from: cache.offset)
            let entries = cache.entries + new
            let events = Trace.events(entries)
            await MainActor.run {
                guard self.bench?.services.audit.url == url else { return }
                self.traceCache = (url, offset, entries)
                self.trace = events
            }
        }
    }

    /// Events from the open task drive the window; a background task only updates its sidebar dot and
    /// is released when it finishes.
    /// Streamed text arrives a few characters at a time from every agent at once. Handling each delta
    /// re-rendered the window and re-parsed the growing Markdown reply; they are buffered and applied
    /// together ~12 times a second (as chat clients do), and flushed before any other event so the
    /// order is kept (state: `pendingDeltas`, `pendingTask`, `deltaFlushScheduled` in `AppModel`).
    static func isDelta(_ ev: AgentEvent) -> Bool {
        switch ev {
        case .textDelta, .thinkingDelta, .toolProgress, .jobOutput: return true
        default: return false
        }
    }

    func flushDeltas() {
        guard !pendingDeltas.isEmpty else { return }
        let batch = pendingDeltas
        pendingDeltas = []
        guard pendingTask == taskId else { return }
        // Adjacent deltas from the same agent become one.
        var merged: [AgentEvent] = []
        for ev in batch {
            switch (merged.last, ev) {
            case (.textDelta(let a, let x)?, .textDelta(let b, let y)) where a == b: merged[merged.count - 1] = .textDelta(agentId: a, x + y)
            case (.thinkingDelta(let a, let x)?, .thinkingDelta(let b, let y)) where a == b: merged[merged.count - 1] = .thinkingDelta(agentId: a, x + y)
            default: merged.append(ev)
            }
        }
        merged.forEach(handle)
    }

    func route(_ ev: AgentEvent, task: String) {
        guard !Self.isDelta(ev) else { return deliver(ev, task: task) }
        switch ev {
        case .turnStarted(_, "main"): turnFailures[task] = nil
        case .error(let e): turnFailures[task] = e
        default: break
        }
        deliver(ev, task: task)
        refreshStage(task)
    }

    private func deliver(_ ev: AgentEvent, task: String) {
        if task == taskId {
            if Self.isDelta(ev) {
                if pendingTask != task { pendingDeltas = []; pendingTask = task }
                pendingDeltas.append(ev)
                if !deltaFlushScheduled {
                    deltaFlushScheduled = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        self.deltaFlushScheduled = false
                        self.flushDeltas()
                    }
                }
                return
            }
            flushDeltas()
            handle(ev)
            switch ev {
            case .toolFinished, .supervisorReview, .integrity, .deliberation, .turnFinished, .error: refreshTrace(soon: true)
            default: break
            }
            return
        }
        guard case .turnFinished(let agent, _) = ev, agent == "main" else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let b = self.background[task], !b.isRunning else { return }
            self.refreshStage(task)
            if self.attention[task]?.stage.needsPerson != true { self.attention[task] = nil }
            b.services.kernel.shutdownAll()
            self.background.removeValue(forKey: task)
            self.backgroundTasks.remove(task)
            self.backgroundWorkspaces.removeValue(forKey: task)
            self.refreshTaskList()
            // A task that now waits for the user already said so; "finished" would be a second message.
            if self.config.notifyTurnFinished, self.attention[task]?.stage.needsPerson != true {
                self.notifier.post(title: L("SieveSci finished"), body: self.title(of: task), id: "turn-\(task)")
            }
        }
    }

    // MARK: Events → activity

    @discardableResult
    func append(_ k: TranscriptItem.Kind, to stream: String) -> Int {
        let key = streams[stream] == nil && cards[stream] == nil ? "main" : stream
        streams[key, default: []].append(TranscriptItem(id: UUID().uuidString, kind: k))
        return streams[key]!.count - 1
    }

    func mutate(_ stream: String, _ i: Int, _ f: (inout TranscriptItem.Kind) -> Void) {
        guard var s = streams[stream], s.indices.contains(i) else { return }
        f(&s[i].kind)
        streams[stream] = s
    }

    static func summary(_ name: String, _ input: JSON) -> String {
        for k in ["command", "query", "path", "ref", "key", "statement", "pattern", "url", "id", "items"] {
            if let s = input[k]?.stringValue { return String(s.prefix(160)) }
        }
        if let code = input["code"]?.stringValue {
            return String((code.split(separator: "\n").first.map(String.init) ?? code).prefix(160))
        }
        return String(input.canonical.prefix(160))
    }

    func closeThinking(_ agent: String) {
        if let i = openThinking[agent] {
            mutate(agent, i) { k in if case .thinking(let t, let s, .none) = k { k = .thinking(t, started: s, ended: Date()) } }
        }
        openThinking[agent] = nil
    }

    func handle(_ ev: AgentEvent) {
        switch ev {
        case .turnStarted(let role, let agent):
            if role == .main && agent == "main" && !running {
                running = true
                runStarted = Date()
                spinnerVerb = Self.verbs.randomElement()!
            }
        case .textDelta(let agent, let t):
            closeThinking(agent)
            if let i = openText[agent] {
                mutate(agent, i) { k in if case .assistant(let s) = k { k = .assistant(s + t) } }
            } else {
                openText[agent] = append(.assistant(t), to: agent)
            }
        case .thinkingDelta(let agent, let t):
            if let i = openThinking[agent] {
                mutate(agent, i) { k in if case .thinking(let s, let st, let e) = k { k = .thinking(s + t, started: st, ended: e) } }
            } else {
                openText[agent] = nil
                openThinking[agent] = append(.thinking(t, started: Date(), ended: nil), to: agent)
            }
        case .toolStarted(let agent, let id, let name, let input):
            closeThinking(agent)
            openText[agent] = nil
            let i = append(.tool(ToolCallView(id: id, name: name, summary: Self.summary(name, input), input: input)), to: agent)
            toolIndex[id] = (streams[agent] == nil ? "main" : agent, i)
            lastTool[agent] = toolIndex[id]
        case .toolProgress(_, let id, let lines):
            if let (s, i) = toolIndex[id] {
                mutate(s, i) { k in if case .tool(var c) = k { c.live = Array((c.live + lines).suffix(400)); k = .tool(c) } }
            }
        case .toolFinished(_, let id, _, let output, let isError, let receipt):
            if let (s, i) = toolIndex[id] {
                mutate(s, i) { k in
                    if case .tool(var c) = k { c.output = output; c.isError = isError; c.receipt = receipt; c.ended = Date(); k = .tool(c) }
                }
            }
        case .fileChanged(let agent, let path, let diff):
            if !changedFiles.contains(path) { changedFiles.append(path) }
            // Attach the diff to the tool call that made it (inline red/green view).
            if let (s, i) = lastTool[agent] {
                mutate(s, i) { k in if case .tool(var c) = k, c.diff == nil { c.diff = diff; k = .tool(c) } }
            }
            if Self.isFigure(path), let ws = workspace { addFigure(ws.appendingPathComponent(path)) }
        case .assistantMessage(let agent, _):
            openText[agent] = nil
        case .usage(let agent, let m):
            if agent == "main" { meter = m }
        case .integrity(let sigs):
            for s in sigs where s.severity >= 2 { append(.signal(Self.signalTitle(s.kind) + " · " + s.detail), to: "main") }
        case .supervisorStarted:
            break   // the agent card (agentStarted) carries it
        case .supervisorReview(let kind, let verdict, let body):
            append(.review(kind: kind, verdict: verdict, body: body), to: "main")
        case .agentStarted(let id, let role, let parent, let purpose):
            cards[id] = AgentCard(id: id, role: role, parent: parent, purpose: purpose)
            streams[id] = []
            append(.agent(id), to: streams[parent] == nil ? "main" : parent)
        case .agentFinished(let id, _, let result):
            cards[id]?.ended = Date()
            cards[id]?.result = result
        case .literature(let agent, let action, let key, let title, let detail):
            literatureLog.append(LiteratureEvent(agent: agent, action: action, key: key, title: title, detail: detail))
            append(.literature(action: action, key: key, title: title, detail: detail), to: agent)
            if action == .added, let s = bench?.services { library = s.library.records }
        case .committed(let hash, let subject, let files):
            append(.commit(hash: hash, subject: subject, files: files), to: "main")
            Task { await refreshHistory() }
        case .jobOutput(let job, let lines):
            if jobs[job] == nil {
                let label = bench?.services.jobs.all.first { $0.id == job }?.label ?? job
                jobs[job] = JobState(id: job, label: label)
                jobOrder.append(job)
            }
            jobs[job]?.lines = Array(((jobs[job]?.lines ?? []) + lines).suffix(5000))
            if inspectorTab != .jobs { jobs[job]?.unread += lines.count }
        case .jobFinished(let job, let code, let secs):
            jobs[job]?.running = false
            jobs[job]?.exitCode = code
            jobs[job]?.seconds = secs
        case .jobNotification(let n):
            append(.job(n), to: "main")
            if config.notifyJobs {
                let title = n.kind == .failed ? L("Job failed") : n.kind == .stalled ? L("Job stalled") : n.kind == .matched ? L("Job update") : L("Job finished")
                notifier.post(title: "\(title): \(n.job)", body: String(n.text.prefix(200)), id: "job-\(n.job)-\(n.kind.rawValue)-\(Int(n.at.timeIntervalSince1970))")
            }
        case .deliberation(let thread, let from, let to, let kind, let text):
            append(.deliberation(thread: thread, from: from, to: to, kind: kind, text: text), to: "main")
            contested = bench?.services.deliberation.contested ?? []
        case .planChanged(let p): plan = p
        case .claimsChanged(let c): claims = c
        case .notice(let n):
            append(.notice(n), to: "main")
            // Notices arrive localized, so don't match on their text; the contested list is a cheap read.
            contested = bench?.services.deliberation.contested ?? []
        case .error(let e): append(.error(e), to: "main"); lastError = e
        case .turnFinished(let agent, _):
            closeThinking(agent)
            openText[agent] = nil
            if agent == "main" {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    self.turnMaybeEnded()
                }
            }
        case .permissionRequested:
            break
        }
    }
}
