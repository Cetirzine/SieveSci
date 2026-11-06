// Design tokens and semantic helpers, ported from Sources/SieveSciApp/Theme.swift. Colours live in
// tokens.css as CSS variables (light/dark, five accent themes); this file holds the mappings.
import { useEffect, useState } from "react";
import { Activity, ArrowDownToLine, ArrowLeftRight, ArrowUp, Atom, AudioLines, BadgeCheck, Bell, Book, BookOpen, BookText, Brain, Calendar, CalendarClock, ChartLine, Check, ChevronDown, ChevronLeft, ChevronRight, ChevronUp, ChevronsUpDown, Circle, CircleAlert, CircleCheck, CircleMinus, CirclePause, CircleX, ClipboardList, Clock, CodeXml, Contrast, Copy, CopyPlus, Cpu, Database, Diff, Download, Ellipsis, Eye, File, FilePlus, FileSearch, FileText, Flag, FlaskConical, FoldVertical, Folder, FolderClosed, FolderPlus, GitBranch, Globe, Globe2, Hammer, Hand, History, Image, Images, KeyRound, LibraryBig, Lightbulb, Link, MessageCircleQuestion, MessageSquareWarning, Microscope, Minus, OctagonX, PanelLeft, PanelRight, Paperclip, Pencil, Plus, Puzzle, RotateCw, Search, Server, Settings, Shield, ShieldCheck, SlidersHorizontal, Sparkle, Square, SquarePen, SquareTerminal, Star, Table, TestTubes, Trash2, TriangleAlert, Undo2, Upload, User, Users, Wrench, X, Zap } from "lucide-react";
/** Only the icons used, so the bundle carries these and not the whole icon set. */
const I = { Activity, ArrowDownToLine, ArrowLeftRight, ArrowUp, Atom, AudioLines, BadgeCheck, Bell, Book, BookOpen, BookText, Brain, Calendar, CalendarClock, ChartLine, Check, ChevronDown, ChevronLeft, ChevronRight, ChevronUp, ChevronsUpDown, Circle, CircleAlert, CircleCheck, CircleMinus, CirclePause, CircleX, ClipboardList, Clock, CodeXml, Contrast, Copy, CopyPlus, Cpu, Database, Diff, Download, Ellipsis, Eye, File, FilePlus, FileSearch, FileText, Flag, FlaskConical, FoldVertical, Folder, FolderClosed, FolderPlus, GitBranch, Globe, Globe2, Hammer, Hand, History, Image, Images, KeyRound, LibraryBig, Lightbulb, Link, MessageCircleQuestion, MessageSquareWarning, Microscope, Minus, OctagonX, PanelLeft, PanelRight, Paperclip, Pencil, Plus, Puzzle, RotateCw, Search, Server, Settings, Shield, ShieldCheck, SlidersHorizontal, Sparkle, Square, SquarePen, SquareTerminal, Star, Table, TestTubes, Trash2, TriangleAlert, Undo2, Upload, User, Users, Wrench, X, Zap };
import type { LucideIcon } from "lucide-react";
import { L } from "../i18n";

export type AccentTheme = "blue" | "violet" | "green" | "orange" | "graphite";
export const accentThemes: AccentTheme[] = ["blue", "violet", "green", "orange", "graphite"];
export const accentName = (a: AccentTheme) => L(a[0].toUpperCase() + a.slice(1));

export function applyAppearance(appearance: "system" | "light" | "dark", accent: AccentTheme) {
  const root = document.documentElement;
  if (appearance === "system") delete root.dataset.theme; else root.dataset.theme = appearance;
  root.dataset.accent = accent;
  window.dispatchEvent(new Event("sievesci-theme"));
}

export function reducedMotion(): boolean {
  return typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;
}

