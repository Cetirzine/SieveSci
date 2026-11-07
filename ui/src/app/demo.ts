// Demo scenes for UI work and parity screenshots, ported from DemoContent.swift: the same sample
// session the SwiftUI app shows with SIEVESCI_UI_DEMO=1. Open with ?demo=<scene>, where scene is
// chat (default), welcome, empty, folders, folders-collapsed, inspector, tab-<tab>, settings-<pane>;
// &appearance=light|dark.
import type { JsonObject } from "../serve";
import { showBrainstorm, brainstormStages, type Idea, type BrainstormState } from "./model";
import { initialState, setState, type AppState, type FileDiff, type ItemKind, type ToolCallView, type TranscriptItem, type InspectorTab } from "./model";

/** Line diff with context (a small LCS; demo-sized inputs only). */
export function makeDiff(path: string, oldText: string | null, newText: string, context = 3): FileDiff {
  const a = oldText ? oldText.split("\n") : [], b = newText.split("\n");
  const n = a.length, m = b.length;
  const lcs = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
  const lines: FileDiff["hunks"][number]["lines"] = [];
  let i = 0, j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) { lines.push({ kind: "context", text: a[i], old: i + 1, new: j + 1 }); i++; j++; }
    else if (j < m && (i >= n || lcs[i][j + 1] >= lcs[i + 1][j])) { lines.push({ kind: "added", text: b[j], old: null, new: j + 1 }); j++; }
    else { lines.push({ kind: "removed", text: a[i], old: i + 1, new: null }); i++; }
  }
  const changed = lines.map((l, k) => (l.kind !== "context" ? k : -1)).filter((k) => k >= 0);
  const keep = new Set<number>();
  for (const k of changed) for (let d = -context; d <= context; d++) if (k + d >= 0 && k + d < lines.length) keep.add(k + d);
  const hunks: FileDiff["hunks"] = [];
  let cur: FileDiff["hunks"][number] | null = null;
  lines.forEach((l, k) => {
    if (!keep.has(k)) { cur = null; return; }
    if (!cur) { cur = { header: `@@ -${l.old ?? 0} +${l.new ?? 0} @@`, lines: [] }; hunks.push(cur); }
    cur.lines.push(l);
  });
  return { path, hunks, added: lines.filter((l) => l.kind === "added").length, removed: lines.filter((l) => l.kind === "removed").length, isNewFile: oldText === null, isBinaryOrLarge: false };
}

export function demoScene(): string | null {
  return new URLSearchParams(location.search).get("demo");
}

