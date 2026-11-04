// Converts the app's Localizable.strings (Sources/SieveSciCore/Localization/<lang>.lproj) into
// src/i18n/<lang>.json, so the web UI uses the same keys and translations as the SwiftUI app.
// Runs before `vite` and `vite build`.
import { readFileSync, writeFileSync, readdirSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const src = path.join(here, "..", "..", "Sources", "SieveSciCore", "Localization");
const out = path.join(here, "..", "src", "i18n");
mkdirSync(out, { recursive: true });

const unescape = (s) => s.replace(/\\(["\\nt])/g, (_, c) => ({ n: "\n", t: "\t" }[c] ?? c));
const entry = /^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/gm;
for (const dir of readdirSync(src).filter((d) => d.endsWith(".lproj"))) {
  const lang = dir.replace(".lproj", "");
  const text = readFileSync(path.join(src, dir, "Localizable.strings"), "utf8");
  const table = {};
  for (const m of text.matchAll(entry)) table[unescape(m[1])] = unescape(m[2]);
  writeFileSync(path.join(out, `${lang}.json`), JSON.stringify(table));
  console.log(`i18n ${lang}: ${Object.keys(table).length} strings`);
}
