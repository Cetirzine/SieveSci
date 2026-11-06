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
| A1 ☑ | Move `AppConfig` (providers, roles, search, permissions, effort, sandbox, appearance, notifications, limits …) from `SieveSciApp` into `SieveSciCore`, same file format and location on macOS | both front ends read and write the same settings |
| A2 ☑ | Cross-platform secret store in core: macOS Keychain (as today), Windows Credential Manager, env vars | API keys entered in either UI |
| A3 ☑ | `serve` v2: workspaces and tasks as parameters (several open, background tasks keep running), settings get/set, provider test / model list / quota, panel data, task actions | everything the SwiftUI `AppModel` does through direct calls |
| A4 | i18n: `Localizable.strings` (en, zh-Hans, zh-Hant, es, fr, ru) → JSON at build time; `L()` / `L10n.f()` in TS with the same keys | same text in every language |
| A5 | Web demo scenes ported from `DemoContent.swift` / `DemoBrainstorm.swift` | screenshot comparison |
| A6 | Brand assets: dot-matrix text (sampled like `DotMatrix.swift`), role ghost SVGs (`RoleGhostSVG.swift`, `BrandSVG.swift`), SF Symbols → matching icon set | the specimen-sheet look |

## Screens and views

### Window frame — `SieveSciApp.swift`
| SwiftUI | Web | serve | Status |
|---|---|---|---|
| `RootView` (sidebar + main, collapsible sidebar) | `Shell` | — | ☑ |
| `AppMark` (logo + name), sidebar toggle | `AppMark` | — | ☑ |
| `SidebarView`: New task, `── WORKSPACE` + open-folder button, workspaces with −/+ disclosure and new-task button, task rows | `Sidebar` | `workspaces.list`, `tasks.list(workspace)` | ☑ |
| `TaskRow` (title, relative time, running ghost badge, stage chip, context menu: rename, copy id, copy/export Markdown, mention, fork, reveal, delete) | `TaskRow` | `task.rename/fork/delete/export` | ☑ |
| `StageChip`, `NeedsYouList` (tasks waiting on you, background) | | `tasks.status` events | ☑ |
| `UpdateBanner` | | Tauri updater | ☑ |
| `MainArea`, `TopBar` (title, `ModeMenu`, `JobsMenu`, `ResearchStatus` readout, export, inspector toggle), tab bar Chat/Trace/Plan/Claims/Library/Notebook | `TopBar` | mode set, jobs list | ☑ |
| `WelcomeView` (dot-matrix brand + version tab, crop marks, GET STARTED steps, Open Workspace, `LanguageMenu`, credit) | `Welcome` | setup status | ☑ |
| `SetupStep` | | | ☑ |

### Chat — `Views/ChatView.swift`
| SwiftUI | Web | serve | Status |
|---|---|---|---|
| `ChatView` (windowed rows, `EarlierRowsLabel`, search, scroll keeping) | `Transcript` | | ☑ |
| `EmptyChatHero` (dot-matrix SieveSci + NEW TASK, headline, three `StartCard`s, dot field) | | | ☑ |
| `SessionSetupCard` (no model yet) | | | ☑ |
| `TranscriptRow`: user, assistant (Markdown + math), thinking, tool, diff, agent card, review, deliberation, commit, literature, notice | rows | `fileChanged`, `committed`, `literature`, `deliberation` events | ☑ |
| `ThinkingRow`, `ToolRow` (icon per tool, title, summary, receipt, expand), `ToolOutputView` (images) | | figure files | ☑ |
| `DiffSummaryRow`, `DiffView`, `DiffLineView` | | | ☑ |
| `AgentCardView` (role ghost, live steps, time) | | subagent events | ☑ |
| `VerdictChip`, `ReviewBody` | | | ☑ |
| `PlanApprovalBar`, `ContestedBanner` | | plan approve | ☑ |
| `Spinner` ("Pipetting…" verb, dot activity, tokens, esc to interrupt, jobs) | `Working` | | ☑ |
| `PermissionPrompt` (TERMINAL label, numbered options, feedback field) | `PermissionCard` | deny with message | ☑ |
| `AskPrompt` (tabs per question, marks, recommended, evidence, Other field, three buttons) — `Views/AskPrompt.swift` | `AskCard` | | ☑ |
| `BrainstormPanel`, `StageTrack`, `IdeaSieve`, `DotCells`, `DotStack`, `IdeaRow` — `Views/BrainstormPanel.swift` | | `brainstorm.*` | ☑ |

### Composer — `Views/PromptInput.swift`, `Views/EffortSlider.swift`
| SwiftUI | Web | serve | Status |
|---|---|---|---|
| `PromptInput` (hard-shadow box, attachments +, slash-command and @file completion, queue while running, Esc to stop) | `Composer` | completions, attachments | ☑ |
| `SandboxMenu`, `ModelMenu` (per role), `EffortMiniGauge` / `EffortMenu` | | sandbox/model/effort set | ☑ |
| `StatsLine` (turns, steps, cache, in/out, jobs), `ContextRing`, `UsagePopover` (quota, spend) | | quota | ☑ |
| `EffortSlider`, `GlitchFrame`, `GlitchLabel` (settings) | | | ☑ |