/** The current value of a CSS colour variable, updated when the appearance or accent changes. */
export function useThemeColor(variable: string): string {
  const read = () => variable.startsWith("--") ? getComputedStyle(document.documentElement).getPropertyValue(variable).trim() || "#000" : variable;
  const [v, setV] = useState(read);
  useEffect(() => {
    const update = () => setV(read());
    const mq = matchMedia("(prefers-color-scheme: dark)");
    mq.addEventListener("change", update);
    window.addEventListener("sievesci-theme", update);
    update();
    return () => { mq.removeEventListener("change", update); window.removeEventListener("sievesci-theme", update); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [variable]);
  return v;
}

export function verdictTone(v: string): "ok" | "bad" | "warn" {
  if (["pass", "verified", "concede", "agree", "withdrawn"].includes(v)) return "ok";
  if (["block", "refuted", "contested"].includes(v)) return "bad";
  return "warn";
}

export function deliberationTone(kind: string): "ok" | "warn" | "accent" {
  if (kind === "concede" || kind === "agree") return "ok";
  if (kind === "disagree" || kind === "maintain") return "warn";
  return "accent";
}

export type Role = "main" | "checker" | "verifier" | "worker";
export const roleVar: Record<Role, string> = { main: "var(--accent)", checker: "var(--info)", verifier: "var(--verifier)", worker: "var(--worker)" };

export function roleName(r: string): string {
  switch (r) {
    case "main": return L("Research agent");
    case "checker": return L("Checker");
    case "verifier": return L("Blind verifier");
    case "worker": return L("Worker");
    default: return r;
  }
}

/** "checker-ab12cd" → "Checker ab12cd"; "main" → "Research agent". */
export function agentName(id: string): string {
  if (id === "main") return roleName("main");
  const [role, rest] = id.split(/-(.*)/s);
  if (!["checker", "verifier", "worker"].includes(role)) return id;
  return roleName(role) + (rest ? " " + rest : "");
}

const toolNames: Record<string, string> = {
  bash: "Terminal", python: "Python", read_file: "Read file", write_file: "Write file", edit_file: "Edit file",
  glob: "Find files", grep: "Search in files", web_search: "Web search", web_fetch: "Open web page",
  literature_search: "Literature search", paper_fetch: "Add paper", paper_read: "Read paper", paper_code_links: "Paper–code links",
  paper_graph: "Citation graph", library_search: "Search library", bio_db: "Database", chem_lookup: "Chemical lookup",
  bio_tool_search: "Biomni tools", repo_map: "Code map", update_plan: "Plan", claim_finding: "Register finding",
  todo_write: "To-do", goal: "Goal", task: "Worker agent", dispatch: "Batch agents", skill: "Skill", skill_env: "Skill environment",
  receipt: "Receipt", job_output: "Job output", job_watch: "Watch job", respond_review: "Reply to review",
  verify_citation: "Verify citation", memory: "Memory", session_search: "Search past sessions", skill_manage: "Manage skills",
  ask_user: "Question for you", brainstorm: "Brainstorm", idea: "Ideas", ideation_seeds: "Idea seeds",
};

export function toolTitle(n: string): string {
  if (toolNames[n]) return L(toolNames[n]);
  if (n.startsWith("mcp__")) return n.replace("mcp__", "").replace(/__/g, ":");
  return n.split("_").map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join("");
}

/** SF Symbols used by the SwiftUI app → the closest Lucide icon (SF Symbols are Apple-only). */
export const symbols: Record<string, LucideIcon> = {
  "terminal": I.SquareTerminal, "chevron.left.forwardslash.chevron.right": I.CodeXml, "doc.text.magnifyingglass": I.FileSearch,
  "pencil": I.Pencil, "globe": I.Globe, "books.vertical": I.LibraryBig, "cylinder.split.1x2": I.Database, "checkmark.seal": I.BadgeCheck,
  "list.bullet.clipboard": I.ClipboardList, "flag": I.Flag, "questionmark.bubble": I.MessageCircleQuestion, "lightbulb": I.Lightbulb,
  "person.3": I.Users, "arrow.left.arrow.right": I.ArrowLeftRight, "waveform": I.AudioLines, "atom": I.Atom, "allergens": I.Microscope,
  "brain": I.Brain, "puzzlepiece.extension": I.Puzzle, "wrench.and.screwdriver": I.Wrench,
  "sparkle": I.Sparkle, "eye": I.Eye, "checkmark.shield": I.ShieldCheck, "hammer": I.Hammer,
  "magnifyingglass": I.Search, "plus.square.on.square": I.CopyPlus, "book": I.BookOpen, "exclamationmark.triangle": I.TriangleAlert,
  "plus": I.Plus, "minus": I.Minus, "square.and.pencil": I.SquarePen, "folder": I.Folder, "folder.fill": I.FolderClosed,
  "folder.badge.plus": I.FolderPlus, "sidebar.left": I.PanelLeft, "sidebar.right": I.PanelRight, "gearshape": I.Settings,
  "square.and.arrow.down": I.Download, "square.and.arrow.up": I.Upload, "chevron.right": I.ChevronRight, "chevron.down": I.ChevronDown,
  "xmark": I.X, "checkmark": I.Check, "arrow.up": I.ArrowUp, "stop.fill": I.Square, "arrow.down.to.line": I.ArrowDownToLine, "shield": I.Shield, "checkmark.circle": I.CircleCheck,
  "exclamationmark.circle.fill": I.CircleAlert, "doc.on.doc": I.Copy, "arrow.triangle.branch": I.GitBranch, "clock": I.Clock,
  "chart.xyaxis.line": I.ChartLine, "flask": I.FlaskConical, "text.book.closed": I.BookText, "globe.americas": I.Globe2,
  "arrow.uturn.backward": I.Undo2, "photo": I.Image, "trash": I.Trash2, "paperclip": I.Paperclip, "bell": I.Bell,
  "waveform.path.ecg": I.Activity, "plusminus": I.Diff, "photo.on.rectangle": I.Images, "clock.arrow.circlepath": I.History, "book.closed": I.Book,
  "doc.badge.plus": I.FilePlus, "doc.text": I.FileText, "circle.lefthalf.filled": I.Contrast, "circle": I.Circle, "minus.circle": I.CircleMinus,
  "xmark.circle.fill": I.CircleX, "flag.fill": I.Flag, "xmark.octagon": I.OctagonX, "xmark.octagon.fill": I.OctagonX, "person": I.User,
  "rectangle.compress.vertical": I.FoldVertical, "doc.richtext": I.FileText, "tablecells": I.Table, "doc": I.File,
  "chevron.left": I.ChevronLeft, "slider.horizontal.3": I.SlidersHorizontal, "chevron.up": I.ChevronUp, "star": I.Star, "star.fill": I.Star, "calendar.badge.clock": I.CalendarClock, "xmark.circle": I.CircleX,
  "exclamationmark.triangle.fill": I.TriangleAlert, "link": I.Link, "key": I.KeyRound,
  "cpu": I.Cpu, "server.rack": I.Server, "testtube.2": I.TestTubes, "calendar": I.Calendar, "arrow.clockwise": I.RotateCw,
  "hand.raised": I.Hand, "bolt": I.Zap, "pause.circle": I.CirclePause, "exclamationmark.bubble.fill": I.MessageSquareWarning,
  "checkmark.circle.fill": I.CircleCheck, "chevron.up.chevron.down": I.ChevronsUpDown, "ellipsis": I.Ellipsis,
};

export function Symbol({ name, size = 13, strokeWidth = 1.75, className, style }: { name: string; size?: number; strokeWidth?: number; className?: string; style?: React.CSSProperties }) {
  const Icon = symbols[name] ?? I.Circle;
  return <Icon size={size} strokeWidth={strokeWidth} className={className} style={style} aria-hidden />;
}

export function toolIcon(n: string): string {
  switch (n) {
    case "bash": return "terminal";
    case "python": return "chevron.left.forwardslash.chevron.right";
    case "read_file": case "glob": case "grep": case "repo_map": return "doc.text.magnifyingglass";
    case "write_file": case "edit_file": return "pencil";
    case "web_search": case "web_fetch": return "globe";
    case "literature_search": case "paper_fetch": case "paper_read": case "library_search": case "paper_code_links": case "paper_graph": return "books.vertical";
    case "bio_db": return "cylinder.split.1x2";
    case "verify_citation": return "checkmark.seal";
    case "update_plan": case "todo_write": case "goal": return "list.bullet.clipboard";
    case "claim_finding": return "flag";
    case "ask_user": return "questionmark.bubble";
    case "brainstorm": case "idea": case "ideation_seeds": return "lightbulb";
    case "dispatch": case "task": return "person.3";
    case "respond_review": return "arrow.left.arrow.right";
    case "job_output": case "job_watch": return "waveform";
    case "chem_lookup": return "atom";
    case "bio_tool_search": return "allergens";
    case "memory": case "skill_manage": case "session_search": case "skill": case "skill_env": return "brain";
    default: return n.startsWith("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver";
  }
}

export const roleIcon: Record<Role, string> = { main: "sparkle", checker: "eye", verifier: "checkmark.shield", worker: "hammer" };

export function literatureIcon(a: string): string {
  return ({ searched: "magnifyingglass", added: "plus.square.on.square", read: "book", verified: "checkmark.seal", flagged: "exclamationmark.triangle" } as Record<string, string>)[a] ?? "book";
}
