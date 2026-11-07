// The research views (InspectorView.swift and Panels.swift): Plan, Claims, Library, Notebook and the
// Trace open as main-area tabs; Changes, Files, Figures, Jobs, History and Learning live in the side
// inspector. Data the SwiftUI panels read from the task's services comes from serve's panels.* methods,
// refetched when an event says it may have changed (`panelTick`).
import { memo, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { L, L10n } from "../i18n";
import { useApp, getState, setState, onPlatform, type AgentCard, type FileDiff, type InspectorTab, type JobState } from "../app/model";
import * as A from "../app/actions";
import type { JsonObject } from "../serve";
import { ActionButton, Box, Chip, EqualWidthButtons, Menu, Popup, SectionLabel, Segmented } from "../theme/primitives";
import { Symbol, agentName, toolIcon, toolTitle } from "../theme/theme";
import { RoleGhostBadge } from "../theme/brand";
import { DiffView, VerdictChip } from "./ChatView";
import { renderMarkdown } from "./markdown";
import "./panels.css";

/** Fetches a panel's data from serve, again when the task or `panelTick` changes (at most every 1.5 s). */
function usePanel<T>(method: string, params: JsonObject = {}, extra: unknown = null): [T | null, () => void] {
  const task = useApp((s) => s.taskId);
  const tick = useApp((s) => s.panelTick);
  const [data, setData] = useState<T | null>(null);
  const [nonce, setNonce] = useState(0);
  const key = JSON.stringify(params);
  const last = useRef(0);
  useEffect(() => {
    let cancelled = false;
    const run = () => void A.request<T>(method, params).then((r) => { if (!cancelled && r.ok) setData(r.value); });
    const wait = Math.max(0, 1500 - (Date.now() - last.current));
    const t = setTimeout(() => { last.current = Date.now(); run(); }, wait);
    return () => { cancelled = true; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [method, key, task, tick, nonce, extra]);
  useEffect(() => { setData(null); }, [task]);
  return [data, () => setNonce((n) => n + 1)];
}

const rel = (p: string) => { const ws = getState().workspace; return ws && p.startsWith(ws + "/") ? p.slice(ws.length + 1) : p; };
const absPath = (p: string) => { const ws = getState().workspace; return p.startsWith("/") || /^[A-Za-z]:[\\/]/.test(p) || !ws ? p : `${ws}/${p}`; };
const base = (p: string) => p.split(/[\\/]/).pop() ?? p;
const revealLabel = () => L(onPlatform(getState().platform, "Show in Finder", "Show in Explorer", "Show in file manager"));

/** Main-area tabs: the reading-width column (MainArea in SieveSciApp.swift). */
export function MainPanel({ tab }: { tab: InspectorTab }) {
  switch (tab) {
    case "activity": return <ActivityPanel />;
    case "plan": return <PlanPanel />;
    case "claims": return <ClaimsPanel />;
    case "library": return <LibraryPanel />;
    default: return <NotebookPanel />;
  }
}

// MARK: Inspector

const sideTabs: InspectorTab[] = ["changes", "files", "figures", "jobs", "history", "learning"];
const tabIcon: Record<InspectorTab, string> = { activity: "waveform.path.ecg", plan: "list.bullet.clipboard", claims: "checkmark.seal", library: "books.vertical",
  changes: "plusminus", files: "folder", figures: "photo.on.rectangle", jobs: "terminal", history: "clock.arrow.circlepath", notebook: "book.closed", learning: "brain" };
export const inspectorTitle = (t: InspectorTab) => ({ activity: L("Activity"), plan: L("Plan"), claims: L("Claims"), library: L("Library"), changes: L("Changes"),
  files: L("Files"), figures: L("Figures"), jobs: L("Jobs"), history: L("History"), notebook: L("Notebook"), learning: L("Learning") } as Record<InspectorTab, string>)[t];

export function InspectorView() {
  const tab = useApp((s) => s.inspectorTab);
  const badges = useApp((s) => ({
    jobs: Object.values(s.jobs).reduce((n, j) => n + j.unread, 0),
    claims: s.contested.length + s.claims.filter((c) => c.status === "verifying").length,
    learning: s.pendingProposals,
  }));
  const badge = (t: InspectorTab) => (badges as Record<string, number>)[t] ?? 0;
  const select = (t: InspectorTab) => {
    setState((s) => ({ inspectorTab: t, ...(t === "jobs" ? { jobs: Object.fromEntries(Object.entries(s.jobs).map(([k, j]) => [k, { ...j, unread: 0 }])) } : {}) }));
  };
  const body: Record<string, ReactNode> = { files: <FilesPanel />, changes: <ChangesPanel />, history: <HistoryPanel />, jobs: <JobsPanel />, figures: <FiguresPanel /> };
  return (
    <div className="inspector">
      <div className="inspector-tabs">
        {sideTabs.map((t) => (
          <button key={t} type="button" className={`inspector-tab ${tab === t ? "selected" : ""}`} title={inspectorTitle(t)} aria-label={inspectorTitle(t)} onClick={() => select(t)}>
            <Symbol name={tabIcon[t]} size={13} strokeWidth={tab === t ? 2.2 : 1.75} />
            {badge(t) > 0 && <i className="tab-dot" />}
          </button>
        ))}
      </div>
      <div className="inspector-head">
        <span className="t-body-strong">{inspectorTitle(tab)}</span>
        {badge(tab) > 0 && <span className="count-pill">{badge(tab)}</span>}
      </div>
      <div className="inspector-body">
        {body[tab] ?? <div className="inspector-scroll">{tab === "learning" ? <LearningPanel /> : <MainPanel tab={tab} />}</div>}
      </div>
    </div>
  );
}

// MARK: Plan

const stepIcon = (s: string): [string, string] => ({
  done: ["checkmark.circle.fill", "var(--ok)"], in_progress: ["circle.lefthalf.filled", "var(--accent)"], failed: ["xmark.circle.fill", "var(--bad)"],
  skipped: ["minus.circle", "var(--secondary)"],
} as Record<string, [string, string]>)[s] ?? ["circle", "var(--secondary)"];

export function PlanPanel() {
  const p = useApp((s) => s.plan);
  const g = useApp((s) => s.grounding);
  return (
    <div className="panel stack-l">
      <div className="hstack">
        <span className="t-meta secondary">{L("Stage")}</span><Chip text={L(p.stage)} tint="var(--accent)" />
        <span style={{ flex: 1 }} />
        {g && (
          <span className="hstack t-caption" title={L("Grounding gate: both searches must succeed before planning, claims and checkpoints")}>
            <span className={g.web ? "c-ok" : "secondary"}><Symbol name={g.web ? "checkmark.circle.fill" : "circle"} size={11} /> {L("web")}</span>
            <span className={g.literature ? "c-ok" : "secondary"}><Symbol name={g.literature ? "checkmark.circle.fill" : "circle"} size={11} /> {L("literature")}</span>
          </span>
        )}
      </div>
      {!p.goal ? <div className="t-body secondary">{L("No plan yet. The agent searches first, then writes a plan with hypotheses and checkpoints.")}</div> : <>
        {p.objective && (
          <div className="stack-xxs" title={L("The user's request. Every change of course must still serve it; only the user changes it.")}>
            <span className="t-label secondary">{L("Objective (fixed)")}</span>
            <span className="t-meta">{p.objective}</span>
          </div>
        )}
        <div className="plan-goal">{p.goal}</div>
        {p.pendingReview && (
          <div className="plan-review-pending t-meta">
            <Symbol name="arrow.triangle.branch" size={11} /> {L("Result review needed before more analysis:")} {p.pendingReview.trigger}
          </div>
        )}
        {p.hypotheses.length > 0 && (
          <div className="stack-m">
            <SectionLabel>{L("Hypotheses")}</SectionLabel>
            {p.hypotheses.map((h) => (
              <div key={h.id} className="thread-rule stack-xs">
                <span className="hstack-xs"><span className="mono-tiny secondary">{h.id}</span><Chip text={L(h.status)} tint="var(--accent)" /></span>
                <span className="t-body">{h.statement}</span>
                <span className="t-meta secondary">{L("falsified if:")} {h.falsification}</span>
                {h.onNegative && <span className="t-meta secondary">{L("if negative:")} {h.onNegative}</span>}
              </div>
            ))}
          </div>
        )}
        <div className="stack-s">
          <SectionLabel>{L("Steps")}</SectionLabel>
          {p.steps.map((st) => {
            const [icon, color] = stepIcon(st.status);
            return (
              <div key={st.id} className="plan-step">
                <span className="gutter" style={{ color }}><Symbol name={icon} size={12} style={st.status === "done" ? { fill: "currentColor", color, stroke: "var(--canvas)" } : undefined} /></span>
                <span className="stack-xxs">
                  <span className="hstack-xs">
                    <span className={`t-body ${st.status === "skipped" ? "secondary struck" : ""}`}>{st.title}</span>
                    {st.checkpoint && <Chip text={L("checkpoint")} tint="var(--accent)" icon="flag.fill" />}
                  </span>
                  {st.evidence.length > 0 && <span className="mono-tiny tertiary">{L("evidence:")} {st.evidence.join(", ")}</span>}
                  {st.onFailure && <span className="t-caption tertiary">{L("if it fails:")} {st.onFailure}</span>}
                </span>
              </div>
            );
          })}
        </div>
        {(p.reviews?.length ?? 0) > 0 && (
          <div className="stack-s">
            <SectionLabel>{L("Result reviews")}</SectionLabel>
            {p.reviews!.map((r) => (
              <div key={r.id} className="plan-step">
                <span className="gutter secondary"><Symbol name="arrow.triangle.branch" size={11} /></span>
                <span className="stack-xxs">
                  <span className="hstack-xs">
                    <span className="mono-tiny secondary">{r.id}{r.subject ? " · " + r.subject : ""}</span>
                    <Chip text={L(r.decision)} tint={r.decision === "stop" ? "var(--bad)" : r.decision === "pivot" ? "var(--warn)" : "var(--accent)"} />
                    {r.followsRule && <span className="t-caption tertiary">{L("as planned")}</span>}
                  </span>
                  <span className="t-meta">{r.observed}</span>
                  {r.causes[0] && <span className="t-caption secondary">{L("Likely cause:")} {r.causes[0]}</span>}
                  <span className="t-caption secondary">{L("Next:")} {r.next}</span>
                </span>
              </div>
            ))}
          </div>
        )}
        {(p.revisions?.length ?? 0) > 1 && (
          <div className="stack-s">
            <SectionLabel>{L("Revisions")}</SectionLabel>
            {p.revisions!.map((r, i) => (
              <div key={i} className="plan-step">
                <span className="gutter" style={{ color: r.afterResults ? "var(--warn)" : "var(--secondary)" }}><Symbol name={r.afterResults ? "exclamationmark.triangle.fill" : "arrow.triangle.branch"} size={11} /></span>
                <span className="stack-xxs"><span className="t-meta">{r.rationale}</span>{r.afterResults && <span className="t-caption c-warn">{L("criteria changed after results")}</span>}</span>
              </div>
            ))}
          </div>
        )}
      </>}
    </div>
  );
}

// MARK: Claims

export function ClaimsPanel() {
  const claims = useApp((s) => s.claims);
  const contested = useApp((s) => s.contested);
  return (
    <div className="panel stack-m">
      {claims.length === 0 && contested.length === 0 && <div className="t-body secondary">{L("No claims. Significant findings are registered with claim_finding and verified blind by an independent agent.")}</div>}
      {contested.length > 0 && <SectionLabel>{L("Contested between agents")}</SectionLabel>}
      {contested.map((c, i) => (
        <Box key={i} highlight="var(--warn)" provisional>
          <div className="stack-xs">
            <span className="hstack-xs"><span className="mono-tiny secondary">{c.thread}</span><VerdictChip verdict="contested" /><span className="t-caption secondary">{L(c.kind)}</span></span>
            <span className="t-body">{c.issue}</span>
            <span className="t-meta secondary">{c.reason}</span>
          </div>
        </Box>
      ))}
      {claims.map((c, i) => (
        <div key={c.id} className="stack-s">
          {(i > 0 || contested.length > 0) && <div className="h-hairline" />}
          <span className="hstack-xs"><span className="mono-tiny secondary">{c.id}</span><VerdictChip verdict={c.status} /></span>
          <span className="t-body">{c.statement}</span>
          <span className="t-meta secondary">{L("criteria:")} {c.successCriteria}</span>
          {c.verdict && <span className={`t-meta secondary clip-6 thread-rule verdict-${c.status}`}>{c.verdict}</span>}
        </div>
      ))}
    </div>
  );
}

// MARK: Library

interface Paper { key: string; title: string; authors: string[]; year?: number; venue?: string; source?: string; doi?: string; pdfPath?: string }
interface CodeLink { paperKey?: string; file: string; line: number; locator?: string }

export function LibraryPanel() {
  const [data] = usePanel<{ dir: string; papers: Paper[] }>("panels.library");
  const count = data?.papers.length ?? 0;
  const [links] = usePanel<{ links: CodeLink[] }>("library.links", {}, count);
  return (
    <div className="panel stack-m">
      <div className="hstack">
        <span className="t-meta secondary">{L10n.f("%d papers", count)}</span>
        <span style={{ flex: 1 }} />
        {data && (
          <EqualWidthButtons>
            <ActionButton onClick={() => A.systemOpen({ path: `${data.dir}/references.bib` })}>{L("BibTeX")}</ActionButton>
            <ActionButton onClick={() => A.systemOpen({ path: data.dir })}>{L("Folder")}</ActionButton>
          </EqualWidthButtons>
        )}
      </div>
      {data?.papers.map((r) => {
        const impl = (links?.links ?? []).filter((l) => l.paperKey === r.key);
        return (
          <div key={r.key} className="stack-xs paper">
            <span className="mono-tiny c-accent">[@{r.key}]</span>
            <span className="t-body" style={{ fontWeight: 500 }}>{r.title}</span>
            <span className="t-meta secondary">{r.authors.slice(0, 3).join(", ")}{r.authors.length > 3 ? " et al." : ""} · {r.year ?? "n.d."} · {r.venue ?? r.source ?? ""}</span>
            <span className="hstack paper-links">
              {r.doi && <button type="button" className="link-button" onClick={() => A.systemOpen({ url: `https://doi.org/${r.doi}` })}>DOI</button>}
              {r.pdfPath && <button type="button" className="link-button" onClick={() => A.systemOpen({ path: `${data.dir}/${r.pdfPath}` })}>PDF</button>}
              {impl.length > 0 && (
                <Menu className="t-caption" label={<span className="link-button">{L10n.f("Implemented in %d places", impl.length)}</span>}
                      items={impl.map((l) => ({ label: `${l.file}:${l.line}${l.locator ? " " + l.locator : ""}`, onSelect: () => A.systemOpen({ path: absPath(l.file) }) }))} />
              )}
            </span>
            <div className="h-hairline" />
          </div>
        );
      })}
    </div>
  );
}

// MARK: Notebook

export function NotebookPanel() {
  const [data] = usePanel<{ path: string; text: string }>("panels.notebook");
  const math = useApp((s) => s.mathVersion);
  const html = useMemo(() => renderMarkdown(data?.text ?? ""), [data?.text, math]);
  return (
    <div className="panel stack-m">
      <div className="hstack">
        <span className="t-meta secondary">{L("Written automatically from the provenance log")}</span>
        <span style={{ flex: 1 }} />
        <EqualWidthButtons>
          {data && <ActionButton onClick={() => A.systemOpen({ path: data.path })}>{L("Open")}</ActionButton>}
          <ActionButton onClick={() => { A.setMainTab("chat"); void A.send("/audit"); }}>{L("Verify chain")}</ActionButton>
        </EqualWidthButtons>
      </div>
      <div className="markdown selectable" dangerouslySetInnerHTML={{ __html: html }} />
    </div>
  );
}

// MARK: Learning

interface Proposal { id: string; role: string; kind: string; target: string; operation: string; content: string; reason: string; status: string }

export function LearningPanel() {
  const [data, reload] = usePanel<{ proposals: Proposal[] }>("panels.learning");
  useEffect(() => { if (data) setState({ pendingProposals: data.proposals.filter((p) => p.status === "pending").length }); }, [data]);
  const act = async (method: string, params: JsonObject) => { await A.request(method, params); reload(); };
  return (
    <div className="panel stack-m">
      <div className="t-meta secondary">{L("Every role learns, through governed proposals: screened for integrity, grounded in receipts, independently reviewed; reviewer and verifier learning needs your approval.")}</div>
      {data?.proposals.map((p) => (
        <div key={p.id} className="stack-s">
          <div className="h-hairline" />
          <span className="hstack-xs">
            <span className="mono-tiny c-accent">{p.role}</span>
            <span className="mono-tiny secondary clip">{p.kind} · {p.target} · {p.operation}</span>
            <span style={{ flex: 1 }} />
            <Chip text={L(p.status)} tint={p.status === "accepted" ? "var(--ok)" : p.status === "rejected" ? "var(--bad)" : "var(--warn)"} />
          </span>
          <span className="t-body clip-6">{p.content}</span>
          <span className="t-meta secondary clip-4">{p.reason}</span>
          {p.status === "pending" && (
            <EqualWidthButtons>
              <ActionButton kind="primary" onClick={() => void act("learning.decide", { id: p.id, approve: true })}>{L("Approve")}</ActionButton>
              <ActionButton kind="destructive" onClick={() => void act("learning.decide", { id: p.id, approve: false })}>{L("Reject")}</ActionButton>
            </EqualWidthButtons>
          )}
          {p.status === "accepted" && <span><ActionButton onClick={() => void act("learning.revert", { id: p.id })}>{L("Revert")}</ActionButton></span>}
        </div>
      ))}
    </div>
  );
}

// MARK: Trace (ActivityPanel)

interface TraceEvent { id: number; at: string; actor: string; kind: string; text: string; isError: boolean; category: string }
const traceCache = new Map<string, { offset: number; events: TraceEvent[] }>();
const PAGE = 200;

function traceIcon(e: TraceEvent): string {
  return ({ review: "checkmark.seal", signal: "exclamationmark.triangle", gate: "exclamationmark.triangle", deliberation: "arrow.left.arrow.right",
    commit: "clock.arrow.circlepath", permission: "hand.raised", error: "xmark.octagon", compaction: "rectangle.compress.vertical", user: "person" } as Record<string, string>)[e.kind] ?? toolIcon(e.kind);
}

export function ActivityPanel() {
  const task = useApp((s) => s.taskId);
  const tick = useApp((s) => s.panelTick);
  const cards = useApp((s) => s.cards);
  const [filter, setFilter] = useState<"all" | "literature" | "agents">("all");
  const [limit, setLimit] = useState(PAGE);
  const [events, setEvents] = useState<TraceEvent[]>(() => traceCache.get(task)?.events ?? []);
  // Only what the audit log gained since the last read is fetched; the rest is kept.
  useEffect(() => {
    let cancelled = false;
    const cached = traceCache.get(task) ?? { offset: 0, events: [] };
    setEvents(cached.events);
    void A.request<{ offset: number; events: TraceEvent[] }>("panels.trace", { offset: cached.offset }).then((r) => {
      if (cancelled || !r.ok) return;
      const next = { offset: r.value.offset, events: r.value.events.length ? [...cached.events, ...r.value.events] : cached.events };
      traceCache.set(task, next);
      setEvents(next.events);
    });
    return () => { cancelled = true; };
  }, [task, tick]);
  const all = filter === "all" ? events : events.filter((e) => e.category === filter);
  const shown = all.slice(-limit).reverse();
  const agents = Object.values(cards).sort((a, b) => b.started - a.started);
  return (
    <div className="panel stack-m">
      <Segmented fill value={filter} onChange={(f) => { setFilter(f); setLimit(PAGE); }}
                 options={[{ value: "all", label: L("All") }, { value: "literature", label: L("Literature") }, { value: "agents", label: L("Agents & checks") }]} />
      {agents.length > 0 && <>
        <div className="stack-s">
          <SectionLabel>{L("Agents")}</SectionLabel>
          {agents.map((c: AgentCard) => (
            <div key={c.id} className="hstack">
              <RoleGhostBadge role={c.role} working={c.ended === undefined} size={24} />
              <span className="t-meta-strong">{agentName(c.id)}</span>
              <span className="t-meta secondary clip" style={{ flex: 1 }}>{c.purpose}</span>
              {c.ended !== undefined && <Symbol name="checkmark" size={11} className="c-ok" />}
            </div>
          ))}
        </div>
        <div className="h-hairline" />
      </>}
      {all.length === 0 ? <div className="t-body secondary">{L("Nothing yet.")}</div> : <SectionLabel>{L("Events")} · {all.length}</SectionLabel>}
      <div className="stack-s">{shown.map((e) => <TraceRow key={e.id} event={e} />)}</div>
      {all.length > limit && <span><ActionButton onClick={() => setLimit(limit + PAGE * 2)}>{L10n.f("Show older (%d more)", all.length - limit)}</ActionButton></span>}
    </div>
  );
}

const TraceRow = memo(function TraceRow({ event: e }: { event: TraceEvent }) {
  const tint = e.isError ? (e.kind === "signal" || e.kind === "gate" ? "var(--warn)" : "var(--bad)") : "var(--secondary)";
  const who = e.actor === "host" ? L("Host") : e.actor === "user" ? L("You") : e.actor === "git" ? "git" : agentName(e.actor);
  const title = toolTitle(e.kind);
  const known = title !== e.kind && !/^[A-Z]/.test(e.kind) && title.toLowerCase() !== e.kind.replace(/_/g, "");
  return (
    <div className="trace-row">
      <span className="gutter" style={{ color: tint }}><Symbol name={traceIcon(e)} size={11} /></span>
      <span className="stack-xxs">
        <span className="hstack-xs"><span className="t-meta-strong">{who}</span><span className="mono-tiny tertiary">{new Date(e.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</span></span>
        <span className="t-meta secondary clip-3 selectable">{known ? title + " " : ""}{e.text}</span>
      </span>
    </div>
  );
});

// MARK: Changes

interface Changed { path: string; added: number; removed: number; isNewFile: boolean }

function Split({ list, detail }: { list: ReactNode; detail: ReactNode }) {
  return <div className="split"><div className="split-list">{list}</div><div className="split-detail">{detail}</div></div>;
}

export function ChangesPanel() {
  const [data, reload] = usePanel<{ files: Changed[] }>("panels.changes");
  const [selected, setSelected] = useState<string | null>(null);
  const [diff, setDiff] = useState<FileDiff | null>(null);
  useEffect(() => {
    setDiff(null);
    if (selected) void A.request<{ diff: FileDiff }>("changes.diff", { path: selected }).then((r) => { if (r.ok) setDiff(r.value.diff); });
  }, [selected, data]);
  const revert = async () => {
    if (!selected || !window.confirm(L("Revert this file to its state before the task?"))) return;
    const r = await A.request<{ diff: FileDiff }>("changes.revert", { path: selected });
    if (r.ok) setDiff(r.value.diff);
    reload();
  };
  const files = data?.files ?? [];
  return (
    <Split
      list={files.length === 0 ? <div className="t-body secondary pad">{L("No files changed in this task yet.")}</div> : files.map((f) => (
        <button key={f.path} type="button" className={`list-row ${selected === f.path ? "selected" : ""}`} onClick={() => setSelected(f.path)}>
          <Symbol name={f.isNewFile ? "doc.badge.plus" : "doc.text"} size={11} className="secondary" />
          <span className="mono-small clip-middle">{f.path}</span>
          <span style={{ flex: 1 }} />
          <span className="mono-tiny c-ok">+{f.added}</span><span className="mono-tiny c-bad">−{f.removed}</span>
        </button>
      ))}
      detail={selected && diff ? <>
        <div className="hstack">
          <span className="mono-small clip-middle" style={{ flex: 1 }}>{selected}</span>
          <EqualWidthButtons>
            <ActionButton onClick={() => A.systemOpen({ path: absPath(selected) })}>{L("Open")}</ActionButton>
            <ActionButton kind="destructive" onClick={() => void revert()}>{L("Revert")}</ActionButton>
          </EqualWidthButtons>
        </div>
        <div className="detail-scroll"><DiffView diff={diff} /></div>
      </> : <div className="t-body secondary">{L("Select a file to see what changed (red removed, green added).")}</div>} />
  );
}

// MARK: History

interface Commit { hash: string; subject: string; date: string; files: number }

export function HistoryPanel() {
  const [data, reload] = usePanel<{ commits: Commit[] }>("panels.history");
  const [selected, setSelected] = useState<string | null>(null);
  const [diffs, setDiffs] = useState<FileDiff[]>([]);
  useEffect(() => {
    setDiffs([]);
    if (selected) void A.request<{ diffs: FileDiff[] }>("history.diffs", { hash: selected }).then((r) => { if (r.ok) setDiffs(r.value.diffs); });
  }, [selected]);
  const restore = async () => {
    if (!selected || !window.confirm(L("Restore all workspace files to this commit? Current state is committed first, so this can be undone."))) return;
    await A.request("history.restore", { hash: selected });
    reload();
  };
  const commits = data?.commits ?? [];
  return (
    <Split
      list={commits.length === 0 ? <div className="t-body secondary pad">{L("No history yet. Every turn that changes files is committed to a private history (.sievesci/history.git).")}</div> : commits.map((c) => (
        <button key={c.hash} type="button" className={`list-row tall ${selected === c.hash ? "selected" : ""}`} onClick={() => setSelected(c.hash)}>
          <span className="stack-xxs" style={{ flex: 1, minWidth: 0 }}>
            <span className="t-body clip-2">{c.subject}</span>
            <span className="hstack"><span className="mono-tiny c-accent">{c.hash.slice(0, 8)}</span><span className="t-caption tertiary">{c.date.slice(0, 16)}</span>
              <span style={{ flex: 1 }} /><span className="t-caption tertiary">{L10n.f("%d files", c.files)}</span></span>
          </span>
        </button>
      ))}
      detail={selected ? <>
        <div className="hstack"><span className="mono-small" style={{ flex: 1 }}>{selected.slice(0, 10)}</span>
          <ActionButton kind="destructive" onClick={() => void restore()}>{L("Restore files to this point")}</ActionButton></div>
        <div className="detail-scroll stack-m">
          {diffs.map((d, i) => (
            <div key={i} className="stack-s">
              <span className="hstack"><span className="mono-small clip-middle" style={{ fontWeight: 500 }}>{d.path}</span><span className="mono-tiny c-ok">+{d.added}</span><span className="mono-tiny c-bad">−{d.removed}</span></span>
              <DiffView diff={d} maxLines={600} />
            </div>
          ))}
        </div>
      </> : <div className="t-body secondary">{L("Select a commit to see its changes.")}</div>} />
  );
}

// MARK: Jobs

interface JobInfo { id: string; label: string; running: boolean; exitCode: number | null; seconds: number | null; logPath: string; lines: string[] }
const errorLine = /Traceback \(most recent call last\)|\b(Error|ERROR|FATAL|Fatal error)\b[:\]]|Segmentation fault|Killed|MemoryError|CUDA out of memory|OOM|core dumped|loss(:|=)\s*nan/;

export function JobsPanel() {
  const jobs = useApp((s) => s.jobs);
  const order = useApp((s) => s.jobOrder);
  const [info] = usePanel<{ jobs: JobInfo[] }>("panels.jobs");
  const [selected, setSelected] = useState<string | null>(null);
  const [follow, setFollow] = useState(true);
  // A job chosen elsewhere ("Log" on its notification) is shown, following its output to the end.
  const asked = useApp((s) => s.selectedJob);
  useEffect(() => { if (asked) { setSelected(asked); setFollow(true); setState({ selectedJob: null }); } }, [asked]);
  const log = useRef<HTMLDivElement>(null);
  // Live lines arrive as events; a job from before this window opened comes from serve with its tail.
  const merged = useMemo(() => {
    const out: Record<string, JobState & { logPath?: string }> = {};
    for (const j of info?.jobs ?? []) out[j.id] = { id: j.id, label: j.label, lines: j.lines, running: j.running, unread: 0, exitCode: j.exitCode ?? undefined, seconds: j.seconds ?? undefined, logPath: j.logPath };
    for (const [id, j] of Object.entries(jobs)) out[id] = { ...out[id], ...j, lines: j.lines.length ? j.lines : (out[id]?.lines ?? []) };
    return out;
  }, [info, jobs]);
  const ids = [...new Set([...(info?.jobs ?? []).map((j) => j.id), ...order])].reverse();
  const id = selected ?? ids[0];
  const j = id ? merged[id] : undefined;
  useEffect(() => { if (follow && log.current) log.current.scrollTop = log.current.scrollHeight; }, [j?.lines.length, follow]);
  return (
    <Split
      list={ids.length === 0 ? <div className="t-body secondary pad">{L("No background jobs. Long commands run as streaming jobs; you and the agent are notified when they finish, fail, match a pattern or stall.")}</div> : ids.map((k) => {
        const x = merged[k];
        if (!x) return null;
        return (
          <button key={k} type="button" className={`list-row ${id === k ? "selected" : ""}`} onClick={() => setSelected(k)}>
            <span className="gutter">{x.running ? <span className="mini-spinner" /> : <Symbol name={x.exitCode === 0 ? "checkmark.circle.fill" : "xmark.octagon.fill"} size={11} className={x.exitCode === 0 ? "c-ok" : "c-bad"} />}</span>
            <span className="mono-tiny secondary">{x.id}</span>
            <span className="mono-small clip-middle" style={{ flex: 1 }}>{x.label}</span>
            {x.seconds !== undefined && <span className="t-caption tertiary">{x.seconds}s</span>}
          </button>
        );
      })}
      detail={j ? <>
        {/* A compact toolbar for the narrow panel: status on the left, small square tools on the right; when
            the panel is too narrow the tools move to a line of their own, never a word per line. */}
        <div className="job-bar">
          <span className="job-meta">
            <Chip text={j.running ? L("running") : L10n.f("exit %d", j.exitCode ?? -1)} tint={j.running ? "var(--accent)" : j.exitCode === 0 ? "var(--ok)" : "var(--bad)"} />
            <span className="t-caption tertiary">{L10n.f("%d lines", j.lines.length)}</span>
          </span>
          <span className="job-actions">
            <button type="button" className={`job-tool ${follow ? "on" : ""}`} aria-pressed={follow} title={L("Follow")} onClick={() => setFollow(!follow)}>
              <Symbol name="arrow.down.to.line" size={12} />{L("Follow")}
            </button>
            {j.running && <button type="button" className="job-tool danger" onClick={() => void A.request("jobs.stop", { id: j.id })}><Symbol name="stop.fill" size={10} style={{ fill: "currentColor" }} />{L("Stop")}</button>}
            {j.logPath && <button type="button" className="job-tool" onClick={() => A.systemOpen({ path: j.logPath! })}><Symbol name="doc.text" size={12} />{L("Open log")}</button>}
          </span>
        </div>
        <div className="job-log" ref={log}>{j.lines.map((l, i) => <div key={i} className={errorLine.test(l) ? "c-bad" : ""}>{l || " "}</div>)}</div>
      </> : null} />
  );
}

// MARK: Figures

export function FiguresPanel() {
  const [data] = usePanel<{ figures: string[] }>("panels.figures");
  const figures = data?.figures ?? [];
  return (
    <div className="inspector-scroll">
      {figures.length === 0 && <div className="t-body secondary pad">{L("Figures written during this task appear here.")}</div>}
      <div className="figure-grid">{figures.map((f) => <FigureTile key={f} path={f} />)}</div>
    </div>
  );
}

/** Figure thumbnail on a white mat (plots are drawn for white paper, in either appearance). */
function FigureTile({ path }: { path: string }) {
  const [src, setSrc] = useState<string | null>(null);
  const [menu, setMenu] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    // Loaded once in view: a long task can have many figures.
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => {
      if (!e.isIntersecting) return;
      io.disconnect();
      void A.request<{ kind: string; dataURL?: string }>("files.read", { path }).then((r) => { if (r.ok && r.value.kind === "image") setSrc(r.value.dataURL ?? null); });
    });
    io.observe(el);
    return () => io.disconnect();
  }, [path]);
  return (
    <div ref={ref} className="figure-tile" title={base(path)} onDoubleClick={() => A.systemOpen({ path })} onContextMenu={(e) => { e.preventDefault(); setMenu(true); }} onMouseLeave={() => setMenu(false)}>
      <div className="figure-mat">{src ? <img src={src} alt={base(path)} /> : <Symbol name="doc.richtext" size={28} className="secondary" />}</div>
      <span className="t-caption secondary clip-middle">{base(path)}</span>
      {menu && (
        <Popup className="menu-list left context">
          <button type="button" className="menu-item" onClick={() => A.systemOpen({ path })}>{L("Open")}</button>
          <button type="button" className="menu-item" onClick={() => A.systemOpen({ path, reveal: true })}>{revealLabel()}</button>
          <button type="button" className="menu-item" onClick={() => { A.setMainTab("chat"); void A.send("/review " + L("figure") + " " + base(path)); }}>{L("Ask the checker to review this figure")}</button>
        </Popup>
      )}
    </div>
  );
}

// MARK: Files

interface Entry { name: string; path: string; isDir: boolean }

function fileIcon(name: string): string {
  const ext = name.split(".").pop()?.toLowerCase() ?? "";
  if (["py", "r", "sh", "swift", "jl", "ipynb"].includes(ext)) return "chevron.left.forwardslash.chevron.right";
  if (["png", "jpg", "jpeg", "svg", "tif", "tiff"].includes(ext)) return "photo";
  if (ext === "pdf") return "doc.richtext";
  if (["csv", "tsv", "xlsx", "parquet", "h5ad"].includes(ext)) return "tablecells";
  if (["fasta", "fa", "fastq", "gb", "pdb", "cif", "sdf", "mol2", "bam", "vcf"].includes(ext)) return "atom";
  if (["md", "txt", "bib"].includes(ext)) return "doc.text";
  return "doc";
}

export function FilesPanel() {
  const changed = useApp((s) => s.changedFiles);
  const [selected, setSelected] = useState<string | null>(null);
  const [preview, setPreview] = useState<{ kind: string; text?: string; dataURL?: string; truncated?: boolean } | null>(null);
  useEffect(() => {
    setPreview(null);
    if (selected) void A.request<NonNullable<typeof preview>>("files.read", { path: selected }).then((r) => { if (r.ok) setPreview(r.value); });
  }, [selected]);
  const changedSet = useMemo(() => new Set(changed.map(rel)), [changed]);
  return (
    <Split
      list={<FolderRows path="" depth={0} selected={selected} onSelect={setSelected} changed={changedSet} reload={changed.length} />}
      detail={!selected ? <div className="t-body secondary center">{L("Select a file to preview it.")}</div>
        : !preview ? null
        : preview.kind === "image" ? <div className="detail-scroll preview-image"><img src={preview.dataURL} alt={base(selected)} /></div>
        : preview.kind === "pdf" ? <iframe className="preview-pdf" src={preview.dataURL} title={base(selected)} />
        : preview.kind === "text" ? <pre className="detail-scroll preview-text selectable">{preview.text}{preview.truncated ? "\n…" : ""}</pre>
        : <div className="t-body secondary center"><ActionButton onClick={() => A.systemOpen({ path: absPath(selected) })}>{L("Open")}</ActionButton></div>} />
  );
}

/** One folder level, read when opened (FileNode in Panels.swift). */
function FolderRows({ path, depth, selected, onSelect, changed, reload }: { path: string; depth: number; selected: string | null; onSelect: (p: string) => void; changed: Set<string>; reload: number }) {
  const [entries, setEntries] = useState<Entry[] | null>(null);
  const [open, setOpen] = useState<Record<string, boolean>>({});
  const [menu, setMenu] = useState<string | null>(null);
  useEffect(() => { void A.request<{ entries: Entry[] }>("files.list", path ? { path } : {}).then((r) => { if (r.ok) setEntries(r.value.entries); }); }, [path, reload]);
  return <>
    {(entries ?? []).map((e) => (
      <div key={e.path} onMouseLeave={() => setMenu(null)} style={{ position: "relative" }}>
        <button type="button" className={`list-row file-row ${selected === e.path ? "selected" : ""}`} style={{ paddingLeft: 8 + depth * 14 }}
                onClick={() => (e.isDir ? setOpen({ ...open, [e.path]: !open[e.path] }) : onSelect(e.path))}
                onDoubleClick={() => !e.isDir && A.systemOpen({ path: absPath(e.path) })}
                onContextMenu={(ev) => { ev.preventDefault(); setMenu(e.path); }}>
          {e.isDir ? <Symbol name="chevron.right" size={9} strokeWidth={2.5} className={`tertiary chev ${open[e.path] ? "open" : ""}`} /> : <span style={{ width: 9 }} />}
          <span className="gutter" style={{ color: e.isDir ? "color-mix(in srgb, var(--info) 85%, transparent)" : "var(--secondary)" }}>
            <Symbol name={e.isDir ? "folder.fill" : fileIcon(e.name)} size={11} style={e.isDir ? { fill: "currentColor" } : undefined} />
          </span>
          <span className="t-meta clip">{e.name}</span>
          {changed.has(e.path) && <i className="changed-dot" title={L("Changed in this task")} />}
        </button>
        {menu === e.path && (
          <Popup className="menu-list left context">
            <button type="button" className="menu-item" onClick={() => A.systemOpen({ path: absPath(e.path) })}>{L("Open")}</button>
            <button type="button" className="menu-item" onClick={() => A.systemOpen({ path: absPath(e.path), reveal: true })}>{revealLabel()}</button>
            <button type="button" className="menu-item" onClick={() => setState({ draft: "@" + e.path + " ", mainTab: "chat" })}>{L("Mention in prompt")}</button>
          </Popup>
        )}
        {e.isDir && open[e.path] && <FolderRows path={e.path} depth={depth + 1} selected={selected} onSelect={onSelect} changed={changed} reload={reload} />}
      </div>
    ))}
  </>;
}
