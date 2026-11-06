// What views ask the app to do (the SwiftUI AppModel's methods). With a serve connection they call
// it (docs/SERVE_PROTOCOL.md); in demo scenes they only change local state.
import { inTauri, type ServeClient, type JsonObject } from "../serve";
import { L, L10n, setLanguage as setUILanguage, type Language } from "../i18n";
import { getState, setState, resetTranscriptIndex, titleOf, type AppState, type MainTab, type AskRequest, type Config, type ProviderInfo, type ProviderProfile, type Quota, type TaskEntry } from "./model";

let client: ServeClient | null = null;
export function attach(c: ServeClient | null) { client = c; }
export const connected = () => client !== null;

async function call<T = JsonObject>(method: string, params: JsonObject = {}): Promise<T | null> {
  if (!client) return null;
  try { return await client.call<T>(method, params); }
  catch (e) { setState({ lastError: e instanceof Error ? e.message : String(e) }); return null; }
}

// MARK: Configuration

interface ConfigPayload {
  config: Config; keys: Record<string, boolean>; usable: string[]; providers: Record<string, ProviderInfo>;
  status: { models: { ready: boolean; text: string }; search: { ready: boolean; text: string } };
}

/** Local edits not yet answered: a reply to an older one must not undo newer typing. */
let editSeq = 0;
let pendingPatch: Partial<Config> = {};
let flushTimer: ReturnType<typeof setTimeout> | undefined;

export function applyConfig(r: ConfigPayload, seq = editSeq) {
  const fresh = seq === editSeq;
  setState((s) => ({ ...(fresh ? { config: r.config } : {}), keys: r.keys, usable: r.usable, providerInfo: r.providers ?? s.providerInfo,
    modelStatus: r.status.models, searchStatus: r.status.search }));
}

async function flushConfig() {
  flushTimer = undefined;
  const patch = pendingPatch;
  pendingPatch = {};
  if (Object.keys(patch).length === 0) return;
  const seq = editSeq;
  const r = await call<ConfigPayload>("config.set", { patch: patch as JsonObject });
  if (r) applyConfig(r, seq);
}

/** Changes configuration fields (AppConfig's didSet saves): shown at once, saved and applied by serve.
 *  `typing` waits for a pause, so a text field does not save on every key. */
export async function updateConfig(patch: Partial<Config>, typing = false) {
  editSeq++;
  setState((s) => ({ config: { ...s.config, ...patch } }));
  pendingPatch = { ...pendingPatch, ...patch };
  if (flushTimer) clearTimeout(flushTimer);
  if (typing) { flushTimer = setTimeout(() => void flushConfig(), 400); return; }
  await flushConfig();
}

/** Edits one provider profile (Settings → Providers). */
export function updateProvider(id: string, change: Partial<ProviderProfile>, typing = false) {
  const providers = getState().config.providers.map((p) => (p.id === id ? { ...p, ...change } : p));
  return updateConfig({ providers }, typing);
}

/** Stores an API key in the platform's credential store (an empty value removes it). */
export async function setKey(ref: string, value: string) {
  const r = await call<ConfigPayload>("secrets.set", { ref, value });
  if (r) applyConfig(r);
}

/** Any settings request; failures come back as the message (shown where the button is). */
export async function request<T = JsonObject>(method: string, params: JsonObject = {}): Promise<{ ok: true; value: T } | { ok: false; error: string }> {
  if (!client) return { ok: false, error: L("Open a workspace first.") };
  try { return { ok: true, value: await client.call<T>(method, params) }; }
  catch (e) { return { ok: false, error: e instanceof Error ? e.message : String(e) }; }
}

export async function refreshQuota(id: string) {
  const r = await call<Quota>("providers.quota", { id });
  if (r) setState((s) => ({ quotas: { ...s.quotas, [id]: r } }));
}

export async function refreshQuotas() {
  const r = await call<{ quotas: Record<string, Quota> }>("providers.quotas");
  if (r) setState((s) => ({ quotas: { ...s.quotas, ...r.quotas } }));
}

/** Opens a folder or web page with the system (Finder / Explorer, the browser). */
export function systemOpen(target: { path?: string; url?: string; reveal?: boolean }) { void call("system.open", target as JsonObject); }

export function setAccent(a: AppState["accent"]) {
  setState({ accent: a });
  try { localStorage.setItem("accentTheme", a); } catch { /* unavailable */ }
}

/** After a provider discovery the serve reply also carries the configuration. */
export function applyConfigPayload(r: JsonObject) { if (r.config) applyConfig(r as unknown as ConfigPayload); }

