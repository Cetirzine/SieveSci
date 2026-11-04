// What views ask the app to do (the SwiftUI AppModel's methods). With a serve connection they call
// it; in demo scenes they only change local state.
import type { ServeClient, JsonObject } from "../serve";
import { getState, setState, resetTranscriptIndex, type MainTab, type AskRequest } from "./model";

let client: ServeClient | null = null;
export function attach(c: ServeClient | null) { client = c; }
export const connected = () => client !== null;

async function call<T = JsonObject>(method: string, params: JsonObject = {}): Promise<T | null> {
  if (!client) return null;
  try { return await client.call<T>(method, params); }
  catch (e) { setState({ lastError: e instanceof Error ? e.message : String(e) }); return null; }
}

interface HistoryItem { kind: string; text?: string; id?: string; name?: string; input?: JsonObject; output?: string; isError?: boolean; receipt?: string }

/** model.startSession(task:): open a task (a new one without an id) and show its saved conversation. */
export async function startSession(task?: string) {
  setState({ showSettingsPage: false, mainTab: "chat" });
  const r = await call<JsonObject>("task.open", task ? { id: task } : {});
  if (!r) { if (!client) setState({ taskId: task ?? `new-${Date.now()}`, streams: { main: [] }, cards: {}, running: false }); return; }
  resetTranscriptIndex();
  const now = Date.now();
  let n = 0;
  const main = ((r.history ?? []) as unknown as HistoryItem[]).map((h) => {
    const id = `h${++n}`;
    if (h.kind === "user") return { id, at: now, kind: { type: "user" as const, text: h.text ?? "", attachments: [] } };
    if (h.kind === "assistant") return { id, at: now, kind: { type: "assistant" as const, text: h.text ?? "" } };
    return { id, at: now, kind: { type: "tool" as const, call: { id: h.id ?? id, name: h.name ?? "tool", summary: "", input: h.input ?? {}, output: h.output ?? "",
      isError: h.isError === true, receipt: h.receipt, started: now, ended: now, live: [] } } };
  });
  setState({ taskId: String(r.task), streams: { main }, cards: {}, running: r.running === true, pendingAsk: ((r.asks ?? []) as unknown as AskRequest[])[0] ?? null,
    pendingPermission: null, plan: (r.plan as never) ?? getState().plan, claims: (r.claims as never) ?? [] });
  await refreshTaskList();
}

export async function refreshTaskList() {
  const r = await call<{ tasks: { id: string; title: string | null; modified: string }[] }>("tasks.list");
  if (!r) return;
  const titles = { ...getState().taskTitles };
  for (const t of r.tasks) if (t.title) titles[t.id] = t.title;
  setState({ tasks: r.tasks.map((t) => ({ id: t.id, modified: Date.parse(t.modified) })), taskTitles: titles });
}

export function setMainTab(t: MainTab) { setState({ mainTab: t, showSettingsPage: false }); }
export function setSidebarVisible(v: boolean) { setState({ sidebarVisible: v }); try { localStorage.setItem("sidebarVisible", v ? "1" : "0"); } catch { /* unavailable */ } }
export function toggleInspector() { setState((s) => ({ showInspector: !s.showInspector })); }
export function openSettings() { setState({ showSettingsPage: true }); }

export function setFolder(path: string, open: boolean) {
  setState((s) => ({ config: { ...s.config, folderOpen: { ...s.config.folderOpen, [path]: open } } }));
}

export function setPermissionMode(mode: "ask" | "acceptEdits" | "auto" | "plan") {
  setState((s) => ({ config: { ...s.config, permissionMode: mode } }));
  void call("config.set", { permissionMode: mode });
}

export async function send(text: string) {
  const s = getState();
  const item = { id: `u${Date.now()}`, at: Date.now(), kind: { type: "user" as const, text, attachments: [] } };
  setState({ streams: { ...s.streams, main: [...(s.streams.main ?? []), item] }, ...(s.running ? { queued: [...s.queued, text] } : { running: true, runStarted: Date.now() }) });
  await call("task.send", { text });
}

export async function stop() { await call("task.stop"); }

export async function answerPermission(id: string | undefined, decision: "allow" | "always" | "deny", reason?: string) {
  setState({ pendingPermission: null, demoAsk: null });
  if (id) await call("permission.respond", { id, decision, ...(reason ? { reason } : {}) });
}

export async function answerAsk(id: string, outcome: JsonObject) {
  setState({ pendingAsk: null });
  await call("ask.respond", { id, outcome });
}

/** Opening another folder: the browser build can only open what the bridge was started for. */
export function openWorkspace(path: string) {
  setState((s) => ({ workspace: path, config: { ...s.config, recentWorkspaces: [path, ...s.config.recentWorkspaces.filter((p) => p !== path)].slice(0, 10) } }));
}

export function deleteTask(id: string) { void call("task.delete", { id }); setState((s) => ({ tasks: s.tasks.filter((t) => t.id !== id) })); }
