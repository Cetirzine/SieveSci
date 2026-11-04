// Dot-matrix graphics, ported from Sources/SieveSciApp/DotMatrix.swift (same maths, same timings):
// text sampled into square dots that sift in and get a scan band, an activity lamp, the sieve
// field behind empty states, and a dot progress bar. Still under prefers-reduced-motion.
import { useEffect, useMemo, useRef } from "react";
import { reducedMotion, useThemeColor } from "./theme";

interface Bitmap { columns: number; rows: number; on: Uint8Array }
const bitmaps = new Map<string, Bitmap>();

/** Which cells a string covers when rendered `rows` cells tall (heavy system font, like NSFont .heavy). */
export function dotBitmap(text: string, rows: number): Bitmap {
  const key = `${text}|${rows}`;
  const hit = bitmaps.get(key);
  if (hit) return hit;
  const font = `900 ${rows * 0.92}px -apple-system, "SF Pro Display", "Segoe UI", system-ui, sans-serif`;
  const measure = document.createElement("canvas").getContext("2d")!;
  measure.font = font;
  const columns = Math.max(1, Math.ceil(measure.measureText(text).width));
  const c = document.createElement("canvas");
  c.width = columns;
  c.height = rows;
  const ctx = c.getContext("2d", { willReadFrequently: true })!;
  ctx.font = font;
  ctx.textBaseline = "middle";
  ctx.fillStyle = "#000";
  ctx.fillText(text, 0, rows / 2);
  const data = ctx.getImageData(0, 0, columns, rows).data;
  const on = new Uint8Array(columns * rows);
  for (let i = 0; i < columns * rows; i++) on[i] = data[i * 4 + 3] / 255 > 0.45 ? 1 : 0;
  const b = { columns, rows, on };
  bitmaps.set(key, b);
  return b;
}

function useCanvasLoop(draw: (ctx: CanvasRenderingContext2D, t: number, w: number, h: number) => void, deps: unknown[], fps = 60) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d")!;
    const start = performance.now();
    let frame = 0, last = 0;
    const tick = (now: number) => {
      if (now - last >= 1000 / fps - 1) {
        last = now;
        const dpr = window.devicePixelRatio || 1;
        const w = canvas.clientWidth, h = canvas.clientHeight;
        if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
          canvas.width = Math.round(w * dpr);
          canvas.height = Math.round(h * dpr);
        }
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, w, h);
        draw(ctx, reducedMotion() ? 99 : (now - start) / 1000, w, h);
      }
      if (!reducedMotion()) frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  return ref;
}

/** A string drawn in dots that sift in (top rows first), then a diagonal scan band every 5 s. */
export function DotMatrixText({ text, rows = 22, dot = 4, gap = 1.5, color = "--ink", accent = "--accent" }:
  { text: string; rows?: number; dot?: number; gap?: number; color?: string; accent?: string }) {
  const bm = useMemo(() => dotBitmap(text, rows), [text, rows]);
  const pitch = dot + gap;
  const ink = useThemeColor(color), acc = useThemeColor(accent);
  const ref = useCanvasLoop((ctx, t) => {
    for (let y = 0; y < bm.rows; y++) {
      for (let x = 0; x < bm.columns; x++) {
        if (!bm.on[y * bm.columns + x]) continue;
        const h = ((Math.imul(x, 73_856_093) ^ Math.imul(y, 19_349_663)) & 1023) / 1023;
        const land = 0.35 * h + 0.5 * y / bm.rows;
        const p = Math.min(1, Math.max(0, (t - land) / 0.35));
        if (p <= 0) continue;
        const eased = 1 - Math.pow(1 - p, 3);
        const fall = (1 - eased) * pitch * 3;
        const phase = ((t - 1.2) % 5) / 5;
        const band = t > 1.2 ? Math.max(0, 1 - Math.abs((x + Math.floor(y / 2)) / (bm.columns + bm.rows) - phase) * 14) : 0;
        ctx.globalAlpha = band > 0.05 ? 0.55 + 0.45 * band : eased;
        ctx.fillStyle = band > 0.05 ? acc : ink;
        ctx.fillRect(x * pitch, y * pitch - fall, dot, dot);
      }
    }
    ctx.globalAlpha = 1;
  }, [bm, pitch, dot, ink, acc]);
  return <canvas ref={ref} role="img" aria-label={text} style={{ width: bm.columns * pitch, height: bm.rows * pitch, display: "block" }} />;
}

/** A small grid that ripples from the centre while an agent works (20 fps). */
export function DotActivity({ size = 5, dot = 3, gap = 1.5, color = "--accent" }: { size?: number; dot?: number; gap?: number; color?: string }) {
  const pitch = dot + gap;
  const c = useThemeColor(color);
  const ref = useCanvasLoop((ctx) => {
    const t = performance.now() / 1000;
    const mid = (size - 1) / 2;
    ctx.fillStyle = c;
    for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
      const d = Math.hypot(x - mid, y - mid);
      const wave = reducedMotion() ? 0.5 : (Math.sin(d * 1.6 - t * 5) + 1) / 2;
      ctx.globalAlpha = 0.15 + 0.85 * wave * wave;
      ctx.fillRect(x * pitch, y * pitch, dot, dot);
    }
    ctx.globalAlpha = 1;
  }, [size, pitch, dot, c], 20);
  return <canvas ref={ref} aria-hidden style={{ width: size * pitch - gap, height: size * pitch - gap, display: "inline-block", flex: "none" }} />;
}

/** Dots that thin out downward, like grains through a sieve, flickering slowly (empty states). */
export function SieveField({ pitch = 12 }: { pitch?: number }) {
  const ink = useThemeColor("--ink");
  const ref = useCanvasLoop((ctx, _t, w, h) => {
    const t = reducedMotion() ? 0 : performance.now() / 1000;
    const cols = Math.floor(w / pitch) + 1, rows = Math.floor(h / pitch) + 1;
    ctx.fillStyle = ink;
    for (let y = 0; y < rows; y++) {
      const density = 1 - y / Math.max(rows, 1);
      for (let x = 0; x < cols; x++) {
        const hsh = ((Math.imul(x, 2_654_435_761 | 0) ^ Math.imul(y, 40_503)) & 4095) / 4095;
        if (hsh >= density * 0.85) continue;
        const flicker = (Math.sin(t * 0.8 + hsh * 12) + 1) / 2;
        ctx.globalAlpha = 0.10 + 0.22 * flicker * density;
        ctx.fillRect(x * pitch, y * pitch, 2, 2);
      }
    }
    ctx.globalAlpha = 1;
  }, [pitch, ink], 15);
  return <canvas ref={ref} aria-hidden className="sieve-field" />;
}

/** Progress as square dots filling from the left. */
export function DotProgress({ value, count = 20, dot = 3, gap = 1.5 }: { value: number; count?: number; dot?: number; gap?: number }) {
  const lit = Math.floor(Math.min(Math.max(value, 0), 1) * count);
  return (
    <span className="dot-progress" style={{ gap }} aria-valuenow={Math.round(value * 100)} role="progressbar">
      {Array.from({ length: count }, (_, i) => <i key={i} style={{ width: dot, height: dot, background: i < lit ? "var(--accent)" : "var(--rule)" }} />)}
    </span>
  );
}
