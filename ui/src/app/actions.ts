// What views ask the app to do (the SwiftUI AppModel's methods). With a serve connection they call
// it (docs/SERVE_PROTOCOL.md); in demo scenes they only change local state.
import { inTauri, type ServeClient, type JsonObject } from "../serve";
import { L, L10n, loadLanguage, type Language } from "../i18n";
import { notify } from "./notify";
import { deliver, getState, setState, resetTranscriptIndex, summary, titleOf, mainTabs, type InspectorTab, type AgentCard, type FileDiff, type Role, type TranscriptItem, type AppState, type MainTab, type AskRequest, type Config, type ContextMeter, type PermissionAsk, type ProviderInfo, type ProviderProfile, type Quota, type TaskEntry } from "./model";

let client: ServeClient | null = null;
export function attach(c: ServeClient | null) { client = c; }
export const connected = () => client !== null;

/** Requests about the open task name the task this window shows. Without it serve acts on the task it
 *  has open, which during a switch (a slow open, another folder) may be a different one: a message,
 *  a Stop or an answer would land in the wrong conversation. Naming it, they fail instead. */
const taskScoped = /^(task\.send|task\.stop|ask\.respond|brainstorm\.|panels\.|library\.links|learning\.|changes\.|history\.|jobs\.stop)/;
function scoped(method: string, params: JsonObject): JsonObject {
  if (!taskScoped.test(method) || params.task !== undefined) return params;
  const s = getState();
  return s.taskId && !s.taskId.startsWith("new-") && s.workspace ? { ...params, task: s.taskId, workspace: s.workspace } : params;
}

