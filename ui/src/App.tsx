import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import { Marked } from "marked";
import { inTauri, RpcError, ServeClient, socketTransport, tauriTransport, type JsonObject, type Transport } from "./serve";
import { empty, reduce, toolSummary, type AskQuestion, type AskRequest, type Item, type PermissionReq } from "./state";

// Model output is untrusted: raw HTML is shown as text and only http(s)/mailto links are kept.
const md = new Marked({ gfm: true, breaks: false });
const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
md.use({
  renderer: {
    html(token) { return escapeHtml(token.text); },
    link(token) {
      const href = token.href ?? "";
      const text = this.parser.parseInline(token.tokens);
      return /^(https?:|mailto:)/i.test(href) ? `<a href="${escapeHtml(href)}" target="_blank" rel="noreferrer">${text}</a>` : text;
    },
    image(token) { return escapeHtml(`[${token.text}]`); },
  },
});

const store = {
  get(k: string) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k: string, v: string) { try { localStorage.setItem(k, v); } catch { /* storage unavailable */ } },
};

interface TaskRow { id: string; title: string | null; modified: string }
interface Info { model?: string; provider?: string; version?: string; workspace?: string; mode?: string }

export default function App() {
  const [workspace, setWorkspace] = useState<string | null>(() => new URLSearchParams(location.search).get("workspace") ?? store.get("workspace"));
  const [client, setClient] = useState<ServeClient | null>(null);
  const [info, setInfo] = useState<Info>({});
  const [tasks, setTasks] = useState<TaskRow[]>([]);
  const [task, setTask] = useState<{ id: string; title: string | null } | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [state, dispatch] = useReducer(reduce, empty);

  const refreshTasks = useCallback(async (c: ServeClient) => {
    const r = await c.call<{ tasks: TaskRow[] }>("tasks.list");
    setTasks(r.tasks);
  }, []);

  const openTask = useCallback(async (c: ServeClient, id?: string) => {
    const r = await c.call<JsonObject>("task.open", id ? { id } : {});
    setTask({ id: String(r.task), title: (r.title as string | null) ?? null });
    dispatch({ type: "reset", history: (r.history ?? []) as JsonObject[], asks: (r.asks ?? []) as unknown as AskRequest[], running: r.running === true });
  }, []);

  // Connect once a workspace is known.
  useEffect(() => {
    if (!workspace) return;
    let cancelled = false;
    let transport: Transport | undefined;
    (async () => {
      try {
        const t = inTauri ? await tauriTransport(workspace)
                          : await socketTransport(`ws://127.0.0.1:8787/?workspace=${encodeURIComponent(workspace)}`);
        transport = t;
        if (cancelled) { t.close(); return; }
        const c = new ServeClient(t);
        t.onClose((why) => setFailure(`SieveSci stopped: ${why}`));
        c.onEvent((e) => dispatch({ type: "event", e }));
        c.onOutput((text) => dispatch({ type: "output", text }));
        setInfo(await c.call<Info>("initialize", { client: inTauri ? "desktop" : "browser" }));
        await refreshTasks(c);
        const list = await c.call<{ tasks: TaskRow[] }>("tasks.list");
        await openTask(c, list.tasks[0]?.id);
        setClient(c);
        setFailure(null);
      } catch (err) {
        if (!cancelled) setFailure(err instanceof Error ? err.message : String(err));
      }
    })();
    // Switching workspace (or React's development double-run) ends the old serve process.
    return () => { cancelled = true; transport?.close(); };
  }, [workspace, openTask, refreshTasks]);

  // Titles appear after the first turn: refresh the list when a turn ends.
  const wasRunning = useRef(false);
  useEffect(() => {
    if (wasRunning.current && !state.running && client) void refreshTasks(client);
    wasRunning.current = state.running;
  }, [state.running, client, refreshTasks]);

  const send = useCallback(async (text: string) => {
    if (!client) return;
    dispatch({ type: "user", text });
    try { await client.call("task.send", { text }); }
    catch (err) { dispatch({ type: "localError", text: err instanceof Error ? err.message : String(err) }); }
  }, [client]);

  if (!workspace) return <Welcome onOpen={(w) => { store.set("workspace", w); setWorkspace(w); }} />;

  const currentTitle = task?.title ?? tasks.find((t) => t.id === task?.id)?.title ?? "New task";
  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="brand">SieveSci</div>
        <button className="btn primary block" disabled={!client || state.running}
                onClick={() => client && openTask(client).then(() => refreshTasks(client)).catch((e) => setFailure(String(e)))}>
          + New task
        </button>
        <div className="section-label">Workspace</div>
        <div className="workspace" title={workspace}>
          <span>{workspace.split(/[\\/]/).filter(Boolean).pop()}</span>
          <button className="link" onClick={() => { setClient(null); setWorkspace(null); }}>Change</button>
        </div>
        <nav className="tasks">
          {tasks.length === 0 && <div className="muted small">No tasks yet</div>}
          {tasks.map((t) => (
            <button key={t.id} className={`task ${t.id === task?.id ? "current" : ""}`} disabled={state.running && t.id !== task?.id}
                    onClick={() => client && t.id !== task?.id && openTask(client, t.id).catch((e) => dispatch({ type: "localError", text: String(e.message ?? e) }))}>
              <span className="task-title">{t.title ?? "New task"}</span>
              <span className="task-date mono">{t.modified.slice(5, 10)}</span>
            </button>
          ))}
        </nav>
      </aside>
      <main className="main">
        <header className="topbar">
          <h1 className="title">{currentTitle}</h1>
          <div className="readout mono">
            <span>{info.provider ?? "—"} / {info.model ?? "—"}</span>
            {state.meter && <span>ctx {Math.round(state.meter.fill * 100)}%</span>}
            <span>{info.mode ?? ""}</span>
          </div>
        </header>
        {failure && <div className="banner">{failure}{!inTauri && <> · start it with <code>npm run bridge -- --provider …</code></>}</div>}
        <Transcript items={state.items} running={state.running} runStarted={state.runStarted}>
          {state.permissions.slice(0, 1).map((p) => (
            <PermissionCard key={p.id} req={p} onAnswer={async (decision) => {
              dispatch({ type: "settle", id: p.id });
              await client?.call("permission.respond", { id: p.id, decision });
            }} />
          ))}
          {state.asks.slice(0, 1).map((q) => (
            <AskCard key={q.id} req={q} onAnswer={async (outcome) => {
              dispatch({ type: "settle", id: q.id });
              await client?.call("ask.respond", { id: q.id, outcome });
            }} />
          ))}
        </Transcript>
        <Composer disabled={!client} running={state.running} onSend={send}
                  onStop={() => client?.call("task.stop").catch(() => {})}
                  meterText={state.meter ? `${state.meter.lastPromptTokens.toLocaleString()} / ${state.meter.contextWindow.toLocaleString()} tokens · cache ${Math.round(state.meter.cacheHitRate * 100)}%` : ""} />
      </main>
    </div>
  );
}