export async function refreshConfig() {
  const r = await call<ConfigPayload>("config.get");
  if (r) applyConfig(r);
}

export async function setLanguage(l: Language) {
  setUILanguage(l);
  try { localStorage.setItem("language", l); } catch { /* unavailable */ }
  setState({ languageChoice: l });
  await call("language.set", { language: l });
  // Status texts and the command catalog come from serve in its language.
  await Promise.all([refreshConfig(), loadCommands()]);
}

export async function loadCommands() {
  const r = await call<{ commands: { name: string; args: string; summary: string; group: string }[] }>("commands.list");
  if (r) setState({ commands: r.commands });
}

// MARK: Workspaces

/** A whole home / Documents / Desktop / Downloads folder is almost never the project. */
function isBroadFolder(path: string): boolean {
  const p = path.replace(/[\\/]+$/, "");
  return p === "" || /^[A-Za-z]:$/.test(p)
    || /^(\/Users\/[^/]+|\/home\/[^/]+|[A-Za-z]:\\Users\\[^\\]+)([\\/](Documents|Desktop|Downloads|Library))?$/.test(p);
}

/** The platform folder picker ("Open Workspace…"); a path typed in by hand in a browser. */
export async function chooseFolder(start?: string): Promise<string | null> {
  if (inTauri) {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const dir = await open({ directory: true, multiple: false, defaultPath: start, title: L("Open Workspace") });
    return typeof dir === "string" ? dir : null;
  }
  const typed = window.prompt(L("Open Workspace…"), start ?? "");
  return typed && typed.trim() ? typed.trim() : null;
}

async function confirmDialog(title: string, message: string, ok: string, cancel: string, warning = false): Promise<boolean> {
  if (inTauri) {
    const { ask } = await import("@tauri-apps/plugin-dialog");
    return ask(message, { title, okLabel: ok, cancelLabel: cancel, kind: warning ? "warning" : "info" });
  }
  return window.confirm(`${title}\n\n${message}`);
}

export async function chooseWorkspace() {
  const dir = await chooseFolder();
  if (dir) await openWorkspace(dir);
}

/** AppModel.open(workspace:task:newTask:): opening a folder resumes its latest task; a new one only
 *  when asked (its + button). Clicking the folder that is already open just shows it. */
export async function openWorkspace(path: string, task?: string, newTask = false) {
  const s = getState();
  if (!newTask && task === undefined && s.workspace === path && s.taskId) return;
  if (isBroadFolder(path)) {
    const name = path.split(/[\\/]/).filter(Boolean).pop() ?? path;
    const pick = await confirmDialog(L10n.f("Use all of “%@” as the workspace?", name),
      L("SieveSci keeps a history of the workspace and lets agents read and write inside it. A folder for one project is safer and faster."),
      L("Choose a project folder…"), L("Use it anyway"), true);
    if (pick) {
      const other = await chooseFolder(path);
      if (other && other !== path) await openWorkspace(other, task);
      return;
    }
  }
  // The folder being left stays as it was shown: open by default while current, it would otherwise
  // fold away in the sidebar on the switch.
  const old = s.workspace;
  if (old && old !== path && s.config.folderOpen[old] === undefined) void updateConfig({ folderOpen: { ...s.config.folderOpen, [old]: true } });
  if (!client) {
    setState((st) => ({ workspace: path, config: { ...st.config, recentWorkspaces: [path, ...st.config.recentWorkspaces.filter((p) => p !== path)].slice(0, 12) } }));
    return;
  }
  const r = await call<{ workspace: string; tasks: RawTask[] }>("workspace.open", { path });
  if (!r) return;
  setState((st) => ({ workspace: r.workspace, config: { ...st.config, recentWorkspaces: [r.workspace, ...st.config.recentWorkspaces.filter((p) => p !== r.workspace)].slice(0, 12) } }));
  applyTasks(r.tasks);
  await startSession(newTask ? undefined : (task ?? r.tasks[0]?.id));
  void loadCommands();
  refreshOpenFolders();
}

// MARK: Tasks

interface RawTask { id: string; title: string | null; modified: string; running?: boolean }
interface HistoryItem { kind: string; text?: string; id?: string; name?: string; input?: JsonObject; output?: string; isError?: boolean; receipt?: string }

function entries(list: RawTask[]): TaskEntry[] { return list.map((t) => ({ id: t.id, modified: Date.parse(t.modified) })); }
function mergeTitles(list: RawTask[]) {
  const titles = { ...getState().taskTitles };
  let changed = false;
  for (const t of list) if (t.title && titles[t.id] !== t.title) { titles[t.id] = t.title; changed = true; }
  if (changed) setState({ taskTitles: titles });
}

