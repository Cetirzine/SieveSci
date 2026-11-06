// Reasoning effort as a stepped dot-matrix gauge (EffortSlider.swift): three rows of square dots in a
// 1 px frame, lit up to a square thumb that drags, snaps and springs between stops. The lit dots run
// from green to the accent with a band of light flowing through them, faster the higher the effort; at
// the top stop the gauge turns hot (amber to red) and glitches like a failing signal. Still under
// Reduce Motion. `null` is the model's default.
//
// Cost: the composer's mini gauge and the glitching "max" label are always on screen, so (as the Swift
// version plays Core Animation flip books) each is drawn once into a strip of frames that CSS steps
// through — no per-frame script. Only the full slider draws live, and only while it is visible.
import { useEffect, useMemo, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent } from "react";
import { L } from "../i18n";
import { reducedMotion, useThemeColor } from "./theme";
import "./effort.css";

export const effortStops = [null, "low", "medium", "high", "xhigh", "max"] as const;
export type Effort = (typeof effortStops)[number];
export const effortName = (e: Effort | string | null | undefined) => (e ? L(e) : L("Model default"));
const maxLevel = effortStops.length - 1;
const levelOf = (e: string | null | undefined) => Math.max(0, effortStops.indexOf((e ?? null) as Effort));

// MARK: Model (same numbers as Swift, so both draw the same frames)

export function hash(a: number, b: number): number {
  const v = (Math.imul(a, 73_856_093) ^ Math.imul(b, 19_349_663) ^ 0x5bd1e995) >>> 0;
  return (v % 1024) / 1023;
}

interface Tear { row: number; from: number; to: number; shift: number }
export interface Glitch {
  intensity: number; frame: number; tears: Tear[]; split: number;
  noise: { from: number; to: number; row: number; rows: number } | null; smearRow: number | null; thumbJitter: number; thumbLift: number;
}

const ROWS = 3;

/** One frame of the top stop's signal failure: calm stretches alternate with bursts re-rolled every frame. */
export function glitch(t: number): Glitch {
  const window = Math.floor(t * 5), frame = Math.floor(t * 30);
  const burst = hash(window, 11) > 0.5;
  const intensity = burst ? 0.45 + 0.55 * hash(frame, 3) : 0.12 * hash(frame, 3);
  const tears: Tear[] = [];
  if (burst) {
    for (let k = 0; k < 1 + Math.floor(hash(frame, 21) * 3); k++) {
      const from = hash(frame, 30 + k) * 0.8;
      tears.push({ row: Math.floor(hash(frame, 40 + k) * ROWS) % ROWS, from, to: Math.min(1, from + 0.12 + hash(frame, 50 + k) * 0.4),
        shift: (hash(frame, 60 + k) > 0.5 ? 1 : -1) * (1 + Math.floor(hash(frame, 70 + k) * 4)) });
    }
  }
  const noise = burst && hash(frame, 80) > 0.55
    ? (() => { const a = hash(frame, 81) * 0.85; return { from: a, to: a + 0.06 + hash(frame, 82) * 0.12, row: Math.floor(hash(frame, 83) * 3) % 3, rows: 1 + Math.floor(hash(frame, 84) * 2) }; })()
    : null;
  return { intensity, frame, tears, split: 0.8 + hash(frame, 4) * 2.4, noise,
    smearRow: burst && hash(frame, 90) > 0.6 ? Math.floor(hash(frame, 91) * 3) % 3 : null,
    thumbJitter: burst ? (hash(frame, 5) - 0.5) * 4 : 0, thumbLift: burst && hash(frame, 6) > 0.8 ? (hash(frame, 7) - 0.5) * 2 : 0 };
}

export interface GaugeColors { ok: string; accent: string; warn: string; bad: string; rule: string; ink: string; raised: string }

export function useGaugeColors(): GaugeColors {
  return { ok: useThemeColor("--ok"), accent: useThemeColor("--accent"), warn: useThemeColor("--warn"), bad: useThemeColor("--bad"),
    rule: useThemeColor("--rule"), ink: useThemeColor("--ink"), raised: useThemeColor("--raised") };
}

/** Lit-dot colour along the gauge: green to accent, or amber to red at the top stop. */
const rampColor = (c: GaugeColors, level: number, far: boolean) => (level === maxLevel ? (far ? c.bad : c.warn) : (far ? c.accent : c.ok));

