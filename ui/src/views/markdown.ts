// Assistant prose: Markdown with LaTeX, ported from Theme.markdown (ChatView.swift) and
// MathMarkdown.swift. Same delimiters and the same test for "is this $…$ really a formula";
// code spans and fences are left alone. Model output is untrusted: raw HTML is shown as text and
// only http(s)/mailto links survive.
import { Marked } from "marked";
import { setState } from "../app/model";

type Katex = typeof import("katex").default;
let katex: Katex | null = null;
let loading: Promise<void> | null = null;

/** Loads KaTeX (script and styles) once; the views re-render their formulas when it arrives. */
export function loadMath(): Promise<void> {
  loading ??= Promise.all([import("katex"), import("katex/dist/katex.min.css")]).then(([k]) => {
    katex = k.default;
    cache.clear();
    setState((s) => ({ mathVersion: s.mathVersion + 1 }));
  });
  return loading;
}

const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

const md = new Marked({ gfm: true, breaks: false });
md.use({
  renderer: {
    html(token) { return escapeHtml(token.text); },
    link(token) {
      const href = token.href ?? "";
      const text = this.parser.parseInline(token.tokens);
      return /^(https?:|mailto:)/i.test(href) ? `<a href="${escapeHtml(href)}" target="_blank" rel="noreferrer">${text}</a>` : text;
    },
    image(token) {
      const m = /^sievemath(-block)?:(\d+)$/.exec(token.href ?? "");
      return m ? `\u0000MATH${m[2]}\u0000` : escapeHtml(`[${token.text}]`);
    },
  },
});

const display = /\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]/g;
const inline = /\\\(([\s\S]+?)\\\)|(?<![\\$\w])\$(?![\s$])([^$\n]+?)(?<!\s)\$(?![\d$])/g;
/** "$5 and $10" is money, not math: a formula has an operator, a command, or is a lone symbol. */
const looksLikeMath = (latex: string) => /[\\^_{}=<>+\-*/]|^[A-Za-z]$|^[A-Za-z]\w*$/.test(latex);

const cache = new Map<string, string>();

/** Markdown + math → HTML (memoised: streaming redraws often, the text rarely changes between draws). */
export function renderMarkdown(text: string): string {
  const hit = cache.get(text);
  if (hit !== undefined) return hit;
  let pendingMath = false;
  const formulas: { latex: string; display: boolean }[] = [];
  const replaceMath = (s: string) => s
    .replace(display, (_, a: string | undefined, b: string | undefined) => { formulas.push({ latex: (a ?? b ?? "").trim(), display: true }); return `\n\n![formula](sievemath-block:${formulas.length - 1})\n\n`; })
    .replace(inline, (whole, a: string | undefined, b: string | undefined) => {
      const latex = (a ?? b ?? "").trim();
      if (b !== undefined && !looksLikeMath(latex)) return whole;
      formulas.push({ latex, display: false });
      return `![formula](sievemath:${formulas.length - 1})`;
    });
  // Only outside code: fenced blocks and inline spans pass through untouched.
  let prepared = "";
  if (/[$\\]/.test(text)) {
    const parts = text.split(/(```[\s\S]*?(?:```|$)|`[^`\n]*`)/g);
    prepared = parts.map((p, i) => (i % 2 === 1 ? p : replaceMath(p))).join("");
  } else prepared = text;
  let html = md.parse(prepared) as string;
  html = html.replace(/\u0000MATH(\d+)\u0000/g, (_, n: string) => {
    const f = formulas[Number(n)];
    if (!katex) { pendingMath = true; return `<code>${escapeHtml(f.latex)}</code>`; }
    try { return katex.renderToString(f.latex, { displayMode: f.display, throwOnError: false, output: "html" }); }
    catch { return `<code>${escapeHtml(f.latex)}</code>`; }
  });
  // A display formula alone in its paragraph becomes a block.
  html = html.replace(/<p>(<span class="katex-display">[\s\S]*?<\/span>)<\/p>/g, "$1");
  // Formulas drawn as code until KaTeX is in: not cached, so the next draw shows them typeset.
  if (pendingMath) { void loadMath(); return html; }
  if (cache.size > 500) cache.clear();
  cache.set(text, html);
  return html;
}
