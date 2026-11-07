import Foundation

/// UI localization: English, 简体中文, 正體中文, Русский, Español, Français.
///
/// Keys are the English strings (so a missing translation falls back to readable English). The
/// language follows the system unless the user picks one in Settings → General; the choice takes
/// effect immediately (strings are looked up per call, not cached at launch). Agents keep replying
/// in the language the user writes in; the UI language is also passed to them as a hint in the
/// per-turn context, so the frozen system prompts (and their caches) are unaffected.
public enum L10n {
    public enum Language: String, CaseIterable, Codable, Sendable, Identifiable {
        case system
        case en
        case zhHans = "zh-Hans"
        case zhHant = "zh-Hant"
        case ru, es, fr

        public var id: String { rawValue }
        /// Native names, shown in the picker regardless of the current language.
        public var nativeName: String {
            switch self {
            case .system: return L10n.t("System")
            case .en: return "English"
            case .zhHans: return "简体中文"
            case .zhHant: return "正體中文"
            case .ru: return "Русский"
            case .es: return "Español"
            case .fr: return "Français"
            }
        }
    }

    static let defaultsKey = "SieveSciLanguage"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bundle] = [:]

    /// The user's choice (persisted in UserDefaults; shared by the app and the CLI).
    public static var language: Language {
        get { Language(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// The app's own defaults domain, whichever process asks: the SwiftUI app (its standard domain),
    /// the engine inside the desktop app, or the CLI in a terminal (which would otherwise each get one
    /// named after their executable). A suite named after the running app itself is not allowed, hence
    /// the check.
    /// A separate profile (`SIEVESCI_CONFIG_DIR`) and test runs keep their own domain, so they never
    /// change the app's.
    static var defaults: UserDefaults {
        #if os(macOS)
        let p = ProcessInfo.processInfo
        let isolated = p.environment["SIEVESCI_CONFIG_DIR"] != nil || p.arguments.contains { $0.contains(".xctest") }
        if !isolated, Bundle.main.bundleIdentifier != suite, let d = UserDefaults(suiteName: suite) { return d }
        #endif
        return .standard
    }
    static let suite = "app.sievesci.SieveSci"

    /// What "follow the system" means, as the front end resolved it (its web view reads the user's
    /// languages reliably; Windows' locale API can report English under a Chinese interface, which left
    /// the engine's notices and statuses in English).
    nonisolated(unsafe) public static var systemLanguage: String?

    /// The concrete language in effect, e.g. "zh-Hans".
    public static var resolved: String {
        if language != .system { return language.rawValue }
        let available = Language.allCases.filter { $0 != .system }.map(\.rawValue)
        if let s = systemLanguage, available.contains(s) { return s }
        return Bundle.preferredLocalizations(from: available, forPreferences: Locale.preferredLanguages).first ?? "en"
    }

    static func bundle(for code: String) -> Bundle {
        lock.lock(); defer { lock.unlock() }
        if let b = cache[code] { return b }
        let candidates = [code, code.lowercased(), code.replacingOccurrences(of: "-", with: "_")]
        let b = candidates.lazy.compactMap { SieveSciResources.bundle.path(forResource: $0, ofType: "lproj") }.first.flatMap(Bundle.init(path:)) ?? SieveSciResources.bundle
        cache[code] = b
        return b
    }

    /// Localized string for an English key.
    public static func t(_ key: String) -> String {
        let code = resolved
        if code == "en" { return key }
        return bundle(for: code).localizedString(forKey: key, value: key, table: nil)
    }

    /// Localized format string (keys use %@ / %d placeholders).
    public static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale(identifier: resolved), arguments: args)
    }

    /// Localized string with text arguments: `%@` takes the next argument, `%1$@` a given one (so a
    /// translation can reorder them). Pure string substitution — no CVarArg, so it behaves the same
    /// on Linux — and an argument containing `%@` is never re-expanded.
    public static func s(_ key: String, _ args: String...) -> String { substitute(t(key), args) }

    static func substitute(_ format: String, _ args: [String]) -> String {
        var out = ""
        var next = 0
        var i = format.startIndex
        while i < format.endIndex {
            let c = format[i]
            guard c == "%" else { out.append(c); i = format.index(after: i); continue }
            let rest = format[format.index(after: i)...]
            if rest.hasPrefix("@") {
                out += next < args.count ? args[next] : ""
                next += 1
                i = format.index(i, offsetBy: 2)
            } else if rest.hasPrefix("%") {
                out.append("%")
                i = format.index(i, offsetBy: 2)
            } else if let digitsEnd = rest.firstIndex(where: { !$0.isASCII || !$0.isNumber }), digitsEnd > rest.startIndex,
                      format[digitsEnd...].hasPrefix("$@"), let n = Int(rest[rest.startIndex..<digitsEnd]) {
                out += n >= 1 && n <= args.count ? args[n - 1] : ""
                i = format.index(digitsEnd, offsetBy: 2)
            } else {
                out.append(c)
                i = format.index(after: i)
            }
        }
        return out
    }
}

/// Shorthand used throughout the UI.
public func L(_ key: String) -> String { L10n.t(key) }
