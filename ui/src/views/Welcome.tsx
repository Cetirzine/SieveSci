// Welcome page, ported from WelcomeView / LanguageMenu / SetupStep in SieveSciApp.swift.
import type { ReactNode } from "react";
import { L, language, languageNames, setLanguage, type Language } from "../i18n";
import { useApp, setState } from "../app/model";
import { ActionButton, CropMarks, LabelTab, Menu, SectionLabel, IconButton } from "../theme/primitives";
import { DotMatrixText, SieveField } from "../theme/dots";
import { Symbol } from "../theme/theme";
import * as A from "../app/actions";

export function WelcomeView({ onOpenWorkspace }: { onOpenWorkspace: () => void }) {
  const version = useApp((s) => s.version);
  const models = useApp((s) => s.modelStatus);
  const search = useApp((s) => s.searchStatus);
  const sidebar = useApp((s) => s.sidebarVisible);
  return (
    <div className="welcome-view">
      <div className="welcome-field"><SieveField fadeMid={0.25} /></div>
      {!sidebar && <span className="welcome-show-sidebar"><IconButton symbol="sidebar.left" label={L("Show sidebar")} onClick={() => A.setSidebarVisible(true)} /></span>}
      <div className="welcome-column appear-pop">
        <div className="welcome-hero">
          <CropMarks length={12} inset={0} />
          <div className="welcome-brand">
            <DotMatrixText text="SieveSci" rows={18} dot={4.5} gap={1.5} />
            <span className="welcome-version"><LabelTab text={version} /></span>
          </div>
          <h1 className="t-display welcome-title">{L("Welcome to SieveSci")}</h1>
          <p className="t-prose secondary welcome-lede">{L("A research agent for biology and chemistry that searches before it speaks, plans with checkpoints, and has every significant claim independently verified.")}</p>
        </div>
        <div className="welcome-steps">
          <SectionLabel>{L("Get started")}</SectionLabel>
          <SetupStep n={1} done={models.ready} title={L("Connect a model")} detail={models.text}>
            <ActionButton kind={models.ready ? "secondary" : "primary"} width="column" onClick={A.openSettings}>{models.ready ? L("Change…") : L("Set up…")}</ActionButton>
          </SetupStep>
          <SetupStep n={2} done={search.ready} title={L("Web search")} detail={search.text} optional>
            <ActionButton width="column" onClick={A.openSettings}>{L("Change…")}</ActionButton>
          </SetupStep>
          <SetupStep n={3} done={false} title={L("Open a project folder")} detail={L("Your data, code and notes. SieveSci keeps its records in a hidden .sievesci folder inside it.")} />
        </div>
        <div className="welcome-actions">
          <ActionButton kind="primary" onClick={onOpenWorkspace}>{L("Open Workspace…")}</ActionButton>
          <span style={{ flex: 1 }} />
          <LanguageMenu />
        </div>
        <div className="t-label tertiary credit">{L("Independently developed by 王鹤年, 2026")}</div>
      </div>
    </div>
  );
}

export function LanguageMenu() {
  const current = language();
  return (
    <Menu className="language-menu" align="right" title={L("Interface language")}
          label={<><Symbol name="globe" size={14} /> <span>{languageNames[current]}</span> <Symbol name="chevron.down" size={11} strokeWidth={2.5} /></>}
          items={(Object.keys(languageNames) as Language[]).map((l) => ({
            label: languageNames[l], checked: l === current,
            onSelect: () => { setLanguage(l); try { localStorage.setItem("language", l); } catch { /* unavailable */ } setState({}); },
          }))} />
  );
}

function SetupStep({ n, done, title, detail, optional, children }: { n: number; done: boolean; title: string; detail: string; optional?: boolean; children?: ReactNode }) {
  return (
    <div className="setup-step">
      {done ? <span className="step-done"><Symbol name="checkmark" size={11} strokeWidth={3.5} /></span>
            : <span className="step-number t-label">{String(n).padStart(2, "0")}</span>}
      <div className="step-text">
        <div><span className="t-body" style={{ fontWeight: 500 }}>{title}</span>{optional && <span className="t-caption tertiary"> {L("optional")}</span>}</div>
        <div className="t-meta secondary">{detail}</div>
      </div>
      <span style={{ flex: 1 }} />
      {children}
    </div>
  );
}
