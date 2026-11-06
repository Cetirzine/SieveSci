// Window frame, ported from Sources/SieveSciApp/SieveSciApp.swift: RootView, AppMark, SidebarView,
// TaskRow, StageChip, NeedsYouList, MainArea, TopBar, ModeMenu, JobsMenu, ResearchStatus.
import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { L, L10n, resolvedLanguage } from "../i18n";
import { useApp, titleOf, isFolderOpen, mainTabs, type MainTab, type AppState, type Attention } from "../app/model";
import * as A from "../app/actions";
import { ActionButton, Chip, IconButton, Menu, SectionLabel } from "../theme/primitives";
import { BrandLogo, RoleGhostBadge } from "../theme/brand";
import { Symbol } from "../theme/theme";

export function RootView({ chat, panel, settings, welcome, inspector }: { chat: ReactNode; panel: (t: MainTab) => ReactNode; settings: ReactNode; welcome: ReactNode; inspector: ReactNode }) {
  const showSettings = useApp((s) => s.showSettingsPage);
  const sidebar = useApp((s) => s.sidebarVisible);
  const workspace = useApp((s) => s.workspace);
  const showInspector = useApp((s) => s.showInspector);
  if (showSettings) return <>{settings}</>;
  return (
    <div className="root">
      {sidebar && <><SidebarView /><div className="v-hairline" /></>}
      {workspace === null ? welcome : (
        <>
          <MainArea chat={chat} panel={panel} />
          {showInspector && <aside className="inspector-column">{inspector}</aside>}
        </>
      )}
    </div>
  );
}

export function AppMark() {
  return <span className="app-mark"><BrandLogo size={32} /><span>SieveSci</span></span>;
}

const basename = (p: string) => p.split(/[\\/]/).filter(Boolean).pop() ?? p;

function SidebarView() {
  const workspace = useApp((s) => s.workspace);
  const recent = useApp((s) => s.config.recentWorkspaces);
  const tasks = useApp((s) => s.tasks);
  const folderTasks = useApp((s) => s.folderTasks);
  const backgroundWorkspaces = useApp((s) => s.backgroundWorkspaces);
  const state = useApp((s) => s);
  const others = recent.filter((p) => p !== workspace);
  const noTasks = <div className="no-tasks t-meta tertiary">{L("No tasks yet")}</div>;
  const disclosure = (path: string) => {
    const open = isFolderOpen(state, path);
    const label = open ? L("Collapse folder") : L("Expand folder");
    return (
      <button type="button" className="icon-button disclosure" title={label} aria-label={label} onClick={() => A.setFolder(path, !open)}>
        <span className="disclosure-box"><Symbol name={open ? "minus" : "plus"} size={8} strokeWidth={3.5} /></span>
      </button>
    );
  };
  const newTaskButton = (onClick: () => void) => (
    <IconButton symbol="square.and.pencil" label={L("New conversation in this folder")} onClick={onClick} className="new-in-folder" />
  );
  const row = (icon: string, title: string, accent: boolean) => (
    <span className="folder-row">
      <Symbol name={icon} size={13} className={accent ? "c-accent" : "secondary"} style={accent ? { fill: "currentColor" } : undefined} />
      <span className="t-body clip">{title}</span>
    </span>
  );
  return (
    <nav className="sidebar">
      <div className="sidebar-head">
        <AppMark />
        <IconButton symbol="sidebar.left" label={L("Hide sidebar")} onClick={() => A.setSidebarVisible(false)} />
      </div>
      <div className="sidebar-new">
        <ActionButton fill disabled={workspace === null} onClick={() => void A.startSession()}>
          <Symbol name="plus" size={13} strokeWidth={2.25} /> {L("New task")}
        </ActionButton>
      </div>
      <NeedsYouList />
      <div className="sidebar-section">
        <SectionLabel>{L("Workspace")}</SectionLabel>
        <IconButton symbol="folder.badge.plus" label={L("Open Workspace…")} onClick={() => { /* platform folder picker */ }} />
      </div>
      <div className="sidebar-scroll">
        {workspace && (
          <>
            <div className="folder-line" title={workspace}>
              {row("folder.fill", basename(workspace), true)}
              {disclosure(workspace)}
              {newTaskButton(() => void A.startSession())}
            </div>
            {isFolderOpen(state, workspace) && (tasks.length === 0 ? noTasks : tasks.map((t) => <TaskRow key={t.id} id={t.id} modified={t.modified} />))}
          </>
        )}
        {others.map((path) => (
          <div key={path}>
            <div className="folder-line">
              <button type="button" className="hover-row folder-button" title={path} onClick={() => A.openWorkspace(path)}>
                {row("folder", basename(path), false)}
                {Object.values(backgroundWorkspaces).includes(path) && <RoleGhostBadge role="main" working size={18} />}
              </button>
              {disclosure(path)}
              {newTaskButton(() => A.openWorkspace(path))}
            </div>
            {isFolderOpen(state, path) && ((folderTasks[path] ?? []).length === 0 ? noTasks
              : (folderTasks[path] ?? []).map((t) => <TaskRow key={t.id} id={t.id} modified={t.modified} folder={path} />))}
          </div>
        ))}
      </div>
      <button type="button" className="hover-row settings-row" onClick={A.openSettings}>
        <Symbol name="gearshape" size={14} /> <span className="t-body">{L("Settings")}</span>
      </button>
    </nav>
  );
}

