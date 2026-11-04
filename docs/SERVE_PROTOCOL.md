# `sievesci serve` protocol (v1)

`sievesci serve` runs the SieveSci agent headless for a front end (the planned cross-platform UI,
editor plugins, scripts). The front end starts it as a child process and talks to it over
**stdin/stdout, one JSON-RPC 2.0 message per line** (UTF-8, `\n`-terminated). stdout carries only
protocol messages; diagnostics go to stderr.

```bash
sievesci serve --workspace ~/projects/crispr --provider deepseek --model deepseek-flash \
               [--checker P/M] [--worker P/M] [--mode ask|acceptEdits|auto|plan] [--search backend]
```

The options are the interactive CLI's. API keys come from environment variables (or, on macOS,
the keys the app saved in the Keychain).

One serve process works in one workspace and has at most one open task at a time.

## Requests (front end → serve)

Requests are handled concurrently, so responses can arrive in a different order than the requests; wait for a response before sending a request that depends on it (e.g. `task.send` after `task.open`). Every request gets exactly one response with the same `id`: `result` on success, `error`
(`code`, `message`) on failure. Codes: `-32700` unreadable line, `-32600` not a request,
`-32601` unknown method, `-32602` bad params, `-32000` the request cannot be done now (message says why).

| method | params | result |
|---|---|---|
| `initialize` | `{client?: string}` | `{name, version, protocol: 1, workspace, provider, model, mode}` |
| `tasks.list` | `{}` | `{tasks: [{id, title, modified}]}` newest first; `title` is null for an empty task |
| `task.open` | `{id?: string}` | Opens the task (new one without `id`) and returns its state: `{task, title, running, messages, plan, claims, ideas, asks}`. Refused while the open task is running. |
| `task.send` | `{text: string}` | `{accepted: true}` at once; the turn streams as `event` notifications and ends with `turnFinished` for agent `main`. Slash commands (`/goal`, `/trace r3`, …) work as in the CLI; their direct output arrives as an `output` notification. Text sent while a turn runs is queued. |
| `task.stop` | `{}` | `{}` Stops the running turn (and its tools and workers). |
| `permission.respond` | `{id, decision: "allow" \| "always" \| "deny", reason?}` | `{}` Answers a `permissionRequested` event. |
| `ask.respond` | `{id, outcome}` | `{}` Answers an `askRequested` event (outcome format below). |
| `brainstorm.wrapUp` | `{}` | `{}` Asks a running brainstorm to stop generating and report. |
| `shutdown` | `{}` | `{}` Stops work, closes the task, then serve exits. Closing stdin does the same. |

`messages` are the task's saved transcript (`Message` as stored in
`.sievesci/tasks/<id>/transcript-main.jsonl`): `{id, role: "user"|"assistant", blocks: [...]}`
with blocks `{type: "text", text}`, `{type: "thinking", thinking: {text}}`,
`{type: "toolUse", toolUse: {id, name, input}}`, `{type: "toolResult", toolResult: {toolUseId, content, isError, …}}`, `{type: "image", …}`.

Answers to an `askRequested` event: `outcome` is `{"kind": "answered", "answers": [{questionId, selected?: [label], other?: string, text?: string}]}`
or `{"kind": "dismissed", note?: string}`. The `askRequested` event carries the questions with their `id`,
`kind` (`single`, `multi`, `text`) and option `label`s; `askResolved` reports the outcome in the same form
(`kind` can also be `timedOut` or `unavailable`).

## Notifications (serve → front end)

No `id`; the front end does not answer them.

- `event` — everything the agent does, in order. `params` is `{type, …fields}` with `type` one of:
  `turnStarted {role, agentId}`, `textDelta {agentId, text}`, `thinkingDelta {agentId, text}`,
  `toolStarted {agentId, id, name, input}`, `toolProgress {agentId, id, lines}`,
  `toolFinished {agentId, id, name, output, isError, receipt}`, `assistantMessage {agentId, message}`,
  `usage {agentId, meter: {model, contextWindow, lastPromptTokens, lastOutputTokens, fill, cacheHitRate, session}}`,
  `permissionRequested {request: {id, tool, summary, input, effect, rememberPattern}}`,
  `integrity {signals}`, `supervisorStarted {kind, reason}`, `supervisorReview {kind, verdict, body}`,
  `planChanged {plan}`, `claimsChanged {claims}`, `notice {text}`, `error {text}`,
  `turnFinished {agentId, stop}`, `agentStarted {id, role, parent, purpose}`, `agentFinished {id, role, result}`,
  `literature {agentId, action, key, title, detail}`, `fileChanged {agentId, path, diff}`,
  `committed {hash, subject, files}`, `jobOutput {job, lines}`, `jobFinished {job, exitCode, seconds}`,
  `jobNotification {notification}`, `deliberation {thread, from, to, kind, text}`,
  `askRequested {request}`, `askResolved {id, outcome}`, `brainstormChanged {state}`, `ideasChanged {ideas}`.
  Text arrives as deltas: append `textDelta` for one `agentId` until a tool, a `thinkingDelta`
  or `turnFinished` for it. `agentId` `main` is the lead agent; others are checkers, verifiers, workers.
- `output {text}` — the direct result of a slash command.

Unknown event types and fields may be added in later versions; front ends ignore what they do not know.

## A session

```
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"client":"web"}}
← {"id":1,"jsonrpc":"2.0","result":{"model":"deepseek-flash","name":"sievesci","protocol":1,…}}
→ {"jsonrpc":"2.0","id":2,"method":"task.open","params":{}}
← {"id":2,"jsonrpc":"2.0","result":{"messages":[],"running":false,"task":"2026-11-04-1a2b3c",…}}
→ {"jsonrpc":"2.0","id":3,"method":"task.send","params":{"text":"Sum the primes below 100 in Python"}}
← {"id":3,"jsonrpc":"2.0","result":{"accepted":true}}
← {"jsonrpc":"2.0","method":"event","params":{"type":"turnStarted","role":"main","agentId":"main"}}
← {"jsonrpc":"2.0","method":"event","params":{"type":"toolStarted","agentId":"main","name":"python",…}}
← {"jsonrpc":"2.0","method":"event","params":{"type":"permissionRequested","request":{"id":"call_1",…}}}
→ {"jsonrpc":"2.0","id":4,"method":"permission.respond","params":{"id":"call_1","decision":"allow"}}
← {"id":4,"jsonrpc":"2.0","result":{}}
← … toolFinished, textDelta …, usage, turnFinished
```