function Welcome({ onOpen }: { onOpen: (path: string) => void }) {
  const [path, setPath] = useState("");
  const pick = async () => {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const dir = await open({ directory: true, multiple: false });
    if (typeof dir === "string") onOpen(dir);
  };
  return (
    <div className="welcome">
      <div className="welcome-card">
        <div className="label-tab">SIEVESCI</div>
        <h1>Open a workspace</h1>
        <p className="muted">A folder with your data and analysis. SieveSci keeps its records in <code>.sievesci/</code> inside it.</p>
        {inTauri ? (
          <button className="btn primary" onClick={pick}>Choose folder…</button>
        ) : (
          <form className="row" onSubmit={(e) => { e.preventDefault(); if (path.trim()) onOpen(path.trim()); }}>
            <input className="field" placeholder="/path/to/project" value={path} onChange={(e) => setPath(e.target.value)} />
            <button className="btn primary" type="submit">Open</button>
          </form>
        )}
      </div>
    </div>
  );
}

function Transcript({ items, running, runStarted, children }: { items: Item[]; running: boolean; runStarted?: number; children: React.ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  useEffect(() => {
    const el = ref.current;
    if (el && stick.current) el.scrollTop = el.scrollHeight;
  });
  return (
    <div className="transcript" ref={ref}
         onScroll={(e) => { const el = e.currentTarget; stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40; }}>
      <div className="column">
        {items.length === 0 && !running && <div className="empty muted">Ask a research question, or describe the data you want analysed.</div>}
        {items.map((it) => <Row key={it.id} item={it} />)}
        {running && <Working since={runStarted} />}
        {children}
      </div>
    </div>
  );
}

function Row({ item }: { item: Item }) {
  switch (item.kind) {
    case "user": return <div className="msg user">{item.text}</div>;
    case "assistant": return <div className="msg assistant md" dangerouslySetInnerHTML={{ __html: md.parse(item.text) as string }} />;
    case "thinking": return <Thinking item={item} />;
    case "tool": return <ToolRow item={item} />;
    case "agent": return (
      <div className="agent-row">
        <span className="tag">{item.role.toUpperCase()}</span> <span>{item.purpose}</span>
        {item.result !== undefined && <div className="muted small agent-result">{item.result.slice(0, 400)}</div>}
      </div>
    );
    case "review": {
      const tone = /pass|verified|ok/.test(item.verdict) ? "ok" : /block|fail|refuted/.test(item.verdict) ? "bad" : "warn";
      return <div className={`review ${tone}`}><span className="mono small">{item.reviewKind} → {item.verdict}</span><div className="small">{item.body.slice(0, 600)}</div></div>;
    }
    case "notice": return <div className={`notice ${item.tone}`}>{item.text}</div>;
  }
}

function useNow(active: boolean) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!active) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [active]);
  return now;
}

