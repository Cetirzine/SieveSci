// Development only: lets the UI run in an ordinary browser. Each WebSocket connection gets its own
// `sievesci serve`; lines are relayed both ways unchanged. The desktop app does the same in Rust.
//
//   node dev-bridge.mjs [--port 8787] [-- serve options…]
//   e.g. DEEPSEEK_API_KEY=… node dev-bridge.mjs -- --provider deepseek --model deepseek-flash
//
// The browser picks the workspace: ws://127.0.0.1:8787/?workspace=/path/to/project
// SIEVESCI_BIN overrides the CLI path (default: ../.build/debug/sievesci).
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { WebSocketServer } from "ws";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const split = args.indexOf("--");
const own = split < 0 ? args : args.slice(0, split);
const serveArgs = split < 0 ? [] : args.slice(split + 1);
const port = Number(own[own.indexOf("--port") + 1] ?? 8787) || 8787;
const bin = process.env.SIEVESCI_BIN ?? path.join(here, "..", ".build", "debug", "sievesci");

const wss = new WebSocketServer({ host: "127.0.0.1", port });
wss.on("connection", (ws, req) => {
  const workspace = new URL(req.url ?? "/", "http://x").searchParams.get("workspace");
  if (!workspace) { ws.close(1008, "workspace query parameter is required"); return; }
  const child = spawn(bin, ["serve", "--workspace", workspace, ...serveArgs], { stdio: ["pipe", "pipe", "inherit"] });
  createInterface({ input: child.stdout }).on("line", (line) => { if (ws.readyState === ws.OPEN) ws.send(line); });
  ws.on("message", (data) => child.stdin.write(String(data).replace(/\n/g, " ") + "\n"));
  ws.on("close", () => { child.stdin.end(); setTimeout(() => child.kill(), 5000).unref(); });
  child.on("exit", (code) => { if (ws.readyState === ws.OPEN) ws.close(1011, `sievesci serve exited (${code})`); });
  console.log(`serve started for ${workspace}`);
});
console.log(`dev bridge on ws://127.0.0.1:${port}  (${bin} serve ${serveArgs.join(" ")})`);
