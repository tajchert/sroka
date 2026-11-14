import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, cleanup, render, waitFor } from "@testing-library/react";
import { createMemoryRouter, RouterProvider } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";

const mounts: string[] = [];
const unmounts: string[] = [];

vi.mock("../lib/api.ts", async (orig) => {
  const m = await orig<typeof import("../lib/api.ts")>();
  return { ...m, api: { ...m.api, getItem: () => new Promise(() => undefined) } };
});
vi.mock("../lib/hooks.ts", async (orig) => {
  const m = await orig<typeof import("../lib/hooks.ts")>();
  const React = await import("react");
  return {
    ...m,
    useItemActions: () => {
      React.useEffect(() => {
        mounts.push("m");
        return () => void unmounts.push("u");
      }, []);
      return {} as ReturnType<typeof m.useItemActions>;
    },
    useParsePolling: () => ({ gaveUp: false }),
  };
});
vi.mock("../lib/store.tsx", () => ({ useToasts: () => ({ push: () => undefined }) }));
vi.mock("../lib/analytics.ts", () => ({ track: () => undefined }));

import Reader from "./Reader.tsx";

describe("Reader", () => {
  afterEach(() => {
    cleanup();
    mounts.length = 0;
    unmounts.length = 0;
  });

  it("remounts when the article id changes, so scroll/progress refs start fresh", async () => {
    const router = createMemoryRouter([{ path: "/item/:id", element: <Reader /> }], { initialEntries: ["/item/a"] });
    render(
      <QueryClientProvider client={new QueryClient()}>
        <RouterProvider router={router} />
      </QueryClientProvider>,
    );
    await waitFor(() => expect(mounts).toHaveLength(1));
    await act(() => router.navigate("/item/b"));
    await waitFor(() => expect(mounts).toHaveLength(2));
    expect(unmounts).toHaveLength(1);
  });
});
