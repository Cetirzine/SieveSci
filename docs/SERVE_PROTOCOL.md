# `sievesci serve` protocol (v2)

`sievesci serve` runs the SieveSci agent headless for a front end (the cross-platform desktop UI in
`ui/`, editor plugins, scripts). The front end starts it as a child process and talks to it over
**stdin/stdout, one JSON-RPC 2.0 message per line** (UTF-8, `\n`-terminated). stdout carries only
protocol messages; diagnostics go to stderr.

```bash
sievesci serve                                   # the saved configuration, no workspace yet
sievesci serve --workspace ~/projects/crispr     # … with a workspace open
sievesci serve --workspace ~/projects/crispr --provider deepseek --model deepseek-flash \
               [--checker P/M] [--worker P/M] [--mode ask|acceptEdits|auto|plan] [--search backend]
```

Without `--provider`, serve does what the macOS app does: models, roles, search and every setting
come from the saved configuration (`config.json` in the app's configuration folder: Application
Support/SieveSci on macOS, `%APPDATA%\SieveSci` on Windows, `~/.config/sievesci` elsewhere;
`SIEVESCI_CONFIG_DIR` overrides it), and API keys from the platform's credential store (the
Keychain items the app writes, Windows Credential Manager, or `secrets.json` elsewhere).
Environment variables always win. A configuration folder set with `SIEVESCI_CONFIG_DIR` is a
profile of its own: its keys are kept in its `secrets.json`, not in the system store. With `--provider`, the command-line options pick the models, as
in the interactive CLI, and keys come from the environment only.

One serve process holds the configuration, any number of workspaces, and live tasks: the **open**
task (the one requests act on by default) plus tasks that keep running in the background after the
front end opened another one — a task that is still working or waiting for the user stays live
until it settles, exactly like the app's sidebar.

## Requests (front end → serve)

Requests are handled concurrently, so responses can arrive in a different order than the requests;
wait for a response before sending a request that depends on it (e.g. `task.send` after
`task.open`). Every request gets exactly one response with the same `id`: `result` on success,
`error` (`code`, `message`) on failure. Codes: `-32700` unreadable line, `-32600` not a request,
`-32601` unknown method, `-32602` bad params, `-32000` the request cannot be done now (message says why).

Requests about tasks take optional `workspace` (a path; default: the open workspace) and
`task` / `id` (default: the open task), so a front end can act on a background task directly.

### Session and configuration

| method | params | result |
|---|---|---|
| `initialize` | `{client?}` | `{name, version, protocol: 2, platform, sandbox, workspace, language, languageChoice, provider?, model?, mode?}` (`platform`: `macos`, `windows` or `linux`, for wording such as where keys are kept; `sandbox`: whether commands can run sandboxed here, Seatbelt on macOS only) (`provider`/`model`/`mode` only with `--provider`; `language` is the language in effect, e.g. `zh-Hans`, `languageChoice` the user's pick or `system`) |
| `language.set` | `{language: "system" \| "en" \| "zh-Hans" \| "zh-Hant" \| "ru" \| "es" \| "fr"}` | `{language, languageChoice}` The interface language, shared with the macOS app and the CLI; texts serve sends follow it. |
| `config.get` | `{}` | `{config, keys, usable, status}` — see below |
| `config.set` | `{patch: {field: value, …}}` | Same as `config.get`. Top-level fields of `config` are replaced, the result is saved and applied to live tasks (permission mode, effort, sandbox, auto titles, …). A value the configuration does not accept is refused with `invalid value for <field>`. |
| `secrets.set` | `{ref, value}` | Same as `config.get`. Stores an API key under a provider's `apiKeyRef` (or the search key's); an empty `value` removes it. Refused with `--provider` (keys come from the environment then). |
| `models.switchMain` | `{providerId, model}` | Same as `config.get`. Makes it the lead agent's model (as the app's model menu does: the shared model when all roles share one, else the main role's); reopen the task with `task.open {id, restart: true}` to use it. |
| `commands.list` | `{}` | `{commands: [{name, args, summary, group}]}` — the slash commands for the composer, including the open workspace's skills and custom commands. |

`config` is the app's whole configuration, with the built-in provider presets merged in as the app does (`providers`, `roles`, `webSearch`, `permissionMode`,
`effort`, `sandboxMode`, `appearance`, `autoTitles`, `autoBrainstorm`, `downloadOAPDFs`,
`recentWorkspaces`, …) as the app stores it. `permissionMode` is `ask`, `acceptEdits`, `auto` (no
approvals; commands always run sandboxed, even with `sandboxMode` off), `yolo` (no approvals and no
sandbox) or `plan`; the safety deny list applies in every mode. `keys` maps each key reference in it to whether a key
is present (`true`/`false`; key values never leave serve). `usable` lists the ids of providers that
can run now (enabled and with a key, or a CLI agent found on PATH). `status` is the welcome
checklist: `{models: {ready, text}, search: {ready, text}}`.

