/** Reader: settings + sandboxed srcdoc builder (decisions D7, api.md section 5.7). Pure, no DOM required. */
import { PROGRESS_ANCHOR_SELECTOR } from "@sroka/shared";

export type ReaderTheme = "light" | "dark" | "sepia" | "system";
export type ReaderFont = "serif" | "sans" | "mono";
export interface ReaderSettings {
  theme: ReaderTheme;
  font: ReaderFont;
  /** px */
  size: number;
  lineHeight: number;
  /** px, max content width */
  width: number;
}

export const DEFAULT_READER_SETTINGS: ReaderSettings = { theme: "system", font: "serif", size: 19, lineHeight: 1.65, width: 680 };

// The article iframe CSP forbids web fonts, so these are system stacks.
export const FONT_STACKS: Record<ReaderFont, string> = {
  serif: `"Iowan Old Style", "Charter", "Palatino Linotype", Georgia, serif`,
  sans: `system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`,
  mono: `ui-monospace, "SF Mono", Menlo, Consolas, monospace`,
};

const PALETTES = {
  light: { bg: "#fbfbf9", fg: "#1b1c1d", muted: "#6b6e71", link: "#0b7f7c", rule: "#e3e3df" },
  dark: { bg: "#121314", fg: "#dcdcd8", muted: "#8f9396", link: "#4cd6c8", rule: "#2a2d2f" },
  sepia: { bg: "#f3ead8", fg: "#40321f", muted: "#8a7656", link: "#1f6f6a", rule: "#e0d3b8" },
} as const;

export function resolveTheme(theme: ReaderTheme, prefersDark: boolean): "light" | "dark" | "sepia" {
  return theme === "system" ? (prefersDark ? "dark" : "light") : theme;
}

export function readerVars(s: ReaderSettings, prefersDark: boolean): Record<string, string> {
  const p = PALETTES[resolveTheme(s.theme, prefersDark)];
  return {
    "--bg": p.bg,
    "--fg": p.fg,
    "--muted": p.muted,
    "--link": p.link,
    "--rule": p.rule,
    "--font": FONT_STACKS[s.font],
    "--size": `${s.size}px`,
    "--lh": String(s.lineHeight),
    "--width": `${s.width}px`,
  };
}

const KEY = "sroka.reader";

function clamp(v: unknown, min: number, max: number, fallback: number): number {
  return typeof v === "number" && Number.isFinite(v) ? Math.min(max, Math.max(min, v)) : fallback;
}

export function loadReaderSettings(storage?: Pick<Storage, "getItem">): ReaderSettings {
  const d = DEFAULT_READER_SETTINGS;
  try {
    const raw = (storage ?? localStorage).getItem(KEY);
    if (!raw) return d;
    const v = JSON.parse(raw) as Partial<ReaderSettings>;
    return {
      theme: ["light", "dark", "sepia", "system"].includes(v.theme as string) ? (v.theme as ReaderTheme) : d.theme,
      font: ["serif", "sans", "mono"].includes(v.font as string) ? (v.font as ReaderFont) : d.font,
      size: clamp(v.size, 14, 28, d.size),
      lineHeight: clamp(v.lineHeight, 1.3, 2.1, d.lineHeight),
      width: clamp(v.width, 480, 960, d.width),
    };
  } catch {
    return d;
  }
}

export function saveReaderSettings(s: ReaderSettings, storage?: Pick<Storage, "setItem">): void {
  try {
    (storage ?? localStorage).setItem(KEY, JSON.stringify(s));
  } catch {
    /* storage unavailable */
  }
}

const escAttr = (s: string) => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

export function makeNonce(): string {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b)).replace(/[^A-Za-z0-9]/g, "");
}

/** The end card is built from static markup + `textContent` only; article-derived strings never reach innerHTML. */
const ICON_CHECK = `<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M8 12.5l2.7 2.7L16 9.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>`;
const ICON_ARCHIVE = `<path d="M3.5 5h17v4h-17z M5 9v10h14V9 M10 13h4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"/>`;

/**
 * The only script that runs in the sandboxed iframe. Talks to the parent via postMessage only.
 * End card: the frame reserves an always-present `#sroka-end` block (so showing the card never changes the
 * scroll height, hence never the progress maths) and fills it when the parent sends `sroka:endCard`; button
 * clicks go back as `sroka:endAction`. No inline handlers: listeners are added here, under the nonce.
 */
