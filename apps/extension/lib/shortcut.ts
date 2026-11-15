/** One-time hint for the toolbar-button keyboard shortcut (`commands._execute_action` in the manifest). */
import { ext } from "./chrome.ts";

const SEEN_KEY = "sroka.shortcutHint.v1";

/** The user's actual binding for the toolbar action (they may have changed or cleared it), or null when none. */
export async function actionShortcut(): Promise<string | null> {
  try {
    const cmds = await ext().commands.getAll();
    const s = cmds.find((c) => c.name === "_execute_action")?.shortcut?.trim();
    return s || null;
  } catch {
    return null;
  }
}

/** The binding to show in the saved state, or null: nothing bound, or the hint was already shown once. */
export async function shortcutHintToShow(): Promise<string | null> {
  try {
    const seen = (await ext().storage.local.get(SEEN_KEY))[SEEN_KEY];
    if (seen) return null;
  } catch {
    return null;
  }
  return actionShortcut();
}

export async function markShortcutHintSeen(): Promise<void> {
  try {
    await ext().storage.local.set({ [SEEN_KEY]: true });
  } catch {
    /* best effort */
  }
}
