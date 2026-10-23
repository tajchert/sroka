// Popup — implements "Sroka Popup" / "Sroka Extension" from Claude Design (screens: email, otp, saving,
// success, saved, tags, removed), plus queued/failed states in the same language.
import type { Item } from "@sroka/shared";
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { Glyph, Mark } from "../../components/Mark.tsx";
import { deleteItem, describeError, listTags, patchItem, sendOtp, signIn, tagSuggestions } from "../../lib/api.ts";
import { invalidate, setCached } from "../../lib/badge-cache.ts";
import type { Msg } from "../../lib/messages.ts";
import { openApp } from "../../lib/open-app.ts";
import type { SaveResult } from "../../lib/save.ts";
import { getPendingOtp, getSettings, setPendingOtp } from "../../lib/settings.ts";

type Tab = { id?: number; url?: string; title?: string };
type Phase =
  | { k: "loading" }
  | { k: "signin" }
  | { k: "saving" }
  | { k: "success"; item: Item }
  | { k: "saved"; item: Item; created: boolean }
  | { k: "tags"; item: Item; created: boolean }
  | { k: "queued"; message: string }
  | { k: "failed"; message: string }
  | { k: "removed" };

const SUCCESS_MS = 1400;
const send = <T,>(m: Msg) => chrome.runtime.sendMessage(m) as Promise<T>;
const sameTag = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
const hostOf = (url?: string) => {
  try {
    return url ? new URL(url).hostname.replace(/^www\./, "") : "";
  } catch {
    return "";
  }
};

export function App() {
  const [phase, setPhase] = useState<Phase>({ k: "loading" });
  const [tab, setTab] = useState<Tab>({});

  const save = useCallback(async (t: Tab) => {
    setPhase({ k: "saving" });
    const r = await send<SaveResult>({ type: "save-tab", tab: t });
    if (r.ok) setPhase(r.created ? { k: "success", item: r.item } : { k: "saved", item: r.item, created: false });
    else if (r.reason === "signed_out") setPhase({ k: "signin" });
    else if (r.queued) setPhase({ k: "queued", message: "You’re offline. It will save as soon as the connection is back." });
    else setPhase({ k: "failed", message: r.message ?? "Could not save this page." });
  }, []);

  useEffect(() => {
    (async () => {
      const [t] = await chrome.tabs.query({ active: true, currentWindow: true });
      const tb = { id: t?.id, url: t?.url, title: t?.title };
      setTab(tb);
      if ((await getSettings()).signedOut) return setPhase({ k: "signin" });
      await save(tb);
    })().catch((e) => setPhase({ k: "failed", message: describeError(e) }));
  }, [save]);

  // Success celebrates briefly, then hands over to the actions screen.
  useEffect(() => {
    if (phase.k !== "success") return;
    const t = setTimeout(() => setPhase({ k: "saved", item: phase.item, created: true }), SUCCESS_MS);
    return () => clearTimeout(t);
  }, [phase]);

  useEffect(() => {
    if ((phase.k === "saved" || phase.k === "success") && tab.url) void setCached(tab.url, { saved: true, id: phase.item.id });
  }, [phase, tab.url]);

  const onSignedIn = async () => {
    // Background owns the queue: drop any queued copy of this page (we save it directly below), release the rest.
    await send({ type: "release-queue", skipUrl: tab.url });
    await save(tab);
  };

  return (
    <div className="popup-card">
      {phase.k === "loading" && <div className="body hint">Loading…</div>}
      {phase.k === "signin" && <SignIn onDone={onSignedIn} />}
      {phase.k === "saving" && <Saving tab={tab} />}
      {phase.k === "success" && <Success />}
      {phase.k === "saved" && (
        <Saved
          item={phase.item}
          created={phase.created}
          tab={tab}
          onItem={(item) => setPhase({ ...phase, item })}
          onTags={() => setPhase({ k: "tags", item: phase.item, created: phase.created })}
          onRemoved={() => setPhase({ k: "removed" })}
        />
      )}
      {phase.k === "tags" && (
        <Tags item={phase.item} tab={tab} onDone={(item) => setPhase({ k: "saved", item, created: phase.created })} />
      )}
      {phase.k === "queued" && (
        <Notice tone="muted" title="Waiting for a connection" message={phase.message}>
          <button className="btn btn-primary" onClick={() => window.close()}>
            Close
          </button>
        </Notice>
      )}
      {phase.k === "failed" && (
        <Notice tone="error" title="Couldn’t save this page" message={phase.message}>
          <div className="pair">
            <button className="btn btn-ghost" onClick={() => window.close()}>
              Close
            </button>
            {tab.url ? (
              <button className="btn btn-primary" onClick={() => void save(tab)}>
                Try again
              </button>
            ) : null}
          </div>
        </Notice>
      )}
      {phase.k === "removed" && (
        <Notice tone="muted" title="Removed from Sroka" message="This page is no longer in your list, and its offline copy was deleted from your devices.">
          <div className="pair">
            <button className="btn btn-ghost" onClick={() => window.close()}>
              Close
            </button>
            <button className="btn btn-primary" onClick={() => void save(tab)}>
              Save again
            </button>
          </div>
        </Notice>
      )}
    </div>
  );
}

