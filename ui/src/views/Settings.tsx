// Settings as a full page, ported from SettingsView.swift (+ UpdateSettings in Updater.swift): the
// same panes, rows, texts and behaviour. What the SwiftUI views compute with the core directly comes
// from `sievesci serve` (providers.*, models.*, connectors.*, memory.*, schedules.*).
import { Children, useEffect, useMemo, useState, type ReactNode } from "react";
import { L, L10n, languageNames, resolvedLanguage, type Language } from "../i18n";
import { useApp, getState, onPlatform, type Config, type ModelInfo, type ModelRef, type ModelSpec, type ProviderProfile, type Quota } from "../app/model";
import * as A from "../app/actions";
import type { SettingsPane } from "../app/actions";
import type { JsonObject } from "../serve";
import { ActionButton, ActionRow, Chip, IconButton, SectionLabel, SpecField } from "../theme/primitives";
import { Symbol, roleName } from "../theme/theme";
import { RoleGhostIcon } from "../theme/brand";
import { EffortSlider } from "../theme/effort";
import "./settings.css";

const panes: { id: SettingsPane; title: () => string; icon: string }[] = [
  { id: "general", title: () => L("General"), icon: "gearshape" },
  { id: "providers", title: () => L("Providers"), icon: "server.rack" },
  { id: "models", title: () => L("Models"), icon: "cpu" },
  { id: "search", title: () => L("Web search"), icon: "globe" },
  { id: "research", title: () => L("Research"), icon: "flask" },
  { id: "memory", title: () => L("Memory & learning"), icon: "brain" },
  { id: "schedules", title: () => L("Schedules"), icon: "calendar.badge.clock" },
];

