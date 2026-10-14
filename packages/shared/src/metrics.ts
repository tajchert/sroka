/** Analytics Engine helper. A missing binding (tests, self-hosting without it) makes every write a no-op. */
export interface MetricsDataset {
  writeDataPoint(p: { blobs?: (string | null)[]; doubles?: number[]; indexes?: (string | null)[] }): void;
}

export interface MetricPoint {
  /** blob1 is always the event name. */
  event: string;
  blobs?: (string | null | undefined)[];
  doubles?: number[];
  /** Sampling key (max 96 bytes, one allowed). Default: the event name. */
  index?: string;
}

/** Layout: blob1=event, blob2.. = `blobs`; double1.. = `doubles`; index1 = `index`. Never throws. */
export function writeMetric(ds: MetricsDataset | undefined | null, p: MetricPoint): void {
  if (!ds) return;
  try {
    ds.writeDataPoint({
      blobs: [p.event, ...(p.blobs ?? []).map((b) => (b ?? "").slice(0, 200))],
      doubles: p.doubles ?? [],
      indexes: [(p.index ?? p.event).slice(0, 96)],
    });
  } catch {
    /* metrics must never break a request */
  }
}
