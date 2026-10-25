/** Brand mark: icon 6a (bookmark magpie on a white tile). Source of truth: scripts/make-icons.mjs. */
export function LogoMark({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 100 100" aria-hidden="true" className="shrink-0">
      <rect width="100" height="100" rx="22" fill="#ffffff" />
      <rect x="0.75" y="0.75" width="98.5" height="98.5" rx="21.25" fill="none" stroke="#15171c" strokeOpacity="0.12" strokeWidth="1.5" />
      <path d="M30 20 H62 Q70 20 70 28 V82 L50 77 L30 82 Z" fill="#15171c" />
      <polygon points="30,56 70,46 70,58 30,68" fill="#1e6f8f" />
      <polygon points="69,27 83,33 69,39" fill="#f2c84b" />
      <circle cx="58" cy="32" r="4" fill="#ffffff" />
    </svg>
  );
}

export function Wordmark() {
  return (
    <span className="inline-flex items-center gap-2 text-ink">
      <LogoMark />
      <span className="text-[1.2rem] font-extrabold tracking-tight">Sroka</span>
    </span>
  );
}
