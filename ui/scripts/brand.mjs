// Extracts the brand artwork the SwiftUI app embeds as source (BrandSVG.swift, RoleGhostSVG.swift)
// into public/brand/<name>.svg, so both apps draw the very same files. Runs before vite.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const app = path.join(here, "..", "..", "Sources", "SieveSciApp");
const out = path.join(here, "..", "public", "brand");
mkdirSync(out, { recursive: true });
let n = 0;
for (const file of ["BrandSVG.swift", "RoleGhostSVG.swift"]) {
  const text = readFileSync(path.join(app, file), "utf8");
  for (const m of text.matchAll(/static let (\w+) = #"""\n([\s\S]*?)\n"""#/g)) {
    writeFileSync(path.join(out, `${m[1]}.svg`), m[2]);
    n++;
  }
}
console.log(`brand: ${n} SVG files`);
