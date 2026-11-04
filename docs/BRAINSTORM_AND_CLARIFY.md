# 头脑风暴与澄清提问：调研与设计方案

状态：已实现第 1–4 期的核心功能与界面（见第 8 节）。日期：2026-11-04。

本文讨论两个相关功能：

- **A. 主动头脑风暴与"做梦"**：让智能体主动提出创新想法，包括在空闲时段于后台产生想法。
- **B. 结构化澄清**：用户指令模糊时，智能体先检索、再头脑风暴，然后把几个候选方向做成单选、多选或填空题交给用户挑选，每道题都允许填写"其他"。

两者共用一条链路：**检索 → 发散 → 去重和初筛 → 让用户选择，或进入新颖性检查与复核**。要守住的约束是 SieveSci 的两条原则：先检索再发言；重要结论由独立的检查者和验证者复核。想法可以大胆，但想法本身不算结论。

文中标注"已核实"的内容，表示读过一手来源：论文原文或摘要、官方文档、源码。"未核实"或"仅二手来源"会单独说明。

---

## 1. 调研结论

### 1.1 总表

| 做法 | 机制 | 产出质量与证据 | 放进 SieveSci |
|---|---|---|---|
| OpenClaw Dreaming | 定时（默认每天凌晨 3 点）分三个阶段整理记忆：light、REM、deep。按加权分数把短期信号提升为长期记忆 | 只做记忆整合，**不生成新假设**；没有效果评估，用户反馈褒贬不一 | 借鉴"可审阅的夜间整理、日记文件、预览后再写入"的形态，不能当作创新机制 |
| OpenClaw 社区 dreaming 技能 | 借心跳在安静时段自由联想，结果写入文件留待早上审阅 | 第三方技能，没有测量结果 | 只借鉴形态 |
| Claude Code AutoDream | 空闲时由后台子智能体整理记忆文件 | 仅有二手报道，触发条件说法不一 | 同上 |
| Google AI co-scientist | Generation、Reflection、Ranking（Elo 锦标赛）、Evolution、Proximity、Meta-review 多智能体循环 | 预印本；Elo 与 GPQA 准确率同向；有湿实验验证的案例（AML 药物重定位、肝纤维化靶点） | **主框架**，`hypothesis-tournament` 已覆盖大部分 |
| Sakana AI Scientist | 生成想法、做新颖性检查、跑实验、写论文 | 独立评测发现新颖性判断差（把已知方法判为新颖），42% 的实验因代码错误失败 | 当反面教材：新颖性检查不能只靠模型自评 |
| Stanford Virtual Lab | PI、专家、Scientific Critic 一起开会；同一议程并行开 5 场（温度 0.8），再合并（温度 0.2） | Nature 2025；设计出 92 个纳米抗体并做了实验验证；作者称 critic 很关键 | **"高温并行 + 低温合并"值得照搬**，`virtual-lab-meeting` 已部分覆盖 |
| 随机概念组合、种子词 | 用随机词或随机概念刺激发散 | 随机输出在发散度指标上得分很高，但缺乏意义；只能当刺激，不能当产出 | 可用，但种子必须来自**受控词表和检索结果**，而不是随机 token |
| 论文要素重组（Scideator） | 把论文拆成目的、机制、评估三类要素，跨论文重组，内置新颖性检查 | 22 人的组内对照研究：明显更好地支持创意；新颖性检查能帮助过滤不原创的想法 | **很适合**，天然以检索为基础 |
| 迭代新颖性提升（SciMON） | 检索近邻文献，与之比较，再改写得更新颖 | 有提升，但想法仍偏增量 | 可作为进化算子之一 |
| 高温采样 | 调高 temperature | 与新颖性弱相关，与不连贯中度相关 | 收益低；SieveSci 目前不传温度参数，不作为主手段 |
| Verbalized Sampling | 一次要求给出多个答案及其概率，再从分布尾部采样 | 创意写作任务上多样性提升 1.6–2.1 倍，不需要训练 | **推荐**，与厂商无关 |
| 跨领域类比 | 先把问题抽象化，再到远端领域找类比 | 2026 年有预印本报告方案多样性明显提高；也有研究指出类比集中在少数领域，多样性和质量此消彼长 | 推荐，需配合检索 |
| 反向假设（推翻假设） | 列出核心假设并逐条否定 | **没有找到单独评估这一技术的研究**；co-scientist 的生成环节有"迭代识别可检验假设"和"跳出框框"两种近似做法 | 可作为低成本算子，但标明"缺乏证据" |
| Sleep-time compute（Letta） | 在提问之前离线预处理上下文 | 同等准确率下测试时计算约减少 5 倍；问题越可预测，收益越大 | 支持"空闲时段做准备工作"，但它是推理加速，不是创意 |

### 1.2 OpenClaw 的"做梦"到底是什么（已核实）

