import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

const h = vi.hoisted(() => ({ signedIn: false, me: { id: "u1", email: "a@b.c" } as unknown }));

vi.mock("../lib/api.ts", async (orig) => {
  const m = await orig<typeof import("../lib/api.ts")>();
  return {
    ...m,
    api: {
      ...m.api,
      config: async () => ({ turnstileSiteKey: null }),
      sendOtp: async () => undefined,
      verifyOtp: async () => {
        h.signedIn = true;
      },
      meOrNull: async () => (h.signedIn ? h.me : null),
    },
  };
});
vi.mock("../lib/analytics.ts", () => ({ track: () => undefined }));

import { api } from "../lib/api.ts";
import SignIn from "./SignIn.tsx";

/** Stand-in for Shell: shows the sign-in screen until `me` resolves to a user. */
function Gate() {
  const me = useQuery({ queryKey: ["me"], queryFn: api.meOrNull, retry: false, staleTime: 60_000 });
  if (me.isPending) return <p>loading</p>;
  return me.data ? <p>library</p> : <SignIn />;
}

describe("SignIn", () => {
  afterEach(() => {
    cleanup();
    h.signedIn = false;
  });

  it("leaves the sign-in screen once the code is accepted, without a reload", async () => {
    render(
      <QueryClientProvider client={new QueryClient()}>
        <Gate />
      </QueryClientProvider>,
    );
    const email = await screen.findByPlaceholderText("you@example.com");
    fireEvent.change(email, { target: { value: "a@b.c" } });
    fireEvent.submit(email.closest("form")!);
    const code = await screen.findByLabelText("Code sent to a@b.c");
    fireEvent.change(code, { target: { value: "123 456" } });
    await waitFor(() => expect(screen.getByText("library")).toBeTruthy());
  });
});
