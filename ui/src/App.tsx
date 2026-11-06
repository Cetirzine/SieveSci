// The app shell: demo scenes (?demo=…) for parity screenshots, otherwise a live connection to
// `sievesci serve` through Tauri (desktop) or the dev bridge (browser).
import { useEffect } from "react";
import { inTauri, ServeClient, socketTransport, tauriTransport, type Transport } from "./serve";
import { L, setLanguage, type Language } from "./i18n";
import { deliver, getState, setState, taskStatus, useApp } from "./app/model";
import * as A from "./app/actions";
import { demoScene, loadDemo } from "./app/demo";
import { RootView } from "./views/Frame";
import { WelcomeView } from "./views/Welcome";
import { ChatView } from "./views/ChatView";
import { SettingsPage } from "./views/Settings";
import { applyAppearance } from "./theme/theme";

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
        c.onEvent(deliver);
        c.onOutput((p) => { if (p.task === undefined || p.task === getState().taskId) deliver({ type: "notice", text: String(p.text ?? "") }); });
        // Development: the connection and its notifications, for the browser console.
        if (import.meta.env.DEV) {
          const w = window as unknown as { __serve?: ServeClient; __notes?: unknown[]; __state?: typeof getState };
          w.__serve = c; w.__notes = []; w.__state = getState;
          c.onNotification((method, p) => { w.__notes!.push({ method, ...p }); });
        }
        c.onNotification((method, p) => {
          if (method !== "taskStatus") return;
          taskStatus(p);
          // A background task was released: its row shows its new time (AppModel+Events).
          if (p.stage === null) { void A.refreshTaskList(); A.refreshOpenFolders(); }
        });
        const info = await c.call<{ version: string; languageChoice?: string; platform?: "macos" | "windows" | "linux" }>("initialize", { client: inTauri ? "desktop" : "browser" });
        A.attach(c);
        // The language is shared with the macOS app and the CLI; a choice made here before wins only
        // when none was made there.
        const local = stored("language") as Language | null;
        const choice = (info.languageChoice && info.languageChoice !== "system" ? info.languageChoice : local ?? "system") as Language;
        setLanguage(choice);
        setState({ version: info.version, languageChoice: choice, ...(info.platform ? { platform: info.platform } : {}) });
        if (local && local !== info.languageChoice) void c.call("language.set", { language: local });
        await A.refreshConfig();
        void A.loadCommands();
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
      panel={(t) => <div className="secondary">{t}</div>}
      settings={<SettingsPage />}
      inspector={<div className="panel-column secondary">{L("Research panel")}</div>}
    />
  );
}
