import { describe, expect, it } from "vitest";
import { extensionIds } from "../src/auth.ts";

const A = "gmfnkkciofcaafddbcgphofiikmplema";
const B = "abcdefghijklmnopabcdefghijklmnop";

describe("extensionIds (EXT_ID)", () => {
  it("returns nothing when unset or empty", () => {
    expect(extensionIds({})).toEqual([]);
    expect(extensionIds({ EXT_ID: " , ," })).toEqual([]);
  });
  it("keeps a single id (backwards compatible)", () => {
    expect(extensionIds({ EXT_ID: A })).toEqual([A]);
  });
  it("splits on commas, trims whitespace, drops empties", () => {
    expect(extensionIds({ EXT_ID: ` ${A} ,, ${B} ` })).toEqual([A, B]);
  });
  it("skips invalid ids", () => {
    expect(extensionIds({ EXT_ID: `${A},short,${B}x,UPPERCASEUPPERCASEUPPERCASEUPPER,${B}` })).toEqual([A, B]);
  });
  it("maps to chrome-extension origins", () => {
    expect(extensionIds({ EXT_ID: `${A},${B}` }).map((id) => `chrome-extension://${id}`)).toEqual([
      `chrome-extension://${A}`,
      `chrome-extension://${B}`,
    ]);
  });
});