function Spinner({ tone = "light" }: { tone?: "light" | "dark" | "blue" }) {
  return <span className={`spin spin-${tone}`} aria-hidden="true" />;
}

function BrandHeader() {
  return (
    <div className="brand-bar">
      <button className="brand" title="Open Sroka" onClick={() => void openApp().then(() => window.close())}>
        <Mark size={28} />
        <span>Sroka</span>
      </button>
    </div>
  );
}

function Thumb({ item }: { item?: Item }) {
  const [broken, setBroken] = useState(false);
  if (item?.leadImageUrl && !broken) return <img className="thumb" src={item.leadImageUrl} alt="" onError={() => setBroken(true)} />;
  return <span className={`thumb ${item ? "thumb-blue" : "thumb-grey"}`} />;
}

function ItemCard({ item, tab, meta }: { item?: Item; tab: Tab; meta: string }) {
  return (
    <div className="item">
      <Thumb item={item} />
      <div className="item-text">
        <div className="item-title">{item?.title || tab.title || item?.url || tab.url}</div>
        <div className="item-meta">{meta}</div>
      </div>
    </div>
  );
}

function SignIn({ onDone }: { onDone: () => Promise<void> }) {
  const [step, setStep] = useState<"email" | "code" | null>(null);
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [resent, setResent] = useState(false);
  const [focus, setFocus] = useState(true);

  // Resume the code step: the popup closes while the user reads their email.
  useEffect(() => {
    void getPendingOtp().then((pending) => {
      if (pending) setEmail(pending);
      setStep(pending ? "code" : "email");
    });
  }, []);

  const valid = /.+@.+\..+/.test(email.trim());

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

  const sendCode = () =>
    run(async () => {
      if (!valid) return;
      await sendOtp(email.trim());
      await setPendingOtp(email.trim());
      setCode("");
      setResent(false);
      setStep("code");
    });

  const verify = (c: string) =>
    run(async () => {
      await signIn(email.trim(), c);
      await setPendingOtp(null);
      await onDone();
    });

  if (!step) return null;

  return (
    <>
      <BrandHeader />
      {step === "email" ? (
        <form
          className="body body-auth"
          onSubmit={(e) => {
            e.preventDefault();
            void sendCode();
          }}
        >
          <div className="heading">
            <h1>Sign in to save</h1>
            <p className="sub">We’ll email you a 6-digit code. No password needed.</p>
          </div>
          <label className="field-group">
            <span className="eyebrow">Email</span>
            <input
              className="input"
              type="email"
              required
              autoFocus
              autoComplete="email"
              placeholder="you@example.com"
              value={email}
              disabled={busy}
              onChange={(e) => setEmail(e.target.value)}
            />
          </label>
          {err && <p className="err">{err}</p>}
          <button className="btn btn-primary" disabled={!valid && !busy} aria-busy={busy}>
            {busy ? (
              <>
                <Spinner />
                Sending code…
              </>
            ) : (
              "Send code"
            )}
          </button>
        </form>
      ) : (
        <form
          className="body body-auth"
          onSubmit={(e) => {
            e.preventDefault();
            if (code.length === 6) void verify(code);
          }}
        >
          <div className="heading">
            <h1>Check your inbox</h1>
            <p className="sub">
              Enter the code we sent to <b>{email}</b>
            </p>
          </div>
          <div className="field-group">
            <div className="otp">
              <div className="otp-boxes" aria-hidden="true">
                {[0, 1, 2, 3, 4, 5].map((i) => {
                  const active = focus && !busy && i === Math.min(code.length, 5);
                  return (
                    <span key={i} className={`otp-box${err ? " is-error" : active ? " is-active" : code[i] ? " is-filled" : ""}`}>
                      {code[i] ?? ""}
                    </span>
                  );
                })}
              </div>
              <input
                className="otp-input"
                aria-label={`Code sent to ${email}`}
                inputMode="numeric"
                autoComplete="one-time-code"
                maxLength={6}
                autoFocus
                value={code}
                disabled={busy}
                onFocus={() => setFocus(true)}
                onBlur={() => setFocus(false)}
                onChange={(e) => {
                  const c = e.target.value.replace(/\D/g, "").slice(0, 6);
                  setCode(c);
                  setErr("");
                  if (c.length === 6) void verify(c);
                }}
              />
            </div>
            {err && <p className="err">{err}</p>}
          </div>
          <button className="btn btn-primary" disabled={code.length < 6 && !busy} aria-busy={busy}>
            {busy ? (
              <>
                <Spinner />
                Verifying…
              </>
            ) : (
              "Sign in"
            )}
          </button>
          <div className="links">
            <button
              type="button"
              className="link"
              disabled={busy}
              onClick={() =>
                void run(async () => {
                  await sendOtp(email.trim());
                  setCode("");
                  setResent(true);
                })
              }
            >
              {resent ? "Code sent" : "Resend code"}
            </button>
            <span>·</span>
            <button
              type="button"
              className="link"
              disabled={busy}
              onClick={() => {
                void setPendingOtp(null);
                setStep("email");
                setCode("");
                setErr("");
              }}
            >
              Use another email
            </button>
          </div>
        </form>
      )}
    </>
  );
}

