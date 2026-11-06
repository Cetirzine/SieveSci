import Foundation
#if os(Windows)
import WinSDK
#endif

/// The programs SieveSci runs, named per platform. On macOS and Linux these are the usual paths;
/// on Windows, bash is Git for Windows' bash (the agent's commands, skills and hooks are written
/// for bash), Python is the python.org/conda `python.exe`, and a venv keeps its interpreter in
/// `Scripts\`.
public enum Platform {
    #if os(Windows)
    public static let isWindows = true
    #else
    public static let isWindows = false
    #endif

    /// PATH entries are separated by `;` on Windows.
    public static let pathSeparator: Character = isWindows ? ";" : ":"

    /// bash for the `bash` tool, background jobs and setup scripts.
    public static var bash: String {
        #if os(Windows)
        return gitBash ?? "bash"
        #else
        return "/bin/bash"
        #endif
    }

    /// A POSIX shell for hooks and plugin launchers.
    public static var sh: String {
        #if os(Windows)
        return bash
        #else
        return "/bin/sh"
        #endif
    }

    /// The Python interpreter's name or path (`python3` on macOS and Linux).
    public static var python: String {
        #if os(Windows)
        return windowsPython ?? "python"
        #else
        return "python3"
        #endif
    }

    /// Where SieveSci writes diagnostic logs: ~/Library/Logs/SieveSci on macOS,
    /// %LOCALAPPDATA%\SieveSci\Logs on Windows, ~/.sievesci/logs elsewhere.
    public static var logsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent("Library/Logs/SieveSci")
        #elseif os(Windows)
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("AppData/Local")
        return base.appendingPathComponent("SieveSci").appendingPathComponent("Logs")
        #else
        return home.appendingPathComponent(".sievesci/logs")
        #endif
    }

    /// Moves a file or folder to the Trash (macOS), the Recycle Bin (Windows) or the freedesktop
    /// trash (`~/.local/share/Trash`), so a deleted conversation can be restored.
    public static func moveToTrash(_ url: URL) throws {
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #elseif os(Windows)
        // pFrom is a list of paths, each NUL-terminated, the list ending with a second NUL.
        let native = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path   // C:\\…, not /C:/…
        var from = Array(native.utf16) + [0, 0]
        let status: Int32 = from.withUnsafeMutableBufferPointer { buf in
            var op = SHFILEOPSTRUCTW()
            op.wFunc = UINT(FO_DELETE)
            op.pFrom = UnsafePointer(buf.baseAddress)
            op.fFlags = FILEOP_FLAGS(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT)
            return SHFileOperationW(&op)
        }
        guard status == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        #else
        let fm = FileManager.default
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        let trash = base.appendingPathComponent("Trash")
        let files = trash.appendingPathComponent("files"), info = trash.appendingPathComponent("info")
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        try fm.createDirectory(at: info, withIntermediateDirectories: true)
        var name = url.lastPathComponent, n = 1
        while fm.fileExists(atPath: files.appendingPathComponent(name).path) { n += 1; name = "\(url.lastPathComponent).\(n)" }
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate])
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        try "[Trash Info]\nPath=\(path)\nDeletionDate=\(date)\n".writeReliably(to: info.appendingPathComponent(name + ".trashinfo"))
        try fm.moveItem(at: url, to: files.appendingPathComponent(name))
        #endif
    }

    /// A virtual environment's interpreter.
    public static func venvPython(_ dir: URL) -> URL {
        isWindows ? dir.appendingPathComponent("Scripts").appendingPathComponent("python.exe")
                  : dir.appendingPathComponent("bin").appendingPathComponent("python")
    }

    #if os(Windows)
    /// Git for Windows' bash. `C:\Windows\System32\bash.exe` is the WSL launcher, which runs
    /// commands in a different file system, so it is skipped.
    static let gitBash: String? = {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        for root in [env["ProgramFiles"], env["ProgramW6432"], env["ProgramFiles(x86)"], env["LOCALAPPDATA"].map { $0 + "\\Programs" }].compactMap({ $0 }) {
            candidates += [root + "\\Git\\bin\\bash.exe", root + "\\Git\\usr\\bin\\bash.exe"]
        }
        if let onPath = ProcessRunner.which("bash"), !onPath.lowercased().contains("\\system32\\") { candidates.insert(onPath, at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// `python.exe` on PATH, skipping the Microsoft Store stub in `WindowsApps` (it opens the Store
    /// instead of running Python).
    static let windowsPython: String? = {
        for name in ["python", "python3"] {
            for p in ProcessRunner.allOnPath(name) where !p.lowercased().contains("\\windowsapps\\") { return p }
        }
        return nil
    }()
    #endif
}
