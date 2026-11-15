import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

const meOrNull = vi.fn();
vi.mock("../lib/api.ts", async (orig) => {
  const m = await orig<typeof import("../lib/api.ts")>();
  return { ...m, api: { ...m.api, meOrNull: () => meOrNull() } };
});

import { Onboarding } from "./Onboarding.tsx";

const me = (clients?: { extension: boolean; android: boolean }) => ({ user: { email: "a@example.com" }, stats: { unread: 0, archived: 0, favorites: 0, tags: 0 }, clients });
const setup = () => {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={qc}>
      <Onboarding />
    </QueryClientProvider>,
  );
};

describe("Onboarding", () => {
  afterEach(() => {
    cleanup();
    meOrNull.mockReset();
  });

  it("shows three actions and a QR code when nothing is connected (missing clients = all false)", async () => {
    meOrNull.mockResolvedValue(me());
    setup();
    expect(screen.getByText("Save from anywhere")).toBeTruthy();
    expect(screen.getByRole("link", { name: "Add to Chrome" }).getAttribute("href")).toBe("https://sroka.app/#get");
    expect(screen.getByRole("button", { name: "Save a link" })).toBeTruthy();
    expect(screen.getByTestId("qr")).toBeTruthy();
    await waitFor(() => expect(screen.getByTestId("qr").querySelector("path")).toBeTruthy());
    expect(screen.queryByRole("img", { name: /connected/ })).toBeNull();
  });

  it("ticks the browser card when the extension has been used", async () => {
    meOrNull.mockResolvedValue(me({ extension: true, android: false }));
    setup();
    await screen.findByRole("img", { name: "Browser extension connected" });
    expect(screen.queryByRole("link", { name: "Add to Chrome" })).toBeNull();
    expect(screen.getByTestId("qr")).toBeTruthy();
  });

  it("ticks the phone card and hides the QR when the Android app has been used", async () => {
    meOrNull.mockResolvedValue(me({ extension: false, android: true }));
    setup();
    await screen.findByRole("img", { name: "Android app connected" });
    expect(screen.queryByTestId("qr")).toBeNull();
    expect(screen.getByRole("link", { name: "Add to Chrome" })).toBeTruthy();
  });
});
