/** Brand mark: icon 6a. Source of truth: scripts/make-icons.mjs. */
export function Mark({ size = 28 }: { size?: number }) {
  return (
    <svg className="mark" width={size} height={size} viewBox="0 0 100 100" aria-hidden="true">
      <rect width="100" height="100" fill="#ffffff" />
      <path d="M30 20 H62 Q70 20 70 28 V82 L50 77 L30 82 Z" fill="#15171c" />
      <polygon points="30,56 70,46 70,58 30,68" fill="#1e6f8f" />
      <polygon points="69,27 83,33 69,39" fill="#f2c84b" />
      <circle cx="58" cy="32" r="4" fill="#ffffff" />
    </svg>
  );
}

/** Single-colour bird (cream) with the yellow beak, for coloured bars. */
export function Glyph() {
  return (
    <svg className="glyph" viewBox="26 16 60 70" width="20" height="23" aria-hidden="true">
      <path
        fillRule="evenodd"
        d="M30 20 H62 Q70 20 70 28 V82 L50 77 L30 82 Z M30 56 L70 46 L70 58 L30 68 Z M54 32 a4 4 0 1 0 8 0 a4 4 0 1 0 -8 0 Z"
        fill="#f6f5f1"
      />
      <polygon points="69,27 83,33 69,39" fill="#f2c84b" />
    </svg>
  );
}
