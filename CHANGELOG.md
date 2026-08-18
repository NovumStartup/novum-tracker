# Changelog

Two components live in this repo and version independently: the **VS Code /
Cursor extension** (below) and the **Claude Code / Codex plugin** under
[`claude-plugin/`](claude-plugin/) (its releases follow further down).

## Extension

## 1.1.0

- Heartbeats now carry the full 0.5.0-generation payload the AI-tool clients
  send: `machineId` (random per-install id, so the server's per-installation
  dark-stream detection works for extension users), `repoKey` (hash of the
  checkout root — two clones sharing a folder name no longer collide in the
  folder mapper), `rootCommit` (repo identity that survives org renames and
  forks; never sent from shallow clones), `sessionId`, `eventId`, and
  `clientVersion`.
- **Offline spool**: undeliverable heartbeats queue locally (bounded, with
  visible drop accounting) and drain after the next successful send. Server
  restarts, rate limits, and offline stretches no longer lose time.
- **Final flush on window close**: `deactivate()` now spools the tail
  interval instead of dropping up to 2 minutes of work.
- **Shared per-editor clock**: concurrent windows on different projects
  partition wall-clock between them instead of each claiming the full span.
- The status bar surfaces attribution ("unattributed" when heartbeats land
  but map to no project) and queueing state.
- Git subprocess calls are now async (`execFile`) — no more blocking the
  extension host on slow git.

## 1.0.1

- Updated the extension icon to the finalized Novum brand mark.

## 1.0.0

- Initial public release as **Novum Startup Tracker**
- IDE heartbeat tracking for VS Code and Cursor
- Configurable API key, server URL, idle threshold, and file exclusion patterns
- One-click setup via the Novum Startup web app (`vscode://novumstartup.novum-tracker/setup`)

## Claude Code / Codex plugin

## 0.6.0

- New `/novum-tracker:track` command: adds the current repo to the
  `NEONPOD_TRACK_REMOTES` allowlist without hand-editing the env file
  (no-op when no allowlist is set — the default tracks every repo).
- `/novum-tracker:status` now checks the CURRENT repo against the
  allowlist and warns prominently when the folder's time is not being
  recorded — the allowlist is fail-closed, so this was previously
  invisible outside the SessionStart self-check.

## 0.5.1

- The same plugin now installs natively in **Codex**: the repo doubles as a
  Codex marketplace, with a `.codex-plugin` manifest generated from the same
  source hooks.

## 0.5.0

- **Durable offline spool**: undeliverable heartbeats queue locally with
  visible drop accounting, and drain after the next successful send.
- **Per-checkout clocks** with a per-tool global clamp: concurrent sessions
  in different repos partition wall-clock instead of multiplying it.
- Heartbeats carry `repoKey`, `rootCommit`, `eventId`, `sessionId`,
  `clientVersion`, and `machineId` (see the payload table in
  `claude-plugin/README.md`).
- In-session broken-tracking warnings via the `SessionStart` self-check.
- `SessionEnd` flushes the final interval to the spool (no network inside
  the tight hook budget).

## 0.4.0

- `/novum-tracker:status` reports attribution — where tracked time actually
  goes, not just whether beats send.

## 0.3.0

- Keyless `/novum-tracker:connect` via device pairing (approve a typed code
  in the browser; no API key handling).

## 0.2.0

- Heartbeat claims capped at 600s (matching the server clamp) so AI
  think-time gaps count; `UserPromptSubmit` hook added.

## 0.1.0

- Initial Claude Code plugin: heartbeat hooks + `/novum-tracker:connect`.