function Thinking({ item }: { item: Extract<Item, { kind: "thinking" }> }) {
  const [open, setOpen] = useState(false);
  const now = useNow(item.ended === undefined);
  const secs = Math.max(1, Math.round(((item.ended ?? now) - item.started) / 1000));
  const last = item.text.trim().split("\n").pop() ?? "";
  return (
    <div className="thinking">
      <button className="row-button" onClick={() => setOpen(!open)}>
        <span className="mono small">{item.ended === undefined ? `Thinking… ${secs}s` : `Thought for ${secs}s`}</span>
        {!open && item.ended === undefined && last && <span className="muted small clip"> · {last}</span>}
        <span className="chev">{open ? "▾" : "▸"}</span>
      </button>
      {open && item.text.trim() && <div className="thinking-text">{item.text.trim()}</div>}
    </div>
  );
}

function ToolRow({ item }: { item: Extract<Item, { kind: "tool" }> }) {
  const [open, setOpen] = useState(false);
  const status = item.running ? <span className="spinner" /> : item.isError ? <span className="bad">✗</span> : <span className="ok">✓</span>;
  return (
    <div className="tool">
      <button className="row-button" onClick={() => setOpen(!open)}>
        <span className="tool-status">{status}</span>
        <span className="tool-name">{item.name}</span>
        <span className="muted mono clip">{toolSummary(item.input)}</span>
        {item.receipt && <span className="receipt mono">{item.receipt}</span>}
      </button>
      {item.running && item.progress.length > 0 && <pre className="output">{item.progress.slice(-8).join("\n")}</pre>}
      {open && item.output !== undefined && <pre className={`output ${item.isError ? "bad" : ""}`}>{item.output.slice(0, 20000)}</pre>}
    </div>
  );
}

function Working({ since }: { since?: number }) {
  const now = useNow(true);
  const secs = since ? Math.round((now - since) / 1000) : 0;
  return (
    <div className="working mono small">
      <span className="dots" aria-hidden>{Array.from({ length: 25 }, (_, i) => <i key={i} style={{ animationDelay: `${(Math.abs((i % 5) - 2) + Math.abs(Math.floor(i / 5) - 2)) * 90}ms` }} />)}</span>
      Working… {secs}s<span className="cursor">▌</span>
    </div>
  );
}

