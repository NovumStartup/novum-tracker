---
description: Connect Novum Startup time tracking (device pairing by default — approve a code in your browser; writes ~/.config/neonpod/heartbeat.env and verifies with a test heartbeat)
argument-hint: "[api-key] [api-url]"
allowed-tools: ["Bash(sh:*)", "Bash(mkdir:*)", "Bash(chmod:*)", "Bash(mv:*)", "Bash(printf:*)", "Bash(grep:*)", "Bash(tail:*)", "Bash(env:*)", "Bash(ls:*)", "Read"]
---

# Connect Novum Startup tracking

Arguments: `$ARGUMENTS`. Pick the mode from the FIRST token:

- **No arguments** → device pairing against `https://novumstartup.com` (the
  default — no key needed).
- First token starts with `http` → device pairing against that URL
  (self-hosted instances).
- First token starts with `cf_` → keyed connect with that API key; the
  optional second token is the API URL (default `https://novumstartup.com`).
- Anything else → stop and explain the three forms above.

NEVER echo a full API key into the conversation — when referring to one,
show only the `cf_` prefix and the last 4 characters. (Pairing codes like
`NVM-XXXX-XXXX` are fine to show — they are useless without the user's own
logged-in browser session.)

## Device pairing (default)

1. Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/pair.sh" start` — append
   `--url <url>` only if the user gave an instance URL. The output contains
   `code:` and `approve-at:` lines.
2. Relay them to the user PROMINENTLY before doing anything else, e.g.:

   > Your pairing code is **NVM-XXXX-XXXX**
   > Approve it at https://novumstartup.com/connect (log in, type the code)

   Tell them the code expires in ~10 minutes and that the /connect page
   only accepts typed codes — never trust a link that claims to carry one.
3. Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/pair.sh" wait` with the Bash tool
   timeout set to 600000 ms (it blocks until the user approves in the
   browser). While it waits, the user approves; on approval the script
   writes `~/.config/neonpod/heartbeat.env` itself (the key never enters
   this conversation) and sends a one-shot test heartbeat.
4. Interpret the outcome:
   - Final log line `ok status=200` → connected. Tell the user tracking is
     live and the Tracking status strip on Account → Integrations shows a
     green dot within a minute of coding.
   - `failed: denied` → they denied it in the browser; nothing was written.
   - `failed: key_limit` → they already have 5 API keys — revoke one on
     Account → Integrations, then re-run `/novum-tracker:connect`.
   - `failed: timeout` or `failed: expired` → the code lapsed; re-run for a
     fresh one.
   - A `skip: … allowlist` line instead of `ok` → `NEONPOD_TRACK_REMOTES`
     is set and the current directory isn't a tracked repo; the config is
     still written correctly — suggest re-verifying from a tracked repo.
5. Continue with **After connecting** below.

## Keyed connect (`cf_…` given — CI or manual key)

1. Run `mkdir -p ~/.config/neonpod`.
2. Write `~/.config/neonpod/heartbeat.env`:
   - If it already exists: PRESERVE every line that is not
     `NEONPOD_API_KEY=…` or `NEONPOD_API_URL=…` (users keep settings like
     `NEONPOD_TRACK_REMOTES` or `NEONPOD_DEBUG` there). Build the new
     content in a temp file in the same directory, then `mv` it into place.
   - If it does not exist, create it with exactly two lines:
     `NEONPOD_API_KEY=<key>` and `NEONPOD_API_URL=<url>`.
3. Run `chmod 600 ~/.config/neonpod/heartbeat.env`.
4. Verify with a one-shot forced heartbeat:
   `env NEONPOD_TOOL_ID=claude-code NEONPOD_FORCE_FLUSH=1 NEONPOD_DEBUG=1 "${CLAUDE_PLUGIN_ROOT}/hooks/heartbeat.sh" </dev/null`
   then read the last line of `~/.local/state/neonpod/heartbeat.log`:
   - `ok status=200` → connected (same message as pairing step 4).
   - `fail status=401` → the key is wrong or revoked; mint a new one or
     just re-run `/novum-tracker:connect` with no arguments to pair.
   - `fail status=000` → network problem or wrong URL; check the URL
     argument.
   - a `skip: … allowlist` line → see pairing step 4.
5. Continue with **After connecting** below.

## After connecting (both modes)

- Migration check: `grep -n "neonpod\|heartbeat" ~/.claude/settings.json`
  (the file may not exist — that's fine). If legacy `PostToolUse`/`Stop`
  hook entries reference a neonpod heartbeat or guard script, tell the user
  the plugin now handles those events and offer to remove the two legacy
  entries (leave any `statusLine` entry untouched — it reads state files,
  not hooks). Double-firing is harmless (shared debounce; the server merges
  overlapping intervals) but noisy.
- Mention once, briefly: repos can be scoped with
  `NEONPOD_TRACK_REMOTES="org/repo other-org/"` in the same env file, and
  `/novum-tracker:status` reports tracking liveness anytime.
