import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useScreenWakeLock } from "./wakeLock.ts";

function fakeWakeLock() {
  const sentinels: { released: boolean; release: () => Promise<void> }[] = [];
  const request = vi.fn(async () => {
    const s = { released: false, release: vi.fn(async () => { s.released = true; }) };
    sentinels.push(s);
    return s;
  });
  Object.defineProperty(navigator, "wakeLock", { value: { request }, configurable: true });
  return { request, sentinels };
}

describe("useScreenWakeLock", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => {
    vi.useRealTimers();
    delete (navigator as { wakeLock?: unknown }).wakeLock;
  });

  it("holds the lock while active and releases it after the idle time", async () => {
    const { request, sentinels } = fakeWakeLock();
    const { rerender } = renderHook(({ a }) => useScreenWakeLock(true, a, 1000), { initialProps: { a: 0 } });
    await act(async () => {});
    expect(request).toHaveBeenCalledTimes(1);

    await act(async () => { vi.advanceTimersByTime(800); });
    rerender({ a: 1 }); // activity restarts the idle timer
    await act(async () => { vi.advanceTimersByTime(800); });
    expect(sentinels[0]!.released).toBe(false);

    await act(async () => { vi.advanceTimersByTime(300); });
    expect(sentinels[0]!.released).toBe(true);
  });

  it("does nothing when disabled or unsupported", async () => {
    const { request } = fakeWakeLock();
    renderHook(() => useScreenWakeLock(false, 0));
    await act(async () => {});
    expect(request).not.toHaveBeenCalled();
    delete (navigator as { wakeLock?: unknown }).wakeLock;
    expect(() => renderHook(() => useScreenWakeLock(true, 0))).not.toThrow();
  });
});