async function call<T = JsonObject>(method: string, params: JsonObject = {}): Promise<T | null> {
  if (!client) return null;
  try { return await client.call<T>(method, scoped(method, params)); }
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
  try { return { ok: true, value: await client.call<T>(method, scoped(method, params)) }; }
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
  await loadLanguage(l);
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

export async function messageDialog(title: string, message: string, warning = false): Promise<void> {
  if (inTauri) {
    const { message: show } = await import("@tauri-apps/plugin-dialog");
    await show(message, { title, kind: warning ? "warning" : "info" });
    return;
  }
  window.alert(`${title}\n\n${message}`);
}

export async function confirmDialog(title: string, message: string, ok: string, cancel: string, warning = false): Promise<boolean> {
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
  // Another folder: its task replaces the conversation shown, never shown under the old one's. A task
  // still running there carries on in the background (as startSession records when it switches).
  const other = r.workspace !== s.workspace;
  const leaving = getState();
  const moved = other && leaving.running && leaving.taskId && leaving.workspace
    ? { backgroundTasks: [...leaving.backgroundTasks.filter((t) => t !== leaving.taskId), leaving.taskId],
        backgroundWorkspaces: { ...leaving.backgroundWorkspaces, [leaving.taskId]: leaving.workspace } } : {};
  setState((st) => ({ ...(other ? { ...moved, taskId: "", live: false, streams: { main: [] }, cards: {}, running: false, pendingPermission: null, pendingAsk: null, askQueue: [] } : {}), workspace: r.workspace, config: { ...st.config, recentWorkspaces: [r.workspace, ...st.config.recentWorkspaces.filter((p) => p !== r.workspace)].slice(0, 12) } }));
  applyTasks(r.tasks);
  await startSession(newTask ? undefined : (task ?? r.tasks[0]?.id));
  void loadCommands();
  refreshOpenFolders();
}

// MARK: Tasks

interface RawTask { id: string; title: string | null; modified: string; running?: boolean }
/** One entry of `task.open`'s history (ServeServer.timeline): what the chat showed live. */
interface HistoryItem {
  kind: string; text?: string; id?: string; name?: string; input?: JsonObject; output?: string; isError?: boolean; receipt?: string;
  diff?: FileDiff; seconds?: number | null; role?: string; parent?: string; purpose?: string; stepCount?: number;
}

/** A tool row of a saved task, as the live view drew it (its summary from the input). */
function historyTool(h: HistoryItem, id: string, now: number): TranscriptItem {
  const input = h.input ?? {};
  return { id, at: now, kind: { type: "tool", call: { id: h.id ?? id, name: h.name ?? "tool", summary: summary(input), input, output: h.output ?? "",
    isError: h.isError === true, receipt: h.receipt, started: now, ended: now, live: [], ...(h.diff ? { diff: h.diff } : {}) } } };
}

/** A reopened task's subagent card, opened: its steps, fetched now (they are not sent with task.open). */
export async function loadAgentSteps(agent: string) {
  const r = await request<{ steps: HistoryItem[] }>("history.agent", { id: agent });
  if (!r.ok) { setState({ lastError: r.error }); return; }
  const now = Date.now();
  const items = r.value.steps.map((h, i) => historyTool(h, `${agent}-s${i}`, now));
  setState((s) => ({ streams: { ...s.streams, [agent]: items }, cards: s.cards[agent] ? { ...s.cards, [agent]: { ...s.cards[agent], lazy: false } } : s.cards }));
}

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
const dreamNoticeShown = new Set<string>();

/** The task being opened ("" for a new one): a second click while it opens is ignored, so a slow
 *  open never starts the same task twice or two new tasks. */
let opening: string | null = null;

export async function startSession(task?: string) {
  setState({ showSettingsPage: false, mainTab: "chat" });
  const before = getState();
  if (task !== undefined && task === before.taskId && before.live) return;
  if (!client) { setState({ taskId: task ?? `new-${Date.now()}`, streams: { main: [] }, cards: {}, running: false }); return; }
  if (opening !== null && opening === (task ?? "")) return;
  opening = task ?? "";
  setState({ openingTask: opening });
  let r: JsonObject | null;
  try { r = await call<JsonObject>("task.open", task ? { id: task } : {}); }
  finally { opening = null; setState({ openingTask: null }); }
  if (!r) { setState({ live: false }); return; }
  resetTranscriptIndex();
  const now = Date.now();
  let n = 0;
  // Rows as the chat showed them live: reasoning with its duration, tool rows with their summary and
  // diff, and each subagent's card with the steps it took (its own stream).
  const cards: Record<string, AgentCard> = {};
  const subStreams: Record<string, TranscriptItem[]> = {};
  const toItem = (h: HistoryItem): TranscriptItem | null => {
    const id = `h${++n}`;
    switch (h.kind) {
      case "user": return { id, at: now, kind: { type: "user", text: h.text ?? "", attachments: [] } };
      case "assistant": return { id, at: now, kind: { type: "assistant", text: h.text ?? "" } };
      case "thinking": {
        const timed = typeof h.seconds === "number";
        return { id, at: now, kind: { type: "thinking", text: h.text ?? "", started: now - (timed ? (h.seconds as number) * 1000 : 0), ended: now, untimed: !timed } };
      }
      case "tool": return historyTool(h, id, now);
      case "agent": {
        const aid = h.id ?? id;
        cards[aid] = { id: aid, role: (h.role ?? "worker") as Role, parent: h.parent ?? "main", purpose: h.purpose ?? "", started: now - (h.seconds ?? 0) * 1000, ended: now,
          stepCount: h.stepCount ?? 0, lazy: (h.stepCount ?? 0) > 0 };
        subStreams[aid] = [];
        return { id, at: now, kind: { type: "agent", id: aid } };
      }
      default: return null;
    }
  };
  const main = ((r.history ?? []) as unknown as HistoryItem[]).map(toItem).filter((x): x is TranscriptItem => x !== null);
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
      taskId: id, live: true, lastError: null, streams: { ...subStreams, main }, cards, jobs: {}, jobOrder: [], changedFiles: [], figures: [], queued: [], inserting: [],
      running: r.running === true, runStarted: Date.now(), backgroundTasks, backgroundWorkspaces, taskTitles: title,
      askQueue: (r.asks ?? []) as unknown as AskRequest[],
      pendingAsk: ((r.asks ?? []) as unknown as AskRequest[])[0] ?? null,
      // An agent of this task may be waiting for an approval asked while another task was shown.
      pendingPermission: (r.permission as unknown as PermissionAsk) ?? null,
      plan: (r.plan as never) ?? s.plan, claims: (r.claims as never) ?? [], contested: (r.contested as never) ?? [],
      ideas: (r.ideas as never) ?? [], brainstorm: (r.brainstorm as never) ?? null,
      grounding: (r.grounding as never) ?? null,
      meter: (r.meter as unknown as ContextMeter) ?? s.meter,
    };
  });
  // A task still working (it ran on while another was shown) says so (AppModel.attach).
  if (r.running === true && main.length > 0) deliver({ type: "notice", text: L("Still working on this task; new output appears below.") });
  // Ideas a background dream left in this workspace: said once per run, when one of its tasks opens.
  const ws = getState().workspace;
  if (Number(r.dreams ?? 0) > 0 && ws && !dreamNoticeShown.has(ws)) {
    dreamNoticeShown.add(ws);
    const text = L10n.f("%d new idea(s) from dreaming. Type /ideas dream to read them.", Number(r.dreams));
    void notify(L("SieveSci dreamed"), text, `dream-${ws}`);
    if (task !== undefined) deliver({ type: "notice", text });
  }
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

