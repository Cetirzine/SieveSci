// The web counterpart of the SwiftUI `AppModel` (Sources/SieveSciApp/AppModel*.swift): the same
// state, built from `sievesci serve` events with the same rules (AppModel+Events.swift).
import { useRef, useSyncExternalStore } from "react";
import type { JsonObject } from "../serve";
import { L } from "../i18n";

export type Role = "main" | "checker" | "verifier" | "worker";

export interface DiffLine { kind: "context" | "added" | "removed"; text: string; old: number | null; new: number | null }
export interface FileDiff { path: string; hunks: { header: string; lines: DiffLine[] }[]; added: number; removed: number; isNewFile: boolean; isBinaryOrLarge: boolean }

export interface ToolCallView {
  id: string; name: string; summary: string; input: JsonObject; output: string; isError: boolean; receipt?: string;
  started: number; ended?: number; live: string[]; diff?: FileDiff;
}
export interface AgentCard {
  id: string; role: Role; parent: string; purpose: string; started: number; ended?: number; result?: string;
  /** A reopened task's card: how many steps it took; they are fetched when the card is opened. */
  stepCount?: number; lazy?: boolean;
}
export interface JobNotification { job: string; agentId: string; kind: string; text: string; at: string }

export type ItemKind =
  | { type: "user"; text: string; attachments: string[] }
  | { type: "assistant"; text: string }
  | { type: "thinking"; text: string; started: number; ended?: number; untimed?: boolean }
  | { type: "tool"; call: ToolCallView }
  | { type: "agent"; id: string }
  | { type: "review"; kind: string; verdict: string; body: string }
  | { type: "deliberation"; thread: string; from: string; to: string; kind: string; text: string }
  | { type: "literature"; action: string; key: string; title: string; detail: string }
  | { type: "fileChange"; path: string; diff: FileDiff }
  | { type: "commit"; hash: string; subject: string; files: number }
  | { type: "job"; notification: JobNotification }
  /** A brainstorm that has ended, where it ended: what follows continues below it. */
  | { type: "brainstorm"; state: BrainstormState }
  | { type: "signal"; text: string }
  | { type: "notice"; text: string }
  | { type: "error"; text: string };
export interface TranscriptItem { id: string; kind: ItemKind; at: number }

export interface ContextMeter { model: string; contextWindow: number; lastPromptTokens: number; lastOutputTokens: number; fill: number; cacheHitRate: number;
  session: { input: number; cacheRead: number; cacheWrite: number; output: number; reasoning: number } }
