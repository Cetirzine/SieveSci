// Shared building blocks, one per SwiftUI primitive in Sources/SieveSciApp/Theme.swift.
import { forwardRef, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type HTMLAttributes, type ReactNode, type ButtonHTMLAttributes, type InputHTMLAttributes } from "react";
import { Symbol } from "./theme";

/** BoxStyle: framed block; dashed when provisional, a leading colour rule, a label tab on the top edge. */
export function Box({ highlight, provisional, tab, tabTint, children, className = "", style }:
  { highlight?: string; provisional?: boolean; tab?: string; tabTint?: string; children: ReactNode; className?: string; style?: CSSProperties }) {
  return (
    <div className={`box ${provisional ? "provisional" : ""} ${tab ? "tabbed" : ""} ${highlight ? "highlighted" : ""} ${className}`}
         style={{ ...style, ...(highlight ? { ["--box-highlight" as string]: highlight } : {}) }}>
      {tab && <LabelTab text={tab} tint={tabTint} className="box-tab" />}
      {children}
    </div>
  );
}

/** LabelTab: inverted monospaced label on a frame's edge. */
export function LabelTab({ text, tint, className = "" }: { text: string; tint?: string; className?: string }) {
  return <span className={`label-tab ${className}`} style={tint ? { background: tint } : undefined}>{text}</span>;
}

/** CropMarks: L-shaped marks at the four corners, as on a print proof. */
export function CropMarks({ length = 10, inset = -14 }: { length?: number; inset?: number }) {
  const s = { ["--crop-len" as string]: `${length}px`, ["--crop-inset" as string]: `${inset}px` } as CSSProperties;
  return <span className="crop-marks" style={s} aria-hidden><i /><i /><i /><i /></span>;
}

/** DotGrid: a faint counting grid of 1 px dots. */
export function DotGrid({ spacing = 14 }: { spacing?: number }) {
  return <span className="dot-grid" style={{ backgroundSize: `${spacing}px ${spacing}px`, backgroundPosition: `${spacing / 2}px ${spacing / 2}px` }} aria-hidden />;
}

export function BlinkingCursor({ color }: { color?: string }) {
  return <span className="blink-cursor" style={color ? { background: color } : undefined} aria-hidden />;
}

/** SectionLabel: "── WORKSPACE". */
export function SectionLabel({ children }: { children: ReactNode }) {
  return <span className="section-label"><i />{children}</span>;
}

export function IconBadge({ symbol, tint = "var(--accent)", size = 22 }: { symbol: string; tint?: string; size?: number }) {
  return (
    <span className="icon-badge" style={{ width: size, height: size, color: tint, ["--badge-tint" as string]: tint }}>
      <Symbol name={symbol} size={size * 0.5} strokeWidth={2.2} />
    </span>
  );
}

export function Keycap({ k }: { k: string }) { return <span className="keycap">{k}</span>; }

/** Chip: small square monospaced tag (verdicts, stages, modes). */
export function Chip({ text, tint = "var(--secondary)", icon }: { text: string; tint?: string; icon?: string }) {
  return (
    <span className="chip" style={{ color: tint, ["--chip-tint" as string]: tint }}>
      {icon && <Symbol name={icon} size={9} strokeWidth={2.5} />}{text}
    </span>
  );
}

/** QuietIconButtonStyle: borderless 28 px icon button with a hover fill. */
export function IconButton({ symbol, label, className = "", ...rest }: { symbol: string; label: string } & ButtonHTMLAttributes<HTMLButtonElement>) {
  return <button type="button" className={`icon-button ${className}`} title={label} aria-label={label} {...rest}><Symbol name={symbol} size={13} /></button>;
}

/** ActionButtonStyle: one height, square, 1 px frame; primary is accent with ink frame and hard shadow. */
export function ActionButton({ kind = "secondary", width, fill, className = "", children, ...rest }:
  { kind?: "primary" | "secondary" | "destructive"; width?: "column" | number; fill?: boolean } & ButtonHTMLAttributes<HTMLButtonElement>) {
  const minWidth = width === "column" ? "var(--c-button-width)" : width;
  return (
    <button type="button" className={`action-button ${kind} ${fill ? "fill" : ""} ${className}`} style={{ minWidth, ...rest.style }} {...rest}>
      <span className="action-label">{children}</span>
    </button>
  );
}

/** EqualWidthButtons: buttons that belong together, all as wide as the widest (min 88). */
export function EqualWidthButtons({ children, minWidth = 88, gap = 8 }: { children: ReactNode; minWidth?: number; gap?: number }) {
  return <div className="equal-width" style={{ gap, gridAutoColumns: `minmax(${minWidth}px, 1fr)` }}>{children}</div>;
}

/** SpecField: framed input with an example prompt; with a title it is a settings row. */
export function SpecField({ title, mono, width, multiline, value, onChange, ...rest }:
  { title?: string; mono?: boolean; width?: number; multiline?: boolean; value: string; onChange: (v: string) => void } & Omit<InputHTMLAttributes<HTMLInputElement>, "onChange" | "value">) {
  const field = multiline
    ? <textarea className={`spec-field multiline ${mono ? "mono" : ""}`} rows={3} value={value} placeholder={rest.placeholder} onChange={(e) => onChange(e.target.value)} />
    : <input className={`spec-field ${mono ? "mono" : ""}`} value={value} onChange={(e) => onChange(e.target.value)} {...rest} />;
  if (!title) return <span style={{ width, display: "block" }}>{field}</span>;
  return (
    <div className="spec-row">
      <span>{title}</span>
      <span style={{ width: width ?? "var(--c-field-width)", flex: "none" }}>{field}</span>
    </div>
  );
}

