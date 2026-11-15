import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AUTO_CLOSE_MS, createAutoClose } from "./auto-close.ts";

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

describe("createAutoClose", () => {
  it("closes after 3 s", () => {
    const onClose = vi.fn();
    const ac = createAutoClose({ onClose });
    ac.start();
    vi.advanceTimersByTime(AUTO_CLOSE_MS - 1);
    expect(onClose).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(ac.state).toBe("closed");
  });

  it("does nothing until started", () => {
    const onClose = vi.fn();
    createAutoClose({ onClose });
    vi.advanceTimersByTime(10_000);
    expect(onClose).not.toHaveBeenCalled();
  });

  it("pauses on hold and continues with the time left on release", () => {
    const onClose = vi.fn();
    const ac = createAutoClose({ onClose });
    ac.start();
    vi.advanceTimersByTime(1000);
    ac.hold("hover");
    expect(ac.state).toBe("paused");
    vi.advanceTimersByTime(60_000);
    expect(onClose).not.toHaveBeenCalled();
    ac.release("hover");
    expect(ac.state).toBe("running");
    vi.advanceTimersByTime(1999);
    expect(onClose).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("stays paused until every hold is released (hover + focus)", () => {
    const onClose = vi.fn();
    const ac = createAutoClose({ onClose });
    ac.start();
    ac.hold("hover");
    ac.hold("focus");
    ac.release("hover");
    expect(ac.state).toBe("paused");
    vi.advanceTimersByTime(10_000);
    expect(onClose).not.toHaveBeenCalled();
    ac.release("focus");
    vi.advanceTimersByTime(AUTO_CLOSE_MS);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("starts paused when held before start", () => {
    const onClose = vi.fn();
    const ac = createAutoClose({ onClose });
    ac.hold("focus");
    ac.start();
    expect(ac.state).toBe("paused");
    vi.advanceTimersByTime(10_000);
    expect(onClose).not.toHaveBeenCalled();
    ac.release("focus");
    vi.advanceTimersByTime(AUTO_CLOSE_MS);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("cancel stops it for good, even after release or restart", () => {
    const onClose = vi.fn();
    const states: string[] = [];
    const ac = createAutoClose({ onClose, onState: (s) => states.push(s) });
    ac.start();
    vi.advanceTimersByTime(500);
    ac.cancel();
    ac.release("hover");
    ac.start();
    ac.hold("x");
    ac.release("x");
    vi.advanceTimersByTime(60_000);
    expect(onClose).not.toHaveBeenCalled();
    expect(ac.state).toBe("cancelled");
    expect(states).toEqual(["running", "cancelled"]);
  });

  it("cancel while paused stays cancelled after release", () => {
    const onClose = vi.fn();
    const ac = createAutoClose({ onClose });
    ac.start();
    ac.hold("hover");
    ac.cancel();
    ac.release("hover");
    vi.advanceTimersByTime(60_000);
    expect(onClose).not.toHaveBeenCalled();
  });

  it("dispose stops the timer and never closes", () => {
    const onClose = vi.fn();
    const ac = createAutoClose({ onClose });
    ac.start();
    ac.dispose();
    vi.advanceTimersByTime(60_000);
    expect(onClose).not.toHaveBeenCalled();
  });

  it("does not close twice and ignores late events after closing", () => {
    const onClose = vi.fn();
    const ac = createAutoClose({ onClose, ms: 100 });
    ac.start();
    vi.advanceTimersByTime(100);
    ac.hold("hover");
    ac.release("hover");
    ac.cancel();
    vi.advanceTimersByTime(1000);
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(ac.state).toBe("closed");
  });
});
