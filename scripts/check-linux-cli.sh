#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${LILT_BIN:-"$ROOT/.build/debug/lilt"}
FIX=$(mktemp -d "$ROOT/work/linux-cli-e2e.XXXXXX")
HOME_DIR="$FIX/home"
mkdir -p "$HOME_DIR/.claude"
chmod 700 "$HOME_DIR/.claude"
printf '%s' '{"claudeAiOauth":{"accessToken":"fixture-access-cli","refreshToken":"fixture-refresh-cli","expiresAt":4102444800000,"scopes":["user:profile","user:inference"]}}' > "$HOME_DIR/.claude/.credentials.json"
chmod 600 "$HOME_DIR/.claude/.credentials.json"
printf '%s' '{"oauthAccount":{"accountUuid":"fixture-cli-account","emailAddress":"fixture@example.invalid"},"projects":{}}' > "$HOME_DIR/.claude.json"
HOME="$HOME_DIR" "$BIN" daemon > "$FIX/daemon.log" 2>&1 &
PID=$!
cleanup() {
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    rm -rf "$FIX"
}
trap cleanup EXIT
for _ in {1..50}; do [ -S "$HOME_DIR/.local/state/lilt/run/lilt.sock" ] && break; sleep 0.1; done
HOME="$HOME_DIR" "$BIN" takeover --label Fixture-A >/dev/null
printf '%s\n' 'sk-ant-oat01-fixture-only-1234567890' | HOME="$HOME_DIR" "$BIN" add-token --label Fixture-T >/dev/null
HOME="$HOME_DIR" "$BIN" switch 2 >/dev/null
HOME="$HOME_DIR" "$BIN" config set five-hour-threshold 6 >/dev/null
HOME="$HOME_DIR" "$BIN" status --json > "$FIX/status.json"
HOME="$HOME_DIR" "$BIN" switch 1 >/dev/null
HOME="$HOME_DIR" "$BIN" remove 2 --yes >/dev/null
HOME="$HOME_DIR" "$BIN" release >/dev/null
if ! grep -q '"ok" : true' "$FIX/status.json" ||
   ! grep -q '"running" : true' "$FIX/status.json" ||
   ! grep -q '"threshold" : 6' "$FIX/status.json" ||
   ! grep -q 'Fixture-T' "$FIX/status.json"; then
    cat "$FIX/status.json"
    cat "$FIX/daemon.log"
    exit 1
fi
HOME="$HOME_DIR" "$BIN" list > "$FIX/list.txt"
grep -q 'Fixture-A' "$FIX/list.txt"
[ ! -e "$HOME_DIR/.local/state/lilt/live-usage.json" ]
printf 'PASS: Linux CLI/socket/daemon — takeover, token import, switch, config, JSON, removal, release; isolated HOME, no network.\n'
