import { useQuery } from "@tanstack/react-query";
import { useEffect, useState, type ReactNode } from "react";
import { api } from "../lib/api.ts";
import { ANDROID_URL, EXTENSION_URL } from "../lib/links.ts";
import { openSavePopup } from "./AddFab.tsx";
import { CheckIcon, LinkIcon, PhoneIcon, PuzzleIcon } from "./StatusIcons.tsx";

/** QR code of `value` as inline SVG: dark modules on a white tile, so it scans in both themes. Loads the encoder lazily. */
export function QrCode({ value, label, size = 104 }: { value: string; label: string; size?: number }) {
  const [qr, setQr] = useState<{ n: number; d: string } | null>(null);
  useEffect(() => {
    let live = true;
    void import("qrcode-generator")
      .then(({ default: qrcode }) => {
        const code = qrcode(0, "M");
        code.addData(value);
        code.make();
        const n = code.getModuleCount();
        let d = "";
        for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (code.isDark(y, x)) d += `M${x + 2} ${y + 2}h1v1h-1z`;
        if (live) setQr({ n, d });
      })
      .catch(() => undefined); // no code: the link around it still works
    return () => {
      live = false;
    };
  }, [value]);
  const box = qr ? qr.n + 4 : 29;
  return (
    <svg
      role="img"
      aria-label={label}
      viewBox={`0 0 ${box} ${box}`}
      width={size}
      height={size}
      shapeRendering="crispEdges"
      className="rounded-lg bg-white"
      data-testid="qr"
    >
      <rect width={box} height={box} fill="#fff" />
      {qr && <path d={qr.d} fill="#15171c" />}
    </svg>
  );
}

function Card({ icon, done, doneLabel, title, line, children }: { icon: ReactNode; done: boolean; doneLabel: string; title: string; line: string; children: ReactNode }) {
  return (
    <li className="flex items-center gap-3.5 rounded-2xl border border-rule bg-paper2 p-4 sm:flex-col sm:items-start sm:gap-3">
      {done ? (
        <span role="img" aria-label={doneLabel} className="flex size-9 shrink-0 items-center justify-center rounded-xl bg-tag text-tagink">
          <CheckIcon size={18} />
        </span>
      ) : (
        <span aria-hidden className="flex size-9 shrink-0 items-center justify-center rounded-xl bg-paper3 text-link">
          {icon}
        </span>
      )}
      <div className="min-w-0 flex-1 sm:w-full sm:flex-none">
        <p className="text-[15px] leading-tight font-semibold">{title}</p>
        <p className="mt-0.5 text-[13px] leading-snug text-ink2">{done ? "Connected" : line}</p>
      </div>
      {!done && <div className="shrink-0 sm:mt-auto">{children}</div>}
    </li>
  );
}

/**
 * Empty My List: three ways to save, each ticked once that client has been used (`/v1/me` `clients`).
 * Refetches the account on window focus so the tick shows up after installing and coming back.
 */
export function Onboarding() {
  const me = useQuery({ queryKey: ["me"], queryFn: api.meOrNull, retry: false, staleTime: 60_000, refetchOnWindowFocus: "always" });
  const clients = me.data?.clients;
  return (
    <section aria-label="Ways to save" className="flex flex-col gap-3.5 py-6">
      <h2 className="text-[17px] font-semibold">Save from anywhere</h2>
      <ul className="grid gap-3 sm:grid-cols-3">
        <Card icon={<PuzzleIcon size={18} />} done={!!clients?.extension} doneLabel="Browser extension connected" title="Browser" line="One click saves the page you're on.">
          <a className="btn whitespace-nowrap" href={EXTENSION_URL} target="_blank" rel="noopener noreferrer">
            Add to Chrome
          </a>
        </Card>
        <Card icon={<PhoneIcon size={18} />} done={!!clients?.android} doneLabel="Android app connected" title="Phone" line="Scan to get the Android app.">
          <a href={ANDROID_URL} target="_blank" rel="noopener noreferrer" aria-label="Get the Android app" className="block">
            <QrCode value={ANDROID_URL} label="QR code: get the Android app" />
          </a>
        </Card>
        <Card icon={<LinkIcon size={18} />} done={false} doneLabel="" title="Link" line="Paste a link to save it.">
          <button type="button" className="btn whitespace-nowrap" onClick={openSavePopup}>
            Save a link
          </button>
        </Card>
      </ul>
    </section>
  );
}
