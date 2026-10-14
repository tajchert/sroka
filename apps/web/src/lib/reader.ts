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

/** The only script that runs in the sandboxed iframe. Talks to the parent via postMessage only. */
export function readerScript(): string {
  return `(function(){
var SEL=${JSON.stringify(PROGRESS_ANCHOR_SELECTOR)};var pending=null,user=false,timer=null,root=document.documentElement;
function sc(){return document.scrollingElement||root}
function anchors(){return document.body?document.body.querySelectorAll(SEL):[]}
function post(m){parent.postMessage(m,"*")}
function report(){var s=sc(),max=s.scrollHeight-s.clientHeight,p=max>0?Math.min(1,Math.max(0,s.scrollTop/max)):0,l=anchors(),a=null;
for(var i=0;i<l.length;i++){if(l[i].getBoundingClientRect().bottom>1){a=i;break}}
post({type:"sroka:metrics",progress:p,anchor:a})}
function restore(){if(pending==null)return;var el=anchors()[pending];if(el){var s=sc();s.scrollTop=el.getBoundingClientRect().top+s.scrollTop-8}}
addEventListener("scroll",function(){clearTimeout(timer);timer=setTimeout(report,500)},{passive:true});
["wheel","touchstart","keydown","mousedown"].forEach(function(e){addEventListener(e,function(){user=true},{passive:true})});
addEventListener("message",function(e){if(e.source!==parent)return;var d=e.data;if(!d||typeof d!=="object")return;
if(d.type==="sroka:scrollToAnchor"&&typeof d.anchor==="number"){pending=d.anchor;if(!user)restore()}
else if(d.type==="sroka:settings"&&d.vars){for(var k in d.vars){root.style.setProperty(k,d.vars[k])}}});
addEventListener("load",function(){if(!user)restore()});
document.addEventListener("DOMContentLoaded",function(){post({type:"sroka:ready"})});
})();`;
}

function readerCss(vars: Record<string, string>): string {
  const decl = Object.entries(vars)
    .map(([k, v]) => `${k}:${v}`)
    .join(";");
  return `:root{${decl}}
html{background:var(--bg);-webkit-text-size-adjust:100%}
body{margin:0 auto;max-width:var(--width);padding:2.5rem 1.25rem 7rem;background:var(--bg);color:var(--fg);font-family:var(--font);font-size:var(--size);line-height:var(--lh);overflow-wrap:break-word;text-wrap:pretty}
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
table{border-collapse:collapse;display:block;overflow-x:auto}td,th{border:1px solid var(--rule);padding:.35em .6em}`;
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
