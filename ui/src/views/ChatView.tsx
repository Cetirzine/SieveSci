// The conversation, ported from Sources/SieveSciApp/Views/ChatView.swift: ChatView (windowed rows,
// search, scroll keeping), EarlierRowsLabel, SessionSetupCard, EmptyChatHero, StartCard,
// TranscriptRow and its rows, VerdictChip, ReviewBody, ThinkingRow, ToolRow, ToolOutputView,
// DiffSummaryRow, DiffView, AgentCardView, PlanApprovalBar, ContestedBanner, Spinner, PermissionPrompt.
import { memo, useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { L, L10n } from "../i18n";
import { useApp, getState, setState, type TranscriptItem, type ToolCallView, type FileDiff, type PermissionAsk } from "../app/model";
import * as A from "../app/actions";
import { ActionButton, Box, BlinkingCursor, Chip, EqualWidthButtons, IconBadge, IconButton, Keycap, LabelTab } from "../theme/primitives";
import { DotActivity, DotMatrixText, SieveField } from "../theme/dots";
import { RoleGhostBadge } from "../theme/brand";
import { agentName, deliberationTone, literatureIcon, roleVar, Symbol, toolIcon, toolTitle, verdictTone, type Role } from "../theme/theme";
import { renderMarkdown } from "./markdown";
import { PromptInput, StatsLine } from "./Composer";
import { AskPrompt } from "./AskPrompt";

const PAGE = 60;
const scrollMemory: Record<string, number | null> = {};   // task → distance from the end (null = at the end)
const hiddenMemory: Record<string, number> = {};

const searchable = (it: TranscriptItem): string => {
  const k = it.kind;
  switch (k.type) {
    case "user": case "assistant": case "thinking": case "notice": case "error": case "signal": return k.text;
    case "tool": return `${k.call.name} ${k.call.summary} ${k.call.output}`;
    case "review": return `${k.kind} ${k.verdict} ${k.body}`;
    case "deliberation": return `${k.from} ${k.to} ${k.text}`;
    case "literature": return `${k.key} ${k.title} ${k.detail}`;
    case "commit": return `${k.hash} ${k.subject}`;
    case "fileChange": return k.path;
    case "job": return k.notification.text;
    case "agent": return k.id;
  }
};

export function ChatView() {
  const items = useApp((s) => s.streams.main ?? []);
  const empty = useApp((s) => (s.streams.main ?? []).length === 0 && !s.running && !s.pendingPermission && !s.demoAsk && !s.lastError && !s.pendingAsk);
  return empty ? <EmptyChatHero /> : <Conversation items={items} />;
}

function Conversation({ items }: { items: TranscriptItem[] }) {
  const task = useApp((s) => s.taskId);
  const showThinking = useApp((s) => s.config.showThinking);
  const running = useApp((s) => s.running);
  const planMode = useApp((s) => s.config.permissionMode === "plan" && s.plan.steps.length > 0 && !s.running);
  const contested = useApp((s) => s.contested.length > 0);
  const pendingAsk = useApp((s) => s.pendingAsk);
  const permission = useApp((s) => s.pendingPermission ?? s.demoAsk);
  const lastError = useApp((s) => s.lastError);
  const live = useApp((s) => s.live);
  const queued = useApp((s) => s.queued);
  const [searching, setSearching] = useState(false);
  const [query, setQuery] = useState("");
  const [hiddenTick, setHiddenTick] = useState(0);
  const scroller = useRef<HTMLDivElement>(null);
  const atEnd = useRef(true);

  const hidden = (() => { void hiddenTick; const h = hiddenMemory[task]; return h !== undefined && h <= items.length ? h : Math.max(0, items.length - PAGE); })();
  const visible = searching && query ? items.filter((it) => searchable(it).toLowerCase().includes(query.toLowerCase())) : items.slice(hidden);

  // Scroll keeping (ChatScrollKeeper): each task reopens where it was left; at the end it follows new rows.
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const fromEnd = scrollMemory[task];
    el.scrollTop = fromEnd === undefined || fromEnd === null ? el.scrollHeight : el.scrollHeight - el.clientHeight - fromEnd;
    atEnd.current = fromEnd === undefined || fromEnd === null;
  }, [task]);
  useLayoutEffect(() => {
    const el = scroller.current;
    if (el && atEnd.current) el.scrollTop = el.scrollHeight;
  });
  const lastKind = items[items.length - 1]?.kind.type;
  useEffect(() => { if (lastKind === "user") { atEnd.current = true; scroller.current?.scrollTo({ top: scroller.current.scrollHeight }); } }, [items.length, lastKind]);
  useEffect(() => { if (permission || pendingAsk) { atEnd.current = true; } }, [permission, pendingAsk]);
  const onScroll = () => {
    const el = scroller.current!;
    const fromEnd = el.scrollHeight - el.scrollTop - el.clientHeight;
    atEnd.current = fromEnd < 24;
    scrollMemory[task] = atEnd.current ? null : fromEnd;
    if (el.scrollTop < 200 && hidden > 0 && !searching) {
      const before = el.scrollHeight;
      hiddenMemory[task] = Math.max(0, hidden - PAGE);
      setHiddenTick((t) => t + 1);
      requestAnimationFrame(() => { el.scrollTop += el.scrollHeight - before; });
    }
  };
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if ((e.metaKey || e.ctrlKey) && e.key === "f") { e.preventDefault(); setSearching((v) => !v); } };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <div className="chat">
      {searching && (
        <div className="chat-search">
          <Symbol name="magnifyingglass" size={13} className="secondary" />
          <input autoFocus placeholder={L("Search this task")} value={query} onChange={(e) => setQuery(e.target.value)} />
          <span className="t-caption secondary">{query ? L10n.f("%d matches", visible.length) : ""}</span>
          <IconButton symbol="xmark" label={L("Close")} onClick={() => { setSearching(false); setQuery(""); }} />
        </div>
      )}
      <div className="chat-scroll" ref={scroller} onScroll={onScroll}>
        <div className="transcript-column">
          {hidden > 0 && !(searching && query) && <EarlierRowsLabel count={hidden} />}
          {visible.map((it) => <TranscriptRow key={it.id} item={it} stream="main" showThinking={showThinking} />)}
          <div className="chat-tail">
            {planMode && <PlanApprovalBar />}
            {contested && <ContestedBanner />}
            {running && <Spinner />}
            {pendingAsk && !permission && <AskPrompt request={pendingAsk} />}
            {permission && <PermissionPrompt request={permission} />}
          </div>
          <div style={{ height: 8 }} />
        </div>
      </div>
      <div className="reading-column composer-area">
        {lastError && !live && <SessionSetupCard detail={lastError} />}
        {queued.length > 0 && (
          <div className="queued t-meta">
            <Symbol name="plus" size={12} className="secondary" /><span className="secondary">{L("Queued")}:</span>
            {queued.map((q, i) => <span key={i} className="queued-pill clip">{q.slice(0, 40)}</span>)}
          </div>
        )}
        <PromptInput />
        <StatsLine />
      </div>
    </div>
  );
}

