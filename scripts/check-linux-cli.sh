#!/bin/bash
# End-to-end check of the real `lilt` CLI ↔ Unix socket ↔ daemon, in isolated HOMEs with fixture credentials and a
# fake `claude`. No network, no real account, no real Claude Code.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${LILT_BIN:-"$ROOT/.build/debug/lilt"}
mkdir -p "$ROOT/work"
FIX=$(mktemp -d "$ROOT/work/linux-cli-e2e.XXXXXX")
HOME_DIR="$FIX/home"
SECOND_HOME="$FIX/second"
mkdir -p "$HOME_DIR/.claude" "$SECOND_HOME/.claude" "$FIX/bin"
chmod 700 "$HOME_DIR/.claude" "$SECOND_HOME/.claude"
# Debug builds send no account request at all with this set; release binaries are checked without a network.
export LILT_OFFLINE=1
for key in CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR XDG_DATA_HOME XDG_STATE_HOME XDG_CONFIG_HOME XDG_RUNTIME_DIR \
           ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CLI_PATH; do unset "$key"; done
printf '%s' '{"claudeAiOauth":{"accessToken":"fixture-access-cli","refreshToken":"fixture-refresh-cli","expiresAt":4102444800000,"scopes":["user:profile","user:inference"]}}' > "$HOME_DIR/.claude/.credentials.json"
printf '%s' '{"claudeAiOauth":{"accessToken":"fixture-access-second","refreshToken":"fixture-refresh-second","expiresAt":4102444800000,"scopes":["user:profile","user:inference"]}}' > "$SECOND_HOME/.claude/.credentials.json"
chmod 600 "$HOME_DIR/.claude/.credentials.json" "$SECOND_HOME/.claude/.credentials.json"
printf '%s' '{"oauthAccount":{"accountUuid":"fixture-cli-account","emailAddress":"fixture@example.invalid"},"projects":{}}' > "$HOME_DIR/.claude.json"

# A stand-in for the official CLI that records what it was started with: working directory, configuration,
# whatever login override survived, every argument on its own line, stdin, and how it was signalled.
cat > "$FIX/bin/claude" <<'FAKE'
#!/bin/sh
out="$LILT_FAKE_OUT"
{
  printf 'cwd=%s\n' "$(pwd -P)"
  printf 'config=%s\n' "${CLAUDE_CONFIG_DIR-}"
  printf 'apikey=%s\n' "${ANTHROPIC_API_KEY-unset}"
  printf 'token=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN-unset}"
  printf 'pid=%s\n' "$$"
  for argument in "$@"; do printf 'arg=%s\n' "$argument"; done
} > "$out"
if [ -n "${LILT_FAKE_SLEEP-}" ]; then
  trap 'echo term > "$out.signal"; exit 143' TERM
  sleep 10 &
  wait
fi
cat > "$out.stdin"
printf 'fake-stdout\n'
printf 'fake-stderr\n' >&2
exit 7
FAKE
chmod 755 "$FIX/bin/claude"

