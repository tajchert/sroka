import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import type { Item } from "@sroka/shared";
import { createMemoryRouter, RouterProvider } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mounts: string[] = [];
const unmounts: string[] = [];
const h = vi.hoisted(() => ({
  getItem: (() => new Promise(() => undefined)) as (id: string) => Promise<unknown>,
  listItems: (async () => ({ items: [], nextCursor: null })) as () => Promise<unknown>,
  setArchived: undefined as unknown as ReturnType<typeof import("vitest").vi.fn>,
}));

vi.mock("../lib/api.ts", async (orig) => {
  const m = await orig<typeof import("../lib/api.ts")>();
  return {
    ...m,
    api: {
      ...m.api,
      getItem: (id: string) => h.getItem(id),
      listItems: () => h.listItems(),
      getContent: async () => ({ articleUrl: "https://c.sroka.app/a/article.html", baseUrl: "https://c.sroka.app/a/" }),
      fetchArticle: async () => "<article><h1>T</h1><p>Body</p></article>",
      updateItem: (id: string) => h.getItem(id),
    },
  };
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
      return { setArchived: h.setArchived, toggleFavorite: vi.fn(), refresh: vi.fn() } as unknown as ReturnType<typeof m.useItemActions>;
    },
    useParsePolling: () => ({ gaveUp: false }),
  };
});
vi.mock("../lib/store.tsx", () => ({ useToasts: () => ({ push: () => undefined }), useHiddenIds: () => new Set<string>() }));
vi.mock("../lib/analytics.ts", () => ({ track: () => undefined }));

import Reader from "./Reader.tsx";

const item = (over: Partial<Item> = {}): Item =>
  ({
    id: "a",
    url: "https://example.com/a",
    canonicalUrl: "https://example.com/a",
    title: "Article A",
    siteName: null,
    fileName: null,
    leadImageUrl: null,
    readingMinutes: 7,
    contentId: "c-a",
    parseStatus: "ok",
    parseError: null,
    status: "unread",
    isFavorite: false,
    progress: 0,
    progressAnchor: null,
    tags: [],
    kind: "article",
    ...over,
  }) as Item;

function mount(path = "/item/a") {
  const router = createMemoryRouter(
    [
      { path: "/", element: <div>list</div> },
      { path: "/archive", element: <div>archive</div> },
      { path: "/item/:id", element: <Reader /> },
    ],
    { initialEntries: [path] },
  );
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { gcTime: Infinity } } })}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  );
  return router;
}

/** Frame stand-in: jsdom does not run the srcdoc script, so the tests speak its protocol directly. */
async function frame() {
  const iframe = (await waitFor(() => {
    const f = document.querySelector("iframe");
    if (!f) throw new Error("no iframe yet");
    return f;
  })) as HTMLIFrameElement;
  const win = iframe.contentWindow!;
  const posted: { type: string; card?: Record<string, unknown> | null }[] = [];
  vi.spyOn(win, "postMessage").mockImplementation((m: unknown) => void posted.push(m as never));
  const send = (data: unknown) => act(() => void window.dispatchEvent(new MessageEvent("message", { data, source: win })));
  const cards = () => posted.filter((m) => m.type === "sroka:endCard").map((m) => m.card);
  return { iframe, send, cards, ready: () => send({ type: "sroka:ready" }), progress: (p: number) => send({ type: "sroka:metrics", progress: p, anchor: 3 }) };
}

