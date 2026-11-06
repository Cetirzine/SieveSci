// System notifications (Notifier.swift / AppModel): a task that needs the user, a turn that finished
// while SieveSci was in the background, job events. Desktop: the Tauri notification plugin; browser:
// the Notification API. Each kind follows its setting (General → Live monitoring).
import { inTauri } from "../serve";

let allowed: boolean | null = null;

async function permitted(): Promise<boolean> {
  if (allowed !== null) return allowed;
  try {
    if (inTauri) {
      const n = await import("@tauri-apps/plugin-notification");
      allowed = (await n.isPermissionGranted()) || (await n.requestPermission()) === "granted";
    } else if (typeof Notification !== "undefined") {
      allowed = Notification.permission === "granted" || (await Notification.requestPermission()) === "granted";
    } else allowed = false;
  } catch { allowed = false; }
  return allowed;
}

/** Whether the window is out of sight or not in front (only then is a "finished" note worth sending). */
export const inBackground = () => typeof document !== "undefined" && (document.hidden || !document.hasFocus());

const recent = new Map<string, number>();

/** Posts a notification; the same `id` is not repeated within ten seconds. */
export async function notify(title: string, body: string, id: string) {
  // As the app's Notifier: only while SieveSci is not the active window.
  if (!inBackground()) return;
  const now = Date.now();
  if ((recent.get(id) ?? 0) > now - 10_000) return;
  recent.set(id, now);
  if (!(await permitted())) return;
  try {
    if (inTauri) (await import("@tauri-apps/plugin-notification")).sendNotification({ title, body });
    else new Notification(title, { body, tag: id });
  } catch { /* notifications unavailable */ }
}
