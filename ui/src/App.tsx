// The app shell: demo scenes (?demo=…) for parity screenshots, otherwise a live connection to
// `sievesci serve` through Tauri (desktop) or the dev bridge (browser).
import { useEffect } from "react";
import { inTauri, ServeClient, socketTransport, tauriTransport, type Transport } from "./serve";
import { loadLanguage, setLanguage, type Language } from "./i18n";
import { deliver, getState, setState, taskStatus, useApp } from "./app/model";
import * as A from "./app/actions";
import { demoScene, loadDemo } from "./app/demo";
import { RootView } from "./views/Frame";
import { WelcomeView } from "./views/Welcome";
import { ChatView } from "./views/ChatView";
import { SettingsPage } from "./views/Settings";
import { InspectorView, MainPanel } from "./views/Panels";
import type { InspectorTab } from "./app/model";
import { applyAppearance } from "./theme/theme";
import { notify } from "./app/notify";
import { startAutomaticChecks } from "./app/updates";
import { installMenuBar, installShortcuts } from "./app/commands";
import { L } from "./i18n";
import { titleOf, type AskRequest } from "./app/model";
import type { JsonObject } from "./serve";

/** The notifications AppModel posts for an event (each behind its Live monitoring setting). */
function notifyFor(e: JsonObject) {
  const s = getState(), c = s.config;
  const str = (k: string) => String(e[k] ?? "");
  const mine = e.task === undefined || e.task === s.taskId;
  const task = typeof e.task === "string" ? e.task : s.taskId;
  switch (e.type) {
    case "turnFinished":
      if (mine && str("agentId") === "main" && c.notifyTurnFinished) {
        const last = [...(s.streams.main ?? [])].reverse().find((i) => i.kind.type === "assistant");
        notify(L("SieveSci finished"), last && last.kind.type === "assistant" ? last.kind.text.slice(0, 160) : titleOf(s, task, L("New task")), `turn-${task}`);
      }
      break;
    case "jobNotification": {
      if (!mine || !c.notifyJobs) break;
      const n = e.notification as JsonObject;
      const kind = String(n.kind);
      const head = kind === "failed" ? L("Job failed") : kind === "stalled" ? L("Job stalled") : kind === "matched" ? L("Job update") : L("Job finished");
      notify(`${head}: ${String(n.job)}`, String(n.text ?? "").slice(0, 200), `job-${String(n.job)}-${kind}-${String(n.at)}`);
      break;
    }
    case "permissionRequested": {
      const r = e.request as JsonObject;
      // A background task's request always says so (it waits until the user comes back to it).
      if (!mine) notify(L("Permission needed"), `${titleOf(s, task, L("New task"))} · ${String(r.tool)}: ${String(r.summary).slice(0, 120)}`, `perm-${String(r.id)}`);
      else if (c.notifyPermission) notify(L("Permission needed"), `${String(r.tool)}: ${String(r.summary).slice(0, 140)}`, `perm-${String(r.id)}`);
      break;
    }
    case "askRequested": {
      const r = e.request as unknown as AskRequest;
      if (c.notifyPermission) notify(L("SieveSci has a question"), r.questions[0]?.question ?? "", `ask-${r.id}`);
      break;
    }
  }
}

/** A task entering a stage that needs the user, or a background task finishing (AppModel.refreshStage). */
function notifyStage(p: JsonObject) {
  const s = getState();
  const id = String(p.task ?? "");
  const before = s.attention[id];
  const st = p.stage as JsonObject | null;
  const title = titleOf(s, id, L("New task"));
  if (st && st.needsPerson === true && before?.needsPerson !== true) {
    const detail = String(st.detail ?? "");
    notify(L("SieveSci needs you") + " · " + String(st.label ?? ""), title + (detail ? " — " + detail.slice(0, 140) : ""), `attn-${id}`);
  } else if (!st && id !== s.taskId && s.backgroundTasks.includes(id) && s.config.notifyTurnFinished && before?.needsPerson !== true) {
    notify(L("SieveSci finished"), title, `turn-${id}`);
  }
}

const stored = (k: string) => { try { return localStorage.getItem(k); } catch { return null; } };