function EarlierRowsLabel({ count }: { count: number }) {
  return <div className="earlier-rows"><i /><span>{L10n.f("%d earlier steps", count)}</span><i /></div>;
}

function SessionSetupCard({ detail }: { detail: string }) {
  // AppModel.needsModelSetup: a workspace, no session, and no usable provider.
  const setup = useApp((s) => s.workspace !== null && !s.live && s.usable.length === 0);
  return (
    <div className="setup-card appear-pop">
      <span className={`setup-card-icon ${setup ? "c-accent" : "c-warn"}`}><Symbol name={setup ? "cpu" : "exclamationmark.triangle"} size={15} strokeWidth={2.2} /></span>
      <div className="setup-card-text">
        <div className="t-body-strong">{setup ? L("Connect a model to start") : L("The session could not start")}</div>
        <div className="t-meta secondary">{setup ? L("SieveSci needs one model provider: an API key (DeepSeek, Anthropic, OpenAI, Gemini, GLM …), a relay, or a signed-in Claude Code, Codex or Gemini CLI. What you typed is kept.") : detail}</div>
        <EqualWidthButtons>
          {setup && <ActionButton kind="primary" fill onClick={() => A.openSettings("providers")}>{L("Set up a provider…")}</ActionButton>}
          <ActionButton fill onClick={() => { setState({ lastError: null }); void A.resumeIfNeeded(); }}>{L("Try again")}</ActionButton>
        </EqualWidthButtons>
      </div>
    </div>
  );
}

