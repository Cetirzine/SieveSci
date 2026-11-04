import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./theme/tokens.css";
import "./theme/primitives.css";
import "./theme/brand.css";
import "./views/frame.css";

// Platform for title-bar layout: macOS draws under a transparent title bar, Windows keeps its own.
document.documentElement.dataset.platform = /Win/.test(navigator.platform) ? "windows" : /Linux/.test(navigator.platform) ? "linux" : "mac";

createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
