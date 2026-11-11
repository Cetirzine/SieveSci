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
    /// A question about what exists on a topic ("what approaches are there for X?", "总结一下这个方向"):
    /// answered from web and literature searches, directly — no plan, checkpoints, claims or workers.
    case lookup
    /// Learning: explain a concept, teach a method, set exercises, lay out what to study.
    case learn
    /// Reading one paper or document closely: what it asks, how, what it found, how far to trust it.
    case read
    /// Working on the user's own text: polish, translate, shorten, restructure.
    case write
    /// Could be either (a short message that mentions research words, a mid-length one without them):
    /// the agent judges it from the message and the workspace, and takes the lighter reading when that
    /// answers it well. It asks only when the two readings would lead to very different work.
    case unclear

    /// The host's first call on a user message.
    public static func classify(_ raw: String) -> TurnScale {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .research }
        let lower = text.lowercased()
        // Commands and host-written prompts (job events, late answers) keep the full protocol.
        if lower.hasPrefix("/") || lower.hasPrefix("<") { return .research }
        let length = text.count
        let oneLine = !text.contains("\n")
        let cjk = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        // A rough size in "words": CJK characters count about half a word each.
        let words = text.split(whereSeparator: { $0.isWhitespace }).count + cjk / 2
        func has(_ list: [String]) -> Bool { list.contains { lower.contains($0) } }

        // The user's own text to work on, whatever its length.
        if has(writeWords), !has(["写一篇", "写篇", "撰写", "write a ", "write an ", "draft a "]) { return .write }
        // One named paper or document to read.
        if has(readWords), mentionsPaper(lower) { return .read }
        if has(learnWords), !mentionsFile(lower), length <= 400, !text.contains("\n\n") { return .learn }
        if length <= 40 || words <= 10 {
            let bare = lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).union(CharacterSet(charactersIn: "！？。，～~")))
            if greetings.contains(bare) || (has(chatWords) && !has(workWords) && !has(lookupWords)) { return .chat }
        }
        // Work to be done (an analysis, a model, an experiment, a document) is research however it is phrased;
        // so is anything about the user's own files or data.
        let work = has(workWords), own = has(ownDataWords) || mentionsFile(lower)
        if has(lookupWords), !work, !own, length <= 400, !text.contains("\n\n") { return .lookup }
        if work || has(researchWords) {
            // Something to build, write or run is research at any length; a short "analyse this" may be a small task.
            if has(makeWords) { return .research }
            if length <= 40 && oneLine { return has(quickWords) ? .quick : .unclear }
            return .research
        }
        if text.contains("\n\n") { return .research }
        if length <= 120 && oneLine { return .quick }
        if length <= 300 { return .unclear }
        return .research
    }

    /// A file name or a path in the message.
    static func mentionsFile(_ lower: String) -> Bool {
        lower.range(of: #"(^|[\s"'(（:：])[\w./~-]+\.(csv|tsv|xlsx?|txt|json|ya?ml|pdb|cif|fasta|fa|fastq|sdf|mol2?|smi|h5ad|py|r|ipynb|md|pdf|docx?)\b"#, options: .regularExpression) != nil
    }

    /// A DOI, an arXiv or PubMed id, a link, or a document file.
    static func mentionsPaper(_ lower: String) -> Bool {
        lower.range(of: #"10\.\d{4,9}/\S+|arxiv[:\s/.]|\b\d{4}\.\d{4,5}(v\d+)?\b|pmid|pmc\d+|https?://|\.pdf\b|\.docx?\b|\[@\w+\]|这篇|该文|this paper|the paper"#, options: .regularExpression) != nil
    }

    /// Modes the user can ask for by name (`/lookup …`), with the scale each sets for that message.
    public static let commands: [String: TurnScale] = ["quick": .quick, "lookup": .lookup, "learn": .learn, "read": .read, "write": .write, "deep": .research]

    /// Light modes: answered directly, with no plan, checkpoints or workers.
    public var isLight: Bool { [.chat, .quick, .lookup, .learn, .read, .write].contains(self) }

    static let writeWords = ["润色", "翻译", "改写", "校对", "语法", "精简一下", "缩写", "扩写", "降重", "polish", "translate", "proofread", "rewrite", "rephrase", "paraphrase", "grammar", "shorten this", "copyedit"]
    static let readWords = ["读", "解读", "精读", "讲讲这篇", "总结这篇", "概括", "看看这篇", "summar", "read ", "walk me through", "explain this paper", "critique", "what does"]
    static let learnWords = ["教我", "教教我", "讲解", "讲一下", "入门", "怎么学", "学习路线", "学习计划", "零基础", "出题", "出几道", "考考我", "练习题", "通俗", "举个例子", "帮我理解", "我不懂", "没看懂", "复习",
                             "teach me", "explain like", "eli5", "quiz me", "study plan", "learning path", "for a beginner", "help me understand", "tutorial", "practice problems", "exercises on"]

    /// Asking what is known: an overview, a comparison, a definition, the state of a field.
    static let lookupWords = [
        "总结", "概述", "综述一下", "介绍", "有哪些", "有什么", "有啥", "是什么", "什么是", "是啥", "现状", "进展", "最新", "区别", "对比", "比较一下", "原理",
        "调研", "了解一下", "科普", "梳理", "盘点", "主流", "常用", "怎么理解", "讲讲", "说说", "查一下", "查查", "搜一下", "搜索一下",
        "summar", "overview", "what is ", "what are ", "what's ", "state of the art", "state-of-the-art", "survey of", "explain ", "difference between",
        "compare ", "how does ", "how do ", "which methods", "which tools", "tell me about", "recent advances", "latest ", "look up", "search for",
    ]

    /// Asking for work: something to run, build, design, test or write.
    static let workWords = [
        "分析", "跑一", "跑下", "运行", "实现", "训练", "建模", "设计", "复现", "验证", "检验", "筛选", "预测", "打分", "评估", "基准", "头脑风暴", "实验", "假设",
        "写一篇", "写一个", "写个", "写篇", "撰写", "做一个", "做个", "开发", "构建", "搭建", "优化", "改进", "方案", "可行性", "统计", "拟合", "对接一下", "计算",
        "analy", "run ", "implement", "train ", "build ", "design ", "reproduce", "benchmark", "fit ", "screen ", "predict", "brainstorm", "experiment",
        "hypothes", "write a ", "write an ", "draft ", "develop ", "evaluate ", "optimi", "statistic", "compute ", "calculate ",
    ]

    /// Asking for a deliverable: a design, a model, a document, an experiment.
    static let makeWords = [
        "设计", "实现", "训练", "建模", "复现", "写一篇", "写篇", "撰写", "做一个", "做个", "开发", "构建", "搭建", "头脑风暴", "可行性", "方案",
        "implement", "train ", "build ", "design ", "reproduce", "benchmark", "brainstorm", "write ", "draft ", "develop ",
    ]

    /// The user's own material: a lookup does not answer a question about it.
    static let ownDataWords = ["这个文件", "这些文件", "这批", "我的数据", "我们的数据", "附件", "工作区", "这份", "数据集", "this file", "these files", "my data", "our data", "attached", "workspace", "dataset"]

    /// Small concrete tasks, even when a research word appears ("分析一下这个报错").
    static let quickWords = ["报错", "错误", "版本", "安装", "装了", "列出", "转换", "格式", "路径", "重命名", "打开", "error", "version", "install", "list ", "convert", "rename", "traceback"]

    /// Words that mark research work in any length of message.
    static let researchWords = [
        "研究", "综述", "文献", "论文", "靶点", "蛋白", "基因", "化合物", "测序", "通路", "机制",
        "research", "review the literature", "literature", "paper", "mechanism", "pathway", "protein", "gene ", "compound",
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
        case .lookup:
            return "turn: lookup — the user wants to know what exists on a topic, not a study. Search first (`web_search` and "
                + "`literature_search`, several queries in one step; `paper_fetch` only what you rely on), then answer directly: an "
                + "organised overview, each point with its source (link or [@key]), and what is uncertain or disputed. No plan, "
                + "hypotheses, checkpoints, claims, brainstorm or workers. If a good answer would need new analysis or experiments, "
                + "say so in one line at the end and offer to start a research task."
        case .learn:
            return "turn: learning — the user wants to understand something. Teach it: start from what they seem to know, build up "
                + "in steps, one worked example (with numbers or a small runnable snippet where it helps), the usual mistakes, then two "
                + "or three questions to check understanding and what to study next. Search (`web_search`, `literature_search`) for "
                + "anything you are not sure of or that changes fast, and give sources for facts. No plan, checkpoints, claims or "
                + "workers. Match the depth to the question; do not pad."
        case .read:
            return "turn: reading — the user wants one paper or document read closely. Get its text (`paper_fetch` + `paper_read`, "
                + "or `read_file` / `web_fetch`), then report: the question, the approach, the main results with their numbers and "
                + "where in the text they are, the limitations and what the evidence does not show, and what to read next "
                + "(`paper_graph` for citing and cited work if asked). Quote or locate what you rely on; never fill a gap from memory "
                + "— say when the full text could not be obtained. No plan, checkpoints, claims or workers."
        case .write:
            return "turn: writing — the user gave text to work on (polish, translate, shorten, restructure). Do exactly that to "
                + "their text: keep the meaning, the terms, the numbers and the citations as they are; add no facts, results or "
                + "references; keep the register (academic stays academic). Return the revised text first, then a short list of "
                + "what changed and anything that looked wrong in the content. No searches unless asked, no plan, no review."
        case .unclear:
            return "turn: scale unclear — judge from the message and the workspace whether this is a quick task, a lookup "
                + "(answer from searches) or research work, and take the lightest reading that answers it well; say in one line "
                + "at the end what a full research task would add, if anything. Ask (`ask_user`, kind single, reason user_decision) "
                + "only when the readings would lead to very different work and nothing tells which. Quick: do it directly and "
                + "briefly. Lookup: search, then answer with sources. Research: start the protocol (search, then `update_plan`)."
        case .research:
            return nil
        }
    }
}