export interface PlanStep { id: string; title: string; detail: string; status: string; checkpoint: boolean; criteria: string; evidence: string[]; note: string }
export interface Hypothesis { id: string; statement: string; prediction: string; falsification: string; status: string }
export interface ResearchPlan { goal: string; background?: string; stage: string; hypotheses: Hypothesis[]; steps: PlanStep[]; rationale?: string; revisions?: { at: string; rationale: string; changedCriteria: string[]; afterResults: boolean }[] }
export interface Claim { id: string; statement: string; successCriteria: string; evidence: string[]; dataPaths: string[]; status: string; verdict: string | null; verifierReceipts: string[] }
export interface Contested { thread: string; kind: string; issue: string; reason: string }
export interface JobState { id: string; label: string; lines: string[]; running: boolean; unread: number; exitCode?: number; seconds?: number }
export interface PermissionAsk { id?: string; tool: string; summary: string; input: JsonObject; effect: string; rememberPattern: string }
export interface AskOption { label: string; description?: string; recommended: boolean; evidence: string[]; idea?: string }
export interface AskQuestion { id: string; header: string; question: string; kind: "single" | "multi" | "text"; options: AskOption[]; allow_other: boolean; placeholder?: string; optional: boolean; reason?: "direction" | "missing_value" | "user_decision" }
export interface AskRequest { id: string; agent_id: string; questions: AskQuestion[] }
export interface TaskEntry { id: string; modified: number }
export interface Idea {
  id: string; statement: string; mechanism: string; test: string; falsifier: string; op: string; seeds: string[]; evidence: string[];
  status: "raw" | "merged" | "checked" | "promoted" | "discarded"; mergedInto?: string; novelty?: "not_found_in_search" | "incremental" | "known";
  noveltyReceipts: string[]; closestPrior: string[]; rank?: number; hypothesisId?: string; origin: string; createdAt: string;
  /** "proven": written in a brainstorm after what works best, checked for evidence instead of novelty. */
  aim?: string; support?: "established" | "partial" | "unproven";
}
export interface BrainstormState {
  id: string; topic: string; reason: string; trigger: "auto" | "user" | "dream"; stage: string; stageNote: string; stagesDone: string[];
  startedAt: string; endedAt?: string; summary?: string; wrapUpRequested: boolean; stopped: boolean;
  /** novel: new ideas, checked for novelty; proven: what works best, checked for evidence. */
  goal?: "novel" | "proven";
}
export const brainstormStages = ["ground", "diverge", "dedupe", "rank", "novelty", "review", "evolve", "report"];
/** A brainstorm's stages: after what works best, an evidence check takes the novelty check's place. */
export const stagesOf = (b: BrainstormState) => (b.goal === "proven" ? brainstormStages.map((s) => (s === "novelty" ? "evidence" : s)) : brainstormStages);
export const ideaIsLive = (i: Idea) => i.status !== "merged" && i.status !== "discarded" && i.novelty !== "known";
export interface Attention { stage: string; label?: string; detail: string; workspace: string; needsPerson?: boolean; showsChip?: boolean }

export type InspectorTab = "activity" | "plan" | "claims" | "library" | "changes" | "files" | "figures" | "jobs" | "history" | "notebook" | "learning";
export type MainTab = "chat" | InspectorTab;
/** The tabs shown under the title (InspectorTab.inMain). */
export const mainTabs: MainTab[] = ["chat", "activity", "plan", "claims", "library", "notebook"];

export interface ModelRef { providerId: string; model: string }
export interface ProviderProfile {
  id: string; displayName: string; family: string; flavor: string; baseURL: string; apiKeyRef: string; auth: string; billing: string;
  defaultModel: string; models: string[]; enabled: boolean; executable?: string; notes: string;
  options: JsonObject; extraBody: JsonObject; modelSettings: JsonObject[];
}
export interface RoleAssignment { mode: "same" | "auto" | "custom" | string; same?: ModelRef; custom: Record<string, ModelRef> }
export interface WebSearchConfig { backend: string; apiKeyRef: string; excludedDomains: string[]; googleCX: string; searxngURL: string }

export interface ModelSpec { id?: string; contextWindow: number; maxOutput: number; supportsImages: boolean; supportsReasoning: boolean }
export interface ModelInfo extends ModelSpec { custom?: boolean; detected?: ModelSpec }
export interface ProviderInfo { ready: boolean; short: string; cliPath: string | null; hasKey: boolean; models: Record<string, ModelInfo> }
export interface QuotaMeter { title: string; value: string; usedFraction: number | null; exhausted: boolean; resetsAt: string | null }
export interface Quota { plan: string | null; note: string | null; summary: string | null; meters: QuotaMeter[]; spend?: { today: number; month: number } }