const starts: { icon: string; title: string; prompt: string }[] = [
  { icon: "books.vertical", title: "Review the literature", prompt: "Review the recent literature on " },
  { icon: "chart.xyaxis.line", title: "Analyse my data", prompt: "Analyse the data in " },
  { icon: "flask", title: "Design an experiment", prompt: "Design an experiment to test whether " },
];

function EmptyChatHero() {
  const spent = useApp((s) => s.meter.session.input + s.meter.session.cacheRead + s.meter.session.cacheWrite > 0);
  return (
    <div className="empty-hero">
      <div className="empty-hero-field"><SieveField fadeMid={0.2} /></div>
      <div className="empty-hero-column appear-pop">
        <div className="welcome-brand">
          <DotMatrixText text="SieveSci" rows={18} dot={4.5} gap={1.5} />
          <span className="welcome-version"><LabelTab text={L("New task")} /></span>
        </div>
        <h1 className="empty-hero-title">{L("What should we investigate?")}</h1>
        <div className="t-prose secondary">{L("Ask a research question, paste a GitHub link, or type / for commands")}</div>
        <div style={{ paddingTop: 8 }}><PromptInput /></div>
        <div className="start-cards">
          {starts.map((s) => (
            <button key={s.title} type="button" className="start-card" onClick={() => setState({ draft: L(s.prompt) })}>
              <Symbol name={s.icon} size={18} strokeWidth={1.75} className="start-card-icon" />
              <span className="t-body" style={{ fontWeight: 500 }}>{L(s.title)}</span>
            </button>
          ))}
        </div>
        <div style={{ opacity: spent ? 1 : 0 }}><StatsLine /></div>
      </div>
    </div>
  );
}

// MARK: Rows

const compactKinds = new Set(["user", "assistant", "agent", "review", "error"]);

export const TranscriptRow = memo(function TranscriptRow({ item, stream, showThinking }: { item: TranscriptItem; stream: string; showThinking: boolean }) {
  const [hovering, setHovering] = useState(false);
  const user = item.kind.type === "user";
  return (
    <div className={`row ${compactKinds.has(item.kind.type) ? "roomy" : "compact"} ${user ? "row-user" : "row-agent"}`}
         onMouseEnter={() => setHovering(true)} onMouseLeave={() => setHovering(false)}>
      <RowContent item={item} stream={stream} showThinking={showThinking} hovering={hovering} />
    </div>
  );
});

const copy = (s: string) => { void navigator.clipboard?.writeText(s); };

