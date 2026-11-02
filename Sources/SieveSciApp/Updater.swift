import AppKit
import SieveSciCore
import SwiftUI

/// Updates from GitHub releases. Checks quietly on launch and once a day; when a newer release exists it
/// downloads the disk image, checks it against the SHA-256 GitHub published, unpacks the app next to the
/// download and waits. The new bundle replaces this one when the user restarts from the banner, or on
/// quit. Manual checks ("Check for Updates…") answer with a dialog either way.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(AppRelease, Double)
        case ready(AppRelease)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "updates.lastCheck") as? Date
    /// "Later" on the sidebar banner: hidden until the next launch or the next release.
    @Published var bannerDismissed = false
    /// The user asked for this download (not a silent background one), so its progress is shown.
    @Published private(set) var userWaiting = false

    var autoCheck = true
    /// Download in the background and install on quit (or from the banner).
    var autoInstall = true
    /// Asked before restarting into the update: is a turn running?
    var isBusy: () -> Bool = { false }
    var notify: (_ title: String, _ body: String) -> Void = { _, _ in }

    private var staged: URL?
    private var downloaded: URL?
    private var helperLaunched = false
    private var loop: Task<Void, Never>?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? SieveSci.version
    }

    /// Where the running app lives, when it can be replaced in place (a bundle in a writable folder; not
    /// running from the disk image or from App Translocation's read-only copy).
    static var installTarget: URL? {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return nil }
        let parent = app.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent), !parent.contains("/AppTranslocation/") else { return nil }
        return app
    }

    static var workDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SieveSci/Updates", isDirectory: true)
    }

    var pending: AppRelease? {
        switch state {
        case .available(let r), .ready(let r), .downloading(let r, _): return r
        default: return nil
        }
    }

    // MARK: Checking

    /// Background checks: shortly after launch, then daily.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while !Task.isCancelled {
                if let self, self.autoCheck { await self.check(manual: false) }
                try? await Task.sleep(nanoseconds: 24 * 3600 * 1_000_000_000)
            }
        }
    }

    func check(manual: Bool) async {
        switch state {
        case .checking, .downloading, .installing: return
        case .ready(let r):
            if manual { confirmInstall(r) }
            return
        default: break
        }
        state = .checking
        do {
            let r = try await Updates.latest()
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: "updates.lastCheck")
            guard Updates.isNewer(r.version, than: Self.currentVersion) else {
                state = .upToDate
                if manual { inform(L("SieveSci is up to date"), L("You have the latest version") + " (\(Self.currentVersion)).") }
                return
            }
            state = .available(r)
            if manual {
                offer(r)
            } else if autoInstall, r.asset != nil {
                await fetch(r)
            }
        } catch {
            let message = error.localizedDescription
            state = manual ? .failed(message) : .idle
            if manual { inform(L("Couldn't check for updates"), message, style: .warning) }
        }
    }

    // MARK: Downloading

    func fetch(_ r: AppRelease, thenInstall: Bool = false) async {
        guard let asset = r.asset else { NSWorkspace.shared.open(r.page); return }
        if case .downloading = state { return }
        userWaiting = thenInstall
        bannerDismissed = false
        defer { userWaiting = false }
        state = .downloading(r, 0)
        let dir = Self.workDir.appendingPathComponent(r.version, isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(asset.name)
            try await Downloader.fetch(asset.url, to: file) { [weak self] p in
                Task { @MainActor in
                    if case .downloading(let cur, _) = self?.state, cur == r { self?.state = .downloading(r, p) }
                }
            }
            downloaded = file
            let app = try await Task.detached { () throws -> URL in
                try Updates.verify(file, against: asset)
                return try Self.stage(file, in: dir, expecting: r.version)
            }.value
            staged = app
            state = .ready(r)
            bannerDismissed = false
            // SIEVESCI_UPDATE_SELFTEST=1 with a SIEVESCI_UPDATE_FEED: restart into the update unattended
            // (end-to-end check of download → verify → swap → relaunch against a local feed).
            let env = ProcessInfo.processInfo.environment
            if thenInstall || (env["SIEVESCI_UPDATE_SELFTEST"] == "1" && env["SIEVESCI_UPDATE_FEED"] != nil) {
                installAndRelaunch()
            } else {
                notify(L("Update ready"), "SieveSci \(r.version) · " + L("Restart to update, or it installs when you quit."))
            }
        } catch {
            state = .failed(error.localizedDescription)
            if thenInstall { inform(L("The update couldn't be downloaded"), error.localizedDescription, style: .warning) }
        }
    }

    /// Unpacks the downloaded disk image or zip and checks the app inside: same bundle id, the release's
    /// version, an intact code signature.
    nonisolated static func stage(_ file: URL, in dir: URL, expecting version: String) throws -> URL {
        let out = dir.appendingPathComponent("staged", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if file.pathExtension.lowercased() == "dmg" {
            let mount = dir.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try run("/usr/bin/hdiutil", ["attach", file.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            guard let app = firstApp(in: mount) else { throw UpdateError(L("The disk image contains no app.")) }
            try run("/usr/bin/ditto", [app.path, out.appendingPathComponent(app.lastPathComponent).path])
        } else {
            try run("/usr/bin/ditto", ["-x", "-k", file.path, out.path])
        }
        guard let app = firstApp(in: out), let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError(L("The download contains no app."))
        }
        let ownId = Bundle.main.bundleIdentifier ?? "app.sievesci.SieveSci"
        guard info["CFBundleIdentifier"] as? String == ownId else { throw UpdateError(L("The download is not SieveSci.")) }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError(L("The download's version doesn't match the release.") + " (\(info["CFBundleShortVersionString"] ?? "?") ≠ \(version))")
        }
        do { try run("/usr/bin/codesign", ["--verify", "--deep", app.path]) } catch {
            throw UpdateError(L("The downloaded app's signature is broken."))
        }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    nonisolated private static func firstApp(in dir: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "app" }
    }

    @discardableResult
    nonisolated static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError("\((exe as NSString).lastPathComponent): \(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))")
        }
        return out
    }

    // MARK: Installing

    /// Quits, swaps in the staged bundle and opens it again. Without a replaceable install (running from the
    /// disk image, a read-only folder) the disk image is opened for a manual drag instead.
    func installAndRelaunch() {
        guard case .ready(let r) = state, let app = staged else { return }
        guard let target = Self.installTarget else {
            if let downloaded { NSWorkspace.shared.open(downloaded) }
            inform(L("Install the update by hand"),
                   L("SieveSci can't replace itself where it is now. Drag SieveSci from the opened disk image into Applications, replacing the old copy.") + " (\(r.version))")
            return
        }
        if isBusy() {
            let a = NSAlert()
            a.messageText = L("Restart to update now?")
            a.informativeText = L("A task is still running. It stops now and can be resumed after the restart.")
            a.addButton(withTitle: L("Restart"))
            a.addButton(withTitle: L("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try launchHelper(target: target, staged: app, relaunch: true)
            state = .installing
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
            inform(L("The update couldn't be installed"), error.localizedDescription, style: .warning)
        }
    }

    /// From `applicationWillTerminate`: a downloaded update goes in as the app quits (not reopened).
    func installOnQuit() {
        guard autoInstall, case .ready = state, let app = staged, let target = Self.installTarget else { return }
        try? launchHelper(target: target, staged: app, relaunch: false)
    }

    /// A detached shell script waits for this process to exit, moves the old bundle aside, copies the new
    /// one in (restoring the old one if that fails) and optionally reopens it. Log: Updates/install.log.
    private func launchHelper(target: URL, staged: URL, relaunch: Bool) throws {
        guard !helperLaunched else { return }
        let script = Self.workDir.appendingPathComponent("install.sh")
        try """
        #!/bin/sh
        pid="$1"; target="$2"; new="$3"; relaunch="$4"
        echo "$(date) installing $new over $target"
        i=0
        while kill -0 "$pid" 2>/dev/null; do
          sleep 0.2; i=$((i+1))
          [ "$i" -gt 600 ] && { echo "SieveSci did not quit; update skipped"; exit 1; }
        done
        backup="$target.updating"
        rm -rf "$backup"
        mv "$target" "$backup" || { echo "could not move the old app aside"; exit 1; }
        if /usr/bin/ditto "$new" "$target"; then
          rm -rf "$backup"; echo "installed"
        else
          rm -rf "$target"; mv "$backup" "$target"; echo "copy failed; old app restored"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target" >/dev/null 2>&1
        [ "$relaunch" = 1 ] && /usr/bin/open "$target"
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        let log = Self.workDir.appendingPathComponent("install.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/sh", script.path, String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path, relaunch ? "1" : "0"]
        let h = try FileHandle(forWritingTo: log)
        h.seekToEndOfFile()
        p.standardOutput = h
        p.standardError = h
        p.standardInput = FileHandle.nullDevice
        try p.run()
        helperLaunched = true
    }

    // MARK: Dialogs

    private func offer(_ r: AppRelease) {
        let a = NSAlert()
        a.messageText = L("SieveSci %@ is available").replacingOccurrences(of: "%@", with: r.version)
        a.informativeText = L("You have") + " \(Self.currentVersion).\n\n" + Self.excerpt(r.notes)
        a.addButton(withTitle: r.asset == nil ? L("Open Release Page") : L("Install and Restart"))
        a.addButton(withTitle: L("Release Notes"))
        a.addButton(withTitle: L("Later"))
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if r.asset == nil { NSWorkspace.shared.open(r.page) } else { Task { await fetch(r, thenInstall: true) } }
        case .alertSecondButtonReturn: NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    private func confirmInstall(_ r: AppRelease) {
        let a = NSAlert()
        a.messageText = L("SieveSci %@ is ready to install").replacingOccurrences(of: "%@", with: r.version)
        a.informativeText = Self.excerpt(r.notes)
        a.addButton(withTitle: L("Restart to Update"))
        a.addButton(withTitle: L("Later"))
        if a.runModal() == .alertFirstButtonReturn { installAndRelaunch() }
    }

    private func inform(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// The first lines of the release notes, without Markdown markers.
    static func excerpt(_ notes: String, lines: Int = 8) -> String {
        let kept = notes.split(separator: "\n", omittingEmptySubsequences: true)
            .prefix { $0.trimmingCharacters(in: .whitespaces) != "---" }
            .prefix(lines)
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) }
        return kept.joined(separator: "\n")
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A file download with progress, on its own session so the delegate sees every byte.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moved: Error??

    private init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let d = Downloader(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("SieveSci/\(SieveSci.version)", forHTTPHeaderField: "User-Agent")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            d.continuation = c
            session.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone once this returns, so it moves now; the outcome is reported on completion.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            moved = .some(Updates.Failure.http(http.statusCode))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            moved = .some(nil)
        } catch {
            moved = .some(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error) }
        else if case .some(.some(let e)) = moved { continuation?.resume(throwing: e) }
        else if moved == nil { continuation?.resume(throwing: UpdateError(L("The download did not finish."))) }
        else { continuation?.resume() }
        continuation = nil
    }
}

// MARK: - Views

/// Sidebar notice for an update: once it is downloaded, or while one the user asked for downloads, or
/// when one is found and automatic install is off. Dashed frame and an accent tab: it waits on a
/// decision, like everything else in the sidebar that does. Background downloads stay silent.
struct UpdateBanner: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        if !updater.bannerDismissed, let r = shown {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(title(r)).font(Theme.body.weight(.semibold))
                Text("\(Updater.currentVersion) → \(r.version)")
                    .font(Theme.monoTiny).foregroundStyle(.secondary)
                if case .downloading(_, let p) = updater.state {
                    HStack(spacing: Theme.Space.s) {
                        DotProgress(value: p)
                        Text("\(Int(p * 100))%").font(Theme.monoTiny).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    Text(ready ? L("Restart to update, or it installs when you quit.") : L("Download it and restart to update."))
                        .font(Theme.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    EqualWidthHStack(spacing: Theme.Space.s) {
                        Button(ready ? L("Restart") : L("Install")) {
                            if ready { updater.installAndRelaunch() } else { Task { await updater.fetch(r, thenInstall: true) } }
                        }
                        .buttonStyle(.action(.primary))
                        Button(L("Later")) { withAnimation(Theme.Motion.settle) { updater.bannerDismissed = true } }
                            .buttonStyle(.action)
                    }
                    .environment(\.actionButtonFills, true)
                }
            }
            .box(provisional: true, tab: L("Update"), tabTint: Theme.accent)
            .appearPop()
        }
    }

    private var ready: Bool { if case .ready = updater.state { return true }; return false }
    private func title(_ r: AppRelease) -> String {
        let key = ready ? "SieveSci %@ is ready" : updater.state.isDownloading ? "Downloading SieveSci %@" : "SieveSci %@ is available"
        return L(key).replacingOccurrences(of: "%@", with: r.version)
    }
    private var shown: AppRelease? {
        switch updater.state {
        case .ready(let r): return r
        case .downloading(let r, _) where updater.userWaiting: return r
        case .available(let r) where !updater.autoInstall && r.asset != nil: return r
        default: return nil
        }
    }
}

extension Updater.State {
    var isDownloading: Bool { if case .downloading = self { return true }; return false }
}

/// Settings → General → Updates.
struct UpdateSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var updater = Updater.shared

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    Text(L("Installed version"))
                    Text(Updater.currentVersion).font(Theme.monoSmall).foregroundStyle(.secondary)
                }
                if !status.isEmpty {
                    HStack(spacing: Theme.Space.s) {
                        switch updater.state {
                        case .downloading(_, let p): DotProgress(value: p, count: 16)
                        case .checking, .installing: DotActivity(size: 3, dot: 2.5, gap: 1.5)
                        default: EmptyView()
                        }
                        Text(status)
                            .font(Theme.monoTiny)
                            .foregroundStyle(isFailure ? Theme.bad : .secondary)
                            .monospacedDigit()
                            .lineLimit(2)
                    }
                }
            }
            Spacer(minLength: Theme.Space.m)
            Button(buttonTitle, action: primary)
                .buttonStyle(.column(primaryKind))
                .disabled(busy)
        }
        Toggle(L("Check for updates automatically"), isOn: $model.config.autoCheckUpdates)
        Toggle(L("Download updates automatically and install them when SieveSci quits"), isOn: $model.config.autoInstallUpdates)
            .disabled(!model.config.autoCheckUpdates)
        Text(L("Releases come from github.com/Cetirzine/SieveSci; each download is checked against the SHA-256 GitHub publishes for it."))
            .font(.caption).foregroundStyle(.secondary)
    }

    private var busy: Bool {
        switch updater.state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var isFailure: Bool { if case .failed = updater.state { return true }; return false }

    /// The button turns primary once there is something to install.
    private var primaryKind: ActionButtonStyle.Kind {
        switch updater.state {
        case .ready: return .primary
        case .available(let r) where r.asset != nil: return .primary
        default: return .secondary
        }
    }

    private var buttonTitle: String {
        switch updater.state {
        case .ready: return L("Restart")
        case .available(let r) where r.asset != nil: return L("Install")
        default: return L("Check now")
        }
    }

    private func primary() {
        switch updater.state {
        case .ready: updater.installAndRelaunch()
        case .available(let r) where r.asset != nil: Task { await updater.fetch(r, thenInstall: true) }
        default: Task { await updater.check(manual: true) }
        }
    }

    private var status: String {
        switch updater.state {
        case .checking: return L("Checking…")
        case .downloading(let r, let p): return L("Downloading") + " \(r.version) · \(Int(p * 100))%"
        case .ready(let r): return L("SieveSci %@ is ready").replacingOccurrences(of: "%@", with: r.version)
        case .available(let r): return L("SieveSci %@ is available").replacingOccurrences(of: "%@", with: r.version)
        case .installing: return L("Installing…")
        case .failed(let m): return m
        case .upToDate, .idle:
            guard let d = updater.lastCheck else { return "" }
            return L("Last checked") + " " + d.formatted(.relative(presentation: .named))
        }
    }
}