/** AppConfig as `sievesci serve` sends it (config.get), shared with the macOS app. */
export interface Config {
  providers: ProviderProfile[];
  roles: RoleAssignment;
  webSearch: WebSearchConfig;
  permissionMode: "ask" | "acceptEdits" | "auto" | "plan" | "yolo";
  retention: string;
  effort?: string | null;
  contactEmail: string;
  downloadOAPDFs: boolean;
  groundingRequired: boolean;
  visionHelper?: ModelRef | null;
  recentWorkspaces: string[];
  folderOpen: Record<string, boolean>;
  maxReviewsPerSession: number;
  maxDeliberationExchanges: number;
  autoDelegate: boolean;
  maxParallelWorkers: number;
  sandboxMode: "workspaceWrite" | "workspaceWriteOffline" | "off";
  appearance: "system" | "light" | "dark";
  autoWake: boolean;
  notifyJobs: boolean;
  notifyTurnFinished: boolean;
  notifyPermission: boolean;
  showThinking: boolean;
  autoTitles: boolean;
  autoBrainstorm: boolean;
  autoCheckUpdates: boolean;
  autoInstallUpdates: boolean;
  /** While a turn runs, Enter inserts into it (⌘/Ctrl+Enter queues); off: the other way round. */
  enterInsertsWhileRunning: boolean;
}

export const defaultConfig: Config = {
  providers: [], roles: { mode: "auto", custom: {} },
  webSearch: { backend: "brave", apiKeyRef: "BRAVE_API_KEY", excludedDomains: [], googleCX: "", searxngURL: "http://localhost:8888" },
  permissionMode: "ask", retention: "short", effort: null, contactEmail: "", downloadOAPDFs: true, groundingRequired: true, visionHelper: null,
  recentWorkspaces: [], folderOpen: {}, maxReviewsPerSession: 24, maxDeliberationExchanges: 2, autoDelegate: true, maxParallelWorkers: 3,
  sandboxMode: "workspaceWrite", appearance: "system", autoWake: true, notifyJobs: true, notifyTurnFinished: true, notifyPermission: true,
  showThinking: true, autoTitles: true, autoBrainstorm: true, autoCheckUpdates: true, autoInstallUpdates: true,
  enterInsertsWhileRunning: false,
};

export interface AppState {
  config: Config;
  workspace: string | null;
  taskId: string;
  tasks: TaskEntry[];
  folderTasks: Record<string, TaskEntry[]>;
  taskTitles: Record<string, string>;
  streams: Record<string, TranscriptItem[]>;
  cards: Record<string, AgentCard>;
  meter: ContextMeter;
  running: boolean;
  runStarted: number;
  spinnerVerb: string;
  pendingPermission: PermissionAsk | null;
  demoAsk: PermissionAsk | null;
  pendingAsk: AskRequest | null;
  /** Every question of the open task waiting for an answer, oldest first; `pendingAsk` is the first.
   *  Agents may ask at once: the next one shows when the first is answered or dismissed. */
  askQueue: AskRequest[];
  /** A task being opened (its id, "" for a new one): the sidebar shows it selected and the chat dims
   *  at once, before the engine's answer arrives. */
  openingTask: string | null;
  /** The job the Jobs panel shows, when chosen from elsewhere (a job notification's "Log"). */
  selectedJob: string | null;
  plan: ResearchPlan;
  claims: Claim[];
  contested: Contested[];
  jobs: Record<string, JobState>;
  jobOrder: string[];
  changedFiles: string[];
  figures: string[];
  queued: string[];
  /** Messages inserted into the running turn that the agent has not read yet (it does at its next step). */
  inserting: string[];
  mainTab: MainTab;
  inspectorTab: InspectorTab;
  showInspector: boolean;
  showSettingsPage: boolean;
  sidebarVisible: boolean;
  backgroundTasks: string[];
  backgroundWorkspaces: Record<string, string>;
  attention: Record<string, Attention>;
  grounding: { web: boolean; literature: boolean } | null;
  modelStatus: { ready: boolean; text: string };
  searchStatus: { ready: boolean; text: string };
  lastError: string | null;
  version: string;
  /** Text handed to the composer (start cards, quote in reply), taken once. */
  draft: string;
  commands: { name: string; args: string; summary: string; group?: string }[];
  ideas: Idea[];
  /** Bumped when something the panels show may have changed (they refetch from serve). */
  panelTick: number;
  /** Bumped when KaTeX has loaded, so text with formulas is drawn again. */
  mathVersion: number;
  /** Learning proposals waiting for the user (Learning tab badge). */
  pendingProposals: number;
  /** The open task's running brainstorm (an ended one is a transcript row). */
  brainstorm: BrainstormState | null;
  /** Which key references hold a key (values never leave serve). */
  keys: Record<string, boolean>;
  /** Providers that can run now. */
  usable: string[];
  /** The interface language picked ("system" or a code); serve's texts follow it. */
  languageChoice: string;
  /** Per provider: whether it can run and what it needs, in serve's words, and its models' settings. */
  providerInfo: Record<string, ProviderInfo>;
  /** Plan limits and balances, by provider (Settings → Providers). */
  quotas: Record<string, Quota>;
  accent: "blue" | "violet" | "green" | "orange" | "graphite";
  /** Where serve runs, for wording such as where keys are kept ("macos" until initialize says). */
  platform: "macos" | "windows" | "linux";
  /** Commands can run sandboxed on this system (serve's `initialize`; Seatbelt on macOS only). */
  sandbox: boolean;
  /** A task is open in serve (the app's `bench != nil`). */
  live: boolean;
  settingsPane: "general" | "providers" | "models" | "search" | "research" | "memory" | "schedules";
}