export function SettingsPage() {
  const pane = useApp((s) => s.settingsPane);
  useEffect(() => {
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape" && !document.querySelector(".sheet")) A.closeSettings(); };
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, []);
  const current = panes.find((p) => p.id === pane) ?? panes[0];
  return (
    <div className="settings-page">
      <nav className="settings-nav">
        <button type="button" className="settings-back" onClick={A.closeSettings}><Symbol name="chevron.left" size={13} /> {L("Back to app")}</button>
        <div className="settings-title">{L("Settings")}</div>
        {panes.map((p) => (
          <button key={p.id} type="button" className={`settings-nav-item ${p.id === current.id ? "selected" : ""}`} onClick={() => A.setSettingsPane(p.id)}>
            <span className="nav-icon"><Symbol name={p.icon} size={13} /></span>{p.title()}
          </button>
        ))}
      </nav>
      <div className="settings-main">
        <div className="settings-pane-title">{current.title()}</div>
        {current.id === "general" && <GeneralSettings />}
        {current.id === "providers" && <ProvidersSettings />}
        {current.id === "models" && <ModelsSettings />}
        {current.id === "search" && <SearchSettings />}
        {current.id === "research" && <ResearchSettings />}
        {current.id === "memory" && <MemorySettings />}
        {current.id === "schedules" && <ScheduleSettings />}
      </div>
    </div>
  );
}

// MARK: Form parts (SwiftUI grouped Form)

function Form({ children, trailing }: { children: ReactNode; trailing?: ReactNode }) {
  return <div className="form-scroll"><div className="form">{children}</div>{trailing}</div>;
}

function Section({ label, header, children }: { label?: string; header?: ReactNode; children: ReactNode }) {
  const rows = Children.toArray(children).filter((c) => c !== "");
  return (
    <section className="form-section">
      {(label || header) && <div className="form-header">{header ?? <SectionLabel>{label}</SectionLabel>}</div>}
      <div className="form-box">{rows.map((r, i) => <div className="form-row" key={i}>{r}</div>)}</div>
    </section>
  );
}

const Caption = ({ children }: { children: ReactNode }) => <p className="form-caption">{children}</p>;

function Row({ label, children }: { label: ReactNode; children: ReactNode }) {
  return <div className="lc"><span className="lc-label">{label}</span><span className="lc-value">{children}</span></div>;
}

function Switch({ on, onChange, disabled, label }: { on: boolean; onChange: (v: boolean) => void; disabled?: boolean; label?: string }) {
  return <button type="button" role="switch" aria-checked={on} aria-label={label} title={label} disabled={disabled} className={`switch ${on ? "on" : ""}`}
                 onClick={(e) => { e.preventDefault(); onChange(!on); }} />;
}

function Toggle({ label, on, onChange, disabled }: { label: string; on: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <div className={`lc toggle-row ${disabled ? "disabled" : ""}`} onClick={() => { if (!disabled) onChange(!on); }}>
      <span className="lc-label">{label}</span>
      <span className="lc-value" onClick={(e) => e.stopPropagation()}><Switch on={on} onChange={onChange} disabled={disabled} label={label} /></span>
    </div>
  );
}

function PopUp<T extends string>({ value, options, onChange, label, disabled }: { value: T; options: { value: T; label: string }[]; onChange: (v: T) => void; label?: string; disabled?: boolean }) {
  return (
    <span className="popup">
      <select value={value} aria-label={label} disabled={disabled} onChange={(e) => onChange(e.target.value as T)}>
        {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
      <span className="popup-arrows"><Symbol name="chevron.up.chevron.down" size={10} strokeWidth={2.2} /></span>
    </span>
  );
}

function Picker<T extends string>(props: { label: string; value: T; options: { value: T; label: string }[]; onChange: (v: T) => void; disabled?: boolean }) {
  return <Row label={props.label}><PopUp {...props} /></Row>;
}

function Segmented<T extends string>({ value, options, onChange }: { value: T; options: { value: T; label: string }[]; onChange: (v: T) => void }) {
  return (
    <div className="segmented" role="tablist">
      {options.map((o) => <button key={o.value} type="button" role="tab" aria-selected={o.value === value} className={o.value === value ? "on" : ""} onClick={() => onChange(o.value)}>{o.label}</button>)}
    </div>
  );
}

function Stepper({ label, value, min, max, step = 1, onChange }: { label: string; value: number; min: number; max: number; step?: number; onChange: (v: number) => void }) {
  return (
    <Row label={label}>
      <span className="stepper">
        <button type="button" aria-label="+" disabled={value + step > max} onClick={() => onChange(Math.min(max, value + step))}><Symbol name="chevron.up" size={9} strokeWidth={2.5} /></button>
        <button type="button" aria-label="−" disabled={value - step < min} onClick={() => onChange(Math.max(min, value - step))}><Symbol name="chevron.down" size={9} strokeWidth={2.5} /></button>
      </span>
    </Row>
  );
}

function Disclosure({ title, open, onToggle, children }: { title: string; open: boolean; onToggle: () => void; children: ReactNode }) {
  return (
    <div>
      <button type="button" className={`disclosure-row ${open ? "open" : ""}`} onClick={onToggle} aria-expanded={open}>
        <Symbol name="chevron.right" size={11} strokeWidth={2.5} className="chev" /> {title}
      </button>
      {open && <div className="disclosure-body">{Children.toArray(children).filter(Boolean).map((c, i) => <div key={i}>{c}</div>)}</div>}
    </div>
  );
}

function relative(iso: string | number): string {
  const ms = typeof iso === "number" ? iso : Date.parse(iso);
  const rtf = new Intl.RelativeTimeFormat(resolvedLanguage(), { numeric: "auto" });
  const s = Math.round((ms - Date.now()) / 1000), a = Math.abs(s);
  if (a < 60) return rtf.format(s, "second");
  if (a < 3600) return rtf.format(Math.round(s / 60), "minute");
  if (a < 86400) return rtf.format(Math.round(s / 3600), "hour");
  return rtf.format(Math.round(s / 86400), "day");
}

// MARK: General

const accents: { id: "blue" | "violet" | "green" | "orange" | "graphite"; name: string; color: string }[] = [
  { id: "blue", name: "Blue", color: "#4d6bfe" }, { id: "violet", name: "Violet", color: "#7657f2" }, { id: "green", name: "Green", color: "#13906a" },
  { id: "orange", name: "Orange", color: "#e0702a" }, { id: "graphite", name: "Graphite", color: "#3f3f46" },
];

function GeneralSettings() {
  const c = useApp((s) => s.config);
  const language = useApp((s) => s.languageChoice);
  const accent = useApp((s) => s.accent);
  const version = useApp((s) => s.version);
  const [cliMessage, setCliMessage] = useState("");
  const set = (patch: Partial<Config>, typing = false) => void A.updateConfig(patch, typing);
  return (
    <Form>
      <Section label={L("Language")}>
        <Picker label={L("Interface language")} value={language as Language} onChange={(l) => void A.setLanguage(l)}
                options={(Object.keys(languageNames) as Language[]).map((l) => ({ value: l, label: l === "system" ? L("System") : languageNames[l] }))} />
        <Caption>{L("Agents reply in the language you write in; the interface language is also passed to them as a hint.")}</Caption>
      </Section>
      <Section label={L("Appearance")}>
        <Picker label={L("Theme")} value={c.appearance} onChange={(v) => set({ appearance: v })}
                options={[{ value: "system", label: L("System") }, { value: "light", label: L("Light") }, { value: "dark", label: L("Dark") }]} />
        <Row label={L("Accent color")}>
          <span className="swatches">
            {accents.map((a) => (
              <button key={a.id} type="button" className={`swatch ${accent === a.id ? "on" : ""}`} style={{ ["--swatch" as string]: a.color }} title={L(a.name)} aria-label={L(a.name)}
                      onClick={() => A.setAccent(a.id)}><i style={{ background: a.color }} /></button>
            ))}
          </span>
        </Row>
        <Toggle label={L("Show thinking")} on={c.showThinking} onChange={(v) => set({ showThinking: v })} />
        <Toggle label={L("Generate conversation titles automatically")} on={c.autoTitles} onChange={(v) => set({ autoTitles: v })} />
        <Caption>{L("After the first reply, the worker model names the conversation after its topic. A name you give with Rename is never replaced.")}</Caption>
      </Section>
      <Section label={L("Live monitoring")}>
        <Toggle label={L("Wake the agent when background jobs finish, fail, match a pattern or stall")} on={c.autoWake} onChange={(v) => set({ autoWake: v })} />
        <Toggle label={L("Notify me about job events")} on={c.notifyJobs} onChange={(v) => set({ notifyJobs: v })} />
        <Toggle label={L("Notify me when a turn finishes (while SieveSci is in the background)")} on={c.notifyTurnFinished} onChange={(v) => set({ notifyTurnFinished: v })} />
        <Toggle label={L("Notify me when permission is needed")} on={c.notifyPermission} onChange={(v) => set({ notifyPermission: v })} />
      </Section>
      <Section label={L("Literature")}>
        <Toggle label={L("Download open-access PDFs")} on={c.downloadOAPDFs} onChange={(v) => set({ downloadOAPDFs: v })} />
        <Caption>{L("Saves the PDF of each open-access paper added to the library (OpenAlex, Europe PMC, arXiv, Unpaywall). Off: only Europe PMC's full text or the abstract is kept.")}</Caption>
      </Section>
      <Section label={L("Identity")}>
        <SpecField title={L("Contact email")} value={c.contactEmail} placeholder="name@university.edu" onChange={(v) => set({ contactEmail: v }, true)} />
        <Caption>{L("Optional. Sent with literature requests so OpenAlex, Crossref and Unpaywall serve them from their faster polite pool; never shared elsewhere.")}</Caption>
      </Section>
      <Section label={L("Updates")}>
        {UpdateSettings({ version })}
      </Section>
      <Section label={L("Command line")}>
        <ActionRow title={L("Command-line tool")} detail={cliMessage || L("`sievesci` runs the same agent headless (scripts, scheduled tasks, SSH).")}>
          <ActionButton width="column" onClick={async () => { const r = await A.request<{ message: string }>("cli.install"); setCliMessage(r.ok ? r.value.message : r.error); }}>{L("Install")}</ActionButton>
        </ActionRow>
      </Section>
      <Section label={L("About")}>
        <ActionRow title={"SieveSci " + version} detail={L("Independently developed by 王鹤年, 2026")}>
          <ActionButton width="column" title="https://github.com/Cetirzine/SieveSci" onClick={() => A.systemOpen({ url: "https://github.com/Cetirzine/SieveSci" })}>GitHub</ActionButton>
        </ActionRow>
      </Section>
    </Form>
  );
}

type UpdateState = { kind: "idle" } | { kind: "checking" } | { kind: "upToDate"; at: number } | { kind: "available"; version: string; url: string } | { kind: "failed"; message: string };
let updateState: UpdateState = { kind: "idle" };

/** UpdateSettings: rows of the Updates section (an array, so each is its own form row). The desktop
 *  app installs a release from its GitHub page. */
function UpdateSettings({ version }: { version: string }): ReactNode[] {
  return [<UpdateRow key="row" version={version} />, ...UpdateToggles()];
}

function UpdateRow({ version }: { version: string }) {
  const [st, setSt] = useState<UpdateState>(updateState);
  const update = (s: UpdateState) => { updateState = s; setSt(s); };
  const check = async () => {
    update({ kind: "checking" });
    const r = await A.request<{ available: boolean; latest: string; url: string }>("updates.check");
    if (!r.ok) update({ kind: "failed", message: r.error });
    else if (r.value.available) update({ kind: "available", version: r.value.latest, url: r.value.url });
    else update({ kind: "upToDate", at: Date.now() });
  };
  const status = st.kind === "checking" ? L("Checking…") : st.kind === "available" ? L("SieveSci %@ is available").replace("%@", st.version)
    : st.kind === "failed" ? st.message : st.kind === "upToDate" ? L("Last checked") + " " + relative(st.at) : "";
  return (
    <div className="lc">
      <div className="stack" style={{ gap: 3 }}>
        <span className="hstack">{L("Installed version")} <span className="mono-small secondary">{version}</span></span>
        {status && <span className={`mono-tiny ${st.kind === "failed" ? "c-bad" : "secondary"}`}>{status}</span>}
      </div>
      {st.kind === "available"
        ? <ActionButton kind="primary" width="column" onClick={() => A.systemOpen({ url: st.url })}>{L("Install")}</ActionButton>
        : <ActionButton width="column" disabled={st.kind === "checking"} onClick={() => void check()}>{L("Check now")}</ActionButton>}
    </div>
  );
}

function UpdateToggles(): ReactNode[] {
  return [
    <ConfigToggle key="a" field="autoCheckUpdates" label={L("Check for updates automatically")} />,
    <ConfigToggle key="b" field="autoInstallUpdates" label={L("Download updates automatically and install them when SieveSci quits")} disabledWhen={(cfg) => !cfg.autoCheckUpdates} />,
    <Caption key="c">{L("Releases come from github.com/Cetirzine/SieveSci; each download is checked against the SHA-256 GitHub publishes for it.")}</Caption>,
  ];
}

function ConfigToggle({ field, label, disabledWhen }: { field: keyof Config; label: string; disabledWhen?: (c: Config) => boolean }) {
  const c = useApp((s) => s.config);
  return <Toggle label={label} on={c[field] === true} disabled={disabledWhen?.(c)} onChange={(v) => void A.updateConfig({ [field]: v } as Partial<Config>)} />;
}

// MARK: Providers

const formatName = (f: string) => ({ anthropic: "Anthropic Messages", openaiResponses: "OpenAI Responses", openaiChat: "OpenAI Chat Completions", gemini: "Gemini", cliAgent: "CLI" } as Record<string, string>)[f] ?? f;
const isPlan = (p: ProviderProfile) => p.billing === "plan" || p.billing === "coding";

/** Where to create a key, for the built-in presets (ProviderStatus.keyPage). */
const keyPages: Record<string, string> = {
  anthropic: "https://console.anthropic.com/settings/keys", openai: "https://platform.openai.com/api-keys", gemini: "https://aistudio.google.com/apikey",
  deepseek: "https://platform.deepseek.com/api_keys", "glm-coding-cn": "https://open.bigmodel.cn/usercenter/apikeys", "glm-api": "https://open.bigmodel.cn/usercenter/apikeys",
  "glm-coding-intl": "https://z.ai/manage-apikey/apikey-list", openrouter: "https://openrouter.ai/keys",
  closeai: "https://platform.closeai-asia.com/dashboard", "closeai-anthropic": "https://platform.closeai-asia.com/dashboard",
};
/** How to install and sign in to a subscription CLI (ProviderStatus.cliHelp). */
const cliHelp: Record<string, { install: string; signIn: string }> = {
  claude: { install: "npm install -g @anthropic-ai/claude-code", signIn: "claude" }, codex: { install: "npm install -g @openai/codex", signIn: "codex login" },
  gemini: { install: "npm install -g @google/gemini-cli", signIn: "gemini" }, agy: { install: "curl -fsSL https://antigravity.google/cli/install.sh | bash", signIn: "agy" },
};
/** A second key some relays need just to read the balance (CloseAI management keys). */
function adminKeyRef(p: ProviderProfile): string | null {
  try { return new URL(p.baseURL).host.toLowerCase() === "api.openai-proxy.org" ? "CLOSEAI_ADMIN_KEY" : null; } catch { return null; }
}
const tokens = (n: number) => (n >= 1_000_000 ? `${Math.floor(n / 1_000_000)}M` : `${Math.floor(n / 1000)}k`);

let providerSelection: string | null = null;

function ProvidersSettings() {
  const providers = useApp((s) => s.config.providers);
  const usable = useApp((s) => s.usable);
  const info = useApp((s) => s.providerInfo);
  const quotas = useApp((s) => s.quotas);
  const [selection, setSelectionState] = useState<string | null>(providerSelection ?? usable[0] ?? null);
  const setSelection = (id: string | null) => { providerSelection = id; setSelectionState(id); };
  const [adding, setAdding] = useState(false);
  useEffect(() => { void A.refreshQuotas(); }, []);

  const ready = providers.filter((p) => usable.includes(p.id));
  const rest = providers.filter((p) => !usable.includes(p.id));
  const groups = [
    { title: L("Ready"), items: ready },
    { title: L("Subscription plans"), items: rest.filter((p) => p.family === "cliAgent" || isPlan(p)) },
    { title: L("API keys"), items: rest.filter((p) => p.family !== "cliAgent" && p.billing === "api") },
    { title: L("Relays & custom"), items: rest.filter((p) => p.family !== "cliAgent" && p.billing !== "api" && !isPlan(p)) },
  ].filter((g) => g.items.length > 0);
  const selected = providers.find((p) => p.id === selection);

  return (
    <div className="providers-split">
      <div className="providers-list">
        <div className="providers-list-scroll">
          {groups.map((g) => (
            <div key={g.title}>
              <SectionLabel>{g.title}</SectionLabel>
              {g.items.map((p) => {
                const st = info[p.id];
                const line = usable.includes(p.id) ? (quotas[p.id]?.summary ?? st?.short ?? "") : (st?.short ?? "");
                return (
                  <button key={p.id} type="button" className={`provider-row ${p.id === selection ? "selected" : ""}`} onClick={() => setSelection(p.id)}
                          title={formatName(p.family) + " · " + L(p.billing)}>
                    <span className={`dot ${usable.includes(p.id) ? "ok" : ""}`} aria-hidden />
                    <span className="names"><span className="name t-body">{p.displayName}</span><span className="mono-tiny secondary">{line}</span></span>
                  </button>
                );
              })}
            </div>
          ))}
        </div>
        <div className="providers-bar">
          <IconButton symbol="plus" label={L("Add provider…")} onClick={() => setAdding(true)} />
          <IconButton symbol="minus" label={L("Remove provider")} disabled={!selection}
                      onClick={() => { if (selection) { void A.updateConfig({ providers: providers.filter((p) => p.id !== selection) }); setSelection(null); } }} />
        </div>
      </div>
      <div className="providers-detail">
        {selected ? <ProviderDetail key={selected.id} profile={selected} /> : <ProvidersOverview add={() => setAdding(true)} select={setSelection} />}
      </div>
      {adding && <AddProviderSheet close={() => setAdding(false)} added={(id) => { setSelection(id); setAdding(false); }} />}
    </div>
  );
}

function ProvidersOverview({ add, select }: { add: () => void; select: (id: string) => void }) {
  const providers = useApp((s) => s.config.providers);
  const usable = useApp((s) => s.usable);
  const info = useApp((s) => s.providerInfo);
  return (
    <div className="overview">
      <h2>{usable.length === 0 ? L("No model provider is ready yet") : L("Pick a provider to change it")}</h2>
      <span className="secondary">{L("One is enough to start. The quickest options:")}</span>
      <div className="stack">
        {["claude-code", "deepseek", "anthropic", "glm-coding-cn"].map((id) => providers.find((p) => p.id === id)).filter((p): p is ProviderProfile => !!p).map((p) => (
          <button key={p.id} type="button" className="quick-row" onClick={() => select(p.id)}>
            <span>{p.displayName}</span><span style={{ flex: 1 }} /><span className="secondary">{info[p.id]?.short}</span><Symbol name="chevron.right" size={12} className="tertiary" />
          </button>
        ))}
      </div>
      <div style={{ paddingTop: 4 }}><ActionButton onClick={add}>{L("Add another provider…")}</ActionButton></div>
    </div>
  );
}

interface Discovered { id: string; displayName: string | null; contextWindow: number | null; supportsImages: boolean; supportsReasoning: boolean }

function ProviderDetail({ profile: p }: { profile: ProviderProfile }) {
  const st = useApp((s) => s.providerInfo[p.id]);
  const usable = useApp((s) => s.usable.includes(p.id));
  const quota = useApp((s) => s.quotas[p.id]);
  const [key, setKey] = useState("");
  const [keyCheck, setKeyCheck] = useState<{ ok: boolean; text: string } | null>(null);
  const [checkingKey, setCheckingKey] = useState(false);
  const [fetching, setFetching] = useState(false);
  const [discovered, setDiscovered] = useState<Discovered[]>([]);
  const [status, setStatus] = useState("");
  const [testing, setTesting] = useState(false);
  const [newModel, setNewModel] = useState("");
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [showDiscovered, setShowDiscovered] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);
  const [adminKey, setAdminKey] = useState("");
  const [refreshingUsage, setRefreshingUsage] = useState(false);
  const [header, setHeader] = useState({ name: "", value: "" });
  const hasKey = st?.hasKey ?? false;
  const platform = useApp((s) => s.platform);
  const admin = adminKeyRef(p);
  const update = (change: Partial<ProviderProfile>, typing = false) => void A.updateProvider(p.id, change, typing);
  const subscriptionFetch = p.flavor === "antigravity" || p.flavor === "codex";

  const refreshUsage = async () => {
    if (!usable && !admin) return;
    setRefreshingUsage(true);
    await A.refreshQuota(p.id);
    setRefreshingUsage(false);
  };
  const discover = async () => {
    const r = await A.request<JsonObject>("providers.discover", { id: p.id });
    if (r.ok) { A.applyConfigPayload(r.value); setDiscovered((r.value.models ?? []) as unknown as Discovered[]); }
    return r;
  };
  const checkKey = async () => {
    setCheckingKey(true);
    const r = await discover();
    setCheckingKey(false);
    if (r.ok) {
      const n = ((r.value.models ?? []) as unknown[]).length;
      setKeyCheck({ ok: true, text: n === 0 ? L("Key saved. The provider does not list models, so it could not be checked for free; use Test connection under Advanced.") : L10n.f("The key works — %d models available.", n) });
    } else setKeyCheck({ ok: false, text: L("The provider did not accept the request:") + " " + r.error });
  };
  const saveAndCheck = async () => {
    const k = key.trim();
    if (!k) return;
    await A.setKey(p.apiKeyRef, k);
    setKey("");
    update({ enabled: true });
    await checkKey();
  };
  const fetchModels = async () => {
    setFetching(true);
    const r = await discover();
    setFetching(false);
    setStatus(r.ok ? L10n.f("%d models listed.", ((r.value.models ?? []) as unknown[]).length) : L("Listing failed:") + " " + r.error);
  };
  const addModel = () => {
    const m = newModel.trim();
    const change: Partial<ProviderProfile> = {};
    if (m && !p.models.includes(m)) change.models = [...p.models, m];
    if (!p.defaultModel) change.defaultModel = m;
    update(change);
    setNewModel("");
  };
  const detect = async (family: string, baseURL: string) => {
    const r = await A.request<{ options: JsonObject }>("providers.detectOptions", { family, baseURL });
    if (r.ok) update({ family, baseURL, options: r.value.options });
  };

  useEffect(() => {
    if (p.billing === "coding") update({ billing: "plan" });
    void refreshUsage();
    if (subscriptionFetch) void fetchModels();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [p.id]);

  const opts = p.options as unknown as { anthropicCacheControl: boolean; supportsLongRetention: boolean; sendPromptCacheKey: boolean; cacheControlInChatParts: boolean;
    explicitPromptCacheMode: boolean; streamUsage: boolean; sessionAffinity: string; headers: Record<string, string> };
  const setOpt = (change: Partial<typeof opts>, typing = false) => update({ options: { ...p.options, ...change } as JsonObject }, typing);
  const exe = p.executable ?? "";
  const help = cliHelp[exe];

  const keySection = (
    <div className="stack">
      <Caption>{hasKey
        ? L(onPlatform(platform, "API key saved in the macOS Keychain. Paste a new one to replace it.", "API key saved in Windows Credential Manager. Paste a new one to replace it.", "API key saved in a private file only you can read. Paste a new one to replace it."))
        : L(onPlatform(platform, "Paste your API key. It is stored in the macOS Keychain, never in a file.", "Paste your API key. It is stored in Windows Credential Manager, never in a plain file.", "Paste your API key. It is kept in a private file only you can read, never in the configuration."))}</Caption>
      <div className="hstack">
        <span className="grow"><SpecField mono type="password" value={key} onChange={setKey} placeholder={hasKey ? L("Saved — paste a new key to replace it") : L("Paste your API key")}
                                           onKeyDown={(e) => { if (e.key === "Enter") void saveAndCheck(); }} /></span>
        <ActionButton kind="primary" width="column" disabled={!key || checkingKey} onClick={() => void saveAndCheck()}>{checkingKey ? L("Checking…") : L("Save & check")}</ActionButton>
      </div>
      <div className="hstack" style={{ gap: 12 }}>
        {keyPages[p.id] && <button type="button" className="link-button" onClick={() => A.systemOpen({ url: keyPages[p.id] })}>{L("Get an API key ↗")}</button>}
        {hasKey && <button type="button" className="link-button" disabled={checkingKey} onClick={() => void checkKey()}>{checkingKey ? L("Checking…") : L("Check key")}</button>}
        {hasKey && <button type="button" className="link-button quiet" onClick={() => { void A.setKey(p.apiKeyRef, ""); setKeyCheck(null); }}>{L("Remove key")}</button>}
      </div>
      {keyCheck && <span className={`check-line ${keyCheck.ok ? "c-ok" : "c-warn"}`}><Symbol name={keyCheck.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"} size={12} />{keyCheck.text}</span>}
    </div>
  );

  const cliSection = (
    <div className="stack">
      {st?.cliPath
        ? <span className="check-line c-ok"><Symbol name="checkmark.circle.fill" size={12} />{L10n.f("Found %@ — SieveSci drives it with your existing sign-in, so usage counts against your plan. Your login token is never read.", st.cliPath)}</span>
        : <span className="check-line secondary"><Symbol name="xmark.circle" size={12} />{L10n.f(onPlatform(platform, "%@ is not installed on this Mac.", "%@ is not installed on this computer."), exe)}</span>}
      {help && <>
        <Caption>{st?.cliPath ? L(onPlatform(platform, "Not signed in yet? Run this once in Terminal:", "Not signed in yet? Run this once in a terminal:"))
                               : L(onPlatform(platform, "Install it in Terminal, then sign in once:", "Install it in a terminal, then sign in once:"))}</Caption>
        <div className="code-box">{st?.cliPath ? help.signIn : `${help.install}\n${help.signIn}`}</div>
      </>}
    </div>
  );

  const usageSection = (
    <Section header={<><SectionLabel>{L("Usage & limits")}</SectionLabel><IconButton symbol="arrow.clockwise" label={L("Refresh")} disabled={refreshingUsage} onClick={() => void refreshUsage()} /></>}>
      {quota ? quotaRows(quota) : <Caption>{refreshingUsage ? L("Checking…") : L("Not checked yet.")}</Caption>}
      {admin && (
        <div className="stack">
          <div className="hstack">
            <span className="grow"><SpecField mono type="password" value={adminKey} onChange={setAdminKey} placeholder={getState().keys[admin] ? L("Saved — paste a new key to replace it") : L("Management key (sk-admin-…)")} /></span>
            <ActionButton width="column" disabled={!adminKey} onClick={async () => { await A.setKey(admin, adminKey.trim()); setAdminKey(""); void refreshUsage(); }}>{L("Save")}</ActionButton>
          </div>
          <Caption>{L("Used only to read the balance; it cannot call models.")}</Caption>
        </div>
      )}
    </Section>
  );

  return (
    <Form>
      <Section>
        <div className="hstack">
          <span style={{ font: "600 16px var(--sans)" }}>{p.displayName}</span>
          <Chip text={st?.short ?? ""} tint={st?.ready ? "var(--ok)" : "var(--secondary)"} />
          <span style={{ flex: 1 }} />
          <Switch on={p.enabled} label={L("Enabled")} onChange={(v) => update({ enabled: v })} />
        </div>
        {p.family === "cliAgent" ? cliSection : keySection}
      </Section>
      {(st?.ready || p.family === "cliAgent" || admin) && usageSection}
      <Section label={L("Models")}>
        <div className="hstack">
          <span className="grow"><SpecField mono value={newModel} onChange={setNewModel} placeholder={L("Model id, e.g. deepseek-chat")} onKeyDown={(e) => { if (e.key === "Enter") addModel(); }} /></span>
          <ActionButton width="column" disabled={!newModel} onClick={addModel}>{L("Add")}</ActionButton>
        </div>
        <ActionRow title={L("Models from the provider")} detail={L("Lists what this key can use; nothing is billed.")}>
          <ActionButton width="column" disabled={fetching || (p.family === "cliAgent" ? !subscriptionFetch : !hasKey)} onClick={() => void fetchModels()}>{fetching ? L("Fetching…") : L("Fetch")}</ActionButton>
        </ActionRow>
        {p.models.map((m) => {
          const d = discovered.find((x) => x.id === m);
          const ms = st?.models[m];
          const ctx = ms?.custom ? ms.contextWindow : (d?.contextWindow ?? ms?.contextWindow ?? 200_000);
          return [
            <div key={m} className="model-line">
              <button type="button" className="plain-icon" title={L("Default model")} aria-label={L("Default model")} onClick={() => update({ defaultModel: m })}>
                <Symbol name="star" size={13} style={p.defaultModel === m ? { fill: "currentColor" } : undefined} />
              </button>
              <span className="mono-small">{m}</span>
              <span style={{ flex: 1 }} />
              <span className="t-caption secondary">{L10n.f("%@ ctx", tokens(ctx))}</span>
              {(ms?.custom ? ms.supportsImages : (d?.supportsImages ?? ms?.supportsImages)) && <span className="secondary" title={L("Accepts images")}><Symbol name="photo" size={12} /></span>}
              {(ms?.custom ? ms.supportsReasoning : (d?.supportsReasoning ?? ms?.supportsReasoning)) && <span className="secondary" title={L("Reasoning model")}><Symbol name="brain" size={12} /></span>}
              {ms?.custom && <Chip text={L("Custom")} tint="var(--accent)" />}
              <IconButton symbol="slider.horizontal.3" label={L("Edit model specs")} className={editing === m ? "on" : ""} onClick={() => setEditing(editing === m ? null : m)} />
              <IconButton symbol="xmark" label={L("Remove")} onClick={() => update({ models: p.models.filter((x) => x !== m), modelSettings: (p.modelSettings as unknown as ModelSpec[]).filter((x) => x.id !== m) as never })} />
            </div>
          ].concat(editing === m && ms ? [<ModelSpecEditor key={m + "-spec"} model={m} info={ms} profile={p} onChange={(change) => update(change)} />] : []);
        })}
        {discovered.length > 0 && (
          <Disclosure title={L10n.f("%d models available", discovered.length)} open={showDiscovered} onToggle={() => setShowDiscovered(!showDiscovered)}>
            {discovered.filter((d) => !p.models.includes(d.id)).map((d) => (
              <div key={d.id} className="hstack">
                <span className="mono-tiny">{d.id}</span>
                {d.contextWindow && <span className="t-caption secondary">{tokens(d.contextWindow)}</span>}
                <span style={{ flex: 1 }} />
                <ActionButton width="column" onClick={() => update({ models: [...p.models, d.id] })}>{L("Add")}</ActionButton>
              </div>
            ))}
          </Disclosure>
        )}
      </Section>
      <Section>
        <Disclosure title={L("Advanced")} open={showAdvanced} onToggle={() => setShowAdvanced(!showAdvanced)}>
          {p.notes && <Caption>{p.notes}</Caption>}
          <SpecField title={L("Name")} value={p.displayName} placeholder="My relay" onChange={(v) => update({ displayName: v }, true)} />
          <Picker label={L("API format")} value={p.family} onChange={(f) => void detect(f, p.baseURL)}
                  options={["anthropic", "openaiResponses", "openaiChat", "gemini", "cliAgent"].map((f) => ({ value: f, label: formatName(f) }))} />
          {p.family === "cliAgent"
            ? <SpecField title={L("Executable")} mono value={exe} placeholder="claude" onChange={(v) => update({ executable: v }, true)} />
            : [<SpecField key="u" title={L("Base URL")} mono value={p.baseURL} placeholder="https://api.example.com/v1" onChange={(v) => update({ baseURL: v }, true)}
                          onKeyDown={(e) => { if (e.key === "Enter") void detect(p.family, p.baseURL); }} />,
               <SpecField key="k" title={L(onPlatform(platform, "Keychain / environment name", "Credential Manager / environment name", "Key file / environment name"))} mono value={p.apiKeyRef} placeholder="EXAMPLE_API_KEY" onChange={(v) => update({ apiKeyRef: v }, true)} />]}
          <Picker label={L("Billing")} value={p.billing} onChange={(b) => update({ billing: b })}
                  options={[{ value: "api", label: L("API (pay per token)") }, { value: "plan", label: L("Coding plan / subscription") }, { value: "relay", label: L("Relay (中转站)") }, { value: "local", label: L("Local") }]} />
          <span className="t-caption secondary" style={{ fontWeight: 600 }}>{L("Cache & compatibility")}</span>
          <Toggle label={L("Anthropic cache_control breakpoints")} on={opts.anthropicCacheControl} onChange={(v) => setOpt({ anthropicCacheControl: v })} />
          <Toggle label={L("Long cache retention (1h / 24h)")} on={opts.supportsLongRetention} onChange={(v) => setOpt({ supportsLongRetention: v })} />
          <Toggle label={L("Send prompt_cache_key")} on={opts.sendPromptCacheKey} onChange={(v) => setOpt({ sendPromptCacheKey: v })} />
          <Toggle label={L("cache_control in chat content parts (OpenRouter-style relays)")} on={opts.cacheControlInChatParts} onChange={(v) => setOpt({ cacheControlInChatParts: v })} />
          <Toggle label={L("Explicit Gemini context cache")} on={opts.explicitPromptCacheMode} onChange={(v) => setOpt({ explicitPromptCacheMode: v })} />
          <Toggle label={L("Stream usage")} on={opts.streamUsage} onChange={(v) => setOpt({ streamUsage: v })} />
          <SpecField title={L("Session-affinity header")} mono value={opts.sessionAffinity} placeholder="x-session-affinity" onChange={(v) => setOpt({ sessionAffinity: v }, true)} />
          <ActionRow title={L("Reset to detected defaults")}><ActionButton width="column" onClick={() => void detect(p.family, p.baseURL)}>{L("Reset")}</ActionButton></ActionRow>
          <span className="t-caption secondary" style={{ fontWeight: 600 }}>{L("Extra headers")}</span>
          {Object.entries(opts.headers ?? {}).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => (
            <div key={k} className="hstack">
              <span className="mono-tiny">{k}</span><span className="mono-tiny secondary grow clip">{v}</span>
              <IconButton symbol="xmark" label={L("Remove")} onClick={() => { const h = { ...opts.headers }; delete h[k]; setOpt({ headers: h }); }} />
            </div>
          ))}
          <div className="hstack">
            <span className="grow"><SpecField mono value={header.name} placeholder={L("Header")} onChange={(v) => setHeader({ ...header, name: v })} /></span>
            <span className="grow"><SpecField mono value={header.value} placeholder={L("Value")} onChange={(v) => setHeader({ ...header, value: v })} /></span>
            <ActionButton width="column" disabled={!header.name} onClick={() => { setOpt({ headers: { ...opts.headers, [header.name]: header.value } }); setHeader({ name: "", value: "" }); }}>{L("Add")}</ActionButton>
          </div>
          <span className="t-caption secondary" style={{ fontWeight: 600 }}>{L("Check")}</span>
          <ActionRow title={L("Test connection and cache")} detail={L("sends two short requests (a few thousand tokens)")}>
            <ActionButton width="column" disabled={testing} onClick={async () => {
              setTesting(true);
              const r = await A.request<{ status: string }>("providers.test", { id: p.id });
              setTesting(false);
              setStatus(r.ok ? r.value.status : r.error);
              void A.refreshQuota(p.id);
            }}>{testing ? L("Testing…") : L("Test")}</ActionButton>
          </ActionRow>
          {status && <span className="mono-tiny status-text">{status}</span>}
        </Disclosure>
      </Section>
    </Form>
  );
}

/** A model's specs set by hand, for providers whose limits differ from what the catalogs or the API say.
 *  Saved as the profile's `modelSettings` entry, which wins everywhere (ModelDiscovery.effectiveSettings). */
function ModelSpecEditor({ model, info, profile, onChange }: { model: string; info: ModelInfo; profile: ProviderProfile; onChange: (c: Partial<ProviderProfile>) => void }) {
  const det = info.detected ?? info;
  const others = (profile.modelSettings as unknown as ModelSpec[]).filter((x) => x.id !== model);
  const save = (change: Partial<ModelSpec>) => {
    const spec: ModelSpec = { id: model, contextWindow: info.contextWindow, maxOutput: info.maxOutput, supportsImages: info.supportsImages, supportsReasoning: info.supportsReasoning, ...change };
    onChange({ modelSettings: [...others, spec] as never });
  };
  const num = (label: string, key: "contextWindow" | "maxOutput") => (
    <div className="lc">
      <span className="stack" style={{ gap: 1 }}><span>{label}</span><span className="t-caption tertiary">{L10n.f("Detected: %@", det[key].toLocaleString())}</span></span>
      <span className="lc-value"><NumberField value={info[key]} onCommit={(v) => save({ [key]: v })} /> <span className="t-caption secondary">{L("tokens")}</span></span>
    </div>
  );
  return (
    <div className="model-spec stack">
      {num(L("Context window"), "contextWindow")}
      {num(L("Max output"), "maxOutput")}
      <Toggle label={L("Accepts images")} on={info.supportsImages} onChange={(v) => save({ supportsImages: v })} />
      <Toggle label={L("Reasoning model")} on={info.supportsReasoning} onChange={(v) => save({ supportsReasoning: v })} />
      <div className="lc">
        <Caption>{L("Set by hand when the provider reports different limits than the model really has. These values win over the catalogs, the provider's listing and what its API reports.")}</Caption>
        <ActionButton width="column" disabled={!info.custom} onClick={() => onChange({ modelSettings: others as never })}>{L("Reset")}</ActionButton>
      </div>
    </div>
  );
}

/** A token count field that saves on Enter or when it loses focus (whole numbers, at least 1k). */
function NumberField({ value, onCommit }: { value: number; onCommit: (v: number) => void }) {
  const [text, setText] = useState(String(value));
  useEffect(() => setText(String(value)), [value]);
  const commit = () => {
    const v = Math.round(Number(text.replace(/[,_\s]/g, "")));
    if (Number.isFinite(v) && v >= 1000 && v !== value) onCommit(v); else setText(String(value));
  };
  return <span style={{ width: 120 }}><SpecField mono value={text} onChange={setText} inputMode="numeric" onBlur={commit} onKeyDown={(e) => { if (e.key === "Enter") commit(); }} /></span>;
}

/** Plan limits (5-hour / weekly windows) and balances, with when they reset. */
function quotaRows(q: Quota): ReactNode[] {
  const rows: ReactNode[] = [];
  if (q.plan) rows.push(<Row key="plan" label={L("Plan")}><span>{q.plan}</span></Row>);
  q.meters.forEach((m, i) => {
    const u = m.usedFraction;
    rows.push(
      <div key={i} className="usage-meter">
        <div className="lc"><span>{m.title}</span>
          <span style={{ fontVariantNumeric: "tabular-nums", color: m.exhausted ? "var(--bad)" : (u ?? 0) > 0.85 ? "var(--warn)" : undefined }}>{m.value}</span></div>
        {u !== null && <div className="progress"><i style={{ width: `${Math.min(Math.max(u, 0), 1) * 100}%`, background: u > 0.85 ? "var(--bad)" : undefined }} /></div>}
        {m.resetsAt && <span className="t-caption secondary">{L10n.f("resets %@", relative(m.resetsAt))}</span>}
      </div>,
    );
  });
  if (q.meters.length === 0 || q.note) rows.push(<Caption key="note">{q.note ?? L("No balance or quota API for this provider.")}</Caption>);
  return rows;
}

interface CatalogRow { id: string; title: string; detail: string }

function AddProviderSheet({ close, added }: { close: () => void; added: (id: string) => void }) {
  const [tab, setTab] = useState<"0" | "1" | "2" | "3">("0");
  const [query, setQuery] = useState("");
  const [catalog, setCatalog] = useState<{ presets: CatalogRow[]; endpoints: CatalogRow[]; modelsDev: CatalogRow[] } | null>(null);
  const [custom, setCustom] = useState({ name: "", url: "", family: "openaiChat" });
  useEffect(() => { void A.request<typeof catalog & object>("providers.catalog").then((r) => { if (r.ok) setCatalog(r.value); }); }, []);
  useEffect(() => {
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") close(); };
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [close]);
  const add = async (params: JsonObject) => {
    const r = await A.request<JsonObject>("providers.add", params);
    if (r.ok) { A.applyConfigPayload(r.value); added(String(r.value.id)); }
  };
  const q = query.toLowerCase();
  const rows = (list: CatalogRow[] | undefined, source: string) => (list ?? []).filter((x) => !q || x.title.toLowerCase().includes(q)).map((x) => (
    <div key={x.id} className="sheet-row">
      <div className="grow"><div>{x.title}</div><div className="t-caption secondary">{x.detail}</div></div>
      <ActionButton width="column" onClick={() => void add({ source, id: x.id })}>{L("Add")}</ActionButton>
    </div>
  ));
  return (
    <div className="sheet-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) close(); }}>
      <div className="sheet appear-pop" role="dialog" aria-label={L("Add provider")}>
        <h3>{L("Add provider")}</h3>
        <Segmented value={tab} onChange={setTab} options={[{ value: "0", label: L("Presets") }, { value: "1", label: L("Endpoint catalog") }, { value: "2", label: "models.dev" }, { value: "3", label: L("Custom / relay") }]} />
        {tab !== "3" && <SpecField value={query} onChange={setQuery} placeholder={L("Search")} />}
        <div className="sheet-list">
          {tab === "0" && rows(catalog?.presets, "preset")}
          {tab === "1" && rows(catalog?.endpoints, "endpoint")}
          {tab === "2" && rows(catalog?.modelsDev, "modelsDev")}
          {tab === "3" && (
            <div className="sheet-custom">
              <SpecField title={L("Name")} value={custom.name} placeholder="My relay" onChange={(v) => setCustom({ ...custom, name: v })} />
              <SpecField title={L("Base URL")} mono value={custom.url} placeholder="https://relay.example.com/v1" onChange={(v) => setCustom({ ...custom, url: v })} />
              <Picker label={L("API format")} value={custom.family} onChange={(f) => setCustom({ ...custom, family: f })}
                      options={["anthropic", "openaiResponses", "openaiChat", "gemini"].map((f) => ({ value: f, label: formatName(f) }))} />
              <Caption>{L("Relays (new-api / one-api, OpenRouter, resellers) usually speak OpenAI Chat Completions; many also offer Anthropic Messages or Gemini routes, which keep vendor-native caching.")}</Caption>
              <div className="sheet-foot">
                <ActionButton kind="primary" width="column" disabled={!custom.url} onClick={() => void add({ source: "custom", name: custom.name, baseURL: custom.url, family: custom.family })}>{L("Add")}</ActionButton>
              </div>
            </div>
          )}
        </div>
        <div className="sheet-foot"><ActionButton width="column" onClick={close}>{L("Cancel")}</ActionButton></div>
      </div>
    </div>
  );
}

// MARK: Models

const refKey = (r: ModelRef | null | undefined) => (r ? `${r.providerId}\t${r.model}` : "");
const parseRef = (k: string): ModelRef | null => { if (!k) return null; const [providerId, model] = k.split("\t"); return { providerId, model }; };
const roles = ["main", "worker", "checker", "verifier"] as const;

interface Overview { roles: Record<string, { model: ModelRef | null; reasons: string }>; vision: ModelRef[]; benchmarks: { title: string; asOf: string; source: string }[] }

function ModelsSettings() {
  const c = useApp((s) => s.config);
  const usable = useApp((s) => s.usable);
  const [overview, setOverview] = useState<Overview | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [report, setReport] = useState("");
  const rolesKey = JSON.stringify(c.roles) + usable.join(",");
  useEffect(() => { void A.request<Overview>("models.overview").then((r) => { if (r.ok) setOverview(r.value); }); }, [rolesKey]);
  const refs = useMemo(() => c.providers.filter((p) => usable.includes(p.id)).flatMap((p) => p.models.map((m) => ({ providerId: p.id, model: m }))), [c.providers, usable]);
  const label = (r: ModelRef) => (c.providers.find((p) => p.id === r.providerId)?.displayName ?? r.providerId) + " / " + r.model;
  const refOptions = (none: string) => [{ value: "", label: none }, ...refs.map((r) => ({ value: refKey(r), label: label(r) }))];
  const setRoles = (change: Partial<Config["roles"]>) => void A.updateConfig({ roles: { ...c.roles, ...change } });
  return (
    <Form>
      <Section>
        <div className="segmented labelled"><span>{L("Assignment")}</span>
          <Segmented value={c.roles.mode} onChange={(m) => setRoles({ mode: m })}
                     options={[{ value: "auto", label: L("Automatic (benchmarks)") }, { value: "same", label: L("Same model for all roles") }, { value: "custom", label: L("Custom per role") }]} />
        </div>
        <Caption>{L("Automatic picks, from your providers, the best model per role on LAB-Bench 2, RiemannBench, Terminal-Bench Science and PostTrainBench (cited snapshot, refreshable), preferring a different vendor for the checker and verifier than for the research agent.")}</Caption>
      </Section>
      {c.roles.mode === "same" && (
        <Section label={L("Model")}>
          <Picker label={L("All roles")} value={refKey(c.roles.same)} options={refOptions(L("Choose…"))} onChange={(k) => setRoles({ same: parseRef(k) ?? undefined })} />
        </Section>
      )}
      <Section label={L("Roles")}>
        {roles.map((role) => (
          <div key={role} className="role-line">
            <div className="lc">
              <span className="hstack"><RoleGhostIcon role={role} size={18} /><span style={{ fontWeight: 500 }}>{roleName(role)}</span></span>
              {c.roles.mode === "custom"
                ? <PopUp value={refKey(c.roles.custom[role])} options={refOptions(L("Automatic"))}
                         onChange={(k) => { const custom = { ...c.roles.custom }; const r = parseRef(k); if (r) custom[role] = r; else delete custom[role]; setRoles({ custom }); }} />
                : <span className="mono-small">{overview?.roles[role]?.model ? label(overview.roles[role].model!) : L("none")}</span>}
            </div>
            {overview?.roles[role]?.reasons && <span className="caption2">{overview.roles[role].reasons}</span>}
          </div>
        ))}
      </Section>
      <Section label={L("Workers")}>
        <Toggle label={L("Run independent parts on workers automatically")} on={c.autoDelegate} onChange={(v) => void A.updateConfig({ autoDelegate: v })} />
        {c.autoDelegate && <Stepper label={L10n.f("Workers at once: %d", c.maxParallelWorkers)} value={c.maxParallelWorkers} min={1} max={8} onChange={(v) => void A.updateConfig({ maxParallelWorkers: v })} />}
        <Caption>{L("When a request or plan has independent parts, SieveSci runs them on workers automatically.")}</Caption>
      </Section>
      <Section label={L("Brainstorming")}>
        <Toggle label={L("Let the agent start brainstorming on its own when new ideas are needed")} on={c.autoBrainstorm} onChange={(v) => void A.updateConfig({ autoBrainstorm: v })} />
        <Caption>{L("You can always ask with /brainstorm. While it brainstorms you see each stage, every idea and what it is thinking, and can wrap up or stop it. Ideas count only after a novelty check and an independent review.")}</Caption>
      </Section>
      <Section label={L("Vision")}>
        <Picker label={L("Image helper for text-only models")} value={refKey(c.visionHelper)} onChange={(k) => void A.updateConfig({ visionHelper: parseRef(k) })}
                options={[{ value: "", label: L("None") }, ...(overview?.vision ?? []).map((r) => ({ value: refKey(r), label: label(r) }))]} />
        <Caption>{L("Input modalities are detected per model (models.dev, provider listings, ZCode rules). Images sent to a text-only model are described by this helper first.")}</Caption>
      </Section>
      <Section label={L("Benchmarks")}>
        {(overview?.benchmarks ?? []).map((b) => (
          <ActionRow key={b.title} title={b.title} detail={L("as of") + " " + b.asOf}>
            <ActionButton width="column" title={b.source} onClick={() => A.systemOpen({ url: b.source })}>{L("Source")}</ActionButton>
          </ActionRow>
        ))}
        <ActionRow title={L("Refresh catalogs and leaderboards")} detail={L("Uses the research agent's model to extract leaderboard rows; every row must appear verbatim on the page.")}>
          <ActionButton width="column" disabled={refreshing} onClick={async () => {
            setRefreshing(true);
            const r = await A.request<{ report: string }>("models.refreshCatalogs");
            setRefreshing(false);
            setReport(r.ok ? r.value.report : r.error);
          }}>{refreshing ? L("Refreshing…") : L("Refresh")}</ActionButton>
        </ActionRow>
        {report && <span className="mono-tiny status-text">{report}</span>}
      </Section>
    </Form>
  );
}

// MARK: Web search

const searchKeyRefs: Record<string, string> = { brave: "BRAVE_API_KEY", tavily: "TAVILY_API_KEY", exa: "EXA_API_KEY", googleCSE: "GOOGLE_CSE_KEY" };

function SearchSettings() {
  const ws = useApp((s) => s.config.webSearch);
  const saved = useApp((s) => s.keys[s.config.webSearch.apiKeyRef] === true);
  const [key, setKey] = useState("");
  const [excluded, setExcluded] = useState(ws.excludedDomains.join("\n"));
  const set = (change: Partial<typeof ws>, typing = false) => void A.updateConfig({ webSearch: { ...getState().config.webSearch, ...change } }, typing);
  const save = async () => { if (!key) return; await A.setKey(ws.apiKeyRef, key.trim()); setKey(""); };
  return (
    <Form>
      <Section label={L("Search engine")}>
        <Picker label={L("Backend")} value={ws.backend} onChange={(b) => set({ backend: b, apiKeyRef: searchKeyRefs[b] ?? "" })}
                options={["brave", "tavily", "exa", "googleCSE", "searxng", "duckduckgo"].map((b) => ({ value: b, label: b }))} />
        {ws.apiKeyRef && (
          <div className="lc">
            <span className="hstack">{L("API key")} <Chip text={saved ? L("Saved") : L("Not set")} tint={saved ? "var(--ok)" : "var(--secondary)"} /></span>
            <span className="lc-value">
              <span style={{ width: "var(--c-field-width)" }}><SpecField mono type="password" value={key} onChange={setKey} placeholder={saved ? L("Saved — paste a new key to replace it") : L("Paste your API key")}
                                                                       onKeyDown={(e) => { if (e.key === "Enter") void save(); }} /></span>
              <ActionButton width="column" disabled={!key} onClick={() => void save()}>{L("Save")}</ActionButton>
            </span>
          </div>
        )}
        {ws.backend === "searxng" && <SpecField title="SearXNG URL" mono value={ws.searxngURL} placeholder="https://searx.example.org" onChange={(v) => set({ searxngURL: v }, true)} />}
        {ws.backend === "googleCSE" && <SpecField title="Google CX" mono value={ws.googleCX} placeholder="0123456789abcdef0" onChange={(v) => set({ googleCX: v }, true)} />}
        <Caption>{L("Models with native search (Claude API, DeepSeek and GLM Anthropic endpoints) search natively first; this engine is the fallback and the independent cross-check.")}</Caption>
      </Section>
      <Section label={L("Excluded domains")}>
        <textarea className="domains" value={excluded} spellCheck={false} aria-label={L("Excluded domains")}
                  onChange={(e) => { setExcluded(e.target.value); set({ excludedDomains: e.target.value.split("\n").map((d) => d.trim()).filter(Boolean) }, true); }} />
        <Caption>{L("Content farms and low-quality aggregators are excluded from every search by default.")}</Caption>
      </Section>
    </Form>
  );
}

// MARK: Research

interface Connector { id: string; title: string; license: string; notes: string; source: string; connected: boolean }

function ResearchSettings() {
  const c = useApp((s) => s.config);
  const [connectors, setConnectors] = useState<Connector[]>([]);
  const [message, setMessage] = useState("");
  useEffect(() => { void A.request<{ connectors: Connector[] }>("connectors.list").then((r) => { if (r.ok) setConnectors(r.value.connectors); }); }, []);
  const set = (patch: Partial<Config>) => void A.updateConfig(patch);
  return (
    <Form trailing={<div className="form-trailing-caption">{L("Changes apply to new tasks.")}</div>}>
      <Section label={L("Science connectors")}>
        {connectors.map((k) => (
          <div key={k.id} className="lc" style={{ alignItems: "flex-start" }}>
            <div className="stack" style={{ gap: 2 }}>
              <span className="hstack" style={{ gap: 4 }}><span style={{ fontWeight: 500 }}>{k.title}</span><Chip text={k.license} /></span>
              <Caption>{k.notes}</Caption>
            </div>
            <div className="stack">
              <ActionButton kind={k.connected ? "secondary" : "primary"} width="column" disabled={k.connected} onClick={async () => {
                const r = await A.request<{ message: string }>("connectors.connect", { id: k.id });
                setMessage(r.ok ? r.value.message : r.error);
                if (r.ok) setConnectors(connectors.map((x) => (x.id === k.id ? { ...x, connected: true } : x)));
              }}>{k.connected ? L("Connected") : L("Connect")}</ActionButton>
              <ActionButton width="column" title={k.source} onClick={() => A.systemOpen({ url: k.source })}>GitHub</ActionButton>
            </div>
          </div>
        ))}
        {message && <Caption>{message}</Caption>}
      </Section>
      <Section label={L("Grounding")}>
        <Toggle label={L("Require web and literature search before plans, claims and conclusions")} on={c.groundingRequired} onChange={(v) => set({ groundingRequired: v })} />
      </Section>
      <Section label={L("Independent review")}>
        <Stepper label={L10n.f("Review budget per session: %d", c.maxReviewsPerSession)} value={c.maxReviewsPerSession} min={4} max={200} step={4} onChange={(v) => set({ maxReviewsPerSession: v })} />
        <Stepper label={L10n.f("Exchanges per disagreement: %d", c.maxDeliberationExchanges)} value={c.maxDeliberationExchanges} min={1} max={4} onChange={(v) => set({ maxDeliberationExchanges: v })} />
        <Caption>{L("Agents may question and rebut each other, but only with new evidence, without repetition and within this limit; unsettled points are marked contested and shown to you.")}</Caption>
      </Section>
      <Section label={L("Sandbox")}>
        <Picker label={L("Commands the agents run")} value={c.sandboxMode} onChange={(v) => set({ sandboxMode: v })}
                options={[{ value: "workspaceWrite", label: L("Write workspace only, network on") }, { value: "workspaceWriteOffline", label: L("Write workspace only, offline") }, { value: "off", label: L("No sandbox") }]} />
        <Caption>{L("The audit log, provenance and history (.sievesci, .git) are always write-protected from agent code.")}</Caption>
      </Section>
      <Section label={L("Model calls")}>
        <Picker label={L("Prompt cache retention")} value={c.retention} onChange={(v) => set({ retention: v })}
                options={[{ value: "short", label: L("Vendor default") }, { value: "long", label: L("Long (1h / 24h; best for long sessions)") }, { value: "none", label: L("Off") }]} />
        <Row label={L("Reasoning effort")}><EffortSlider effort={c.effort} width={320} onChange={(e) => set({ effort: e })} /></Row>
      </Section>
    </Form>
  );
}

// MARK: Memory & learning

const stores = [
  { id: "MEMORY", title: () => L("Notes"), hint: () => L("Environment, conventions and facts this role has learned.") },
  { id: "USER", title: () => L("About you"), hint: () => L("Who you are and how you like to work.") },
  { id: "LESSONS", title: () => L("Lessons"), hint: () => L("Mistakes caught before, approaches that failed, quirks of sources.") },
];

function MemorySettings() {
  const [role, setRole] = useState<(typeof roles)[number]>("main");
  const [data, setData] = useState<{ dir: string; learnedSkills: string; stores: Record<string, string[]>; pendingProposals: number } | null>(null);
  useEffect(() => { void A.request<NonNullable<typeof data>>("memory.list", { role }).then((r) => { if (r.ok) setData(r.value); }); }, [role]);
  const tilde = (p: string) => p.replace(/^(\/Users\/[^/]+|\/home\/[^/]+|[A-Za-z]:\\Users\\[^\\]+)/, "~");
  return (
    <Form>
      <Section>
        <div className="segmented labelled"><span>{L("Role")}</span>
          <Segmented value={role} onChange={setRole} options={roles.map((r) => ({ value: r, label: roleName(r) }))} />
        </div>
        <Caption>{L("Every role keeps long-term memory and can propose skills. Proposals are screened against gaming and unscientific shortcuts, must cite the receipts they were learned from, and are reviewed independently; checker and verifier learning needs your approval.")}</Caption>
      </Section>
      {stores.map((s) => {
        const entries = data?.stores[s.id] ?? [];
        return (
          <Section key={s.id} header={<div><SectionLabel>{s.title()}</SectionLabel><span className="hint">{s.hint()}</span></div>}>
            {entries.length === 0 ? <span className="secondary">{L("Empty")}</span> : entries.map((e, i) => <span key={i} className="t-caption" style={{ userSelect: "text" }}>{e}</span>)}
          </Section>
        );
      })}
      <Section label={L("Files")}>
        <ActionRow title={L("Memory folder")} detail={data ? tilde(data.dir) : ""}>
          <ActionButton width="column" disabled={!data} onClick={() => data && A.systemOpen({ path: data.dir })}>{L("Open")}</ActionButton>
        </ActionRow>
        <ActionRow title={L("Learned skills")} detail="~/.sievesci/learned-skills">
          <ActionButton width="column" disabled={!data} onClick={() => data && A.systemOpen({ path: data.learnedSkills })}>{L("Open")}</ActionButton>
        </ActionRow>
        {(data?.pendingProposals ?? 0) > 0 && (
          <ActionRow title={L10n.f("%d proposals await approval", data!.pendingProposals)}>
            <ActionButton kind="primary" width="column" onClick={() => A.setMainTab("learning")}>{L("Review")}</ActionButton>
          </ActionRow>
        )}
      </Section>
    </Form>
  );
}

// MARK: Schedules

interface Scheduled { id: string; workspace: string; prompt: string; when: string }

function ScheduleSettings() {
  const workspace = useApp((s) => s.workspace);
  const platform = useApp((s) => s.platform);
  const [tasks, setTasks] = useState<Scheduled[]>([]);
  const [when, setWhen] = useState("daily 08:30");
  const [prompt, setPrompt] = useState("");
  const [message, setMessage] = useState("");
  useEffect(() => { void A.request<{ schedules: Scheduled[] }>("schedules.list").then((r) => { if (r.ok) setTasks(r.value.schedules); }); }, []);
  const base = (p: string) => p.split(/[\\/]/).filter(Boolean).pop() ?? p;
  return (
    <Form>
      <Section label={L("Scheduled tasks")}>
        {tasks.length === 0 && <span className="secondary">{L("None. Example: a daily literature watch on your topic.")}</span>}
        {tasks.map((t) => (
          <div key={t.id} className="lc">
            <div className="stack" style={{ gap: 2, minWidth: 0 }}>
              <span className="clip-2">{t.prompt}</span>
              <span className="t-caption secondary">{t.when} · {base(t.workspace)}</span>
            </div>
            <ActionButton kind="destructive" width="column" onClick={async () => {
              const r = await A.request<{ message: string; schedules: Scheduled[] }>("schedules.remove", { id: t.id });
              if (r.ok) { setMessage(r.value.message); setTasks(r.value.schedules); } else setMessage(r.error);
            }}>{L("Remove")}</ActionButton>
          </div>
        ))}
      </Section>
      <Section label={L("New")}>
        <SpecField title={L("When")} mono value={when} placeholder="daily 08:30 · weekly mon 09:00 · every 6h" onChange={setWhen} />
        <div className="stack">
          <span>{L("Prompt")}</span>
          <SpecField multiline value={prompt} onChange={setPrompt} placeholder={L("e.g. Every morning, find new papers on CRISPR base editing and summarise the three most relevant.")} />
        </div>
        <ActionRow title={workspace ? L("Runs in") + " " + base(workspace) : L("Open a workspace first.")} detail={message}>
          <ActionButton kind="primary" width="column" disabled={!prompt || !workspace} onClick={async () => {
            if (!workspace) { setMessage(L("Open a workspace first.")); return; }
            const r = await A.request<{ message: string; schedules: Scheduled[] }>("schedules.add", { workspace, when, prompt });
            if (r.ok) { setMessage(r.value.message); setTasks(r.value.schedules); setPrompt(""); } else setMessage(r.error);
          }}>{L("Schedule")}</ActionButton>
        </ActionRow>
        <Caption>{L(onPlatform(platform, "Runs headless as a macOS LaunchAgent with the same research rules, audit log and notebook; results land in the workspace's task list.",
          "Runs headless as a Windows scheduled task with the same research rules, audit log and notebook; results land in the workspace's task list.",
          "Runs headless from your crontab with the same research rules, audit log and notebook; results land in the workspace's task list."))}</Caption>
      </Section>
    </Form>
  );
}
