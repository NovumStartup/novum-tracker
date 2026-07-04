---
description: Connect Novum Startup time tracking (writes ~/.config/neonpod/heartbeat.env and verifies with a test heartbeat)
argument-hint: <api-key> [api-url]
allowed-tools: ["Bash(mkdir:*)", "Bash(chmod:*)", "Bash(mv:*)", "Bash(printf:*)", "Bash(grep:*)", "Bash(tail:*)", "Bash(env:*)", "Bash(ls:*)", "Read"]
---

# Connect Novum Startup tracking

Arguments: `$ARGUMENTS` — the first token is the API key (starts with `cf_`,
minted on Account → Integrations → "AI coding tools" at novumstartup.com);
the optional second token is the API URL (default `https://novumstartup.com`).

Follow these steps exactly. NEVER echo the full API key back into the
conversation — when referring to it, show only the `cf_` prefix and the last
4 characters.

1. Validate: the key must start with `cf_`. If it is missing or malformed,
   stop and tell the user to mint one on the Account → Integrations page
   ("AI coding tools" → Generate key) and re-run
   `/novum-tracker:connect <key>`.
2. Run `mkdir -p ~/.config/neonpod`.
3. Write `~/.config/neonpod/heartbeat.env`:
   - If it already exists: PRESERVE every line that is not
     `NEONPOD_API_KEY=…` or `NEONPOD_API_URL=…` (users keep settings like
     `NEONPOD_TRACK_REMOTES` or `NEONPOD_DEBUG` there). Build the new
     content in a temp file in the same directory, then `mv` it into place.
   - If it does not exist, create it with exactly two lines:
     `NEONPOD_API_KEY=<key>` and `NEONPOD_API_URL=<url>`.
4. Run `chmod 600 ~/.config/neonpod/heartbeat.env`.
5. Verify with a one-shot forced heartbeat:
   `env NEONPOD_TOOL_ID=claude-code NEONPOD_FORCE_FLUSH=1 NEONPOD_DEBUG=1 "${CLAUDE_PLUGIN_ROOT}/hooks/heartbeat.sh" </dev/null`
   then read the last line of `~/.local/state/neonpod/heartbeat.log`:
   - `ok status=200` → connected. Tell the user tracking is live and that
     the Tracking status strip on Account → Integrations shows a green dot
     within a minute of coding.
   - `fail status=401` → the key is wrong or revoked; mint a new one.
   - `fail status=000` → network problem or wrong URL; check the second
     argument.
   - a `skip: … allowlist` line → `NEONPOD_TRACK_REMOTES` is set and the
     current directory is not a tracked repo; the config is still written
     correctly — suggest re-running the verify step from a tracked repo.
6. Migration check: `grep -n "neonpod\|heartbeat" ~/.claude/settings.json`
   (the file may not exist — that's fine). If legacy `PostToolUse`/`Stop`
   hook entries reference a neonpod heartbeat or guard script, tell the user
   the plugin now handles those events and offer to remove the two legacy
   entries (leave any `statusLine` entry untouched — it reads state files,
   not hooks). Double-firing is harmless (shared debounce; the server merges
   overlapping intervals) but noisy.
7. Mention once, briefly: repos can be scoped with
   `NEONPOD_TRACK_REMOTES="org/repo other-org/"` in the same env file, and
   `/novum-tracker:status` reports tracking liveness anytime.