/** AppModel.show(_:): a panel where it lives. Trace, Plan, Claims, Library and Notebook are tabs of the
 *  main area; Changes, Files, Figures, Jobs, History and Learning open in the research panel (Jobs
 *  marked read). Passing one of those to `setMainTab` showed another panel under the Chat tab. */
export function show(tab: InspectorTab) {
  if ((mainTabs as string[]).includes(tab)) { setMainTab(tab); return; }
  setState((s) => ({
    inspectorTab: tab, showInspector: true, showSettingsPage: false,
    ...(tab === "jobs" ? { jobs: Object.fromEntries(Object.entries(s.jobs).map(([k, j]) => [k, { ...j, unread: 0 }])) } : {}),
  }));
}

/** A job's log: the Jobs panel with that job selected (ChatView's job notification "Log"). */
export function showJob(id: string) { setState({ selectedJob: id }); show("jobs"); }
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

/** YOLO mode is asked about first: nothing is sandboxed and nothing is asked. */
export async function setPermissionMode(mode: Config["permissionMode"]) {
  if (mode === "yolo" && getState().config.permissionMode !== "yolo") {
    const ok = await confirmDialog(L("Turn on YOLO mode?"),
      L("Agents run commands and edit files without asking, and nothing runs in the sandbox: a command can change anything your user account can. Only the safety deny list still applies (sudo, rm -rf /, force pushes …)."),
      L("Turn On"), L("Cancel"), true);
    if (!ok) return;
  }
  void updateConfig({ permissionMode: mode });
}

/** What commands actually run under (SandboxMode.effective): auto mode always sandboxes, YOLO never does. */
export function effectiveSandbox(c: Pick<Config, "permissionMode" | "sandboxMode">): Config["sandboxMode"] {
  return c.permissionMode === "yolo" ? "off" : c.permissionMode === "auto" && c.sandboxMode === "off" ? "workspaceWrite" : c.sandboxMode;
}

/** The sandbox choice, kept consistent with the mode: no sandbox in auto mode is YOLO, a sandbox in YOLO is auto. */
export async function setSandbox(m: Config["sandboxMode"]) {
  const mode = getState().config.permissionMode;
  if (m === "off" && mode === "auto") { await setPermissionMode("yolo"); return; }
  void updateConfig(mode === "yolo" && m !== "off" ? { permissionMode: "auto", sandboxMode: m } : { sandboxMode: m });
}

// MARK: Turns

export async function send(text: string, attachments: string[] = []) {
  if (!getState().live) await resumeIfNeeded();
  if (!getState().live) {
    // Never drop what the user typed: put it back and let the setup card explain what is missing.
    setState((st) => ({ draft: text, lastError: st.lastError ?? (st.workspace === null ? L("Open a workspace first.") : L("No model is set up yet.")) }));
    return;
  }
  const trimmed = text.trim();
  if (!trimmed && attachments.length === 0) return;
  // Commands that open native UI.
  if (trimmed === "/providers") { openSettings("providers"); return; }
  if (trimmed === "/config") { openSettings(); return; }
  if (trimmed === "/clear") { await startSession(); return; }
  if (trimmed === "/fork") { await forkTask(getState().taskId); return; }
  if (trimmed === "/doctor") {
    // Support.swift's Doctor, run by serve: tools, sandbox, providers, search key and network.
    deliver({ type: "notice", text: L("SieveSci doctor") + " …" });
    const r = await call<{ text: string }>("system.doctor");
    if (r) deliver({ type: "notice", text: r.text });
    return;
  }
  const s = getState();
  const item = { id: `u${Date.now()}`, at: Date.now(), kind: { type: "user" as const, text, attachments: attachments.map((a) => a.split(/[\\/]/).pop() ?? a) } };
  setState({ streams: { ...s.streams, main: [...(s.streams.main ?? []), item] }, ...(s.running ? { queued: [...s.queued, text] } : { running: true, runStarted: Date.now() }) });
  await call("task.send", attachments.length ? { text, attachments } : { text });
}

