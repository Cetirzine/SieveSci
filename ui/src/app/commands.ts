// The app's commands and shortcuts (SieveSciApp.swift `.commands`): the macOS menu bar in the desktop
// app, and the same shortcuts as keys everywhere else (⌘ on macOS, Ctrl on Windows and Linux).
import { inTauri } from "../serve";
import { L } from "../i18n";
import * as A from "./actions";
import { getState, mainTabs, setState, type InspectorTab, type MainTab } from "./model";
import { checkForUpdates } from "./updates";

const modes = ["ask", "acceptEdits", "auto", "plan"] as const;
const sideTabs: InspectorTab[] = ["changes", "files", "figures", "jobs", "history", "learning"];

export const commands = {
  settings: () => A.openSettings(),
  newTask: () => void A.startSession(),
  openWorkspace: () => void A.chooseWorkspace(),
  interrupt: () => void A.stop(),
  cycleMode: () => { const m = getState().config.permissionMode; A.setPermissionMode(modes[(modes.indexOf(m) + 1) % modes.length]); },
  fork: () => { const id = getState().taskId; if (id) void A.forkTask(id); },
  review: () => void A.send("/review"),
  report: () => void A.send("/report"),
  refreshCatalogs: () => void A.send("/refresh"),
  toggleInspector: () => A.toggleInspector(),
  mainTab: (t: MainTab) => A.setMainTab(t),
  sideTab: (t: InspectorTab) => setState({ inspectorTab: t, showInspector: true, showSettingsPage: false }),
  checkUpdates: () => void checkForUpdates(true),
};

const isMac = typeof navigator !== "undefined" && /Mac/.test(navigator.platform);
/** The desktop app on macOS takes its shortcuts from the menu bar; everywhere else they are keys here. */
const menuBar = inTauri && isMac;

/** Keyboard shortcuts (when the menu bar does not handle them). */
export function installShortcuts(): () => void {
  if (menuBar) return () => {};
  const onKey = (e: KeyboardEvent) => {
    const mod = isMac ? e.metaKey : e.ctrlKey;
    const k = e.key.toLowerCase();
    let run: (() => void) | null = null;
    if (mod && !e.altKey && !e.shiftKey) {
      if (k === ",") run = commands.settings;
      else if (k === "n") run = commands.newTask;
      else if (k === "o") run = commands.openWorkspace;
      else if (k === ".") run = commands.interrupt;
      else if (/^[1-9]$/.test(k) && mainTabs[Number(k) - 1]) run = () => commands.mainTab(mainTabs[Number(k) - 1]);
    } else if (mod && e.shiftKey && !e.altKey && k === "r") run = commands.review;
    else if (mod && e.altKey && (k === "i" || e.code === "KeyI")) run = commands.toggleInspector;
    else if (mod && e.altKey && /^Digit[1-9]$/.test(e.code) && sideTabs[Number(e.code.slice(5)) - 1]) run = () => commands.sideTab(sideTabs[Number(e.code.slice(5)) - 1]);
    else if (!mod && !e.altKey && e.shiftKey && e.key === "Tab" && !(e.target as HTMLElement)?.closest?.("input, textarea, select")) run = commands.cycleMode;
    if (run) { e.preventDefault(); run(); }
  };
  window.addEventListener("keydown", onKey);
  return () => window.removeEventListener("keydown", onKey);
}

const tabTitle = (t: MainTab) => ({ chat: L("Chat"), activity: L("Trace"), plan: L("Plan"), claims: L("Claims"), library: L("Library"), notebook: L("Notebook") } as Record<string, string>)[t] ?? t;
const sideTitle = (t: InspectorTab) => ({ changes: L("Changes"), files: L("Files"), figures: L("Figures"), jobs: L("Jobs"), history: L("History"), learning: L("Learning") } as Record<string, string>)[t] ?? t;

/** The macOS menu bar, in the interface language (built again when it changes). */
export async function installMenuBar(version: string) {
  if (!menuBar) return;
  const { Menu, Submenu, MenuItem, PredefinedMenuItem } = await import("@tauri-apps/api/menu");
  const item = (text: string, action: () => void, accelerator?: string) => MenuItem.new({ text, action, accelerator });
  const sep = () => PredefinedMenuItem.new({ item: "Separator" });
  const app = await Submenu.new({ text: "SieveSci", items: [
    await PredefinedMenuItem.new({ item: { About: { name: "SieveSci", version, copyright: L("Independently developed by 王鹤年, 2026") } }, text: L("About SieveSci") }),
    await item(L("Check for Updates…"), commands.checkUpdates),
    await sep(),
    await item(L("Settings") + "…", commands.settings, "CmdOrCtrl+,"),
    await sep(),
    await PredefinedMenuItem.new({ item: "Services" }),
    await sep(),
    await PredefinedMenuItem.new({ item: "Hide" }),
    await PredefinedMenuItem.new({ item: "HideOthers" }),
    await PredefinedMenuItem.new({ item: "ShowAll" }),
    await sep(),
    await PredefinedMenuItem.new({ item: "Quit" }),
  ] });
  const file = await Submenu.new({ text: L("File"), items: [
    await item(L("New Task"), commands.newTask, "CmdOrCtrl+N"),
    await item(L("Open Workspace…"), commands.openWorkspace, "CmdOrCtrl+O"),
    await sep(),
    await PredefinedMenuItem.new({ item: "CloseWindow" }),
  ] });
  // Copy, paste and select-all in text fields need these in a custom menu bar.
  const edit = await Submenu.new({ text: L("Edit"), items: [
    await PredefinedMenuItem.new({ item: "Undo" }), await PredefinedMenuItem.new({ item: "Redo" }), await sep(),
    await PredefinedMenuItem.new({ item: "Cut" }), await PredefinedMenuItem.new({ item: "Copy" }), await PredefinedMenuItem.new({ item: "Paste" }),
    await PredefinedMenuItem.new({ item: "SelectAll" }),
  ] });
  const agent = await Submenu.new({ text: L("Agent"), items: [
    await item(L("Interrupt"), commands.interrupt, "CmdOrCtrl+."),
    await item(L("Cycle Permission Mode"), commands.cycleMode, "Shift+Tab"),
    await item(L("Fork Task"), commands.fork),
    await item(L("Review Now"), commands.review, "CmdOrCtrl+Shift+R"),
    await sep(),
    await item(L("Export Report…"), commands.report),
    await item(L("Refresh Catalogs & Leaderboards"), commands.refreshCatalogs),
  ] });
  const view = await Submenu.new({ text: L("View"), items: [
    await item(L("Toggle Research Panel"), commands.toggleInspector, "CmdOrCtrl+Alt+I"),
    await sep(),
    ...(await Promise.all(mainTabs.map((t, i) => item(tabTitle(t), () => commands.mainTab(t), `CmdOrCtrl+${i + 1}`)))),
    await sep(),
    ...(await Promise.all(sideTabs.map((t, i) => item(sideTitle(t), () => commands.sideTab(t), `CmdOrCtrl+Alt+${i + 1}`)))),
  ] });
  const window = await Submenu.new({ text: L("Window"), items: [
    await PredefinedMenuItem.new({ item: "Minimize" }), await PredefinedMenuItem.new({ item: "Maximize" }), await sep(),
    await PredefinedMenuItem.new({ item: "Fullscreen" }),
  ] });
  const menu = await Menu.new({ items: [app, file, edit, agent, view, window] });
  await menu.setAsAppMenu();
}
