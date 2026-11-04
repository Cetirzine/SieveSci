// The transcript as the UI shows it, built from `task.open` history and the `event` stream.
// Follows the macOS app's AppModel+Events: one open text and thinking row per agent; a tool call
// or a new turn closes them.
import type { Json, JsonObject } from "./serve";

export type Item =
  | { kind: "user"; id: string; text: string }
  | { kind: "assistant"; id: string; text: string }
  | { kind: "thinking"; id: string; text: string; started: number; ended?: number }
  | { kind: "tool"; id: string; name: string; input: JsonObject; output?: string; isError?: boolean; receipt?: string; running: boolean; progress: string[] }
  | { kind: "notice"; id: string; text: string; tone: "info" | "error" | "output" }
  | { kind: "agent"; id: string; role: string; purpose: string; result?: string }
  | { kind: "review"; id: string; reviewKind: string; verdict: string; body: string };

export interface PermissionReq { id: string; tool: string; summary: string; input: JsonObject; effect: string; rememberPattern: string }
export interface AskOption { label: string; description?: string; recommended: boolean; evidence: string[] }
export interface AskQuestion { id: string; header: string; question: string; kind: "single" | "multi" | "text"; options: AskOption[]; allow_other: boolean; placeholder?: string; optional: boolean }
export interface AskRequest { id: string; agent_id: string; questions: AskQuestion[] }
export interface Meter { model: string; contextWindow: number; lastPromptTokens: number; fill: number; cacheHitRate: number }

export interface State {
  items: Item[];
  running: boolean;
  runStarted?: number;
  permissions: PermissionReq[];
  asks: AskRequest[];
  meter?: Meter;
  openText?: number;
  openThinking?: number;
}

export const empty: State = { items: [], running: false, permissions: [], asks: [] };

export type Action =
  | { type: "reset"; history: JsonObject[]; asks: AskRequest[]; running: boolean }
  | { type: "user"; text: string }
  | { type: "output"; text: string }
  | { type: "event"; e: JsonObject }
  | { type: "localError"; text: string }
  | { type: "settle"; id: string };   // a permission or question answered here

let seq = 0;
const uid = () => `i${++seq}`;

/** One line that says what a tool call is about (command, query, path, first code line …). */
export function toolSummary(input: JsonObject): string {
  for (const k of ["command", "query", "path", "pattern", "url", "claim", "ref", "purpose", "action"]) {
    const v = input[k];
    if (typeof v === "string" && v) return v.slice(0, 160);
  }
  const code = input.code;
  if (typeof code === "string") return (code.split("\n")[0] ?? "").slice(0, 160);
  return JSON.stringify(input).slice(0, 160);
}

function fromHistory(h: JsonObject[]): Item[] {
  return h.map((x): Item => {
    switch (x.kind) {
      case "user": return { kind: "user", id: uid(), text: String(x.text ?? "") };
      case "assistant": return { kind: "assistant", id: uid(), text: String(x.text ?? "") };
      default: return {
        kind: "tool", id: String(x.id ?? uid()), name: String(x.name ?? "tool"), input: (x.input ?? {}) as JsonObject,
        output: x.output as string | undefined, isError: x.isError === true, receipt: x.receipt as string | undefined,
        running: false, progress: [],
      };
    }
  });
}

export function reduce(s: State, a: Action): State {
  switch (a.type) {
    case "reset":
      return { ...empty, items: fromHistory(a.history), asks: a.asks, running: a.running };
    case "user":
      return { ...s, items: [...s.items, { kind: "user", id: uid(), text: a.text }], running: true, runStarted: s.running ? s.runStarted : Date.now(), openText: undefined, openThinking: undefined };
    case "output":
      return { ...s, items: [...s.items, { kind: "notice", id: uid(), text: a.text, tone: "output" }] };
    case "localError":
      return { ...s, items: [...s.items, { kind: "notice", id: uid(), text: a.text, tone: "error" }] };
    case "settle":
      return { ...s, permissions: s.permissions.filter((p) => p.id !== a.id), asks: s.asks.filter((q) => q.id !== a.id) };
    case "event":
      return onEvent(s, a.e);
  }
}

