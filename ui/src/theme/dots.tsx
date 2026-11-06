// Dot-matrix graphics, ported from Sources/SieveSciApp/DotMatrix.swift (same maths, same timings):
// text sampled into square dots that sift in and get a scan band, an activity lamp, the sieve
// field behind empty states, and a dot progress bar. Still under prefers-reduced-motion.
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
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

/** Redraws a canvas each frame for `playTime` seconds, then stops on its final frame. */
function useCanvasPlay(draw: (ctx: CanvasRenderingContext2D, t: number) => void, deps: unknown[], playTime: number) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d")!;
    const start = performance.now();
    let frame = 0;
    const tick = (now: number) => {
      const dpr = window.devicePixelRatio || 1;
      const w = canvas.clientWidth, h = canvas.clientHeight;
      if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) { canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr); }
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, h);
      const t = reducedMotion() ? 99 : (now - start) / 1000;
      draw(ctx, t);
      if (t < playTime) frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  return ref;
}

/** Landing (~1.2 s) plus one full sweep of the scan band (5 s); the wordmark stays still after. */
const PLAY_TIME = 6.2;

/** A string drawn in dots that sift in (top rows first), then one diagonal scan band, then still. */
export function DotMatrixText({ text, rows = 22, dot = 4, gap = 1.5, color = "--ink", accent = "--accent" }:
  { text: string; rows?: number; dot?: number; gap?: number; color?: string; accent?: string }) {
  const bm = useMemo(() => dotBitmap(text, rows), [text, rows]);
  const pitch = dot + gap;
  const ink = useThemeColor(color), acc = useThemeColor(accent);
  const ref = useCanvasPlay((ctx, t) => {
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
        const band = t > 1.2 && t < PLAY_TIME ? Math.max(0, 1 - Math.abs((x + Math.floor(y / 2)) / (bm.columns + bm.rows) - phase) * 14) : 0;
        ctx.globalAlpha = band > 0.05 ? 0.55 + 0.45 * band : eased;
        ctx.fillStyle = band > 0.05 ? acc : ink;
        ctx.fillRect(x * pitch, y * pitch - fall, dot, dot);
      }
    }
    ctx.globalAlpha = 1;
  }, [bm, pitch, dot, ink, acc], PLAY_TIME);
  return <canvas ref={ref} role="img" aria-label={text} style={{ width: bm.columns * pitch, height: bm.rows * pitch, display: "block" }} />;
}

/** A small grid that ripples from the centre while an agent works. Each dot plays its own sampled
 *  opacity curve as a CSS animation (as the Swift version uses Core Animation): no per-frame work. */
export function DotActivity({ size = 5, dot = 3, gap = 1.5, color = "var(--accent)" }: { size?: number; dot?: number; gap?: number; color?: string }) {
  const period = (2 * Math.PI) / 5;
  const mid = (size - 1) / 2;
  const dots = useMemo(() => Array.from({ length: size * size }, (_, i) => {
    const x = i % size, y = Math.floor(i / size);
    const d = Math.hypot(x - mid, y - mid);
    // sin(d·1.6 − t·5) is the centre wave shifted in time by d·1.6/5.
    return -((d * 1.6) / 5) % period;
  }), [size, mid, period]);
  return (
    <span className="dot-activity" aria-hidden style={{ gridTemplateColumns: `repeat(${size}, ${dot}px)`, gap, ["--period" as string]: `${period}s` }}>
      {dots.map((delay, i) => <i key={i} style={{ width: dot, height: dot, background: color, animationDelay: `${delay}s` }} />)}
    </span>
  );
}

/** The brainstorm's own indicator, unlike the model's centre ripple: a storm. Two spiral arms sweep
 *  round a calm eye, turning like a cyclone. Each dot plays one bright band of a CSS loop, delayed by
 *  its angle and twisted by its distance from the eye, so the arms rotate with no per-frame work. */
