// The ask_user card, ported from Sources/SieveSciApp/Views/AskPrompt.swift: one to four questions
// (single, multiple, fill-in), each choice question with "Other"; dashed frame while the answer is open.
import { useEffect, useState } from "react";
import { L, L10n } from "../i18n";
import type { AskQuestion, AskRequest } from "../app/model";
import * as A from "../app/actions";
import { ActionButton, Chip, EqualWidthButtons, IconBadge, LabelTab, SpecField } from "../theme/primitives";
import { Symbol } from "../theme/theme";

interface Answer { questionId: string; selected: string[]; other?: string; text?: string }
const isEmpty = (a: Answer) => a.selected.length === 0 && !(a.other ?? "").trim() && !(a.text ?? "").trim();

export function AskPrompt({ request }: { request: AskRequest }) {
  const questions = request.questions;
  const [tab, setTab] = useState(0);
  const [picks, setPicks] = useState<Record<string, string[]>>({});
  const [otherOn, setOtherOn] = useState<Record<string, boolean>>({});
  const [other, setOther] = useState<Record<string, string>>({});
  const [text, setText] = useState<Record<string, string>>({});
  useEffect(() => { setTab(0); setPicks({}); setOtherOn({}); setOther({}); setText({}); }, [request.id]);

  const q = questions[Math.min(tab, questions.length - 1)];
  const answer = (q: AskQuestion): Answer => ({ questionId: q.id, selected: picks[q.id] ?? [],
    other: otherOn[q.id] ? other[q.id] : undefined, text: q.kind === "text" ? text[q.id] : undefined });
  const answered = (q: AskQuestion) => !isEmpty(answer(q));
  const canSubmit = questions.every((x) => x.optional || answered(x));
  const submit = () => {
    const answers = questions.map(answer).filter((a) => !isEmpty(a))
      .map((a) => ({ questionId: a.questionId, selected: a.selected, ...(a.other ? { other: a.other } : {}), ...(a.text ? { text: a.text } : {}) }));
    void A.answerAsk(request.id, { kind: "answered", answers });
  };
  const advance = () => { if (tab < questions.length - 1) setTab(tab + 1); else if (canSubmit) submit(); };
  const toggle = (q: AskQuestion, label: string) => {
    const p = picks[q.id] ?? [];
    if (q.kind === "multi") setPicks({ ...picks, [q.id]: p.includes(label) ? p.filter((x) => x !== label) : [...p, label] });
    else { setPicks({ ...picks, [q.id]: p.length === 1 && p[0] === label ? [] : [label] }); setOtherOn({ ...otherOn, [q.id]: false }); }
  };
  const reason = ({ direction: L("Directions found by searching and brainstorming — pick what to pursue."),
    missing_value: L("Something only you can tell it."), user_decision: L("A decision that is yours to make.") } as Record<string, string>)[q.reason ?? "user_decision"];

  return (
    <div className="ask-prompt appear-pop">
      <LabelTab text={L("Needs your answer")} tint="var(--accent)" className="permission-tab" />
      <div className="row-center gap-12">
        <IconBadge symbol="questionmark.bubble" size={28} />
        <div>
          <div className="permission-title">{questions.length === 1 ? L("SieveSci has a question") : L10n.f("SieveSci has %d questions", questions.length)}</div>
          <div className="t-meta secondary">{reason}</div>
        </div>
      </div>
      {questions.length > 1 && (
        <div className="ask-tabs">
          {questions.map((item, i) => (
            <button key={item.id} type="button" className={`ask-tab ${i === tab ? "selected" : ""}`} onClick={() => setTab(i)}>
              <i className={answered(item) ? "done" : ""} /><span>{item.header}</span>
            </button>
          ))}
          <span style={{ flex: 1 }} />
          <span className="t-label tertiary tabular">{tab + 1}/{questions.length}</span>
        </div>
      )}
      <div className="ask-body" key={q.id}>
        <div className="t-body-strong">{q.question}</div>
        {q.kind === "multi" && <div className="t-meta secondary">{L("Choose any that apply.")}</div>}
        {q.kind === "text" ? (
          <div style={{ paddingTop: 4 }}><SpecField multiline value={text[q.id] ?? ""} onChange={(v) => setText({ ...text, [q.id]: v })} placeholder={q.placeholder ?? L("Type your answer")} /></div>
        ) : (
          <>
            {q.options.map((o) => {
              const on = (picks[q.id] ?? []).includes(o.label);
              const idea = o.idea;
              return (
                <button key={o.label} type="button" className={`hover-row ask-option ${on ? "picked" : ""}`} onClick={() => toggle(q, o.label)}>
                  <Mark on={on} multi={q.kind === "multi"} />
                  <span className="ask-option-text">
                    <span className="row-center gap-6"><span className="t-body-strong">{o.label}</span>
                      {o.recommended && <Chip text={L("Recommended")} tint="var(--accent)" />}{idea && <Chip text={idea} />}</span>
                    {o.description && <span className="t-meta secondary">{o.description}</span>}
                    {o.evidence.length > 0 && <span className="row-center gap-4">{o.evidence.slice(0, 6).map((e) => <span key={e} className="t-mono-tiny c-accent">{e.startsWith("@") || e.startsWith("r") ? e : "@" + e}</span>)}</span>}
                  </span>
                </button>
              );
            })}
            {q.allow_other && (
              <div className="ask-other">
                <button type="button" className="plain row-center gap-10" onClick={() => { const on = !otherOn[q.id]; setOtherOn({ ...otherOn, [q.id]: on }); if (on && q.kind === "single") setPicks({ ...picks, [q.id]: [] }); }}>
                  <Mark on={!!otherOn[q.id]} multi={q.kind === "multi"} /><span className="t-body-strong">{L("Other")}</span>
                </button>
                <span style={{ flex: 1 }}><SpecField value={other[q.id] ?? ""} placeholder={q.placeholder ?? L("Your own answer")}
                  onChange={(v) => { setOther({ ...other, [q.id]: v }); if (v && !otherOn[q.id]) { setOtherOn({ ...otherOn, [q.id]: true }); if (q.kind === "single") setPicks({ ...picks, [q.id]: [] }); } }}
                  onKeyDown={(e) => { if (e.key === "Enter") advance(); }} /></span>
              </div>
            )}
          </>
        )}
      </div>
      <div className="row-center gap-8">
        <span className="t-caption tertiary">{L("Your answer is recorded in the audit log.")}</span>
        <span style={{ flex: 1, minWidth: 12 }} />
        <EqualWidthButtons>
          <ActionButton fill onClick={() => void A.answerAsk(request.id, { kind: "dismissed" })}>{L("Let's just talk")}</ActionButton>
          {questions.length > 1 && tab < questions.length - 1 && <ActionButton fill onClick={advance}>{L("Next")}</ActionButton>}
          <ActionButton kind="primary" fill disabled={!canSubmit} onClick={submit}>{L("Submit")}</ActionButton>
        </EqualWidthButtons>
      </div>
    </div>
  );
}

/** Square option mark: a filled square (single choice) or a tick box (multiple). */
function Mark({ on, multi }: { on: boolean; multi: boolean }) {
  return (
    <span className={`ask-mark ${on ? "on" : ""}`}>
      {on && (multi ? <Symbol name="checkmark" size={8} strokeWidth={4} /> : <i />)}
    </span>
  );
}
