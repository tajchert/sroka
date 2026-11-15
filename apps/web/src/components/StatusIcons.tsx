import type { ReactNode } from "react";

/** Small stroke icons (24-unit box, `currentColor`) for list-row statuses and the onboarding cards. Decorative: callers label them. */
export function Icon({ size = 16, strokeWidth = 1.8, children }: { size?: number; strokeWidth?: number; children: ReactNode }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      aria-hidden
      focusable="false"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      className="shrink-0"
    >
      {children}
    </svg>
  );
}

type P = { size?: number; strokeWidth?: number };

export const CheckIcon = (p: P) => (
  <Icon strokeWidth={2.4} {...p}>
    <path d="M5 12.5l4.5 4.5L19 7.5" />
  </Icon>
);
export const LockIcon = (p: P) => (
  <Icon {...p}>
    <rect x="5" y="11" width="14" height="9" rx="2" />
    <path d="M8 11V8a4 4 0 0 1 8 0v3" />
  </Icon>
);
/** Failed: exclamation in a circle. */
export const ErrorIcon = (p: P) => (
  <Icon strokeWidth={2.2} {...p}>
    <circle cx="12" cy="12" r="9" />
    <path d="M12 7.5v5.5M12 16.4v.1" />
  </Icon>
);
/** Partial: exclamation in a triangle. */
export const WarnIcon = (p: P) => (
  <Icon strokeWidth={2.2} {...p}>
    <path d="M12 4l9 16H3z" />
    <path d="M12 10v4.5M12 17.2v.1" />
  </Icon>
);
export const ExternalIcon = (p: P) => (
  <Icon {...p}>
    <path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5" />
  </Icon>
);
export const RetryIcon = (p: P) => (
  <Icon {...p}>
    <path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4.5v4h-4" />
  </Icon>
);
export const PuzzleIcon = (p: P) => (
  <Icon {...p}>
    <path d="M10 4.5a2 2 0 1 1 4 0V6h3.5a1 1 0 0 1 1 1v3.5H20a2 2 0 1 1 0 4h-1.5V18a1 1 0 0 1-1 1H14v-1.5a2 2 0 1 0-4 0V19H6.5a1 1 0 0 1-1-1v-3.5H7a2 2 0 1 0 0-4H5.5V7a1 1 0 0 1 1-1H10z" />
  </Icon>
);
export const PhoneIcon = (p: P) => (
  <Icon {...p}>
    <rect x="7" y="2.5" width="10" height="19" rx="2.4" />
    <path d="M11 18.5h2" />
  </Icon>
);
export const LinkIcon = (p: P) => (
  <Icon {...p}>
    <path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3A4 4 0 0 0 11 18.7l1-1" />
  </Icon>
);