export const verbs = ["Sieving", "Pipetting", "Titrating", "Centrifuging", "Sequencing", "Culturing", "Incubating", "Annealing", "Distilling", "Staining"];

export const initialState: AppState = {
  config: defaultConfig,
  workspace: null, taskId: "", tasks: [], folderTasks: {}, taskTitles: {},
  streams: { main: [] }, cards: {},
  meter: { model: "", contextWindow: 0, lastPromptTokens: 0, lastOutputTokens: 0, fill: 0, cacheHitRate: 0, session: { input: 0, cacheRead: 0, cacheWrite: 0, output: 0, reasoning: 0 } },
  running: false, runStarted: Date.now(), spinnerVerb: "Sieving",
  pendingPermission: null, demoAsk: null, pendingAsk: null, askQueue: [], openingTask: null, selectedJob: null,
  plan: { goal: "", stage: "scoping", hypotheses: [], steps: [] }, claims: [], contested: [],
  jobs: {}, jobOrder: [], changedFiles: [], figures: [], queued: [], inserting: [],
  mainTab: "chat", inspectorTab: "files", showInspector: false, showSettingsPage: false, sidebarVisible: true,
  backgroundTasks: [], backgroundWorkspaces: {}, attention: {}, grounding: null,
  modelStatus: { ready: false, text: "" }, searchStatus: { ready: false, text: "" }, lastError: null, version: "", draft: "", commands: [],
  ideas: [], brainstorm: null, panelTick: 0, pendingProposals: 0, mathVersion: 0,
  keys: {}, usable: [], languageChoice: "system", live: false, settingsPane: "general", providerInfo: {}, quotas: {}, accent: "blue",
  platform: typeof navigator !== "undefined" && /Win/.test(navigator.platform) ? "windows" : typeof navigator !== "undefined" && /Linux/.test(navigator.platform) ? "linux" : "macos",
  sandbox: typeof navigator === "undefined" || /Mac/.test(navigator.platform),
};

// MARK: Store

type Listener = () => void;
let state: AppState = initialState;
const listeners = new Set<Listener>();
export function getState(): AppState { return state; }
export function setState(patch: Partial<AppState> | ((s: AppState) => Partial<AppState>)) {
  state = { ...state, ...(typeof patch === "function" ? patch(state) : patch) };
  listeners.forEach((l) => l());
}
function shallowEqual(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const ka = Object.keys(a), kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  return ka.every((k) => Object.is((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]));
}
const subscribe = (l: Listener) => { listeners.add(l); return () => { listeners.delete(l); }; };

