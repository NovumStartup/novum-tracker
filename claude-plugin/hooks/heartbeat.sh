#!/bin/sh
# hooks/heartbeat.sh (novum-tracker Claude Code plugin)
#
# UPSTREAM: chronoforge scripts/coding-tool-heartbeat.sh — do not edit here.
# Sync: copy verbatim from chronoforge on each plugin release (see the
# release checklist in ../README.md), then bump plugin.json +
# ../.claude-plugin/marketplace.json versions.
#
# Posts a single coding-time heartbeat to NovumStartup's /api/ide/heartbeat
# endpoint from an AI coding tool's hook event (Claude Code / Codex
# PostToolUse + UserPromptSubmit + Stop, plus CwdChanged / DirectoryAdded /
# SessionEnd where the tool has them). Mirrors the payload shape the
# VS Code extension uses (now the standalone novum-tracker extension) so the
# existing aggregator at src/lib/ide/aggregate-heartbeats.ts rolls these up
# alongside human IDE heartbeats.
#
# Required env:
#   NEONPOD_TOOL_ID    — editor value (e.g. "claude-code", "codex")
#   NEONPOD_API_KEY    — UserApiKey from the NeonPod dashboard
#   NEONPOD_API_URL    — e.g. https://neonpod.example
#
# Optional env:
#   NEONPOD_CONFIG        — path to env file to source (default: ~/.config/neonpod/heartbeat.env)
#   NEONPOD_FORCE_FLUSH   — "1" to bypass the debounce window (use on Stop hook)
#   NEONPOD_LOCAL_ONLY    — "1" to append the beat to the offline spool and
#                           send NOTHING (for SessionEnd, whose hook budget
#                           may be too small for a network call; the spool
#                           drains on the next successful send)
#   NEONPOD_DEBUG         — "1" to append diagnostic lines to the log file
#   NEONPOD_CWD           — override the workspace root (beats hook stdin cwd)
#   NEONPOD_TRACK_REMOTES — space-separated substrings; when set, ONLY repos
#                           whose git origin remote matches one (lowercased,
#                           ':' normalized to '/') send heartbeats. Fail-closed
#                           while set: non-git dirs and non-matching remotes
#                           send nothing. Unset = track everything (default).
#                           Quote multi-pattern values in heartbeat.env.
#
# The script always exits 0 so a transient API outage cannot interrupt
# the operator's coding session.

set -u
trap 'exit 0' INT TERM HUP
# EXIT (not just signals): a host hook timeout that kills the script mid-curl
# must not strand the per-PID temp files — one of them holds the API key.
# STATE_DIR is defined below; the trap only fires at exit, after it exists.
# ${STATE_DIR:-}: the trap body runs under set -u, and a signal arriving
# before STATE_DIR is assigned would otherwise make the EXIT trap itself
# fail — a nonzero exit is Claude Code's BLOCKING code on UserPromptSubmit.
trap '[ -n "${STATE_DIR:-}" ] && rm -f "$STATE_DIR/.curl-headers-$$" "$STATE_DIR/.live-resp-$$" "$STATE_DIR/.drain-resp-$$" 2>/dev/null || true' EXIT

# Everything this script creates is private: the spool persists FULL payloads
# (a git remote URL can embed a credential), and state/log files carry repo
# metadata. New files land 0600 / dirs 0700; the state dir itself is
# re-tightened on every run because redirection onto an existing file keeps
# its old mode.
umask 077

# Version of THIS script, reported as clientVersion on every beat. The server
# stores it per heartbeat and GET /api/ide/health advertises a minimum — the
# remote answer to the stale-copy drift class (a July script ran unnoticed on
# Codex for ~3 weeks because nothing reported which version was sending).
SCRIPT_VERSION="0.5.1"

DEBUG="${NEONPOD_DEBUG:-0}"
TOOL_ID="${NEONPOD_TOOL_ID:-other}"
FORCE_FLUSH="${NEONPOD_FORCE_FLUSH:-0}"
LOCAL_ONLY="${NEONPOD_LOCAL_ONLY:-0}"