function closeThinking(s: State, items: Item[]): void {
  if (s.openThinking === undefined) return;
  const t = items[s.openThinking];
  if (t?.kind === "thinking" && t.ended === undefined) items[s.openThinking] = { ...t, ended: Date.now() };
}

function onEvent(s: State, e: JsonObject): State {
  const agent = String(e.agentId ?? "");
  const main = agent === "main";
  const items = s.items.slice();
  const str = (k: string) => String(e[k] ?? "");
  switch (e.type) {
    case "turnStarted":
      return main ? { ...s, running: true, runStarted: s.running ? s.runStarted : Date.now() } : s;
    case "textDelta": {
      if (!main) return s;
      closeThinking(s, items);
      const t = s.openText !== undefined ? items[s.openText] : undefined;
      if (t?.kind === "assistant") {
        items[s.openText!] = { ...t, text: t.text + str("text") };
        return { ...s, items, openThinking: undefined };
      }
      items.push({ kind: "assistant", id: uid(), text: str("text") });
      return { ...s, items, openText: items.length - 1, openThinking: undefined };
    }
    case "thinkingDelta": {
      if (!main) return s;
      const t = s.openThinking !== undefined ? items[s.openThinking] : undefined;
      if (t?.kind === "thinking") {
        items[s.openThinking!] = { ...t, text: t.text + str("text") };
        return { ...s, items };
      }
      items.push({ kind: "thinking", id: uid(), text: str("text"), started: Date.now() });
      return { ...s, items, openThinking: items.length - 1, openText: undefined };
    }
    case "toolStarted": {
      if (!main) return s;
      closeThinking(s, items);
      items.push({ kind: "tool", id: str("id"), name: str("name"), input: (e.input ?? {}) as JsonObject, running: true, progress: [] });
      return { ...s, items, openText: undefined, openThinking: undefined };
    }
    case "toolProgress": {
      const i = items.findIndex((x) => x.kind === "tool" && x.id === str("id"));
      if (i < 0) return s;
      const t = items[i] as Extract<Item, { kind: "tool" }>;
      items[i] = { ...t, progress: [...t.progress, ...((e.lines ?? []) as string[])].slice(-40) };
      return { ...s, items };
    }
    case "toolFinished": {
      const i = items.findIndex((x) => x.kind === "tool" && x.id === str("id"));
      if (i < 0) return s;
      const t = items[i] as Extract<Item, { kind: "tool" }>;
      items[i] = { ...t, running: false, output: str("output"), isError: e.isError === true, receipt: str("receipt") };
      return { ...s, items };
    }
    case "turnFinished":
      if (!main) return s;
      closeThinking(s, items);
      return { ...s, items, running: false, openText: undefined, openThinking: undefined };
    case "usage":
      return main ? { ...s, meter: e.meter as unknown as Meter } : s;
    case "permissionRequested": {
      const r = e.request as unknown as PermissionReq;
      return s.permissions.some((p) => p.id === r.id) ? s : { ...s, permissions: [...s.permissions, r] };
    }
    case "askRequested": {
      const r = e.request as unknown as AskRequest;
      return s.asks.some((q) => q.id === r.id) ? s : { ...s, asks: [...s.asks, r] };
    }
    case "askResolved":
      return { ...s, asks: s.asks.filter((q) => q.id !== str("id")) };
    case "agentStarted":
      items.push({ kind: "agent", id: str("id"), role: str("role"), purpose: str("purpose") });
      return { ...s, items, openText: undefined };
    case "agentFinished": {
      const i = items.findIndex((x) => x.kind === "agent" && x.id === str("id"));
      if (i < 0) return s;
      items[i] = { ...(items[i] as Extract<Item, { kind: "agent" }>), result: str("result") };
      return { ...s, items };
    }
    case "supervisorReview":
      items.push({ kind: "review", id: uid(), reviewKind: str("kind"), verdict: str("verdict"), body: str("body") });
      return { ...s, items, openText: undefined };
    case "notice":
      items.push({ kind: "notice", id: uid(), text: str("text"), tone: "info" });
      return { ...s, items, openText: undefined };
    case "error":
      items.push({ kind: "notice", id: uid(), text: str("text"), tone: "error" });
      return { ...s, items, openText: undefined, running: false };
    default:
      return s;
  }
}

export type { Json };