function RowContent({ item, stream, showThinking, hovering }: { item: TranscriptItem; stream: string; showThinking: boolean; hovering: boolean }) {
  const [expanded, setExpanded] = useState(false);
  const k = item.kind;
  switch (k.type) {
    case "user":
      return (
        <div className="user-message">
          <div className="user-bubble t-prose">{k.text}</div>
          {k.attachments.length > 0 && <div className="t-caption secondary attachments">{k.attachments.map((a, i) => <span key={i}><Symbol name="paperclip" size={11} /> {a}</span>)}</div>}
          {stream === "main" && (
            <div className="user-actions" style={{ opacity: hovering ? 1 : 0 }}>
              <IconButton symbol="pencil" label={L("Edit and resend")} />
              <IconButton symbol="arrow.uturn.backward" label={L("Rewind to here")} />
              <IconButton symbol="doc.on.doc" label={L("Copy")} onClick={() => copy(k.text)} />
            </div>
          )}
        </div>
      );
    case "assistant":
      return (
        <div className="assistant">
          <div className="md" dangerouslySetInnerHTML={{ __html: renderMarkdown(k.text) }} />
          {hovering && <span className="assistant-copy"><IconButton symbol="doc.on.doc" label={L("Copy")} onClick={() => copy(k.text)} /></span>}
        </div>
      );
    case "thinking": return showThinking ? <ThinkingRow text={k.text} started={k.started} ended={k.ended} /> : null;
    case "tool": return <ToolRow call={k.call} />;
    case "agent": return <AgentCardView id={k.id} />;
    case "review": {
      const tone = verdictTone(k.verdict);
      return (
        <Box highlight={`var(--${tone})`} tab={L(k.kind)} tabTint={`var(--${tone})`}>
          <div className="review-head"><Symbol name="checkmark.seal" size={13} className={`c-${tone}`} /><span className="t-body-strong">{L10n.s("Independent %@ review", L(k.kind))}</span><VerdictChip verdict={k.verdict} /></div>
          <ReviewBody text={k.body} />
        </Box>
      );
    }
    case "deliberation": {
      const tone = deliberationTone(k.kind);
      return (
        <div className="line-row align-top">
          <span className="gutter"><Symbol name="arrow.left.arrow.right" size={13} className={`c-${tone}`} /></span>
          <div className="deliberation">
            <div className="deliberation-head">
              <span className="t-meta-strong">{agentName(k.from)}</span><Symbol name="chevron.right" size={9} className="tertiary" />
              <span className="t-meta-strong">{agentName(k.to)}</span><Chip text={L(k.kind)} tint={`var(--${tone})`} /><span className="t-mono-tiny tertiary">{k.thread}</span>
            </div>
            <div className={`t-body secondary ${expanded ? "" : "clamp-4"}`} onClick={() => setExpanded(!expanded)}>{k.text}</div>
          </div>
        </div>
      );
    }
    case "literature":
      return (
        <div className="line-row">
          <span className={`gutter ${k.action === "flagged" ? "c-bad" : "secondary"}`}><Symbol name={literatureIcon(k.action)} size={11} /></span>
          <span className="t-meta secondary">{L(k.action)}</span>
          {k.key && k.action !== "searched" && <span className="t-mono-tiny c-accent">[@{k.key}]</span>}
          <span className="t-meta clip">{k.title}</span>
          {k.detail && <span className="t-caption tertiary clip">{k.detail}</span>}
        </div>
      );
    case "fileChange": return <DiffSummaryRow path={k.path} diff={k.diff} />;
    case "commit":
      return (
        <button type="button" className="line-row plain-row" onClick={() => A.setMainTab("history")}>
          <span className="gutter secondary"><Symbol name="arrow.triangle.branch" size={11} /></span>
          <span className="t-mono-tiny c-accent">{k.hash.slice(0, 8)}</span>
          <span className="t-meta clip">{k.subject}</span>
          <span className="t-caption tertiary">{L10n.f("%d receipts", k.files)}</span>
        </button>
      );
    case "job": {
      const n = k.notification;
      const tone = n.kind === "failed" ? "bad" : n.kind === "exited" ? "ok" : "warn";
      return (
        <div className="line-row align-top" onClick={() => setExpanded(!expanded)}>
          <span className={`gutter c-${tone}`}><Symbol name={n.kind === "failed" ? "exclamationmark.circle.fill" : n.kind === "exited" ? "checkmark.circle.fill" : "bell"} size={11} /></span>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div className="t-meta-strong">{n.text.split("\n")[0]}</div>
            {expanded && <pre className="code-block t-mono-tiny secondary">{n.text}</pre>}
          </div>
          <button type="button" className="link-button t-meta" onClick={(e) => { e.stopPropagation(); A.setMainTab("jobs"); }}>{L("Log")}</button>
        </div>
      );
    }
    case "signal":
      return <div className="line-row align-top"><span className="gutter c-warn"><Symbol name="exclamationmark.triangle" size={11} /></span><span className="t-meta">{k.text}</span></div>;
    case "notice": return <div className="notice t-mono-small secondary">{k.text}</div>;
    case "error":
      return <div className="error-row"><Symbol name="exclamationmark.circle.fill" size={15} className="c-bad" /><span className="t-body">{L("Error")}: {k.text}</span></div>;
  }
}

export function VerdictChip({ verdict }: { verdict: string }) {
  return <Chip text={L(verdict).toUpperCase()} tint={`var(--${verdictTone(verdict)})`} />;
}