export function readerScript(): string {
  return `(function(){
var SEL=${JSON.stringify(PROGRESS_ANCHOR_SELECTOR)};var pending=null,user=false,timer=null,last=0,root=document.documentElement,end=null;
var CHECK=${JSON.stringify(ICON_CHECK)},ARCHIVE=${JSON.stringify(ICON_ARCHIVE)};
function sc(){return document.scrollingElement||root}
function anchors(){return document.body?document.body.querySelectorAll(SEL):[]}
function post(m){parent.postMessage(m,"*")}
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e}
function ico(p){var s=el("span","se-ico");s.setAttribute("aria-hidden","true");s.innerHTML='<svg viewBox="0 0 24 24" width="18" height="18">'+p+'</svg>';return s}
function btn(c,a,label,p){var b=el("button",c);b.type="button";if(p)b.appendChild(ico(p));b.appendChild(el("span",null,label));b.addEventListener("click",function(){post({type:"sroka:endAction",action:a})});return b}
function str(v){return typeof v==="string"?v:""}
function renderEnd(m){if(!end)return;end.textContent="";if(!m||typeof m!=="object")return;
var c=el("div","se-card"),h=el("div","se-head");h.appendChild(ico(CHECK));h.appendChild(el("span",null,str(m.finished)));if(m.meta)h.appendChild(el("span","se-dim"," \u00b7 "+str(m.meta)));c.appendChild(h);
if(m.primary){var a=el("div","se-actions");a.appendChild(btn("se-btn se-primary","archive",str(m.primary),ARCHIVE));if(m.keep)a.appendChild(btn("se-btn","keep",str(m.keep)));c.appendChild(a)}
var n=m.next;if(n&&typeof n==="object"){c.appendChild(el("div","se-label",str(m.upNext)));var b=el("button","se-next");b.type="button";
if(n.thumb){var i=document.createElement("img");i.alt="";i.src=str(n.thumb);b.appendChild(i)}
var t=el("span","se-text");t.appendChild(el("span","se-t",str(n.title)));if(n.meta)t.appendChild(el("span","se-m",str(n.meta)));b.appendChild(t);
b.addEventListener("click",function(){post({type:"sroka:endAction",action:"next"})});c.appendChild(b)}
end.appendChild(c)}
function report(){var s=sc(),max=s.scrollHeight-s.clientHeight,p=max>0?Math.min(1,Math.max(0,s.scrollTop/max)):0,l=anchors(),a=null;
for(var i=0;i<l.length;i++){if(l[i].getBoundingClientRect().bottom>1){a=i;break}}
post({type:"sroka:metrics",progress:p,anchor:a})}
function restore(){if(pending==null)return;var el=anchors()[pending],s=sc();if(el&&s.clientHeight>0){s.scrollTop=el.getBoundingClientRect().top+s.scrollTop-8}}
addEventListener("scroll",function(){var n=Date.now();clearTimeout(timer);if(n-last>=150){last=n;report()}else{timer=setTimeout(function(){last=Date.now();report()},150)}},{passive:true});
["wheel","touchstart","keydown","mousedown"].forEach(function(e){addEventListener(e,function(){user=true},{passive:true})});
addEventListener("message",function(e){if(e.source!==parent)return;var d=e.data;if(!d||typeof d!=="object")return;
if(d.type==="sroka:scrollToAnchor"&&typeof d.anchor==="number"){pending=d.anchor;if(!user)restore()}
else if(d.type==="sroka:scrollToTop"){pending=null;user=true;sc().scrollTop=0;report()}
else if(d.type==="sroka:settings"&&d.vars){for(var k in d.vars){root.style.setProperty(k,d.vars[k])}}
else if(d.type==="sroka:endCard"){renderEnd(d.card)}});
addEventListener("load",function(){if(!user)restore()});
addEventListener("resize",function(){if(!user)restore()});
document.addEventListener("DOMContentLoaded",function(){if(document.body){end=el("div");end.id="sroka-end";document.body.appendChild(end)}post({type:"sroka:ready"})});
})();`;
}

function readerCss(vars: Record<string, string>): string {
  const decl = Object.entries(vars)
    .map(([k, v]) => `${k}:${v}`)
    .join(";");
  return `:root{${decl}}
html{background:var(--bg);-webkit-text-size-adjust:100%}
body{margin:0 auto;max-width:var(--width);padding:2.5rem 1.25rem 0;background:var(--bg);color:var(--fg);font-family:var(--font);font-size:var(--size);line-height:var(--lh);overflow-wrap:break-word;text-wrap:pretty}
h1,h2,h3,h4,h5,h6{line-height:1.2;margin:1.8em 0 .6em;text-wrap:balance}
h1{font-size:1.7em}h2{font-size:1.4em}h3{font-size:1.2em}
p,ul,ol,pre,blockquote,figure,table{margin:0 0 1.1em}
a{color:var(--link);text-underline-offset:.15em}
img,video,svg{max-width:100%;height:auto}
figure{margin-inline:0}figcaption{font-size:.8em;color:var(--muted);margin-top:.4em}
blockquote{margin-inline:0;padding-inline-start:1em;border-inline-start:3px solid var(--link);color:var(--muted)}
pre,code{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-size:.88em}
pre{overflow-x:auto;padding:.9em 1em;border:1px solid var(--rule);border-radius:6px}
hr{border:0;border-top:1px solid var(--rule);margin:2em 0}
table{border-collapse:collapse;display:block;overflow-x:auto}td,th{border:1px solid var(--rule);padding:.35em .6em}
${HEAD_CSS}
${POST_CARD_CSS}
${END_CARD_CSS}`;
}