function Saving({ tab }: { tab: Tab }) {
  return (
    <>
      <div className="bar bar-blue">
        <Glyph />
        <span className="bar-title">Saving to Sroka…</span>
        <span className="progress" aria-hidden="true">
          <span />
        </span>
      </div>
      <div className="body">
        <ItemCard tab={tab} meta={hostOf(tab.url)} />
        <div className="status-row">
          <Spinner tone="blue" />
          <span>Downloading text and images for offline…</span>
        </div>
      </div>
    </>
  );
}

function Success() {
  return (
    <div className="success" role="status">
      <div className="badge">
        <span className="badge-ring" />
        <span className="badge-disc">
          <svg viewBox="0 0 24 24" width="36" height="36">
            <polyline points="5,12.5 10,17 19,7" />
          </svg>
        </span>
      </div>
      <div>
        <div className="success-title">Saved to Sroka</div>
        <div className="success-sub">Downloaded · ready to read offline</div>
      </div>
    </div>
  );
}

function Saved({
  item,
  created,
  tab,
  onItem,
  onTags,
  onRemoved,
}: {
  item: Item;
  created: boolean;
  tab: Tab;
  onItem: (i: Item) => void;
  onTags: () => void;
  onRemoved: () => void;
}) {
  const [busy, setBusy] = useState<"fav" | "remove" | "open" | null>(null);
  const [err, setErr] = useState("");

  const act = async (k: NonNullable<typeof busy>, fn: () => Promise<void>) => {
    if (busy) return;
    setBusy(k);
    setErr("");
    try {
      await fn();
    } catch (e) {
      setErr(describeError(e));
    } finally {
      setBusy(null);
    }
  };

  const meta = [item.siteName || hostOf(item.url), item.readingMinutes ? `${item.readingMinutes} min` : ""].filter(Boolean).join(" · ");

  return (
    <>
      <div className="bar bar-blue">
        <span className="tick" aria-hidden="true">
          <svg viewBox="0 0 12 12" width="12" height="12">
            <polyline points="2.5,6.3 5,8.6 9.5,3.6" />
          </svg>
        </span>
        <span className="bar-title">{created ? "Saved to Sroka" : "Already in Sroka"}</span>
      </div>
      <div className="body">
        <ItemCard item={item} tab={tab} meta={meta} />
        <div className="field-group">
          <span className="eyebrow">Tags</span>
          <div className="chips">
            {item.tags.map((t) => (
              <button key={t} className="chip chip-tag" onClick={onTags}>
                {t}
              </button>
            ))}
            <button className="chip chip-add" onClick={onTags}>
              {item.tags.length ? "+ Tag" : "+ Add tags"}
            </button>
          </div>
        </div>
        <div className="grid2">
          <button
            className={`btn-tile${item.isFavorite && busy !== "fav" ? " is-fav" : ""}`}
            aria-pressed={item.isFavorite}
            onClick={() => void act("fav", async () => onItem(await patchItem(item.id, { isFavorite: !item.isFavorite })))}
          >
            {busy === "fav" ? (
              <>
                <Spinner tone="dark" />
                Saving…
              </>
            ) : (
              <>
                <svg className="star" viewBox="0 0 24 24" width="17" height="17" aria-hidden="true">
                  <polygon points="12,2.8 14.8,8.9 21.4,9.6 16.5,14.1 17.9,20.6 12,17.3 6.1,20.6 7.5,14.1 2.6,9.6 9.2,8.9" />
                </svg>
                {item.isFavorite ? "Favourited" : "Favourite"}
              </>
            )}
          </button>
          <button
            className="btn-tile btn-danger"
            onClick={() =>
              void act("remove", async () => {
                await deleteItem(item.id);
                if (tab.url) await invalidate(tab.url);
                if (tab.id != null) await send({ type: "refresh-badge", tabId: tab.id, url: tab.url });
                onRemoved();
              })
            }
          >
            {busy === "remove" ? (
              <>
                <Spinner tone="dark" />
                Removing…
              </>
            ) : (
              <>
                <svg viewBox="0 0 24 24" width="17" height="17" aria-hidden="true">
                  <path d="M4.5 7h15 M9.5 7V4.5h5V7 M6.5 7l1 13h9l1-13" />
                </svg>
                Remove
              </>
            )}
          </button>
        </div>
        {err && <p className="err">{err}</p>}
        <button
          className="btn btn-primary"
          onClick={() =>
            void act("open", async () => {
              await openApp(`item/${item.id}`);
              window.close();
            })
          }
        >
          {busy === "open" ? (
            <>
              <Spinner />
              Opening…
            </>
          ) : (
            <>
              Open in Sroka
              <svg className="ext-arrow" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
                <path d="M13.5 5h5.5v5.5 M19 5l-8.5 8.5 M17 14v5H5V7h5" />
              </svg>
            </>
          )}
        </button>
      </div>
    </>
  );
}

