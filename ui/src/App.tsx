// The app shell: demo scenes (?demo=…) for parity screenshots, otherwise a live connection to
// `sievesci serve` through Tauri (desktop) or the dev bridge (browser).
import { useEffect } from "react";
import { inTauri, ServeClient, socketTransport, tauriTransport, type Transport } from "./serve";
import { L, setLanguage, type Language } from "./i18n";
import { deliver, setState, useApp } from "./app/model";
import * as A from "./app/actions";
import { demoScene, loadDemo } from "./app/demo";
import { RootView } from "./views/Frame";
import { WelcomeView } from "./views/Welcome";
import { applyAppearance } from "./theme/theme";

const stored = (k: string) => { try { return localStorage.getItem(k); } catch { return null; } };

export default function App() {
  const workspace = useApp((s) => s.workspace);
  const scene = demoScene();

  useEffect(() => {
    const lang = stored("language") as Language | null;
    if (lang) setLanguage(lang);
    const params = new URLSearchParams(location.search);
    const appearance = (params.get("appearance") ?? "system") as "system" | "light" | "dark";
    applyAppearance(appearance, "blue");
    if (scene) { loadDemo(scene); return; }
    setState({ sidebarVisible: stored("sidebarVisible") !== "0", workspace: params.get("workspace") ?? stored("workspace") });
  }, [scene]);

  // Live: one serve connection per workspace.
  useEffect(() => {
    if (scene || !workspace) return;
    let cancelled = false;
    let transport: Transport | undefined;
    (async () => {
      try {
        const t = inTauri ? await tauriTransport(workspace) : await socketTransport(`ws://127.0.0.1:8787/?workspace=${encodeURIComponent(workspace)}`);
        transport = t;
        if (cancelled) { t.close(); return; }
        const c = new ServeClient(t);
        t.onClose((why) => setState({ lastError: `SieveSci stopped: ${why}` }));
        c.onEvent(deliver);
        c.onOutput((text) => deliver({ type: "notice", text }));
        const info = await c.call<{ version: string; model: string; provider: string; mode: "ask" | "acceptEdits" | "auto" | "plan" }>("initialize", { client: inTauri ? "desktop" : "browser" });
        A.attach(c);
        setState((s) => ({ version: info.version, config: { ...s.config, permissionMode: info.mode },
          modelStatus: { ready: true, text: `${info.provider} / ${info.model}` } }));
        await A.refreshTaskList();
        const list = await c.call<{ tasks: { id: string }[] }>("tasks.list");
        await A.startSession(list.tasks[0]?.id);
      } catch (err) {
        if (!cancelled) setState({ lastError: err instanceof Error ? err.message : String(err) });
      }
    })();
    return () => { cancelled = true; A.attach(null); transport?.close(); };
  }, [scene, workspace]);

  const openWorkspace = async () => {
    if (!inTauri) return;
    const { open } = await import("@tauri-apps/plugin-dialog");
    const dir = await open({ directory: true, multiple: false });
    if (typeof dir === "string") { try { localStorage.setItem("workspace", dir); } catch { /* unavailable */ } A.openWorkspace(dir); }
  };

  return (
    <RootView
      welcome={<WelcomeView onOpenWorkspace={openWorkspace} />}
      chat={<div className="panel-scroll"><div className="panel-column secondary">{L("Chat")}</div></div>}
      panel={(t) => <div className="secondary">{t}</div>}
      settings={<div className="panel-column">{L("Settings")}</div>}
      inspector={<div className="panel-column secondary">{L("Research panel")}</div>}
    />
  );
}
