// The composer, ported from Sources/SieveSciApp/Views/PromptInput.swift: PromptInput (slash
// completion, attachments, Esc to interrupt), SandboxMenu, ModelMenu with ContextRing and
// UsagePopover, StatsLine; and the composer's effort control (EffortMenu / EffortMiniGauge).
import { useEffect, useRef, useState } from "react";
import { L, L10n } from "../i18n";
import { useApp, setState, getState } from "../app/model";
import * as A from "../app/actions";
import { inTauri } from "../serve";
import { Menu, Popup, SectionLabel } from "../theme/primitives";
import { Symbol } from "../theme/theme";
import { EffortMiniGauge, EffortSlider, GlitchLabel, effortName } from "../theme/effort";
import { relative } from "./Settings";

export { effortStops, effortName } from "../theme/effort";

export function PromptInput() {
  const running = useApp((s) => s.running);
  const platform = useApp((s) => s.platform);
  const draft = useApp((s) => s.draft);
  const commands = useApp((s) => s.commands);
  const [text, setText] = useState("");
  const [attachments, setAttachments] = useState<string[]>([]);
  // Files dropped on the window attach to the message (PromptInput's onDrop); the desktop app gets their paths.
  useEffect(() => {
    if (!inTauri) return;
    let off: (() => void) | undefined;
    void import("@tauri-apps/api/webview").then(({ getCurrentWebview }) => getCurrentWebview().onDragDropEvent((e) => {
      const d = e.payload;
      if (d.type === "drop") setAttachments((a) => [...a, ...d.paths.filter((p: string) => !a.includes(p))]);
    })).then((f) => { off = f; });
    return () => off?.();
  }, []);
  const [selection, setSelection] = useState(0);
  const [focused, setFocused] = useState(false);
  const area = useRef<HTMLTextAreaElement>(null);
  const lastEscape = useRef(0);

  useEffect(() => { area.current?.focus(); }, []);
  useEffect(() => {
    if (draft) { setText(draft); setState({ draft: "" }); area.current?.focus(); }
  }, [draft]);
  // Grows with the text up to 180 px, like the SwiftUI TextEditor.
  useEffect(() => {
    const el = area.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(180, Math.max(22, el.scrollHeight))}px`;
  }, [text]);

  const suggestions = text.startsWith("/") && !text.includes(" ")
    ? commands.filter((c) => { const q = text.slice(1).toLowerCase(); return !q || c.name.toLowerCase().startsWith(q) || c.name.toLowerCase().includes(q); }).slice(0, 12)
    : [];
  const canSend = text.trim() !== "" || attachments.length > 0;
  const interrupts = running && text === "";

  const send = () => {
    const t = text;
    const files = attachments;
    setText(""); setAttachments([]);
    if (t.trim() || files.length) void A.send(t, files);
  };
  // While a turn runs (DeepSeek Harness): one Enter queues for after the turn, the other inserts into it,
  // read at the agent's next step. Files and commands always go the ordinary way.
  const enterInserts = useApp((s) => s.config.enterInsertsWhileRunning);
  const queuedCount = useApp((s) => s.queued.length);
  const mod = platform === "windows" ? "Ctrl" : "⌘";
  const submit = (accelerated: boolean) => {
    if (!getState().running) { send(); return; }
    const t = text.trim();
    if (!t && accelerated && queuedCount > 0) { void A.insertAllQueued(); return; }
    const inserts = accelerated !== enterInserts;
    if (inserts && t && attachments.length === 0 && !t.startsWith("/") && !t.startsWith("!") && !t.startsWith("#")) {
      setText("");
      void A.insert(t);
      return;
    }
    send();
  };
  const busyHint = enterInserts
    ? L10n.f("Enter inserts now · %@+Enter queues · Esc interrupts", mod)
    : L10n.f("Enter queues · %@+Enter inserts now · Esc interrupts", mod);
  const complete = (c: { name: string; args: string }) => {
    const next = `/${c.name}${c.args ? " " : ""}`;
    if (c.args) setText(next); else { setText(""); void A.send(next); }
  };

  return (
    <div className="prompt-input">
      {suggestions.length > 0 && (
        <div className="slash-list">
          {suggestions.map((c, i) => (
            <div key={c.name} className={`slash-item ${i === selection ? "selected" : ""}`} onMouseDown={(e) => { e.preventDefault(); complete(c); }}>
              <span className="t-mono-small">/{c.name}</span>
              {c.args && <span className="t-mono-tiny tertiary">{c.args}</span>}
              <span style={{ flex: 1, minWidth: 12 }} />
              <span className="t-meta secondary clip">{L(c.summary)}</span>
            </div>
          ))}
        </div>
      )}
      <div className={`composer-box ${focused ? "focused" : ""}`} onClick={() => area.current?.focus()}>
        {attachments.length > 0 && (
          <div className="attachment-row">
            {attachments.map((a) => (
              <span key={a} className="attachment-chip t-meta"><Symbol name="paperclip" size={11} className="secondary" /><span className="clip">{a.split(/[\\/]/).pop()}</span>
                <button type="button" className="plain tertiary" onClick={() => setAttachments(attachments.filter((x) => x !== a))}><Symbol name="xmark" size={9} strokeWidth={3} /></button></span>
            ))}
          </div>
        )}
        <textarea ref={area} className="composer-text t-prose" rows={1} value={text}
                  onPaste={(e) => {
                    // A pasted image (a screenshot) is saved into inputs/ and attached; text pastes as usual.
                    const imgs = [...e.clipboardData.items].filter((it) => it.kind === "file" && it.type.startsWith("image/")).map((it) => it.getAsFile()).filter((f): f is File => !!f);
                    if (imgs.length === 0) return;
                    e.preventDefault();
                    for (const f of imgs) void A.savePastedImage(f).then((p) => { if (p) setAttachments((a) => [...a, p]); });
                  }}
                  placeholder={running ? (text === "" && queuedCount > 0 ? L10n.f("%@+Enter inserts every queued message now", mod) : busyHint) : L("Ask a research question, paste a GitHub link, or type / for commands")}
                  onFocus={() => setFocused(true)} onBlur={() => setFocused(false)}
                  onChange={(e) => { setText(e.target.value); setSelection(0); }}
                  onKeyDown={(e) => {
                    // Return while an input method composes (pinyin, kana …) confirms the candidate; it must not send.
                    if (e.nativeEvent.isComposing || e.keyCode === 229) return;
                    if (e.key === "Enter" && !e.shiftKey) {
                      e.preventDefault();
                      const c = suggestions[selection];
                      if (c && text !== `/${c.name}`) { complete(c); return; }
                      submit(e.metaKey || e.ctrlKey);
                    } else if (e.key === "Tab" && suggestions[selection]) { e.preventDefault(); complete(suggestions[selection]); }
                    else if (e.key === "ArrowUp" && suggestions.length) { e.preventDefault(); setSelection(Math.max(0, selection - 1)); }
                    else if (e.key === "ArrowDown" && suggestions.length) { e.preventDefault(); setSelection(Math.min(suggestions.length - 1, selection + 1)); }
                    else if (e.key === "Escape") {
                      e.preventDefault();
                      if (getState().running) { void A.stop(); return; }
                      if (Date.now() - lastEscape.current < 600) void A.send("/rewind");
                      lastEscape.current = Date.now();
                    }
                  }} />
        <div className="composer-bar">
          <Menu className="attach-menu" title={L("Attach files, images, PDFs or data")}
                label={<span className="attach-button"><Symbol name="plus" size={12} strokeWidth={2.5} /></span>}
                items={[{ label: L("Attach files…"), onSelect: () => void A.pickFiles().then((ps) => setAttachments((a) => [...a, ...ps.filter((p) => !a.includes(p))])) },
                        { label: L("Add a read-only folder…"), onSelect: () => void A.addReadOnlyFolders() }]} />
          <SandboxMenu />
          <span style={{ flex: 1 }} />
          <EffortMenu />
          <ModelMenu />
          <button type="button" className={`send-button ${canSend || interrupts ? "" : "disabled"}`} disabled={!canSend && !interrupts}
                  title={interrupts ? L("Interrupt (Esc)") : L("Send (Enter)")} aria-label={interrupts ? L("Interrupt (Esc)") : L("Send (Enter)")}
                  onClick={() => (interrupts ? void A.stop() : submit(false))}>
            <Symbol name={interrupts ? "stop.fill" : "arrow.up"} size={interrupts ? 10 : 13} strokeWidth={3} style={interrupts ? { fill: "currentColor" } : undefined} />
          </button>
        </div>
      </div>
    </div>
  );
}

function sandboxLabel(m: string) {
  return m === "workspaceWriteOffline" ? L("Workspace write · offline") : m === "off" ? L("No sandbox") : L("Workspace write");
}

function SandboxMenu() {
  const mode = useApp((s) => A.effectiveSandbox(s.config));
  const yolo = useApp((s) => s.config.permissionMode === "yolo");
  const available = useApp((s) => s.sandbox);
  const set = (m: "workspaceWrite" | "workspaceWriteOffline" | "off") => void A.setSandbox(m);
  if (!available) {
    return <span className="sandbox-menu c-warn t-meta" title={L("Commands the agents run")}><Symbol name="exclamationmark.triangle" size={13} /> {L("No sandbox on this system")}</span>;
  }
  return (
    <Menu className={`sandbox-menu ${mode === "off" ? "c-warn" : ""}`} title={L("Commands the agents run")}
          label={<><Symbol name={mode === "off" ? "exclamationmark.triangle" : "checkmark.shield"} size={13} /> {yolo ? <GlitchLabel text={sandboxLabel(mode)} font="500 11px var(--mono)" /> : sandboxLabel(mode)} <Symbol name="chevron.down" size={10} strokeWidth={2.5} /></>}
          items={[
            { label: L("Write workspace only, network on"), onSelect: () => set("workspaceWrite"), checked: mode === "workspaceWrite" },
            { label: L("Write workspace only, offline"), onSelect: () => set("workspaceWriteOffline"), checked: mode === "workspaceWriteOffline" },
            { label: L("No sandbox"), onSelect: () => set("off"), checked: mode === "off" },
          ]} />
  );
}

/** Composer control (EffortMenu): the mini gauge and the level; click opens the slider. */
function EffortMenu() {
  const effort = useApp((s) => s.config.effort);
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", close);
    document.addEventListener("keydown", esc);
    return () => { document.removeEventListener("mousedown", close); document.removeEventListener("keydown", esc); };
  }, [open]);
  return (
    <span className="effort-menu" ref={ref} style={{ position: "relative" }}>
      <button type="button" className="plain effort-label" title={L("Reasoning effort")} aria-expanded={open} onClick={() => setOpen(!open)}>
        <EffortMiniGauge effort={effort} />
        {effort === "max" ? <GlitchLabel text={effortName(effort)} font="11px var(--mono)" /> : <span className="t-mono-tiny secondary">{effortName(effort ?? null)}</span>}
      </button>
      {open && (
        <Popup className="effort-popover appear-pop">
          <SectionLabel>{L("Reasoning effort")}</SectionLabel>
          <EffortSlider effort={effort} onChange={(e) => void A.updateConfig({ effort: e })} width={308} />
        </Popup>
      )}
    </span>
  );
}

function ContextRing({ fill }: { fill: number }) {
  const color = fill > 0.85 ? "var(--bad)" : fill > 0.6 ? "var(--warn)" : "var(--accent)";
  const r = 5, c = 2 * Math.PI * r;
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" aria-label={L10n.f("Context %d%% full", Math.round(fill * 100))}>
      <circle cx="6" cy="6" r={r} fill="none" stroke="var(--separator)" strokeWidth="2" />
      <circle cx="6" cy="6" r={r} fill="none" stroke={color} strokeWidth="2" strokeLinecap="round" strokeDasharray={`${c * Math.max(0.02, fill)} ${c}`} transform="rotate(-90 6 6)" />
    </svg>
  );
}

function ModelMenu() {
  const meter = useApp((s) => s.meter);
  const providers = useApp((s) => s.config.providers);
  const usable = useApp((s) => s.usable);
  const quotas = useApp((s) => s.quotas);
  const [showUsage, setShowUsage] = useState(false);
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!showUsage) return;
    const close = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setShowUsage(false); };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [showUsage]);
  const prompt = meter.session.input + meter.session.cacheRead + meter.session.cacheWrite;
  return (
    <span className="model-menu" ref={ref}>
      <Menu align="right" label={<span className="t-meta">{meter.model || L("no model")} <Symbol name="chevron.down" size={10} strokeWidth={2.5} /></span>}
            items={[
              ...providers.filter((p) => usable.includes(p.id)).flatMap((p) => [
                { label: p.displayName, section: true },
                ...p.models.map((m) => ({ label: m, onSelect: () => void A.switchMainModel(p.id, m) })),
              ]),
              ...(usable.length ? [{ label: "", divider: true }] : []),
              { label: L("Providers…"), onSelect: () => A.openSettings("providers") },
            ]} />
      <button type="button" className="plain" onClick={() => {
        // Balances not fetched yet (they are refreshed after each turn) are asked for when the popover opens.
        if (!showUsage && usable.some((id) => !quotas[id])) void A.refreshQuotas();
        setShowUsage(!showUsage);
      }}><ContextRing fill={meter.fill} /></button>
      {showUsage && (
        <Popup className="usage-popover">
          <SectionLabel>{L("Context")}</SectionLabel>
          <div className="t-mono-small">{meter.lastPromptTokens.toLocaleString()} / {meter.contextWindow.toLocaleString()} {L("tokens")} ({Math.round(meter.fill * 100)}%)</div>
          <div className="usage-bar"><i style={{ width: `${Math.round(meter.fill * 100)}%`, background: meter.fill > 0.85 ? "var(--bad)" : "var(--accent)" }} /></div>
          <div className="h-hairline" />
          <SectionLabel>{L("This session")}</SectionLabel>
          <div className="usage-grid t-mono-small">
            <span>{L("Input (uncached)")}</span><span>{meter.session.input.toLocaleString()}</span>
            <span>{L("Cache read")}</span><span>{meter.session.cacheRead.toLocaleString()}</span>
            <span>{L("Cache write")}</span><span>{meter.session.cacheWrite.toLocaleString()}</span>
            <span>{L("Output")}</span><span>{meter.session.output.toLocaleString()}</span>
            <span>{L("Cache hit rate")}</span><span className={meter.cacheHitRate > 0.7 ? "c-ok" : ""}>{prompt ? (meter.cacheHitRate * 100).toFixed(1) : "0.0"}%</span>
          </div>
          <div className="h-hairline" />
          <SectionLabel>{L("Plans & balances")}</SectionLabel>
          {providers.filter((p) => usable.includes(p.id)).map((p) => {
            const q = quotas[p.id];
            return (
              <div key={p.id} className="usage-provider">
                <span className="t-body-strong">{p.displayName}{q?.plan ? ` · ${q.plan}` : ""}</span>
                {q ? <>
                  {q.meters.map((m, i) => (
                    <div key={i} className="usage-meter">
                      <div className="usage-meter-line t-mono-tiny"><span className="secondary">{m.title}</span><span className={m.exhausted ? "c-bad" : ""}>{m.value}</span></div>
                      {m.usedFraction !== null && <div className="usage-bar"><i style={{ width: `${Math.min(Math.max(m.usedFraction, 0), 1) * 100}%`, background: m.usedFraction > 0.85 ? "var(--bad)" : "var(--accent)" }} /></div>}
                      {m.resetsAt && <span className="t-caption secondary">{L10n.f("resets %@", relative(m.resetsAt))}</span>}
                    </div>
                  ))}
                  {q.note && <span className="t-caption secondary">{q.note}</span>}
                </> : <span className="t-caption secondary">{L("loading…")}</span>}
                {q?.spend && <span className="t-caption secondary">{L("tracked spend: $%.4f today · $%.2f this month").replace("%.4f", q.spend.today.toFixed(4)).replace("%.2f", q.spend.month.toFixed(2))}</span>}
              </div>
            );
          })}
          <div className="usage-refresh"><button type="button" className="link-button" onClick={() => void A.refreshQuotas()}>{L("Refresh")}</button></div>
        </Popup>
      )}
    </span>
  );
}

const compact = (n: number) => new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(n);

export function StatsLine() {
  const turns = useApp((s) => (s.streams.main ?? []).filter((i) => i.kind.type === "user").length);
  const steps = useApp((s) => Object.values(s.streams).flat().filter((i) => i.kind.type === "tool").length);
  const m = useApp((s) => s.meter);
  const running = useApp((s) => Object.values(s.jobs).filter((j) => j.running).length);
  const prompt = m.session.input + m.session.cacheRead + m.session.cacheWrite;
  return (
    <div className="stats-line t-mono-tiny tertiary">
      <span>{L10n.f("%d turns", turns)} · {L10n.f("%d steps", steps)}</span>
      {prompt > 0 && <>
        <i />
        <span className={m.cacheHitRate > 0.7 ? "c-ok" : "secondary"} title={L("Share of prompt tokens served from the provider's prefix cache this session")}>{L10n.f("cache %d%%", Math.round(m.cacheHitRate * 100))}</span>
        <i />
        <span>{L10n.s("%@ in · %@ out", compact(prompt), compact(m.session.output))}</span>
      </>}
      {running > 0 && <>
        <i />
        <button type="button" className="plain c-accent" title={L("Background jobs stream live; the agent is notified when they finish or report errors")} onClick={() => A.show("jobs")}>
          <Symbol name="waveform" size={11} /> {L10n.f("%d jobs", running)}
        </button>
      </>}
    </div>
  );
}
