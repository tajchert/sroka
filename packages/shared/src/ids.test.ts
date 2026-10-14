import { describe, expect, it } from "vitest";
import { isUuid, uuidv7, uuidv7Time } from "./ids.ts";

describe("uuidv7", () => {
  it("is a valid v7 uuid", () => {
    const id = uuidv7();
    expect(isUuid(id)).toBe(true);
    expect(id[14]).toBe("7");
    expect("89ab").toContain(id[19]);
  });
  it("encodes the timestamp", () => {
    const t = 2_000_000_000_000; // ahead of real clock (generator is monotonic)
    expect(uuidv7Time(uuidv7(t))).toBe(t);
  });
  it("is strictly increasing within the same ms and across many calls", () => {
    const ids = Array.from({ length: 10_000 }, () => uuidv7(1_900_000_000_000));
    for (let i = 1; i < ids.length; i++) expect(ids[i]! > ids[i - 1]!).toBe(true);
    expect(new Set(ids).size).toBe(ids.length);
  });
  it("stays monotonic if the clock goes backwards", () => {
    const a = uuidv7(1_950_000_000_000);
    const b = uuidv7(1_940_000_000_000);
    expect(b > a).toBe(true);
  });
  it("isUuid rejects junk", () => {
    expect(isUuid("nope")).toBe(false);
    expect(isUuid(42)).toBe(false);
  });
});