/** Article title + byline written by the extractor (`package.ts`), styled as the reader header. */
const HEAD_CSS = `article>h1:first-child{margin:.2em 0 .5em;font-size:clamp(1.75rem,1.1rem + 2.4vw,2.6rem);line-height:1.15;letter-spacing:-.015em}
article>h1:first-child+.byline{margin:0 0 2.25rem;padding:0 0 2rem;border-bottom:1px solid var(--rule);font:14px/1.4 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:var(--muted)}`;

/**
 * X / Twitter and Reddit post cards (extractor `twitter.ts`, `reddit.ts`; classes allowlisted in `sanitize.ts` POST_CLASSES): one card per
 * post, a thread line joining the avatars of consecutive cards, quoted posts as nested cards.
 */
const POST_CARD_CSS = `.sr-thread{display:flex;flex-direction:column;gap:1rem;margin:0 0 1.1em}
.sr-post{position:relative;padding:.9rem 1rem;border:1px solid var(--rule);border-radius:14px;background:color-mix(in srgb,var(--fg) 2.5%,var(--bg))}
.sr-thread>.sr-post+.sr-post::before{content:"";position:absolute;left:calc(1rem + 19px);top:calc(-1rem - 1px);height:1rem;width:2px;background:var(--rule)}
.sr-post-focus{border-color:var(--link)}
.sr-post-head{display:flex;align-items:center;flex-wrap:wrap;column-gap:.35em;margin:0 0 .6rem;font-size:.8em;line-height:1.3;color:var(--muted)}
.sr-post-head .sr-avatar{width:40px;height:40px;border-radius:50%;object-fit:cover;margin-right:.35em;flex:none}
.sr-post-who strong{color:var(--fg)}
.sr-post-head a{color:inherit;text-decoration:none}.sr-post-head a:hover{text-decoration:underline}
.sr-post-body>:last-child{margin-bottom:0}
.sr-post-body figure img{display:block;width:100%;border-radius:10px;border:1px solid var(--rule)}
.sr-post-body figure>a{display:block}
.sr-post-stats{margin:.6rem 0 0;color:var(--muted);font-size:.85em}
blockquote.sr-post-quote{margin:0 0 1.1em;padding:.7rem .85rem;border:1px solid var(--rule);border-radius:10px;background:var(--bg);color:var(--fg);font-size:.92em}
blockquote.sr-post-quote .sr-avatar{width:22px;height:22px}
blockquote.sr-note{padding:.6rem .85rem;border:1px solid var(--rule);border-radius:10px;color:var(--fg);font-size:.9em}
.sr-comments{display:flex;flex-direction:column;gap:.75rem;margin:0 0 1.1em}
.sr-replies{margin:.7rem 0 0;padding:0 0 0 .85rem;border-left:2px solid var(--rule)}
.sr-reply{padding:.55rem 0 0}.sr-reply:first-child{padding-top:0}
.sr-reply.sr-post-focus{margin:0 0 0 -.85rem;padding:.55rem .85rem;border-left:2px solid var(--link);background:color-mix(in srgb,var(--link) 6%,var(--bg))}
.sr-reply>.sr-post-head{margin-bottom:.35rem}.sr-reply>.sr-post-stats{margin-top:.35rem}
.sr-thread-foot{color:var(--muted);text-align:center}`;

/**
 * Finish line. `#sroka-end` is always present at the end of the article and reserves the card's height, so the
 * document is the same height whether or not the card is shown (the 98% "Read" maths and resume never see it
 * change). It also stands in for the old bottom padding.
 */
