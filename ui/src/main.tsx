import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import { loadLanguage, type Language } from "./i18n";
import { loadMath } from "./views/markdown";
import "./theme/tokens.css";
import "./theme/primitives.css";
import "./theme/brand.css";
import "./views/frame.css";
import "./views/chat.css";

// Platform for title-bar layout: macOS draws under a transparent title bar, Windows keeps its own.
document.documentElement.dataset.platform = /Win/.test(navigator.platform) ? "windows" : /Linux/.test(navigator.platform) ? "linux" : "mac";

// The chosen language's table first, so the window never paints in the wrong language; formulas
// (KaTeX) load right after, off the first paint.
const stored = (() => { try { return localStorage.getItem("language"); } catch { return null; } })() as Language | null;
void loadLanguage(stored ?? "system").finally(() => {
  createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
  const idle = (window as unknown as { requestIdleCallback?: (f: () => void) => void }).requestIdleCallback ?? ((f: () => void) => setTimeout(f, 300));
  idle(() => void loadMath());
});
