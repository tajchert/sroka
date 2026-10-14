import { z } from "zod";

/** Per-site extraction rules stored in KV `CONFIG` (decisions D10). */
export const SITE_RULE_KEY_PREFIX = "site-rules:v1:";

export const SiteRuleSchema = z
  .object({
    render: z.enum(["auto", "always", "never"]).optional(),
    contentSelector: z.string().min(1).max(500).optional(),
    removeSelectors: z.array(z.string().min(1).max(500)).max(50).optional(),
    stripParams: z.array(z.string().min(1).max(100)).max(50).optional(),
    userAgent: z.enum(["default", "browser"]).optional(),
    minTextChars: z.number().int().min(0).max(100_000).optional(),
    waitForSelector: z.string().min(1).max(500).optional(),
    disabled: z.boolean().optional(),
    note: z.string().max(1000).optional(),
    updatedAt: z.number().int().optional(),
  })
  .strict();
export type SiteRule = z.infer<typeof SiteRuleSchema>;

/** Normalized rule host: lowercase, no trailing dot, no leading `www.`. */
export function ruleHost(host: string): string {
  return host.trim().toLowerCase().replace(/\.$/, "").replace(/^www\./, "");
}

export function siteRuleKey(host: string): string {
  return SITE_RULE_KEY_PREFIX + ruleHost(host);
}

/** Hosts to try for a URL host, most specific first: `a.b.example.com` → a.b.example.com, b.example.com, example.com. */
export function ruleLookupHosts(host: string): string[] {
  const parts = ruleHost(host).split(".");
  const out: string[] = [];
  for (let i = 0; i <= parts.length - 2; i++) out.push(parts.slice(i).join("."));
  return out.length ? out : [ruleHost(host)];
}
