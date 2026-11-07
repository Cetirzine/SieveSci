import Foundation

/// How much of the research machinery a message needs, judged by the host for each user message.
///
/// A greeting or "what can you do?" answered with searches, a plan and an integrity review is the
/// agent talking past the user; so is a one-line task ("what Python is installed?") held behind the
/// pre-registration gate. The host makes a cheap first call from the message itself, the turn context
/// tells the model, and the model can still turn a quick task into research by writing a plan
/// (`update_plan`), after which the protocol's gates apply as usual.
public enum TurnScale: String, Sendable, Equatable {
    /// Conversation: greetings, thanks, questions about SieveSci itself. A few sentences, no tools.
    case chat
    /// A small concrete task or a quick question: done directly, briefly, without plan or review.
    case quick
    /// Research work: the full protocol (search, plan, checkpoints, claims, review).
    case research
    /// Could be either (a short message that mentions research words, a mid-length one without them):
    /// the agent asks the user which it is before using tools, unless the message makes it clear.
    case unclear

    /// The host's first call on a user message.
    public static func classify(_ raw: String) -> TurnScale {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .research }
        let lower = text.lowercased()
        // Commands and host-written prompts (job events, late answers) keep the full protocol.
        if lower.hasPrefix("/") || lower.hasPrefix("<") || text.contains("\n\n") { return .research }
        let length = text.count
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        // A rough size in "words": CJK characters count about half a word each.
        let words = text.split(whereSeparator: { $0.isWhitespace }).count + cjk / 2
        let researchy = researchWords.contains(where: { lower.contains($0) })
        if researchy { return length <= 40 && !text.contains("\n") ? .unclear : .research }
        if length <= 40 || words <= 10 {
            let bare = lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).union(CharacterSet(charactersIn: "！？。，～~")))
            if greetings.contains(bare) || chatWords.contains(where: { lower.contains($0) }) { return .chat }
        }
        if length <= 120 && !text.contains("\n") { return .quick }
        if length <= 300 { return .unclear }
        return .research
    }

    /// Words that mark research work in any length of message.
    static let researchWords = [
        "研究", "分析", "综述", "文献", "论文", "实验", "假设", "设计", "方案", "数据集", "统计", "检验", "建模", "头脑风暴",
        "靶点", "蛋白", "基因", "化合物", "测序", "通路", "机制", "筛选", "预测", "benchmark", "基准",
        "research", "analy", "review the literature", "literature", "paper", "experiment", "hypothes", "dataset",
        "statistic", "brainstorm", "design a", "mechanism", "pathway", "protein", "gene ", "compound", "screen",
    ]

    /// Conversation openers and questions about the agent itself.
    static let chatWords = [
        "你好", "您好", "嗨", "哈喽", "早上好", "晚上好", "谢谢", "多谢", "辛苦", "再见", "在吗", "你是谁", "你能干", "你会什么",
        "你能做", "能做什么", "可以做什么", "怎么用", "介绍一下你", "hello", "thanks", "thank you",
        "good morning", "who are you", "what can you do", "what do you do", "how do i use",
    ]

    /// Whole-message greetings (substring matching would catch "this" or "which").
    static let greetings: Set<String> = ["hi", "hey", "hello", "yo", "hiya", "ok", "okay", "好的", "嗯", "ok thanks"]

    /// The turn-context line the model reads (nil for research, which the protocol already covers).
    public var contextLine: String? {
        switch self {
        case .chat:
            return "turn: chat — answer in a few plain sentences, directly; no searches, plan, tools or review. "
                + "Describe only what you can actually do here; do not claim software is installed unless a receipt shows it."
        case .quick:
            return "turn: quick task — do just this, with the few tool calls it needs, and answer briefly; no plan, "
                + "literature search, brainstorm or workers. If it turns out to need real research, say so and start "
                + "the research protocol with `update_plan`."
        case .unclear:
            return "turn: scale unclear — judge whether this is a quick task or research work. If the message does not "
                + "make it clear, ask the user once with `ask_user` (kind single, reason user_decision: a quick, direct answer · a "
                + "full research task with searches, a plan and review) before using tools. Quick: do it directly and briefly. "
                + "Research: start the protocol (search, then `update_plan`)."
        case .research:
            return nil
        }
    }
}
