#!/bin/sh
# hooks/session-check.sh (novum-tracker Claude Code plugin)
#
# UPSTREAM: chronoforge scripts/coding-tool-session-check.sh (served at
# /install/session-check.sh) — do not edit here. Sync verbatim per the
# release checklist in ../README.md.
#
# SessionStart self-check for NovumStartup coding-time tracking. The
# heartbeat sender fails SILENTLY by design (a tracking hiccup must never
# interrupt a coding session), which historically made "broken" identical to
# "idle" — a stale script ran on one machine for ~3 weeks before anyone
# noticed. This hook runs once per session start, while a human is present
# to act, and prints ONE warning line when tracking cannot work:
#
#   - config exists but the API key or URL is missing/empty
#   - the API is unreachable, or answers 401 (key revoked)
#   - the server's minimum client version is above this script's
#   - NEONPOD_TRACK_REMOTES is set and this repo does not match it
#     (the allowlist is fail-closed — a typo here silently stops tracking)
#
# NO config file at all means "not connected yet" — the documented contract
# is a silent no-op until the user pairs, so that stays quiet. A healthy
# check prints NOTHING.
#
# The reachability probe is latency-guarded: it only runs when the newest
# heartbeat state is stale (>24h) or a delivery error marker exists, and is
# capped at 3s — most session starts do zero network I/O. A 429 from the
# probe means "reachable and authenticated, just busy" and is treated as
# healthy, never as broken.
#
# Output contract (Claude Code SessionStart): a single JSON object on
# stdout whose systemMessage is shown to the user. Bare stdout would be
# injected as model context instead, so this script emits valid JSON or
# nothing. Always exits 0.

set -u
trap 'exit 0' INT TERM HUP
umask 077

SCRIPT_VERSION="0.5.0"
TOOL_ID="${NEONPOD_TOOL_ID:-claude-code}"

CONFIG_FILE="${NEONPOD_CONFIG:-$HOME/.config/neonpod/heartbeat.env}"

# Drain stdin fully (SessionStart pipes session JSON; a dangling fd can stall
# the host) keeping only the head for the cwd field.
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

# Not connected yet: stay silent (the plugin's documented pre-pairing state).
[ -f "$CONFIG_FILE" ] || exit 0

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/neonpod"
ERROR_FILE="$STATE_DIR/last-error-$TOOL_ID.json"

warn() {
  # Emit the systemMessage JSON and stop — one actionable line per session.
  MSG=$(printf '%s' "$1" | tr -d '[:cntrl:]' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  printf '{"systemMessage":"⚠ Novum tracking: %s — run /novum-tracker:status for details"}\n' "$MSG"
  exit 0
}

# Defensive source (mirrors the heartbeat script): a config that aborts the
# shell under set -u — an unset-variable reference, or an unterminated quote
# on dash — must produce a WARNING, never a non-zero exit with shell stderr
# noise breaking this hook's valid-JSON-or-nothing output contract.
if ( set +u; . "$CONFIG_FILE" ) >/dev/null 2>&1; then
  set +u
  # shellcheck disable=SC1090
  set -a; . "$CONFIG_FILE"; set +a
  set -u
else
  warn "the config file at ~/.config/neonpod/heartbeat.env failed to parse; fix or re-run the installer"
fi

API_KEY="${NEONPOD_API_KEY:-}"
API_URL="${NEONPOD_API_URL:-}"

[ -n "$API_KEY" ] || warn "config exists but NEONPOD_API_KEY is empty; reconnect with /novum-tracker:connect"
[ -n "$API_URL" ] || warn "config exists but NEONPOD_API_URL is empty"

# Allowlist check for THIS repo — the invisible fail-closed path. When
# NEONPOD_TRACK_REMOTES is set and this directory's remote doesn't match,
# every heartbeat from here is silently skipped; say so once, up front.
CWD=$(hook_field cwd)
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="$PWD"
ALLOW="${NEONPOD_TRACK_REMOTES:-}"
if [ -n "$ALLOW" ]; then
  ALLOW_REMOTE=$(git -C "$CWD" config --get remote.origin.url 2>/dev/null || true)
  if [ -z "$ALLOW_REMOTE" ]; then
    warn "NEONPOD_TRACK_REMOTES is set and this folder has no git remote; no time will be recorded here"
  fi
  ALLOW_NORMALIZED=$(printf '%s' "$ALLOW_REMOTE" | tr '[:upper:]' '[:lower:]' | tr ':' '/')
  ALLOW_MATCH=0
  # set -f: see the same guard in coding-tool-heartbeat.sh.
  set -f
  for ALLOW_PATTERN in $ALLOW; do
    case "$ALLOW_NORMALIZED" in
      *"$ALLOW_PATTERN"*) ALLOW_MATCH=1; break ;;
    esac
  done
  set +f
  if [ "$ALLOW_MATCH" = "0" ]; then
    warn "this repo is not in NEONPOD_TRACK_REMOTES; no time will be recorded here"
  fi