# Source the user-edited config DEFENSIVELY. Under `set -u` a config line
# referencing an unset variable — or, on dash, an unterminated quote (the
# header invites quoting NEONPOD_TRACK_REMOTES) — aborts the whole script
# with a NON-ZERO exit the INT/TERM/HUP trap cannot catch. Exit 2 from a
# UserPromptSubmit hook is Claude Code's BLOCKING code: a typo'd env file
# would block and erase the user's prompt on every submission. So: parse the
# file in a throwaway subshell first; only a file that survives is sourced
# for real, with -u relaxed around the source.
CONFIG_FILE="${NEONPOD_CONFIG:-$HOME/.config/neonpod/heartbeat.env}"
if [ -f "$CONFIG_FILE" ]; then
  if ( set +u; . "$CONFIG_FILE" ) >/dev/null 2>&1; then
    set +u
    # shellcheck disable=SC1090
    set -a; . "$CONFIG_FILE"; set +a
    set -u
  fi
fi

API_KEY="${NEONPOD_API_KEY:-}"
API_URL="${NEONPOD_API_URL:-}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/neonpod"
LOG_FILE="$STATE_DIR/heartbeat.log"
SPOOL_FILE="$STATE_DIR/spool-$TOOL_ID.jsonl"
ERROR_FILE="$STATE_DIR/last-error-$TOOL_ID.json"
DROPPED_FILE="$STATE_DIR/spool-dropped-$TOOL_ID.json"

# Spool bounds. MAX_SPOOL_AGE stays one hour inside the server's 72h ingest
# window so a drained beat is never rejected purely for age; drops are counted
# in $DROPPED_FILE — silent data loss is the exact failure this spool exists
# to end, so losing beats must itself be visible.
MAX_SPOOL_AGE_SECONDS=255600
MAX_SPOOL_LINES=500
DRAIN_BATCH=10