/** Inserts a message into the running turn (DeepSeek Harness's steering): the agent reads it at its
 *  next step. It waits above the composer until then and joins the conversation where it was read
 *  (`userInserted`). With no turn running it is sent as an ordinary message. */
export async function insert(text: string) {
  const t = text.trim();
  if (!t) return;
  if (!getState().running) { await send(text); return; }
  setState((s) => ({ inserting: [...s.inserting, t] }));
  const r = await call<{ inserted: boolean }>("task.insert", { text: t });
  // The turn ended as it arrived: serve sent it as an ordinary message, shown like one.
  if (r && !r.inserted) setState((s) => {
    const i = s.inserting.indexOf(t);
    const item = { id: `u${Date.now()}`, at: Date.now(), kind: { type: "user" as const, text: t, attachments: [] } };
    return { inserting: i < 0 ? s.inserting : [...s.inserting.slice(0, i), ...s.inserting.slice(i + 1)], streams: { ...s.streams, main: [...(s.streams.main ?? []), item] } };
  });
}

/** Moves a queued message into the running turn. Its placeholder in the conversation goes; it comes back
 *  where the agent reads it. One that already started as its own turn stays as it was. */
export async function insertQueued(index: number) {
  const s = getState();
  const text = s.queued[index];
  if (text === undefined || !s.running) return;
  const main = s.streams.main ?? [];
  const at = main.map((m) => m.kind.type === "user" && m.kind.text === text).lastIndexOf(true);
  const removed = at >= 0 ? main[at] : null;
  setState({ queued: s.queued.filter((_, i) => i !== index), inserting: [...s.inserting, text.trim()],
             streams: { ...s.streams, main: at >= 0 ? [...main.slice(0, at), ...main.slice(at + 1)] : main } });
  const r = await call<{ inserted: boolean }>("task.insert", { text, fromQueue: true });
  if (r && !r.inserted) setState((st) => ({
    inserting: st.inserting.filter((x) => x !== text.trim()),
    streams: removed ? { ...st.streams, main: [...(st.streams.main ?? []), removed] } : st.streams,
  }));
}

/** Every queued message into the running turn, oldest first (empty draft + ⌘/Ctrl+Enter). */
export async function insertAllQueued() {
  while (getState().running && getState().queued.length > 0) await insertQueued(0);
}

/** Stop also answers the approval on screen (serve denies it), so the prompt goes too. */
/** AppModel.rewind(to:edit:): back to before this message (the agent forgets what came after); with
 *  edit, the message returns to the composer to be changed and sent again. */
export async function rewind(itemId: string, edit: boolean) {
  const main = getState().streams.main ?? [];
  const users = main.filter((i) => i.kind.type === "user");
  const at = users.findIndex((u) => u.id === itemId);
  if (at < 0) return;
  const item = users[at];
  if (edit && item.kind.type === "user") setState({ draft: item.kind.text });
  const cut = main.findIndex((x) => x.id === itemId);
  setState((st) => ({ streams: { ...st.streams, main: (st.streams.main ?? []).slice(0, cut) } }));
  await call("task.send", { text: `/rewind ${users.length - at}` });
}

/** AppModel.approvePlan: leave plan mode with edits accepted, and tell the agent to go ahead. */
export async function approvePlan() {
  await setPermissionMode("acceptEdits");
  await send(L("The plan is approved. Proceed with it."));
}