function Tags({ item, tab, onDone }: { item: Item; tab: Tab; onDone: (i: Item) => void }) {
  const [draft, setDraft] = useState<string[]>(item.tags);
  const [input, setInput] = useState("");
  const [known, setKnown] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  // Recent + frequent first, then every other tag the user has (for filtering as they type).
  useEffect(() => {
    const merge = (names: string[]) => setKnown((cur) => [...cur, ...names.filter((n) => !cur.some((c) => sameTag(c, n)))]);
    if (tab.url)
      tagSuggestions(tab.url)
        .then((s) => merge([...s.recent, ...s.frequent]))
        .catch(() => {});
    listTags()
      .then((r) => merge(r.tags.map((t) => t.name)))
      .catch(() => {});
  }, [tab.url]);

  const q = input.trim().replace(/\s+/g, " ");
  const add = (raw: string) => {
    const name = raw.trim().replace(/\s+/g, " ");
    if (name && !draft.some((d) => sameTag(d, name))) setDraft([...draft, name]);
    setInput("");
    inputRef.current?.focus();
  };
  const shown = known.filter((t) => !draft.some((d) => sameTag(d, t)) && (!q || t.toLowerCase().includes(q.toLowerCase()))).slice(0, 6);
  const canCreate = !!q && !known.some((t) => sameTag(t, q)) && !draft.some((d) => sameTag(d, q));

  const saveTags = async () => {
    if (busy) return;
    const tags = q && !draft.some((d) => sameTag(d, q)) ? [...draft, q] : draft;
    setBusy(true);
    setErr("");
    try {
      onDone(await patchItem(item.id, { tags }));
    } catch (e) {
      setErr(describeError(e));
      setBusy(false);
    }
  };

  return (
    <>
      <div className="bar bar-blue bar-tight">
        <button className="back" aria-label="Back" onClick={() => onDone(item)}>
          <svg viewBox="0 0 24 24" width="16" height="16">
            <polyline points="14.5,5 7.5,12 14.5,19" />
          </svg>
        </button>
        <span className="bar-title">Edit tags</span>
      </div>
      <div className="body">
        <div className="tag-box" onClick={() => inputRef.current?.focus()}>
          {draft.map((t) => (
            <span key={t} className="chip chip-tag chip-draft">
              {t}
              <button aria-label={`Remove tag ${t}`} onClick={() => setDraft(draft.filter((d) => d !== t))}>
                <svg viewBox="0 0 12 12" width="9" height="9">
                  <path d="M2.5 2.5l7 7 M9.5 2.5l-7 7" />
                </svg>
              </button>
            </span>
          ))}
          <input
            ref={inputRef}
            className="tag-input"
            placeholder="Add a tag…"
            autoFocus
            maxLength={64}
            value={input}
            onChange={(e) => setInput(e.target.value.replace(/,/g, ""))}
            onKeyDown={(e) => {
              if (e.key === "Enter" || e.key === ",") {
                e.preventDefault();
                if (q) add(q);
                else void saveTags();
              } else if (e.key === "Backspace" && !input && draft.length) setDraft(draft.slice(0, -1));
            }}
          />
        </div>
        {(canCreate || shown.length > 0) && (
          <div className="field-group">
            <span className="eyebrow">Your tags</span>
            <div className="chips">
              {canCreate && (
                <button className="chip chip-create" onClick={() => add(q)}>
                  + Create “{q}”
                </button>
              )}
              {shown.map((t) => (
                <button key={t} className="chip chip-sugg" onClick={() => add(t)}>
                  {t}
                </button>
              ))}
            </div>
          </div>
        )}
        {err && <p className="err">{err}</p>}
        <div className="pair">
          <button className="btn btn-ghost" onClick={() => onDone(item)}>
            Cancel
          </button>
          <button className="btn btn-primary" onClick={() => void saveTags()} aria-busy={busy}>
            {busy ? (
              <>
                <Spinner />
                Saving…
              </>
            ) : (
              "Save tags"
            )}
          </button>
        </div>
      </div>
    </>
  );
}

function Notice({ tone, title, message, children }: { tone: "muted" | "error"; title: string; message: string; children: ReactNode }) {
  return (
    <>
      <div className={`bar bar-${tone}`}>
        <Glyph />
        <span className="bar-title">{title}</span>
      </div>
      <div className="body">
        <p className="note">{message}</p>
        {children}
      </div>
    </>
  );
}
