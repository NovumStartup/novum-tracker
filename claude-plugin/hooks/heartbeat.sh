#!/bin/sh
# hooks/heartbeat.sh (novum-tracker Claude Code plugin)
#
# UPSTREAM: chronoforge scripts/coding-tool-heartbeat.sh — do not edit here.
# Sync: copy verbatim from chronoforge on each plugin release (see the
# release checklist in ../README.md), then bump plugin.json +
# ../.claude-plugin/marketplace.json versions.
#
# Posts a single coding-time heartbeat to Novum Startup's /api/ide/heartbeat
# endpoint from an AI coding tool's hook event (Claude Code / Codex
# PostToolUse + Stop). Mirrors the payload shape the VS Code extension
# uses (now the standalone novum-tracker extension) so the existing aggregator at
# src/lib/ide/aggregate-heartbeats.ts rolls these up alongside human IDE
# heartbeats.
#
# Required env:
#   NEONPOD_TOOL_ID    — editor value (e.g. "claude-code", "codex")
#   NEONPOD_API_KEY    — UserApiKey from the NeonPod dashboard
#   NEONPOD_API_URL    — e.g. https://neonpod.example
#
# Optional env:
#   NEONPOD_CONFIG        — path to env file to source (default: ~/.config/neonpod/heartbeat.env)
#   NEONPOD_FORCE_FLUSH   — "1" to bypass the debounce window (use on Stop / SessionEnd hook)
#   NEONPOD_DEBUG         — "1" to append diagnostic lines to the log file
#   NEONPOD_CWD           — override $PWD as the workspace root
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

DEBUG="${NEONPOD_DEBUG:-0}"
TOOL_ID="${NEONPOD_TOOL_ID:-other}"
FORCE_FLUSH="${NEONPOD_FORCE_FLUSH:-0}"

CONFIG_FILE="${NEONPOD_CONFIG:-$HOME/.config/neonpod/heartbeat.env}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$CONFIG_FILE"; set +a
fi

API_KEY="${NEONPOD_API_KEY:-}"
API_URL="${NEONPOD_API_URL:-}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/neonpod"
STATE_FILE="$STATE_DIR/heartbeat-$TOOL_ID.json"
LOG_FILE="$STATE_DIR/heartbeat.log"

