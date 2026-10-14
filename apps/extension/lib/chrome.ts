/** Thin accessor so lib code (and tests) use `globalThis.chrome` directly. */
export const ext = (): typeof chrome => (globalThis as unknown as { chrome: typeof chrome }).chrome;
