import { Component, type ErrorInfo, type ReactNode } from "react";
import { reportClientError } from "../lib/error-reporting.ts";

interface State {
  failed: boolean;
}

/** Top-level React error boundary: reports the error and shows a friendly screen with a reload button. */
export default class ErrorBoundary extends Component<{ children: ReactNode }, State> {
  override state: State = { failed: false };

  static getDerivedStateFromError(): State {
    return { failed: true };
  }

  override componentDidCatch(error: Error, info: ErrorInfo): void {
    reportClientError(error, `react (${(info.componentStack ?? "").trim().split("\n")[0] ?? ""})`);
  }

  override render(): ReactNode {
    if (!this.state.failed) return this.props.children;
    return (
      <div role="alert" style={{ maxWidth: 440, margin: "20vh auto", padding: "0 24px", textAlign: "center", color: "var(--ink)" }}>
        <h1 style={{ fontFamily: "var(--font-read)", fontSize: 28, margin: "0 0 12px" }}>Something went wrong</h1>
        <p style={{ color: "var(--ink-2, var(--ink))", margin: "0 0 24px" }}>
          Sroka hit an unexpected error. Your library is safe. We have been notified; reloading usually fixes it.
        </p>
        <button type="button" className="btn btn-primary" onClick={() => location.reload()}>
          Reload
        </button>
      </div>
    );
  }
}
