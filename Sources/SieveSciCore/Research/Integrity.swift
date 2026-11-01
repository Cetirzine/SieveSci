import Foundation

/// A deterministic integrity signal. Signals cost no tokens; they decide *when* the (token-costing)
/// checker agent is dispatched, and they are what the checker is asked to rule on.
public struct IntegritySignal: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case codeHack          // test tampering, swallowed errors, hard-coded results, seed fishing…
        case falseCompletion   // "done/passed/works" while the last relevant receipt failed or none exists
        case ignoredError      // a failed tool call followed by a success narrative
        case scopeShrink       // "for simplicity I'll just…", silently dropping plan steps
        case syntheticData     // generated/mock data used where real data exists, not labelled
        case ungrounded        // conclusions without search/literature receipts; fabricated citation/number
        case harking           // criteria changed after results
        case breakthrough      // strong-claim language → independent verification
        case checkpoint        // plan checkpoint reached
    }
    public var kind: Kind
    public var severity: Int           // 1 info, 2 warn, 3 high
    public var detail: String
    public var location: String?       // file:line or receipt id
}

/// Static scan of code the agent writes or executes. Patterns are deliberately conservative and
/// language-aware enough for Python, R and shell, the bulk of bio/chem analysis code.
public enum HackDetector {
    /// A rule runs on one line at a time; a rule that spans lines (`window` > 0) runs only on the
    /// `window` lines that start at a line containing `trigger`. Every match is bounded by a short
    /// input, so a long script can no longer make a pattern backtrack for minutes.
    struct Rule {
        let kind: IntegritySignal.Kind; let severity: Int; let pattern: String; let message: String
        var window = 0; var trigger = ""
    }

