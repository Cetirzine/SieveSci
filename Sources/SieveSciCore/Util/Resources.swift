import Foundation

/// Locates SieveSci's resource bundle. SwiftPM's generated `Bundle.module` only looks next to the
/// executable's bundle root, which a signed `.app` cannot contain; the app bundles the resources
/// in `Contents/Resources/`. Search there first, then next to the executable, then fall back to
/// `Bundle.module` (development builds and the CLI).
public enum SieveSciResources {
    public static let bundleName = "SieveSci_SieveSciCore.bundle"

    public static let bundle: Bundle = {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            exeDir.appendingPathComponent(bundleName),
            exeDir.deletingLastPathComponent().appendingPathComponent("Resources").appendingPathComponent(bundleName),
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c.path) {
            if let b = Bundle(url: c) { return b }
        }
        return Bundle.module
    }()

    /// A directory inside the bundle, e.g. `Resources/skills`. `url(forResource:withExtension: nil)`
    /// does not find directories with corelibs Foundation (Linux, Windows), so the path is built here.
    public static func directory(_ relative: String) -> URL? {
        let roots = [bundle.resourceURL, bundle.bundleURL, bundle.bundleURL.appendingPathComponent("Contents/Resources")].compactMap { $0 }
        for root in roots {
            let u = root.appendingPathComponent(relative)
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &dir), dir.boolValue { return u }
        }
        return nil
    }
}

/// Canonical filesystem paths for security checks and sandbox rules.
public enum FilePaths {
    /// The real path: symlinks resolved via realpath(3) for the longest existing prefix, the rest
    /// appended. Unlike `URL.resolvingSymlinksInPath()`, it never strips `/private` (which would
    /// make `/private/var/…` and `/var/…` compare unequal, and Seatbelt rules miss).
    public static func canonical(_ path: String) -> String {
        #if os(Windows)
        // No /private aliasing (and no realpath) on Windows; Foundation resolves links itself.
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        #else
        var head = URL(fileURLWithPath: path).standardizedFileURL.path
        var tail: [String] = []
        while !head.isEmpty && head != "/" {
            if let r = realpath(head, nil) {
                defer { free(r) }
                let base = String(cString: r)
                return tail.isEmpty ? base : (base as NSString).appendingPathComponent(tail.reversed().joined(separator: "/"))
            }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
        return "/" + tail.reversed().joined(separator: "/")
        #endif
    }
}
