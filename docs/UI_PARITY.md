# Web UI ↔ SwiftUI parity

The cross-platform UI (`ui/`, React in a Tauri window, talking to `sievesci serve`) must match the
macOS SwiftUI app one to one: same screens, same layout and design language
([DESIGN_LANGUAGE.md](DESIGN_LANGUAGE.md)), same features. This file tracks every SwiftUI view and
what the Web UI and `serve` need for it. Status: ☐ not started · ◐ partial · ☑ matches (checked by
side-by-side screenshots of the same demo scene).

**How parity is checked.** Both apps render the same demo scenes: SwiftUI with
`SIEVESCI_UI_DEMO=1` (+ `_WELCOME`, `_EMPTY`, `_ASK`, `_FOLDERS`, `_INSPECTOR`, `_TAB=<tab>`,
`_SETTINGS` + `-settingsPane <pane>`, `_APPEARANCE=light|dark`), the Web UI with
`?demo=<scene>&appearance=…`. Screenshots at the same window size are compared in light and dark.

## Architecture prerequisites

| | What | Why |
|---|---|---|
| A1 | Move `AppConfig` (providers, roles, search, permissions, effort, sandbox, appearance, notifications, limits …) from `SieveSciApp` into `SieveSciCore`, same file format and location on macOS | both front ends read and write the same settings |
| A2 | Cross-platform secret store in core: macOS Keychain (as today), Windows Credential Manager, env vars | API keys entered in either UI |
| A3 | `serve` v2: workspaces and tasks as parameters (several open, background tasks keep running), settings get/set, provider test / model list / quota, panel data, task actions | everything the SwiftUI `AppModel` does through direct calls |
| A4 | i18n: `Localizable.strings` (en, zh-Hans, zh-Hant, es, fr, ru) → JSON at build time; `L()` / `L10n.f()` in TS with the same keys | same text in every language |
| A5 | Web demo scenes ported from `DemoContent.swift` / `DemoBrainstorm.swift` | screenshot comparison |
| A6 | Brand assets: dot-matrix text (sampled like `DotMatrix.swift`), role ghost SVGs (`RoleGhostSVG.swift`, `BrandSVG.swift`), SF Symbols → matching icon set | the specimen-sheet look |

## Screens and views

### Window frame — `SieveSciApp.swift`
| SwiftUI | Web | serve | Status |
|---|---|---|---|
| `RootView` (sidebar + main, collapsible sidebar) | `Shell` | — | ◐ |
| `AppMark` (logo + name), sidebar toggle | `AppMark` | — | ☐ |
| `SidebarView`: New task, `── WORKSPACE` + open-folder button, workspaces with −/+ disclosure and new-task button, task rows | `Sidebar` | `workspaces.list`, `tasks.list(workspace)` | ◐ |
| `TaskRow` (title, relative time, running ghost badge, stage chip, context menu: rename, copy id, copy/export Markdown, mention, fork, reveal, delete) | `TaskRow` | `task.rename/fork/delete/export` | ☐ |
| `StageChip`, `NeedsYouList` (tasks waiting on you, background) | | `tasks.status` events | ☐ |
| `UpdateBanner` | | Tauri updater | ☐ |
| `MainArea`, `TopBar` (title, `ModeMenu`, `JobsMenu`, `ResearchStatus` readout, export, inspector toggle), tab bar Chat/Trace/Plan/Claims/Library/Notebook | `TopBar` | mode set, jobs list | ◐ |
| `WelcomeView` (dot-matrix brand + version tab, crop marks, GET STARTED steps, Open Workspace, `LanguageMenu`, credit) | `Welcome` | setup status | ◐ |
| `SetupStep` | | | ☐ |

### Chat — `Views/ChatView.swift`
| SwiftUI | Web | serve | Status |
|---|---|---|---|
| `ChatView` (windowed rows, `EarlierRowsLabel`, search, scroll keeping) | `Transcript` | | ◐ |
| `EmptyChatHero` (dot-matrix SieveSci + NEW TASK, headline, three `StartCard`s, dot field) | | | ☐ |
| `SessionSetupCard` (no model yet) | | | ☐ |
| `TranscriptRow`: user, assistant (Markdown + math), thinking, tool, diff, agent card, review, deliberation, commit, literature, notice | rows | `fileChanged`, `committed`, `literature`, `deliberation` events | ◐ |
| `ThinkingRow`, `ToolRow` (icon per tool, title, summary, receipt, expand), `ToolOutputView` (images) | | figure files | ◐ |
| `DiffSummaryRow`, `DiffView`, `DiffLineView` | | | ☐ |
| `AgentCardView` (role ghost, live steps, time) | | subagent events | ☐ |
| `VerdictChip`, `ReviewBody` | | | ☐ |
| `PlanApprovalBar`, `ContestedBanner` | | plan approve | ☐ |
| `Spinner` ("Pipetting…" verb, dot activity, tokens, esc to interrupt, jobs) | `Working` | | ◐ |
| `PermissionPrompt` (TERMINAL label, numbered options, feedback field) | `PermissionCard` | deny with message | ◐ |
| `AskPrompt` (tabs per question, marks, recommended, evidence, Other field, three buttons) — `Views/AskPrompt.swift` | `AskCard` | | ◐ |
| `BrainstormPanel`, `StageTrack`, `IdeaSieve`, `DotCells`, `DotStack`, `IdeaRow` — `Views/BrainstormPanel.swift` | | `brainstorm.*` | ☐ |

