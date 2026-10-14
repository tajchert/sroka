import { useInfiniteQuery, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useMemo, useState } from "react";
import { useSearchParams } from "react-router";
import { SiteRuleSchema, ruleHost, type AdminAttempt, type AdminDomainSummary, type SiteRule } from "@sroka/shared";
import { ApiRequestError, api } from "../lib/api.ts";
import { useToasts } from "../lib/store.tsx";

type Tab = "overview" | "attempts" | "rules";
const TABS: { id: Tab; label: string }[] = [
  { id: "overview", label: "Overview" },
  { id: "attempts", label: "Attempts" },
  { id: "rules", label: "Site rules" },
];

export default function Admin() {
  const [sp, setSp] = useSearchParams();
  const me = useQuery({ queryKey: ["me"], queryFn: api.meOrNull });
  const tab = (TABS.find((t) => t.id === sp.get("tab"))?.id ?? "overview") as Tab;

  const go = (next: Record<string, string | null>) => {
    const n = new URLSearchParams(sp);
    for (const [k, v] of Object.entries(next)) {
      if (v) n.set(k, v);
      else n.delete(k);
    }
    setSp(n);
  };

  if (me.isPending) return <div className="p-8"><span className="spinner" aria-label="Loading" /></div>;
  if (!me.data?.isAdmin) return <p className="p-8 text-ink2">Nothing here.</p>;

  return (
    <div className="mx-auto max-w-6xl px-4 py-6 md:px-8">
      <h1 className="mb-4 text-2xl font-semibold">Admin</h1>
      <div className="mb-6 flex gap-1 border-b border-rule" role="tablist">
        {TABS.map((t) => (
          <button
            key={t.id}
            role="tab"
            aria-selected={tab === t.id}
            className={`-mb-px cursor-pointer border-b-2 px-3 py-2 text-sm ${tab === t.id ? "border-wing font-semibold text-ink" : "border-transparent text-ink2 hover:text-ink"}`}
            onClick={() => setSp(t.id === "overview" ? new URLSearchParams() : new URLSearchParams({ tab: t.id }))}
          >
            {t.label}
          </button>
        ))}
      </div>
      {tab === "overview" && <Overview sp={sp} go={go} />}
      {tab === "attempts" && <Attempts sp={sp} go={go} />}
      {tab === "rules" && <Rules sp={sp} go={go} />}
    </div>
  );
}

type Go = (next: Record<string, string | null>) => void;

const pct = (n: number, d: number) => (d > 0 ? `${Math.round((n / d) * 100)}%` : "–");
const fmtTime = (ms: number) => new Date(ms).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });

function ErrorNote({ error }: { error: unknown }) {
  const msg = error instanceof ApiRequestError && error.status === 404 ? "Not available." : "Could not load. Try again.";
  return <p className="text-sm text-[#c2362f]">{msg}</p>;
}

function Card({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="rounded-xl border border-rule p-4">
      <div className="text-xs text-ink2">{label}</div>
      <div className="mt-1 text-2xl font-semibold tabular-nums">{value}</div>
      {sub && <div className="text-xs text-ink2">{sub}</div>}
    </div>
  );
}

function SuccessBar({ d }: { d: { total: number; ok: number; partial: number; failed: number } }) {
  const w = (n: number) => `${d.total ? (n / d.total) * 100 : 0}%`;
  return (
    <div className="flex h-2 w-28 overflow-hidden rounded-full bg-paper2" title={`${d.ok} ok, ${d.partial} partial, ${d.failed} failed`}>
      <span style={{ width: w(d.ok), background: "var(--wing)" }} />
      <span style={{ width: w(d.partial), background: "#d9a21b" }} />
      <span style={{ width: w(d.failed), background: "#c2362f" }} />
    </div>
  );
}

// ---------------------------------------------------------------- overview

