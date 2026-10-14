// Applies the real D1 migrations (workers/api/migrations) to the test D1, once per isolate.
const sqlFiles = (import.meta as unknown as { glob: (p: string, o: object) => Record<string, string> }).glob(
  "../../api/migrations/*.sql",
  { query: "?raw", import: "default", eager: true },
);

let migrated = false;
export async function migrateD1(db: D1Database): Promise<void> {
  if (migrated) return;
  for (const f of Object.keys(sqlFiles).sort()) {
    const stmts = (sqlFiles[f] as string).split("--> statement-breakpoint").map((s) => s.trim()).filter(Boolean);
    for (const s of stmts) await db.prepare(s).run();
  }
  migrated = true;
}

/** Inserts a minimal Better Auth `user` row (idempotent). */
export async function addUser(db: D1Database, id: string): Promise<void> {
  await db.prepare("INSERT OR IGNORE INTO user (id, name, email) VALUES (?1, ?1, ?1 || '@example.com')").bind(id).run();
}
