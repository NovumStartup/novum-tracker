---
description: Add the current repo to the tracking allowlist (NEONPOD_TRACK_REMOTES) so its coding time records — a no-op when no allowlist is set
allowed-tools: ["Bash(git:*)", "Bash(grep:*)", "Bash(sed:*)", "Bash(ls:*)", "Bash(uname:*)", "Read"]
---

# Track this repo

Add the current repository to `NEONPOD_TRACK_REMOTES` in
`~/.config/neonpod/heartbeat.env` (or `$NEONPOD_CONFIG` if set). The
allowlist is FAIL-CLOSED: when it is set, repos that don't match send no
heartbeats at all — no error, no spool, nothing to recover. This command
exists so adding a repo never means hand-editing an env file.

NEVER print `NEONPOD_API_KEY`'s value, and never cat or Read the whole env
file into the response — operate only on the `NEONPOD_TRACK_REMOTES` line
via `grep` and `sed`.

1. Config exists? `ls ~/.config/neonpod/heartbeat.env`. Missing → suggest
   `/novum-tracker:connect` and stop.
2. The pattern to add: if the user passed an argument, lowercase it and use
   it verbatim. Otherwise derive it from this repo's origin remote:
   ```
   git config --get remote.origin.url | tr '[:upper:]' '[:lower:]' | tr ':' '/' | sed -e 's|\.git$||' -e 's|.*/\([^/]*/[^/]*\)$|\1|'
   ```
   (normalizes ssh and https forms alike to `org/repo`). No git remote and
   no argument → explain that allowlist patterns match git remotes, so a
   folder with no remote can't be allowlisted — with an allowlist set it
   never sends (that is the fail-closed rule) — and stop.
3. Current list: `grep -m1 '^NEONPOD_TRACK_REMOTES=' <config>`. If the line
   is absent or its value empty, there is NO allowlist — every repo already
   tracks; report that and stop (do not create one).
4. Already covered? The heartbeat script treats each space-separated entry
   as a SUBSTRING of the normalized remote. If any existing entry is a
   substring of the normalized remote from step 2 (or equals the pattern),
   report the repo is already tracked and stop.
5. Append the pattern inside the value, preserving the existing entries.
   Use `sed -i` in place (`sed -i ''` on macOS/BSD — check `uname`); an
   in-place edit preserves the file's 600 permissions, which matter because
   the file also holds the API key. Handle both the quoted
   (`NEONPOD_TRACK_REMOTES="a b"`) and unquoted (`NEONPOD_TRACK_REMOTES=a`)
   forms; write the result quoted.
6. Verify: grep the line again and show it (that line carries no secret),
   and confirm the file is still mode 600 (`ls -l`).
7. Tell the user what changes and what doesn't:
   - New heartbeats from this repo start with the next hook event — no
     restart needed (the script re-reads the env on every beat).
   - Beats from BEFORE this change were never sent and cannot be recovered;
     if the lost hours matter, a manual time entry on the project is the
     honest fix.
   - The allowlist only controls SENDING. Attribution to a project still
     needs the repo's remote registered on the project (Settings →
     Integrations) or a folder map — if the next beat lands
     `attributed: false`, run `/novum-tracker:status` for the fix per
     reason.
