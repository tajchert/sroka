# Sync architecture

The sample is local-first: UI reads come exclusively from Room, writes update Room first. Room seeds two demo tasks only on first database creation; normal startup and Retry never import remote data. A separately labeled, confirmed demo import replaces the local snapshot atomically.

The bundled network implementation is an in-memory demonstration. Best-effort write calls are useful for showing the boundary, but they are not durable synchronization. A process death or failed request can leave local and remote state different.

Before implementing real synchronization, define:

- whether the server or device owns identifiers and timestamps;
- an outbox/pending-operation representation that survives process death;
- idempotency keys and retry/backoff behavior;
- update-versus-delete ordering and tombstone retention;
- conflict rules for edits made on multiple devices;
- authentication expiry and permanent versus retryable failures;
- background execution constraints and user-visible sync state;
- telemetry, privacy, and operational recovery.

Only after those contracts exist should a product add WorkManager, connectivity triggers, and reconciliation. Avoid copying a generic last-write-wins engine without confirming that data loss is acceptable for the domain.
