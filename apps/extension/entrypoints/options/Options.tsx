import { useEffect, useState } from "react";
import { describeError, signOut } from "../../lib/api.ts";
import { clearCache } from "../../lib/badge-cache.ts";
import { DEFAULT_SERVER, getSettings, normalizeServerUrl, setSettings, clearSession, type Settings } from "../../lib/settings.ts";

export function Options() {
  const [s, setS] = useState<Settings | null>(null);
  const [server, setServer] = useState("");
  const [msg, setMsg] = useState("");
  const [err, setErr] = useState("");

  const load = async () => {
    const cur = await getSettings();
    setS(cur);
    setServer(cur.serverUrl);
  };
  useEffect(() => void load(), []);

  if (!s) return null;

  const saveServer = async () => {
    setErr("");
    setMsg("");
    const origin = normalizeServerUrl(server);
    if (!origin) return setErr("Enter a full URL such as https://api.sroka.app");
    if (origin === s.serverUrl) return setMsg("Already using this server.");
    try {
      const granted = await chrome.permissions.contains({ origins: [origin + "/*"] });
      if (!granted && !(await chrome.permissions.request({ origins: [origin + "/*"] }))) {
        return setErr("Permission to reach that server was denied, so the URL was not saved.");
      }
      // A session belongs to one server; queued saves stay but are only sent to the server (and account)
      // that queued them (lib/queue.ts ownedBy).
      await clearSession();
      await clearCache();
      await setSettings({ serverUrl: origin });
      setMsg("Server saved. Sign in again from the popup.");
      await load();
    } catch (e) {
      setErr(describeError(e));
    }
  };

  return (
    <div className="page">
      <h1 className="serif">Sroka settings</h1>

      <div className="section">
        <label className="label" htmlFor="server" style={{ marginTop: 0 }}>
          Server URL
        </label>
        <input id="server" className="field" value={server} onChange={(e) => setServer(e.target.value)} spellCheck={false} />
        <div className="actions">
          <button className="btn primary" style={{ flex: "0 0 auto" }} onClick={() => void saveServer()}>
            Save server
          </button>
          {server !== DEFAULT_SERVER && (
            <button className="btn" style={{ flex: "0 0 auto" }} onClick={() => setServer(DEFAULT_SERVER)}>
              Use default
            </button>
          )}
        </div>
        {msg && <p className="hint">{msg}</p>}
        {err && <p className="err">{err}</p>}
      </div>

      <div className="section">
        <label className="toggle">
          <input
            type="checkbox"
            checked={s.captureHtml}
            onChange={async (e) => {
              await setSettings({ captureHtml: e.target.checked });
              await load();
            }}
          />
          <span>
            Always capture the rendered page
            <span className="hint" style={{ display: "block" }}>
              Sends the page as you see it, including content behind a login. Saved this way, the article stays private to you. Pages over 5 MB are saved by URL instead.
            </span>
          </span>
        </label>
      </div>

      <div className="section">
        {s.signedOut ? (
          <p className="hint" style={{ margin: 0 }}>
            Signed out. Open the toolbar popup to sign in.
          </p>
        ) : (
          <>
            <p style={{ margin: "0 0 10px" }}>
              Signed in as <strong>{s.email ?? "your account"}</strong>
            </p>
            <button
              className="btn"
              style={{ flex: "0 0 auto" }}
              onClick={async () => {
                await signOut();
                await clearCache();
                await load();
              }}
            >
              Sign out
            </button>
          </>
        )}
      </div>
    </div>
  );
}
