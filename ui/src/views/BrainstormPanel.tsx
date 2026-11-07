// Brainstorming mode, watched live (BrainstormPanel.swift). The sieve motif carries the meaning: ideas
// fall in as dots and thin out column by column (generated → distinct → checked → kept → registered),
// the stage track fills like an instrument's segment display, and the frame stays dashed while the
// ideas are speculation. The user sees what the agent is thinking right now and can wrap up or stop.
import { memo, useEffect, useState } from "react";
import { L, L10n } from "../i18n";
import { useApp, stagesOf, ideaIsLive, type BrainstormState, type Idea } from "../app/model";
import * as A from "../app/actions";
import { ActionButton, BlinkingCursor, Chip, EqualWidthButtons, LabelTab } from "../theme/primitives";
import { DotActivity, DotStorm } from "../theme/dots";
import { Symbol } from "../theme/theme";
import "./brainstorm.css";

const ms = (iso: string) => Date.parse(iso);

export const BrainstormPanel = memo(function BrainstormPanel({ state }: { state: BrainstormState }) {
  const live = !state.endedAt;
  const start = ms(state.startedAt), end = state.endedAt ? ms(state.endedAt) : null;
  // This brainstorm's ideas (an ended one stays in the conversation, so later brainstorms' are left out).
  const ideas = useApp((s) => s.ideas.filter((i) => ms(i.createdAt) >= start - 1000 && (end === null || ms(i.createdAt) <= end + 5000)));
  const trigger = state.trigger === "auto" ? L("Started by the agent") : state.trigger === "user" ? L("You asked") : L("Dream");
  return (
    <div className={`brainstorm appear-pop ${live ? "live" : ""}`} role="group" aria-label={L("Brainstorm") + ": " + state.topic}>
      <span className="brainstorm-tabs">
        <LabelTab text={L("Brainstorm")} tint={live ? "var(--accent)" : "var(--ink)"} />
        <LabelTab text={trigger} tint="color-mix(in srgb, var(--ink) 55%, transparent)" />
      </span>
      <Header state={state} live={live} />
      <StageTrack state={state} />
      <IdeaSieve ideas={ideas} />
      {live && <Thought state={state} />}
      <IdeaList ideas={ideas} />
      <div className="t-caption tertiary">{state.goal === "proven"
        ? L("Ideas are candidates: they count only after an evidence check, an independent review and, for findings, blind verification.")
        : L("Ideas are speculation: they count only after a novelty check, an independent review and, for findings, blind verification.")}</div>
    </div>
  );
});

function Header({ state, live }: { state: BrainstormState; live: boolean }) {
  return (
    <div className="bs-header">
      <span className="bs-activity" style={live ? undefined : { opacity: 0.6 }}>
        {live ? <DotStorm size={7} dot={3} gap={1.5} color={state.wrapUpRequested ? "var(--warn)" : "var(--accent)"} turn={state.wrapUpRequested ? 3.2 : 1.8} />
              : <DotActivity size={7} dot={3} gap={1.5} color="var(--rule)" />}
      </span>
      <div className="bs-title">
        <div className="bs-topic"><span className="t-body-strong clip-2">{state.topic}</span>
          {/* What the ideas are for, as the user decided before the brainstorm. */}
          <Chip text={state.goal === "proven" ? L("What works best") : L("Novelty first")} tint={state.goal === "proven" ? "var(--ok)" : "var(--accent)"} />
        </div>
        {state.reason && live ? <div className="t-meta secondary clip-2">{state.reason}</div>
          : state.summary ? <div className="t-meta secondary">{state.summary}</div> : null}
      </div>
      <span style={{ flex: 1 }} />
      <Clock start={ms(state.startedAt)} end={state.endedAt ? ms(state.endedAt) : null} />
      {live ? (
        <EqualWidthButtons>
          <ActionButton disabled={state.wrapUpRequested} title={L("Stop generating and report the best ideas so far")} onClick={() => void A.wrapUpBrainstorm()}>
            {state.wrapUpRequested ? L("Wrapping up…") : L("Wrap up")}
          </ActionButton>
          <ActionButton kind="destructive" title={L("Stop the agent now")} onClick={() => void A.stop()}>{L("Stop")}</ActionButton>
        </EqualWidthButtons>
      ) : (
        <span style={{ paddingTop: 3 }}><Chip text={state.stopped ? L("Stopped") : L("Done")} tint={state.stopped ? "var(--warn)" : "var(--ok)"} /></span>
      )}
    </div>
  );
}

