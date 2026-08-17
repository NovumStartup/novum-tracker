// Pure helpers shared by the extension runtime and its tests. No vscode
// import here — this file must load under plain `node --test` (out/core.test.js).

import { createHash } from "crypto";

// Spool bounds. MAX_SPOOL_AGE stays one hour inside the server's 72h ingest
// window so a drained beat is never rejected purely for age; drops are counted
// in spool-dropped.json — silent data loss is the exact failure the spool
// exists to end, so losing beats must itself be visible.
export const MAX_SPOOL_AGE_SECONDS = 255600;
export const MAX_SPOOL_LINES = 500;
export const DRAIN_BATCH = 10;

export type SpoolLine = { epoch: number; payload: string };

// Line format shared with the shell client: "<epoch-seconds> <payload-json>".
export function buildSpoolLine(epoch: number, payload: string): string {
  return `${epoch} ${payload}\n`;
}

export function parseSpoolLine(line: string): SpoolLine | null {
  const sp = line.indexOf(" ");
  if (sp <= 0) return null;
  const epoch = Number(line.slice(0, sp));
  if (!Number.isSafeInteger(epoch) || epoch <= 0) return null;
  const payload = line.slice(sp + 1);
  if (!payload) return null;
  return { epoch, payload };
}

// Overflow drops the OLDEST lines and reports how many, so the caller can
// count them — a bounded spool that trims silently would re-create the silent
// loss it exists to end.
export function trimSpoolLines(
  lines: string[],
  max: number,
): { kept: string[]; dropped: number } {
  if (lines.length <= max) return { kept: lines, dropped: 0 };
  return { kept: lines.slice(lines.length - max), dropped: lines.length - max };
}

export type SendOutcome = "ok" | "transient" | "permanent";

// Transient failures stop a drain and go back to the spool; permanent
// rejections (validation, revoked key) are counted as dropped rather than
// retried forever. 0 = transport failure (offline, DNS, timeout).
export function classifyStatus(status: number): SendOutcome {
  if (status >= 200 && status < 300) return "ok";
  if (status === 0 || status === 408 || status === 429 || status >= 500) {
    return "transient";
  }
  return "permanent";
}

// Wall-clock conservation, mirroring the shell client: a window's beat claims
// the seconds since ITS last beat, clamped by the seconds since this editor's
// last beat in ANY window. Two windows share one clock — wall-clock is
// partitioned between them, never multiplied — and returning to a window
// after time spent in another cannot re-claim the span the other window's
// beats already own. The 1s floor keeps a same-second race from producing a
// zero-duration beat the server would store as empty.
export function clampDuration(
  elapsedSec: number,
  globalElapsedSec: number | null,
  capSec: number,
): number {
  let d = Math.min(Math.max(elapsedSec, 0), capSec);
  if (globalElapsedSec !== null && globalElapsedSec >= 0 && globalElapsedSec < d) {
    d = globalElapsedSec;
  }
  return Math.max(d, 1);
}

// First 16 hex chars of SHA-256 of the checkout root path. Must stay
// byte-compatible with the shell client (`printf '%s' "$root" | sha256`,
// cut to 16) — both clients in the same checkout must agree on its key, or
// a folder mapping made from one client is invisible to the other.
export function repoKeyFromToplevel(root: string): string {
  return createHash("sha256").update(root, "utf8").digest("hex").slice(0, 16);
}

// Deterministic pick when a grafted history has several root commits — the
// SET is identical in every clone, so all clients agree (the shell client's
// `sort | head -1`).
export function rootCommitFromRevList(stdout: string): string | null {
  const hashes = stdout
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => /^[0-9a-f]{40}$/.test(l))
    .sort();
  return hashes[0] ?? null;
}