export function DotStorm({ size = 7, dot = 3, gap = 1.5, color = "var(--accent)", turn = 1.8 }: { size?: number; dot?: number; gap?: number; color?: string; turn?: number }) {
  const arms = 2, twist = 1.25;
  const period = turn / arms;
  const mid = (size - 1) / 2;
  const dots = useMemo(() => Array.from({ length: size * size }, (_, i) => {
    const x = i % size - mid, y = Math.floor(i / size) - mid;
    const r = Math.hypot(x, y);
    if (r < 0.5) return null;   // the eye stays calm
    // Counter-clockwise on screen; the band reaches a dot when the arm's angle passes it.
    const phase = (arms * Math.atan2(-y, x) - twist * r) / (2 * Math.PI);
    const frac = ((phase % 1) + 1) % 1;
    return { delay: -frac * period, edge: r / (mid * Math.SQRT2) };
  }), [size, mid, period]);
  return (
    <span className="dot-storm" aria-hidden style={{ gridTemplateColumns: `repeat(${size}, ${dot}px)`, gap, ["--period" as string]: `${period}s` }}>
      {dots.map((d, i) => d === null
        ? <i key={i} className="eye" style={{ width: dot, height: dot, background: color }} />
        // Outer dots are the storm's thin edge: smaller peaks, as grains fly off.
        : <i key={i} style={{ width: dot, height: dot, background: color, animationDelay: `${d.delay.toFixed(3)}s`, ["--peak" as string]: (1 - 0.35 * d.edge).toFixed(2) }} />)}
    </span>
  );
}

/** Dots that thin out downward, like grains through a sieve. Six phases of the field are drawn once
 *  and cross-faded by CSS (SieveField in LayerAnimations.swift), so an idle window does no work. */
export function SieveField({ pitch = 12, fadeMid = 0.25 }: { pitch?: number; fadeMid?: number }) {
  const ink = useThemeColor("--ink");
  const wrap = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  useLayoutEffect(() => {
    const el = wrap.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setSize({ w: Math.ceil(el.clientWidth), h: Math.ceil(el.clientHeight) }));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const speed = 0.8, period = (2 * Math.PI) / speed;
  const phases = reducedMotion() ? 1 : 6;
  const frames = useMemo(() => {
    if (!size.w || !size.h) return [] as string[];
    const cols = Math.floor(size.w / pitch) + 1, rows = Math.floor(size.h / pitch) + 1;
    return Array.from({ length: phases }, (_, k) => {
      const t = (period * k) / phases;
      const c = document.createElement("canvas");
      c.width = size.w; c.height = size.h;
      const ctx = c.getContext("2d")!;
      ctx.fillStyle = ink;
      for (let y = 0; y < rows; y++) {
        const density = 1 - y / Math.max(rows, 1);
        const fy = (y * pitch) / Math.max(size.h, 1);
        const fade = fy < 0.5 ? 1 - (1 - fadeMid) * fy * 2 : fadeMid * (1 - (fy - 0.5) * 2);
        for (let x = 0; x < cols; x++) {
          const hh = ((Math.imul(x, 2_654_435_761 | 0) ^ Math.imul(y, 40_503)) & 4095) / 4095;
          if (hh >= density * 0.85) continue;
          const flicker = (Math.sin(t * speed + hh * 12) + 1) / 2;
          ctx.globalAlpha = (0.10 + 0.22 * flicker * density) * Math.max(0, fade);
          ctx.fillRect(x * pitch, y * pitch, 2, 2);
        }
      }
      return c.toDataURL();
    });
  }, [size.w, size.h, pitch, fadeMid, ink, phases, period]);
  return (
    <div ref={wrap} className="sieve-field" aria-hidden style={{ ["--period" as string]: `${period}s`, ["--phases" as string]: phases }}>
      {frames.map((src, k) => <img key={k} src={src} alt="" style={{ animationDelay: `${(-period * k) / phases}s`, opacity: phases === 1 ? 1 : undefined }} />)}
    </div>
  );
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
