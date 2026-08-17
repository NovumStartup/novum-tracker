import { test } from "node:test";
import * as assert from "node:assert/strict";

import {
  MAX_SPOOL_LINES,
  buildSpoolLine,
  clampDuration,
  classifyStatus,
  parseSpoolLine,
  repoKeyFromToplevel,
  rootCommitFromRevList,
  trimSpoolLines,
} from "./core";

test("spool line round-trips", () => {
  const payload = '{"editor":"vscode","duration":120}';
  const line = buildSpoolLine(1755300000, payload);
  assert.equal(line, `1755300000 ${payload}\n`);
  const parsed = parseSpoolLine(line.trimEnd());
  assert.deepEqual(parsed, { epoch: 1755300000, payload });
});

test("parseSpoolLine rejects malformed lines", () => {
  assert.equal(parseSpoolLine(""), null);
  assert.equal(parseSpoolLine("no-epoch {}"), null);
  assert.equal(parseSpoolLine("12.5 {}"), null);
  assert.equal(parseSpoolLine("-3 {}"), null);
  assert.equal(parseSpoolLine("1755300000"), null);
  assert.equal(parseSpoolLine("1755300000 "), null);
  // A payload containing spaces splits only on the FIRST space.
  const parsed = parseSpoolLine('17 {"a": "b c"}');
  assert.deepEqual(parsed, { epoch: 17, payload: '{"a": "b c"}' });
});

test("trimSpoolLines keeps the newest lines and counts drops", () => {
  const lines = Array.from({ length: MAX_SPOOL_LINES + 3 }, (_, i) => `l${i}`);
  const { kept, dropped } = trimSpoolLines(lines, MAX_SPOOL_LINES);
  assert.equal(dropped, 3);
  assert.equal(kept.length, MAX_SPOOL_LINES);
  assert.equal(kept[0], "l3"); // oldest three dropped
  assert.equal(kept[kept.length - 1], `l${MAX_SPOOL_LINES + 2}`);

  const small = trimSpoolLines(["a", "b"], MAX_SPOOL_LINES);
  assert.equal(small.dropped, 0);
  assert.deepEqual(small.kept, ["a", "b"]);
});

test("classifyStatus mirrors the shell client's drain rules", () => {
  assert.equal(classifyStatus(200), "ok");
  assert.equal(classifyStatus(299), "ok");
  assert.equal(classifyStatus(0), "transient"); // transport failure
  assert.equal(classifyStatus(408), "transient");
  assert.equal(classifyStatus(429), "transient");
  assert.equal(classifyStatus(500), "transient");
  assert.equal(classifyStatus(503), "transient");
  assert.equal(classifyStatus(400), "permanent");
  assert.equal(classifyStatus(401), "permanent");
  assert.equal(classifyStatus(404), "permanent");
});

test("clampDuration caps, floors, and applies the shared-clock clamp", () => {
  // Plain cap and floor.
  assert.equal(clampDuration(300, null, 120), 120);
  assert.equal(clampDuration(45, null, 120), 45);
  assert.equal(clampDuration(0, null, 120), 1);
  assert.equal(clampDuration(-10, null, 120), 1);
  // The global clamp partitions wall-clock between windows: a window
  // returning after 90s spent in another window claims only the 30s since
  // this editor's last beat anywhere.
  assert.equal(clampDuration(120, 30, 120), 30);
  // A same-second race floors at 1, never 0.
  assert.equal(clampDuration(120, 0, 120), 1);
  // A global clock ahead of the local one never inflates the claim.
  assert.equal(clampDuration(45, 300, 120), 45);
});

test("repoKeyFromToplevel matches the shell client byte-for-byte", () => {
  // printf '%s' "/Users/dev/app" | shasum -a 256 | cut -c1-16
  assert.equal(repoKeyFromToplevel("/Users/dev/app"), "9e270cd0a1b05c91");
  assert.equal(repoKeyFromToplevel("/Users/dev/app").length, 16);
  // Two clones sharing a basename produce different keys — the collision the
  // field exists to end.
  assert.notEqual(
    repoKeyFromToplevel("/Users/a/app"),
    repoKeyFromToplevel("/Users/b/app"),
  );
});

test("rootCommitFromRevList picks deterministically and rejects noise", () => {
  const a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  // Multiple root commits (grafted history): lexicographically first wins,
  // matching the shell client's `sort | head -1`.
  assert.equal(rootCommitFromRevList(`${b}\n${a}\n`), a);
  assert.equal(rootCommitFromRevList(`${a}\n`), a);
  assert.equal(rootCommitFromRevList(""), null);
  assert.equal(rootCommitFromRevList("fatal: not a git repository"), null);
  assert.equal(rootCommitFromRevList("short\nlines\n"), null);
});
