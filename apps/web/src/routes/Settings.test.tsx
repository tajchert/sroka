import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

const push = vi.fn();
const signOut = vi.fn();
vi.mock("../lib/store.tsx", () => ({ useToasts: () => ({ push }) }));
vi.mock("../lib/analytics.ts", () => ({ track: () => undefined }));
vi.mock("../lib/api.ts", async (orig) => {
  const m = await orig<typeof import("../lib/api.ts")>();
  return {
    ...m,
    api: {
      ...m.api,
      meOrNull: async () => ({ user: { email: "a@example.com" } }),
      signOut: (...a: unknown[]) => signOut(...a),
    },
  };
});

import Settings from "./Settings.tsx";

function setup() {
  const qc = new QueryClient();
  qc.setQueryData(["me"], { user: { email: "a@example.com" } });
  render(
    <QueryClientProvider client={qc}>
      <Settings />
    </QueryClientProvider>,
  );
  return qc;
}

describe("Settings sign-out", () => {
  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("keeps the signed-in state and shows an error when the sign-out request fails", async () => {
    signOut.mockRejectedValue(new Error("offline"));
    const qc = setup();
    fireEvent.click(screen.getByRole("button", { name: "Sign out" }));
    await waitFor(() => expect(push).toHaveBeenCalledWith(expect.objectContaining({ tone: "error" })));
    expect(qc.getQueryData(["me"])).not.toBeNull();
  });

  it("clears the client state once sign-out succeeds", async () => {
    signOut.mockResolvedValue(undefined);
    const qc = setup();
    fireEvent.click(screen.getByRole("button", { name: "Sign out" }));
    await waitFor(() => expect(qc.getQueryData(["me"])).toBeNull());
    expect(push).not.toHaveBeenCalled();
  });
});
