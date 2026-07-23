#!/bin/sh
# claude-plugin/scripts/pair.sh — device pairing for /novum-tracker:connect
# keyless mode. Two phases so the human always sees the code BEFORE the
# blocking wait begins:
#
#   pair.sh start [--url https://your-instance]
#     mints a pairing, prints the code + approval URL, saves state
#   pair.sh wait
#     polls until approved, writes ~/.config/neonpod/heartbeat.env
#     (0600, unrelated lines preserved), sends a one-shot test heartbeat
#
# The poll token lives in ~/.config/neonpod/pairing.tmp (0600) between the
# two calls and is deleted on completion or failure. The API key is written
# straight to heartbeat.env — it never appears on stdout.

set -eu

CFG_DIR="$HOME/.config/neonpod"
STATE="$CFG_DIR/pairing.tmp"
ENV_FILE="$CFG_DIR/heartbeat.env"

json_field() { printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p"; }
json_num()   { printf '%s' "$1" | sed -n "s/.*\"$2\":\\([0-9][0-9]*\\).*/\\1/p"; }

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  start)
    URL="https://novumstartup.com"
    while [ $# -gt 0 ]; do
      case "$1" in
        --url) URL="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
      esac
    done
    URL="${URL%/}"
    mkdir -p "$CFG_DIR"
    umask 077
    MINT=$(curl -fsS -X POST "$URL/api/device-pairing" \
      -H 'Content-Type: application/json' \
      --data '{"toolId":"claude-code"}') || {
      echo "error: could not reach $URL to start pairing" >&2; exit 1; }
    CODE=$(json_field "$MINT" userCode)
    POLL_TOKEN=$(json_field "$MINT" pollToken)
    INTERVAL=$(json_num "$MINT" intervalSeconds)
    EXPIRES=$(json_num "$MINT" expiresInSeconds)
    [ -n "$CODE" ] && [ -n "$POLL_TOKEN" ] || {
      echo "error: unexpected pairing response from $URL" >&2; exit 1; }
    printf 'URL=%s\nPOLL_TOKEN=%s\nINTERVAL=%s\nEXPIRES=%s\n' \
      "$URL" "$POLL_TOKEN" "${INTERVAL:-3}" "${EXPIRES:-600}" > "$STATE"
    chmod 600 "$STATE"
    echo "code: $CODE"
    echo "approve-at: $URL/connect"
    echo "expires-in-minutes: $(( ${EXPIRES:-600} / 60 ))"
    ;;

  wait)
    [ -f "$STATE" ] || {
      echo "error: no pairing in progress — run 'start' first" >&2; exit 1; }
    . "$STATE"
    DEADLINE=$(( $(date +%s) + EXPIRES ))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      RESP=$(curl -s -w '\n%{http_code}' -X POST "$URL/api/device-pairing/poll" \
        -H 'Content-Type: application/json' \
        --data "{\"pollToken\":\"$POLL_TOKEN\"}") || RESP=""
      HTTP=$(printf '%s' "$RESP" | tail -n 1)
      BODY=$(printf '%s' "$RESP" | sed '$d')
      case "$HTTP" in
        200)
          KEY=$(json_field "$BODY" key)
          [ -n "$KEY" ] || { echo "error: approval response missing key" >&2; exit 1; }
          umask 077
          TMP="$ENV_FILE.tmp.$$"
          {
            if [ -f "$ENV_FILE" ]; then
              grep -v '^NEONPOD_API_KEY=' "$ENV_FILE" | grep -v '^NEONPOD_API_URL=' || true
            fi
            printf 'NEONPOD_API_KEY=%s\nNEONPOD_API_URL=%s\n' "$KEY" "$URL"
          } > "$TMP"
          mv "$TMP" "$ENV_FILE"
          chmod 600 "$ENV_FILE"
          rm -f "$STATE"
          echo "approved: heartbeat.env written"
          SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
          env NEONPOD_TOOL_ID=claude-code NEONPOD_FORCE_FLUSH=1 NEONPOD_DEBUG=1 \
            "$SCRIPT_DIR/../hooks/heartbeat.sh" </dev/null || true
          tail -n 1 "${XDG_STATE_HOME:-$HOME/.local/state}/neonpod/heartbeat.log" 2>/dev/null || true
          exit 0
          ;;
        410)
          STATUS=$(json_field "$BODY" status)
          rm -f "$STATE"
          echo "failed: ${STATUS:-gone}" >&2
          exit 1
          ;;
        *) ;; # 202 pending / 429 slow_down / transient — keep polling
      esac
      sleep "$INTERVAL"
    done
    rm -f "$STATE"
    echo "failed: timeout" >&2
    exit 1
    ;;

  *)
    echo "usage: pair.sh start [--url URL] | pair.sh wait" >&2
    exit 1
    ;;
esac
