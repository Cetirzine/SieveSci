// Same keys and placeholders as the SwiftUI app (Sources/SieveSciCore/Util/L10n.swift):
// L("English text") → translation; L10n.s / L10n.f fill %@, %d, %1$@ … placeholders.
import en from "./en.json";
import es from "./es.json";
import fr from "./fr.json";
import ru from "./ru.json";
import zhHans from "./zh-Hans.json";
import zhHant from "./zh-Hant.json";

export type Language = "system" | "en" | "zh-Hans" | "zh-Hant" | "es" | "fr" | "ru";
const tables: Record<string, Record<string, string>> = { en, es, fr, ru, "zh-Hans": zhHans, "zh-Hant": zhHant };

/** Native names, shown in the picker regardless of the current language. */
export const languageNames: Record<Language, string> = {
  system: "System", en: "English", "zh-Hans": "简体中文", "zh-Hant": "繁體中文", es: "Español", fr: "Français", ru: "Русский",
};

let choice: Language = "system";
let resolved = resolve("system");

function resolve(l: Language): string {
  if (l !== "system") return l;
  for (const tag of typeof navigator === "undefined" ? [] : navigator.languages) {
    const t = tag.toLowerCase();
    if (t.startsWith("zh")) return /hant|tw|hk|mo/.test(t) ? "zh-Hant" : "zh-Hans";
    for (const code of ["es", "fr", "ru", "en"]) if (t.startsWith(code)) return code;
  }
  return "en";
}

export function setLanguage(l: Language) { choice = l; resolved = resolve(l); }
export function language(): Language { return choice; }
export function resolvedLanguage(): string { return resolved; }

export function L(key: string): string {
  if (resolved === "en") return key;
  return tables[resolved]?.[key] ?? key;
}

function substitute(format: string, args: (string | number)[]): string {
  let next = 0;
  return format.replace(/%(?:(\d+)\$)?(@|d|ld|s|%)/g, (_, pos: string | undefined, spec: string) => {
    if (spec === "%") return "%";
    const i = pos ? Number(pos) - 1 : next++;
    return i < args.length ? String(args[i]) : "";
  });
}

export const L10n = {
  /** Text arguments (`%@`, `%1$@`). */
  s: (key: string, ...args: string[]) => substitute(L(key), args),
  /** Number or text arguments (`%d`, `%@`). */
  f: (key: string, ...args: (string | number)[]) => substitute(L(key), args),
};