export async function stop() { setState({ pendingPermission: null }); await call("task.stop"); }

export async function answerPermission(id: string | undefined, decision: "allow" | "always" | "deny", reason?: string) {
  setState({ pendingPermission: null, demoAsk: null });
  if (id) await call("permission.respond", { id, decision, ...(reason ? { reason } : {}) });
}

export async function answerAsk(id: string, outcome: JsonObject) {
  // The next question, if another agent asked one meanwhile, takes its place.
  setState((s) => { const askQueue = s.askQueue.filter((q) => q.id !== id); return { askQueue, pendingAsk: askQueue[0] ?? null }; });
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

/** Progress of the catalog and leaderboard refresh (serve's `catalogRefresh`: a `line`, then `done`). */
export const catalogRefreshListeners = new Set<(p: { line?: string; done?: boolean }) => void>();

/** Output of a CLI agent's installer (serve's `agentInstall` notifications), by provider id. */
export const agentInstallListeners = new Set<(id: string, lines: string[]) => void>();

// MARK: Task menu (SidebarView's context menu)

export async function copyText(text: string) {
  try { await navigator.clipboard.writeText(text); } catch { /* clipboard unavailable */ }
}

export async function copyTaskMarkdown(id: string) {
  const md = await taskMarkdown(id);
  if (md) await copyText(md);
}

/** Save dialog, then serve writes the file (a browser downloads it instead). */
export async function exportTaskMarkdown(id: string) {
  const name = titleOf(getState(), id, L("New task")).replace(/[\\/:*?"<>|]/g, "-").slice(0, 60) + ".md";
  if (inTauri) {
    const { save } = await import("@tauri-apps/plugin-dialog");
    const path = await save({ defaultPath: name, filters: [{ name: "Markdown", extensions: ["md"] }] });
    if (path) await call("task.markdown", { id, path });
    return;
  }
  const md = await taskMarkdown(id);
  if (!md) return;
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([md], { type: "text/markdown" }));
  a.download = name;
  a.click();
  URL.revokeObjectURL(a.href);
}

/** The task's folder in Finder / Explorer (`folder`: a workspace other than the open one). */
export async function revealTask(id: string, folder?: string) {
  const r = await call<{ dir: string }>("task.markdown", folder ? { id, workspace: folder } : { id });
  if (r?.dir) systemOpen({ path: r.dir, reveal: true });
}

/** Mentions another conversation in the open one's composer. */
export function referenceTask(id: string) { setState({ showSettingsPage: false, mainTab: "chat", draft: `@task:${id} ` }); }

// MARK: Attachments (PromptInput.swift)

/** "Attach files…": the platform's file picker. */
export async function pickFiles(): Promise<string[]> {
  if (!inTauri) return [];
  const { open } = await import("@tauri-apps/plugin-dialog");
  const r = await open({ multiple: true, directory: false });
  return Array.isArray(r) ? r : typeof r === "string" ? [r] : [];
}

/** "Add a read-only folder…": folders agents may read but never change. */
export async function addReadOnlyFolders() {
  if (!inTauri) return;
  const { open } = await import("@tauri-apps/plugin-dialog");
  const r = await open({ multiple: true, directory: true, title: L("Agents can read these folders but never change them.") });
  const paths = Array.isArray(r) ? r : typeof r === "string" ? [r] : [];
  if (paths.length === 0) return;
  const res = await call<{ message: string }>("workspace.addReadOnlyFolders", { paths });
  if (res) deliverNotice(res.message);
}

/** A pasted screenshot is saved into the workspace's inputs/ folder and attached. */
export async function savePastedImage(blob: Blob): Promise<string | null> {
  const buf = new Uint8Array(await blob.arrayBuffer());
  let bin = "";
  for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
  const ext = (blob.type.split("/")[1] ?? "png").replace("jpeg", "jpg");
  const r = await call<{ path: string }>("attachments.savePasted", { base64: btoa(bin), ext });
  return r?.path ?? null;
}

function deliverNotice(text: string) {
  setState((s) => ({ streams: { ...s.streams, main: [...(s.streams.main ?? []), { id: `n${Date.now()}`, at: Date.now(), kind: { type: "notice" as const, text } }] } }));
}