log() {
  [ "$DEBUG" = "1" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '[%s] [%s] %s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$TOOL_ID" \
    "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# Hook handlers pipe event JSON on stdin. Drain it FULLY (a partial read can
# EPIPE the host writing a large tool_input) while keeping only the head, and
# extract the identity fields: session_id correlates beats into sessions
# server-side, and cwd is the AUTHORITATIVE working directory — $PWD is wrong
# after an in-session `cd`, and CwdChanged / DirectoryAdded events exist
# precisely because the directory moved.
#
# Extraction is deliberately paranoid about big tool payloads: everything
# from the first "tool_input" on is cut away (a Bash tool call legitimately
# contains its own "cwd", and POSIX sed is greedy — `.*"cwd"` would match the
# LAST occurrence), then the remainder is split on commas/braces so the FIRST
# top-level match wins. Values containing a comma truncate and degrade
# (cwd falls back to $PWD via the -d check; session_id is a UUID).
HOOK_INPUT=""
if [ ! -t 0 ]; then
  HOOK_INPUT=$({ head -c 65536; cat >/dev/null; } 2>/dev/null || true)
fi
HOOK_HEAD=${HOOK_INPUT%%\"tool_input\"*}
hook_field() {
  printf '%s' "$HOOK_HEAD" \
    | tr ',{' '\n\n' \
    | sed -n 's/^[[:space:]]*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}
SESSION_ID=$(hook_field session_id)
HOOK_CWD=$(hook_field cwd)

if [ -z "$API_KEY" ]; then log "skip: NEONPOD_API_KEY not set"; exit 0; fi
if [ -z "$API_URL" ]; then log "skip: NEONPOD_API_URL not set"; exit 0; fi

# Workspace root precedence: explicit override, then the hook's own cwd,
# then the process cwd.
CWD="${NEONPOD_CWD:-}"
if [ -z "$CWD" ] && [ -n "$HOOK_CWD" ] && [ -d "$HOOK_CWD" ]; then
  CWD="$HOOK_CWD"
fi
[ -z "$CWD" ] && CWD="$PWD"
if [ ! -d "$CWD" ]; then
  # Deliberately no path in the log line — raw filesystem paths stay out of
  # every file this script writes.
  log "skip: cwd is not a directory"
  exit 0
fi

# Optional repo allowlist — see NEONPOD_TRACK_REMOTES in the header. Checked
# before the debounce so filtered repos never touch a state file. (The
# SessionStart self-check surfaces this skip in-session — a typo here used to
# be indistinguishable from idle.)
ALLOW="${NEONPOD_TRACK_REMOTES:-}"
if [ -n "$ALLOW" ]; then
  ALLOW_REMOTE=$(git -C "$CWD" config --get remote.origin.url 2>/dev/null || true)
  if [ -z "$ALLOW_REMOTE" ]; then
    log "skip: allowlist active, no git origin remote"
    exit 0
  fi
  # Normalize so ssh (git@host:org/repo.git) and https forms both match a
  # lowercase "org/repo" substring pattern.
  ALLOW_NORMALIZED=$(printf '%s' "$ALLOW_REMOTE" | tr '[:upper:]' '[:lower:]' | tr ':' '/')
  ALLOW_MATCH=0
  # set -f: the unquoted word split must not pathname-expand — a pattern like
  # `org/*` would otherwise be replaced by matching local file names.
  set -f
  for ALLOW_PATTERN in $ALLOW; do
    case "$ALLOW_NORMALIZED" in
      *"$ALLOW_PATTERN"*) ALLOW_MATCH=1; break ;;
    esac
  done
  set +f
  if [ "$ALLOW_MATCH" = "0" ]; then
    # No remote URL in the log — an https remote can embed a credential.
    log "skip: remote not in allowlist"
    exit 0
  fi
fi

DEBOUNCE_SECONDS=60
MIN_DURATION_SECONDS=60
# Cap the per-heartbeat duration at 10 min (the server's own ingest clamp).
# AI-assisted sessions legitimately pause while the operator reads output and
# writes the next prompt — no hook fires during that window, so gaps up to the
# cap count as working time. Anything longer reads as stepping away.
MAX_DURATION_SECONDS=600

mkdir -p "$STATE_DIR" 2>/dev/null || true
# Re-tighten on every run: umask covers new files, but files that predate
# this version keep their old world-readable mode — a 0700 dir denies
# traversal regardless.
chmod 700 "$STATE_DIR" 2>/dev/null || true

# Git introspection — silent failures yield null fields. `git -C` avoids
# changing the script's own cwd.
git_field() {
  git -C "$CWD" "$@" 2>/dev/null
}

# First 16 hex chars of the SHA-256 of stdin; prints nothing if no hashing
# tool is available. Every candidate is `command -v`-guarded because a
# GUI-launched editor does not inherit a Homebrew PATH, and shasum/sha256sum
# come first for exactly that reason.
#
# The sed extractor pulls the 64-hex run out of ANY of the three output
# formats: `shasum`/`sha256sum` print "<hash>  -", LibreSSL prints the bare
# hash, and OpenSSL 3 prints "SHA2-256(stdin)= <hash>". `cut -d' ' -f1` and
# `tr -dc '0-9a-f'` both silently corrupt that last one.
sha256_16() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 2>/dev/null
  else
    return 0
  fi | sed -n 's/.*\([0-9a-f]\{64\}\).*/\1/p' | head -n 1 | cut -c1-16
}

# Random UUID, lowercased; falls back through the kernel and od so a machine
# without uuidgen still gets real entropy (eventId collisions are scoped to
# this user by the server's (userId, eventId) unique, but weak ids would
# still self-collide across this machine's own beats).
uuid_gen() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid 2>/dev/null
  else
    od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
  fi
}

# Identifies THIS CHECKOUT, so two clones that share a basename stop
# colliding in the folder mapper. The root path is hashed and immediately
# discarded — it must never reach the payload, the log, or a state file name
# in the clear. `printf '%s'` rather than `echo`: a trailing newline would
# change the digest. Computed BEFORE the debounce because the state file is
# keyed on it (the call is ~8ms).
REPO_ROOT=$(git_field rev-parse --show-toplevel || true)
REPO_KEY=""
if [ -n "$REPO_ROOT" ]; then
  REPO_KEY=$(printf '%s' "$REPO_ROOT" | sha256_16)
fi
unset REPO_ROOT

# Debounce/duration state is PER (tool, checkout), not per tool. One shared
# file meant two concurrent sessions in different repos stole each other's
# lastFire: the second repo's beat was debounced away, and the survivor's
# duration covered wall-clock spent in the OTHER repo — misattributed time.
# Non-git folders key on a hash of the cwd instead; the embedded "tool" and
# "folder" fields are what readers (statusline, status skill) should use —
# never the filename.
if [ -n "$REPO_KEY" ]; then
  STATE_FILE="$STATE_DIR/heartbeat-$TOOL_ID-$REPO_KEY.json"
else
  CWD_KEY=$(printf '%s' "$CWD" | sha256_16)
  [ -z "$CWD_KEY" ] && CWD_KEY="nogit"
  STATE_FILE="$STATE_DIR/heartbeat-$TOOL_ID-cwd$CWD_KEY.json"
fi

read_last_fire() {
  # $1 = state file; prints the stored epoch or 0.
  RLF=0
  if [ -f "$1" ]; then
    RLF=$(sed -n 's/.*"lastFire"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -n 1)
    [ -z "$RLF" ] && RLF=0
  fi
  printf '%s' "$RLF"
}

NOW=$(date +%s)
LAST_FIRE=$(read_last_fire "$STATE_FILE")

if [ "$LAST_FIRE" = "0" ]; then
  ELAPSED=0
else
  ELAPSED=$((NOW - LAST_FIRE))
fi

if [ "$FORCE_FLUSH" != "1" ] && [ "$LAST_FIRE" != "0" ] && [ "$ELAPSED" -lt "$DEBOUNCE_SECONDS" ]; then
  log "debounce: elapsed=${ELAPSED}s < ${DEBOUNCE_SECONDS}s"
  exit 0
fi

if [ "$LAST_FIRE" = "0" ]; then
  DURATION=$MIN_DURATION_SECONDS
else
  DURATION=$ELAPSED
  if [ "$DURATION" -gt "$MAX_DURATION_SECONDS" ]; then DURATION=$MAX_DURATION_SECONDS; fi
fi

# Wall-clock CONSERVATION clamp. Debounce/attribution state is per checkout,
# but a tool still has only ONE clock: without this, two concurrent sessions
# in different repos would each claim the full wall-clock span (banking 2x),
# and returning to a repo after 15 min elsewhere would claim 600s that the
# other repo's beats already own. Clamping the backward claim to the elapsed
# time since this tool's LAST BEAT ANYWHERE partitions wall-clock between
# repos instead of multiplying it — attribution stays per checkout, totals
# stay ≤1x per tool. The MIN floor is applied after the clamp (bounded ≤60s
# overlap per switch — the same magnitude as the first-beat floor that has
# always existed; the server's per-user merge absorbs it within a project).
GLOBAL_FILE="$STATE_DIR/heartbeat-$TOOL_ID-global.json"
GLOBAL_LAST=$(read_last_fire "$GLOBAL_FILE")
if [ "$GLOBAL_LAST" != "0" ]; then
  GLOBAL_ELAPSED=$((NOW - GLOBAL_LAST))
  [ "$GLOBAL_ELAPSED" -lt 0 ] && GLOBAL_ELAPSED=0
  if [ "$GLOBAL_ELAPSED" -lt "$DURATION" ]; then DURATION=$GLOBAL_ELAPSED; fi
fi
if [ "$DURATION" -lt "$MIN_DURATION_SECONDS" ]; then DURATION=$MIN_DURATION_SECONDS; fi

BRANCH=$(git_field rev-parse --abbrev-ref HEAD || true)
REMOTE_URL=$(git_field config --get remote.origin.url || true)
COMMIT_HASH=$(git_field rev-parse HEAD || true)
COMMIT_EMAIL=$(git_field log -1 --format=%ae || true)

WORKSPACE_FOLDER=$(basename "$CWD" 2>/dev/null || printf 'workspace')

# The repo's root commit — the same object in every clone, worktree and fork,
# and unchanged by an org rename or a repo transfer, all of which break the
# remote URL. The server keeps only an HMAC of it.
#
# A SHALLOW clone must send nothing: `rev-list --max-parents=0` returns the
# grafted boundary commit there, which is stable per machine and plausible and
# WRONG — the one failure mode that could attribute one repo's time to another.
# Sending null just falls back to the remote and folder-map paths.
#
# NOT cached, deliberately. Caching this by checkout path was tried and is
# unsafe: `rm -rf ~/dev/api && git clone <other repo> ~/dev/api` reuses the
# path, so the cache would keep serving the OLD repo's root commit and bind a
# second repo's time to the first repo's project — the same plausible-and-wrong
# mis-match the shallow guard above exists to prevent. The walk is O(history),
# but the 60s debounce above means it runs at most once a minute per tool —
# and LOCAL_ONLY (SessionEnd) skips it entirely to stay inside a tight hook
# budget; the spooled beat just falls back to the remote path.
#
# `sort | head -1` picks deterministically when a grafted history has several
# root commits — the SET is identical in every clone, so all clients agree.
ROOT_COMMIT=""
if [ "$LOCAL_ONLY" != "1" ] && [ -n "$REPO_KEY" ] && [ "$(git_field rev-parse --is-shallow-repository || true)" = "false" ]; then
  ROOT_COMMIT=$(git_field rev-list --max-parents=0 HEAD | sort | head -n 1)
fi

# Random installation id (never the hostname or anything derived from it —
# hostnames rename, collide, and dictionary-reverse). Minted once, 0600.
INSTALL_ID_FILE="$STATE_DIR/installation-id"
MACHINE_ID=""
if [ -f "$INSTALL_ID_FILE" ]; then
  MACHINE_ID=$(head -n 1 "$INSTALL_ID_FILE" 2>/dev/null | tr -cd 'a-f0-9-' | cut -c1-64)
fi
if [ -z "$MACHINE_ID" ]; then
  MACHINE_ID=$(uuid_gen)
  if [ -n "$MACHINE_ID" ]; then
    umask 077
    printf '%s\n' "$MACHINE_ID" > "$INSTALL_ID_FILE" 2>/dev/null || true
  fi
fi

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EVENT_ID=$(uuid_gen)

# JSON helper: emits a JSON string literal (escaped) or the bare literal
# `null` when empty. Strips ALL C0 control bytes (including \r \n \t)
# because none of the heartbeat string fields legitimately carry them
# and unescaped control chars would yield invalid JSON the server's
# req.json() parse would 400 on.
json_str_or_null() {
  if [ -z "$1" ]; then
    printf 'null'
    return
  fi
  printf '"%s"' "$(printf '%s' "$1" \
    | tr -d '[:cntrl:]' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

PAYLOAD=$(printf '{"editor":%s,"language":null,"file":null,"branch":%s,"workspaceFolder":%s,"duration":%s,"timestamp":%s,"gitRemoteUrl":%s,"commitHash":%s,"commitAuthorEmail":%s,"repoKey":%s,"rootCommit":%s,"eventId":%s,"sessionId":%s,"clientVersion":%s,"machineId":%s}' \
  "$(json_str_or_null "$TOOL_ID")" \
  "$(json_str_or_null "$BRANCH")" \
  "$(json_str_or_null "$WORKSPACE_FOLDER")" \
  "$DURATION" \
  "$(json_str_or_null "$TIMESTAMP")" \
  "$(json_str_or_null "$REMOTE_URL")" \
  "$(json_str_or_null "$COMMIT_HASH")" \
  "$(json_str_or_null "$COMMIT_EMAIL")" \
  "$(json_str_or_null "$REPO_KEY")" \
  "$(json_str_or_null "$ROOT_COMMIT")" \
  "$(json_str_or_null "$EVENT_ID")" \
  "$(json_str_or_null "$SESSION_ID")" \
  "$(json_str_or_null "$SCRIPT_VERSION")" \
  "$(json_str_or_null "$MACHINE_ID")")

API_URL_CLEAN="${API_URL%/}"

# ---- offline spool ---------------------------------------------------------
#
# A beat that cannot be delivered is APPENDED here (epoch-prefixed for cheap
# age math), and lastFire STILL advances — the spooled beat owns its interval,
# so the next live beat must not re-claim the same span. Each line carries its
# own eventId, which the server dedupes per user, so a retry after a
# timed-out-but-committed send acknowledges as a duplicate instead of
# double-storing. The spool drains only after a SUCCESSFUL live send (network
# provably up), oldest first, a bounded batch per run.

advance_last_fire() {
  # Per-checkout clock (debounce + duration base) AND the per-tool global
  # clock (the conservation clamp) advance together.
  printf '{"lastFire":%s,"tool":%s,"folder":%s}\n' \
    "$NOW" "$(json_str_or_null "$TOOL_ID")" "$(json_str_or_null "$WORKSPACE_FOLDER")" \
    > "$STATE_FILE" 2>/dev/null || true
  printf '{"lastFire":%s,"tool":%s}\n' \
    "$NOW" "$(json_str_or_null "$TOOL_ID")" \
    > "$GLOBAL_FILE" 2>/dev/null || true
}

count_dropped() {
  # $1 = how many beats were just dropped (age/overflow/permanent rejection)
  PREV=0
  if [ -f "$DROPPED_FILE" ]; then
    PREV=$(sed -n 's/.*"droppedTotal"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DROPPED_FILE" 2>/dev/null | head -n 1)
    [ -z "$PREV" ] && PREV=0
  fi
  printf '{"droppedTotal":%s,"lastDropAt":"%s","tool":%s}\n' \
    "$((PREV + $1))" "$TIMESTAMP" "$(json_str_or_null "$TOOL_ID")" \
    > "$DROPPED_FILE" 2>/dev/null || true
}

spool_append() {
  printf '%s %s\n' "$NOW" "$PAYLOAD" >> "$SPOOL_FILE" 2>/dev/null || true
  # Bound the spool visibly: overflow drops the OLDEST lines and counts them.
  LINES=$(wc -l < "$SPOOL_FILE" 2>/dev/null | tr -d ' ')
  [ -z "$LINES" ] && LINES=0
  if [ "$LINES" -gt "$MAX_SPOOL_LINES" ]; then
    OVERFLOW=$((LINES - MAX_SPOOL_LINES))
    TMP_SPOOL="$SPOOL_FILE.trim.$$"
    tail -n "$MAX_SPOOL_LINES" "$SPOOL_FILE" > "$TMP_SPOOL" 2>/dev/null \
      && mv "$TMP_SPOOL" "$SPOOL_FILE" 2>/dev/null \
      && count_dropped "$OVERFLOW"
    rm -f "$TMP_SPOOL" 2>/dev/null || true
  fi
}

post_payload() {
  # $1 = payload, $2 = response file. Prints the HTTP status ("000" on
  # transport failure). Pipe via stdin (--data-binary @-) instead of --data:
  # the latter treats a leading '@' as a filename, which could break for an
  # unusual branch / workspace name starting with '@'. The API key rides in
  # a 0600 header FILE (-H @file), never in argv — process argv is readable
  # by other local users via ps for the full life of the curl.
  STATUS=$(printf '%s' "$1" | curl -sS -o "$2" -w '%{http_code}' \
    -X POST "${API_URL_CLEAN}/api/ide/heartbeat" \
    -H 'Content-Type: application/json' \
    -H "@$HEADER_FILE" \
    --max-time 10 \
    --data-binary @- 2>>"$CURL_ERR") || true
  [ -z "$STATUS" ] && STATUS=000
  printf '%s' "$STATUS"
}

make_header_file() {
  HEADER_FILE="$STATE_DIR/.curl-headers-$$"
  printf 'X-API-Key: %s\n' "$API_KEY" > "$HEADER_FILE" 2>/dev/null || true
}

cleanup_header_file() {
  rm -f "$HEADER_FILE" 2>/dev/null || true
}

reclaim_orphans() {
  # A drainer killed mid-loop (host hook timeout, laptop sleep, shutdown)
  # leaves its mv-claimed file behind with every unsent beat inside — the
  # exact silent loss this spool exists to end. Sweep stale claims back into
  # the live spool. Age-gated (>10 min) so an ACTIVE drainer's claim is
  # never stolen; beats it already posted before dying re-send and the
  # server's per-user eventId dedupe ACKs them as duplicates — at-least-once
  # locally, exactly-once at the ledger.
  for ORPHAN in "$SPOOL_FILE".draining.*; do
    [ -f "$ORPHAN" ] || continue
    # Age from the FILENAME epoch (claim names end .<pid>.<epoch>), never
    # mtime: rename(2) preserves mtime, so a spool that sat quiet >10 min
    # before draining looked "stale" the moment it was claimed, and a second
    # window robbed the ACTIVE drainer this gate exists to protect.
    ORPHAN_EPOCH=${ORPHAN##*.}
    case "$ORPHAN_EPOCH" in ''|*[!0-9]*) ORPHAN_EPOCH=0 ;; esac
    if [ "$ORPHAN_EPOCH" -eq 0 ] || [ $((NOW - ORPHAN_EPOCH)) -gt 600 ]; then
      cat "$ORPHAN" >> "$SPOOL_FILE" 2>/dev/null && rm -f "$ORPHAN" 2>/dev/null
    fi
  done
  return 0
}

drain_spool() {
  reclaim_orphans
  [ -f "$SPOOL_FILE" ] || return 0
  # mv-claim: atomically take the whole file so a concurrent drainer skips
  # (macOS has no flock(1)). New failures append to a fresh live spool. The
  # claim name carries $$ AND the epoch so a recycled PID after reboot can
  # never mv onto an existing orphan and destroy it; a killed drain leaves
  # the claim behind for reclaim_orphans above.
  CLAIM="$SPOOL_FILE.draining.$$.$NOW"
  mv "$SPOOL_FILE" "$CLAIM" 2>/dev/null || return 0
  DRAINED=0
  DROPPED=0
  LINE_NO=0
  TRANSIENT=0
  DRAIN_RESP="$STATE_DIR/.drain-resp-$$"
  while IFS= read -r SPOOL_LINE || [ -n "$SPOOL_LINE" ]; do
    LINE_NO=$((LINE_NO + 1))
    if [ "$TRANSIENT" = "1" ] || [ "$LINE_NO" -gt "$DRAIN_BATCH" ]; then
      # Remainder goes back to the live spool for the next drain.
      printf '%s\n' "$SPOOL_LINE" >> "$SPOOL_FILE" 2>/dev/null || true
      continue
    fi
    LINE_EPOCH=${SPOOL_LINE%% *}
    LINE_PAYLOAD=${SPOOL_LINE#* }
    case "$LINE_EPOCH" in
      ''|*[!0-9]*) DROPPED=$((DROPPED + 1)); continue ;;
    esac
    if [ $((NOW - LINE_EPOCH)) -gt "$MAX_SPOOL_AGE_SECONDS" ]; then
      DROPPED=$((DROPPED + 1))
      continue
    fi
    DRAIN_STATUS=$(post_payload "$LINE_PAYLOAD" "$DRAIN_RESP")
    case "$DRAIN_STATUS" in
      2*) DRAINED=$((DRAINED + 1)) ;;
      429|408|5*|000)
        # Transient — put it back and stop burning the batch on a down API;
        # every later line rides straight back to the live spool.
        printf '%s\n' "$SPOOL_LINE" >> "$SPOOL_FILE" 2>/dev/null || true
        TRANSIENT=1
        ;;
      *)
        # Permanent rejection (validation, revoked key mid-drain, …): count
        # it as lost rather than retrying forever.
        DROPPED=$((DROPPED + 1))
        ;;
    esac
  done < "$CLAIM"
  rm -f "$CLAIM" "$DRAIN_RESP" 2>/dev/null || true
  if [ "$DROPPED" -gt 0 ]; then
    count_dropped "$DROPPED"
  fi
  if [ "$DRAINED" -gt 0 ] || [ "$DROPPED" -gt 0 ]; then
    log "drain: sent=$DRAINED dropped=$DROPPED"
  fi
  return 0
}

spool_depth() {
  DEPTH=""
  if [ -f "$SPOOL_FILE" ]; then
    DEPTH=$(wc -l < "$SPOOL_FILE" 2>/dev/null | tr -d ' ')
  fi
  case "$DEPTH" in
    ''|*[!0-9]*) DEPTH=0 ;;
  esac
  printf '%s' "$DEPTH"
}

