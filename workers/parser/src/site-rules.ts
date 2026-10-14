import { log, ruleLookupHosts, SiteRuleSchema, siteRuleKey, type SiteRule } from "@sroka/shared";

/** Per-isolate cache of KV site rules (decisions D10): one entry per lookup host, misses included. */
export const RULE_CACHE_TTL_MS = 60_000;
const cache = new Map<string, { rule: SiteRule | null; at: number }>();

/** Test hook. */
export function clearSiteRuleCache(): void {
  cache.clear();
}

async function readRule(kv: KVNamespace, host: string): Promise<SiteRule | null> {
  const raw = await kv.get(siteRuleKey(host));
  if (raw == null) return null;
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    log.warn("invalid site rule ignored", { event: "site_rule_invalid", host, reason: "json" });
    return null;
  }
  const parsed = SiteRuleSchema.safeParse(json);
  if (!parsed.success) {
    log.warn("invalid site rule ignored", { event: "site_rule_invalid", host, reason: parsed.error.issues[0]?.message ?? "schema" });
    return null;
  }
  return parsed.data;
}

/**
 * The most specific site rule for `hostname` (full host, then parent domains; `www.` ignored), or null.
 * KV errors degrade to "no rule" (not cached, so the next job retries).
 */
export async function loadSiteRule(kv: KVNamespace | undefined, hostname: string, now = Date.now()): Promise<{ host: string; rule: SiteRule } | null> {
  if (!kv || !hostname) return null;
  const hosts = ruleLookupHosts(hostname);
  const rules = await Promise.all(
    hosts.map(async (h) => {
      const hit = cache.get(h);
      if (hit && now - hit.at < RULE_CACHE_TTL_MS) return hit.rule;
      try {
        const rule = await readRule(kv, h);
        cache.set(h, { rule, at: now });
        return rule;
      } catch (e) {
        log.warnException("site rule lookup failed", e, { event: "site_rule_lookup_failed", host: h });
        return null;
      }
    }),
  );
  for (let i = 0; i < hosts.length; i++) if (rules[i]) return { host: hosts[i]!, rule: rules[i]! };
  return null;
}

/** `url` minus the rule's `stripParams` query parameters (used for the fetch only). */
export function stripParams(url: string, params: readonly string[] | undefined): string {
  if (!params?.length) return url;
  try {
    const u = new URL(url);
    for (const p of params) u.searchParams.delete(p);
    return u.href;
  } catch {
    return url;
  }
}
