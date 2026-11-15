import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render as rtlRender, screen, waitFor } from "@testing-library/react";
import type { ReactElement } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { resetExtensionDetection } from "../lib/extension.ts";
import { RESAVE_LABEL, ResaveButton } from "./ResaveButton.tsx";

let qc: QueryClient;
const render = (ui: ReactElement) => rtlRender(<QueryClientProvider client={qc}>{ui}</QueryClientProvider>);

const ITEM = { id: "0192f3c4-0000-7000-8000-000000000001", url: "https://news.example.com/story" };

function runtime(reply: (msg: { type: string }) => unknown) {
  const sendMessage = vi.fn((_id: string, msg: { type: string }, cb: (r: unknown) => void) => cb(reply(msg)));
  vi.stubGlobal("chrome", { runtime: { sendMessage } });
  return sendMessage;
}

beforeEach(() => {
  resetExtensionDetection();
  qc = new QueryClient();
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("ResaveButton", () => {
  it("renders nothing when the extension is not installed (banner looks as before)", async () => {
    vi.stubGlobal("chrome", undefined);
    const { container } = render(<ResaveButton item={ITEM} />);
    await new Promise((r) => setTimeout(r, 0));
    expect(container.innerHTML).toBe("");
  });

  it("with the extension: one click asks it to re-save, no window.open", async () => {
    const send = runtime((m) => (m.type === "sroka.ping" ? { ok: true, version: "1" } : { ok: true, opened: true, auto: false }));
    const open = vi.spyOn(window, "open").mockReturnValue(null);
    render(<ResaveButton item={ITEM} />);
    fireEvent.click(await screen.findByRole("button", { name: RESAVE_LABEL }));
    await waitFor(() => expect(send).toHaveBeenCalledWith(expect.any(String), { type: "sroka.resave", itemId: ITEM.id, url: ITEM.url }, expect.any(Function)));
    await screen.findByRole("button", { name: /Opened/ });
    expect(open).not.toHaveBeenCalled();
    // Coming back to the tab refetches the item so the re-parse shows up.
    const inv = vi.spyOn(qc, "invalidateQueries");
    window.dispatchEvent(new Event("focus"));
    expect(inv).toHaveBeenCalledWith({ queryKey: ["item", ITEM.id] });
  });

  it("falls back to opening the original when the extension refuses", async () => {
    runtime((m) => (m.type === "sroka.ping" ? { ok: true, version: "1" } : { ok: false, error: "signed_out" }));
    const open = vi.spyOn(window, "open").mockReturnValue(null);
    render(<ResaveButton item={ITEM} />);
    fireEvent.click(await screen.findByRole("button", { name: RESAVE_LABEL }));
    await waitFor(() => expect(open).toHaveBeenCalledWith(ITEM.url, "_blank", "noopener,noreferrer"));
  });
});