/** AppModel.refreshTaskList: the open task stays listed before it has been saved. */
function applyTasks(list: RawTask[]) {
  mergeTitles(list);
  const s = getState();
  const tasks = entries(list);
  if (s.taskId && !tasks.some((t) => t.id === s.taskId)) tasks.unshift({ id: s.taskId, modified: s.tasks.find((t) => t.id === s.taskId)?.modified ?? Date.now() });
  setState({ tasks });
}

export async function refreshTaskList() {
  const r = await call<{ tasks: RawTask[] }>("tasks.list");
  if (r) applyTasks(r.tasks);
}

/** Reads a folder other than the open workspace: its conversations, newest first, and their titles. */
export async function loadFolderTasks(path: string) {
  const r = await call<{ tasks: RawTask[] }>("tasks.list", { workspace: path });
  if (!r) return;
  mergeTitles(r.tasks);
  setState((s) => ({ folderTasks: { ...s.folderTasks, [path]: entries(r.tasks) } }));
}

export function refreshOpenFolders() {
  const s = getState();
  for (const p of s.config.recentWorkspaces) if (p !== s.workspace && (s.config.folderOpen[p] ?? false)) void loadFolderTasks(p);
}

/** model.startSession(task:): opens a task (a new one without an id) and shows its saved conversation.
 *  A turn still running in the task being left keeps going in the background. */
export async function startSession(task?: string) {
  setState({ showSettingsPage: false, mainTab: "chat" });
  const before = getState();
  if (task !== undefined && task === before.taskId && before.live) return;
  if (!client) { setState({ taskId: task ?? `new-${Date.now()}`, streams: { main: [] }, cards: {}, running: false }); return; }
  const r = await call<JsonObject>("task.open", task ? { id: task } : {});
  if (!r) { setState({ live: false }); return; }
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
  const id = String(r.task);
  setState((s) => {
    let backgroundTasks = s.backgroundTasks.filter((t) => t !== id);
    let backgroundWorkspaces = Object.fromEntries(Object.entries(s.backgroundWorkspaces).filter(([t]) => t !== id));
    if (before.running && before.taskId && before.taskId !== id) {
      backgroundTasks = [...backgroundTasks, before.taskId];
      if (before.workspace) backgroundWorkspaces = { ...backgroundWorkspaces, [before.taskId]: before.workspace };
    }
    const title = typeof r.title === "string" ? { ...s.taskTitles, [id]: r.title } : s.taskTitles;
    return {
      taskId: id, live: true, lastError: null, streams: { main }, cards: {}, jobs: {}, jobOrder: [], changedFiles: [], figures: [], queued: [],
      running: r.running === true, runStarted: Date.now(), backgroundTasks, backgroundWorkspaces, taskTitles: title,
      pendingAsk: ((r.asks ?? []) as unknown as AskRequest[])[0] ?? null, pendingPermission: null,
      plan: (r.plan as never) ?? s.plan, claims: (r.claims as never) ?? [], contested: (r.contested as never) ?? [],
      ideas: (r.ideas as never) ?? [], brainstorm: (r.brainstorm as never) ?? null,
      grounding: (r.grounding as never) ?? null,
    };
  });
  await refreshTaskList();
}

export async function renameTask(id: string, title: string) {
  const r = await call<{ task: string; title: string | null }>("task.rename", { id, title });
  if (!r) return;
  setState((s) => {
    const t = { ...s.taskTitles };
    if (r.title) t[id] = r.title; else delete t[id];
    return { taskTitles: t };
  });
}

/** Moves a conversation to the Trash after confirming; deleting the open one opens the next most recent. */
export async function deleteTask(id: string) {
  const s = getState();
  const ok = await confirmDialog(L10n.f("Delete “%@”?", titleOf(s, id, L("New task"))), L("The conversation and its records are moved to the Trash."),
    L("Move to Trash"), L("Cancel"), true);
  if (!ok) return;
  const wasOpen = id === s.taskId;
  if (wasOpen) setState({ taskId: "", streams: { main: [] }, cards: {}, running: false });
  setState((st) => {
    const attention = { ...st.attention };
    delete attention[id];
    return { attention, backgroundTasks: st.backgroundTasks.filter((t) => t !== id), tasks: st.tasks.filter((t) => t.id !== id) };
  });
  await call("task.delete", { id });
  await refreshTaskList();
  if (wasOpen) await startSession(getState().tasks[0]?.id);
}