export function loadDemo(scene: string) {
  const now = Date.now();
  const t = (s: number) => now - s * 1000;
  let n = 0;
  const item = (kind: ItemKind, id = `d${++n}`): TranscriptItem => ({ id, kind, at: now });
  const tool = (id: string, name: string, summary: string, o: { output?: string; error?: boolean; receipt?: string; start: number; dur: number | null; live?: string[]; diff?: FileDiff }): TranscriptItem => {
    const call: ToolCallView = { id, name, summary, input: {} as JsonObject, output: o.output ?? "", isError: o.error ?? false, receipt: o.receipt,
      started: t(o.start), ended: o.dur === null ? undefined : t(o.start - o.dur), live: o.live ?? [], diff: o.diff };
    return item({ type: "tool", call }, id);
  };
  const ws = "/private/tmp/crispr-offtarget";
  const kinase = "/Users/demo/Research/kinase-screen";
  const oldPy = "import pandas as pd\n\ndef rate(df):\n    return df['indels'] / df['reads']\n";
  const newPy = "import pandas as pd\n\ndef rate(df):\n    reads = df['read_count']\n    return df['indel_reads'] / reads.where(reads > 0)\n";
  const fig = `${ws}/figures/offtarget_rates.png`;
  const review = `{"verdict":"pass","issues":[{"severity":"medium","what":"Replicate 2 has 18% fewer reads at OT3","evidence":"hf1_rep2.csv row 3"}],"required_actions":["Report per-replicate rates alongside the pooled rate"],"reasoning":"Design is sound; the read-depth gap does not change the conclusion."}`;

  const s: AppState = {
    ...initialState,
    version: "0.2.1",
    config: { ...initialState.config, permissionMode: "acceptEdits", recentWorkspaces: [kinase, "/Users/demo/Research/metabolomics-2026"],
      folderOpen: scene === "folders" ? { [kinase]: true } : scene === "folders-collapsed" ? { [kinase]: true, [ws]: false } : {} },
    workspace: ws,
    taskId: "emx1-hf1-offtarget",
    tasks: [{ id: "emx1-hf1-offtarget", modified: t(40) }, { id: "guide-design-vegfa", modified: t(26 * 3600) }, { id: "amplicon-qc", modified: t(3 * 86400) }],
    folderTasks: { [kinase]: [{ id: "kinase-hits-2026", modified: t(5 * 3600) }, { id: "ic50-refit", modified: t(6 * 86400) }] },
    taskTitles: {
      "emx1-hf1-offtarget": "Does SpCas9-HF1 reduce off-target editing at EMX1?", "guide-design-vegfa": "Design guides for VEGFA exon 1",
      "amplicon-qc": "QC the amplicon run from March", "kinase-hits-2026": "Rank the screen hits by selectivity", "ic50-refit": "Refit the IC50 curves with a 4PL model",
    },
    meter: { model: "deepseek-v4-pro", contextWindow: 128_000, lastPromptTokens: 41_300, lastOutputTokens: 0, fill: 41_300 / 128_000, cacheHitRate: 118000 / (5200 + 118000 + 9400),
      session: { input: 5200, cacheRead: 118000, cacheWrite: 9400, output: 6100, reasoning: 0 } },
    figures: [fig],
    changedFiles: ["analysis/count_indels.py", "figures/offtarget_rates.png"],
    streams: {
      "checker-a1b2c3": [
        tool("c1", "read_file", "analysis/count_indels.py", { output: "18 lines", start: 300, dur: 1 }),
        tool("c2", "verify_citation", "kleinstiver2016", { output: "DOI resolves; title and year match", receipt: "R-0012", start: 298, dur: 2 }),
        item({ type: "assistant", text: "No blocking issues. The off-target sites match the GUIDE-seq list in Kleinstiver et al. (2016)." }, "c3"),
      ],
      "verifier-77de01": [
        tool("v1", "python", "recompute indel rates from raw amplicon counts", { start: 40, dur: null,
          live: ["loading data/emx1/hf1_rep1.csv (412,088 reads)", "loading data/emx1/hf1_rep2.csv (398,551 reads)", "site OT1: 0.04% (wt 12.8%)"] }),
      ],
      main: [
        item({ type: "user", text: "Does SpCas9-HF1 reduce off-target editing at the EMX1 site compared with wild-type SpCas9? Use the amplicon data in data/emx1/.", attachments: [] }, "u1"),
        item({ type: "thinking", text: "Search the literature for the GUIDE-seq off-target list first, then compute indel rates per site.", started: t(400), ended: t(394) }, "th1"),
        tool("t1", "literature_search", "SpCas9-HF1 off-target EMX1 GUIDE-seq", { output: "6 results\n1. Kleinstiver 2016 Nature\n2. Tsai 2015 Nat Biotechnol", receipt: "R-0007", start: 392, dur: 3 }),
        item({ type: "literature", action: "added", key: "kleinstiver2016", title: "High-fidelity CRISPR–Cas9 nucleases with no detectable genome-wide off-target effects", detail: "Nature 529" }, "l1"),
        tool("t2", "bash", "ls data/emx1", { output: "hf1_rep1.csv\nhf1_rep2.csv\nwt_rep1.csv\nwt_rep2.csv", receipt: "R-0008", start: 385, dur: 1 }),
        tool("t3", "python", "analysis/count_indels.py", { output: "Traceback (most recent call last):\n  File \"analysis/count_indels.py\", line 4, in rate\nKeyError: 'reads'", error: true, start: 380, dur: 2 }),
        tool("t4", "edit_file", "analysis/count_indels.py", { start: 370, dur: 1, diff: makeDiff("analysis/count_indels.py", oldPy, newPy) }),
        tool("t5", "python", "analysis/count_indels.py --plot figures/offtarget_rates.png", { output: fig + "\nrates written for 4 sites", receipt: "R-0010", start: 360, dur: 6 }),
        item({ type: "assistant", text: [
          "Indel rates at the four GUIDE-seq off-target sites, pooled over two replicates. The rate at a site is $r = n_{\\text{indel}} / N$, and the specificity gain is",
          "", "$$\\Delta = \\log_2 \\frac{r_{\\text{WT}}}{r_{\\text{HF1}}} \\approx 8.3 \\quad (p < 10^{-6})$$", "",
          "| Site | Wild-type | SpCas9-HF1 |", "|---|---|---|", "| EMX1 on-target | 38.2% | 36.9% |", "| OT1 | 12.8% | 0.04% |", "| OT2 | 3.1% | below detection |", "",
          "On-target activity is kept (`-1.3` points) while every off-target site drops below 0.1%. I registered this as claim **C2** and dispatched a blind verifier [@kleinstiver2016].",
        ].join("\n") }, "a1"),
        item({ type: "agent", id: "checker-a1b2c3" }, "ag1"),
        item({ type: "review", kind: "plan", verdict: "pass", body: review }, "r1"),
        item({ type: "deliberation", thread: "T1", from: "checker-a1b2c3", to: "main", kind: "disagree", text: "OT3 should not be pooled: replicate 2 is under-sequenced. Report it separately or drop it." }, "d1"),
        item({ type: "commit", hash: "9f3c2ab41e", subject: "Fix indel rate columns; add off-target figure", files: 3 }, "cm1"),
        item({ type: "agent", id: "verifier-77de01" }, "ag2"),
      ],
    },
    cards: {
      "checker-a1b2c3": { id: "checker-a1b2c3", role: "checker", parent: "main", purpose: "Review the analysis plan against the literature", started: t(302), ended: t(290),
        result: "Plan passes: hypotheses are falsifiable, controls cover both replicates." },
      "verifier-77de01": { id: "verifier-77de01", role: "verifier", parent: "main", purpose: "Blind re-analysis of claim C2 from raw reads", started: t(42) },
      "worker-5c9e10": { id: "worker-5c9e10", role: "worker", parent: "main", purpose: "Align the replicate-2 amplicons to the off-target sites", started: t(25) },
    },
    running: true, runStarted: t(42), spinnerVerb: "Pipetting",
    demoAsk: { tool: "bash", summary: "Rscript analysis/stats.R --site EMX1 --test fisher", input: {}, effect: "executes", rememberPattern: "bash(Rscript analysis/stats.R:*)" },
    plan: {
      goal: "Test whether SpCas9-HF1 lowers off-target editing at EMX1 without losing on-target activity.", stage: "verification",
      objective: "Does the high-fidelity SpCas9-HF1 variant cut fewer off-target sites at EMX1 than wild-type, and does it keep on-target editing? Use the GUIDE-seq data in data/emx1.",
      decisions: [
        { at: "2026-11-06T09:12:00Z", topic: "Scope", answer: "EMX1 only; the other loci can wait." },
        { at: "2026-11-06T09:40:00Z", topic: "brainstorm outcome", answer: "Six candidate tests checked; you chose the per-site off-target comparison with Fisher's exact test.", ideas: ["I3"] },
        { at: "2026-11-07T14:05:00Z", topic: "Replicates", answer: "Skip re-sequencing OT3 replicate 2; report it as a limitation." },
      ],
      hypotheses: [
        { id: "H1", statement: "HF1 reduces indel rates at GUIDE-seq off-target sites by at least 10-fold.", prediction: "OT1–OT3 < 0.5%", falsification: "Any off-target site with rate ≥ 10% of wild-type.", status: "supported" },
        { id: "H2", statement: "On-target activity stays within 5 points of wild-type.", prediction: "|Δ| < 5 points", falsification: "On-target drop > 5 points in either replicate.", status: "open" },
      ],
      steps: [
        { id: "S1", title: "Collect the GUIDE-seq off-target list", detail: "", status: "done", checkpoint: false, criteria: "", evidence: ["R-0007"], note: "" },
        { id: "S2", title: "Compute indel rates per site and replicate", detail: "", status: "done", checkpoint: false, criteria: "", evidence: ["R-0010"], note: "" },
        { id: "S3", title: "Blind verification of the main claim", detail: "", status: "in_progress", checkpoint: true, criteria: "", evidence: [], note: "" },
        { id: "S4", title: "Statistics: Fisher's exact test per site", detail: "", status: "pending", checkpoint: false, criteria: "", evidence: [], note: "" },
        { id: "S5", title: "Re-sequence OT3 replicate 2", detail: "", status: "skipped", checkpoint: false, criteria: "", evidence: [], note: "" },
      ],
    },
    claims: [
      { id: "C1", statement: "On-target editing at EMX1 is 38.2% (WT) vs 36.9% (HF1).", successCriteria: "Recomputed from raw reads within 0.5 points.", evidence: ["R-0010"], dataPaths: ["data/emx1"], status: "verified", verdict: "Recomputed 38.1% / 36.9% from raw counts.", verifierReceipts: ["R-0014"] },
      { id: "C2", statement: "HF1 lowers OT1 editing from 12.8% to 0.04%.", successCriteria: "Independent recount from the CSVs reproduces both rates.", evidence: ["R-0010"], dataPaths: ["data/emx1"], status: "verifying", verdict: null, verifierReceipts: [] },
    ],
    contested: [{ thread: "T1", kind: "disagree", issue: "OT3 pooled across replicates with unequal depth", reason: "Replicate 2 has 18% fewer reads at OT3." }],
    jobs: { j1: { id: "j1", label: "Rscript analysis/stats.R", lines: ["Fisher test OT1: p < 1e-12", "Fisher test OT2: p = 3.2e-6", "running OT3…"], running: true, unread: 1 } },
    jobOrder: ["j1"],
    mainTab: "chat", inspectorTab: "files",
    showInspector: scene === "inspector",
    grounding: null,
    modelStatus: { ready: true, text: "Ready: DeepSeek API" },
    searchStatus: { ready: true, text: "Built into DeepSeek API." },
  };
  if (scene.startsWith("tab-")) s.mainTab = scene.slice(4) as InspectorTab;
  if (scene.startsWith("settings")) s.showSettingsPage = true;
  if (scene === "welcome") s.workspace = null;
  if (scene === "empty") {
    s.streams = { main: [] }; s.cards = {}; s.contested = []; s.demoAsk = null; s.running = false;
    s.meter = { ...s.meter, lastPromptTokens: 0, fill: 0, session: { input: 0, cacheRead: 0, cacheWrite: 0, output: 0, reasoning: 0 }, cacheHitRate: 0 };
  }
  if (scene === "brainstorm" || scene === "ask") loadBrainstormDemo(s, scene === "ask");
  setState(s);
}