/** Draws the dot rows; columns starting left of `litEdge` are lit (EffortSlider.drawGauge). */
export function drawGauge(ctx: CanvasRenderingContext2D, w: number, h: number, litEdge: number, level: number, t: number, g: Glitch | null, c: GaugeColors,
                          dot = 3, gap = 1.5, inset = 4, rows = ROWS) {
  const pitch = dot + gap;
  const cols = Math.max(1, Math.floor((w - inset * 2 + gap) / pitch));
  const top = (h - rows * pitch + gap) / 2;
  const litCols = Math.min(cols, Math.max(0, Math.floor((litEdge - inset) / pitch) + 1));
  const speed = 3.0 + level * 3.2;
  const scale = dot / 3;
  const fill = (x: number, y: number, ww: number, hh: number, color: string, alpha: number) => { ctx.globalAlpha = alpha; ctx.fillStyle = color; ctx.fillRect(x, y, ww, hh); };
  for (let col = 0; col < cols; col++) {
    const f = col / Math.max(cols - 1, 1);
    for (let r = 0; r < rows; r++) {
      let px = inset + col * pitch;
      const py = top + r * pitch;
      if (col >= litCols) { fill(px, py, dot, dot, c.rule, 0.7); continue; }
      let width = dot;
      let staticColor: string | null = null;
      if (g) {
        for (const tear of g.tears) if (tear.row % rows === r && f >= tear.from && f <= tear.to) px += tear.shift * pitch;
        if (hash(Math.imul(col, 31) + r, g.frame) > 1 - 0.14 * g.intensity) continue;   // lost dots
        if (g.noise && f >= g.noise.from && f <= g.noise.to && r >= g.noise.row % rows && r < (g.noise.row % rows) + g.noise.rows) {
          staticColor = hash(Math.imul(col, 13) + r, g.frame) > 0.5 ? c.ink : "#ffffff";
        }
        if (g.smearRow !== null && g.smearRow % rows === r && hash(col, g.frame + 5) > 0.55) width = dot + pitch * 2;
      }
      const wave = (Math.sin(col * 0.45 - t * speed) + 1) / 2;
      const sparkle = hash(Math.imul(col, 7) + r, Math.floor(t * 3) + col) > 0.965;
      const alpha = sparkle ? 1 : 0.45 + 0.55 * wave * wave;
      if (staticColor) { fill(px, py, width, dot, staticColor, 0.9); continue; }
      if (g) {
        const d = (0.5 + g.split * g.intensity) * scale;
        fill(px - d, py, width, dot, c.accent, 0.55 * alpha);
        fill(px + d, py + (g.intensity > 0.7 ? 0.5 : 0), width, dot, c.bad, 0.55 * alpha);
      }
      fill(px, py, width, dot, rampColor(c, level, false), alpha * (width > dot ? 0.6 : 1));
      fill(px, py, width, dot, rampColor(c, level, true), alpha * f);
      if (sparkle) fill(px, py, width, dot, "#ffffff", 0.6);
    }
  }
  ctx.globalAlpha = 1;
}

// MARK: Flip books

const sprites = new Map<string, string>();

/** Draws `count` frames side by side once (cached by key and colours) and returns the strip's image. */
function sprite(key: string, count: number, w: number, h: number, draw: (ctx: CanvasRenderingContext2D, i: number) => void): string {
  const hit = sprites.get(key);
  if (hit) return hit;
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  const canvas = document.createElement("canvas");
  canvas.width = Math.ceil(w * count * dpr); canvas.height = Math.ceil(h * dpr);
  const ctx = canvas.getContext("2d")!;
  ctx.scale(dpr, dpr);
  for (let i = 0; i < count; i++) {
    ctx.save(); ctx.translate(i * w, 0); ctx.beginPath(); ctx.rect(0, 0, w, h); ctx.clip();
    draw(ctx, i);
    ctx.restore();
  }
  const url = canvas.toDataURL("image/png");
  if (sprites.size > 40) sprites.clear();
  sprites.set(key, url);
  return url;
}

function FlipBook({ url, count, duration, w, h, className, style }: { url: string; count: number; duration: number; w: number; h: number; className?: string; style?: CSSProperties }) {
  return <span className={`flip-book ${className ?? ""}`} aria-hidden style={{ ...style, width: w, height: h, backgroundImage: `url(${url})`, backgroundSize: `${w * count}px ${h}px`,
    ["--flip-end" as string]: `-${w * count}px`, ["--flip-steps" as string]: count, ["--flip-duration" as string]: `${duration}s` }} />;
}

/** One loop of the flow: a whole number of band periods, about three seconds, at 30 fps. */
function gaugeLoop(level: number) {
  const period = (2 * Math.PI) / (3.0 + level * 3.2);
  const duration = Math.max(1, Math.round(3 / period)) * period;
  return { count: Math.max(1, Math.round(duration * 30)), duration };
}

