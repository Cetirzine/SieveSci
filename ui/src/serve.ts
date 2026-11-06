// The connection to `sievesci serve` (docs/SERVE_PROTOCOL.md): JSON-RPC 2.0, one message per line.
// In the desktop app the lines travel through Tauri; in a browser (development) through the
// WebSocket of dev-bridge.mjs. Everything above this file is the same in both.

export type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
export type JsonObject = { [k: string]: Json };

export interface Transport {
  send(line: string): void;
  onLine(cb: (line: string) => void): void;
  onClose(cb: (why: string) => void): void;
  /** Ends the connection and the serve process behind it. */
  close(): void;
}

declare global {
  interface Window { __TAURI_INTERNALS__?: unknown }
}

export const inTauri = typeof window !== "undefined" && window.__TAURI_INTERNALS__ !== undefined;

/** Desktop: the Rust side owns the serve process and relays its lines. */
export async function tauriTransport(workspace?: string): Promise<Transport> {
  const { invoke } = await import("@tauri-apps/api/core");
  const { listen } = await import("@tauri-apps/api/event");
  const lineCbs: ((l: string) => void)[] = [];
  const closeCbs: ((w: string) => void)[] = [];
  // Each start is a new generation; lines and exits of other generations (a replaced process) are ignored.
  let gen = -1;
  const unlistenLine = await listen<{ gen: number; line: string }>("serve-line", (e) => { if (e.payload.gen === gen) lineCbs.forEach((cb) => cb(e.payload.line)); });
  const unlistenExit = await listen<{ gen: number; reason: string }>("serve-exit", (e) => { if (e.payload.gen === gen) closeCbs.forEach((cb) => cb(e.payload.reason)); });
  gen = await invoke<number>("serve_start", { workspace: workspace ?? null });
  return {
    send: (line) => { void invoke("serve_send", { gen, line }); },
    onLine: (cb) => { lineCbs.push(cb); },
    onClose: (cb) => { closeCbs.push(cb); },
    close: () => { closeCbs.length = 0; unlistenLine(); unlistenExit(); void invoke("serve_stop", { gen }); },
  };
}

/** Browser: dev-bridge.mjs starts serve and relays its lines over a WebSocket. */
export function socketTransport(url: string): Promise<Transport> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const lineCbs: ((l: string) => void)[] = [];
    const closeCbs: ((w: string) => void)[] = [];
    ws.onmessage = (e) => lineCbs.forEach((cb) => cb(String(e.data)));
    ws.onclose = (e) => closeCbs.forEach((cb) => cb(e.reason || "connection closed"));
    ws.onerror = () => reject(new Error(`cannot reach the dev bridge at ${url}`));
    ws.onopen = () => resolve({
      send: (line) => ws.send(line),
      onLine: (cb) => { lineCbs.push(cb); },
      onClose: (cb) => { closeCbs.push(cb); },
      close: () => { closeCbs.length = 0; ws.close(1000, "closed by the UI"); },
    });
  });
}

export class RpcError extends Error {
  constructor(public code: number, message: string) { super(message); }
}

export class ServeClient {
  private nextId = 0;
  private pending = new Map<number, { resolve: (v: Json) => void; reject: (e: Error) => void }>();
  private eventCbs: ((e: JsonObject) => void)[] = [];
  private outputCbs: ((params: JsonObject) => void)[] = [];
  private noteCbs: ((method: string, params: JsonObject) => void)[] = [];

  constructor(private transport: Transport) {
    transport.onLine((line) => this.receive(line));
    transport.onClose((why) => {
      for (const p of this.pending.values()) p.reject(new Error(why));
      this.pending.clear();
    });
  }

  call<T = JsonObject>(method: string, params: JsonObject = {}): Promise<T> {
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve: (v) => resolve(v as T), reject });
      this.transport.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  onEvent(cb: (e: JsonObject) => void) { this.eventCbs.push(cb); }
  /** `output {task, workspace, text}`: the direct result of a slash command. */
  onOutput(cb: (params: JsonObject) => void) { this.outputCbs.push(cb); }
  /** Every other notification (`taskStatus`, and what later versions add). */
  onNotification(cb: (method: string, params: JsonObject) => void) { this.noteCbs.push(cb); }

  private receive(line: string) {
    let msg: JsonObject;
    try { msg = JSON.parse(line); } catch { return; }
    if (typeof msg.id === "number" && this.pending.has(msg.id)) {
      const p = this.pending.get(msg.id)!;
      this.pending.delete(msg.id);
      const err = msg.error as JsonObject | undefined;
      if (err) p.reject(new RpcError(Number(err.code), String(err.message)));
      else p.resolve(msg.result ?? null);
      return;
    }
    const params = (msg.params ?? {}) as JsonObject;
    if (msg.method === "event") this.eventCbs.forEach((cb) => cb(params));
    else if (msg.method === "output") this.outputCbs.forEach((cb) => cb(params));
    else if (typeof msg.method === "string") this.noteCbs.forEach((cb) => cb(String(msg.method), params));
  }
}