fi

# Reachability/key probe — only when tracking already looks unhealthy:
# no successful heartbeat state written in the last day, or a delivery
# error marker present. `find -mtime -1` is the portable "modified within
# 24h" (BSD and GNU agree); the per-repo state files all match the glob.
RECENT=""
if [ -d "$STATE_DIR" ]; then
  RECENT=$(find "$STATE_DIR" -name "heartbeat-${TOOL_ID}*.json" -mtime -1 2>/dev/null | head -n 1)
fi
if [ -n "$RECENT" ] && [ ! -f "$ERROR_FILE" ]; then
  exit 0
fi

# Probe response and key header live inside the 0700 state dir, never in a
# shared /tmp (predictable names there are symlink-clobber bait on Linux),
# and the key never rides in curl argv (ps-visible to other local users).
mkdir -p "$STATE_DIR" 2>/dev/null || true
chmod 700 "$STATE_DIR" 2>/dev/null || true
RESP_FILE="$STATE_DIR/.health-resp-$$"
HEADER_FILE="$STATE_DIR/.curl-headers-check-$$"
printf 'X-API-Key: %s\n' "$API_KEY" > "$HEADER_FILE" 2>/dev/null || true
HTTP_STATUS=$(curl -sS -o "$RESP_FILE" -w '%{http_code}' \
  "${API_URL%/}/api/ide/health" \
  -H "@$HEADER_FILE" \
  --max-time 3 2>/dev/null) || true
[ -z "$HTTP_STATUS" ] && HTTP_STATUS=000
RESP_BODY=$(cat "$RESP_FILE" 2>/dev/null || true)
rm -f "$RESP_FILE" "$HEADER_FILE" 2>/dev/null || true

case "$HTTP_STATUS" in
  2*)
    # Reachable and authenticated. Last check: is this script version still
    # supported? The floor is "0" until version enforcement begins.
    MIN_VERSION=$(printf '%s' "$RESP_BODY" | sed -n 's/.*"minClientVersion":"\([0-9.][0-9.]*\)".*/\1/p')
    if [ -n "$MIN_VERSION" ] && [ "$MIN_VERSION" != "0" ]; then
      # Dotted-numeric compare without sort -V (absent from some BSD sorts):
      # compare up to four components, missing ones count as 0.
      IFS_SAVE=$IFS
      IFS=.
      # shellcheck disable=SC2086
      set -- $SCRIPT_VERSION
      V1=${1:-0}; V2=${2:-0}; V3=${3:-0}; V4=${4:-0}
      # shellcheck disable=SC2086
      set -- $MIN_VERSION
      M1=${1:-0}; M2=${2:-0}; M3=${3:-0}; M4=${4:-0}
      IFS=$IFS_SAVE
      OUTDATED=0
      if   [ "$V1" -lt "$M1" ]; then OUTDATED=1
      elif [ "$V1" -eq "$M1" ] && [ "$V2" -lt "$M2" ]; then OUTDATED=1
      elif [ "$V1" -eq "$M1" ] && [ "$V2" -eq "$M2" ] && [ "$V3" -lt "$M3" ]; then OUTDATED=1
      elif [ "$V1" -eq "$M1" ] && [ "$V2" -eq "$M2" ] && [ "$V3" -eq "$M3" ] && [ "$V4" -lt "$M4" ]; then OUTDATED=1
      fi
      if [ "$OUTDATED" = "1" ]; then
        warn "tracking script v$SCRIPT_VERSION is below the supported minimum v$MIN_VERSION; re-run the installer"
      fi
    fi
    exit 0
    ;;
  401)
    warn "API key was rejected (revoked or invalid); reconnect with /novum-tracker:connect"
    ;;
  429)
    # Reachable + authenticated, just busy — healthy by definition.
    exit 0
    ;;
  *)
    warn "cannot reach ${API_URL%/} (status $HTTP_STATUS); beats are spooling locally and will retry"
    ;;
esac

exit 0