/** The composer's effort readout: the slider's gauge in miniature (2 px dots). */
export function EffortMiniGauge({ effort }: { effort: string | null | undefined }) {
  const level = levelOf(effort);
  const hot = level === maxLevel;
  const c = useGaugeColors();
  const w = 44, h = 13;
  const still = reducedMotion();
  const { count, duration } = gaugeLoop(level);
  const edge = Math.max(2 + (w - 4) * level / maxLevel, 3);   // the default still lights a column
  const url = useMemo(() => sprite(`gauge|${level}|${still}|${Object.values(c).join()}`, still ? 1 : count, w, h,
    (ctx, i) => drawGauge(ctx, w, h, edge, level, still ? 0 : duration * i / count, hot && !still ? glitch(duration * i / count) : null, c, 2, 1, 2, 3)),
  // eslint-disable-next-line react-hooks/exhaustive-deps
  [level, still, c.ok, c.accent, c.warn, c.bad, c.rule, c.ink]);
  return <FlipBook url={url} count={still ? 1 : count} duration={duration} w={w} h={h} className={`mini-gauge ${hot ? "hot" : ""}`} />;
}

/** The "max" label of a glitching gauge: in bursts it flickers through corrupted spellings and splits
 *  into accent and red, like the dots. A flip book of four seconds that loops without a seam. */
export function GlitchLabel({ text, font = "500 10.5px var(--mono)" }: { text: string; font?: string }) {
  const c = useGaugeColors();
  const mono = useThemeColor("--mono");
  const still = reducedMotion();
  const margin = 6, loop = 4, fps = 30;
  const canvasFont = font.replace("var(--mono)", mono);
  const textW = useMemo(() => { const x = document.createElement("canvas").getContext("2d")!; x.font = canvasFont; return Math.ceil(x.measureText(text).width); }, [text, canvasFont]);
  const w = textW + margin * 2, h = 16;
  const count = Math.round(loop * fps);
  const url = useMemo(() => still ? "" : sprite(`glitch|${text}|${canvasFont}|${c.bad}|${c.accent}`, count, w, h, (ctx, i) => {
    const g = glitch(i / fps);
    const shown = g.intensity > 0.6 ? corrupt(text, g.frame) : text;
    const d = g.split * g.intensity * 0.6;
    const x = margin + (g.intensity > 0.85 ? g.thumbJitter * 0.5 : 0), y = 12;
    ctx.font = canvasFont;
    if (d > 0.4) {
      ctx.globalAlpha = 0.7; ctx.fillStyle = c.accent; ctx.fillText(shown, x - d, y);
      ctx.globalAlpha = 0.5; ctx.fillStyle = c.bad; ctx.fillText(shown, x + d, y + 0.5);
    }
    ctx.globalAlpha = 1; ctx.fillStyle = c.bad; ctx.fillText(shown, x, y);
  }), [text, canvasFont, still, c.bad, c.accent, w, count]);
  return (
    <span className="glitch-label" style={{ font }}>
      <span style={{ visibility: still ? "visible" : "hidden", color: "var(--bad)" }}>{text}</span>
      {!still && <FlipBook url={url} count={count} duration={loop} w={w} h={h} style={{ position: "absolute", left: -margin, top: "50%", marginTop: -h / 2 }} />}
    </span>
  );
}

/** Swaps a character or two for look-alikes and block glyphs; the length stays, so nothing reflows. */
function corrupt(s: string, frame: number): string {
  const swaps: Record<string, string[]> = { a: ["4", "@", "▚"], x: ["×", "%", "▞"], m: ["M", "r", "▙"], i: ["1", "!", "▌"], g: ["9", "6", "▟"], h: ["#", "H", "▜"] };
  return [...s].map((ch, i) => {
    const opts = swaps[ch.toLowerCase()];
    if (!(hash(i, Math.imul(frame, 3)) > 0.72) || !opts) return hash(i, frame) > 0.8 ? ch.toUpperCase() : ch;
    return opts[Math.floor(hash(i + 9, frame) * opts.length) % opts.length];
  }).join("");
}

// MARK: Slider

const THUMB = 18;

