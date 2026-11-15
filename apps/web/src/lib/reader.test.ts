import { describe, expect, it } from "vitest";
import {
  DEFAULT_READER_SETTINGS,
  buildSrcdoc,
  endCardModel,
  endCardThumb,
  isEndAction,
  loadReaderSettings,
  readerVars,
  resolveTheme,
  saveReaderSettings,
} from "./reader.ts";

const BASE = "https://c.sroka.app/s/1760486400/abc/p/0192/";
const input = (html: string) => ({ html, baseUrl: BASE, settings: DEFAULT_READER_SETTINGS, prefersDark: false, nonce: "NONCE123" });

describe("buildSrcdoc", () => {
  it("injects CSP, base, style and nonce'd script into an existing head", () => {
    const out = buildSrcdoc(input("<!doctype html><html><head><title>x</title></head><body><p>hi</p></body></html>"));
    expect(out).toContain(
      `content="default-src 'none'; img-src https://c.sroka.app data:; style-src 'unsafe-inline'; script-src 'nonce-NONCE123'"`,
    );
    expect(out).toContain(`<base href="${BASE}" target="_blank">`);
    expect(out).toContain(`<script nonce="NONCE123">`);
    expect(out.indexOf("Content-Security-Policy")).toBeLessThan(out.indexOf("<title>"));
    expect(out).toContain("<p>hi</p>");
  });

  it("wraps fragments in a full document", () => {
    const out = buildSrcdoc(input("<p>fragment</p>"));
    expect(out.startsWith("<!doctype html><html><head>")).toBe(true);
    expect(out).toContain("<body><p>fragment</p></body>");
  });

  it("adds a head when only <html> exists, and a doctype when missing", () => {
    const out = buildSrcdoc(input("<html lang=en><body>x</body></html>"));
    expect(out.startsWith("<!doctype html><html lang=en><head>")).toBe(true);
  });

  it("escapes the base href attribute", () => {
    const out = buildSrcdoc({ ...input("<p>x</p>"), baseUrl: 'https://c.sroka.app/a"b/' });
    expect(out).toContain('href="https://c.sroka.app/a&quot;b/"');
  });

  it("never grants same-origin and the script only posts messages", () => {
    const out = buildSrcdoc(input("<p>x</p>"));
    expect(out).toContain("sroka:metrics");
    expect(out).toContain("sroka:scrollToAnchor");
    expect(out).toContain("p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,figure");
    expect(out).toContain(".sr-post{"); // X / Twitter post cards
    expect(out).not.toContain("document.cookie");
  });

  it("generates a fresh nonce by default", () => {
    const a = buildSrcdoc({ ...input("<p>x</p>"), nonce: undefined });
    const b = buildSrcdoc({ ...input("<p>x</p>"), nonce: undefined });
    expect(a.match(/nonce="(\w+)"/)![1]).not.toBe(b.match(/nonce="(\w+)"/)![1]);
  });
});

describe("reader settings", () => {
  it("resolves system theme", () => {
    expect(resolveTheme("system", true)).toBe("dark");
    expect(resolveTheme("sepia", true)).toBe("sepia");
    expect(readerVars({ ...DEFAULT_READER_SETTINGS, theme: "dark" }, false)["--bg"]).toBe("#121314");
  });

  it("round-trips and clamps stored settings", () => {
    const store: Record<string, string> = {};
    const storage = { getItem: (k: string) => store[k] ?? null, setItem: (k: string, v: string) => void (store[k] = v) };
    saveReaderSettings({ ...DEFAULT_READER_SETTINGS, font: "mono", size: 99 }, storage);
    const s = loadReaderSettings(storage);
    expect(s.font).toBe("mono");
    expect(s.size).toBe(28);
    expect(loadReaderSettings({ getItem: () => "{bad" })).toEqual(DEFAULT_READER_SETTINGS);
  });
});

describe("end card (frame side)", () => {
  const script = () => buildSrcdoc(input("<p>x</p>"));

  it("keeps the CSP as strict as before and adds no inline handlers", () => {
    const out = script();
    expect(out).toContain(`default-src 'none'; img-src https://c.sroka.app data:; style-src 'unsafe-inline'; script-src 'nonce-NONCE123'`);
    expect(out.match(/<script/g)).toHaveLength(1);
    expect(out).not.toMatch(/\son(click|load|error)=/i);
    expect(out).toContain("sroka:endCard");
    expect(out).toContain("sroka:endAction");
    // Article-derived strings are written with textContent only; innerHTML is limited to the static icons.
    expect(out.match(/innerHTML/g)).toHaveLength(1);
  });

  it("tells the parent when the article fits without scrolling (load, resize, settings) and leaves progress alone", () => {
    const out = script();
    expect(out).toContain('post({type:"sroka:fits"})');
    expect(out).toContain('addEventListener("load",function(){if(!user)restore();fits()})');
    expect(out).toContain('addEventListener("resize",function(){if(!user)restore();fits()})');
    expect(out).toContain("requestAnimationFrame(fits)");
  });

  it("reserves the end block in the document so showing the card never changes the scroll height", () => {
    const out = script();
    expect(out).toContain("#sroka-end{box-sizing:border-box;min-height:19rem");
    expect(out).toContain(`end.id="sroka-end"`);
  });

  it("builds a model with the right primary label", () => {
    const next = { id: "n", title: "T", meta: "4 min", thumb: null };
    expect(endCardModel({ readingMinutes: 7, archived: false, next })).toMatchObject({ finished: "Finished", meta: "7 min", primary: "Archive & next", keep: "Keep", next });
    expect(endCardModel({ readingMinutes: null, archived: false, next: null })).toMatchObject({ meta: null, primary: "Archive", keep: "Keep", next: null });
    expect(endCardModel({ readingMinutes: 0, archived: true, next })).toMatchObject({ meta: null, primary: null, keep: null, next });
  });

  it("only offers thumbnails from the content origin", () => {
    expect(endCardThumb("https://c.sroka.app/n/thumb.webp?x=1", BASE)).toBe("https://c.sroka.app/n/thumb.webp?x=1");
    expect(endCardThumb("https://evil.example/t.webp", BASE)).toBeNull();
    expect(endCardThumb("not a url", BASE)).toBeNull();
    expect(endCardThumb(null, BASE)).toBeNull();
  });

  it("recognises only known end actions", () => {
    expect(["archive", "keep", "next"].every(isEndAction)).toBe(true);
    expect(isEndAction("delete")).toBe(false);
    expect(isEndAction(undefined)).toBe(false);
  });
});
