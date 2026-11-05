import { cancelPendingDeletes, flushPendingDeletes } from "../lib/hooks.ts";
import type { ImportFormat, Job } from "@sroka/shared";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { track } from "../lib/analytics.ts";
import { useConsent, setConsent } from "../lib/consent.ts";
import { hasAnalyticsConfig } from "../lib/firebase-config.ts";
import { ApiRequestError, api } from "../lib/api.ts";
import { useToasts } from "../lib/store.tsx";

const FORMATS: { value: ImportFormat; label: string; hint: string; accept: string }[] = [
  { value: "pocket_csv", label: "Pocket (CSV or ZIP)", hint: "The export file from getpocket.com/export", accept: ".csv,.zip" },
  { value: "pocket_html", label: "Pocket (HTML)", hint: "ril_export.html", accept: ".html,.htm" },
  { value: "instapaper_csv", label: "Instapaper (CSV)", hint: "Export from Instapaper settings", accept: ".csv" },
  { value: "netscape_html", label: "Browser bookmarks (HTML)", hint: "Bookmarks exported from Chrome, Firefox or Safari", accept: ".html,.htm" },
];

export default function Settings() {
  const qc = useQueryClient();
  const toasts = useToasts();
  const me = useQuery({ queryKey: ["me"], queryFn: api.meOrNull });

  const signOut = async () => {
    try {
      await flushPendingDeletes().catch(() => undefined);
      await api.signOut();
    } finally {
      qc.clear();
      qc.setQueryData(["me"], null);
    }
  };

  // import
  const [format, setFormat] = useState<ImportFormat>("pocket_csv");
  const [jobId, setJobId] = useState<string | null>(null);
  const [uploading, setUploading] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const job = useQuery({
    queryKey: ["import", jobId],
    queryFn: () => api.getImport(jobId!),
    enabled: !!jobId,
    refetchInterval: (q) => {
      if (q.state.status === "error") return false;
      const s = q.state.data?.status;
      return s === "done" || s === "failed" ? false : 1500;
    },
  });
  const startImport = async () => {
    const file = fileRef.current?.files?.[0];
    if (!file) return;
    setUploading(true);
    try {
      const j = await api.createImport(file, format);
      track({ name: "import_start", params: { source: format } });
      setJobId(j.id);
      qc.setQueryData(["import", j.id], j);
    } catch (e) {
      const msg =
        e instanceof ApiRequestError && e.status === 413 ? "That file is too large (20 MB max)."
        : e instanceof ApiRequestError && e.status === 415 ? "That file type is not supported."
        : "The import could not start. Try again.";
      toasts.push({ message: msg, tone: "error" });
    } finally {
      setUploading(false);
    }
  };
  const j = job.data;
  const finished = j?.status === "done";
  useEffect(() => {
    if (!finished) return;
    void qc.invalidateQueries({ queryKey: ["items"] });
    void qc.invalidateQueries({ queryKey: ["me"] });
    void qc.invalidateQueries({ queryKey: ["tags"] });
  }, [finished, qc]);

  // delete account
  const [confirmText, setConfirmText] = useState("");
  const [deleting, setDeleting] = useState(false);
  const deleteAccount = async () => {
    setDeleting(true);
    try {
      await api.deleteAccount();
      cancelPendingDeletes();
      await api.signOut().catch(() => undefined);
      qc.clear();
      qc.setQueryData(["me"], null);
    } catch {
      toasts.push({ message: "Could not delete the account. Try again.", tone: "error" });
      setDeleting(false);
    }
  };

  return (
    <div className="mx-auto max-w-2xl px-4 py-6 sm:px-8">
      <h1 className="text-3xl font-extrabold tracking-tight">Settings</h1>

      <Section title="Account">
        <p className="text-sm text-ink2">Signed in as <strong className="text-ink">{me.data?.user.email}</strong></p>
        <button className="btn mt-3" onClick={() => void signOut()}>Sign out</button>
      </Section>

      <Section title="Import">
        <p className="text-sm text-ink2">Bring your saved pages from Pocket, Instapaper or browser bookmarks. Duplicates are merged.</p>
        <div className="mt-3 flex flex-col gap-3">
          <label className="flex flex-col gap-1 text-sm">
            Format
            <select className="input" value={format} onChange={(e) => setFormat(e.target.value as ImportFormat)}>
              {FORMATS.map((f) => <option key={f.value} value={f.value}>{f.label}</option>)}
            </select>
            <span className="text-xs text-ink2">{FORMATS.find((f) => f.value === format)?.hint}</span>
          </label>
          <input ref={fileRef} type="file" className="input" aria-label="Import file" accept={FORMATS.find((f) => f.value === format)?.accept} />
          <button className="btn btn-primary w-fit" disabled={uploading || (j && j.status !== "done" && j.status !== "failed")} onClick={() => void startImport()}>
            {uploading ? "Uploading" : "Import"}
          </button>
          {j && <ImportProgress job={j} />}
          {job.isError && !j && <p className="text-[#c2362f]">Could not load the import status. Try again later.</p>}
        </div>
      </Section>

      <Section title="Export">
        <p className="text-sm text-ink2">Download everything you have saved.</p>
        <div className="mt-3 flex gap-2">
          <a className="btn" href={api.exportUrl("csv")} download onClick={() => track({ name: "export", params: { format: "csv" } })}>CSV (Pocket compatible)</a>
          <a className="btn" href={api.exportUrl("json")} download onClick={() => track({ name: "export", params: { format: "json" } })}>JSON</a>
        </div>
      </Section>

      <Section title="Browser extension">
        <p className="text-sm text-ink2">Save any page with one click or Alt+Shift+S.</p>
        <a className="btn mt-3" href="https://sroka.app/#extension" target="_blank" rel="noopener noreferrer">Get the Chrome extension</a>
      </Section>

      <PrivacySection />

      <Section title="Delete account">
        <p className="text-sm text-ink2">This permanently deletes your account, saved pages and tags. It cannot be undone. Export first if you want a copy.</p>
        <form className="mt-3 flex flex-wrap gap-2" onSubmit={(e) => { e.preventDefault(); if (confirmText === "DELETE") void deleteAccount(); }}>
          <input className="input !w-56" aria-label="Type DELETE to confirm" placeholder="Type DELETE to confirm" value={confirmText} onChange={(e) => setConfirmText(e.target.value)} autoComplete="off" />
          <button className="btn btn-danger" disabled={confirmText !== "DELETE" || deleting}>{deleting ? "Deleting" : "Delete my account"}</button>
        </form>
      </Section>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="mt-8 border-t border-rule pt-6">
      <h2 className="mb-2 text-xl font-semibold">{title}</h2>
      {children}
    </section>
  );
}