function Overview({ sp, go }: { sp: URLSearchParams; go: Go }) {
  const days = [1, 7, 30].includes(Number(sp.get("days"))) ? Number(sp.get("days")) : 7;
  const [sort, setSort] = useState<"failed" | "total">("failed");
  const q = useQuery({ queryKey: ["admin", "summary", days], queryFn: () => api.adminSummary(days), staleTime: 30_000 });
  const rows = useMemo(
    () => [...(q.data?.domains ?? [])].sort((a, b) => b[sort] - a[sort] || b.total - a.total),
    [q.data, sort],
  );
  const t = q.data?.totals;
  const open = (domain: string, tab: Tab, extra: Record<string, string> = {}) =>
    go({ tab, domain, status: null, method: null, fallback: null, host: null, days: null, ...extra });

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center gap-2" role="group" aria-label="Period">
        {[1, 7, 30].map((d) => (
          <button key={d} className={`btn ${days === d ? "btn-primary" : ""}`} aria-pressed={days === d} onClick={() => go({ days: d === 7 ? null : String(d) })}>
            {d === 1 ? "24 hours" : `${d} days`}
          </button>
        ))}
        {q.isFetching && <span className="spinner ml-2" aria-label="Loading" />}
      </div>
      {q.isError && <ErrorNote error={q.error} />}
      {t && (
        <div className="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
          <Card label="Attempts" value={String(t.total)} />
          <Card label="OK" value={pct(t.ok, t.total)} sub={`${t.ok}`} />
          <Card label="Partial" value={pct(t.partial, t.total)} sub={`${t.partial}`} />
          <Card label="Failed" value={pct(t.failed, t.total)} sub={`${t.failed}`} />
          <Card label="Render fallback used" value={String(t.renderTried)} sub={t.renderBudgetBlocked ? `${t.renderBudgetBlocked} blocked by budget` : undefined} />
          <Card label="Fallback success" value={pct(t.renderOk, t.renderTried)} sub={`${t.renderOk} of ${t.renderTried}`} />
        </div>
      )}
      {q.data && q.data.daily.length > 0 && <Daily daily={q.data.daily} />}
      {q.data && (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="text-xs text-ink2">
              <tr className="border-b border-rule">
                <th className="py-2 pr-3 font-medium">Domain</th>
                <th className="py-2 pr-3 font-medium">
                  <button className="cursor-pointer" onClick={() => setSort("total")}>Total{sort === "total" ? " ↓" : ""}</button>
                </th>
                <th className="py-2 pr-3 font-medium">Success</th>
                <th className="py-2 pr-3 font-medium">
                  <button className="cursor-pointer" onClick={() => setSort("failed")}>Failed{sort === "failed" ? " ↓" : ""}</button>
                </th>
                <th className="py-2 pr-3 font-medium">Render ok / tried</th>
                <th className="py-2 pr-3 font-medium">Top errors</th>
                <th className="py-2 pr-3 font-medium">Last</th>
                <th className="py-2 font-medium" />
              </tr>
            </thead>
            <tbody>
              {rows.map((d: AdminDomainSummary) => (
                <tr key={d.domain} className="border-b border-rule align-middle">
                  <td className="py-2 pr-3">
                    <button className="cursor-pointer font-medium hover:underline" onClick={() => open(d.domain, "attempts")}>{d.domain}</button>
                  </td>
                  <td className="py-2 pr-3 tabular-nums">{d.total}</td>
                  <td className="py-2 pr-3"><SuccessBar d={d} /></td>
                  <td className="py-2 pr-3 tabular-nums">
                    <button className="cursor-pointer hover:underline" onClick={() => open(d.domain, "attempts", { status: "failed" })}>{d.failed}</button>
                  </td>
                  <td className="py-2 pr-3 tabular-nums">
                    {d.renderOk} / {d.renderTried}
                    {d.renderBudgetBlocked > 0 && <span className="text-ink2"> (+{d.renderBudgetBlocked} budget)</span>}
                  </td>
                  <td className="py-2 pr-3 text-xs text-ink2">{d.topErrors.map((e) => `${e.code} ×${e.count}`).join(", ")}</td>
                  <td className="py-2 pr-3 whitespace-nowrap text-xs text-ink2">{fmtTime(d.lastAttemptAt)}</td>
                  <td className="py-2 whitespace-nowrap">
                    <button className="chip" onClick={() => open(d.domain, "rules", { host: d.domain })}>Add rule</button>
                  </td>
                </tr>
              ))}
              {rows.length === 0 && (
                <tr><td colSpan={8} className="py-6 text-center text-ink2">No parse attempts in this period.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function Daily({ daily }: { daily: { day: string; total: number; ok: number; partial: number; failed: number }[] }) {
  const max = Math.max(1, ...daily.map((d) => d.total));
  return (
    <div className="flex h-24 items-end gap-1" role="img" aria-label="Attempts per day">
      {daily.map((d) => (
        <div key={d.day} className="flex h-full min-w-1 flex-1 flex-col justify-end" title={`${d.day}: ${d.total} (${d.failed} failed)`}>
          <div style={{ height: `${(d.failed / max) * 100}%`, background: "#c2362f" }} />
          <div style={{ height: `${(d.partial / max) * 100}%`, background: "#d9a21b" }} />
          <div style={{ height: `${(d.ok / max) * 100}%`, background: "var(--wing)" }} />
        </div>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------- attempts

const STATUS_CLS: Record<string, string> = {
  ok: "border-wing text-wing",
  partial: "border-[#d9a21b] text-[#b8860b]",
  failed: "border-[#c2362f] text-[#c2362f]",
};

function Attempts({ sp, go }: { sp: URLSearchParams; go: Go }) {
  const f = { domain: sp.get("domain") ?? "", status: sp.get("status") ?? "", method: sp.get("method") ?? "", fallback: sp.get("fallback") ?? "" };
  const [domainInput, setDomainInput] = useState(f.domain);
  useEffect(() => setDomainInput(f.domain), [f.domain]);
  const q = useInfiniteQuery({
    queryKey: ["admin", "attempts", f],
    queryFn: ({ pageParam }) => api.adminAttempts({ ...f, cursor: pageParam, limit: 50 }),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last) => last.nextCursor ?? undefined,
    staleTime: 15_000,
  });
  const rows = q.data?.pages.flatMap((p) => p.attempts) ?? [];
  const sel = (key: string, label: string, opts: string[]) => (
    <select className="input !w-auto" aria-label={label} value={sp.get(key) ?? ""} onChange={(e) => go({ [key]: e.target.value || null })}>
      <option value="">{label}: any</option>
      {opts.map((o) => <option key={o} value={o}>{o}</option>)}
    </select>
  );

  return (
    <div className="flex flex-col gap-4">
      <form
        className="flex flex-wrap items-center gap-2"
        onSubmit={(e) => {
          e.preventDefault();
          go({ domain: domainInput.trim().toLowerCase() || null });
        }}
      >
        <input className="input !w-56" placeholder="Domain" aria-label="Domain" value={domainInput} onChange={(e) => setDomainInput(e.target.value)} />
        {sel("status", "Status", ["ok", "partial", "failed"])}
        {sel("method", "Method", ["fetch", "render", "capture", "cache"])}
        {sel("fallback", "Fallback", ["none", "ok", "partial", "failed", "budget", "disabled"])}
        <button className="btn" type="submit">Apply</button>
        {q.isFetching && <span className="spinner" aria-label="Loading" />}
      </form>
      {q.isError && <ErrorNote error={q.error} />}
      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead className="text-xs text-ink2">
            <tr className="border-b border-rule">
              {["Time", "Domain", "URL", "Status", "Error", "Method", "Fallback", "HTTP", "Chars", "ms (render)", "#"].map((h) => (
                <th key={h} className="py-2 pr-3 font-medium whitespace-nowrap">{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((a: AdminAttempt) => (
              <tr key={a.id} className="border-b border-rule align-top">
                <td className="py-2 pr-3 whitespace-nowrap text-xs text-ink2">{fmtTime(a.createdAt)}</td>
                <td className="py-2 pr-3">
                  <button className="cursor-pointer hover:underline" onClick={() => go({ domain: a.domain })}>{a.domain}</button>
                </td>
                <td className="max-w-64 truncate py-2 pr-3">
                  {a.url ? <a className="hover:underline" href={a.url} target="_blank" rel="noreferrer noopener" title={a.url}>{a.url}</a> : <span className="text-ink2">captured page</span>}
                </td>
                <td className="py-2 pr-3"><span className={`chip ${STATUS_CLS[a.status] ?? ""}`}>{a.status}</span></td>
                <td className="max-w-64 py-2 pr-3">
                  {a.errorCode && <div className="font-medium">{a.errorCode}</div>}
                  {a.errorDetail && <div className="text-xs break-words text-ink2">{a.errorDetail}</div>}
                </td>
                <td className="py-2 pr-3">{a.method}{a.ruleApplied && <span className="chip ml-1" title="site rule applied">rule</span>}</td>
                <td className="py-2 pr-3">{a.fallbackOutcome}</td>
                <td className="py-2 pr-3 tabular-nums">{a.httpStatus ?? "–"}</td>
                <td className="py-2 pr-3 tabular-nums">{a.textChars ?? "–"}</td>
                <td className="py-2 pr-3 whitespace-nowrap tabular-nums">{a.durationMs ?? "–"}{a.renderMs ? ` (${a.renderMs})` : ""}</td>
                <td className="py-2 tabular-nums">{a.attempt ?? "–"}</td>
              </tr>
            ))}
            {!q.isPending && rows.length === 0 && (
              <tr><td colSpan={11} className="py-6 text-center text-ink2">No attempts match.</td></tr>
            )}
          </tbody>
        </table>
      </div>
      {q.hasNextPage && (
        <button className="btn self-center" disabled={q.isFetchingNextPage} onClick={() => void q.fetchNextPage()}>Load more</button>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- site rules

interface RuleForm {
  render: string;
  contentSelector: string;
  removeSelectors: string;
  stripParams: string;
  userAgent: string;
  minTextChars: string;
  waitForSelector: string;
  disabled: boolean;
  note: string;
}

const EMPTY_FORM: RuleForm = {
  render: "", contentSelector: "", removeSelectors: "", stripParams: "", userAgent: "", minTextChars: "", waitForSelector: "", disabled: false, note: "",
};

const lines = (s: string) => s.split("\n").map((x) => x.trim()).filter(Boolean);

export function ruleToForm(r: SiteRule): RuleForm {
  return {
    render: r.render ?? "",
    contentSelector: r.contentSelector ?? "",
    removeSelectors: (r.removeSelectors ?? []).join("\n"),
    stripParams: (r.stripParams ?? []).join("\n"),
    userAgent: r.userAgent ?? "",
    minTextChars: r.minTextChars === undefined ? "" : String(r.minTextChars),
    waitForSelector: r.waitForSelector ?? "",
    disabled: r.disabled ?? false,
    note: r.note ?? "",
  };
}

export function formToRuleInput(f: RuleForm): Record<string, unknown> {
  const o: Record<string, unknown> = {};
  if (f.render) o.render = f.render;
  if (f.contentSelector.trim()) o.contentSelector = f.contentSelector.trim();
  if (lines(f.removeSelectors).length) o.removeSelectors = lines(f.removeSelectors);
  if (lines(f.stripParams).length) o.stripParams = lines(f.stripParams);
  if (f.userAgent) o.userAgent = f.userAgent;
  if (f.minTextChars.trim()) o.minTextChars = Number(f.minTextChars);
  if (f.waitForSelector.trim()) o.waitForSelector = f.waitForSelector.trim();
  if (f.disabled) o.disabled = true;
  if (f.note.trim()) o.note = f.note.trim();
  return o;
}

/** Validate with the shared schema; returns the rule or a readable error. */
export function validateRule(input: unknown): { rule: SiteRule } | { error: string } {
  const p = SiteRuleSchema.safeParse(input);
  if (p.success) return { rule: p.data };
  const i = p.error.issues[0];
  return { error: `${i?.path.join(".") || "rule"}: ${i?.message ?? "invalid"}` };
}

function Rules({ sp, go }: { sp: URLSearchParams; go: Go }) {
  const q = useQuery({ queryKey: ["admin", "rules"], queryFn: api.adminRules });
  const editHost = sp.get("host");
  return (
    <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,28rem)]">
      <div className="flex flex-col gap-2">
        <div className="flex items-center justify-between">
          <h2 className="font-semibold">Rules</h2>
          <button className="btn" onClick={() => go({ host: "" , new: "1" })}>New rule</button>
        </div>
        {q.isError && <ErrorNote error={q.error} />}
        {q.data?.length === 0 && <p className="text-sm text-ink2">No site rules yet.</p>}
        <ul className="flex flex-col divide-y divide-rule rounded-xl border border-rule">
          {q.data?.map((r) => (
            <li key={r.host}>
              <button
                className={`flex w-full cursor-pointer flex-col items-start gap-0.5 px-4 py-2.5 text-left hover:bg-paper2 ${editHost === r.host ? "bg-paper2" : ""}`}
                onClick={() => go({ host: r.host, new: null })}
              >
                <span className="font-medium">{r.host}</span>
                <span className="text-xs text-ink2">
                  {[r.rule.render && `render: ${r.rule.render}`, r.rule.disabled && "disabled", r.rule.contentSelector && "selector", r.rule.note].filter(Boolean).join(" · ")}
                </span>
              </button>
            </li>
          ))}
        </ul>
      </div>
      {(editHost !== null || sp.get("new")) && (
        <RuleEditor
          key={editHost ?? "new"}
          host={editHost ?? ""}
          existing={q.data?.find((r) => r.host === ruleHost(editHost ?? ""))?.rule}
          onDone={() => go({ host: null, new: null })}
          onSaved={(h) => go({ host: h, new: null })}
        />
      )}
    </div>
  );
}

function RuleEditor({ host: initialHost, existing, onDone, onSaved }: { host: string; existing?: SiteRule; onDone: () => void; onSaved: (host: string) => void }) {
  const qc = useQueryClient();
  const toasts = useToasts();
  const [host, setHost] = useState(initialHost);
  const [form, setForm] = useState<RuleForm>(existing ? ruleToForm(existing) : EMPTY_FORM);
  const [raw, setRaw] = useState(false);
  const [json, setJson] = useState(() => JSON.stringify(existing ? stripStamp(existing) : {}, null, 2));
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const isExisting = !!existing;
  const set = <K extends keyof RuleForm>(k: K, v: RuleForm[K]) => setForm((f) => ({ ...f, [k]: v }));

  const toggleRaw = () => {
    setError(null);
    if (!raw) {
      setJson(JSON.stringify(formToRuleInput(form), null, 2));
    } else {
      try {
        const v = validateRule(JSON.parse(json));
        if ("error" in v) return setError(v.error);
        setForm(ruleToForm(v.rule));
      } catch {
        return setError("Invalid JSON");
      }
    }
    setRaw(!raw);
  };

  const save = async () => {
    const h = ruleHost(host);
    if (!/^[a-z0-9.-]+\.[a-z]{2,}$/.test(h)) return setError("Enter a host like example.com");
    let input: unknown;
    if (raw) {
      try {
        input = JSON.parse(json);
      } catch {
        return setError("Invalid JSON");
      }
    } else input = formToRuleInput(form);
    const v = validateRule(input);
    if ("error" in v) return setError(v.error);
    setError(null);
    setBusy(true);
    try {
      await api.adminPutRule(h, v.rule);
      await qc.invalidateQueries({ queryKey: ["admin", "rules"] });
      toasts.push({ message: "Rule saved" });
      onSaved(h);
    } catch (e) {
      setError(e instanceof ApiRequestError && e.status === 400 ? (e.message === e.code ? "The server rejected this rule." : e.message) : "Could not save the rule.");
    } finally {
      setBusy(false);
    }
  };
  const remove = async () => {
    if (!confirm(`Delete the rule for ${ruleHost(host)}?`)) return;
    setBusy(true);
    try {
      await api.adminDeleteRule(ruleHost(host));
      await qc.invalidateQueries({ queryKey: ["admin", "rules"] });
      toasts.push({ message: "Rule deleted" });
      onDone();
    } catch {
      setError("Could not delete the rule.");
    } finally {
      setBusy(false);
    }
  };

  const field = (label: string, el: React.ReactNode) => (
    <label className="flex flex-col gap-1 text-sm"><span className="text-xs text-ink2">{label}</span>{el}</label>
  );

  return (
    <section className="flex flex-col gap-3 rounded-xl border border-rule p-4" aria-label="Rule editor">
      <div className="flex items-center justify-between">
        <h2 className="font-semibold">{isExisting ? "Edit rule" : "New rule"}</h2>
        <button className="chip" type="button" onClick={toggleRaw}>{raw ? "Form" : "Raw JSON"}</button>
      </div>
      {field("Host (no www)", <input className="input" value={host} disabled={isExisting} placeholder="example.com" onChange={(e) => setHost(e.target.value)} />)}
      {raw ? (
        <textarea className="input min-h-56 font-mono text-xs" aria-label="Rule JSON" value={json} onChange={(e) => setJson(e.target.value)} spellCheck={false} />
      ) : (
        <>
          <div className="grid grid-cols-2 gap-3">
            {field("Render", (
              <select className="input" value={form.render} onChange={(e) => set("render", e.target.value)}>
                <option value="">default (auto)</option><option value="auto">auto</option><option value="always">always</option><option value="never">never</option>
              </select>
            ))}
            {field("User agent", (
              <select className="input" value={form.userAgent} onChange={(e) => set("userAgent", e.target.value)}>
                <option value="">default</option><option value="default">default</option><option value="browser">browser</option>
              </select>
            ))}
          </div>
          {field("Content selector", <input className="input font-mono text-xs" value={form.contentSelector} onChange={(e) => set("contentSelector", e.target.value)} placeholder="article.post" />)}
          {field("Remove selectors (one per line)", <textarea className="input min-h-20 font-mono text-xs" value={form.removeSelectors} onChange={(e) => set("removeSelectors", e.target.value)} />)}
          {field("Strip params (one per line)", <textarea className="input min-h-16 font-mono text-xs" value={form.stripParams} onChange={(e) => set("stripParams", e.target.value)} />)}
          <div className="grid grid-cols-2 gap-3">
            {field("Min text chars", <input className="input" inputMode="numeric" value={form.minTextChars} onChange={(e) => set("minTextChars", e.target.value)} placeholder="500" />)}
            {field("Wait for selector", <input className="input font-mono text-xs" value={form.waitForSelector} onChange={(e) => set("waitForSelector", e.target.value)} />)}
          </div>
          {field("Note", <input className="input" value={form.note} onChange={(e) => set("note", e.target.value)} />)}
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={form.disabled} onChange={(e) => set("disabled", e.target.checked)} /> Disabled
          </label>
        </>
      )}
      {error && <p role="alert" className="text-sm text-[#c2362f]">{error}</p>}
      <div className="flex items-center gap-2">
        <button className="btn btn-primary" disabled={busy} onClick={() => void save()}>Save</button>
        <button className="btn" onClick={onDone}>Cancel</button>
        {isExisting && <button className="btn btn-danger ml-auto" disabled={busy} onClick={() => void remove()}>Delete</button>}
      </div>
    </section>
  );
}

function stripStamp(r: SiteRule): SiteRule {
  const { updatedAt: _u, ...rest } = r;
  return rest;
}