log() {
  [ "$DEBUG" = "1" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '[%s] [%s] %s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$TOOL_ID" \
    "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# Always drain stdin (hook handlers pipe JSON context in even when we
# don't consume it). Reading via `cat` avoids leaving fd 0 dangling.
cat >/dev/null 2>&1 || true

if [ -z "$API_KEY" ]; then log "skip: NEONPOD_API_KEY not set"; exit 0; fi
if [ -z "$API_URL" ]; then log "skip: NEONPOD_API_URL not set"; exit 0; fi

CWD="${NEONPOD_CWD:-$PWD}"
if [ ! -d "$CWD" ]; then
  log "skip: cwd '$CWD' not a directory"
  exit 0
fi

# Optional repo allowlist — see NEONPOD_TRACK_REMOTES in the header. Checked
# before the debounce so filtered repos never touch the shared state file.
ALLOW="${NEONPOD_TRACK_REMOTES:-}"
if [ -n "$ALLOW" ]; then
  ALLOW_REMOTE=$(git -C "$CWD" config --get remote.origin.url 2>/dev/null || true)
  if [ -z "$ALLOW_REMOTE" ]; then
    log "skip: allowlist active, no git origin remote in $CWD"
    exit 0
  fi
  # Normalize so ssh (git@host:org/repo.git) and https forms both match a
  # lowercase "org/repo" substring pattern.
  ALLOW_NORMALIZED=$(printf '%s' "$ALLOW_REMOTE" | tr '[:upper:]' '[:lower:]' | tr ':' '/')
  ALLOW_MATCH=0
  for ALLOW_PATTERN in $ALLOW; do
    case "$ALLOW_NORMALIZED" in
      *"$ALLOW_PATTERN"*) ALLOW_MATCH=1; break ;;
    esac
  done
  if [ "$ALLOW_MATCH" = "0" ]; then
    log "skip: remote '$ALLOW_NORMALIZED' not in allowlist"
    exit 0
  fi
fi

DEBOUNCE_SECONDS=60
MIN_DURATION_SECONDS=60
# Cap the per-heartbeat duration at 5 min. Longer gaps between hook fires
# almost always represent the operator stepping away mid-session; attributing
# those as solid coding time would over-count.
MAX_DURATION_SECONDS=300

mkdir -p "$STATE_DIR" 2>/dev/null || true

NOW=$(date +%s)
LAST_FIRE=0
if [ -f "$STATE_FILE" ]; then
  LAST_FIRE=$(sed -n 's/.*"lastFire"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$STATE_FILE" 2>/dev/null | head -n 1)
  [ -z "$LAST_FIRE" ] && LAST_FIRE=0
fi

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
  if [ "$DURATION" -lt "$MIN_DURATION_SECONDS" ]; then DURATION=$MIN_DURATION_SECONDS; fi
  if [ "$DURATION" -gt "$MAX_DURATION_SECONDS" ]; then DURATION=$MAX_DURATION_SECONDS; fi
fi

# Git introspection — silent failures yield null fields. `git -C` avoids
# changing the script's own cwd.
git_field() {
  git -C "$CWD" "$@" 2>/dev/null
}

BRANCH=$(git_field rev-parse --abbrev-ref HEAD || true)
REMOTE_URL=$(git_field config --get remote.origin.url || true)
COMMIT_HASH=$(git_field rev-parse HEAD || true)
COMMIT_EMAIL=$(git_field log -1 --format=%ae || true)

WORKSPACE_FOLDER=$(basename "$CWD" 2>/dev/null || printf 'workspace')

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

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

PAYLOAD=$(printf '{"editor":%s,"language":null,"file":null,"branch":%s,"workspaceFolder":%s,"duration":%s,"timestamp":%s,"gitRemoteUrl":%s,"commitHash":%s,"commitAuthorEmail":%s}' \
  "$(json_str_or_null "$TOOL_ID")" \
  "$(json_str_or_null "$BRANCH")" \
  "$(json_str_or_null "$WORKSPACE_FOLDER")" \
  "$DURATION" \
  "$(json_str_or_null "$TIMESTAMP")" \
  "$(json_str_or_null "$REMOTE_URL")" \
  "$(json_str_or_null "$COMMIT_HASH")" \
  "$(json_str_or_null "$COMMIT_EMAIL")")

API_URL_CLEAN="${API_URL%/}"

# Pipe the payload via stdin (--data-binary @-) instead of --data: the
# latter treats leading '@' as a filename, which could break for an
# unusual branch / workspace name starting with '@'.
#
# Suppress curl's stderr unless DEBUG mode is on — otherwise transient
# TLS / DNS errors silently accumulate in $LOG_FILE forever. curl emits
# the actual HTTP status via -w even on connection failure (prints "000"
# and exits non-zero); tolerate that exit code.
if [ "$DEBUG" = "1" ]; then
  CURL_ERR="$LOG_FILE"
else
  CURL_ERR="/dev/null"
fi

HTTP_STATUS=$(printf '%s' "$PAYLOAD" | curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "${API_URL_CLEAN}/api/ide/heartbeat" \
  -H 'Content-Type: application/json' \
  -H "X-API-Key: $API_KEY" \
  --max-time 10 \
  --data-binary @- 2>>"$CURL_ERR") || true
[ -z "$HTTP_STATUS" ] && HTTP_STATUS=000

case "$HTTP_STATUS" in
  2*)
    printf '{"lastFire":%s}\n' "$NOW" > "$STATE_FILE" 2>/dev/null || true
    log "ok status=$HTTP_STATUS duration=${DURATION}s force=$FORCE_FLUSH"
    ;;
  *)
    log "fail status=$HTTP_STATUS duration=${DURATION}s payload=$PAYLOAD"
    ;;
esac

exit 0
