import AppKit
import Foundation
import SieveSciCore
import UniformTypeIdentifiers

/// Conversation actions for the sidebar's context menu (Codex-style): rename, copy id or Markdown,
/// export, fork, reference from the open conversation, show in Finder, delete.
extension AppModel {
    func taskDir(_ id: String) -> URL? { workspace.map { SessionStore.taskDir(id, in: $0) } }

    func renameTask(_ id: String) {
        guard let ws = workspace else { return }
        let a = NSAlert()
        a.messageText = L("Rename conversation")
        let field = NSTextField(string: title(of: id))
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("Rename"))
        a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        SessionStore.setTitle(field.stringValue, task: id, in: ws)
        taskTitles[id] = SessionStore.title(dir: SessionStore.taskDir(id, in: ws))
    }

    func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func taskMarkdown(_ id: String) -> String {
        guard let dir = taskDir(id) else { return "" }
        return "# " + title(of: id) + "\n\n`" + id + "`\n" + SessionStore.markdown(SessionStore.load(dir: dir, agent: "main"))
    }

    func exportTaskMarkdown(_ id: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = title(of: id).replacingOccurrences(of: "/", with: "-").prefix(60) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try taskMarkdown(id).write(to: url, atomically: true, encoding: .utf8) } catch { lastError = error.localizedDescription }
    }

    /// A copy of any conversation (not only the open one) that continues on its own.
    func forkTask(_ id: String) {
        guard let ws = workspace, let src = taskDir(id) else { return }
        if id == taskId { fork(); return }
        let newId = id + "-fork-" + String(UUID().uuidString.prefix(4)).lowercased()
        let dir = SessionStore.taskDir(newId, in: ws)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for m in SessionStore.load(dir: src, agent: "main") { SessionStore.shared.append(m, task: newId, agent: "main", dir: dir) }
        startSession(task: newId)
    }

    /// Puts `@task:<id>` in the composer: the next message carries that conversation's digest.
    func referenceTask(_ id: String) {
        showSettingsPage = false
        mainTab = .chat
        draft = "@task:\(id) "
    }

    func revealTask(_ id: String) {
        guard let dir = taskDir(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    // MARK: Sidebar folders

    /// Whether a sidebar folder lists its conversations: the user's last choice for it, else open only
    /// while it is the open workspace.
    func isFolderOpen(_ path: String) -> Bool { config.folderOpen[path] ?? (path == workspace?.path) }

    /// Expands or collapses a folder's list without switching workspace. Several can be open at once.
    func setFolder(_ path: String, open: Bool) {
        var f = config.folderOpen.filter { config.recentWorkspaces.contains($0.key) }
        f[path] = open
        config.folderOpen = f
        if open, path != workspace?.path { loadFolderTasks(path) }
    }

    /// Reads a folder other than the open workspace: its conversations, newest first, and their titles.
    func loadFolderTasks(_ path: String) {
        if Self.isDemo, folderTasks[path] != nil { return }
        let ws = URL(fileURLWithPath: path)
        let list = SessionStore.tasks(in: ws)
        var t = taskTitles
        for task in list where t[task.id] == nil {
            if let title = SessionStore.title(dir: SessionStore.taskDir(task.id, in: ws)) { t[task.id] = title }
        }
        if t != taskTitles { taskTitles = t }
        let old = folderTasks[path]
        if old?.map(\.id) != list.map(\.id) || old?.map(\.modified) != list.map(\.modified) { folderTasks[path] = list }
    }

    /// Re-reads every expanded folder other than the open workspace.
    func refreshOpenFolders() {
        for p in config.recentWorkspaces where p != workspace?.path && isFolderOpen(p) { loadFolderTasks(p) }
    }

    /// Shows a conversation of another folder in Finder.
    func revealTask(_ id: String, in folder: String) {
        NSWorkspace.shared.activateFileViewerSelecting([SessionStore.taskDir(id, in: URL(fileURLWithPath: folder))])
    }
}