/** DemoBrainstorm.swift: a brainstorm in its novelty stage, or ("ask") ended, with the card offering its ideas. */
function loadBrainstormDemo(s: AppState, ask: boolean) {
  const now = Date.now();
  const iso = (secondsAgo: number) => new Date(now - secondsAgo * 1000).toISOString();
  s.streams = { main: [
    { id: "bu", at: now - 100_000, kind: { type: "user", text: "Our electrolyte additive stopped helping above 45 °C. Give me some new angles.", attachments: [] } },
    { id: "bt", at: now - 20_000, kind: { type: "thinking", text: "The pool is thin on interface effects.\nAnalogy from load balancing: a second additive that takes over at high temperature. Checking whether dual-additive studies already exist.", started: now - 20_000 } },
  ] };
  s.cards = {}; s.contested = []; s.demoAsk = null; s.running = !ask;
  const idea = (id: string, statement: string, op: string, status: Idea["status"], o: { novelty?: Idea["novelty"]; rank?: number; merged?: string } = {}): Idea => ({
    id, statement, mechanism: "", test: "", falsifier: "", op, seeds: [], evidence: [], status, mergedInto: o.merged, novelty: o.novelty,
    noveltyReceipts: [], closestPrior: [], rank: o.rank, origin: "brainstorm:Bdemo", createdAt: iso(30) });
  s.ideas = [
    idea("I1", "A second additive that only decomposes above 45 °C takes over film formation", "analogy", "checked", { novelty: "not_found_in_search", rank: 1 }),
    idea("I2", "The interphase cracks from thermal mismatch, not chemistry", "invert", "checked", { novelty: "incremental", rank: 2 }),
    idea("I3", "Additive is consumed faster at high temperature; dose it from a reservoir", "seed", "raw", { rank: 3 }),
    idea("I4", "Two additives that switch roles with temperature", "analogy", "merged", { merged: "I1" }),
    idea("I5", "Salt concentration shift changes which species reaches the surface first", "facet", "raw", { rank: 4 }),
    idea("I6", "Coat the cathode instead of relying on the electrolyte", "free", "discarded", { novelty: "known" }),
    idea("I7", "Trace water catalyses additive breakdown above 45 °C", "invert", "raw"),
  ];
  const state: BrainstormState = { id: "Bdemo", topic: "Why the additive fails above 45 °C", reason: "The current hypothesis was refuted at 50 °C", trigger: "auto",
    stage: "novelty", stageNote: "Searching prior work for I1 (dual-additive, temperature-gated film formation)", stagesDone: ["ground", "diverge", "dedupe", "rank"],
    startedAt: iso(95), wrapUpRequested: false, stopped: false };
  if (!ask) { s.brainstorm = state; return; }
  // Ended: the brainstorm becomes a row of the conversation, and the reply continues below it.
  showBrainstorm(s, { ...state, endedAt: iso(0), summary: "Seven ideas, five distinct; I1 found no prior work in 6 searches.", stage: "report", stagesDone: brainstormStages });
  s.streams = { main: [...s.streams.main, { id: "ba", at: now, kind: { type: "assistant", text: "I1 is the strongest lead: no prior work turned up in six searches, and your existing cells can test it. Two quick questions before I plan it." } }] };
  s.pendingAsk = { id: "ask-demo", agent_id: "main", questions: [
    { id: "dir", header: "Direction", question: "Which ideas should I pursue first?", kind: "multi", reason: "direction", allow_other: true, optional: false, options: [
      { label: "Temperature-gated second additive", description: "No prior work found in 6 searches; testable with existing cells", recommended: true, evidence: ["@lee2024additive", "r31"], idea: "I1" },
      { label: "Thermal-mismatch cracking", description: "Incremental on known interphase studies", recommended: false, evidence: ["@chen2023sei"], idea: "I2" },
      { label: "Additive reservoir dosing", description: "Not checked yet", recommended: false, evidence: [], idea: "I3" },
    ] },
    { id: "cells", header: "Cells", question: "Which cells can you test in the next two weeks?", kind: "text", reason: "missing_value", allow_other: false, optional: false, options: [], placeholder: "e.g. 12 coin cells, NMC811/graphite" },
  ] };
}