PIDS=()
fail() { printf 'FAIL: %s\n' "$1" >&2; for log in "$FIX"/*.log; do [ -f "$log" ] && { echo "--- $log" >&2; cat "$log" >&2; }; done; exit 1; }
# Ready means answering: right after a restart the previous daemon's socket file can still be there.
start_daemon() {
    HOME="$1" "$BIN" daemon > "$2" 2>&1 & PIDS+=($!)
    for _ in {1..100}; do HOME="$1" "$BIN" status > /dev/null 2>&1 && return; sleep 0.1; done
    fail "daemon did not start"
}
stop_daemon() { kill -TERM "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
cleanup() {
    for pid in "${PIDS[@]}"; do stop_daemon "$pid"; done
    rm -rf "$FIX"
}
trap cleanup EXIT
lilt() { HOME="$HOME_DIR" PATH="$FIX/bin:$PATH" "$BIN" "$@"; }
# Output goes to a file before grep reads it: under pipefail, `grep -q` closing the pipe early fails the writer.
# Feeds `input` to a command through a pseudo-terminal, the only place `lilt export|import` reads a passphrase from.
# The input arrives after the prompt and the pipe stays open a moment: `script` turns the end of its input into an
# end-of-file on the terminal, which would otherwise reach the program before the passphrase does.
with_tty() {
    local input=$1; shift
    if [ "$(uname)" = Darwin ]; then
        { sleep 1; printf '%s' "$input"; sleep 2; } | script -q /dev/null "$@" > /dev/null 2>&1 || true
    else
        { sleep 1; printf '%s' "$input"; sleep 2; } | script -q -c "$(printf '%q ' "$@")" /dev/null > /dev/null 2>&1 || true
    fi
}

start_daemon "$HOME_DIR" "$FIX/daemon.log"
DAEMON=${PIDS[0]}
lilt takeover --label Fixture-A >/dev/null
printf '%s\n' 'sk-ant-oat01-fixture-only-1234567890' | lilt add-token --label Fixture-T >/dev/null
lilt switch 2 >/dev/null
lilt config set five-hour-threshold 6 >/dev/null
lilt status --json > "$FIX/status.json"
lilt switch 1 >/dev/null
grep -q '"ok" : true' "$FIX/status.json" && grep -q '"running" : true' "$FIX/status.json" &&
    grep -q '"threshold" : 6' "$FIX/status.json" && grep -q 'Fixture-T' "$FIX/status.json" || fail "status JSON"
lilt list > "$FIX/list.txt"
grep -q 'Fixture-A' "$FIX/list.txt" || fail "list"
[ ! -e "$HOME_DIR/.local/state/lilt/live-usage.json" ] || fail "legacy single-slot record"

# Two projects, each on an account of its own.
printf '%s\n' 'sk-ant-oat01-fixture-project-p1-000000' | lilt add-token --label Fixture-P1 >/dev/null
printf '%s\n' 'sk-ant-oat01-fixture-project-p2-000000' | lilt add-token --label Fixture-P2 >/dev/null
PA="$FIX/Project A ' 项目"
PB="$FIX/Project B"
mkdir -p "$PA/sub dir" "$PB" "$FIX/unbound"
DEFAULT_BEFORE=$(cat "$HOME_DIR/.claude/.credentials.json")
lilt project bind "$PA" Fixture-P1 >/dev/null || fail "bind A"
lilt project bind "$PB" Fixture-P2 >/dev/null || fail "bind B"
lilt project list > "$FIX/projects.txt"
grep -q 'Project A' "$FIX/projects.txt" && grep -q 'Project B' "$FIX/projects.txt" || fail "project list"
lilt project status "$PA" --json > "$FIX/project-a.json"
grep -q '"phase" : "ready"' "$FIX/project-a.json" || fail "project A not ready"
SCOPES="$HOME_DIR/.local/share/lilt/projects"
[ "$(find "$SCOPES" -name .credentials.json | wc -l | tr -d ' ')" = 2 ] || fail "two project scopes"
[ "$(cat "$HOME_DIR/.claude/.credentials.json")" = "$DEFAULT_BEFORE" ] || fail "binding changed the default login"
if lilt switch Fixture-P1 >/dev/null 2>&1; then fail "default login took a project account"; fi
if lilt remove Fixture-P1 --yes >/dev/null 2>&1; then fail "bound account removed"; fi
if lilt project bind "$PA" Fixture-P2 >/dev/null 2>&1; then fail "one directory bound twice"; fi
if lilt project rebind "$PA" Fixture-P2 >/dev/null 2>&1; then fail "shared without --allow-shared"; fi

# `lilt run` becomes the official CLI: same process, working directory kept inside the project, only the project's
# configuration set, login overrides removed, arguments passed through untouched, stdio and exit status preserved.
OUT="$FIX/run.out"
set +e
(cd "$PA/sub dir" && printf 'fixture-stdin' | ANTHROPIC_API_KEY=fixture-key CLAUDE_CODE_OAUTH_TOKEN=fixture-token LILT_FAKE_OUT="$OUT" \
    HOME="$HOME_DIR" PATH="$FIX/bin:$PATH" "$BIN" run --project "$PA" -- --resume "fixture session" '$(touch pwned)' "it's" \
    > "$FIX/run.stdout" 2> "$FIX/run.stderr")
STATUS=$?
set -e
[ "$STATUS" = 7 ] || fail "exit status $STATUS"
grep -qx 'fake-stdout' "$FIX/run.stdout" && grep -qx 'fake-stderr' "$FIX/run.stderr" || fail "stdout/stderr"
[ "$(cat "$OUT.stdin")" = 'fixture-stdin' ] || fail "stdin"
grep -qx "cwd=$(cd "$PA/sub dir" && pwd -P)" "$OUT" || fail "working directory"
grep -qx 'apikey=unset' "$OUT" && grep -qx 'token=unset' "$OUT" || fail "login overrides reached the CLI"
CONFIG_A=$(sed -n 's/^config=//p' "$OUT")
case "$CONFIG_A" in "$SCOPES"/*/claude) ;; *) fail "configuration directory $CONFIG_A";; esac
grep -q 'fixture-project-p1' "$CONFIG_A/.credentials.json" || fail "project A login"
[ "$(sed -n 's/^arg=//p' "$OUT")" = "$(printf '%s\n' --resume 'fixture session' '$(touch pwned)' "it's")" ] || fail "arguments"
[ ! -e "$PA/sub dir/pwned" ] && [ ! -e "$PA/pwned" ] || fail "argument ran through a shell"
(cd "$FIX" && LILT_FAKE_OUT="$FIX/run-b.out" HOME="$HOME_DIR" PATH="$FIX/bin:$PATH" "$BIN" run --project "$PB" < /dev/null > /dev/null 2>&1) || true
grep -qx "cwd=$(cd "$PB" && pwd -P)" "$FIX/run-b.out" || fail "outside the project the CLI starts in it"
CONFIG_B=$(sed -n 's/^config=//p' "$FIX/run-b.out")
[ "$CONFIG_A" != "$CONFIG_B" ] || fail "projects share a configuration"
# A signal reaches the CLI itself, not a wrapper.
LILT_FAKE_SLEEP=1 LILT_FAKE_OUT="$FIX/run-signal.out" HOME="$HOME_DIR" PATH="$FIX/bin:$PATH" "$BIN" run --project "$PA" < /dev/null > /dev/null 2>&1 &
RUNNER=$!
for _ in {1..50}; do [ -s "$FIX/run-signal.out" ] && break; sleep 0.1; done
[ "$(sed -n 's/^pid=//p' "$FIX/run-signal.out")" = "$RUNNER" ] || fail "lilt run did not become the CLI process"
kill -TERM "$RUNNER"
set +e; wait "$RUNNER"; STATUS=$?; set -e
[ "$STATUS" = 143 ] && [ -f "$FIX/run-signal.out.signal" ] || fail "signal not delivered to the CLI ($STATUS)"
# No binding, no daemon: nothing starts, and certainly not a plain `claude`.
if (cd "$FIX/unbound" && LILT_FAKE_OUT="$FIX/unbound.out" lilt run --project "$FIX/unbound" > /dev/null 2>&1); then fail "unbound project ran"; fi
[ ! -e "$FIX/unbound.out" ] || fail "unbound project started claude"

# Rebinding A writes A only; B stays byte for byte.
B_BEFORE=$(cat "$CONFIG_B/.credentials.json")
lilt project rebind "$PA" Fixture-P2 --allow-shared >/dev/null || fail "rebind A"
grep -q 'fixture-project-p2' "$CONFIG_A/.credentials.json" || fail "rebind did not write A"
[ "$(cat "$CONFIG_B/.credentials.json")" = "$B_BEFORE" ] || fail "rebinding A changed B"
lilt project rebind "$PA" Fixture-P1 >/dev/null || fail "rebind A back"

# A daemon restart keeps the projects.
stop_daemon "$DAEMON"
start_daemon "$HOME_DIR" "$FIX/daemon-restarted.log"
lilt project list > "$FIX/projects-restarted.txt"
grep -q 'Project B' "$FIX/projects-restarted.txt" || fail "projects lost across restart"

# Encrypted export: passphrase from the terminal only, a new 0600 file, never stdout, never over an existing file.
ARCHIVE="$FIX/accounts.lilt-credential-export"
PASSPHRASE='fixture-passphrase-long'
if lilt export "$ARCHIVE" --password "$PASSPHRASE" >/dev/null 2>&1; then fail "export took a password argument"; fi
if lilt export - >/dev/null 2>&1; then fail "export wrote to stdout"; fi
with_tty "$PASSPHRASE
$PASSPHRASE
" env HOME="$HOME_DIR" PATH="$FIX/bin:$PATH" "$BIN" export "$ARCHIVE"
[ -s "$ARCHIVE" ] || fail "no archive"
MODE=$(stat -c %a "$ARCHIVE" 2>/dev/null || stat -f %Lp "$ARCHIVE")
[ "$MODE" = 600 ] || fail "archive mode $MODE"
if grep -q -e 'fixture-access' -e 'fixture-only' -e 'Fixture-A' -e 'example.invalid' "$ARCHIVE"; then fail "archive shows plaintext"; fi
cp "$ARCHIVE" "$FIX/archive.copy"
with_tty "$PASSPHRASE
$PASSPHRASE
" env HOME="$HOME_DIR" PATH="$FIX/bin:$PATH" "$BIN" export "$ARCHIVE"
cmp -s "$ARCHIVE" "$FIX/archive.copy" || fail "export replaced an existing file"

# Import on a second machine: adds only, disabled, relay off, and its own login is untouched.
start_daemon "$SECOND_HOME" "$FIX/daemon-second.log"
HOME="$SECOND_HOME" "$BIN" takeover --label Second >/dev/null
HOME="$SECOND_HOME" "$BIN" auto on >/dev/null
SECOND_BEFORE=$(cat "$SECOND_HOME/.claude/.credentials.json")
with_tty "fixture-wrong-passphrase
" env HOME="$SECOND_HOME" "$BIN" import "$ARCHIVE"
[ "$(HOME="$SECOND_HOME" "$BIN" list | grep -c '\.')" = 1 ] || fail "wrong passphrase imported something"
with_tty "$PASSPHRASE
" env HOME="$SECOND_HOME" "$BIN" import "$ARCHIVE"
HOME="$SECOND_HOME" "$BIN" list > "$FIX/second-list.txt"
[ "$(grep -c '\[已停用\]' "$FIX/second-list.txt")" = 4 ] || fail "imported accounts not added disabled"
HOME="$SECOND_HOME" "$BIN" status --json > "$FIX/second-status.json"
grep -q '"autoRelay" : false' "$FIX/second-status.json" || fail "import left relay on"
[ "$(cat "$SECOND_HOME/.claude/.credentials.json")" = "$SECOND_BEFORE" ] || fail "import changed the login in use"
with_tty "$PASSPHRASE
" env HOME="$SECOND_HOME" "$BIN" import "$ARCHIVE"
[ "$(HOME="$SECOND_HOME" "$BIN" list | grep -c '\[已停用\]')" = 4 ] || fail "a second import added accounts"

# Unbinding keeps the project's configuration and login.
lilt project unbind "$PA" >/dev/null || fail "unbind"
[ -f "$CONFIG_A/.credentials.json" ] || fail "unbind removed the project login"
lilt project list > "$FIX/projects-final.txt"
if grep -q 'Project A' "$FIX/projects-final.txt"; then fail "unbound project still listed"; fi
lilt remove Fixture-T --yes >/dev/null
lilt release >/dev/null
for log in "$FIX"/*.log; do
    if grep -q -e "$PASSPHRASE" -e 'fixture-access' -e 'fixture-only' "$log"; then fail "secret in $(basename "$log")"; fi
done
printf 'PASS: Linux CLI/socket/daemon — takeover, token import, switch, config, JSON, two isolated projects (bind/status/run/rebind/unbind, restart), lilt run as the official CLI (cwd, environment, arguments, stdio, exit status, signals, no shell, no fallback), encrypted export/import through a terminal; isolated HOMEs, fake claude, no network.\n'
