export function LogoMark({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" aria-hidden="true">
      <defs>
        <linearGradient id="sroka-wing" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#1fb7a6" />
          <stop offset="0.55" stopColor="#2b7fe0" />
          <stop offset="1" stopColor="#7a56d6" />
        </linearGradient>
      </defs>
      <rect width="32" height="32" rx="9" fill="currentColor" />
      {/* body */}
      <path d="M6 20c0-6 5-11 12-11 3 0 5 1 8 3l-4 1.5c1 1.5 1 3.5 0 5.5-2 3.5-6 5-9.5 5-3 0-6.500-1-6.500-4z" fill="var(--paper)" />
      {/* wing sheen */}
      <path d="M11 22c1-6 6-10 14-10-1 7-6 11-14 10z" fill="url(#sroka-wing)" />
      <circle cx="21" cy="12.500" r="1" fill="currentColor" />
    </svg>
  );
}

export function Wordmark() {
  return (
    <span className="inline-flex items-center gap-2 text-ink">
      <LogoMark />
      <span className="font-serif text-xl font-semibold tracking-tight">Sroka</span>
    </span>
  );
}