/** mm:ss since the start; ticks once a second only while running. */
function Clock({ start, end }: { start: number; end: number | null }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (end !== null) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [end]);
  const secs = Math.max(0, Math.floor(((end ?? now) - start) / 1000));
  return <span className="t-label secondary bs-clock">{String(Math.floor(secs / 60)).padStart(2, "0")}:{String(secs % 60).padStart(2, "0")}</span>;
}

const stageTitle = (s: string) => ({ ground: L("Ground"), diverge: L("Diverge"), dedupe: L("Dedupe"), rank: L("Rank"), novelty: L("Novelty"), evidence: L("Evidence"),
  review: L("Review"), evolve: L("Evolve") } as Record<string, string>)[s] ?? L("Report");

/** The eight stages as segment cells: settled ones filled, the current one rippling, later ones empty. */
function StageTrack({ state }: { state: BrainstormState }) {
  return (
    <div className="stage-track">
      <div className="stages">
        {stagesOf(state).map((s) => {
          const current = s === state.stage && !state.endedAt;
          const done = state.stagesDone.includes(s) || (!!state.endedAt && s === state.stage);
          return (
            <div key={s} className={`stage ${current ? "current" : done ? "done" : ""}`}>
              {current ? <DotStorm size={3} dot={3} gap={1.5} color="var(--accent)" turn={1.2} /> : <span className={`dot-cells ${done ? "lit" : ""}`}>{Array.from({ length: 9 }, (_, i) => <i key={i} />)}</span>}
              <span className="stage-name">{stageTitle(s)}</span>
            </div>
          );
        })}
      </div>
      {!state.endedAt && state.stageNote && <div className="t-meta secondary clip-2">{state.stageNote}</div>}
    </div>
  );
}

/** The sieve: one dot per idea, columns thinning out as ideas are merged, found known or set aside. */
function IdeaSieve({ ideas }: { ideas: Idea[] }) {
  const distinct = ideas.filter((i) => i.status !== "merged");
  const columns: [string, number, string][] = [
    [L("Generated"), ideas.length, "color-mix(in srgb, var(--ink) 35%, transparent)"],
    [L("Distinct"), distinct.length, "color-mix(in srgb, var(--ink) 60%, transparent)"],
    [L("Checked"), distinct.filter((i) => i.novelty || i.support).length, "color-mix(in srgb, var(--accent) 65%, transparent)"],
    [L("Kept"), distinct.filter(ideaIsLive).length, "var(--accent)"],
    [L("Registered"), ideas.filter((i) => i.status === "promoted").length, "var(--ok)"],
  ];
  return (
    <div className="idea-sieve" aria-label={columns.map((c) => `${c[0]} ${c[1]}`).join(", ")}>
      {columns.map(([name, count, color], i) => (
        <div key={name} className="sieve-col-wrap">
          <div className="sieve-col">
            <DotStack count={count} color={color} />
            <span className="t-label"><span className="sieve-count">{count}</span> <span className="secondary upper">{name}</span></span>
          </div>
          {i < columns.length - 1 && <span className="t-label tertiary sieve-arrow">›</span>}
        </div>
      ))}
    </div>
  );
}

/** Bottom-up fill, like grains settling; new dots drop in from above. */
function DotStack({ count, color }: { count: number; color: string }) {
  const perRow = 6, rows = 4, cap = perRow * rows;
  const shown = Math.min(count, cap);
  const cells = [];
  for (let r = rows - 1; r >= 0; r--) for (let c = 0; c < perRow; c++) {
    const i = r * perRow + c;
    cells.push(<i key={`${r}-${c}`} className={i < shown ? "on" : ""} style={i < shown ? { background: color } : undefined} />);
  }
  return <span className="dot-stack" aria-hidden>{cells}{count > cap && <span className="dot-more mono-tiny secondary">+{count - cap}</span>}</span>;
}

function Thought({ state }: { state: BrainstormState }) {
  const [open, setOpen] = useState(false);
  const start = ms(state.startedAt);
  // The agent's latest thought since the brainstorm began: its reasoning, or its text if it thinks aloud.
  const text = useApp((s) => {
    const rows = s.streams.main ?? [];
    for (let i = rows.length - 1; i >= 0 && rows[i].at >= start; i--) {
      const k = rows[i].kind;
      if ((k.type === "thinking" || k.type === "assistant") && k.text) return k.text;
    }
    return state.stageNote;
  }).trim();
  const last = text.split("\n").pop() ?? "";
  return (
    <div className="bs-thought">
      <button type="button" className="bs-thought-head" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className="t-label upper c-accent">{L("Thinking")}</span>
        {open ? <span style={{ flex: 1 }} /> : <span className="t-mono-small secondary clip-2" style={{ flex: 1 }}>{last || L("…")}</span>}
        <BlinkingCursor />
        <Symbol name="chevron.right" size={9} strokeWidth={2.5} className={`tertiary chev ${open ? "open" : ""}`} />
      </button>
      {open && <div className="bs-thought-body">{text.slice(-2400)}</div>}
      {state.wrapUpRequested && <div className="t-meta c-warn">{L("You asked it to wrap up; it is finishing the checks already running.")}</div>}
    </div>
  );
}

