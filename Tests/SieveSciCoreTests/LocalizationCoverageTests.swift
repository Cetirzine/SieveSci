import Foundation
import Testing
@testable import SieveSciCore

/// Every user-facing string the core emits goes through L10n and exists in all six languages.
/// Serialized: some tests switch the process-wide UI language.
@Suite(.serialized) struct LocalizationCoverage {
    /// Literal keys passed to `L(…)` and `L10n.s/t(…)` anywhere in SieveSciCore.
    static func coreKeys() throws -> [String] {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SieveSciCore")
        let re = try NSRegularExpression(pattern: #"\bL(?:10n\.[st])?\(\s*"((?:[^"\\]|\\.)*)""#)
        var keys: Set<String> = []
        let files = FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil)
        while let u = files?.nextObject() as? URL {
            guard u.pathExtension == "swift", let s = try? String(contentsOf: u, encoding: .utf8) else { continue }
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range(at: 1), in: s) else { continue }
                let k = String(s[r]).replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\")
                if !k.contains("\\(") { keys.insert(k) }
            }
        }
        return keys.sorted()
    }

    static func placeholders(_ s: String) -> Int {
        (try? NSRegularExpression(pattern: #"%(?:\d+\$)?@|%d"#))?.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) ?? 0
    }

    @Test func everyCoreStringIsTranslated() throws {
        let keys = try Self.coreKeys()
        #expect(keys.count > 150, "the scan should find the core's strings (found \(keys.count))")
        let missingMarker = "\u{1}missing"
        for lang in L10n.Language.allCases where lang != .system && lang != .en {
            let bundle = L10n.bundle(for: lang.rawValue)
            var missing: [String] = []
            for k in keys {
                let v = bundle.localizedString(forKey: k, value: missingMarker, table: nil)
                if v == missingMarker { missing.append(k); continue }
                #expect(Self.placeholders(v) == Self.placeholders(k), "\(lang.rawValue): placeholders differ for “\(k)” → “\(v)”")
            }
            #expect(missing.isEmpty, "\(lang.rawValue) lacks \(missing.count) strings: \(missing.prefix(10))")
        }
    }

    @Test func textSubstitution() {
        #expect(L10n.substitute("%@ of %@", ["a", "b"]) == "a of b")
        #expect(L10n.substitute("%2$@ / %1$@", ["a", "b"]) == "b / a")
        #expect(L10n.substitute("100%% · %@", ["x"]) == "100% · x")
        #expect(L10n.substitute("%@", ["contains %@ literally"]) == "contains %@ literally", "arguments are never re-expanded")
        #expect(L10n.substitute("%@ %@", ["only one"]) == "only one ")
    }

    @Test func noticesFollowTheUILanguage() {
        let saved = L10n.language
        defer { L10n.language = saved }
        L10n.language = .zhHans
        #expect(L("Interrupted.") == "已中断。")
        #expect(L10n.s("Context compacted (%@).", L("on request")) == "已压缩上下文（按请求）。")
        L10n.language = .en
        #expect(L10n.s("Context compacted (%@).", L("on request")) == "Context compacted (on request).")
        #expect(L("active") == "active", "English never shows a raw key")
    }

    @Test func permissionPromptsAreLocalized() {
        let saved = L10n.language
        defer { L10n.language = saved }
        let input: JSON = ["mode": "map", "items": ["a", "b"], "instructions": "screen"]
        for lang in L10n.Language.allCases where lang != .system && lang != .en {
            L10n.language = lang
            let text = PermissionPolicy.summary("dispatch", input)
            #expect(!text.hasPrefix("map batch of"), "\(lang.rawValue): \(text)")
            #expect(text.contains("2") && text.contains("screen"), "\(lang.rawValue): \(text)")
        }
    }
}