/** Relative date like the SwiftUI .relative(presentation: .named, unitsStyle: .narrow). */
export function relativeTime(ms: number, now = Date.now()): string {
  const rtf = new Intl.RelativeTimeFormat(resolvedLanguage(), { numeric: "auto", style: "narrow" });
  const s = Math.round((ms - now) / 1000);
  const abs = Math.abs(s);
  if (abs < 60) return rtf.format(s, "second");
  if (abs < 3600) return rtf.format(Math.round(s / 60), "minute");
  if (abs < 86400) return rtf.format(Math.round(s / 3600), "hour");
  if (abs < 7 * 86400) return rtf.format(Math.round(s / 86400), "day");
  if (abs < 30 * 86400) return rtf.format(Math.round(s / (7 * 86400)), "week");
  return rtf.format(Math.round(s / (30 * 86400)), "month");
}

function TaskRow({ id, modified, folder }: { id: string; modified: number; folder?: string }) {
  const [hovering, setHovering] = useState(false);
  const selected = useApp((s) => folder === undefined && id === s.taskId);
  const title = useApp((s) => titleOf(s, id, L("New task")));
  const running = useApp((s) => (selected && s.running) || s.backgroundTasks.includes(id));
  const attention = useApp((s) => s.attention[id]);
  const open = () => {
    if (folder) { A.openWorkspace(folder); void A.startSession(id); }
    else if (!selected) void A.startSession(id);
  };
  return (
    <div className={`task-row ${selected ? "selected" : ""}`} onMouseEnter={() => setHovering(true)} onMouseLeave={() => setHovering(false)} title={`${title}\n${id}`}>
      <button type="button" className="hover-row task-row-button" onClick={open}>
        <span className="t-body clip">{title}</span>
        <span className="task-row-trailing">
          {hovering && !folder ? <span style={{ width: 22 }} />
            : attention && stageShowsChip(attention) ? <StageChip attention={attention} />
            : running ? <RoleGhostBadge role="main" working size={20} />
            : <span className="t-caption tertiary">{relativeTime(modified)}</span>}
        </span>
      </button>
      {hovering && !folder && <IconButton symbol="xmark" label={L("Delete conversation…")} className="task-delete" onClick={() => A.deleteTask(id)} />}
    </div>
  );
}

const needsPerson = (a: Attention) => a.stage === "answer" || a.stage === "review" || a.stage === "blocked";
const stageShowsChip = (a: Attention) => a.stage === "waitingForJobs" || needsPerson(a);
function stageLabel(a: Attention): string {
  return ({ answer: L("Needs your answer"), review: L("Plan to approve"), blocked: L("Blocked"), working: L("Working"), waitingForJobs: L("Waiting for jobs") } as Record<string, string>)[a.stage] ?? "";
}