function IdeaList({ ideas }: { ideas: Idea[] }) {
  const [all, setAll] = useState(false);
  const ranked = [...ideas].sort((a, b) => {
    const la = ideaIsLive(a), lb = ideaIsLive(b);
    if (la !== lb) return la ? -1 : 1;
    const ra = a.rank ?? Number.MAX_SAFE_INTEGER, rb = b.rank ?? Number.MAX_SAFE_INTEGER;
    return ra !== rb ? ra - rb : ms(a.createdAt) - ms(b.createdAt);
  });
  const shown = all ? ranked : ranked.slice(0, 6);
  return (
    <div className="idea-list">
      {shown.map((i) => <IdeaRow key={i.id} idea={i} />)}
      {ranked.length > 6 && <button type="button" className="link-button" onClick={() => setAll(!all)}>{all ? L("Show fewer") : L10n.f("Show all %d ideas", ranked.length)}</button>}
    </div>
  );
}

/** One idea: dashed rule while speculative, solid green once registered, faded when merged, discarded or known. */
function IdeaRow({ idea }: { idea: Idea }) {
  const [open, setOpen] = useState(false);
  const live = ideaIsLive(idea), promoted = idea.status === "promoted";
  // After what works best, the check is how well published results back the idea (prior work is wanted).
  const proven = idea.aim === "proven";
  const checked = proven ? !!idea.support : !!idea.novelty;
  const tint = promoted ? "var(--ok)" : !live ? "var(--rule)" : !checked ? "color-mix(in srgb, var(--ink) 35%, transparent)" : "var(--accent)";
  const novelty = idea.status === "merged" ? L10n.f("Same as %@", idea.mergedInto ?? "")
    : promoted ? L10n.f("Hypothesis %@", idea.hypothesisId ?? "")
    : idea.status === "discarded" && idea.novelty !== "known" ? L("Set aside")
    : proven ? (!idea.support ? L("Not checked") : idea.support === "established" ? L("Established") : idea.support === "partial" ? L("Partly supported") : L("No evidence found"))
    : !idea.novelty ? L("Not checked") : idea.novelty === "not_found_in_search" ? L("No prior work found") : idea.novelty === "incremental" ? L("Incremental") : L("Already published");
  const noveltyTint = promoted ? "var(--ok)"
    : proven ? (idea.support === "established" ? "var(--ok)" : idea.support === "unproven" ? "var(--bad)" : idea.support ? "var(--accent)" : "var(--secondary)")
    : idea.novelty === "not_found_in_search" ? "var(--accent)" : idea.novelty === "known" ? "var(--bad)" : "var(--secondary)";
  const detail = (k: string, v: string) => <div className="idea-detail" key={k}><span className="t-label upper tertiary">{k}</span><span className="t-meta secondary">{v}</span></div>;
  return (
    <button type="button" className={`idea-row ${promoted ? "promoted" : ""}`} style={{ ["--idea-tint" as string]: tint }} onClick={() => setOpen(!open)} aria-expanded={open}>
      <span className="idea-line">
        <span className="t-label secondary idea-id">{idea.id}</span>
        <span className={`t-body idea-statement ${open ? "" : "clip-2"} ${!live && !promoted ? "struck" : ""}`}>{idea.statement}</span>
        <Chip text={(idea.op.split(":")[0] ?? "").toUpperCase()} />
        <Chip text={novelty} tint={noveltyTint} />
      </span>
      {open && (
        <span className="idea-details">
          {idea.mechanism && detail(L("Mechanism"), idea.mechanism)}
          {idea.test && detail(L("Test"), idea.test)}
          {idea.falsifier && detail(L("Refuted if"), idea.falsifier)}
          {idea.seeds.length > 0 && detail(L("Seeds"), idea.seeds.join(", "))}
          {idea.closestPrior.length > 0 && detail(proven ? L("Published results") : L("Closest prior work"), idea.closestPrior.join(", "))}
          {idea.noveltyReceipts.length > 0 && detail(L("Searches"), idea.noveltyReceipts.join(" "))}
        </span>
      )}
    </button>
  );
}