### Composer — `Views/PromptInput.swift`, `Views/EffortSlider.swift`
| SwiftUI | Web | serve | Status |
|---|---|---|---|
| `PromptInput` (hard-shadow box, attachments +, slash-command and @file completion, queue while running, Esc to stop) | `Composer` | completions, attachments | ◐ |
| `SandboxMenu`, `ModelMenu` (per role), `EffortMiniGauge` / `EffortMenu` | | sandbox/model/effort set | ☐ |
| `StatsLine` (turns, steps, cache, in/out, jobs), `ContextRing`, `UsagePopover` (quota, spend) | | quota | ◐ |
| `EffortSlider`, `GlitchFrame`, `GlitchLabel` (settings) | | | ☐ |

### Panels — `Views/Panels.swift`, `Views/InspectorView.swift`, `ActivityModel.swift`
| SwiftUI | Web | serve | Status |
|---|---|---|---|
| `InspectorView` + `InspectorTabButton` (side inspector) | | | ☐ |
| `ActivityPanel` / `TraceRow` (Trace: paged audit events, filters) | | `panel.trace` | ☐ |
| `PlanPanel` | | plan | ☐ |
| `ClaimsPanel` | | claims | ☐ |
| `LibraryPanel` | | `panel.library` | ☐ |
| `NotebookPanel` | | `panel.notebook` | ☐ |
| `LearningPanel` | | memory, lessons | ☐ |
| `ChangesPanel`, `HistoryPanel` (shadow git) | | `panel.changes/history` | ☐ |
| `JobsPanel` | | jobs | ☐ |
| `FiguresPanel`, `FigureTile` | | figure files | ☐ |
| `FilesPanel`, `QuickLookPreview` | | files | ☐ |

### Settings — `Views/SettingsView.swift`, `Updater.swift`
| SwiftUI | Web | serve | Status |
|---|---|---|---|
| `SettingsPage` (pane list, Back to app) | | `config.get/set` | ☐ |
| `GeneralSettings` (language, appearance, accent, show thinking, live monitoring, literature, identity, updates, CLI, about) | | | ☐ |
| `ProvidersSettings`, `ProvidersOverview`, `ProviderDetail`, `AddProviderSheet` | | providers, keys, test, models | ☐ |
| `ModelsSettings` (role assignment, alternates, vision helper) | | | ☐ |
| `SearchSettings` | | | ☐ |
| `ResearchSettings` | | | ☐ |
| `MemorySettings` | | memory stores | ☐ |
| `ScheduleSettings` | | schedules | ☐ |
| `UpdateSettings` | | updater | ☐ |

### Theme and brand — `Theme.swift`, `DotMatrix.swift`, `Brand.swift`
`BoxStyle`, `FrameStroke`, `LabelTab`, `CropMarks`, `DotGrid`, `BlinkingCursor`, `HardShadow`,
`AppearPop`, `ThreadRule`, `CodeBlockStyle`, `SectionLabel`, `IconBadge`, `Keycap`, `Chip`,
`QuietIconButtonStyle`, `HoverRowStyle`, `ActionButtonStyle`, `EqualWidthButtons`, `SpecField`,
`ActionRow`; `DotMatrixText`, `DotActivity`, `SieveField`, `DotProgress`; `BrandLogo`,
`GhostLoader`, `RoleGhostIcon`, `RoleGhostBadge` — each as a CSS/React primitive. ☐

### App-level behaviour
Menus and shortcuts, notifications (jobs, turn finished, permission) through Tauri, Quick Look
→ in-app preview, drag-and-drop attachments, math (`MathMarkdown.swift`, LaTeX via KaTeX),
quota text (`QuotaText.swift`), language switching at runtime. ☐

## Order of work

1. A4 i18n, A6 theme primitives and brand, A5 demo scenes → window frame, chat rows, composer, welcome and empty hero match.
2. A1 + A2 config and secrets in core → A3 serve v2 for workspaces, background tasks, task actions, settings → sidebar and settings panes.
3. Panels (trace, plan, claims, library, notebook, learning, changes, history, jobs, figures, files) and the inspector.
4. Brainstorm panel, effort slider, menus, notifications, updater, packaging (Windows installer with the CLI and its resources).