/** Selects from the store; a selection that is shallowly equal to the last one keeps its identity. */
export function useApp<T>(select: (s: AppState) => T): T {
  const cache = useRef<{ value: T } | null>(null);
  return useSyncExternalStore(subscribe, () => {
    const next = select(state);
    if (cache.current && shallowEqual(cache.current.value, next)) return cache.current.value;
    cache.current = { value: next };
    return next;
  });
}

/** model.title(of:): the task's title, else "New task". */
export function titleOf(s: AppState, id: string, newTask: string): string { return s.taskTitles[id] ?? newTask; }

/** Folders are open unless closed (the open workspace) or closed unless opened (the others). */
export function isFolderOpen(s: AppState, path: string): boolean {
  return s.config.folderOpen[path] ?? path === s.workspace;
}

// MARK: Events → transcript (AppModel+Events.swift)

let seq = 0;
const uid = () => `w${++seq}`;
const toolIndex = new Map<string, [string, number]>();
const lastTool = new Map<string, [string, number]>();
const openText = new Map<string, number>();
const openThinking = new Map<string, number>();

export function resetTranscriptIndex() { toolIndex.clear(); lastTool.clear(); openText.clear(); openThinking.clear(); }

export function summary(input: JsonObject): string {
  for (const k of ["command", "query", "path", "ref", "key", "statement", "pattern", "url", "id", "items"]) {
    const v = input[k];
    if (typeof v === "string") return v.slice(0, 160);
  }
  const code = input.code;
  if (typeof code === "string") return (code.split("\n")[0] ?? code).slice(0, 160);
  return JSON.stringify(input).slice(0, 160);
}

function streamKey(s: AppState, stream: string) { return s.streams[stream] === undefined && s.cards[stream] === undefined ? "main" : stream; }

function append(s: AppState, k: ItemKind, stream: string): number {
  const key = streamKey(s, stream);
  const list = [...(s.streams[key] ?? []), { id: uid(), kind: k, at: Date.now() }];
  s.streams = { ...s.streams, [key]: list };
  return list.length - 1;
}

function mutate(s: AppState, stream: string, i: number, f: (k: ItemKind) => ItemKind) {
  const list = s.streams[stream];
  if (!list || i < 0 || i >= list.length) return;
  const copy = list.slice();
  copy[i] = { ...copy[i], kind: f(copy[i].kind) };
  s.streams = { ...s.streams, [stream]: copy };
}

function closeThinking(s: AppState, agent: string) {
  const i = openThinking.get(agent);
  if (i !== undefined) mutate(s, streamKey(s, agent), i, (k) => k.type === "thinking" && k.ended === undefined ? { ...k, ended: Date.now() } : k);
  openThinking.delete(agent);
}

/** Events after which the panels' data (trace, files, history, jobs, library …) may have changed. */
const panelEvents = new Set(["toolFinished", "turnFinished", "supervisorReview", "deliberation", "fileChanged", "committed", "jobFinished",
  "literature", "agentFinished", "integrity", "error"]);
const isDelta = (t: string) => t === "textDelta" || t === "thinkingDelta" || t === "toolProgress" || t === "jobOutput";
let pending: JsonObject[] = [];
let flushScheduled = false;

/** Deltas are buffered and applied ~12 times a second, flushed before any other event (order kept). */
export function deliver(ev: JsonObject) {
  if (isDelta(String(ev.type))) {
    pending.push(ev);
    if (!flushScheduled) { flushScheduled = true; setTimeout(() => { flushScheduled = false; flush(); }, 80); }
    return;
  }
  flush();
  apply([ev]);
}

function flush() {
  if (!pending.length) return;
  const merged: JsonObject[] = [];
  for (const ev of pending) {
    const last = merged[merged.length - 1];
    if (last && (ev.type === "textDelta" || ev.type === "thinkingDelta") && last.type === ev.type && last.agentId === ev.agentId) {
      merged[merged.length - 1] = { ...last, text: String(last.text) + String(ev.text) };
    } else merged.push(ev);
  }
  pending = [];
  apply(merged);
}

