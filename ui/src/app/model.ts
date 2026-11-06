// The web counterpart of the SwiftUI `AppModel` (Sources/SieveSciApp/AppModel*.swift): the same
// state, built from `sievesci serve` events with the same rules (AppModel+Events.swift).
import { useRef, useSyncExternalStore } from "react";
import type { JsonObject } from "../serve";

export type Role = "main" | "checker" | "verifier" | "worker";

export interface DiffLine { kind: "context" | "added" | "removed"; text: string; old: number | null; new: number | null }
export interface FileDiff { path: string; hunks: { header: string; lines: DiffLine[] }[]; added: number; removed: number; isNewFile: boolean; isBinaryOrLarge: boolean }

export interface ToolCallView {
  id: string; name: string; summary: string; input: JsonObject; output: string; isError: boolean; receipt?: string;
  started: number; ended?: number; live: string[]; diff?: FileDiff;
}
export interface AgentCard { id: string; role: Role; parent: string; purpose: string; started: number; ended?: number; result?: string }
export interface JobNotification { job: string; agentId: string; kind: string; text: string; at: string }

export type ItemKind =
  | { type: "user"; text: string; attachments: string[] }
  | { type: "assistant"; text: string }
  | { type: "thinking"; text: string; started: number; ended?: number }
  | { type: "tool"; call: ToolCallView }
  | { type: "agent"; id: string }
  | { type: "review"; kind: string; verdict: string; body: string }
  | { type: "deliberation"; thread: string; from: string; to: string; kind: string; text: string }
  | { type: "literature"; action: string; key: string; title: string; detail: string }
  | { type: "fileChange"; path: string; diff: FileDiff }
  | { type: "commit"; hash: string; subject: string; files: number }
  | { type: "job"; notification: JobNotification }
  | { type: "signal"; text: string }
  | { type: "notice"; text: string }
  | { type: "error"; text: string };
export interface TranscriptItem { id: string; kind: ItemKind; at: number }

export interface ContextMeter { model: string; contextWindow: number; lastPromptTokens: number; lastOutputTokens: number; fill: number; cacheHitRate: number;
  session: { input: number; cacheRead: number; cacheWrite: number; output: number; reasoning: number } }
export interface PlanStep { id: string; title: string; detail: string; status: string; checkpoint: boolean; criteria: string; evidence: string[]; note: string }
export interface Hypothesis { id: string; statement: string; prediction: string; falsification: string; status: string }
export interface ResearchPlan { goal: string; background?: string; stage: string; hypotheses: Hypothesis[]; steps: PlanStep[]; rationale?: string }
export interface Claim { id: string; statement: string; successCriteria: string; evidence: string[]; dataPaths: string[]; status: string; verdict: string | null; verifierReceipts: string[] }
export interface Contested { thread: string; kind: string; issue: string; reason: string }
export interface JobState { id: string; label: string; lines: string[]; running: boolean; unread: number; exitCode?: number; seconds?: number }
export interface PermissionAsk { id?: string; tool: string; summary: string; input: JsonObject; effect: string; rememberPattern: string }
export interface AskOption { label: string; description?: string; recommended: boolean; evidence: string[] }
export interface AskQuestion { id: string; header: string; question: string; kind: "single" | "multi" | "text"; options: AskOption[]; allow_other: boolean; placeholder?: string; optional: boolean }
export interface AskRequest { id: string; agent_id: string; questions: AskQuestion[] }
export interface TaskEntry { id: string; modified: number }
export interface Attention { stage: string; detail: string; workspace: string }

export type InspectorTab = "activity" | "plan" | "claims" | "library" | "changes" | "files" | "figures" | "jobs" | "history" | "notebook" | "learning";
export type MainTab = "chat" | InspectorTab;
/** The tabs shown under the title (InspectorTab.inMain). */
export const mainTabs: MainTab[] = ["chat", "activity", "plan", "claims", "library", "notebook"];

export interface Config {
  permissionMode: "ask" | "acceptEdits" | "auto" | "plan";
  recentWorkspaces: string[];
  folderOpen: Record<string, boolean>;
  showThinking: boolean;
  appearance: "system" | "light" | "dark";
  effort: string | null;
  sandboxMode: "workspaceWrite" | "workspaceWriteOffline" | "off";
}

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
  plan: ResearchPlan;
  claims: Claim[];
  contested: Contested[];
  jobs: Record<string, JobState>;
  jobOrder: string[];
  changedFiles: string[];
  figures: string[];
  queued: string[];
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
  commands: { name: string; args: string; summary: string }[];
}

export const verbs = ["Sieving", "Pipetting", "Titrating", "Centrifuging", "Sequencing", "Culturing", "Incubating", "Annealing", "Distilling", "Staining"];

export const initialState: AppState = {
  config: { permissionMode: "ask", recentWorkspaces: [], folderOpen: {}, showThinking: true, appearance: "system", effort: null, sandboxMode: "workspaceWrite" },
  workspace: null, taskId: "", tasks: [], folderTasks: {}, taskTitles: {},
  streams: { main: [] }, cards: {},
  meter: { model: "", contextWindow: 0, lastPromptTokens: 0, lastOutputTokens: 0, fill: 0, cacheHitRate: 0, session: { input: 0, cacheRead: 0, cacheWrite: 0, output: 0, reasoning: 0 } },
  running: false, runStarted: Date.now(), spinnerVerb: "Sieving",
  pendingPermission: null, demoAsk: null, pendingAsk: null,
  plan: { goal: "", stage: "scoping", hypotheses: [], steps: [] }, claims: [], contested: [],
  jobs: {}, jobOrder: [], changedFiles: [], figures: [], queued: [],
  mainTab: "chat", inspectorTab: "files", showInspector: false, showSettingsPage: false, sidebarVisible: true,
  backgroundTasks: [], backgroundWorkspaces: {}, attention: {}, grounding: null,
  modelStatus: { ready: false, text: "" }, searchStatus: { ready: false, text: "" }, lastError: null, version: "", draft: "", commands: [],
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

function handle(s: AppState, e: JsonObject) {
  const str = (k: string) => String(e[k] ?? "");
  const agent = str("agentId");
  switch (e.type) {
    case "turnStarted":
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
      for (const sig of (e.signals ?? []) as JsonObject[]) if (Number(sig.severity ?? 0) >= 2) append(s, { type: "signal", text: `${sig.kind} · ${sig.detail}` }, "main");
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
      break;
    case "permissionRequested": s.pendingPermission = s.pendingPermission ?? (e.request as unknown as PermissionAsk); break;
    case "askRequested": { const r = e.request as unknown as AskRequest; if (!s.pendingAsk || s.pendingAsk.id === r.id) s.pendingAsk = r; break; }
    case "askResolved": if (s.pendingAsk?.id === str("id")) s.pendingAsk = null; break;
  }
}