/** Checker/verifier JSON rendered as issues and actions instead of raw JSON. */
function ReviewBody({ text }: { text: string }) {
  const [raw, setRaw] = useState(false);
  let parsed: Record<string, unknown> | null = null;
  const a = text.indexOf("{"), b = text.lastIndexOf("}");
  if (a >= 0 && b > a) { try { parsed = JSON.parse(text.slice(a, b + 1)); } catch { parsed = null; } }
  const strs = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
  return (
    <div className="review-body">
      {parsed && !raw ? (
        <>
          {((parsed.issues ?? []) as Record<string, string>[]).map((issue, i) => (
            <div key={i} className="review-issue">
              <span className="t-mono-tiny tertiary issue-num">{i + 1}</span>
              <div>
                <div className="issue-what">{issue.severity && <Chip text={L(issue.severity)} tint={issue.severity === "high" ? "var(--bad)" : "var(--warn)"} />}<span className="t-body">{issue.what ?? ""}</span></div>
                {issue.evidence && <div className="t-meta secondary">{issue.evidence}</div>}
              </div>
            </div>
          ))}
          {strs(parsed.required_actions).map((x, i) => <div key={i} className="t-body c-accent review-action"><Symbol name="chevron.right" size={12} /> {x}</div>)}
          {strs(parsed.questions).map((x, i) => <div key={i} className="t-body secondary review-action"><Symbol name="questionmark.bubble" size={12} /> {x}</div>)}
          {typeof (parsed.reasoning ?? parsed.notes) === "string" && <div className="t-meta secondary">{String(parsed.reasoning ?? parsed.notes)}</div>}
        </>
      ) : <pre className="t-mono-tiny review-raw">{text}</pre>}
      <button type="button" className="link-button t-caption" onClick={() => setRaw(!raw)}>{raw ? L("formatted") : L("raw")}</button>
    </div>
  );
}

function useTicker(active: boolean) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!active) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [active]);
  return now;
}

function ThinkingRow({ text, started, ended }: { text: string; started: number; ended?: number }) {
  const [expanded, setExpanded] = useState(false);
  const now = useTicker(ended === undefined);
  const secs = Math.floor(((ended ?? now) - started) / 1000);
  const last = text.split("\n").filter(Boolean).pop() ?? "";
  return (
    <div className="thinking-row">
      <button type="button" className="line-row plain-row" onClick={() => setExpanded(!expanded)}>
        <span className="gutter secondary"><Symbol name="brain" size={12} /></span>
        <span className="t-body thinking-label">{ended === undefined ? L10n.f("Thinking… %ds", secs) : L10n.f("Thought for %ds", Math.max(1, secs))}</span>
        {!expanded && ended === undefined && <span className="t-body secondary clip">· {last}</span>}
        <span className={`chev ${expanded ? "open" : ""}`}><Symbol name="chevron.right" size={9} strokeWidth={3} /></span>
      </button>
      {expanded && <div className="thinking-text t-body">{text}</div>}
    </div>
  );
}

function ToolRow({ call }: { call: ToolCallView }) {
  const [expanded, setExpanded] = useState(false);
  const running = call.ended === undefined;
  const now = useTicker(running);
  const hasOutput = !call.diff && call.output !== "";
  const secs = ((call.ended ?? now) - call.started) / 1000;
  return (
    <div className="tool-row">
      <button type="button" className="hover-row tool-row-button" title={hasOutput ? (expanded ? L("Hide output") : L("Show output")) : ""}
              onClick={() => hasOutput && setExpanded(!expanded)}>
        <span className="gutter">
          {running ? <span className="mini-spinner" /> : <Symbol name={call.isError ? "exclamationmark.circle.fill" : toolIcon(call.name)} size={12} className={call.isError ? "c-bad" : "secondary"} />}
        </span>
        <span className="t-body tool-title">{toolTitle(call.name)}</span>
        <span className="t-body tertiary">·</span>
        <span className="t-body secondary clip">{call.summary}</span>
        <span style={{ flex: 1, minWidth: 8 }} />
        <span className="t-caption tertiary tabular">{secs < 1 ? "" : `${secs.toFixed(0)}s`}</span>
        {call.receipt && <span className="t-mono-tiny tertiary" title={L("Evidence receipt — cite it to prove this result")}>{call.receipt}</span>}
        <span className={`chev ${expanded ? "open" : ""}`} style={{ opacity: hasOutput ? 1 : 0 }}><Symbol name="chevron.right" size={9} strokeWidth={3} /></span>
      </button>
      <div className="tool-below">
        {running && call.live.length > 0 && <pre className="code-block t-mono-tiny secondary">{call.live.slice(-8).join("\n")}</pre>}
        {call.diff ? <DiffSummaryRow path={call.diff.path} diff={call.diff} /> : hasOutput && <ToolOutputView call={call} expanded={expanded} />}
      </div>
    </div>
  );
}

function ToolOutputView({ call, expanded }: { call: ToolCallView; expanded: boolean }) {
  if (expanded) return <pre className={`code-block t-mono-tiny ${call.isError ? "c-bad" : "secondary"}`}>{call.output}</pre>;
  if (call.isError) return <div className="t-mono-tiny c-bad clamp-2">{call.output.split("\n").slice(0, 2).join("\n")}</div>;
  return null;
}

