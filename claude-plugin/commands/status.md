---
description: Show Novum Startup tracking liveness (reads local state files; never prints your API key)
allowed-tools: ["Bash(ls:*)", "Bash(grep:*)", "Bash(cat:*)", "Bash(date:*)", "Bash(tail:*)", "Bash(sed:*)", "Bash(wc:*)", "Read"]
---

# Novum tracking status

Report tracking health WITHOUT ever printing secret values. Do not cat or
read `NEONPOD_API_KEY`'s value into the response — check for its presence
only (e.g. `grep -c '^NEONPOD_API_KEY=' ~/.config/neonpod/heartbeat.env`).

1. Config: does `~/.config/neonpod/heartbeat.env` exist? Check its
   permissions are 600 (`ls -l`). Confirm it defines `NEONPOD_API_KEY`
   (presence only) and `NEONPOD_API_URL` (safe to show the URL value).
   Report whether `NEONPOD_TRACK_REMOTES` is set and to what. If the file
   is missing, suggest `/novum-tracker:connect` and stop.
2. **Broken beats idle — check delivery errors FIRST.** For each
   `~/.local/state/neonpod/last-error-*.json` (fields:
   `{status, at, tool, spoolDepth}`): report prominently that deliveries
   are FAILING for that tool — HTTP status, when, and how many beats are
   queued. A present error marker means beats are being recorded but not
   arriving; without it, an old lastFire is just idleness. Queued beats
   retry automatically on the next successful send; nothing is lost
   silently.
3. Liveness: state files are per (tool, checkout) since script 0.5.0 —
   `heartbeat-<tool>-<key>.json` with the tool embedded in the JSON
   (`"tool"` field; pre-0.5.0 files have no suffix and their filename stem
   is the tool). For each tool, take the NEWEST `lastFire` across its
   files (the `-global` file is exactly that) and compute age against
   `date +%s`:
   - `claude-code: last heartbeat 43s ago — tracking` (age < 120s)
   - `codex: last heartbeat 3h ago — idle` (older, and no error marker)
   - `claude-code: no heartbeats yet` (no state files)
4. Spool: if `~/.local/state/neonpod/spool-<tool>.jsonl` exists and is
   non-empty, report `N beats queued for retry` (wc -l). If
   `spool-dropped-<tool>.json` exists, report its `droppedTotal` — beats
   that could NOT be recovered (older than the server's 72h window, or
   permanently rejected) — with `lastDropAt`. Dropped time is gone;
   flag it so the user knows the week's totals may undercount.
5. Attribution — WHERE the time is going, not just that beats send. For each
   `~/.local/state/neonpod/attribution-*.json`, read the JSON
   (`{attributed, reason, folder, at}`) and report the last beat's outcome:
   - `attributed: true` → healthy; mention it in the tool's liveness line.
   - `attributed: false` → **flag this prominently — beats are landing but
     the folder's time counts toward NO project.** Name the folder and
     explain the fix by reason:
     - `remote_unregistered`: the repo isn't registered to a project — a pod
       lead adds its git URL on the project's Settings → Integrations, or
       map the folder yourself at Account → Integrations → "Your coding
       folders" (mapping also claims the time already recorded).
     - `remote_conflict`: the remote is registered on more than one project —
       resolve on the projects' Integrations tabs, or map the folder to pin it.
     - `fingerprint_conflict`: the repo's identity is learned on more than
       one project — map the folder to pin it.
     - `no_project_access`: you aren't a member of the matched project's pod —
       ask a pod lead for access.
     - `tracking_disabled`: the project's IDE-tracking toggle is off.
     - `no_signal`: not a git repo — map the folder as above.
   - `attributed: null` (or file missing) → the server predates attribution
     feedback, or no beat has been sent since updating; skip quietly.
6. **Version drift**: compare the bundled script's version with any config
   copy: `grep -m1 '^SCRIPT_VERSION=' "${CLAUDE_PLUGIN_ROOT}/hooks/heartbeat.sh"`
   vs `grep -m1 '^SCRIPT_VERSION=' ~/.config/neonpod/heartbeat.sh` (the
   Codex copy; may not exist — pre-0.5.0 copies have no SCRIPT_VERSION
   line, which itself means "outdated"). If the config copy is older,
   say so and suggest re-running
   `curl -fsSL <NEONPOD_API_URL>/install/codex.sh | sh` — a stale copy
   once ran unnoticed for three weeks.
7. If something looks wrong (stale ages while actively coding), suggest
   setting `NEONPOD_DEBUG=1` in heartbeat.env and checking
   `tail -5 ~/.local/state/neonpod/heartbeat.log` for skip/fail lines.
   The SessionStart self-check also warns automatically at the next
   session start when tracking is broken.

This command is the desktop-app equivalent of the optional terminal
statusline (the Claude desktop app does not render statuslines).