# ---- send (or spool, in LOCAL_ONLY mode) -----------------------------------

if [ "$DEBUG" = "1" ]; then
  CURL_ERR="$LOG_FILE"
else
  CURL_ERR="/dev/null"
fi

if [ "$LOCAL_ONLY" = "1" ]; then
  # SessionEnd path: durability without a network dependency. The final
  # interval is spooled with its own eventId and drains on the next
  # successful send from any session.
  spool_append
  advance_last_fire
  log "local-only: spooled duration=${DURATION}s depth=$(spool_depth)"
  exit 0
fi

# Per-PROCESS response file: concurrent same-tool runs in different repos are
# the supported normal case now, and a shared file let one run parse the
# OTHER run's verdict into its attribution marker. The canonical
# last-response-<tool>.json the status skill reads is refreshed via mv
# (atomic) after parsing.
RESP_FILE="$STATE_DIR/.live-resp-$$"
CANONICAL_RESP="$STATE_DIR/last-response-$TOOL_ID.json"

make_header_file
HTTP_STATUS=$(post_payload "$PAYLOAD" "$RESP_FILE")

# Attribution feedback (server ≥ the attributed-response deploy; older servers
# just return {"ok":true} and both fields stay "unknown"). The marker file is
# what `/novum-tracker:status` and the installers read to say WHERE time is
# going — a 200 with attributed=false means the beat landed but counts toward
# no project. A replay ACK carries reason "duplicate"; it is NOT a fresh
# attribution verdict, so it must never overwrite the marker.
ATTRIBUTED=unknown
REASON=unknown
RESP_BODY=$(cat "$RESP_FILE" 2>/dev/null || true)
mv "$RESP_FILE" "$CANONICAL_RESP" 2>/dev/null || rm -f "$RESP_FILE" 2>/dev/null || true
case "$RESP_BODY" in
  *'"attributed":true'*) ATTRIBUTED=true ;;
  *'"attributed":false'*) ATTRIBUTED=false ;;