    static let rules: [Rule] = [
        Rule(kind: .codeHack, severity: 3, pattern: #"(?m)^\s*except(\s+(Base)?Exception)?\s*(as\s+\w+)?\s*:\s*(pass|continue|return\s+None)?\s*$\n?\s*(pass|continue)\b"#,
             message: "exception swallowed (except: pass) — errors would be hidden", window: 2, trigger: "except"),
        Rule(kind: .codeHack, severity: 3, pattern: #"(?m)^\s*except\s*:\s*pass"#, message: "bare except: pass"),
        Rule(kind: .codeHack, severity: 3, pattern: #"tryCatch\([\s\S]{0,400}?error\s*=\s*function\(\s*\w*\s*\)\s*\{?\s*(NULL|NA|invisible\(NULL\))"#,
             message: "R tryCatch returns NULL on error — failure would be silent", window: 12, trigger: "tryCatch"),
        Rule(kind: .codeHack, severity: 3, pattern: #"(?i)(@pytest\.mark\.skip|pytest\.skip\(|@unittest\.skip|\bxfail\b|testthat::skip\(|skip_on_cran)"#,
             message: "test skipped"),
        Rule(kind: .codeHack, severity: 3, pattern: #"(?m)^\s*assert\s+(True|1)\b"#, message: "vacuous assertion"),
        Rule(kind: .codeHack, severity: 3, pattern: #"(?i)\b(p_?val(ue)?|pvalue|padj|fdr|q_?value)\s*(=|<-)\s*0?\.\d+\s*(#.*)?$"#,
             message: "p-value assigned a literal instead of computed"),
        Rule(kind: .codeHack, severity: 3, pattern: #"(?i)["'](p_?val(ue)?|pvalue|padj|fdr|q_?value)["']\s*:\s*0?\.\d+"#,
             message: "p-value assigned a literal instead of computed (in a dict)"),
        Rule(kind: .codeHack, severity: 2, pattern: #"(?i)\b(accuracy|auc|r2|r_squared|f1|ic50|kd|fold_change|log2fc)\s*(=|<-)\s*-?\d+(\.\d+)?\s*(#.*)?$"#,
             message: "result metric assigned a literal"),
        Rule(kind: .codeHack, severity: 3, pattern: #"(?i)for\s+\w*seed\w*\s+in\s+range\("#, message: "loop over random seeds (seed fishing?) — report all seeds, not the best"),
        Rule(kind: .codeHack, severity: 3, pattern: #"for[ \t]+(\w+)[ \t]+in[ \t][^\n]*:[ \t]*\n(?:[ \t][^\n]*\n){0,6}?[ \t][^\n]*?(\.seed\([ \t]*\1[ \t]*\)|random_state[ \t]*=[ \t]*\1\b|default_rng\([ \t]*\1[ \t]*\))"#,
             message: "loop over random seeds (seed fishing?) — report all seeds, not the best", window: 8, trigger: "for"),
        Rule(kind: .codeHack, severity: 3, pattern: #"for\s*\(\s*(\w+)\s+in\s+[^)]*\)\s*\{[^}]*set\.seed\(\s*\1\s*\)"#,
             message: "loop over random seeds (seed fishing?) — report all seeds, not the best", window: 12, trigger: "for"),
        Rule(kind: .codeHack, severity: 3, pattern: #"(?i)^\s*\w*seed\w*\s*(\+=\s*1|<-\s*\w*seed\w*\s*\+\s*1)\s*$"#,
             message: "random seed incremented in a loop (retrying seeds until a result appears?)"),
        Rule(kind: .codeHack, severity: 2, pattern: #"\|\|\s*true\b"#, message: "shell failure masked with `|| true`"),
        Rule(kind: .codeHack, severity: 2, pattern: #"(?i)warnings\.(filterwarnings|simplefilter)\(\s*['"]ignore['"]\s*\)"#, message: "all warnings silenced"),
        Rule(kind: .codeHack, severity: 2, pattern: #"(?i)\b(TODO|FIXME|placeholder|dummy result|fake result|hardcoded)\b"#, message: "placeholder left in analysis code"),
        Rule(kind: .syntheticData, severity: 2, pattern: Self.syntheticPattern, message: Self.syntheticMessage),
        Rule(kind: .codeHack, severity: 2, pattern: #"(?i)(mock|fake|stub)_?(data|result|response)"#, message: "mock data/results in analysis code"),
    ]

    static let syntheticPattern = #"(?i)(np\.random\.(rand|randn|normal|uniform|randint)|\b(rng|gen|generator)\w*\.(normal|uniform|integers|standard_normal|lognormal|poisson|binomial|exponential)\(|default_rng\([^)]*\)\.(normal|uniform|integers|standard_normal)\(|torch\.(randn|rand)\(|rnorm\(|runif\(|make_classification|make_blobs|sample\(\s*1e?\d)"#
    static let syntheticMessage = "random/synthetic data generated — must be labelled a simulation, never substituted for measured data"

    /// A simulation the code itself labels as one (power analysis, "simulated" comment) and does not
    /// save as a data file is not synthetic data passed off as measured. Saved output is still flagged,
    /// whatever the comment says.
    static func isLabelledUnsavedSimulation(_ code: String) -> Bool {
        // Comment lines only, one at a time (a whole-file `^\s*#` spans blank lines and went quadratic).
        let labelled = code.split(separator: "\n").contains { l in
            let t = l.drop { $0 == " " || $0 == "\t" }
            return t.first == "#" && t.count < 2000
                && t.range(of: #"(?i)\b(simulat\w*|synthetic|power (analysis|calculation)|toy (data|example))\b"#, options: .regularExpression) != nil
        }
        let saved = code.range(of: #"(?i)(\.to_(csv|parquet|excel|feather|hdf|pickle)\(|np\.save|savetxt|write\.(csv|table|delim)|write_(csv|tsv)|saveRDS|fwrite\()"#, options: .regularExpression) != nil
        return labelled && !saved
    }

    static let compiled: [(Rule, NSRegularExpression)] = rules.compactMap { r in
        (try? NSRegularExpression(pattern: r.pattern, options: [.anchorsMatchLines])).map { (r, $0) }
    }

    public static func scan(code: String, location: String? = nil) -> [IntegritySignal] {
        var out: [IntegritySignal] = []
        let labelledSimulation = isLabelledUnsavedSimulation(code)
        // Lines past 2000 characters are data (inline arrays, base64), not code worth checking.
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map { $0.count > 2000 ? "" : String($0) }
        for (r, re) in compiled where !(r.kind == .syntheticData && labelledSimulation) {
            var first: Int?, count = 0
            if r.window > 0 {
                for (i, line) in lines.enumerated() where line.contains(r.trigger) {
                    let text = lines[i..<min(lines.count, i + r.window)].joined(separator: "\n") + "\n"
                    if re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                        count += 1
                        if first == nil { first = i + 1 }
                    }
                }
            } else {
                // Single-line rules run on chunks of 64 lines: few calls, and each input stays small.
                for start in stride(from: 0, to: lines.count, by: 64) {
                    let text = lines[start..<min(lines.count, start + 64)].joined(separator: "\n")
                    let ms = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    guard let m = ms.first else { continue }
                    count += ms.count
                    if first == nil {
                        let ns = text as NSString
                        first = start + ns.substring(to: m.range.location).filter { $0 == "\n" }.count + 1
                    }
                }
            }
            guard let line = first else { continue }
            out.append(IntegritySignal(kind: r.kind, severity: r.severity, detail: r.message + (count > 1 ? " (×\(count))" : ""),
                                       location: location.map { "\($0):\(line)" } ?? "line \(line)"))
        }
        // Multiple hypothesis tests without correction.
        let tests = (try? NSRegularExpression(pattern: #"(?i)(ttest_ind|ttest_rel|mannwhitneyu|wilcox(on)?\.test|t\.test\(|cor\.test\(|chisq\.test\(|fisher\.test\(|chi2_contingency|fisher_exact|pearsonr|spearmanr)"#))?
            .numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code)) ?? 0
        let corrected = code.range(of: #"(?i)(multipletests|p\.adjust|fdrcorrection|bonferroni|benjamini|holm)"#, options: .regularExpression) != nil
        let testCall = #"(ttest|mannwhitneyu|pearsonr|spearmanr|wilcoxon|chi2_contingency|fisher_exact|t\.test|wilcox\.test|cor\.test|chisq\.test|fisher\.test)"#
        let looped = tests > 0 && Self.testInLoop(code, testCall: testCall)
        if (tests >= 3 || looped) && !corrected {
            out.append(IntegritySignal(kind: .codeHack, severity: 2, detail: "multiple statistical tests without multiple-comparison correction", location: location))
        }
        return out
    }

    /// A statistical test inside a loop: a Python `for` body (not `for _ in range(n)`, which repeats one
    /// test), a comprehension, R `*apply` / purrr `map`, or an R `for (…)`. Line by line, so it stays
    /// linear: the former multi-line regexes backtracked for minutes on long scripts.
    static func testInLoop(_ code: String, testCall: String) -> Bool {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func indent(_ l: String) -> Int { l.prefix { $0 == " " || $0 == "\t" }.count }
        func has(_ l: String, _ re: String) -> Bool { l.range(of: re, options: .regularExpression) != nil }
        let call = "(?i)" + testCall
        for (i, line) in lines.enumerated() where line.count < 5000 && has(line, call) {
            if has(line, call + #"[^\n]*\bfor\s+\w+\s+in\b"#) { return true }                       // comprehension
            if has(line, #"(?i)\b((s|l|v|m)?apply|map(_dbl|_df|_dfr)?)\("#) { return true }             // R apply / purrr
            let mine = indent(line)
            for j in stride(from: i - 1, through: max(0, i - 6), by: -1) {
                let prev = lines[j]
                guard prev.count < 5000, !prev.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                if has(prev, #"(?i)\bfor\s*\("#) && i - j <= 2 { return true }                          // R for loop
                if indent(prev) < mine, has(prev, #"^\s*for\s+(?!_\s)\S[^\n]*\s+in\s+[^\n]*:\s*(#.*)?$"#) { return true }
                if indent(prev) < mine && !has(prev, #"^\s*(for|if|elif|else|with|try|except|while)\b"#) { break } // left the block
            }
        }
        return false
    }

    /// Edits to test files or expected-output fixtures while the task is not about tests.
    public static func isTestTampering(path: String) -> Bool {
        let p = path.lowercased()
        return p.contains("/tests/") || p.contains("/test/") || p.hasPrefix("tests/") || p.hasPrefix("test/")
            || (p as NSString).lastPathComponent.hasPrefix("test_") || p.hasSuffix("_test.py") || p.contains("expected_output")
            || p.contains("/fixtures/") || p.hasSuffix(".snap")
    }
}

/// Reads the assistant's own narrative against the receipts.
public enum NarrativeDetector {
    // `\b` never matches between CJK characters, so the Chinese words stand outside the word-bounded group.
    static let completionWords = #"(?i)\b(all (tests )?pass(ed|es)?|successfully|works (now|correctly)|completed?|done|fixed|verified|confirmed)\b|成功|已完成|完成了|通过了|已验证"#
    static let scopeShrink = #"(?i)(for simplicity|to keep (it|things) simple|simplif(y|ied) (the|this) (analysis|approach)|instead of the full|skip(ping)? (this|the) step|as a (quick )?placeholder|rough approximation|we('ll| will) assume|为简化|简单起见|暂时跳过|先假设|近似处理)"#
    static let breakthrough = #"(?i)\b(breakthrough|novel (finding|mechanism|target)|first (ever|to show|demonstration)|paradigm|unprecedented|significantly (outperform|improv)|strong(ly)? (evidence|support)|prove[sdn]?\b|definitive(ly)?)|突破|首次|重大发现|显著(提升|改善|优于)|证明了|颠覆"#

    /// Strong-claim wording that is the agent's own: sentences that cite a source ([@key], DOI, PMID,
    /// "et al.", a receipt id) report published or retrieved results and do not need blind verification.
    static func ownStrongClaim(_ text: String) -> Bool {
        let cited = #"\[@[^\]]+\]|\b10\.\d{4,9}/\S+|(?i)\bPMID:?\s*\d+|\bet al\.?|\[r\d+(?:[,，]\s*r?\d+)*\]|等人?\s*[（(]?\s*(19|20)\d{2}"#
        // Sentence ends: . ! ? ; followed by whitespace (so DOIs and decimals stay whole), CJK stops, newlines.
        let sentences = text.replacingOccurrences(of: "(?s)```.*?```", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[.!?;])\s+|[。！？；\n]"#, with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}")
        return sentences.contains { s in
            s.range(of: breakthrough, options: .regularExpression) != nil && s.range(of: cited, options: .regularExpression) == nil
        }
    }

    public static func scan(text: String, recentReceipts: [Receipt]) -> [IntegritySignal] {
        var out: [IntegritySignal] = []
        let lastExec = recentReceipts.last { ["python", "bash"].contains($0.tool) }
        if text.range(of: completionWords, options: .regularExpression) != nil {
            if let r = lastExec, !r.success {
                out.append(IntegritySignal(kind: .falseCompletion, severity: 3,
                                           detail: "claims success but the last execution (\(r.id)) failed with exit \(r.exitCode.map(String.init) ?? "error")", location: r.id))
            }
        }
        if let failed = recentReceipts.last(where: { !$0.success }), recentReceipts.last?.id == failed.id,
           text.range(of: #"(?i)(error|fail|exception|traceback|错误|失败)"#, options: .regularExpression) == nil {
            out.append(IntegritySignal(kind: .ignoredError, severity: 2, detail: "the last tool call (\(failed.id)) failed and the reply does not mention it", location: failed.id))
        }
        if text.range(of: scopeShrink, options: .regularExpression) != nil {
            out.append(IntegritySignal(kind: .scopeShrink, severity: 2, detail: "scope reduction language — check the plan was revised with a rationale", location: nil))
        }
        if ownStrongClaim(text) {
            out.append(IntegritySignal(kind: .breakthrough, severity: 3, detail: "strong-claim language — requires independent verification", location: nil))
        }
        return out
    }
}

// MARK: Claims

public struct Claim: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, verifying, verified, refuted, inconclusive }
    public var id: String
    public var statement: String
    public var successCriteria: String
    public var evidence: [String]          // receipt ids cited by the main agent
    public var dataPaths: [String]         // raw inputs the verifier may read
    public var status: Status
    public var verdict: String?
    public var verifierReceipts: [String]
    public var createdAt: Date
}

/// Claims can only be moved to verified/refuted by the host after a verifier run; the main agent has
/// no tool that sets a claim's status (Reasonix's rule: status changes need a host-issued identity).
public final class ClaimLedger: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var claims: [Claim] = []
    /// `claims.json` in the task's state directory; nil = in memory only.
    let stateURL: URL?

    /// Loads the task's claims. A claim left `verifying` was interrupted (app quit mid-run): it is
    /// not treated as verified, it is reported as inconclusive and can be registered again.
    public init(stateURL: URL? = nil) {
        self.stateURL = stateURL
        claims = StateFile.load([Claim].self, from: stateURL) ?? []
        var changed = false
        for i in claims.indices where claims[i].status == .verifying {
            claims[i].status = .inconclusive
            claims[i].verdict = "not verified — verification was interrupted before it finished; register the claim again to re-verify"
            changed = true
        }
        if changed { persist() }
    }

    private func persist() { StateFile.save(claims, to: stateURL) }

    public func add(statement: String, criteria: String, evidence: [String], dataPaths: [String]) -> Claim {
        lock.lock(); defer { lock.unlock() }
        let next = (claims.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        let c = Claim(id: "C\(next)", statement: statement, successCriteria: criteria, evidence: evidence,
                      dataPaths: dataPaths, status: .pending, verdict: nil, verifierReceipts: [], createdAt: Date())
        claims.append(c)
        persist()
        return c
    }

    func hostSet(_ id: String, status: Claim.Status, verdict: String?, receipts: [String] = []) {
        lock.lock(); defer { lock.unlock() }
        guard let i = claims.firstIndex(where: { $0.id == id }) else { return }
        claims[i].status = status
        if let verdict { claims[i].verdict = verdict }
        if !receipts.isEmpty { claims[i].verifierReceipts = receipts }
        persist()
    }

    public var snapshot: [Claim] { lock.lock(); defer { lock.unlock() }; return claims }
    public func restore(_ cs: [Claim]) { lock.lock(); claims = cs; persist(); lock.unlock() }
}
