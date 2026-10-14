import { describe, expect, it } from "vitest";
import { formToRuleInput, ruleToForm, validateRule } from "./Admin.tsx";

describe("admin rule form", () => {
  it("round-trips a rule through the form", () => {
    const rule = { render: "always" as const, removeSelectors: [".ad", ".nav"], minTextChars: 200, disabled: true, note: "x" };
    expect(formToRuleInput(ruleToForm(rule))).toEqual(rule);
  });
  it("empty form yields an empty valid rule", () => {
    expect(validateRule(formToRuleInput(ruleToForm({})))).toEqual({ rule: {} });
  });
  it("reports schema errors", () => {
    const r = validateRule({ render: "sometimes" });
    expect("error" in r && r.error).toContain("render");
    expect("error" in validateRule({ minTextChars: -3 })).toBe(true);
    expect("error" in validateRule({ bogus: 1 })).toBe(true);
  });
});