### Workspaces and tasks

| method | params | result |
|---|---|---|
| `workspace.open` | `{path}` | `{workspace, tasks}` Makes it the open workspace and adds it to `recentWorkspaces`. |
| `tasks.list` | `{workspace?}` | `{tasks: [{id, title, modified, running, stage}]}` newest first; `title` is null until the task has one; `stage` is null unless the task is live. |
| `task.open` | `{workspace?, id?, restart?}` | Opens the task (a new one without `id`) and makes it the open task; the previous one is closed unless it is still working or needs the user. `restart: true` stops a live task first and starts it again on the current configuration (after a model switch). Returns `{task, workspace, title, running, meter, history, plan, claims, ideas, brainstorm, asks, permission, stage, contested, grounding}` (`brainstorm`: the task's current or last brainstorm, or null; `meter`: the lead agent's model and context window; `permission`: the approval one of its agents waits for, or null, so a front end that switched away shows it again). Opening a task that is still being opened waits for that open instead of starting it twice. |
| `task.send` | `{text, attachments?, task?}` | `{accepted: true}` at once (`attachments`: absolute file paths, sent with the message); the turn streams as `event` notifications and ends with `turnFinished` for agent `main`. Slash commands (`/goal`, `/trace r3`, …) work as in the CLI; their direct output arrives as an `output` notification. Text sent while a turn runs is queued. |
| `task.insert` | `{task?, text, fromQueue?, index?}` | `{inserted}` Adds the text to the running turn: the agent reads it at its next step (DeepSeek Harness's steering). With no turn running it is sent as an ordinary message (`inserted: false`). `fromQueue` moves a queued message (matched by text; `index`, its place in the queue, picks among identical ones) into the turn instead; `false` then means it had already started as its own turn. Delivery is announced by `userInserted`. |
| `task.unqueue` | `{task?, text, index?}` | `{removed, queued}` Takes a queued message back without sending it. `index` picks among identical texts; the text must still match. Returns the queue as it is now. |
| `task.uninsert` | `{task?, text}` | `{removed}` Takes back an inserted message the agent has not read yet; `false` once it was delivered (a `userInserted` event says so). |
| `task.compact` | `{task?, focus?}` | `{ok, message}` Compacts the lead agent's context now, as `/compact [focus]` does; refused (`ok: false`) while a turn runs. A `usage` event brings the new size. |
| `task.stop` | `{task?}` | `{}` Stops the running turn (and its tools and workers), and denies the approval its agents wait for, so the turn ends. |
| `permission.respond` | `{id, decision: "allow" \| "always" \| "deny", reason?}` | `{}` Answers a `permissionRequested` event (of any live task). |
| `ask.respond` | `{id, outcome, task?}` | `{}` Answers an `askRequested` event (outcome format below). |
| `brainstorm.wrapUp` | `{task?}` | `{}` Asks a running brainstorm to stop generating and report. |
| `task.rename` | `{id, title, workspace?}` | `{task, title}` An empty title goes back to the generated or first-message title. |
| `task.delete` | `{id, workspace?}` | `{}` Closes the task if it is live and moves its folder to the Trash / Recycle Bin. |
| `task.fork` | `{id, workspace?}` | `{task}` A new task with a copy of the conversation. |
| `task.markdown` | `{id, workspace?, path?}` | `{markdown, dir}` The conversation as Markdown (for export or copying), also written to `path` when given; `dir` is the task's folder. |
| `shutdown` | `{}` | `{}` Stops all work, closes every task, then serve exits. Closing stdin does the same. |

`history` is the saved conversation as a front end shows it, oldest first: `{kind: "user", text}` (what the
user typed; context the host adds for the model is left out), `{kind: "assistant", text}`, and
`{kind: "tool", id, name, input, output?, isError?, receipt?}` (a tool call with its result).
`contested` lists open disagreements `{thread, kind, issue, reason}`; `grounding` is
`{web, literature}` — whether this task has searched the web / the literature yet.

Answers to an `askRequested` event: `outcome` is `{"kind": "answered", "answers": [{questionId, selected?: [label], other?: string, text?: string}]}`
or `{"kind": "dismissed", note?: string}`. The `askRequested` event carries the questions with their `id`,
`kind` (`single`, `multi`, `text`) and option `label`s; `askResolved` reports the outcome in the same form
(`kind` can also be `timedOut` or `unavailable`).

### Settings

What the Settings pages compute with the core. Methods that change the configuration answer like
`config.get`, plus the fields named.

| method | params | result |
|---|---|---|
| `providers.discover` | `{id}` | `config.get` + `{models: [{id, displayName, contextWindow, supportsImages, supportsReasoning}]}` The models the key (or signed-in CLI) can use; nothing is billed. A CLI agent's list replaces its models. Fails with the provider's message when the key is refused. |
| `providers.test` | `{id}` | `{status}` Two short identical requests: latency, then whether the prefix cache answers. |
| `providers.quota` | `{id}` | `{plan, note, summary, meters: [{title, value, usedFraction, exhausted, resetsAt}]}` Plan limits and balances, worded in the interface language. |
| `providers.quotas` | `{}` | `{quotas: {id: quota}}` For every usable provider. |
| `providers.catalog` | `{}` | `{presets, endpoints, modelsDev}`, each `[{id, title, detail}]` |
| `providers.add` | `{source: "preset" \| "endpoint" \| "modelsDev" \| "custom", id?, name?, baseURL?, family?}` | `config.get` + `{id}` (made unique) |
| `providers.detectOptions` | `{family, baseURL}` | `{options}` The cache and compatibility defaults for that endpoint. |
| `models.overview` | `{}` | `{roles: {role: {model, reasons}}, vision: [ModelRef], benchmarks: [{title, asOf, source}]}` The model each role gets now and why, models that accept images, the benchmark snapshot. |
| `models.refreshCatalogs` | `{}` | `{report}` Refreshes models.dev and the leaderboards. |
| `connectors.list` / `connectors.connect` | `{}` / `{id}` | `{connectors: [{id, title, license, notes, source, connected}]}` / `{message}` |
| `memory.list` | `{role}` | `{dir, learnedSkills, stores: {MEMORY, USER, LESSONS}: [entry], pendingProposals}` |
| `schedules.list` / `schedules.add` / `schedules.remove` | `{}` / `{when, prompt, workspace?}` / `{id}` | `{schedules}` (+ `{message}`) |
| `system.open` | `{path}` or `{url}` (http/https only) | `{}` Opens it with Finder / Explorer / the browser. |
| `cli.install` | `{}` | `{message}` Links this `sievesci` into ~/.local/bin (on Windows: says which folder to add to PATH). |
| `updates.check` | `{}` | `{current, latest, available, url}` The newest GitHub release. |

| `agents.install` | `{id}` | `config.get` + `{ok, message}` Installs a provider's CLI agent with its vendor's own installer (claude.ai, chatgpt.com, antigravity.google; Gemini CLI through Homebrew or npm); output streams as `agentInstall {id, lines}` notifications. |
| `agents.signIn` | `{id}` | `{message}` Opens a terminal on the agent's sign-in command. |

### Panels

The open task's research views (or the task named by `task`).

| method | params | result |
|---|---|---|
| `panels.trace` | `{offset}` | `{offset, events: [{id, at, actor, kind, text, isError, category}]}` What the audit log gained since `offset` (0 for all); pass the returned offset next time. |
| `panels.library` / `library.links` | `{}` | `{dir, papers}` / `{links: [{paperKey, file, line, locator}]}` (code citing a paper; walks the workspace) |
| `panels.notebook` | `{}` | `{path, text}` |
| `panels.learning` | `{}` | `{proposals}`; `learning.decide {id, approve}` and `learning.revert {id}` answer `{message, proposals}` |
| `panels.changes` | `{}` | `{files: [{path, added, removed, isNewFile}]}`; `changes.diff {path}` → `{diff}`; `changes.revert {path}` → `{ok, diff}` |
| `panels.history` | `{}` | `{commits: [{hash, subject, date, files}]}`; `history.diffs {hash}` → `{diffs}`; `history.restore {hash}` → `{ok}` (the current state is committed first) |
| `panels.jobs` | `{}` | `{jobs: [{id, label, running, exitCode, seconds, logPath, lines}]}`; `jobs.stop {id}` |
| `panels.figures` | `{}` | `{figures: [path]}` newest first |
| `files.list` | `{path?}` | `{entries: [{name, path, isDir}]}` one folder of the workspace |
| `files.read` | `{path}` | `{kind: "text" \| "image" \| "pdf" \| "binary", text?, dataURL?, size, truncated?}` |

Files are read inside the workspace only. `system.open` also takes `reveal: true` (show the file
in Finder / Explorer).

`config.get` (and every result shaped like it) also has `providers`: per provider id
`{ready, short, cliPath, hasKey, models: {model: {contextWindow, supportsImages, supportsReasoning}}}` —
whether it can run and what it needs, in the interface language; each model also carries `maxOutput`, `custom` (set by hand
in the profile's `modelSettings`) and `detected` (what the catalogs and the provider's listing say).

## Notifications (serve → front end)

No `id`; the front end does not answer them. Each carries `task` and `workspace`, so a front end
routes them to the open task or marks a background one in its sidebar.

- `event` — everything the agent does, in order. `params` is `{type, task, workspace, …fields}` with `type` one of:
  `turnStarted {role, agentId}`, `textDelta {agentId, text}`, `thinkingDelta {agentId, text}`,
  `toolStarted {agentId, id, name, input}`, `toolProgress {agentId, id, lines}`,
  `toolFinished {agentId, id, name, output, isError, receipt}`, `assistantMessage {agentId, message}`,
  `usage {agentId, meter: {model, contextWindow, lastPromptTokens, lastOutputTokens, fill, cacheHitRate, session}}`,
  `permissionRequested {request: {id, tool, summary, input, effect, rememberPattern}}` (sent when the request is put to
  the user: agents asking at once are asked one after another, each announced when its turn comes),
  `permissionResolved {id}` (answered without the prompt: Stop, a switch to a mode that allows the call, another window),
  `integrity {signals}`, `supervisorStarted {kind, reason}`, `supervisorReview {kind, verdict, body}`,
  `planChanged {plan}`, `claimsChanged {claims}`, `notice {text}`, `error {text}`,
  `turnFinished {agentId, stop}`, `agentStarted {id, role, parent, purpose}`, `agentFinished {id, role, result}`,
  `literature {agentId, action, key, title, detail}`, `fileChanged {agentId, path, diff}`,
  `committed {hash, subject, files}`, `jobOutput {job, lines}`, `jobFinished {job, exitCode, seconds}`,
  `jobNotification {notification}`, `deliberation {thread, from, to, kind, text}`,
  `askRequested {request}`, `askResolved {id, outcome}`, `brainstormChanged {state}`, `ideasChanged {ideas}`,
  `titleChanged {task, title}` (a generated conversation title),
  `userInserted {agent, text}` (an inserted message reached the agent — at its next step, or as the next turn
  when the turn it was meant for had ended).
  Text arrives as deltas: append `textDelta` for one `agentId` until a tool, a `thinkingDelta`
  or `turnFinished` for it. `agentId` `main` is the lead agent; others are checkers, verifiers, workers.
- `taskStatus {task, workspace, running, stage}` — a live task's stage changed (the sidebar chip
  and the "Needs you" list). `stage` is `{kind, label, detail, needsPerson, showsChip}` with `kind`
  one of `answer`, `review`, `blocked`, `working`, `waitingForJobs`, `idle`, or null once the task
  is closed.