官方文档（[docs.openclaw.ai/concepts/dreaming](https://docs.openclaw.ai/concepts/dreaming.md)）的要点：

- 它是 `memory-core` 插件里的后台**记忆整合**，默认开启，由 cron 触发，默认时间 `0 3 * * *`。它**不检测空闲**。
- 每轮依次运行三个阶段：
  - **light**：去重并暂存近期的短期材料，不写 `MEMORY.md`；
  - **REM**：生成主题和反思摘要，记录强化信号，不写 `MEMORY.md`；
  - **deep**：按阈值 `minScore`、`minRecallCount`、`minUniqueQueries` 筛选候选，再由一次不调用工具的模型补全决定新增、合并和替换，只有这一步写 `MEMORY.md`。
- 打分权重：相关性 0.30、频率 0.24、查询多样性 0.15、新近性 0.15、多日重现 0.10、概念丰富度 0.06。
- 输出：`DREAMS.md` 梦境日记（只给人读，不作为记忆来源）。另有若干安全闸：来源为 untrusted 或 system 的候选先剔除；一次改写如果删掉超过 25% 的旧条目，或丢失任何来源引用，就被拒绝。
- 控制方式：`/dreaming on|off|status`，以及 `openclaw memory promote`（默认只预览，加 `--apply` 才写入）。
- 文档**没有描述任何随机重组或生成新想法的机制**。

用户说的"做梦和自主创新（随机 token 组合）"，在 OpenClaw 官方功能里**查不到**。最接近的是社区技能：ClawHub 上的 `dreaming`、`inner-life-dream`、`agent-dreams` 等。它们利用心跳（默认每 30 分钟一次），在安静时段（默认 23:00–07:00）做假设、未来情景、意外联想等自由思考，结果写入文件供人第二天审阅（[clawhub.ai/briancolinger/dreaming](https://clawhub.ai/briancolinger/dreaming)）。这些技能是第三方维护的，没有任何质量测量。"随机 token 组合"本身没有找到出处，可能是用户对这类技能的概括。

Claude Code 的 AutoDream 也属于同一类记忆整合。目前只有二手报道（[claudefa.st](https://claudefa.st/blog/guide/mechanics/auto-dream)、[implicator.ai](https://www.implicator.ai/anthropic-adds-auto-dream-to-claude-code-fixing-memory-decay-between-sessions)），触发条件说法不一，本文不以它为依据。

**结论**：业界的"做梦"主要是**离线整理记忆**，不是产生科学假设。SieveSci 可以借鉴它的形态：定时运行、产出可审阅的日记、先预览后提升、设置安全闸。生成新想法这一块则需要自己设计，见第 3 节。

### 1.3 Google AI co-scientist（已核实：[arXiv 2502.18864](https://arxiv.org/abs/2502.18864)）

- **Generation**：检索文献，模拟多轮科学辩论，迭代找出可检验的假设，并参考以往评审意见向未探索的方向扩展。
- **Reflection**：设有六种评审：初审（不用工具，快速过滤正确性、新颖性、安全性）、全审（联网检索，对照文献判断新颖性）、深度验证（把假设拆成子假设逐条核查）、观察评审（看它能否比现有解释更好地解释已有观察）、模拟评审（逐步推演机制，找出失败情景）、锦标赛评审（针对反复出现的问题调整评审）。
- **Ranking**：Elo 锦标赛，新假设的初始分为 1200。排名靠前的假设之间用多轮辩论比较，靠后的用单轮两两比较。配对时优先选相似、较新或排名靠前的假设。
- **Evolution**：增强依据、提高连贯性和可行性、借鉴高分假设、合并、简化、**跳出框框（发散）**。进化**生成新假设，而不是修改旧假设**，新版本必须在锦标赛里赢得位置。
- **Proximity**：在假设之间建相似度图，用来聚类、去重和配对。**Meta-review**：把评审中反复出现的模式写回其他智能体的提示词，不做微调。
- **证据**：Elo 分档与 GPQA diamond 准确率同向，最高档的 top-1 准确率为 78.4%。AML 药物重定位候选在体外达到临床可用浓度；肝纤维化表观遗传靶点在类器官中得到验证（[Google Research 博客](https://research.google/blog/accelerating-scientific-breakthroughs-with-an-ai-co-scientist)）。这是预印本，代码未开源。

### 1.4 Sakana AI Scientist（已核实摘要：[arXiv 2502.14297](https://arxiv.org/abs/2502.14297)）

Beel 等人的独立评测发现，它的文献综述把已有方法（例如 SGD 的 micro-batching）判为新颖；生成的论文引用数中位数为 5，34 篇引用中只有 5 篇来自 2020 年以后；42% 的实验因代码错误失败；还出现过编造的数值结果。这篇摘要没有写明评测的是哪个版本。v2 版的独立审计目前只找到 NeurIPS 2026 的投稿页面（[neurips.cc](https://neurips.cc/virtual/2026/156512)），无法确认是否经过同行评审。

**对 SieveSci 的启示**：新颖性判断必须**以检索为证据，并由生成者以外的角色复核**。SieveSci 现有的 `novelty-check` 技能就来自 AI Scientist，但目前没有任何机制强制执行。

### 1.5 Stanford Virtual Lab（已核实源码：[zou-group/virtual-lab](https://github.com/zou-group/virtual-lab)）

- `prompts.py` 定义了 `SCIENTIFIC_CRITIC` 角色，任务是"指出并纠正所有错误"。个人会议的每一轮里，先由科学家回答，再由 critic 批评，科学家再修改。
- `constants.py` 定义了 `CREATIVE_TEMPERATURE = 0.8` 和 `CONSISTENT_TEMPERATURE = 0.2`。在 `run_nanobody_design.ipynb` 中，每个阶段先用 0.8 并行开 `num_iterations = 5` 场独立讨论（`num_rounds = 3`），再用 0.2 开一场合并会，合并提示词要求"融合各份答案中最好的部分，并说明每一部分来自哪份答案"。
- 论文结果：设计出 92 个纳米抗体并做了实验验证，其中两个对近期变异株有独特的结合谱（[Nature 2025](https://www.nature.com/articles/s41586-025-09442-9)，二手报道见 [GEN](https://www.genengnews.com/topics/artificial-intelligence/interdisciplinary-ai-scientists-in-virtual-lab-work-with-humans-to-solve-complex-research-questions/)）。Zou 在采访中称 critic 很关键，并减少了幻觉。

**对 SieveSci 的启示**："多份独立发散，再合并并注明出处"这一模式与模型厂商无关。SieveSci 不必依赖温度，可以用不同的 worker、不同的种子、不同的模型做发散，再由 main 合并。

### 1.6 多样性与新颖性的系统证据

- **LLM 的想法缺乏多样性**（[Si、Yang、Hashimoto，arXiv 2409.04109](https://arxiv.org/abs/2409.04109)，ICLR 2025）：100 多位 NLP 研究者盲评，LLM 的想法被评为比专家更新颖（p<0.05），可行性略弱。但每个主题生成的 4000 个种子想法中，去重后只剩约 200 个（约 5%），而且越往后生成，重复率越高。作者同时指出 LLM 自我评估不可靠。
- **构思与执行之间的落差**（[arXiv 2506.20803](https://arxiv.org/abs/2506.20803)，ICLR 2026）：43 位专家各花 100 多小时实际执行随机分配的想法。执行后，LLM 想法的得分在所有指标上下降得都比人类想法多，排名随之反转。**事前看起来新颖，并不代表做出来有效。**
- **温度**（[Peeperkorn 等，arXiv 2405.00492](https://arxiv.org/abs/2405.00492)）：温度与新颖性弱相关，与不连贯中度相关。
- **Verbalized Sampling**（[arXiv 2510.01171](https://arxiv.org/abs/2510.01171)）：作者认为模式坍缩源于偏好数据中的"典型性偏差"。改为要求模型输出一组答案及其概率，创意写作任务上的多样性提升 1.6–2.1 倍。
- **随机词**：在发散联想任务（DAT）上，随机输出可以拿到很高的分，却缺乏意义（[arXiv 2601.20546](https://arxiv.org/abs/2601.20546)）。随机词只能当作刺激或基线。
- **类比**：跨领域类比能提高方案多样性（[arXiv 2605.11258](https://arxiv.org/abs/2605.11258)）；但 LLM 的类比集中在少数领域，多样性与质量此消彼长（[arXiv 2608.03233](https://arxiv.org/abs/2608.03233)）。
- **要素重组**：Scideator（[arXiv 2409.14634](https://arxiv.org/abs/2409.14634)）。**迭代新颖性提升**：SciMON（[ACL 2024](https://aclanthology.org/2024.acl-long.18)），作者承认产出仍偏增量。
- **Sleep-time compute**（[arXiv 2504.13171](https://arxiv.org/abs/2504.13171)）：在提问前离线处理上下文，同等准确率下测试时计算约减少 5 倍。

**综合判断**：发散手段能提高想法的**表面新颖度和多样性**，但只靠模型自评无法证明想法真正有价值。真正的筛选来自检索比对、独立评审，最终要靠执行和验证。这正好对应 SieveSci 已有的结构：检索闸、检查者、验证者。

### 1.7 澄清提问的产品形态

**Claude Code AskUserQuestion**（已核实：[Agent SDK 文档](https://code.claude.com/docs/en/agent-sdk/user-input)）

- 每次 1–4 个问题，每题 2–4 个选项。每个选项有 `label` 和 `description`，TypeScript 版本还可以带 `preview`（Markdown 或 HTML）。每题有不超过 12 个字符的 `header`，以及 `multiSelect` 开关。
- 返回值以问题文本为键、以所选 label 为值。"其他"由宿主界面自行添加，用户填写的文字直接作为答案。另有可选的 `response` 字段，表示用户关掉卡片、改为直接回复。
- 问题由模型生成，宿主不能往里加题。子智能体不能使用。回调可以一直挂起，也可以用 `defer` 先退出进程、之后恢复。
- 使用规则写在工具描述里：推荐的选项放第一位并标注"(Recommended)"；问题要能独立成立。

**Reasonix 的 `ask` 工具**（已核实源码：[esengine/DeepSeek-Reasonix](https://github.com/esengine/DeepSeek-Reasonix) 中的 `internal/runtime/agent/ask.go` 和 `desktop/frontend-next/src/ui/cards/AskCard.tsx`）

- 结构与 Claude Code 基本一致：1–4 题、每题 2–4 个选项、`header`、`multiSelect`。另外多了一个 `reason` 字段，取值为 `user_decision`（必须由用户在真实的备选方案之间做决定）或 `missing_value`（请求里缺少某个必要的值）。
- 工具描述划清了边界：是否允许改某个文件属于权限问题；计划能否执行属于计划卡片；"东西放在哪""测试为什么失败"应该自己去查；局部、低风险、可逆的细节直接取合理默认值。**"有推荐答案不等于这个选择归你"**：推荐项放第一位，但仍然要问。
- **决策屏障**：调用 `ask` 会结束本轮，同一轮里写的其他内容不会执行。工具被标记为 ReadOnly，在计划模式下也可以用。
- 结果分四种情况，各有专门的措辞：
  - 正常作答；
  - **全部未答（用户关掉卡片）**：明确告诉模型"不要替用户选，停下来等用户的下一条消息"；
  - **超时**：明确告诉模型"这是超时，不是用户的偏好"，可以先做不依赖这个决定的部分，并在回复里写明采用了什么假设；
  - **没有交互用户（无界面运行）**：返回 `unresolved`，禁止替用户做决定。
- 卡片界面：多道题以标签页或步进器切换；"其他"是一个单行输入框；单选题选中后还能附一句备注；草稿自动保存；支持倒计时跳过；答完后卡片封存。Reasonix 也是**宿主定义工具、界面只负责渲染**的结构，并且已经有 Tauri 桌面客户端。这与 SieveSci 正在考虑的跨平台方向一致。

**ChatGPT deep research**（部分核实）

- 官方 API 文档（[developers.openai.com deep-research 指南](https://developers.openai.com/api/docs/guides/deep-research)）说明，ChatGPT 的 deep research 分三步：先由一个**中间模型做澄清**，收集偏好、目标和约束；再由中间模型**改写成更详细的提示词**；最后才进入研究。API 本身不包含前两步。文档给出的澄清提示词要点：简洁；必要时用项目符号或编号列表；不要问用户已经提供的信息；**澄清阶段不做研究**。
- 帮助中心（[help.openai.com 10500283](https://help.openai.com/en/articles/10500283-deep-research-faq)，WebFetch 返回 403，内容取自搜索摘要）说明：deep research "可能"先问澄清问题，并给出一份可以审阅和编辑的研究计划，运行中可以打断并调整关注点和信源。
- **未核实**：没有找到 OpenAI 官方说明 deep research 的澄清问题以选项卡片形式呈现。现有资料显示是聊天里的普通文本问题，用户用自然语言回答。只有一家二手媒体报道 ChatGPT 的"Intelligent UI"能在回答里插入按钮、表单和选择题式追问（[trendingtopics.eu](https://www.trendingtopics.eu/gpt-6-chatgpt-intelligent-ui-everyone/)），没有找到官方发布说明。
- 值得借鉴的是**流程**（澄清 → 改写 → 可编辑的计划 → 执行），以及"澄清阶段不做研究"这条规则。SieveSci 对后一条要反过来：因为要求先检索再发言，**问方向之前必须先做少量检索**，见第 2 节。

---

## 2. 推荐方案总览

```
用户指令
  │
  ├─ 指令清楚 ──────────────────────────────────→ 正常研究流程
  │
  └─ 指令模糊（由模型判断，或用户执行 /clarify）
        │
        ① 快速检索：web_search 加 literature_search 3–6 次，满足检索闸
        ② 发散：生成 8–12 个方向（多个算子，可以分给多个 worker 并行）
        ③ 去重、聚类，初筛可行性
        ④ ask_user：3–4 个方向（单选或多选）+ 约束题（填空）+ "其他"
        ⑤ 用户的回答记入审计 → 改写成具体的研究问题 → update_plan
```

```
/brainstorm 或 /dream（主动创新）
  ① 检索并建立证据摘要  ② 用多个算子发散，记录种子
  ③ 去重（Proximity）  ④ 用 dispatch rank 初排
  ⑤ 前三分之一做新颖性检查（必须基于检索，host 强制执行）
  ⑥ 检查者复核新颖性判断  ⑦ 进化一到两轮
  ⑧ 写入想法登记 Idea Ledger，状态为 speculation
  ⑨ 用户采纳 → 提升为 Hypothesis（必须写出预测和证伪标准）
  ⑩ 执行 → claim_finding → 验证者盲法复核 → 才算结论
```

三层状态分开，互不混用：

| 层级 | 载体 | 能否在结论里出现 | 进入下一层的门槛 |
|---|---|---|---|
| 想法（Idea） | 新增 `IdeaLedger` | 只能写成"推测"，并带上 `idea:` 标签 | 新颖性检查的检索回执，加检查者通过 |
| 假设（Hypothesis） | 现有 `ResearchPlan.hypotheses` | 写成"待检验的假设" | 预测和证伪标准事先写明，然后执行 |
| 结论（Claim） | 现有 `ClaimLedger` | 只有 verified 的才能作为结论 | 验证者盲法复现 |

**取舍**

- **不做"随机 token 组合"**。研究表明随机输出只提高表面新颖度，而且会产生无法检索验证的内容，与"先检索再发言"冲突。改为从**受控词表**（MeSH、GO、ChEBI 分类、任务文献库的关键词和方法名）以及 `paper_graph` 的远端邻居里**有种子地随机抽取**概念作为刺激。种子记入审计，结果可以复现，不会编造实体。
- **不把调温度作为主手段**。SieveSci 当前不向任何厂商发送 temperature 参数（`Sources/SieveSciCore/LLM/` 中检索不到 temperature），而且部分厂商在开启思考模式时限制改温度（实现时需逐家核实）。多样性改由 worker 并行、不同种子、不同模型和 Verbalized Sampling 提供；温度只作为可选参数，放到第 4 期。
- **做梦默认关闭**，第 4 期才做。目前没有证据表明后台做梦能提高科研产出；OpenClaw 的用户反馈也褒贬不一。它的价值在于**利用空闲时段做准备工作**（证据来自 Sleep-time compute），以及给出可审阅的灵感簿。
- **ask_user 先做**。它被多个产品验证过，实现成本低，并且是头脑风暴结果交给用户的出口。

---

## 3. 设计细节

### 3.1 现有代码里能复用的部分

| 现有代码 | 现状 | 复用方式 |
|---|---|---|
| `GoalTool` 的 `wait`（`Tools/BuiltinTools.swift:668`，`Agent/Goal.swift` 的 `modelWait`） | README 所说"用结构化的方式提一个具体问题"，实际只是 `note` 字符串。目标进入 `waiting` 状态，`TaskStage.answer` 在侧边栏显示"Needs your answer"；用户回复任意消息后 `userReplied()` 恢复 | `ask_user` 在目标激活时自动让目标进入 waiting；`goal wait` 保留，作为纯文本问题的退路，提示词引导模型优先用 `ask_user` |
| 权限请求（`AgentSession.swift:435`、`SessionServices.requestPermission`、`PermissionQueue`、`AppModel.answerPermission`） | 发出事件、挂起等待用户回答、写审计日志，已经有完整的"异步等待用户"链路 | `ask_user` 照搬：`services.requestAnswer` 加 `AskQueue` |
| `TaskStage.Facts`、`TaskStage.of` | 有 `permissionAsk` 和 `goal.waiting` 两种"等用户回答"的来源 | 新增 `pendingAsk`，侧边栏优先列出 |
| `DispatchTool` 的 `map`、`rank`、`consensus` 三种模式，以及 `BradleyTerry.swift` | 已能做并行发散、两两比较排名（带置信区间）、多轨迹共识 | 发散、排名、并行评审全部复用，不另造锦标赛 |
| `hypothesis-tournament` 技能 | 已有生成、排名、反思、进化、元评审，来自 co-scientist 和 Robin | 作为 `/brainstorm` 的骨架；补上发散算子、去重和强制新颖性检查 |
| `virtual-lab-meeting` 技能 | 已有 PI、专家两轮、critic 环节，交给用户批准 | 补上"N 份并行发散加合并并注明出处"；用于选方向型的头脑风暴 |
| `novelty-check` 技能 | 有步骤（5–10 个查询，读 5–10 篇最近邻文献，给出判断），但没有强制力 | 升级为 host 侧闸门：想法提升为假设时，必须引用想法创建之后产生的检索回执 |
| `ResearchProtocol.requireGrounding` | 计划、结论、检查点之前强制完成 web 和文献检索 | 方向型提问（`reason: direction`）也走这道闸 |
| `Supervisor`（检查者） | 支持多种 review kind | 新增 `ideation` 类型，复核新颖性判断和想法到假设的提升 |
| `Scheduler`（LaunchAgent）与无界面 `sievesci -p` | 已支持 daily、weekly、every 等定时运行 | `/dream` 直接复用，运行在 plan 模式（只读） |
| `MemoryStore`、`Evolution` | 记忆写入需要审核 | 做梦**不直接写记忆**，只产出 Evolution 提案，与 OpenClaw 不直接写 `MEMORY.md` 的思路一致 |

### 3.2 B：`ask_user` 工具（核心层）

#### 工具定义草案

工具名 `ask_user`，所有角色都在工具列表里。工具列表不随会话变化，这样可以保持前缀缓存命中。只有 `main` 角色在调用时被允许使用：checker、verifier、worker 调用时返回错误。verifier 绝不能问用户，否则会破坏盲法。

```jsonc
{
  "questions": [            // 1–4 题，一次提交
    {
      "id": "direction",    // 可选，缺省为 q1、q2……
      "header": "研究方向",  // ≤12 个字符（中文 ≤6 个字），用作标签页标题
      "question": "你最想先回答哪个问题？",
      "kind": "single",     // single | multi | text
      "reason": "direction",// user_decision | missing_value | direction
      "options": [          // single/multi：2–5 个；text 不填
        {
          "label": "比较三种降解途径",
          "description": "已有 RNA-seq，2 天内可完成",
          "recommended": true,           // 至多 1 个，界面上排在第一位并加标记
          "evidence": ["@smith2023", "r12"],  // 可选：文献 key 或回执 id，界面上显示为可点击的标签
          "idea": "I7"                   // 可选：这个选项来自哪条想法
        }
      ],
      "allow_other": true,  // 缺省为 true："其他"加输入框由界面自动添加，模型不要自己写"其他"
      "placeholder": "例如：小鼠肝脏，n≥6",   // 用于 text 题或"其他"输入框
      "optional": false     // 可跳过的题；未答的题不会被当成默认答案
    }
  ]
}
```

与 Claude Code 和 Reasonix 的差异，以及原因：

- **`kind: text`（填空题）**：两个参考产品都没有独立的填空题，只能通过"其他"输入框间接实现。科研场景经常需要物种、样本量、数据路径、预算这类具体值，所以单独列为一种题型。
- **`reason: direction`**：在 Reasonix 两种取值的基础上新增，表示"由头脑风暴得出、需要用户挑选的研究方向"。这类题**必须先通过检索闸**，选项应当带 `evidence`。
- **`evidence` 和 `idea`**：让每个选项都能追溯到检索回执，体现"先检索再发言"。
- 选项上限放宽到 5 个：研究方向常有 4 个以上，再多会增加用户负担。

`effect`：`.readOnly`，计划模式下可用。决策屏障参考 Reasonix：如果同一条 assistant 消息里 `ask_user` 与其他工具调用并存，其他调用一律拒绝执行，并返回"等用户回答后再运行"，然后 `ask_user` 挂起等待。

#### 数据类型（建议放在 `Agent/Ask.swift`，全部 Codable，字段名使用稳定的 snake_case，便于 Tauri 前端直接复用）

```swift
public struct AskRequest: Codable, Sendable, Identifiable {
    public var id: String            // = tool_use id
    public var agentId: String
    public var questions: [AskQuestion]
    public var createdAt: Date
}
public struct AskQuestion: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case single, multi, text }
    public enum Reason: String, Codable, Sendable { case userDecision = "user_decision", missingValue = "missing_value", direction }
    public var id, header, question: String
    public var kind: Kind
    public var reason: Reason
    public var options: [AskOption]
    public var allowOther: Bool
    public var placeholder: String?
    public var optional: Bool
}
public struct AskOption: Codable, Sendable {
    public var label: String
    public var description: String?
    public var recommended: Bool
    public var evidence: [String]
    public var idea: String?
}
public enum AskOutcome: Codable, Sendable {
    case answered([AskAnswer])   // 部分作答也走这里，未答的题不出现在列表里
    case dismissed(note: String?)// 用户关掉卡片，或改为直接回复
    case timedOut(seconds: Int)  // 用户设置了超时
    case unavailable             // 无界面运行，或定时任务
}
public struct AskAnswer: Codable, Sendable {
    public var questionId: String
    public var selected: [String]    // 所选 label
    public var other: String?        // "其他"里填写的文字
    public var text: String?         // 填空题的答案
    public var note: String?         // 单选题附加的备注
}
```

#### 事件与服务

```swift
// AgentEvent 新增
case askRequested(AskRequest)
case askResolved(id: String, outcome: AskOutcome)   // 用于封存卡片、多客户端同步、记录笔记

// SessionServices 新增，与 requestPermission 并列
public var requestAnswer: @Sendable (AskRequest) async -> AskOutcome = { _ in .unavailable }
let askQueue = AskQueue()   // 一次只显示一张卡；后台任务发起的提问也排队
```

- **持久化**：未回答的提问写入 `state/asks.json`。应用在等待期间退出后，下次恢复会话时，task 的状态显示为"Needs your answer"。由于原先挂起的 `await` 已经丢失，用户的回答会作为一条 `<ask_answer id="…">` 用户消息注入，模型照常继续。这与 Claude Code SDK "defer 后再恢复"的思路相同。
- **TaskStage**：`Facts` 新增 `pendingAsk: String?`，取各题 header 拼接而成，优先级与 `permissionAsk` 相同。
- **Goal**：目标处于 active 状态时调用 `ask_user`，自动执行 `hostWait(header)`；收到 `askResolved` 后执行 `userReplied()`。`nextRound` 生成的续写提示里，"需要用户决定"一句改为引导模型使用 `ask_user`。
- **审计**：记录两条日志：`services.log("ask", actor: "agent", …)` 和 `services.log("ask_answer", actor: "user", …)`。回答写入回执，模型之后修改计划时可以引用，例如 `rationale: "user chose direction (r31)"`。这样计划变更有据可查，不会被误判为偷偷缩小范围；但如果是在看到结果之后修改判据，仍然按现有规则记为 deviation。
- **CLI**：`sievesci-cli/main.swift` 按 `requestPermission` 的写法实现终端交互：显示编号选项，输入数字（多选用逗号分隔），也可以直接输入文字作为"其他"，空行表示跳过。无界面的 `-p` 运行和定时任务返回 `.unavailable`。

#### 给模型的返回文本（参考 Reasonix 的措辞，四种结果分别说明）

```
<ask_answer id="toolu_…">
用户回答：
- 研究方向：比较三种降解途径；其他："也看一下自噬"
- 物种与样本：小鼠肝脏，n=6
- 预算：（未作答，不要假定任何选项）
</ask_answer>
```

- `dismissed`："用户关闭了提问，意思是不要替他做决定，先聊一聊。不要选择任何选项，也不要继续推进，等待用户的下一条消息。"
- `timedOut`："这是超时，不是用户的选择。可以先做不依赖这个决定的部分，并在回复里写明你采用了什么假设、缺少哪个决定。"
- `unavailable`："本次运行没有交互用户。不要替用户决定；做完不依赖这个决定的部分，在回复里列出缺少的决定。"

#### 提示词策略（加到 `SystemPrompts.main`）

系统提示词是冻结的，修改会让所有会话的前缀缓存失效一次，这可以接受。规则保持精简：

```
# Asking the user
Use `ask_user` only for what the user alone can supply: a choice between real alternatives
(scope, organism, data, method family, what decision the work informs) or a value the request
never gave. Never for what a search, a file or a tool can answer. When a request is too vague
to plan: run a few background searches first, brainstorm candidate directions, then ask once
with 2–4 grounded directions (cite evidence per option), plus any missing values as `text`
questions. Put your recommended option first. One ask per turn; do not ask again what was answered.
```

#### host 侧约束

- `reason == direction` 的提问必须先通过 `requireGrounding("asking the user to choose a direction")`。没有检索就提方向时，host 拒绝并提示"先检索，再给有依据的选项"。
- 计划制定之前最多提问 3 次，超过后 host 拒绝，避免用提问代替工作。
- 检查者的提示词新增一条信号："向用户询问了本可通过检索得到的事实"，严重程度为 low。

#### 界面卡片规格（只描述，本文不改界面代码）

卡片放在对话流里，显示于触发提问的那条 assistant 消息下方：

- 多道题用标签页（取 header）或步进器切换，标签上显示答题进度。
- 单选题用单选框，多选题用复选框；推荐项排在第一位，带"推荐"标记；`description` 显示为灰色副文本；`evidence` 显示为可点击的 `[@key]` 或 `r12` 标签，点击后打开文献或回执。
- `allow_other` 为真时，末尾自动添加"其他"项，选中后展开单行输入框。text 题直接显示输入框，带 placeholder。
- 按钮：**提交**（主按钮）、**跳过本题**（仅 `optional` 题显示）、**不用选，直接聊**（对应 `dismissed`）。快捷键：数字 1–9 选择，Enter 提交，Esc 等同"直接聊"。
- 草稿保存在本地。答完后卡片封存，只读显示所选答案。如果 `askResolved` 由另一个客户端触发，同样封存。
- 视觉风格遵循 `docs/DESIGN_LANGUAGE.md` 的标本卡风格，按钮等宽右对齐，输入框带边框。
- 跨平台：事件和请求体都是 JSON，SwiftUI 版本和将来的 Tauri/Web 版本渲染同一套 schema。

### 3.3 A：头脑风暴与做梦

#### 想法登记（新增 `Research/IdeaLedger.swift`）

```swift
public struct Idea: Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case raw, merged, triaged, noveltyChecked, promoted, discarded
    }
    public enum Novelty: String, Codable, Sendable {
        case notFoundInSearch = "not_found_in_search"  // 不写"novel"，只写"在已检索范围内未发现"
        case incremental, known
    }
    public var id: String                 // I1、I2……
    public var statement: String
    public var mechanism: String
    public var test: String               // 用什么实验或分析检验
    public var falsifier: String          // 什么结果会否定它
    public var operator_: String          // 产生它的算子：analogy、facet、invert、seed、evolve:<id>……
    public var seeds: [String]            // 种子概念与 RNG seed，用于复现
    public var evidence: [String]         // 生成时依据的 [@key] 或回执
    public var noveltyReceipts: [String]  // 新颖性检查用到的检索回执
    public var closestPrior: [String]     // 最接近的已有工作，形如 [@key]
    public var novelty: Novelty?
    public var rank: Double?              // Bradley–Terry 得分
    public var status: Status
    public var origin: String             // 来源会话：session、brainstorm:<label>、dream:<date>
    public var createdAt: Date
}
// AgentEvent 新增
case ideasChanged([Idea])
```

想法存放在 `state/ideas.json`。做梦产生的想法存放在工作区级别的 `.sievesci/ideas/`。

#### 工具（尽量少加）

- `idea`：动作包括 `add`（批量）、`update`、`discard`、`list`、`promote`。
  - `promote` 把想法转成 `Hypothesis`，host 检查以下条件：
    1. `noveltyReceipts` 至少 3 条，且都在想法创建之后产生，属于 `literature_search` 或 `web_search`；
    2. `novelty != known`；
    3. 预测和证伪标准不能为空；
    4. 检查者的 ideation 评审结论不是 block。
  - 不满足时拒绝，并说明缺了什么。
- `ideation_seeds`：从受控来源抽取 k 个概念，可选来源包括 `library`（任务文献库的关键词和方法）、`mesh`、`go`、`chebi`、`graph_far`（`paper_graph` 两跳以外的邻居）。种子固定且写入回执，所以可以复现。这一工具替代"随机 token"。
- 不新增锦标赛工具，直接用 `dispatch rank`。

#### 发散算子（写进新技能 `brainstorm/SKILL.md`，同时补进 `hypothesis-tournament` 的第 2 步）

| 算子 | 做法 | 证据强度 |
|---|---|---|
| `facet` 要素重组 | 从文献库中的论文抽取目的、机制、评估三类要素，跨论文重组 | 中（Scideator 用户研究） |
| `analogy` 跨领域类比 | 把问题抽象成与具体领域无关的描述，再到远端领域检索类比（`graph_far` 和 `web_search`） | 中（多样性提高；领域集中的问题需要靠种子缓解） |
| `seed` 种子扰动 | 用 `ideation_seeds` 抽取 2–3 个概念作为强制联想的刺激 | 低（随机刺激只提高表面新颖度），必须配合后续检索 |
| `invert` 反向假设 | 列出领域里的 3–5 条核心假设，逐条否定，再追问"如果否定成立，能观察到什么" | 低（没有找到专门评估） |
| `verbalized` | 一次要求生成 N 个想法并给出各自的概率，保留低概率的尾部想法 | 中（Verbalized Sampling） |
| `parallel+merge` | 用 `dispatch map` 让 N 个 worker 独立发散，可以使用不同种子或不同模型，再由 main 合并并注明出处 | 中（Virtual Lab 的做法） |
| `evolve` | 采用 co-scientist 的六种进化策略，生成新想法与原想法同场竞争 | 中（co-scientist） |

#### `/brainstorm` 流程

`/brainstorm [主题] [--n 20] [--ops facet,analogy,invert,seed] [--rounds 2]`，不带参数时使用当前任务的主题。

1. **检索与证据摘要**：通过检索闸，得到 5–10 篇关键文献，并用 `paper_fetch` 获取全文。
2. **发散**：`dispatch map`，每个 worker 分配一个算子或一组种子，每人生成 4–6 个想法，总数为 `--n`。每个想法都要写明机制、检验方法和证伪条件，并引用证据。
3. **去重（Proximity）**：host 侧先做低成本的词项 Jaccard 去重，阈值待定；再由 main 合并语义重复的想法，状态记为 `merged`，保留来源。界面上显示去重前后的数量，即不重复率；Si 等人的数据表明这个比例可能很低。
4. **初排**：`dispatch rank`，标准为"依据是否扎实、机制是否具体、在现有条件下是否可检验"，排名用 Bradley–Terry。
5. **新颖性检查**：对排名前三分之一的想法执行 `dispatch map`，每个想法跑 5–10 个查询，阅读最近邻文献，给出 `not_found_in_search`、`incremental` 或 `known` 的判断。判断为 known 的直接丢弃。
6. **检查者复核**：发起一次 `Supervisor` 的 `ideation` 评审。检查者拿到想法、查询列表和最近邻文献，重点核实"是否把已有工作误判为新颖"（这是 AI Scientist 的教训），必要时要求补充检索。
7. **进化**：对存活的想法进化一到两轮，再排名；前三名不再变化时提前停止。
8. **元评审**：总结反复出现的弱点，写进计划或 LESSONS 提案。
9. **交给用户**：用 `ask_user` 让用户勾选要推进的想法（`kind: multi`，`reason: direction`，每个选项带 `idea: I7` 和证据），也可以要求"再发散一轮"或填写其他想法。
10. 用户选中的想法经 `idea promote` 变为假设，之后走正常研究流程，最终由 `claim_finding` 交给验证者盲法复核。

在报告和对话中，想法一律标为**推测**，新颖性一律写成"在 N 个查询、M 篇文献范围内未发现先例"，不写"首次""新颖"。这与系统提示词中区分"测量结果、推断、推测"的规则一致。

#### 触发方式

- **用户主动**：`/brainstorm`；用户在对话里明确要想法，例如"有什么新思路""帮我想想"，由模型调用技能。
- **澄清流程内**：指令模糊时执行轻量版，只做第 1–3 步并生成 8–12 个想法，然后直接用 `ask_user` 提问，不做锦标赛。
- **host 提示（只提示，不自动执行）**：
  - `/goal` 连续两轮被判定为重复，进入 waiting 状态时，在通知里提示"可以运行 /brainstorm 换个思路"；
  - 某条结论被验证为 refuted 后，提示可以针对替代假设做一次头脑风暴。
- **后台做梦**：`/dream`，见下一节。

#### `/dream`：后台做梦（第 4 期，默认关闭）

`/dream on [daily 03:00] | off | status | now | preview`

- **实现**：复用 `Scheduler`，在 LaunchAgent 中以 `sievesci -p` 运行。权限强制为 **plan 模式**：只读，允许检索，不能执行代码，也不能写工作区。唯一的写入位置是 `.sievesci/ideas/` 和 `.sievesci/dreams/`。设置 token 上限和费用上限（复用 `QuotaService` 的计费），超出即停止。
- **三个阶段**（借用 OpenClaw 的命名，内容按科研场景重新设计）：
  1. **light（整理）**：收集最近 N 天各任务中未解决的问题、被驳倒或不确定的结论、存在争议的观点、检查者反复指出的问题，以及 `/schedule` 文献监测发现的新论文。这一阶段不调用模型，只读取状态文件。
  2. **REM（联想）**：在整理出的材料之间跨任务找联系；用 `ideation_seeds` 加 `facet` 或 `analogy` 算子生成 5–10 个想法；对新论文问一句"它能否解决某个未解决的问题"。
  3. **deep（筛选）**：去重，做轻量新颖性检查（每个想法 3 个查询），排名，保留前 3 个。
- **产出**：
  - `.sievesci/dreams/YYYY-MM-DD.md` 灵感簿，给人读，包含每个想法的来源材料、种子和检索记录；
  - `ideas.json` 新增条目，`origin: dream:<date>`，状态为 `triaged`；
  - 可选的 Evolution 提案，例如"把某条反复出现的检查者问题加入 LESSONS"，必须经用户批准，**不直接写记忆**。
- **呈现**：下次打开该工作区时，显示一条通知"昨晚产生了 3 个想法"，点开后是一张 `ask_user` 卡片（多选：推进、放弃、再看看）。
- **安全闸**（参考 OpenClaw）：
  - 只读取来源为本工作区的材料，网页内容只作为检索证据，不作为指令；
  - 做梦产生的想法永远不能跳过 `promote` 闸门；
  - 做梦从不修改计划和结论。
- **为什么放在最后**：它的价值有两部分。一是"利用空闲时间提前检索和整理"，这部分有间接证据（Sleep-time compute）；二是"产生好想法"，这部分目前没有证据。所以先把 `/brainstorm` 的质量指标测出来（见第 5 节），再决定是否默认开启。

### 3.4 与检查者、验证者的衔接

| 环节 | 谁负责 | 看什么 | 能做什么 |
|---|---|---|---|
| 澄清提问 | 检查者，在回合结束时 | 是否先检索再提问；选项是否有依据；是否把能查到的事实拿来问用户 | 给出 low 或 medium 问题，要求修改 |
| 新颖性判断 | 检查者，`ideation` 评审 | 查询是否覆盖同义词、机制、方法和物种；最近邻文献是否真的读过（核对 `paper_read` 回执）；known 的想法是否被误标 | revise（补充检索）或 block（明显把已知工作当成新的） |
| 想法提升为假设 | host 闸门加检查者 | 检索回执的时间顺序、预测和证伪标准 | 拒绝提升 |
| 假设执行后形成结论 | 验证者（现有流程） | 看不到 main 的代码，从原始数据独立复现 | verified、refuted 或 inconclusive |
| 讨论 | `respond_review` 和 `Deliberation`（现有） | main 可以拿新的检索证据反驳新颖性质疑 | 讨论不收敛时标为 contested |

验证者**不参与**想法阶段：想法没有数据可以复现，让验证者介入会稀释它的盲法职责。

生成与评判分离：发散由 worker 完成，可以用较便宜或不同的模型；排名用 `dispatch rank`，每次比较都是全新的上下文；新颖性由检索结果决定，并由检查者复核。Si 等人的研究和 AI Scientist 的评测都表明模型自评不可靠，所以**最终判断不交给生成想法的同一个上下文**。

---

## 4. 分阶段实现计划与工作量

工作量按一名熟悉代码库的开发者估算，"天"指实际开发日，包含测试。

| 期 | 内容 | 涉及文件 | 工作量 |
|---|---|---|---|
| **1. ask_user 核心** | `Ask.swift` 中的类型；`AskUserTool`；`requestAnswer` 和 `AskQueue`；`askRequested`、`askResolved` 事件；`asks.json` 持久化与恢复；`TaskStage` 与 `Goal` 的衔接；审计和回执；CLI 交互；单元测试（四种结果、决策屏障、只允许 main 调用、恢复会话） | `Agent/Ask.swift`（新）、`Tools/BuiltinTools.swift`、`Agent/AgentEvents.swift`、`Agent/SessionServices.swift`、`Agent/AgentSession.swift`、`Agent/TaskStage.swift`、`Agent/Goal.swift`、`sievesci-cli/main.swift`、`Tests/` | 2.5–3 天 |
| 1b. 卡片界面 | SwiftUI 卡片（按 3.2 节规格），在对话页的修复会话合并后再做，避免冲突 | `Sources/SieveSciApp/`（`AppModel+Events.swift` 等） | 2 天 |
| **2. 澄清流程** | 系统提示词增加"Asking the user"一节；`direction` 提问走检索闸；计划前的提问次数上限；检查者新增一条信号；新增 `clarify` 技能和 `/clarify` 命令；评测样例：模糊指令应先检索再提问，清楚的指令不应提问 | `Agent/SystemPrompts.swift`、`Research/ResearchProtocol.swift`、`Research/Supervisor.swift`、`Resources/skills/clarify/`（新）、`Agent/SlashCommands.swift`、`Eval/` | 1.5–2 天 |
| **3. 头脑风暴** | `IdeaLedger` 与 `ideasChanged` 事件；`idea` 工具及 promote 闸门；`ideation_seeds`（文献库关键词与 `graph_far`；MeSH、GO、ChEBI 词表随包附带或在线查询，需要评估许可与体积）；Jaccard 去重；`ideation` 评审类型；新增 `brainstorm` 技能并更新 `hypothesis-tournament`、`virtual-lab-meeting`（加入并行加合并）、`novelty-check`（输出改为 not_found_in_search、incremental、known）；`/brainstorm` 与 `/ideas` 命令；想法列表界面（另算 1–2 天） | `Research/IdeaLedger.swift`（新）、`Tools/ResearchTools.swift`、`Research/Supervisor.swift`、`Resources/skills/*`、`Agent/SlashCommands.swift` | 4–5 天 |
| **4. 做梦** | `/dream` 复用 `Scheduler`；强制 plan 模式、限定写入目录、预算上限；light、REM、deep 三阶段的提示词与状态读取；灵感簿；打开工作区时的提醒与卡片；`preview` 只显示不写入；可选的温度参数（逐家核实厂商是否支持） | `Agent/Scheduler.swift`、`sievesci-cli/main.swift`、`Agent/Dream.swift`（新）、`LLM/*`（温度，可选） | 3–4 天 |
| **5. 评测（持续进行）** | 见下一节 | `Eval/` | 每期结束时补 0.5 天 |

合计：核心层约 11–14 天，界面约 3–4 天。第 1 期完成后就可以单独发布；第 2 期依赖第 1 期；第 3 期的轻量版（不含 `IdeaLedger`，只用技能和 `ask_user`）可以和第 2 期一起上线。

**跨平台**：所有新类型都是 Codable 的 JSON，界面只消费 `askRequested`、`askResolved`、`ideasChanged` 三个事件，并通过一个 `answerAsk(id, outcome)` 入口回传答案。将来的 Tauri 前端可以直接复用这套接口。现有的 `AgentEvent` 本身还不是 Codable，跨平台时需要统一做一层 wire 编码，这不属于本方案的范围，但新增的类型已经按 wire 格式设计。

---

## 5. 如何判断有没有用

以下指标在第 3 期之后开始记录，写进 notebook 和 `/cost` 旁边的统计：

- **不重复率**：去重后的数量除以生成总数。如果低于 20%，说明发散算子没有起作用。
- **新颖性误判率**：被检查者推翻的 not_found_in_search 判断所占比例。抽样时由人工复核一部分。
- **known 比例**：新颖性检查中判为 known 的比例。比例很高说明发散前的检索不充分。
- **采纳率**：用户在卡片上选择推进的想法所占比例；做梦产生的想法单独统计。
- **转化率**：想法提升为假设、再到结论 verified 的比例。这是唯一接近"想法真有价值"的指标，样本会很少，需要长期积累。
- **澄清质量**：提问后用户选择"直接聊"的比例（太高说明问得不对）；提问前检索次数为 0 的比例（应当为 0）；清楚指令被误问的比例（在评测集中测量）。

---

## 6. 未核实与待定事项

- ChatGPT 的澄清问题是否以选项卡片形式呈现：没有找到官方说明，现有资料显示为文本提问。
- OpenClaw 的"随机 token 组合"：官方功能中没有，出处不明。
- Virtual Lab 论文正文中关于并行会议的描述：网页抓取被内容过滤拦截，本文依据其官方仓库代码（温度 0.8/0.2、5 场并行、3 轮讨论）。
- Sakana AI Scientist v2 的独立审计：只有 NeurIPS 2026 的投稿页面，尚未确认是否经过同行评审。
- 各厂商在开启思考模式时能否设置 temperature：需要在第 4 期实现时逐一核实。
- MeSH、GO、ChEBI 词表的离线打包许可与体积：第 3 期开始前评估。
- 去重的 Jaccard 阈值、提问次数上限等参数：需要用评测集调整。

## 8. 实现状态（2026-11-04）

已实现的部分，及其与上文方案不同之处：

| 部分 | 位置 | 说明 |
|---|---|---|
| `ask_user` 工具 | `Agent/Ask.swift`、`Tools/IdeationTools.swift` | 单选、多选、填空；"其他"由前端自动添加；推荐项排第一；四种结果文案分别对应作答、关掉卡片、超时、无人可问。只允许 main 调用；`direction` 类提问先过检索闸；计划前最多问 3 次 |
| 决策屏障 | `AgentSession.runTools` | 同一步里与 `ask_user` 一起发出的其他调用一律不执行 |
| 等待与恢复 | `AskCenter` | 挂起等待用户；待答问题写入 `state/asks.json`。应用重启后卡片仍在，回答作为下一条用户消息送达（`Workbench.answerAsk`） |
| 事件 | `AgentEvents.swift` | `askRequested`、`askResolved`、`brainstormChanged`、`ideasChanged`，数据类型全部 Codable |
| 任务状态 / 目标 | `TaskStage`、`GoalTool` | 有待答问题时侧边栏显示"等你回答"；目标激活时提问自动让目标等待，作答后恢复 |
| 想法登记 | `Research/Ideas.swift` | 词项 Jaccard 去重，阈值 0.6（中文按字的二元组）；新颖性判断需要至少 3 次想法创建之后的成功检索；判为 known 自动搁置 |
| `brainstorm` 工具 | `IdeationTools.swift` | 包括 start、stage、end。设置关闭时，自主 start 被拒绝；`/brainstorm` 和 `/dream now` 不受影响 |
| `idea` 工具 | 同上 | 包括 add、list、discard、rank、novelty、promote。promote 先检查闸门条件，再发起检查者的 `ideation` 评审，通过后调用 `ResearchProtocol.addHypothesis` 登记假设；未改动就重试会被拒绝 |
| `ideation_seeds` | 同上 | 种子来源：文献库词项、文献库中与主题最远的论文、约 90 个跨领域机制词。使用 SplitMix64 和记录下的种子，可以复现 |
| 收束 / 停止 | `IdeaLedger.requestWrapUp`、`Workbench.interrupt` | "收束"在下一步的工具结果后附加一次 `<brainstorm_wrap_up>`；"停止"中断当前回合，并把本次头脑风暴标记为已停止 |
| 每回合上下文 | `AgentSession.render` | 进行中时写入主题、阶段和存活想法数；设置关闭时注明"autonomous brainstorming: off" |
| 提示词 | `SystemPrompts` | main 新增"Asking the user""Brainstorming"两节；checker 新增 ideation 评审规则 |
| 技能 | `Resources/skills/` | 新增 `brainstorm`、`clarify`；更新 `hypothesis-tournament`、`virtual-lab-meeting`（并行加合并）、`novelty-check`（不写"新颖"） |
| 命令 | `SlashCommands` | `/brainstorm`、`/clarify`、`/ideas [dream]`、`/dream on [daily HH:MM]\|off\|now\|status` |
| 做梦 | `DreamProtocol`、`DreamInbox`、`Scheduler` | 定时任务新增 `mode` 字段，做梦任务以 plan 模式（只读）运行；结束时写 `.sievesci/dreams/<日期>.md` 和收件箱；不能登记假设；下次打开工作区时提醒 |
| 界面 | `Views/AskPrompt.swift`、`Views/BrainstormPanel.swift` | 规格见 `docs/DESIGN_LANGUAGE.md` 第 6 节。设置 → 角色页"头脑风暴"一节有开关（`AppConfig.autoBrainstorm`，默认开）。演示：`SIEVESCI_UI_DEMO=1` 加 `SIEVESCI_UI_BRAINSTORM=1` 或 `SIEVESCI_UI_ASK=1` |
| CLI | `sievesci-cli/main.swift` | 交互模式下显示编号选项（多选用逗号分隔，直接输入文字即"其他"，q 表示关掉）；`-p` 运行返回无人可问 |
| 测试 | `Tests/SieveSciCoreTests/BrainstormAndAskTests.swift` | 解析、四种结果、无人可问、等待与恢复、只允许 main、方向提问的检索闸、决策屏障、去重、新颖性闸门、自主开关、收束、promote 全流程、种子可复现 |

尚未做的：

- 做梦产生的想法目前只能用 `/ideas dream` 查看，还没有 `ask_user` 采纳卡片；
- 第 5 节的统计指标；
- 温度参数；
- 提问超时设置：核心已支持 `AskCenter.timeout`，界面还没有入口；
- 这些交互还没有评测样例（`Eval/`）。

## 7. 来源

- OpenClaw Dreaming 官方文档：https://docs.openclaw.ai/concepts/dreaming.md
- ClawHub `dreaming` 社区技能：https://clawhub.ai/briancolinger/dreaming
- Claude Code AutoDream（二手）：https://claudefa.st/blog/guide/mechanics/auto-dream ；https://www.implicator.ai/anthropic-adds-auto-dream-to-claude-code-fixing-memory-decay-between-sessions
- Towards an AI co-scientist：https://arxiv.org/abs/2502.18864 ；博客 https://research.google/blog/accelerating-scientific-breakthroughs-with-an-ai-co-scientist
- Evaluating Sakana's AI Scientist：https://arxiv.org/abs/2502.14297 ；v2 审计投稿页 https://neurips.cc/virtual/2026/156512
- Virtual Lab 代码：https://github.com/zou-group/virtual-lab ；论文 https://www.nature.com/articles/s41586-025-09442-9 ；预印本 https://www.biorxiv.org/content/10.1101/2024.11.11.623004v1
- Can LLMs Generate Novel Research Ideas?：https://arxiv.org/abs/2409.04109
- The Ideation–Execution Gap：https://arxiv.org/abs/2506.20803
- Is Temperature the Creativity Parameter of LLMs?：https://arxiv.org/abs/2405.00492
- Verbalized Sampling：https://arxiv.org/abs/2510.01171
- Beyond Divergent Creativity（随机基线与 DAT）：https://arxiv.org/abs/2601.20546
- Unlocking LLM Creativity in Science through Analogical Reasoning：https://arxiv.org/abs/2605.11258
- On the Diversity of Analogy Making in LLMs：https://arxiv.org/abs/2608.03233
- Scideator：https://arxiv.org/abs/2409.14634
- SciMON：https://aclanthology.org/2024.acl-long.18
- Sleep-time Compute：https://arxiv.org/abs/2504.13171
- Claude Agent SDK，Handle approvals and user input：https://code.claude.com/docs/en/agent-sdk/user-input
- DeepSeek-Reasonix 源码：https://github.com/esengine/DeepSeek-Reasonix （`internal/runtime/agent/ask.go`、`internal/contract/eventwire/ask.go`、`desktop/frontend-next/src/ui/cards/AskCard.tsx`、`AskFreeText.tsx`）
- OpenAI deep research API 指南：https://developers.openai.com/api/docs/guides/deep-research
- OpenAI 帮助中心 deep research FAQ：https://help.openai.com/en/articles/10500283-deep-research-faq
- ChatGPT Intelligent UI（二手，未核实）：https://www.trendingtopics.eu/gpt-6-chatgpt-intelligent-ui-everyone/
