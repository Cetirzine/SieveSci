import Foundation

/// Names a conversation after its first exchange: the worker model reads the user's first message
/// and the first reply and returns a short topic title (`title-auto.txt`). A name the user gave
/// (`title.txt`) always wins and is never replaced. Generation is best effort: a failed, empty or
/// slow call leaves the current title (the first question) as it is, silently.
///
/// Front ends only display the result: it arrives as `AgentEvent.titleChanged` and is read back by
/// `SessionStore.title(dir:)`.
public enum TitleSummarizer {
    /// Frozen instructions for the naming call.
    static let system = """
    You name conversations in a research assistant. Read the user's first message and the assistant's first \
    reply, and reply with one short title for the topic of the conversation, in the language the user wrote in: \
    6 to 16 characters for Chinese or Japanese, 3 to 8 words for other languages. Name the subject itself \
    (the gene, compound, organism, method, dataset or question), not the act of asking. Plain text on one line: \
    no quotation marks, no final period, no prefix such as "Title:", nothing else.
    """

    /// Hard limits after cleaning (the prompt asks for less; these catch a model that ignores it).
    static let maxCJKCharacters = 16
    static let maxWords = 8
    static let maxCharacters = 64

    public enum Outcome: Equatable, Sendable {
        /// A new title was written and announced.
        case titled(String)
        /// Nothing to do: the user named it, or it already has a generated title.
        case skipped
        /// No question yet, or the call failed, timed out or returned nothing usable; the current title stays.
        case failed
    }

    // MARK: Cleaning

    /// Turns a model's reply into a title: first meaningful line, without labels, quotes, Markdown or
    /// a final period, cut to the length limits. Nil when nothing usable remains.
    public static func clean(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        guard let line = s.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        s = line
        s = s.replacingOccurrences(of: #"^[#>*_\-\s]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)^(title|topic|subject|titre|título|titulo|название|тема|标题|標題|主题|主題|题目|題目)\s*[:：]\s*"#,
                                   with: "", options: .regularExpression)
        let wrappers = CharacterSet(charactersIn: "\"'`*_“”‘’「」『』《》〈〉«»„‹›")
        let trailing = CharacterSet(charactersIn: ".。,，;；:：、!！").union(.whitespaces)
        var previous = ""
        while previous != s {
            previous = s
            s = s.trimmingCharacters(in: wrappers.union(.whitespaces))
            while let last = s.unicodeScalars.last, trailing.contains(last) { s.unicodeScalars.removeLast() }
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !s.isEmpty else { return nil }
        s = limit(s)
        return s.count >= 2 ? s : nil
    }

    /// Whether a title reads as Chinese or Japanese (counted in characters rather than words).
    static func isCJK(_ s: String) -> Bool {
        var cjk = 0, letters = 0
        for u in s.unicodeScalars where CharacterSet.letters.contains(u) {
            letters += 1
            if (0x3040...0x30FF).contains(u.value) || (0x3400...0x9FFF).contains(u.value) || (0xF900...0xFAFF).contains(u.value) { cjk += 1 }
        }
        return letters > 0 && cjk * 3 >= letters
    }

    static func limit(_ s: String) -> String {
        var t = s
        if isCJK(t) {
            if t.count > maxCJKCharacters { t = String(t.prefix(maxCJKCharacters)) }
        } else {
            let words = t.split(separator: " ")
            if words.count > maxWords { t = words.prefix(maxWords).joined(separator: " ") }
            if t.count > maxCharacters {
                let cut = t.prefix(maxCharacters)
                t = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
            }
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: ".。,，;；:：、-–— ").union(.whitespaces))
    }

    // MARK: Source

    /// The user's first message and the reply that closed the first turn (its last non-empty text).
    static func firstExchange(_ transcript: [Message]) -> (question: String, reply: String)? {
        var question: String?
        var reply = ""
        for m in transcript {
            if m.role == .user, let q = SessionStore.userWords(m) {
                if question != nil { break }      // the second question ends the first turn
                question = HostContext.userText(q)
            } else if m.role == .assistant, question != nil {
                let t = m.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { reply = t }
            }
        }
        guard let q = question, !q.isEmpty, !q.hasPrefix("/") else { return nil }
        return (q, reply)
    }

    // MARK: Generation

    /// One cheap call to `provider`/`model`; nil on error, timeout or an unusable reply.
    public static func summarize(question: String, reply: String, provider: LLMProvider, model: String,
                                 lineage: String, workspace: URL? = nil, timeout: TimeInterval = 30) async -> String? {
        var body = "<first_message>\n\(question.truncated(2000, marker: "…"))\n</first_message>"
        if !reply.isEmpty { body += "\n<first_reply>\n\(reply.truncated(1500, marker: "…"))\n</first_reply>" }
        var req = LLMRequest(model: model, system: system, tools: [], messages: [Message.user(body)],
                             maxTokens: 256, effort: .low, cache: CacheHints(lineageKey: lineage + "-title", retention: .none))
        req.host = CLIHost(workspace: workspace, readOnly: true)
        let text: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { (try? await provider.complete(req))?.message.plainText }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if provider is CLIAgentProvider { CLIAgentProvider.endProcess(conversation: req.cache.lineageKey, profile: provider.profile) }
        return text.flatMap(clean)
    }

    /// Names the session's conversation with the worker model (the main model when no worker is
    /// set), unless the user named it or it already has a generated title. Writes `title-auto.txt`
    /// and emits `.titleChanged` on success.
    @discardableResult
    public static func autoTitle(services: SessionServices, transcript: [Message], timeout: TimeInterval = 30) async -> Outcome {
        let dir = services.taskDir
        guard !SessionStore.hasManualTitle(dir: dir), SessionStore.autoTitle(dir: dir) == nil else { return .skipped }
        guard let ex = firstExchange(transcript) else { return .failed }   // nothing to name yet
        let (p, m) = services.models.worker
        let started = Date()
        guard let title = await summarize(question: ex.question, reply: ex.reply, provider: p, model: m,
                                          lineage: services.taskId, workspace: services.workspace, timeout: timeout) else {
            services.log("auto_title", actor: "host", ["model": .string(m), "error": "no usable title",
                                                       "seconds": .double(Date().timeIntervalSince(started))])
            return .failed
        }
        // The user may have renamed it while the call ran.
        guard !SessionStore.hasManualTitle(dir: dir) else { return .skipped }
        SessionStore.setAutoTitle(title, dir: dir)
        services.log("auto_title", actor: "host", ["model": .string(m), "title": .string(title),
                                                   "seconds": .double(Date().timeIntervalSince(started))])
        services.emit(.titleChanged(task: services.taskId, title: title))
        return .titled(title)
    }
}