esac
case "$RESP_BODY" in
  *'"reason":"'*)
    REASON=$(printf '%s' "$RESP_BODY" | sed -n 's/.*"reason":"\([a-z_][a-z_]*\)".*/\1/p')
    [ -z "$REASON" ] && REASON=unknown
    ;;
esac

case "$HTTP_STATUS" in
  2*)
    advance_last_fire
    rm -f "$ERROR_FILE" 2>/dev/null || true
    if [ "$REASON" != "duplicate" ]; then
      # "unknown" (pre-feedback server) must serialize as JSON null, not a
      # bare unquoted word — the marker is parsed as JSON by the status skill.
      ATTRIBUTED_JSON="$ATTRIBUTED"
      [ "$ATTRIBUTED_JSON" = "unknown" ] && ATTRIBUTED_JSON=null
      printf '{"attributed":%s,"reason":"%s","folder":%s,"at":"%s"}\n' \
        "$ATTRIBUTED_JSON" "$REASON" "$(json_str_or_null "$WORKSPACE_FOLDER")" "$TIMESTAMP" \
        > "$STATE_DIR/attribution-$TOOL_ID.json" 2>/dev/null || true
    fi
    log "ok status=$HTTP_STATUS duration=${DURATION}s force=$FORCE_FLUSH attributed=$ATTRIBUTED reason=$REASON"
    drain_spool
    ;;
  *)
    # The beat is NOT lost: it goes to the spool (with its interval claimed
    # via lastFire) and the failure becomes visible state — `last-error` is
    # what lets the status skill distinguish "broken" from "idle", which
    # were indistinguishable for the three weeks a stale script ran silently.
    spool_append
    advance_last_fire
    printf '{"status":"%s","at":"%s","tool":%s,"spoolDepth":%s}\n' \
      "$HTTP_STATUS" "$TIMESTAMP" "$(json_str_or_null "$TOOL_ID")" "$(spool_depth)" \
      > "$ERROR_FILE" 2>/dev/null || true
    log "fail status=$HTTP_STATUS duration=${DURATION}s spooled depth=$(spool_depth)"
    ;;
esac

cleanup_header_file
exit 0