/** ActionRow: title and a line of detail left, actions in the shared button column right. */
export function ActionRow({ title, detail, children }: { title: string; detail?: string; children?: ReactNode }) {
  return (
    <div className="action-row">
      <div className="action-row-text">
        <div>{title}</div>
        {detail && <div className="t-caption secondary">{detail}</div>}
      </div>
      <div className="action-row-trailing">{children}</div>
    </div>
  );
}

/** A borderless dropdown (SwiftUI Menu with .borderlessButton): label button, item list below. */
/** Keeps a popup inside the window. One anchored below or above its control opens toward the side with
 *  more room; any popup shifts sideways off the edges; one taller than the room it has scrolls. A fixed
 *  one (a right-click menu at the pointer) is moved back inside. */
export function fitInWindow(el: HTMLElement | null, margin = 8) {
  if (!el) return;
  const st = el.style, vw = window.innerWidth, vh = window.innerHeight;
  st.translate = ""; st.maxHeight = ""; st.overflowY = "";
  if (getComputedStyle(el).position === "fixed") {
    const r = el.getBoundingClientRect();
    st.left = `${Math.max(margin, Math.min(r.left, vw - margin - r.width))}px`;
    st.top = `${Math.max(margin, Math.min(r.top, vh - margin - r.height))}px`;
    if (r.height > vh - 2 * margin) { st.maxHeight = `${vh - 2 * margin}px`; st.overflowY = "auto"; }
    return;
  }
  st.top = ""; st.bottom = "";
  const anchor = el.parentElement?.getBoundingClientRect();
  let r = el.getBoundingClientRect();
  if (anchor) {
    const below = vh - margin - anchor.bottom, above = anchor.top - margin;
    const down = r.top >= anchor.top + anchor.height / 2;
    if (down && r.bottom > vh - margin && above > below) { st.top = "auto"; st.bottom = "calc(100% + 4px)"; }
    else if (!down && r.top < margin && below > above) { st.bottom = "auto"; st.top = "calc(100% + 4px)"; }
    r = el.getBoundingClientRect();
    const room = r.top >= anchor.top + anchor.height / 2 ? vh - margin - r.top : r.bottom - margin;
    if (r.height > room) { st.maxHeight = `${Math.max(80, room)}px`; st.overflowY = "auto"; r = el.getBoundingClientRect(); }
  }
  let dx = 0;
  if (r.right > vw - margin) dx = vw - margin - r.right;
  if (r.left + dx < margin) dx = margin - r.left;
  if (dx) st.translate = `${Math.round(dx)}px 0`;
}

/** A popup (menu, popover, right-click menu) fitted inside the window when it opens and when the window resizes. */
export const Popup = forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(function Popup(props, outer) {
  const ref = useRef<HTMLDivElement | null>(null);
  useLayoutEffect(() => {
    const fit = () => fitInWindow(ref.current);
    fit();
    window.addEventListener("resize", fit);
    return () => window.removeEventListener("resize", fit);
  }, []);
  return <div {...props} ref={(el) => { ref.current = el; if (typeof outer === "function") outer(el); else if (outer) outer.current = el; }} />;
});

export function Menu({ label, items, className = "", align = "left", title }:
  { label: ReactNode; items: { label: ReactNode; onSelect?: () => void; checked?: boolean; destructive?: boolean; divider?: boolean; section?: boolean }[]; className?: string; align?: "left" | "right"; title?: string }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", close);
    document.addEventListener("keydown", esc);
    return () => { document.removeEventListener("mousedown", close); document.removeEventListener("keydown", esc); };
  }, [open]);
  return (
    <span ref={ref} className={`menu ${className}`}>
      <button type="button" className="menu-label" onClick={() => setOpen(!open)} title={title} aria-haspopup="menu" aria-expanded={open}>{label}</button>
      {open && (
        <Popup className={`menu-list ${align}`} role="menu">
          {items.map((it, i) => it.divider ? <div key={i} className="menu-divider" />
            : it.section ? <div key={i} className="menu-section">{it.label}</div> : (
            <button key={i} type="button" role="menuitem" className={`menu-item ${it.destructive ? "c-bad" : ""}`} onClick={() => { setOpen(false); it.onSelect?.(); }}>
              <span className="menu-check">{it.checked ? "✓" : ""}</span>{it.label}
            </button>
          ))}
        </Popup>
      )}
    </span>
  );
}

/** Segmented choice, square: a framed light track, the chosen segment in the accent colour, hairlines between the
 *  others. With `label`, the label sits to its left; several `SegmentedRow`s inside a `SegmentedGroup`
 *  line their labels and tracks up in two columns. */
export function Segmented<T extends string>({ value, options, onChange, label, fill }:
  { value: T; options: { value: T; label: string }[]; onChange: (v: T) => void; label?: string; fill?: boolean }) {
  const track = (
    <div className={`seg ${fill ? "fill" : ""}`} role="tablist" aria-label={label}>
      {options.map((o) => (
        <button key={o.value} type="button" role="tab" aria-selected={o.value === value} className={o.value === value ? "on" : ""} onClick={() => onChange(o.value)}>{o.label}</button>
      ))}
    </div>
  );
  return label ? <div className="seg-row"><span className="seg-label">{label}</span>{track}</div> : track;
}

/** Aligns the labels and tracks of the Segmented rows inside it. */
export function SegmentedGroup({ children }: { children: ReactNode }) {
  return <div className="seg-group">{children}</div>;
}
