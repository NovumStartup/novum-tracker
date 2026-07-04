---
description: Show Novum Startup tracking liveness (reads local state files; never prints your API key)
allowed-tools: ["Bash(ls:*)", "Bash(grep:*)", "Bash(cat:*)", "Bash(date:*)", "Bash(tail:*)", "Read"]
---

# Novum tracking status

Report tracking health WITHOUT ever printing secret values. Do not cat or
read `NEONPOD_API_KEY`'s value into the response — check for its presence
only (e.g. `grep -c '^NEONPOD_API_KEY=' ~/.config/neonpod/heartbeat.env`).

1. Config: does `~/.config/neonpod/heartbeat.env` exist? Check its
   permissions are 600 (`ls -l`). Confirm it defines `NEONPOD_API_KEY`
   (presence only) and `NEONPOD_API_URL` (safe to show the URL value).
   Report whether `NEONPOD_TRACK_REMOTES` is set and to what. If the file
   is missing, suggest `/novum-tracker:connect <key>` and stop.
2. Liveness: for each `~/.local/state/neonpod/heartbeat-*.json`, extract
   `lastFire` (unix seconds) and compute its age against `date +%s`.
   Present one line per tool, e.g.:
   - `claude-code: last heartbeat 43s ago — tracking` (age < 120s)
   - `codex: last heartbeat 3h ago — idle` (older)
   - `claude-code: no heartbeats yet` (no state file)
3. If something looks wrong (stale ages while actively coding), suggest
   setting `NEONPOD_DEBUG=1` in heartbeat.env and checking
   `tail -5 ~/.local/state/neonpod/heartbeat.log` for skip/fail lines.

This command is the desktop-app equivalent of the optional terminal
statusline (the Claude desktop app does not render statuslines).
