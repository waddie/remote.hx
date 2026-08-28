#!/bin/sh
# Socket-level test: a real server in its own process, driven by bin/hx-send.
#
# Deliberately cross-process. A client and server sharing one Steel runtime can
# deadlock on a request/response round trip, so the suite never drives a socket
# from inside the process that serves it.
set -eu
cd "$(dirname "$0")/.."

STEEL=${STEEL:-steel}
HELIX_REMOTE_DIR=$(mktemp -d)
export HELIX_REMOTE_DIR

fails=0
server_pid=

cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$HELIX_REMOTE_DIR"
}
trap cleanup EXIT

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
        fails=$((fails + 1))
    fi
}

"$STEEL" tests/integration-server.scm work >"$HELIX_REMOTE_DIR/server.log" 2>&1 &
server_pid=$!

# Wait for the session file to appear rather than sleeping a fixed time.
tries=0
while [ ! -f "$HELIX_REMOTE_DIR/work.session" ]; do
    tries=$((tries + 1))
    [ "$tries" -gt 100 ] && { echo "server did not start:"; cat "$HELIX_REMOTE_DIR/server.log"; exit 1; }
    sleep 0.1
done

HX=bin/hx-send

check "ping names the session" "pong work" "$($HX --ping)"
check "a command reaches the runner" "ran open [/tmp/x.txt]" "$($HX open /tmp/x.txt)"
check "spaces in paths survive" "ran open [/tmp/a b.txt]" "$($HX open '/tmp/a b.txt')"
check "denied commands are refused" "error command not permitted: write" "$($HX write || true)"
check "eval is off by default" "error eval is disabled" "$($HX --eval '(+ 1 2)' || true)"
check "malformed names are refused" "error bad command name" "$($HX 'open; rm -rf /' || true)"
check "unknown commands are refused" "error unknown command: frobnicate" "$($HX frobnicate || true)"

# A wrong token must be rejected even though the port is open.
port=$(sed -n 's/^port=//p' "$HELIX_REMOTE_DIR/work.session")
bad=$(printf 'wrong\ncmd\nopen\n/tmp/x\n\n' | nc 127.0.0.1 "$port")
check "a bad token is rejected" "error unauthorised" "$bad"

# The listing and the environment route both find the same server.
check "--list finds the session" "work" "$($HX --list | cut -f1)"
token=$(sed -n 's/^token=//p' "$HELIX_REMOTE_DIR/work.session")
env_reply=$(HELIX_REMOTE=127.0.0.1:$port HELIX_REMOTE_TOKEN=$token $HX --ping)
check "\$HELIX_REMOTE routes without a session file" "pong work" "$env_reply"

# Exit codes matter: scripts branch on them.
if $HX write >/dev/null 2>&1; then
    printf 'FAIL a refused command exits non-zero\n'
    fails=$((fails + 1))
else
    printf 'ok   a refused command exits non-zero\n'
fi

# Shutdown, then confirm the server stopped answering.
printf '%s\nshutdown\n\n' "$token" | nc 127.0.0.1 "$port" >/dev/null
sleep 0.5
after=$(printf '%s\nping\n\n' "$token" | nc -w 2 127.0.0.1 "$port" || true)
check "shutdown stops the server" "" "$after"

if [ "$fails" -eq 0 ]; then
    printf '\nintegration: all checks passed\n'
else
    printf '\nintegration: %s failed\n' "$fails"
    exit 1
fi
