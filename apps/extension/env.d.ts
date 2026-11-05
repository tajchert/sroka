// No @types/chrome in this repo: `chrome` has the same shape as WXT's `browser` (promise-based MV3 API).
declare const chrome: typeof import("wxt/browser").browser;
// Injected by wxt.config.ts from analytics.config.json (null when absent). Undefined under vitest.
declare const __SROKA_GA__: { measurementId: string; apiSecret: string } | null;