export default function App() {
  const scene = demoScene();
  const appearance = useApp((s) => s.config.appearance);
  const accent = useApp((s) => s.accent);

  useEffect(() => {
    const lang = stored("language") as Language | null;
    if (lang) setLanguage(lang);
    const params = new URLSearchParams(location.search);
    if (scene) { applyAppearance((params.get("appearance") ?? "system") as "system" | "light" | "dark", "blue"); loadDemo(scene); return; }
    const pane = stored("settingsPane"), accentTheme = stored("accentTheme");
    setState({ sidebarVisible: stored("sidebarVisible") !== "0", ...(pane ? { settingsPane: pane as never } : {}), ...(accentTheme ? { accent: accentTheme as never } : {}) });
  }, [scene]);

  useEffect(() => { if (!scene) applyAppearance(appearance, accent); }, [scene, appearance, accent]);
  // Back in the window: look again for what may have changed outside it (a CLI installed from a
  // terminal, a key set elsewhere), at most every few seconds.
  useEffect(() => {
    if (scene) return;
    let last = 0;
    const onFocus = () => { if (Date.now() - last > 3000) { last = Date.now(); void A.refreshConfig(); } };
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [scene]);

  // Menu bar (macOS desktop) and keyboard shortcuts; the menu follows the interface language.
  const languageChoice = useApp((s) => s.languageChoice);
  const version = useApp((s) => s.version);
  useEffect(() => installShortcuts(), []);
  // Web links (a reply's database records and papers, a panel's DOI) open in the system browser: the
  // desktop app's web view does not open new windows, so a plain link would do nothing there.
  useEffect(() => {
    const onClick = (e: MouseEvent) => {
      const a = (e.target as HTMLElement | null)?.closest?.("a[href]") as HTMLAnchorElement | null;
      if (!a || !/^(https?:|mailto:)/i.test(a.getAttribute("href") ?? "")) return;
      e.preventDefault();
      A.systemOpen({ url: a.href });
    };
    document.addEventListener("click", onClick);
    return () => document.removeEventListener("click", onClick);
  }, []);
  useEffect(() => { if (!scene && version) void installMenuBar(version); }, [scene, version, languageChoice]);

  // Live: one serve connection for the window, as the app has one AppModel. It reopens the last
  // workspace and resumes its latest task (AppModel.init → resumeIfNeeded).
  useEffect(() => {
    if (scene) return;
    let cancelled = false;
    let transport: Transport | undefined;
    (async () => {
      try {
        const t = inTauri ? await tauriTransport() : await socketTransport("ws://127.0.0.1:8787/");
        transport = t;
        if (cancelled) { t.close(); return; }
        const c = new ServeClient(t);
        t.onClose((why) => setState({ lastError: `SieveSci stopped: ${why}`, live: false }));
        c.onEvent((e) => {
          deliver(e); notifyFor(e);
          // Plan limits and balances move with each turn (AppModel.turnMaybeEnded → refreshQuotas).
          if (e.type === "turnFinished" && e.agentId === "main" && e.task === getState().taskId) void A.refreshQuotas();
        });
        c.onOutput((p) => { if (p.task === undefined || p.task === getState().taskId) deliver({ type: "notice", text: String(p.text ?? "") }); });
        // Development: the connection and its notifications, for the browser console.
        if (import.meta.env.DEV) {
          const w = window as unknown as { __serve?: ServeClient; __notes?: unknown[]; __state?: typeof getState };
          w.__serve = c; w.__notes = []; w.__state = getState;
          c.onNotification((method, p) => { w.__notes!.push({ method, ...p }); });
        }
        c.onNotification((method, p) => {
          if (method === "catalogRefresh") { A.catalogRefreshListeners.forEach((f) => f({ line: typeof p.line === "string" ? p.line : undefined, done: p.done === true })); return; }
          if (method === "agentInstall") { A.agentInstallListeners.forEach((f) => f(String(p.id), (p.lines ?? []) as string[])); return; }
          if (method !== "taskStatus") return;
          notifyStage(p);
          taskStatus(p);
          // A background task was released: its row shows its new time (AppModel+Events).
          if (p.stage === null) { void A.refreshTaskList(); A.refreshOpenFolders(); }
        });
        const info = await c.call<{ version: string; languageChoice?: string; platform?: "macos" | "windows" | "linux"; sandbox?: boolean }>("initialize", { client: inTauri ? "desktop" : "browser" });
        A.attach(c);
        // The language is shared with the macOS app and the CLI; a choice made here before wins only
        // when none was made there.
        const local = stored("language") as Language | null;
        const choice = (info.languageChoice && info.languageChoice !== "system" ? info.languageChoice : local ?? "system") as Language;
        await loadLanguage(choice);
        setState({ version: info.version, languageChoice: choice, ...(info.platform ? { platform: info.platform } : {}), sandbox: info.sandbox ?? info.platform !== "windows" });
        if (local && local !== info.languageChoice) void c.call("language.set", { language: local });
        await A.refreshConfig();
        void A.loadCommands();
        startAutomaticChecks();
        const params = new URLSearchParams(location.search);
        const last = params.get("workspace") ?? getState().config.recentWorkspaces[0];
        if (last) await A.openWorkspace(last);
        A.refreshOpenFolders();
      } catch (err) {
        if (!cancelled) setState({ lastError: err instanceof Error ? err.message : String(err) });
      }
    })();
    return () => { cancelled = true; A.attach(null); transport?.close(); };
  }, [scene]);

  return (
    <RootView
      welcome={<WelcomeView onOpenWorkspace={() => void A.chooseWorkspace()} />}
      chat={<ChatView />}
      panel={(t) => <MainPanel tab={t as InspectorTab} />}
      settings={<SettingsPage />}
      inspector={<InspectorView />}
    />
  );
}