function ImportProgress({ job }: { job: Job }) {
  const pct = job.total ? Math.min(100, Math.round((job.done / job.total) * 100)) : null;
  return (
    <div className="rounded-xl border border-rule p-3 text-sm" role="status">
      {job.status === "failed" ? (
        <p className="text-[#c2362f]">Import failed{job.error ? `: ${job.error}` : "."}</p>
      ) : job.status === "done" ? (
        <p>Import finished. {job.done} processed{job.skipped ? `, ${job.skipped} skipped` : ""}. Pages are fetched in the background.</p>
      ) : (
        <p>{job.status === "queued" ? "Waiting to start" : `Importing, ${job.done}${job.total ? ` of ${job.total}` : ""}`}</p>
      )}
      {job.status !== "failed" && (
        <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-paper2">
          <div className="sheen-bg h-full transition-all" style={{ width: `${job.status === "done" ? 100 : pct ?? 8}%` }} />
        </div>
      )}
    </div>
  );
}

export function PrivacySection() {
  const consent = useConsent();
  return (
    <Section title="Privacy">
      <div className="flex flex-col gap-3">
        {hasAnalyticsConfig() && (
          <Toggle
            label="Share usage analytics"
            hint="Anonymous statistics about which features are used, never what you read. Off unless you allow it."
            checked={consent.analytics === true}
            onChange={(v) => setConsent({ analytics: v })}
          />
        )}
        <Toggle
          label="Send crash reports"
          hint="Technical error details (no page content) so problems can be fixed."
          checked={consent.errors}
          onChange={(v) => setConsent({ errors: v })}
        />
        <p className="flex gap-4 text-sm">
          <a className="text-link hover:underline" href="/privacy" target="_blank" rel="noopener noreferrer">Privacy policy</a>
          <a className="text-link hover:underline" href="/terms" target="_blank" rel="noopener noreferrer">Terms of service</a>
        </p>
      </div>
    </Section>
  );
}

function Toggle({ label, hint, checked, onChange }: { label: string; hint: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="flex cursor-pointer items-start gap-3 text-sm">
      <input type="checkbox" className="mt-1 size-4 accent-[var(--wing)]" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      <span>
        {label}
        <span className="block text-xs text-ink2">{hint}</span>
      </span>
    </label>
  );
}
