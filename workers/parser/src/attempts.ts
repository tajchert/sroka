/**
 * Parse analytics (decisions D10): one D1 `parse_attempts` row, one `parse` log line and one Analytics Engine
 * `parse` point per finished job (final outcome of a delivery incl. cache hits, and DLQ failures). Domain only in
 * logs/metrics; the canonical URL goes to D1 for public content only (NULL for captured/private).
 */
import { displayDomain, hashId, log, normalizeUrl, PARSER_VERSION, uuidv7, writeMetric, type ParseJob, type ParseResult } from "@sroka/shared";
import type { ParserEnv } from "./env.ts";
import type { JobStats } from "./process.ts";

export const ATTEMPTS_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

export interface AttemptReport {
  job: ParseJob;
  result: ParseResult;
  stats: JobStats;
  durationMs: number;
  attempt: number;
  /** "dlq" for dead-letter failures (source blob). */
  source?: string;
  now?: number;
}

export async function reportParse(env: ParserEnv, r: AttemptReport): Promise<void> {
  const { job, result, stats } = r;
  const domain = displayDomain(job.url) || "unknown";
  const source = r.source ?? (job.rawKey ? "capture" : job.force ? "refresh" : "fetch");
  const method = stats.method ?? (job.rawKey ? "capture" : "fetch");
  const fallbackOutcome = stats.fallbackOutcome ?? "none";
  const ruleApplied = !!stats.ruleApplied;
  const level = result.status === "failed" ? "warn" : "info";
  log[level]("parse", {
    event: "parse",
    domain,
    status: result.status,
    error: result.error,
    errorDetail: stats.errorDetail,
    source,
    method,
    fallbackOutcome,
    ruleApplied,
    durationMs: r.durationMs,
    renderMs: stats.renderMs ?? 0,
    textChars: stats.textChars ?? 0,
    httpStatus: stats.httpStatus ?? null,
    bytes: stats.bytes ?? 0,
    images: stats.images ?? 0,
    cacheHit: stats.cacheHit ?? false,
    parserVersion: result.parserVersion,
    attempts: r.attempt,
    itemId: job.itemId,
  });
  writeMetric(env.METRICS, {
    event: "parse",
    blobs: [domain, result.status, result.error ?? "", source, stats.cacheHit ? "hit" : "miss", method, fallbackOutcome, ruleApplied ? "1" : "0"],
    doubles: [r.durationMs, stats.bytes ?? 0, stats.images ?? 0, stats.renderMs ?? 0, stats.textChars ?? 0, r.attempt],
    index: domain,
  });

  let url: string | null = null;
  if (!job.rawKey && !result.contentPrivate) {
    try {
      url = normalizeUrl(job.url);
    } catch {
      url = null;
    }
  }
  try {
    await env.DB.prepare(
      `INSERT INTO parse_attempts (id, created_at, user_hash, item_id, domain, url, status, error_code, error_detail, method,
         fallback_outcome, http_status, text_chars, word_count, images, duration_ms, render_ms, attempt, parser_version, rule_applied)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)`,
    )
      .bind(
        uuidv7(),
        r.now ?? Date.now(),
        await hashId(job.userId, 16),
        job.itemId,
        domain,
        url,
        result.status,
        result.error ?? null,
        stats.errorDetail ? stats.errorDetail.slice(0, 300) : null,
        method,
        fallbackOutcome,
        stats.httpStatus ?? null,
        stats.textChars ?? null,
        result.wordCount ?? null,
        stats.images ?? null,
        Math.round(r.durationMs),
        stats.renderMs ?? null,
        r.attempt,
        result.parserVersion ?? PARSER_VERSION,
        ruleApplied ? 1 : 0,
      )
      .run();
  } catch (e) {
    log.warnException("parse_attempts insert failed", e, { event: "parse_attempt_insert_failed" });
  }
}
