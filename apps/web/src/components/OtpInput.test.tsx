import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { useState } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { OtpInput, cleanOtp } from "./OtpInput.tsx";

function Harness({ onComplete, busy = false, invalid = false }: { onComplete: (v: string) => void; busy?: boolean; invalid?: boolean }) {
  const [v, setV] = useState("");
  return <OtpInput value={v} onChange={setV} onComplete={onComplete} label="Code sent to a@b.c" busy={busy} invalid={invalid} />;
}
const input = () => screen.getByLabelText("Code sent to a@b.c") as HTMLInputElement;
const boxes = () => screen.getAllByTestId("otp-box");

describe("OtpInput", () => {
  afterEach(cleanup);

  it("is one real numeric one-time-code input under six boxes, with no placeholder", () => {
    render(<Harness onComplete={() => undefined} />);
    expect(boxes()).toHaveLength(6);
    expect(input().getAttribute("autocomplete")).toBe("one-time-code");
    expect(input().inputMode).toBe("numeric");
    expect(input().placeholder).toBe("");
    expect(input().hasAttribute("maxlength")).toBe(false);
  });

  it("fills boxes as digits are typed, highlights the active box, and completes once at 6", () => {
    const done = vi.fn();
    render(<Harness onComplete={done} />);
    fireEvent.focus(input());
    expect(boxes()[0]!.className).toContain("is-active");
    for (const v of ["1", "12", "123", "1234", "12345"]) fireEvent.change(input(), { target: { value: v } });
    expect(boxes().map((b) => b.textContent).join("")).toBe("12345");
    expect(boxes()[4]!.className).toContain("is-filled");
    expect(boxes()[5]!.className).toContain("is-active");
    expect(done).not.toHaveBeenCalled();
    fireEvent.change(input(), { target: { value: "123456" } });
    expect(done).toHaveBeenCalledTimes(1);
    expect(done).toHaveBeenCalledWith("123456");
    expect(boxes()[5]!.className).toContain("is-active");
  });

  it("drops non-digits and ignores digits beyond six", () => {
    const done = vi.fn();
    render(<Harness onComplete={done} />);
    fireEvent.change(input(), { target: { value: "12a3" } });
    expect(input().value).toBe("123");
    fireEvent.change(input(), { target: { value: "1234567890" } });
    expect(input().value).toBe("123456");
    expect(done).toHaveBeenCalledTimes(1);
  });

  it.each(["123 456", "123-456", " 123456 ", "123 – 456", "12 34 56"])("accepts a pasted code with separators: %j", (pasted) => {
    const done = vi.fn();
    render(<Harness onComplete={done} />);
    fireEvent.change(input(), { target: { value: pasted } });
    expect(input().value).toBe("123456");
    expect(done).toHaveBeenCalledExactlyOnceWith("123456");
  });

  it("shows the error state and goes read-only while busy", () => {
    render(<Harness onComplete={() => undefined} invalid />);
    expect(boxes().every((b) => b.className.includes("is-error"))).toBe(true);
    expect(input().getAttribute("aria-invalid")).toBe("true");
    cleanup();
    render(<Harness onComplete={() => undefined} busy />);
    expect(input().readOnly).toBe(true);
    expect(input().disabled).toBe(false);
  });

  it("cleanOtp", () => {
    expect(cleanOtp("1 2-3 4.5 6 7")).toBe("123456");
  });
});
