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
}