### Panels — `Views/Panels.swift`, `Views/InspectorView.swift`, `ActivityModel.swift`
| SwiftUI | Web | serve | Status |
|---|---|---|---|
| `InspectorView` + `InspectorTabButton` (side inspector) | | | ☑ |
| `ActivityPanel` / `TraceRow` (Trace: paged audit events, filters) | | `panel.trace` | ☑ |
| `PlanPanel` | | plan | ☑ |
| `ClaimsPanel` | | claims | ☑ |
| `LibraryPanel` | | `panel.library` | ☑ |
| `NotebookPanel` | | `panel.notebook` | ☑ |
| `LearningPanel` | | memory, lessons | ☑ |
| `ChangesPanel`, `HistoryPanel` (shadow git) | | `panel.changes/history` | ☑ |
| `JobsPanel` | | jobs | ☑ |
| `FiguresPanel`, `FigureTile` | | figure files | ☑ |
| `FilesPanel`, `QuickLookPreview` | `FilesPanel` (text, image and PDF previews) | `files.list/read` | ◐ previews cover text, images and PDFs; other formats open in their app |

### Settings — `Views/SettingsView.swift`, `Updater.swift`
| SwiftUI | Web | serve | Status |
|---|---|---|---|
| `SettingsPage` (pane list, Back to app) | `Settings.tsx` `SettingsPage` | `config.get/set` | ☑ |
| `GeneralSettings` (language, appearance, accent, show thinking, live monitoring, literature, identity, updates, CLI, about) | `GeneralSettings` | `language.set`, `cli.install`, `system.open` | ☑ |
| `ProvidersSettings`, `ProvidersOverview`, `ProviderDetail`, `AddProviderSheet` | same names | `secrets.set`, `providers.*` | ☑ key texts still name the macOS Keychain on Windows |
| `ModelsSettings` (role assignment, alternates, vision helper) | `ModelsSettings` | `models.overview`, `models.refreshCatalogs` | ☑ |
| `SearchSettings` | `SearchSettings` | `secrets.set` | ☑ |
| `ResearchSettings` | `ResearchSettings` | `connectors.*` | ☑ |
| `MemorySettings` | `MemorySettings` | `memory.list` | ☑ |
| `ScheduleSettings` | `ScheduleSettings` | `schedules.*` | ☑ (Windows scheduling is the core's crontab hint) |
| `UpdateSettings` | `UpdateRow` | `updates.check` | ☑ |

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

## Audit against the SwiftUI app (2026-11-06)

Every interface string the SwiftUI app uses (564) was checked against the web UI, every SwiftUI
view type and every `AppModel` action matched to its web counterpart, then each difference read by
hand. Fixed:

| SwiftUI | Was in the web UI | Now |
|---|---|---|
| `PlanApprovalBar` "Approve and run" (`approvePlan`) | sent `/approve`, which the core does not know | accept-edits mode and "The plan is approved. Proceed with it."; ⌘↩ / Ctrl+Enter |
| User message "Edit and resend", "Rewind to here" (`rewind(to:edit:)`) | buttons without an action | `/rewind n`, transcript cut there; edit puts the message back in the composer |
| Transcript row context menu | none | Copy, Rewind, Edit and resend, Quote in reply, Fork task from here, Copy input / output, Show provenance, Copy conversation ID, Export Markdown |
| Queued message pills (`bench.queuedPrompts`) | never cleared | serve sends `queued` with the main agent's `turnStarted` / `turnFinished` |
| Usage popover "Plans & balances" | missing | plan, meters with resets, tracked spend (`providers.quota(s)` → `spend`), Refresh; balances refreshed after each turn |
| `/doctor` (`Doctor`) | "handled by the app window", never handled | `Doctor` moved to the core; serve `system.doctor` |
| Dream notice when a workspace's task opens | missing | `task.open` → `dreams`; notification and notice once per workspace per run |
| "Still working on this task" on returning to a running task | missing | notice when `task.open` reports `running` |
| Integrity signal titles (`signalTitle`) | raw kind (`harking`) | translated titles |
| Status line "%ds · ↑ … tokens · esc to interrupt" | a key with no translation | the app's key |
| Ask card ⌘↩ submit, Esc "Let's just talk" | missing | added (Esc only when not typing) |
| Check for Updates… answer, restart warning while a task runs | silent; restart without asking | up-to-date / failed dialogs; "Restart to update now?" when a task runs |
| Several prompts at once (questions, approvals) | only the first ever shown | queued and shown in turn (see SERVE_PROTOCOL, `permissionResolved`) |

Differences kept on purpose: the Tauri updater replaces `Updater.swift`'s DMG download, so its
messages differ; Quick Look is the in-app preview (images, PDF, text); provider status and CLI
setup texts come from serve (`providers` info, `agents.install`) and are platform-worded; the
SwiftUI app's CLI help ("Install it in Terminal…") is the one-click installer.

## Order of work

1. A4 i18n, A6 theme primitives and brand, A5 demo scenes → window frame, chat rows, composer, welcome and empty hero match.
2. A1 + A2 config and secrets in core → A3 serve v2 for workspaces, background tasks, task actions, settings → sidebar and settings panes.
3. Panels (trace, plan, claims, library, notebook, learning, changes, history, jobs, figures, files) and the inspector.
4. Brainstorm panel, effort slider, menus, notifications, updater, packaging (Windows installer with the CLI and its resources).