export async function forkTask(id: string) {
  const r = await call<{ task: string }>("task.fork", { id });
  if (r) await startSession(r.task);
}

export async function taskMarkdown(id: string): Promise<string | null> {
  const r = await call<{ markdown: string }>("task.markdown", { id });
  return r?.markdown ?? null;
}

/** Opens a task from the "Needs you" list, switching workspace when needed. */
export async function openAttention(id: string) {
  setState({ showSettingsPage: false, mainTab: "chat" });
  const s = getState();
  const a = s.attention[id];
  if (!a) return;
  if (a.workspace && a.workspace !== s.workspace) await openWorkspace(a.workspace, id);
  else if (id !== s.taskId) await startSession(id);
}

// MARK: Window

export function setMainTab(t: MainTab) { setState({ mainTab: t, showSettingsPage: false }); }
export function setSidebarVisible(v: boolean) { setState({ sidebarVisible: v }); try { localStorage.setItem("sidebarVisible", v ? "1" : "0"); } catch { /* unavailable */ } }
export function toggleInspector() { setState((s) => ({ showInspector: !s.showInspector })); }
export type SettingsPane = "general" | "providers" | "models" | "search" | "research" | "memory" | "schedules";
export function openSettings(pane?: SettingsPane) {
  if (pane) { setState({ settingsPane: pane }); try { localStorage.setItem("settingsPane", pane); } catch { /* unavailable */ } }
  setState({ showSettingsPage: true });
}
export function setSettingsPane(pane: SettingsPane) { openSettings(pane); }
export function closeSettings() { setState({ showSettingsPage: false }); void resumeIfNeeded(); }

/** Starts (or resumes) a session when a workspace is open but none is running: after launch, after
 *  Settings, or when the user sends a message. */
export async function resumeIfNeeded() {
  const s = getState();
  if (!client || !s.workspace || s.live) return;
  await startSession(s.taskId && !s.taskId.startsWith("new-") ? s.taskId : s.tasks[0]?.id);
}

/** AppModel.setFolder: open or fold a sidebar folder (saved; folders no longer listed are forgotten). */
export function setFolder(path: string, open: boolean) {
  const s = getState();
  const f = Object.fromEntries(Object.entries(s.config.folderOpen).filter(([k]) => s.config.recentWorkspaces.includes(k)));
  f[path] = open;
  void updateConfig({ folderOpen: f });
  if (open && path !== s.workspace) void loadFolderTasks(path);
}

export function setPermissionMode(mode: Config["permissionMode"]) { void updateConfig({ permissionMode: mode }); }

// MARK: Turns

export async function send(text: string) {
  if (!getState().live) await resumeIfNeeded();
  if (!getState().live) {
    // Never drop what the user typed: put it back and let the setup card explain what is missing.
    setState((st) => ({ draft: text, lastError: st.lastError ?? (st.workspace === null ? L("Open a workspace first.") : L("No model is set up yet.")) }));
    return;
  }
  const trimmed = text.trim();
  if (!trimmed) return;
  // Commands that open native UI.
  if (trimmed === "/providers") { openSettings("providers"); return; }
  if (trimmed === "/config") { openSettings(); return; }
  if (trimmed === "/clear") { await startSession(); return; }
  if (trimmed === "/fork") { await forkTask(getState().taskId); return; }
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

export async function wrapUpBrainstorm() { await call("brainstorm.wrapUp"); }

/** The composer's model menu: after a confirmation (the prompt cache goes cold), the lead agent's model
 *  changes and the open task restarts on it (AppModel.switchMainModel). */
export async function switchMainModel(providerId: string, model: string) {
  const ok = await confirmDialog(L("Switch model?"),
    L("The conversation is kept, but the new model starts with a cold prompt cache: the next request pays full price for the whole context. Switch at a natural break."),
    L("Switch"), L("Cancel"));
  if (!ok) return;
  const r = await call<ConfigPayload>("models.switchMain", { providerId, model });
  if (!r) return;
  applyConfig(r);
  const s = getState();
  if (!s.workspace) return;
  const id = s.taskId && !s.taskId.startsWith("new-") ? s.taskId : undefined;
  const opened = await call<JsonObject>("task.open", { ...(id ? { id } : {}), restart: true });
  if (opened) { setState({ live: false }); await startSession(String(opened.task)); }
}

/** Output of a CLI agent's installer (serve's `agentInstall` notifications), by provider id. */
export const agentInstallListeners = new Set<(id: string, lines: string[]) => void>();