function apply(events: JsonObject[]) {
  const s: AppState = { ...state };
  for (const ev of events) handle(s, ev);
  state = s;
  listeners.forEach((l) => l());
}

/** What an integrity signal means, in the interface language (AppModel.signalTitle); the detail stays as detected. */
function signalTitle(kind: string): string {
  const t: Record<string, string> = {
    codeHack: "Questionable code", falseCompletion: "Success claimed after a failure", ignoredError: "Error not mentioned",
    scopeShrink: "Scope reduced", syntheticData: "Synthetic data", ungrounded: "Not backed by evidence",
    harking: "Criteria changed after results", breakthrough: "Strong claim — needs verification", checkpoint: "Checkpoint", ideation: "Idea under review",
  };
  return t[kind] ? L(t[kind]) : kind;
}

function handle(s: AppState, e: JsonObject) {
  const str = (k: string) => String(e[k] ?? "");
  const agent = str("agentId");
  // Events of a task running in the background only move its title; its stage arrives as taskStatus
  // and its transcript is read back when it is opened (AppModel+Events: background benches).
  if (typeof e.task === "string" && e.task !== s.taskId) {
    if (e.type === "titleChanged") s.taskTitles = { ...s.taskTitles, [str("task")]: str("title") };
    return;
  }
  if (panelEvents.has(String(e.type))) s.panelTick++;
  switch (e.type) {
    case "turnStarted":
      // The messages still waiting behind this turn (the queued pills shrink as each one starts).
      if (agent === "main" && Array.isArray(e.queued)) s.queued = e.queued as string[];
      if (e.role === "main" && agent === "main" && !s.running) {
        s.running = true; s.runStarted = Date.now(); s.spinnerVerb = verbs[Math.floor(Math.random() * verbs.length)];
      }
      break;
    case "textDelta": {
      closeThinking(s, agent);
      const i = openText.get(agent);
      if (i !== undefined) mutate(s, streamKey(s, agent), i, (k) => k.type === "assistant" ? { ...k, text: k.text + str("text") } : k);
      else openText.set(agent, append(s, { type: "assistant", text: str("text") }, agent));
      break;
    }
    case "thinkingDelta": {
      const i = openThinking.get(agent);
      if (i !== undefined) mutate(s, streamKey(s, agent), i, (k) => k.type === "thinking" ? { ...k, text: k.text + str("text") } : k);
      else { openText.delete(agent); openThinking.set(agent, append(s, { type: "thinking", text: str("text"), started: Date.now() }, agent)); }
      break;
    }
    case "toolStarted": {
      closeThinking(s, agent);
      openText.delete(agent);
      const input = (e.input ?? {}) as JsonObject;
      const i = append(s, { type: "tool", call: { id: str("id"), name: str("name"), summary: summary(input), input, output: "", isError: false, started: Date.now(), live: [] } }, agent);
      const where: [string, number] = [streamKey(s, agent), i];
      toolIndex.set(str("id"), where);
      lastTool.set(agent, where);
      break;
    }
    case "toolProgress": {
      const at = toolIndex.get(str("id"));
      if (at) mutate(s, at[0], at[1], (k) => k.type === "tool" ? { ...k, call: { ...k.call, live: [...k.call.live, ...((e.lines ?? []) as string[])].slice(-400) } } : k);
      break;
    }
    case "toolFinished": {
      const at = toolIndex.get(str("id"));
      if (at) mutate(s, at[0], at[1], (k) => k.type === "tool" ? { ...k, call: { ...k.call, output: str("output"), isError: e.isError === true, receipt: str("receipt"), ended: Date.now() } } : k);
      break;
    }
    case "fileChanged": {
      const path = str("path");
      if (!s.changedFiles.includes(path)) s.changedFiles = [...s.changedFiles, path];
      const at = lastTool.get(agent);
      if (at) mutate(s, at[0], at[1], (k) => k.type === "tool" && !k.call.diff ? { ...k, call: { ...k.call, diff: e.diff as unknown as FileDiff } } : k);
      break;
    }
    case "assistantMessage": openText.delete(agent); break;
    case "usage": if (agent === "main") s.meter = e.meter as unknown as ContextMeter; break;
    case "integrity":
      for (const sig of (e.signals ?? []) as JsonObject[]) if (Number(sig.severity ?? 0) >= 2) append(s, { type: "signal", text: `${signalTitle(String(sig.kind))} · ${sig.detail}` }, "main");
      break;
    case "supervisorReview": append(s, { type: "review", kind: str("kind"), verdict: str("verdict"), body: str("body") }, "main"); break;
    case "agentStarted": {
      const id = str("id");
      s.cards = { ...s.cards, [id]: { id, role: str("role") as Role, parent: str("parent"), purpose: str("purpose"), started: Date.now() } };
      s.streams = { ...s.streams, [id]: [] };
      append(s, { type: "agent", id }, s.streams[str("parent")] === undefined ? "main" : str("parent"));
      break;
    }
    case "agentFinished": {
      const c = s.cards[str("id")];
      if (c) s.cards = { ...s.cards, [c.id]: { ...c, ended: Date.now(), result: str("result") } };
      break;
    }
    case "literature": append(s, { type: "literature", action: str("action"), key: str("key"), title: str("title"), detail: str("detail") }, agent); break;
    case "committed": append(s, { type: "commit", hash: str("hash"), subject: str("subject"), files: Number(e.files ?? 0) }, "main"); break;
    case "jobOutput": {
      const job = str("job");
      const cur = s.jobs[job] ?? { id: job, label: job, lines: [], running: true, unread: 0 };
      if (!s.jobs[job]) s.jobOrder = [...s.jobOrder, job];
      const lines = (e.lines ?? []) as string[];
      s.jobs = { ...s.jobs, [job]: { ...cur, lines: [...cur.lines, ...lines].slice(-5000), unread: s.inspectorTab === "jobs" ? cur.unread : cur.unread + lines.length } };
      break;
    }
    case "jobFinished": {
      const j = s.jobs[str("job")];
      if (j) s.jobs = { ...s.jobs, [j.id]: { ...j, running: false, exitCode: Number(e.exitCode), seconds: Number(e.seconds) } };
      break;
    }
    case "jobNotification": append(s, { type: "job", notification: e.notification as unknown as JobNotification }, "main"); break;
    case "deliberation": append(s, { type: "deliberation", thread: str("thread"), from: str("from"), to: str("to"), kind: str("kind"), text: str("text") }, "main"); break;
    case "planChanged": s.plan = e.plan as unknown as ResearchPlan; break;
    case "claimsChanged": s.claims = e.claims as unknown as Claim[]; break;
    case "notice": append(s, { type: "notice", text: str("text") }, "main"); break;
    case "error": append(s, { type: "error", text: str("text") }, "main"); s.lastError = str("text"); break;
    case "turnFinished":
      closeThinking(s, agent);
      openText.delete(agent);
      if (agent === "main") s.running = false;
      if (agent === "main" && Array.isArray(e.queued)) s.queued = e.queued as string[];
      break;
    case "permissionRequested": s.pendingPermission = s.pendingPermission ?? (e.request as unknown as PermissionAsk); break;
    case "askRequested": {
      const r = e.request as unknown as AskRequest;
      s.askQueue = s.askQueue.some((q) => q.id === r.id) ? s.askQueue.map((q) => (q.id === r.id ? r : q)) : [...s.askQueue, r];
      s.pendingAsk = s.askQueue[0];
      break;
    }
    case "permissionResolved": if (s.pendingPermission?.id === str("id")) s.pendingPermission = null; break;
    case "askResolved": s.askQueue = s.askQueue.filter((q) => q.id !== str("id")); s.pendingAsk = s.askQueue[0] ?? null; break;
    case "brainstormChanged": showBrainstorm(s, e.state as unknown as BrainstormState); break;
    case "ideasChanged": s.ideas = e.ideas as unknown as Idea[]; break;
    // A generated title replaces the row's text in place (names given by hand were skipped by the core).
    case "titleChanged": s.taskTitles = { ...s.taskTitles, [str("task")]: str("title") }; break;
    case "userInserted": {
      // An inserted message reached the agent: it leaves the waiting list and joins the conversation
      // where the agent read it; what the agent says next starts below it.
      if (str("agent") !== "main") break;
      const text = str("text");
      const i = s.inserting.indexOf(text);
      if (i >= 0) s.inserting = [...s.inserting.slice(0, i), ...s.inserting.slice(i + 1)];
      closeThinking(s, "main");
      openText.delete("main");
      append(s, { type: "user", text, attachments: [] }, "main");
      break;
    }
  }
}