function StageChip({ attention }: { attention: Attention }) {
  const tint = attention.stage === "answer" || attention.stage === "review" ? "var(--warn)" : attention.stage === "blocked" ? "var(--bad)" : "var(--info)";
  return <span title={attention.detail}><Chip text={stageLabel(attention)} tint={tint} /></span>;
}

function NeedsYouList() {
  const attention = useApp((s) => s.attention);
  const workspace = useApp((s) => s.workspace);
  const titles = useApp((s) => s.taskTitles);
  const items = Object.entries(attention).filter(([, a]) => needsPerson(a));
  if (items.length === 0) return null;
  return (
    <div className="needs-you">
      <div className="needs-you-label"><SectionLabel>{L("Needs you")} · {items.length}</SectionLabel></div>
      {items.map(([id, a]) => (
        <button key={id} type="button" className="hover-row needs-you-item appear-pop" onClick={() => void A.startSession(id)}>
          <span className="needs-you-top"><span className="t-body clip">{titles[id] ?? L("New task")}</span><StageChip attention={a} /></span>
          {a.detail && <span className="t-caption secondary">{a.detail}</span>}
          {a.workspace !== workspace && <span className="t-caption tertiary">{basename(a.workspace)}</span>}
        </button>
      ))}
    </div>
  );
}

function MainArea({ chat, panel }: { chat: ReactNode; panel: (t: MainTab) => ReactNode }) {
  const tab = useApp((s) => s.mainTab);
  return (
    <main className="main-area">
      <TopBar />
      <div className="h-hairline" />
      {tab === "chat" ? chat : <div className="panel-scroll"><div className="panel-column">{panel(tab)}</div></div>}
    </main>
  );
}

function tabTitle(t: MainTab): string {
  return ({ chat: L("Chat"), activity: L("Trace"), plan: L("Plan"), claims: L("Claims"), library: L("Library"), notebook: L("Notebook"),
    changes: L("Changes"), files: L("Files"), figures: L("Figures"), jobs: L("Jobs"), history: L("History"), learning: L("Learning") } as Record<MainTab, string>)[t];
}

function TopBar() {
  const sidebar = useApp((s) => s.sidebarVisible);
  const tab = useApp((s) => s.mainTab);
  // The same title as the sidebar row: the user's name for it, the generated title, or (until one
  // arrives) the first question.
  const title = useApp((s) => {
    const t = s.taskTitles[s.taskId];
    if (t) return t;
    for (const it of s.streams.main ?? []) if (it.kind.type === "user") return it.kind.text.slice(0, 60);
    return L("New task");
  });
  const badge = useApp((s) => s.contested.length + s.claims.filter((c) => c.status === "verifying").length);
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(1000);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const tabsRef = useRef<HTMLDivElement>(null);
  const [underline, setUnderline] = useState<{ left: number; width: number } | null>(null);
  useEffect(() => {
    const b = tabsRef.current?.querySelector<HTMLButtonElement>(`[data-tab="${tab}"] .tab-text`);
    if (b) setUnderline({ left: b.offsetLeft, width: b.offsetWidth });
  }, [tab, width, badge]);
  return (
    <div className="top-bar" ref={ref} style={{ paddingLeft: sidebar ? 24 : 80 }}>
      <div className="top-bar-row">
        {!sidebar && <IconButton symbol="sidebar.left" label={L("Show sidebar")} onClick={() => A.setSidebarVisible(true)} />}
        <span className="top-title">{title}</span>
        {width > 720 && <ModeMenu />}
        {width > 900 && <JobsMenu />}
        <span style={{ flex: 1, minWidth: 12 }} />
        {width > 560 && <ResearchStatus />}
        <span className="top-icons">
          <IconButton symbol="square.and.arrow.down" label={L("Export Report…")} onClick={() => void A.send("/report")} />
          <IconButton symbol="sidebar.right" label={L("Research panel")} onClick={A.toggleInspector} />
        </span>
      </div>
      <div className="tabs" ref={tabsRef}>
        {mainTabs.map((t) => (
          <button key={t} type="button" data-tab={t} className={`tab ${t === tab ? "selected" : ""}`} onClick={() => A.setMainTab(t)}>
            <span className="tab-text">{tabTitle(t)}</span>
            {t === "claims" && badge > 0 && <span className="tab-badge">{badge}</span>}
          </button>
        ))}
        {underline && <span className="tab-underline" style={{ transform: `translateX(${underline.left}px)`, width: underline.width }} />}
      </div>
    </div>
  );
}

