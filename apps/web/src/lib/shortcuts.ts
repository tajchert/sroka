/** Keyboard shortcuts as listed in the reader's shortcuts sheet. Keep in step with `useListKeyboard` (hooks.ts), the `/` handler (Shell.tsx) and the reader's key handler (Reader.tsx). */
export type Shortcut = { keys: string; label: string };

export const READER_SHORTCUTS: Shortcut[] = [
  { keys: "a", label: "Archive" },
  { keys: "f", label: "Favorite" },
  { keys: "t", label: "Tags" },
  { keys: "o", label: "Open original" },
  { keys: "?", label: "Shortcuts" },
  { keys: "Esc", label: "Back" },
];

export const LIST_SHORTCUTS: Shortcut[] = [
  { keys: "j", label: "Next" },
  { keys: "k", label: "Previous" },
  { keys: "Enter", label: "Open" },
  { keys: "a", label: "Archive" },
  { keys: "f", label: "Favorite" },
  { keys: "/", label: "Search" },
];
