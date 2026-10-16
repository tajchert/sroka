import type { Item } from "@sroka/shared";
import { useCallback, useEffect, useState } from "react";
import { deleteItem, describeError, getConfig, patchItem, sendOtp, signIn, tagSuggestions } from "../../lib/api.ts";
import { invalidate, setCached } from "../../lib/badge-cache.ts";
import type { Msg } from "../../lib/messages.ts";
import type { SaveResult } from "../../lib/save.ts";
import { getPendingOtp, getSettings, setPendingOtp } from "../../lib/settings.ts";

type Tab = { id?: number; url?: string; title?: string };
type Phase =
  | { k: "loading" }
  | { k: "signin" }
  | { k: "saving" }
  | { k: "saved"; item: Item; created: boolean }
  | { k: "queued"; message: string }
  | { k: "failed"; message: string }
  | { k: "removed" };

const send = <T,>(m: Msg) => chrome.runtime.sendMessage(m) as Promise<T>;

function Header({ email }: { email?: string | null }) {
  return (
    <div className="bar">
      <img src="/icon/48.png" alt="" />
      <span className="brand serif">Sroka</span>
      {email && <span className="email">{email}</span>}
    </div>
  );
}

export function App() {
  const [phase, setPhase] = useState<Phase>({ k: "loading" });
  const [tab, setTab] = useState<Tab>({});
  const [email, setEmail] = useState<string | null>(null);

  const save = useCallback(async (t: Tab) => {
    setPhase({ k: "saving" });
    const r = await send<SaveResult>({ type: "save-tab", tab: t });
    if (r.ok) setPhase({ k: "saved", item: r.item, created: r.created });
    else if (r.reason === "signed_out") setPhase({ k: "signin" });
    else if (r.queued) setPhase({ k: "queued", message: "You're offline. It will save when the connection is back." });
    else setPhase({ k: "failed", message: r.message ?? "Could not save this page." });
  }, []);

  useEffect(() => {
    (async () => {
      const [t] = await chrome.tabs.query({ active: true, currentWindow: true });
      const tb = { id: t?.id, url: t?.url, title: t?.title };
      setTab(tb);
      const s = await getSettings();
      setEmail(s.email);
      if (s.signedOut) return setPhase({ k: "signin" });
      await save(tb);
    })().catch((e) => setPhase({ k: "failed", message: describeError(e) }));
  }, [save]);

  const onSignedIn = async () => {
    setEmail((await getSettings()).email);
    // Background owns the queue: drop any queued copy of this page (we save it directly below), release the rest.
    await send({ type: "release-queue", skipUrl: tab.url });
    await save(tab);
  };

  return (
    <div className="wrap">
      <Header email={email} />
      {phase.k === "loading" && <p className="hint">Loading…</p>}
      {phase.k === "signin" && <SignIn onDone={onSignedIn} />}
      {phase.k === "saving" && (
        <>
          <h1 className="status pending serif">Saving…</h1>
          <p className="page-title">{tab.title}</p>
        </>
      )}
      {phase.k === "saved" && <Saved item={phase.item} created={phase.created} tab={tab} onRemoved={() => setPhase({ k: "removed" })} />}
      {phase.k === "queued" && (
        <>
          <h1 className="status serif">Queued</h1>
          <p className="page-title">{phase.message}</p>
        </>
      )}
      {phase.k === "failed" && (
        <>
          <h1 className="status serif">Not saved</h1>
          <p className="err">{phase.message}</p>
          {tab.url && (
            <div className="actions">
              <button className="btn primary" onClick={() => void save(tab)}>
                Try again
              </button>
            </div>
          )}
        </>
      )}
      {phase.k === "removed" && <h1 className="status pending serif">Removed</h1>}
    </div>
  );
}