- `output {task, workspace, text}` — the direct result of a slash command.

Unknown methods' results, event types and fields may be added in later versions; front ends ignore
what they do not know.

## A session

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"client":"web"}}
← {"id":1,"jsonrpc":"2.0","result":{"name":"sievesci","protocol":2,"workspace":null,…}}
→ {"jsonrpc":"2.0","id":2,"method":"config.get","params":{}}
← {"id":2,"jsonrpc":"2.0","result":{"config":{…},"keys":{"deepseek":true},"usable":["deepseek"],"status":{…}}}
→ {"jsonrpc":"2.0","id":3,"method":"workspace.open","params":{"path":"/Users/me/projects/crispr"}}
← {"id":3,"jsonrpc":"2.0","result":{"workspace":"/Users/me/projects/crispr","tasks":[…]}}
→ {"jsonrpc":"2.0","id":4,"method":"task.open","params":{}}
← {"id":4,"jsonrpc":"2.0","result":{"history":[],"running":false,"task":"2026-11-04-1a2b3c",…}}
→ {"jsonrpc":"2.0","id":5,"method":"task.send","params":{"text":"Sum the primes below 100 in Python"}}
← {"id":5,"jsonrpc":"2.0","result":{"accepted":true}}
← {"jsonrpc":"2.0","method":"event","params":{"type":"turnStarted","role":"main","agentId":"main","task":"2026-11-04-1a2b3c",…}}
← {"jsonrpc":"2.0","method":"taskStatus","params":{"task":"2026-11-04-1a2b3c","running":true,"stage":{"kind":"working",…},…}}
← {"jsonrpc":"2.0","method":"event","params":{"type":"permissionRequested","request":{"id":"call_1",…},…}}
→ {"jsonrpc":"2.0","id":6,"method":"permission.respond","params":{"id":"call_1","decision":"allow"}}
← {"id":6,"jsonrpc":"2.0","result":{}}
← … toolFinished, textDelta …, usage, turnFinished, taskStatus
```

## Changes from v1

- serve can start without a workspace and use the saved configuration and credential store;
  `config.*`, `secrets.set`, `commands.list`, `workspace.open` and the `task.rename/delete/fork/markdown`
  methods are new.
- Notifications carry `task` and `workspace`; `taskStatus` is new.
- Opening another task no longer requires the open one to be idle: a working task continues in the
  background.