// MARK: Stages (taskStatus)

/** `taskStatus {task, workspace, running, stage}`: a live task's stage (AppModel.refreshStage) or,
 *  with `stage: null`, a task that was closed (a released background task, AppModel+Events). */
export function taskStatus(p: JsonObject) {
  const id = String(p.task ?? ""), ws = String(p.workspace ?? "");
  const st = p.stage as JsonObject | null | undefined;
  setState((s) => {
    const attention = { ...s.attention };
    let backgroundTasks = s.backgroundTasks, backgroundWorkspaces = s.backgroundWorkspaces;
    if (st) {
      attention[id] = { stage: String(st.kind), label: String(st.label ?? ""), detail: String(st.detail ?? ""), workspace: ws,
        needsPerson: st.needsPerson === true, showsChip: st.showsChip === true };
      if (id !== s.taskId && p.running === true && !backgroundTasks.includes(id)) {
        backgroundTasks = [...backgroundTasks, id];
        backgroundWorkspaces = { ...backgroundWorkspaces, [id]: ws };
      } else if (p.running === false && backgroundTasks.includes(id)) {
        // Settled: serve releases it a moment later (stage null); the row stops working now.
        backgroundTasks = backgroundTasks.filter((t) => t !== id);
      }
    } else {
      if (attention[id]?.needsPerson !== true) delete attention[id];
      backgroundTasks = backgroundTasks.filter((t) => t !== id);
      backgroundWorkspaces = Object.fromEntries(Object.entries(backgroundWorkspaces).filter(([t]) => t !== id));
    }
    return { attention, backgroundTasks, backgroundWorkspaces };
  });
}

// MARK: Platform wording

type Platform = AppState["platform"];
/** The text for this platform: SwiftUI's macOS wording, or its Windows / Linux counterpart. */
export function onPlatform(p: Platform, mac: string, windows: string, linux: string = windows): string {
  return p === "macos" ? mac : p === "windows" ? windows : linux;
}

/** AppModel.showBrainstorm: a running brainstorm sits at the end of the conversation; once it ends it
 *  becomes a row where it ended, so the report and the conversation that follows continue below it. */
export function showBrainstorm(s: AppState, b: BrainstormState | null) {
  if (!b || !b.endedAt) { s.brainstorm = b; return; }
  const rows = s.streams.main ?? [];
  let at = -1;
  for (let i = rows.length - 1; i >= 0; i--) { const k = rows[i].kind; if (k.type === "brainstorm" && k.state.id === b.id) { at = i; break; } }
  if (at >= 0) mutate(s, "main", at, () => ({ type: "brainstorm", state: b }));
  else append(s, { type: "brainstorm", state: b }, "main");
  openText.delete("main");
  openThinking.delete("main");
  s.brainstorm = null;
}