function SignIn({ onDone }: { onDone: () => Promise<void> }) {
  const [step, setStep] = useState<"email" | "code">("email");
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [ready, setReady] = useState(false);

  // Resume the code step: the popup closes while the user reads their email.
  useEffect(() => {
    void getPendingOtp().then((pending) => {
      if (pending) {
        setEmail(pending);
        setStep("code");
      }
      setReady(true);
    });
  }, []);

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    setErr("");
    try {
      await fn();
    } catch (e) {
      setErr(describeError(e));
    } finally {
      setBusy(false);
    }
  };

  if (!ready) return null;

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        void run(async () => {
          if (step === "email") {
            await sendOtp(email.trim());
            await setPendingOtp(email.trim());
            setStep("code");
          } else {
            await signIn(email.trim(), code.trim());
            await setPendingOtp(null);
            await onDone();
          }
        });
      }}
    >
      <h1 className="status serif">Sign in to save</h1>
      {step === "email" ? (
        <>
          <label className="label" htmlFor="email">
            Email
          </label>
          <input id="email" className="field" type="email" required autoFocus autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} />
          <p className="hint">We'll email you a 6-digit code.</p>
        </>
      ) : (
        <>
          <label className="label" htmlFor="code">
            Code sent to {email}
          </label>
          <input id="code" className="field" inputMode="numeric" pattern="[0-9]{6}" maxLength={6} required autoFocus autoComplete="one-time-code" value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))} />
        </>
      )}
      {err && <p className="err">{err}</p>}
      <div className="actions">
        {step === "code" && (
          <button type="button" className="btn" disabled={busy} onClick={() => { void setPendingOtp(null); setStep("email"); setCode(""); setErr(""); }}>
            Back
          </button>
        )}
        <button className="btn primary" disabled={busy}>
          {step === "email" ? "Send code" : "Sign in"}
        </button>
      </div>
    </form>
  );
}

function Saved({ item: initial, created, tab, onRemoved }: { item: Item; created: boolean; tab: Tab; onRemoved: () => void }) {
  const [item, setItem] = useState(initial);
  const [draft, setDraft] = useState("");
  const [sugg, setSugg] = useState<string[]>([]);
  const [err, setErr] = useState("");
  const [archived, setArchived] = useState(initial.status === "archived");

  useEffect(() => {
    if (!tab.url) return;
    tagSuggestions(tab.url)
      .then((s) => setSugg([...s.recent, ...s.frequent]))
      .catch(() => {});
  }, [tab.url]);

  const guard = async <T,>(fn: () => Promise<T>) => {
    setErr("");
    try {
      return await fn();
    } catch (e) {
      setErr(describeError(e));
    }
  };

  const setTags = (tags: string[]) =>
    guard(async () => {
      const next = await patchItem(item.id, { tags });
      setItem(next);
    });

  const addTag = (raw: string) => {
    const name = raw.trim().replace(/\s+/g, " ");
    if (!name || item.tags.some((t) => t.toLowerCase() === name.toLowerCase())) return setDraft("");
    setDraft("");
    return setTags([...item.tags, name]);
  };

  const archive = () =>
    guard(async () => {
      const next = await patchItem(item.id, { status: archived ? "unread" : "archived" });
      setItem(next);
      setArchived(next.status === "archived");
    });

  const remove = () =>
    guard(async () => {
      await deleteItem(item.id);
      if (tab.url) await invalidate(tab.url);
      if (tab.id != null) await send({ type: "refresh-badge", tabId: tab.id, url: tab.url });
      onRemoved();
    });

  const open = () =>
    guard(async () => {
      const { appOrigin } = await getConfig();
      await chrome.tabs.create({ url: `${appOrigin}/app/item/${item.id}` });
      window.close();
    });

  useEffect(() => {
    if (tab.url) void setCached(tab.url, { saved: true, id: item.id });
  }, [tab.url, item.id]);

  const shown = sugg.filter((s) => !item.tags.some((t) => t.toLowerCase() === s.toLowerCase())).slice(0, 8);

  return (
    <>
      <h1 className="status serif">
        <span className="tick">{created ? "Saved ✓" : "Already saved ✓"}</span>
      </h1>
      <p className="page-title">{item.title || tab.title || item.url}</p>

      <label className="label" htmlFor="tag">
        Tags
      </label>
      {item.tags.length > 0 && (
        <div className="chips">
          {item.tags.map((t) => (
            <span className="chip" key={t}>
              {t}
              <button aria-label={`Remove tag ${t}`} onClick={() => void setTags(item.tags.filter((x) => x !== t))}>
                ×
              </button>
            </span>
          ))}
        </div>
      )}
      <input
        id="tag"
        className="field"
        placeholder="Add a tag, press Enter"
        value={draft}
        maxLength={64}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === ",") {
            e.preventDefault();
            void addTag(draft);
          } else if (e.key === "Backspace" && !draft && item.tags.length) {
            void setTags(item.tags.slice(0, -1));
          }
        }}
      />
      {shown.length > 0 && (
        <div className="sugg-row">
          {shown.map((s) => (
            <button key={s} className="sugg" onClick={() => void addTag(s)}>
              {s}
            </button>
          ))}
        </div>
      )}
      {err && <p className="err">{err}</p>}

      <div className="actions">
        <button className="btn" onClick={() => void archive()}>
          {archived ? "Unarchive" : "Archive"}
        </button>
        <button className="btn danger" onClick={() => void remove()}>
          Remove
        </button>
        <button className="btn primary" onClick={() => void open()}>
          Open Sroka
        </button>
      </div>
    </>
  );
}
