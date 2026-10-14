// No @types/chrome in this repo: `chrome` has the same shape as WXT's `browser` (promise-based MV3 API).
declare const chrome: typeof import("wxt/browser").browser;