function PermissionCard({ req, onAnswer }: { req: PermissionReq; onAnswer: (d: "allow" | "always" | "deny") => void }) {
  const detail = typeof req.input.command === "string" ? req.input.command : typeof req.input.code === "string" ? req.input.code : JSON.stringify(req.input, null, 2);
  return (
    <div className="card pending">
      <div className="label-tab">{req.tool.toUpperCase()}</div>
      <div className="card-title">{req.tool} wants to run</div>
      <div className="muted small">{req.summary.split("\n")[0]}</div>
      <pre className="output">{detail.slice(0, 4000)}</pre>
      <div className="choices">
        <button className="choice" onClick={() => onAnswer("allow")}><span className="num">1</span>Yes</button>
        <button className="choice" onClick={() => onAnswer("always")}><span className="num">2</span>Yes, and don't ask again for <code>{req.rememberPattern}</code></button>
        <button className="choice" onClick={() => onAnswer("deny")}><span className="num">3</span>No</button>
      </div>
    </div>
  );
}

function AskCard({ req, onAnswer }: { req: AskRequest; onAnswer: (o: JsonObject) => void }) {
  const [picked, setPicked] = useState<Record<string, string[]>>({});
  const [other, setOther] = useState<Record<string, string>>({});
  const toggle = (q: AskQuestion, label: string) => setPicked((p) => {
    const cur = p[q.id] ?? [];
    const next = q.kind === "multi" ? (cur.includes(label) ? cur.filter((l) => l !== label) : [...cur, label]) : [label];
    return { ...p, [q.id]: next };
  });
  const answers = useMemo(() => {
    const out: JsonObject[] = [];
    for (const q of req.questions) {
      const typed = (other[q.id] ?? "").trim();
      const selected = picked[q.id] ?? [];
      if (q.kind === "text") { if (typed) out.push({ questionId: q.id, text: typed }); continue; }
      if (selected.length || typed) out.push(typed ? { questionId: q.id, selected, other: typed } : { questionId: q.id, selected });
    }
    return out;
  }, [req, picked, other]);
  return (
    <div className="card pending">
      <div className="label-tab">NEEDS YOUR ANSWER</div>
      {req.questions.map((q) => (
        <div className="question" key={q.id}>
          {q.header && <div className="section-label">{q.header}</div>}
          <div className="card-title">{q.question}</div>
          {q.kind !== "text" && q.options.map((o) => {
            const on = (picked[q.id] ?? []).includes(o.label);
            return (
              <button key={o.label} className={`choice ${on ? "on" : ""}`} onClick={() => toggle(q, o.label)}>
                <span className={`mark ${q.kind}`}>{on ? (q.kind === "multi" ? "✓" : "■") : ""}</span>
                <span>{o.label}{o.recommended && <span className="tag rec">Recommended</span>}
                  {o.description && <span className="muted small"> — {o.description}</span>}
                  {o.evidence.length > 0 && <span className="evidence mono"> {o.evidence.join(" ")}</span>}</span>
              </button>
            );
          })}
          {(q.kind === "text" || q.allow_other) && (
            <input className="field" placeholder={q.kind === "text" ? (q.placeholder ?? "Your answer") : "Other…"}
                   value={other[q.id] ?? ""} onChange={(e) => setOther((o) => ({ ...o, [q.id]: e.target.value }))} />
          )}
        </div>
      ))}
      <div className="row end">
        <button className="btn" onClick={() => onAnswer({ kind: "dismissed" })}>Don't choose, let's talk</button>
        <button className="btn primary" disabled={answers.length === 0} onClick={() => onAnswer({ kind: "answered", answers })}>Submit</button>
      </div>
    </div>
  );
}

function Composer({ disabled, running, onSend, onStop, meterText }: { disabled: boolean; running: boolean; onSend: (t: string) => void; onStop: () => void; meterText: string }) {
  const [text, setText] = useState(() => store.get("draft") ?? "");
  useEffect(() => store.set("draft", text), [text]);
  const submit = () => { const t = text.trim(); if (!t || disabled) return; onSend(t); setText(""); };
  return (
    <div className="composer-wrap">
      <div className="composer">
        <textarea rows={3} value={text} disabled={disabled} placeholder={running ? "Queue a message…" : "Ask SieveSci…"}
                  onChange={(e) => setText(e.target.value)}
                  onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); submit(); } }} />
        <div className="composer-bar">
          <span className="mono small muted">{meterText}</span>
          {running && <button className="btn danger" onClick={onStop}>Stop</button>}
          <button className="btn primary" disabled={disabled || !text.trim()} onClick={submit}>Send</button>
        </div>
      </div>
    </div>
  );
}

export { RpcError };
