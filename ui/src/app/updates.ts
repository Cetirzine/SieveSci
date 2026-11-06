// Updates (Updater.swift): the desktop app checks GitHub's latest release through the Tauri updater,
// downloads it (the signature is checked against the key built into the app), installs it and restarts.
// In a browser only the check is possible (serve's updates.check), and the release page opens.
import { inTauri } from "../serve";
import { L } from "../i18n";
import * as A from "./actions";
import { getState } from "./model";
import { notify } from "./notify";

export type UpdateState =
  | { kind: "idle" } | { kind: "checking" } | { kind: "upToDate"; at: number }
  | { kind: "available"; version: string; url?: string }
  | { kind: "downloading"; version: string; progress: number }
  | { kind: "ready"; version: string } | { kind: "installing" } | { kind: "failed"; message: string };

let state: UpdateState = { kind: "idle" };
/** The user asked for this download (the banner shows its progress), or put the banner away. */
export const banner = { userWaiting: false, dismissed: false };
const listeners = new Set<(s: UpdateState) => void>();
// The plugin's Update object, kept between "available" and installing it.
let pending: { version: string; downloadAndInstall?: unknown; download?: (cb: (e: DownloadEvent) => void) => Promise<void>; install?: () => Promise<void> } | null = null;
type DownloadEvent = { event: "Started"; data: { contentLength?: number } } | { event: "Progress"; data: { chunkLength: number } } | { event: "Finished" };

export const updateState = () => state;
export function onUpdate(f: (s: UpdateState) => void) { listeners.add(f); return () => { listeners.delete(f); }; }
function set(s: UpdateState) { state = s; listeners.forEach((f) => f(s)); }

export async function checkForUpdates(manual = true) {
  if (state.kind === "checking" || state.kind === "downloading" || state.kind === "installing") return;
  set({ kind: "checking" });
  if (inTauri) {
    try {
      const { check } = await import("@tauri-apps/plugin-updater");
      const u = await check();
      if (!u) { set({ kind: "upToDate", at: Date.now() }); return; }
      pending = u as never;
      set({ kind: "available", version: u.version });
      // Automatic installs download in the background and wait for a restart (installing on quit).
      if (!manual && getState().config.autoInstallUpdates) await download(false);
    } catch (e) {
      set(manual ? { kind: "failed", message: e instanceof Error ? e.message : String(e) } : { kind: "idle" });
    }
    return;
  }
  const r = await A.request<{ available: boolean; latest: string; url: string }>("updates.check");
  if (!r.ok) set({ kind: "failed", message: r.error });
  else if (r.value.available) set({ kind: "available", version: r.value.latest, url: r.value.url });
  else set({ kind: "upToDate", at: Date.now() });
}

/** Downloads the update; it is installed now (Windows installs as it goes) and applied on restart. */
export async function download(byUser = true) {
  if (state.kind !== "available") return;
  banner.userWaiting = byUser;
  if (!pending?.download) { if (state.url) A.systemOpen({ url: state.url }); return; }
  const version = state.version;
  let total = 0, got = 0;
  set({ kind: "downloading", version, progress: 0 });
  try {
    await pending.download((e) => {
      if (e.event === "Started") total = e.data.contentLength ?? 0;
      else if (e.event === "Progress") { got += e.data.chunkLength; if (total) set({ kind: "downloading", version, progress: got / total }); }
    });
    set({ kind: "installing" });
    await pending.install?.();
    set({ kind: "ready", version });
    notify(L("SieveSci %@ is ready").replace("%@", version), L("Restart"), "update");
  } catch (e) {
    set({ kind: "failed", message: e instanceof Error ? e.message : String(e) });
  }
}

export async function restart() {
  if (!inTauri) return;
  // Updater.swift: a running task stops with the app; it can be resumed after the restart.
  if (getState().running && !(await A.confirmDialog(L("Restart to update now?"), L("A task is still running. It stops now and can be resumed after the restart."), L("Restart"), L("Cancel"), true))) return;
  const { relaunch } = await import("@tauri-apps/plugin-process");
  await relaunch();
}

/** At launch, when automatic checks are on: once after a short wait, then every six hours. */
export function startAutomaticChecks() {
  const tick = () => { if (getState().config.autoCheckUpdates) void checkForUpdates(false); };
  setTimeout(tick, 15_000);
  setInterval(tick, 6 * 3600_000);
}

export function dismissBanner() { banner.dismissed = true; set({ ...state }); }

/** "Check for Updates…" from the menu: the answer is shown whatever it is (Updater.swift's alerts);
 *  an available update brings the banner back even if it was put away. */
export async function checkFromMenu() {
  banner.dismissed = false;
  await checkForUpdates(true);
  const s = updateState();
  if (s.kind === "upToDate") await A.messageDialog(L("SieveSci is up to date"), L("You have the latest version") + ` (${getState().version}).`);
  else if (s.kind === "failed") await A.messageDialog(L("Couldn't check for updates"), s.message, true);
}
