import { beforeEach, describe, expect, it, vi } from "vitest";
import { actionShortcut, markShortcutHintSeen, shortcutHintToShow } from "./shortcut.ts";
import { installChrome } from "./test-chrome.ts";

let chromeMock: ReturnType<typeof installChrome> & { commands?: { getAll: ReturnType<typeof vi.fn> } };
const withCommands = (all: Array<{ name: string; shortcut?: string }>) => {
  chromeMock.commands = { getAll: vi.fn(async () => all) };
};

beforeEach(() => {
  chromeMock = installChrome();
});

describe("shortcut hint", () => {
  it("returns the actual binding of _execute_action", async () => {
    withCommands([{ name: "other", shortcut: "Ctrl+Q" }, { name: "_execute_action", shortcut: "Alt+Shift+S" }]);
    expect(await actionShortcut()).toBe("Alt+Shift+S");
  });

  it("returns null when the shortcut is unbound or missing", async () => {
    withCommands([{ name: "_execute_action", shortcut: "" }]);
    expect(await actionShortcut()).toBeNull();
    withCommands([{ name: "other", shortcut: "Ctrl+Q" }]);
    expect(await actionShortcut()).toBeNull();
  });

  it("returns null when chrome.commands is unavailable or throws", async () => {
    expect(await actionShortcut()).toBeNull();
    chromeMock.commands = { getAll: vi.fn(async () => Promise.reject(new Error("nope"))) };
    expect(await actionShortcut()).toBeNull();
  });

  it("is shown until marked seen, then never again", async () => {
    withCommands([{ name: "_execute_action", shortcut: "⌥⇧S" }]);
    expect(await shortcutHintToShow()).toBe("⌥⇧S");
    await markShortcutHintSeen();
    expect(await shortcutHintToShow()).toBeNull();
  });
});
