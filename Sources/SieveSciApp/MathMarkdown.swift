import AppKit
import MarkdownUI
import SwiftMath
import SwiftUI

/// LaTeX in agent replies. MarkdownUI has no math, so formulas are turned into images it already
/// knows how to place: `$$…$$` / `\[…\]` become block images, `$…$` / `\(…\)` inline images, both
/// rendered natively by SwiftMath. Code spans and fenced code are left alone.
enum MathMarkdown {
    static let blockScheme = "sievemath-block", inlineScheme = "sievemath"

    private static let cache = NSCache<NSString, NSString>()

    /// `prepare`, memoised: views redraw often (streaming), the text rarely changes between draws.
    static func prepared(_ text: String) -> String {
        if let hit = cache.object(forKey: text as NSString) { return hit as String }
        let out = prepare(text)
        cache.setObject(out as NSString, forKey: text as NSString)
        return out
    }

    /// Markdown with every formula replaced by a `sievemath:` image reference.
    static func prepare(_ text: String) -> String {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") else { return text }
        // Work on non-code segments only: fenced code and inline code spans pass through untouched.
        return transform(text)
    }

    private static func transform(_ text: String) -> String {
        var result = "", buffer = ""
        var i = text.startIndex
        func flush() { result += replaceMath(buffer); buffer = "" }
        while i < text.endIndex {
            if text[i...].hasPrefix("```") {
                flush()
                let rest = text[text.index(i, offsetBy: 3)...]
                let end = rest.range(of: "```").map { $0.upperBound } ?? text.endIndex
                result += text[i..<end]; i = end; continue
            }
            if text[i] == "`" {
                flush()
                let rest = text[text.index(after: i)...]
                let end = rest.firstIndex(of: "`").map { text.index(after: $0) } ?? text.endIndex
                result += text[i..<end]; i = end; continue
            }
            buffer.append(text[i]); i = text.index(after: i)
        }
        flush()
        return result
    }

    private static func encode(_ latex: String) -> String {
        Data(latex.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ url: URL) -> String? {
        var s = url.absoluteString.components(separatedBy: ":").dropFirst().joined(separator: ":")
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static let display = try! NSRegularExpression(pattern: #"\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]"#)
    private static let inline = try! NSRegularExpression(pattern: #"\\\(([\s\S]+?)\\\)|(?<![\\$\w])\$(?![\s$])([^$\n]+?)(?<!\s)\$(?![\d$])"#)

    static func replaceMath(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var t = sub(display, s) { "\n\n![formula](\(blockScheme):\(encode($0)))\n\n" }
        t = sub(inline, t) { latex in
            // "$5 and $10" is money, not math: require something formula-like.
            latex.range(of: #"[\\^_{}=<>+\-*/]|^[A-Za-z]$|^[A-Za-z]\w*$"#, options: .regularExpression) == nil ? nil : "![formula](\(inlineScheme):\(encode(latex)))"
        }
        return t
    }

    private static func sub(_ re: NSRegularExpression, _ s: String, _ f: (String) -> String?) -> String {
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let g = (1..<m.numberOfRanges).map { m.range(at: $0) }.first { $0.location != NSNotFound }
            guard let g, let rep = f(ns.substring(with: g).trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + rep
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// A template image (tinted by the text colour, so it follows light and dark mode).
    static func render(_ latex: String, size: CGFloat, display: Bool) -> NSImage? {
        var m = MathImage(latex: latex, fontSize: size, textColor: .black, labelMode: display ? .display : .text, textAlignment: .left)
        // SwiftMath sizes the image to the ink's advance; italic glyphs overhang it and get clipped.
        m.contentInsets = NSEdgeInsets(top: 2, left: 1, bottom: 2, right: size * 0.35)
        let (error, image, _) = m.asImage()
        guard error == nil, let image else { return nil }
        image.isTemplate = true
        return image
    }
}

/// Block formulas (and ordinary images, via the default provider).
struct MathImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        if let url, url.scheme == MathMarkdown.blockScheme, let latex = MathMarkdown.decode(url) {
            if let img = MathMarkdown.render(latex, size: 17, display: true) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(nsImage: img).renderingMode(.template).foregroundStyle(.primary)
                        .accessibilityLabel(latex)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
            } else {
                Text(latex).font(Theme.monoSmall).foregroundStyle(.secondary)
            }
        } else {
            DefaultImageProvider.default.makeImage(url: url)
        }
    }
}

/// Inline formulas inside a line of text.
struct MathInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        if url.scheme == MathMarkdown.inlineScheme, let latex = MathMarkdown.decode(url),
           let img = MathMarkdown.render(latex, size: 15, display: false) {
            return Image(nsImage: img).renderingMode(.template)
        }
        return try await DefaultInlineImageProvider.default.image(with: url, label: label)
    }
}

extension View {
    /// Formula support for a `Markdown` view (pair with `MathMarkdown.prepare` on its text).
    func markdownMath() -> some View {
        markdownImageProvider(MathImageProvider()).markdownInlineImageProvider(MathInlineImageProvider())
    }
}