describe("Reader", () => {
  beforeEach(() => {
    h.getItem = () => new Promise(() => undefined);
    h.listItems = async () => ({ items: [], nextCursor: null });
    h.setArchived = vi.fn(async () => undefined);
  });
  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
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

  describe("finish line", () => {
    const NEXT = item({ id: "n1", title: "Next one", readingMinutes: 4, leadImageUrl: "https://c.sroka.app/n1/thumb.webp?sig=1" });
    const list = [
      item({ id: "a" }), // the current item is never its own next
      item({ id: "x1", parseStatus: "failed" }),
      item({ id: "x2", parseStatus: "pending" }),
      item({ id: "x3", status: "archived" }),
      NEXT,
      item({ id: "n2", title: "Later" }),
    ];

    it("shows nothing before the end, then Finished + Archive & next + Up next at 98%", async () => {
      h.getItem = async () => item();
      h.listItems = async () => ({ items: list, nextCursor: null });
      mount();
      const f = await frame();
      await f.ready();
      await f.progress(0.5);
      expect(f.cards().at(-1)).toBeNull();
      await f.progress(0.97);
      expect(f.cards().at(-1)).toBeNull();
      await f.progress(0.99);
      await waitFor(() => expect(f.cards().at(-1)).toMatchObject({ finished: "Finished", meta: "7 min", primary: "Archive & next", keep: "Keep" }));
      expect(f.cards().at(-1)!.next).toEqual({ id: "n1", title: "Next one", meta: "4 min", thumb: "https://c.sroka.app/n1/thumb.webp?sig=1" });
      // The card stays up if the reader scrolls back a little (latched for the visit).
      await f.progress(0.9);
      expect(f.cards().at(-1)).not.toBeNull();
    });

    it("Archive & next archives the item and opens the next item's reader", async () => {
      h.getItem = async () => item();
      h.listItems = async () => ({ items: list, nextCursor: null });
      const router = mount();
      const f = await frame();
      await f.ready();
      await f.progress(1);
      await waitFor(() => expect(f.cards().at(-1)).not.toBeNull());
      await f.send({ type: "sroka:endAction", action: "archive" });
      expect(h.setArchived).toHaveBeenCalledWith(expect.objectContaining({ id: "a" }), true);
      await waitFor(() => expect(router.state.location.pathname).toBe("/item/n1"));
    });

    it("Up next opens the next item without archiving", async () => {
      h.getItem = async () => item();
      h.listItems = async () => ({ items: list, nextCursor: null });
      const router = mount();
      const f = await frame();
      await f.ready();
      await f.progress(1);
      await waitFor(() => expect(f.cards().at(-1)).not.toBeNull());
      await f.send({ type: "sroka:endAction", action: "next" });
      await waitFor(() => expect(router.state.location.pathname).toBe("/item/n1"));
      expect(h.setArchived).not.toHaveBeenCalled();
    });

    it("Keep dismisses the card for this visit", async () => {
      h.getItem = async () => item();
      h.listItems = async () => ({ items: list, nextCursor: null });
      const router = mount();
      const f = await frame();
      await f.ready();
      await f.progress(1);
      await waitFor(() => expect(f.cards().at(-1)).not.toBeNull());
      await f.send({ type: "sroka:endAction", action: "keep" });
      await waitFor(() => expect(f.cards().at(-1)).toBeNull());
      await f.progress(1);
      expect(f.cards().at(-1)).toBeNull();
      expect(router.state.location.pathname).toBe("/item/a");
      expect(h.setArchived).not.toHaveBeenCalled();
    });

    it("with no next item the primary button is plain Archive and returns to My List", async () => {
      h.getItem = async () => item();
      h.listItems = async () => ({ items: [item({ id: "a" }), item({ id: "x", parseStatus: "failed" })], nextCursor: null });
      const router = mount();
      const f = await frame();
      await f.ready();
      await f.progress(1);
      await waitFor(() => expect(f.cards().at(-1)).toMatchObject({ primary: "Archive", next: null }));
      await f.send({ type: "sroka:endAction", action: "archive" });
      expect(h.setArchived).toHaveBeenCalledWith(expect.objectContaining({ id: "a" }), true);
      await waitFor(() => expect(router.state.location.pathname).toBe("/"));
    });

    it("an archived item shows only Finished and Up next", async () => {
      h.getItem = async () => item({ status: "archived" });
      h.listItems = async () => ({ items: list, nextCursor: null });
      mount("/item/a");
      const f = await frame();
      await f.ready();
      await f.progress(1);
      await waitFor(() => expect(f.cards().at(-1)).toMatchObject({ finished: "Finished", primary: null, keep: null }));
      expect(f.cards().at(-1)!.next).toMatchObject({ id: "n1" });
    });

    it("leaves out the thumbnail when it is not on the content origin the frame CSP allows", async () => {
      h.getItem = async () => item();
      h.listItems = async () => ({ items: [item({ id: "n1", title: "N", leadImageUrl: "https://elsewhere.example/t.webp" })], nextCursor: null });
      mount();
      const f = await frame();
      await f.ready();
      await f.progress(1);
      await waitFor(() => expect(f.cards().at(-1)).not.toBeNull());
      expect((f.cards().at(-1)!.next as { thumb: unknown }).thumb).toBeNull();
    });

    it("ignores end actions that do not come from the frame or are unknown", async () => {
      h.getItem = async () => item();
      h.listItems = async () => ({ items: list, nextCursor: null });
      mount();
      const f = await frame();
      await f.ready();
      await f.progress(1);
      await waitFor(() => expect(f.cards().at(-1)).not.toBeNull());
      await act(() => void window.dispatchEvent(new MessageEvent("message", { data: { type: "sroka:endAction", action: "archive" }, source: window })));
      await f.send({ type: "sroka:endAction", action: "delete" });
      expect(h.setArchived).not.toHaveBeenCalled();
    });

    it("skips the card for PDFs", async () => {
      h.getItem = async () => item({ kind: "pdf", fileName: "p.pdf" });
      mount();
      await waitFor(() => expect(screen.getAllByText("Article A").length).toBeGreaterThan(0));
      expect(document.querySelector("iframe")).toBeNull();
    });
  });

  describe("status wording", () => {
    it("pending: plain title", async () => {
      h.getItem = async () => item({ contentId: null, parseStatus: "pending" });
      mount();
      expect(await screen.findByRole("heading", { name: "Preparing article" })).toBeTruthy();
    });

    it("failed: title plus a plain reason, never the raw code", async () => {
      h.getItem = async () => item({ contentId: null, parseStatus: "failed", parseError: "http_503" });
      mount();
      expect(await screen.findByRole("heading", { name: "Couldn't save the text" })).toBeTruthy();
      expect(screen.getByText("The site didn't respond.")).toBeTruthy();
      expect(screen.queryByText(/http/i)).toBeNull();
    });

    it("failed with an unknown code: title only", async () => {
      h.getItem = async () => item({ contentId: null, parseStatus: "failed", parseError: "weird_internal_thing" });
      mount();
      await screen.findByRole("heading", { name: "Couldn't save the text" });
      expect(screen.queryByText(/weird/i)).toBeNull();
    });

    it("partial and paywalled banners are one short line", async () => {
      h.getItem = async () => item({ parseStatus: "partial" });
      mount();
      expect((await screen.findByRole("note")).textContent).toBe("Partial copyOpen original");
      cleanup();
      h.getItem = async () => item({ parseStatus: "partial", parseError: "paywalled" });
      mount();
      expect((await screen.findByRole("note")).textContent).toBe("Preview onlyOpen original");
    });
  });
});