function DiffSummaryRow({ path, diff }: { path: string; diff: FileDiff }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="diff-summary">
      <div className="line-row">
        <span className="gutter secondary"><Symbol name={diff.isNewFile ? "plus.square.on.square" : "pencil"} size={11} /></span>
        <span className="t-mono-small clip-middle">{path}</span>
        <span className="t-mono-tiny c-ok">+{diff.added}</span>
        <span className="t-mono-tiny c-bad">−{diff.removed}</span>
        <span style={{ flex: 1 }} />
        <button type="button" className="link-button t-meta" onClick={() => setOpen(!open)}>{open ? L("hide") : L("show diff")}</button>
        <button type="button" className="link-button t-meta" onClick={() => A.setMainTab("changes")}>{L("Changes")}</button>
      </div>
      {open && <DiffView diff={diff} maxLines={400} />}
    </div>
  );
}

export function DiffView({ diff, maxLines = 2000 }: { diff: FileDiff; maxLines?: number }) {
  if (diff.isBinaryOrLarge) return <div className="t-meta secondary">{L("File too large or binary to diff.")}</div>;
  return (
    <div className="diff-view">
      {diff.hunks.map((h, i) => (
        <div key={i}>
          <div className="t-mono-tiny diff-hunk">{h.header}</div>
          {h.lines.slice(0, maxLines).map((l, j) => (
            <div key={j} className={`diff-line ${l.kind}`}>
              <span className="ln">{l.old ?? ""}</span><span className="ln">{l.new ?? ""}</span>
              <span className="mark">{l.kind === "added" ? "  + " : l.kind === "removed" ? "  − " : "    "}</span>
              <span className="text">{l.text || " "}</span>
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

function AgentCardView({ id }: { id: string }) {
  const card = useApp((s) => s.cards[id]);
  const items = useApp((s) => s.streams[id] ?? []);
  const showThinking = useApp((s) => s.config.showThinking);
  const [expanded, setExpanded] = useState(false);
  const now = useTicker(!!card && card.ended === undefined);
  if (!card) return null;
  const tools = items.filter((it) => it.kind.type === "tool");
  const last = [...tools].reverse()[0]?.kind;
  const tint = roleVar[card.role as Role];
  return (
    <div className="agent-card" style={{ ["--thread" as string]: `color-mix(in srgb, ${tint} ${card.ended === undefined ? 90 : 35}%, transparent)` }}>
      <button type="button" className="hover-row agent-card-head" onClick={() => setExpanded(!expanded)}>
        <RoleGhostBadge role={card.role as Role} working={card.ended === undefined} size={30} />
        <span className="agent-card-text">
          <span className="agent-card-name"><span className="t-body-strong">{agentName(id)}</span><span className="t-caption tertiary">← {agentName(card.parent)}</span></span>
          <span className="t-meta secondary clip">{card.purpose}</span>
        </span>
        <span style={{ flex: 1, minWidth: 8 }} />
        <span className="t-caption tertiary tabular">{`${(((card.ended ?? now) - card.started) / 1000).toFixed(0)}s`}</span>
        <span className="t-caption tertiary">{L10n.f("%d steps", tools.length)}</span>
        <span className={`chev ${expanded ? "open" : ""}`}><Symbol name="chevron.right" size={9} strokeWidth={3} /></span>
      </button>
      {expanded ? items.map((it) => <TranscriptRow key={it.id} item={it} stream={id} showThinking={showThinking} />)
        : card.ended === undefined && last?.type === "tool" ? (
          <div className="agent-card-live secondary">
            <Symbol name={toolIcon(last.call.name)} size={11} /><span className="t-meta-strong">{toolTitle(last.call.name)}</span><span className="t-mono-tiny clip">{last.call.summary}</span>
          </div>
        ) : null}
      {card.result && !expanded && <div className="t-meta secondary clamp-3">{card.result.slice(0, 300)}</div>}
    </div>
  );
}

function PlanApprovalBar() {
  return (
    <Box provisional className="appear-pop plan-approval">
      <div className="row-center">
        <IconBadge symbol="list.bullet.clipboard" size={26} />
        <span className="t-body-strong">{L("Plan ready for review.")}</span>
        <span style={{ flex: 1 }} />
        <EqualWidthButtons>
          <ActionButton fill onClick={() => A.setMainTab("plan")}>{L("Open plan")}</ActionButton>
          <ActionButton kind="primary" fill onClick={() => void A.send("/approve")}>{L("Approve and run")}</ActionButton>
        </EqualWidthButtons>
      </div>
    </Box>
  );
}

function ContestedBanner() {
  const contested = useApp((s) => s.contested);
  return (
    <Box highlight="var(--warn)" provisional className="appear-pop">
      <div className="t-body-strong c-warn contested-title"><Symbol name="exclamationmark.bubble.fill" size={13} /> {L("Unresolved disagreements between agents — your call")}</div>
      {contested.map((c, i) => (
        <div key={i} className="contested-item">
          <div className="row-center gap-6"><span className="t-mono-tiny tertiary">{c.thread}</span><Chip text={L(c.kind)} tint="var(--warn)" /></div>
          <div className="t-body">{c.issue.slice(0, 160)}</div>
          <div className="t-meta secondary">{c.reason.slice(0, 120)}</div>
        </div>
      ))}
    </Box>
  );
}

function Spinner() {
  const verb = useApp((s) => s.spinnerVerb);
  const started = useApp((s) => s.runStarted);
  const tokens = useApp((s) => s.meter.lastPromptTokens);
  const jobs = useApp((s) => Object.values(s.jobs).filter((j) => j.running).length);
  const now = useTicker(true);
  return (
    <div className="spinner">
      <span style={{ marginLeft: -5 }}><RoleGhostBadge role="main" working size={28} /></span>
      <DotActivity />
      <span className="t-body c-accent" style={{ fontWeight: 500 }}>{L(verb)}…</span>
      <BlinkingCursor />
      <span className="t-mono-tiny tertiary">{L10n.s("%@s · ↑ %@ tokens · esc to interrupt", String(Math.floor((now - started) / 1000)), tokens.toLocaleString())}</span>
      {jobs > 0 && <span className="t-mono-tiny tertiary">· {L10n.f("%d jobs running", jobs)}</span>}
    </div>
  );
}

function PermissionPrompt({ request }: { request: PermissionAsk }) {
  const [feedback, setFeedback] = useState("");
  const answer = useCallback((d: "allow" | "always" | "deny") => void A.answerPermission(request.id, d, d === "deny" ? feedback : undefined), [request.id, feedback]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement)?.tagName === "INPUT" || (e.target as HTMLElement)?.tagName === "TEXTAREA") return;
      if (e.key === "1") answer("allow"); else if (e.key === "2") answer("always"); else if (e.key === "3") answer("deny");
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [answer]);
  const writes = request.effect === "writesFiles";
  const what = writes ? L("wants to edit files") : ["dispatch", "task", "claim_finding"].includes(request.tool) ? L("wants to start independent agents")
    : request.effect === "external" ? L("wants to contact an external service") : L("wants to run code");
  const option = (key: string, label: ReactNode, d: "allow" | "always" | "deny", prominent = false) => (
    <button type="button" className="hover-row permission-option" onClick={() => answer(d)}>
      <Keycap k={key} /><span className={prominent ? "t-body-strong" : "t-body"}>{label}</span>
    </button>
  );
  return (
    <div className="permission-prompt appear-pop">
      <LabelTab text={toolTitle(request.tool)} tint="var(--accent)" className="permission-tab" />
      <div className="row-center gap-12">
        <IconBadge symbol={writes ? "pencil" : toolIcon(request.tool)} size={28} />
        <div><div className="permission-title">{toolTitle(request.tool)} {what}</div><div className="t-meta secondary">{L("Do you want to proceed?")}</div></div>
      </div>
      <pre className="code-block t-mono-small">{request.summary}</pre>
      <div className="permission-options">
        {option("1", L("Yes"), "allow", true)}
        {option("2", `${L("Yes, and don't ask again for")} ${request.rememberPattern}`, "always")}
        <div className="row-center gap-8">
          {option("3", L("No, and tell SieveSci what to do differently"), "deny")}
          <input className="underline-field t-body" placeholder={L("(optional)")} value={feedback} onChange={(e) => setFeedback(e.target.value)} />
        </div>
      </div>
    </div>
  );
}

export { getState };