export function modeStyle(mode: AppState["config"]["permissionMode"]): { icon: string; text: string; tint: string } {
  switch (mode) {
    case "ask": return { icon: "hand.raised", text: L("ask before edits & code"), tint: "var(--secondary)" };
    case "acceptEdits": return { icon: "pencil", text: L("accept edits on"), tint: "var(--accent)" };
    case "auto": return { icon: "bolt", text: L("auto mode on"), tint: "var(--warn)" };
    case "plan": return { icon: "pause.circle", text: L("plan mode on"), tint: "var(--info)" };
  }
}

function ModeMenu() {
  const mode = useApp((s) => s.config.permissionMode);
  const m = modeStyle(mode);
  return (
    <Menu className="mode-menu" title={L("(⇧⇥ to cycle)")} label={<><Symbol name={m.icon} size={12} /> {m.text}</>}
          items={(["ask", "acceptEdits", "auto", "plan"] as const).map((x) => ({ label: <><Symbol name={modeStyle(x).icon} size={12} /> {modeStyle(x).text}</>, onSelect: () => A.setPermissionMode(x), checked: x === mode }))} />
  );
}

function JobsMenu() {
  const running = useApp((s) => s.jobOrder.map((id) => s.jobs[id]).filter((j) => j?.running));
  if (running.length === 0) return null;
  return (
    <Menu className="jobs-menu" label={<>{L10n.f("%d background jobs running", running.length)} <Symbol name="chevron.down" size={11} strokeWidth={2.5} /></>}
          items={running.map((j) => ({ label: `${j.id} · ${j.label}`, onSelect: () => setTimeoutJobs() }))} />
  );
}
const setTimeoutJobs = () => A.setMainTab("jobs");

function ResearchStatus() {
  const plan = useApp((s) => s.plan);
  const grounding = useApp((s) => s.grounding);
  const claims = useApp((s) => s.claims);
  const contested = useApp((s) => s.contested.length);
  const verified = claims.filter((c) => c.status === "verified").length;
  return (
    <span className="research-status">
      {(plan.goal !== "" || plan.stage !== "scoping") && (
        <button type="button" className="plain" title={L("Stage")} onClick={() => A.setMainTab("plan")}><Symbol name="flag" size={12} /> {L(plan.stage)}</button>
      )}
      {grounding && (
        <span className="grounding" title={L("Grounding gate: both searches must succeed before planning, claims and checkpoints")}>
          <span className={grounding.web ? "c-ok" : ""}><Symbol name={grounding.web ? "checkmark.circle.fill" : "globe"} size={12} /> {L("Web")}</span>
          <span className={grounding.literature ? "c-ok" : ""}><Symbol name={grounding.literature ? "checkmark.circle.fill" : "books.vertical"} size={12} /> {L("Literature")}</span>
        </span>
      )}
      {claims.length > 0 && (
        <button type="button" className={`plain ${verified === claims.length ? "c-ok" : ""}`} onClick={() => A.setMainTab("claims")}>
          <Symbol name="checkmark.seal" size={12} /> {L10n.f("%d/%d verified", verified, claims.length)}
        </button>
      )}
      {contested > 0 && (
        <button type="button" className="plain c-warn" title={L("Unresolved disagreements between agents — your call")} onClick={() => A.setMainTab("claims")}>
          <Symbol name="exclamationmark.bubble.fill" size={12} /> {contested}
        </button>
      )}
    </span>
  );
}