/** The full slider (Settings → Research, the composer's popover). Draws at up to 30 fps while visible. */
export function EffortSlider({ effort, onChange, compact = false, width }: { effort: string | null | undefined; onChange: (e: Effort) => void; compact?: boolean; width?: number }) {
  const index = levelOf(effort);
  const c = useGaugeColors();
  const area = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const thumb = useRef<HTMLSpanElement>(null);
  const [areaW, setAreaW] = useState(width ?? 320);
  const [dragX, setDragX] = useState<number | null>(null);
  const step = (areaW - THUMB) / maxLevel;
  const x = dragX ?? index * step;
  const level = Math.round(x / Math.max(step, 1));   // while dragging, the gauge shows the stop it will snap to
  const hot = level === maxLevel;
  const live = useRef({ x, level, c });
  live.current = { x, level, c };

  useEffect(() => {
    const el = area.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setAreaW(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // The gauge: one frame per 1/30 s while on screen and the window is visible; one frame under Reduce Motion.
  useEffect(() => {
    const cv = canvas.current;
    if (!cv) return;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const w = areaW - THUMB + 8, h = 16;
    cv.width = Math.ceil(w * dpr); cv.height = Math.ceil(h * dpr);
    const ctx = cv.getContext("2d")!;
    let raf = 0, last = 0, visible = true;
    const draw = (now: number) => {
      const { x: xx, level: lv, c: cc } = live.current;
      const t = reducedMotion() ? 0 : now / 1000;
      const g = lv === maxLevel && !reducedMotion() ? glitch(t) : null;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, h);
      drawGauge(ctx, w, h, xx + 4 + 1, lv, t, g, cc);
      const frame = cv.parentElement!;
      frame.classList.toggle("ghost", !!g && g.intensity > 0.55);
      frame.style.setProperty("--split", `${g ? g.split * g.intensity : 0}px`);
      if (thumb.current) {
        thumb.current.style.setProperty("--jitter", `${g?.thumbJitter ?? 0}px`);
        thumb.current.style.setProperty("--lift", `${g?.thumbLift ?? 0}px`);
        thumb.current.classList.toggle("split", !!g && g.split * g.intensity > 0.3);
      }
    };
    const loop = (now: number) => {
      raf = requestAnimationFrame(loop);
      if (!visible || document.hidden || now - last < 1000 / 30) return;
      last = now;
      draw(now);
    };
    draw(performance.now());
    if (!reducedMotion()) raf = requestAnimationFrame(loop);
    const io = new IntersectionObserver(([e]) => { visible = e.isIntersecting; });
    io.observe(cv);
    return () => { cancelAnimationFrame(raf); io.disconnect(); };
  }, [areaW]);

  const pick = (clientX: number) => {
    const r = area.current!.getBoundingClientRect();
    return Math.min(Math.max(0, clientX - r.left - THUMB / 2), maxLevel * step);
  };
  const down = (e: ReactPointerEvent) => { (e.target as Element).setPointerCapture?.(e.pointerId); setDragX(pick(e.clientX)); };
  const move = (e: ReactPointerEvent) => { if (dragX !== null) setDragX(pick(e.clientX)); };
  const up = (e: ReactPointerEvent) => {
    if (dragX === null) return;
    onChange(effortStops[Math.round(pick(e.clientX) / Math.max(step, 1))]);
    setDragX(null);
  };
  const key = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowRight" || e.key === "ArrowUp") { e.preventDefault(); onChange(effortStops[Math.min(index + 1, maxLevel)]); }
    if (e.key === "ArrowLeft" || e.key === "ArrowDown") { e.preventDefault(); onChange(effortStops[Math.max(index - 1, 0)]); }
  };
  const swatch = rampColor(c, level, true);

  return (
    <div className="effort-slider" style={width ? { width } : undefined} role="slider" tabIndex={0} aria-label={L("Reasoning effort")}
         aria-valuemin={0} aria-valuemax={maxLevel} aria-valuenow={index} aria-valuetext={effortName(effortStops[index])} onKeyDown={key}>
      <div ref={area} className="effort-track" onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={() => setDragX(null)}>
        <div className={`effort-frame ${hot ? "hot" : ""}`} style={{ left: THUMB / 2 - 4, right: THUMB / 2 - 4 }}>
          <canvas ref={canvas} style={{ width: areaW - THUMB + 8, height: 16 }} />
        </div>
        <span className={`effort-thumb-pos ${dragX !== null ? "" : "settle"}`} style={{ transform: `translateX(${x}px)` }}>
          <span ref={thumb} className={`effort-thumb ${hot ? "hot" : ""} ${dragX !== null ? "pressed" : ""}`}><i style={{ background: swatch }} /></span>
        </span>
      </div>
      {!compact && (
        <div className="effort-labels">
          {effortStops.map((s, i) => i === maxLevel && i === index
            ? <GlitchLabel key={i} text={L(s!)} />
            : <button key={i} type="button" tabIndex={-1} className={`t-label ${i === index ? "c-accent" : "secondary"}`} onClick={() => onChange(s)}>{i === 0 ? L("default") : L(s!)}</button>)}
        </div>
      )}
    </div>
  );
}