const END_CARD_CSS = `#sroka-end{box-sizing:border-box;min-height:19rem;padding:1.5rem 0 3rem;color:var(--fg);font:15px/1.4 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.se-card{display:flex;flex-direction:column;gap:1.1rem;padding-top:1.75rem;border-top:1px solid var(--rule);animation:se-in .25s ease-out}
@keyframes se-in{from{opacity:0;transform:translateY(6px)}}
@media (prefers-reduced-motion:reduce){.se-card{animation:none}}
.se-head{display:flex;align-items:center;gap:.5rem;font-size:1.05rem;font-weight:600}
.se-ico{display:inline-flex;flex:none}.se-head .se-ico{color:var(--link)}
.se-dim{color:var(--muted);font-weight:400;white-space:pre}
.se-actions{display:flex;flex-wrap:wrap;gap:.6rem}
.se-btn{display:inline-flex;align-items:center;gap:.5rem;height:44px;padding:0 1.1rem;border:1.5px solid var(--rule);border-radius:10px;background:transparent;color:var(--fg);font:inherit;font-weight:600;cursor:pointer}
.se-btn.se-primary{border-color:var(--fg);background:var(--fg);color:var(--bg)}
.se-label{color:var(--muted);font-size:.72rem;letter-spacing:.1em;text-transform:uppercase}
.se-next{display:flex;align-items:center;gap:.9rem;box-sizing:border-box;width:100%;padding:.6rem;border:1px solid var(--rule);border-radius:12px;background:transparent;color:var(--fg);font:inherit;text-align:start;cursor:pointer}
.se-next img{flex:none;width:72px;height:54px;border-radius:8px;object-fit:cover;background:var(--rule)}
.se-text{display:flex;min-width:0;flex-direction:column;gap:.15rem}
.se-t{display:-webkit-box;overflow:hidden;font-weight:600;-webkit-line-clamp:2;-webkit-box-orient:vertical}
.se-m{color:var(--muted);font-size:.85rem}
.se-btn:focus-visible,.se-next:focus-visible{outline:2px solid var(--link);outline-offset:2px}
.se-btn:hover,.se-next:hover{border-color:var(--muted)}`;

export interface EndCardNext {
  id: string;
  title: string;
  /** "N min" or null. */
  meta: string | null;
  /** Signed thumbnail URL on the article's content origin (anything else the frame CSP would block), or null. */
  thumb: string | null;
}

/** What the frame draws; all strings are final text. `primary`/`keep` are null for an already archived item. */
export interface EndCardModel {
  finished: string;
  meta: string | null;
  primary: string | null;
  keep: string | null;
  upNext: string;
  next: EndCardNext | null;
}

export type EndAction = "archive" | "keep" | "next";
export const isEndAction = (v: unknown): v is EndAction => v === "archive" || v === "keep" || v === "next";

export const minutesLabel = (m: number | null | undefined) => (m && m > 0 ? `${m} min` : null);

export function endCardModel(o: { readingMinutes: number | null; archived: boolean; next: EndCardNext | null }): EndCardModel {
  return {
    finished: "Finished",
    meta: minutesLabel(o.readingMinutes),
    primary: o.archived ? null : o.next ? "Archive & next" : "Archive",
    keep: o.archived ? null : "Keep",
    upNext: "Up next",
    next: o.next,
  };
}

/** Thumbnail URL for the card, only when it lives on the same origin the frame CSP allows for images. */
export function endCardThumb(url: string | null, baseUrl: string): string | null {
  if (!url) return null;
  try {
    return new URL(url).origin === new URL(baseUrl).origin ? url : null;
  } catch {
    return null;
  }
}

export interface SrcdocInput {
  html: string;
  baseUrl: string;
  settings: ReaderSettings;
  prefersDark: boolean;
  nonce?: string;
}

/** Wrap sanitized article.html in a sandbox-ready document with CSP, base href, theme CSS and reader script. */
export function buildSrcdoc({ html, baseUrl, settings, prefersDark, nonce = makeNonce() }: SrcdocInput): string {
  const origin = new URL(baseUrl).origin;
  const csp = `default-src 'none'; img-src ${origin} data:; style-src 'unsafe-inline'; script-src 'nonce-${nonce}'`;
  const inject =
    `<meta http-equiv="Content-Security-Policy" content="${escAttr(csp)}">` +
    `<base href="${escAttr(baseUrl)}" target="_blank">` +
    `<style>${readerCss(readerVars(settings, prefersDark))}</style>` +
    `<script nonce="${nonce}">${readerScript()}</script>`;

  const doctype = (s: string) => (/^\s*<!doctype/i.test(s) ? s : "<!doctype html>" + s);
  const headOpen = /<head(\s[^>]*)?>/i;
  const htmlOpen = /<html(\s[^>]*)?>/i;
  if (headOpen.test(html)) return doctype(html.replace(headOpen, (m) => m + inject));
  if (htmlOpen.test(html)) {
    return doctype(html.replace(htmlOpen, (m) => `${m}<head><meta charset="utf-8">${inject}</head>`));
  }
  return `<!doctype html><html><head><meta charset="utf-8">${inject}</head><body>${html}</body></html>`;
}
