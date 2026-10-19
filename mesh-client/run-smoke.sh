#!/bin/sh
# End-to-end smoke for the Swift mesh client against the real Go server.
#
# Boots meshserver (built from ../mesh-server) on a loopback port with
# two test invites, then drives two Swift devices (separate identity
# dirs) through: register -> pair request -> approve -> presence ->
# WebSocket signaling (offer one way, answer back). Every step prints a
# PASS line from mesh-smoke; this script asserts them all and exits
# non-zero on any failure.
set -u

CLIENT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SERVER_DIR="$CLIENT_DIR/../mesh-server"
GO=${GO:-"$HOME/workspace/toolchains/go/bin/go"}
SWIFT=${SWIFT:-"$HOME/workspace/toolchains/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swift"}

WORK=$(mktemp -d /tmp/mesh-smoke.XXXXXX)
SERVER_PID=""
LISTENER_PID=""

cleanup() {
    [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

fail() {
    echo "SMOKE FAIL: $1" >&2
    echo "--- server log ---" >&2; cat "$WORK/server.log" >&2 2>/dev/null
    echo "--- listener log ---" >&2; cat "$WORK/listener.log" >&2 2>/dev/null
    exit 1
}

# --- allocate a free loopback port -------------------------------------
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
) || fail "cannot allocate a port"
BASE="http://127.0.0.1:$PORT"
echo "smoke: server at $BASE (workdir $WORK)"

# --- build the Go server and the Swift package --------------------------
(cd "$SERVER_DIR" && "$GO" build -o "$WORK/meshserver" ./cmd/meshserver) \
    || fail "go build of mesh-server failed"
(cd "$CLIENT_DIR" && "$SWIFT" build) || fail "swift build failed"
SMOKE="$CLIENT_DIR/.build/debug/mesh-smoke"
[ -x "$SMOKE" ] || fail "mesh-smoke binary missing"

# --- boot the server -----------------------------------------------------
cat > "$WORK/config.json" <<EOF
{"listen": "127.0.0.1:$PORT", "data_dir": "$WORK/data", "invites": ["smoke-invite-a", "smoke-invite-b"]}
EOF
"$WORK/meshserver" -config "$WORK/config.json" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!

i=0
while [ $i -lt 50 ]; do
    if curl -sf "$BASE/healthz" >/dev/null 2>&1; then break; fi
    i=$((i + 1)); sleep 0.2
done
curl -sf "$BASE/healthz" >/dev/null 2>&1 || fail "server did not become healthy"

# --- register both devices ------------------------------------------------
DIR_A="$WORK/device-a"
DIR_B="$WORK/device-b"
"$SMOKE" register --server "$BASE" --dir "$DIR_A" --name "smoke-mac" --invite smoke-invite-a \
    || fail "register A"
"$SMOKE" register --server "$BASE" --dir "$DIR_B" --name "smoke-windows" --invite smoke-invite-b \
    || fail "register B"
ID_A=$(cat "$DIR_A/mesh-id.txt")
ID_B=$(cat "$DIR_B/mesh-id.txt")
echo "smoke: A=$ID_A B=$ID_B"

# --- pairing: A requests, B approves --------------------------------------
"$SMOKE" pair-request --server "$BASE" --dir "$DIR_A" --peer "$ID_B" \
    || fail "pair-request"
"$SMOKE" pair-approve --server "$BASE" --dir "$DIR_B" --peer "$ID_A" \
    || fail "pair-approve"
"$SMOKE" pair-list --server "$BASE" --dir "$DIR_B" | grep -q "peers=$ID_A" \
    || fail "B's local pairing record does not list A"

# --- presence: nobody is connected yet -------------------------------------
"$SMOKE" presence --server "$BASE" --dir "$DIR_A" --id "$ID_B" --expect offline \
    || fail "presence B should be offline before signaling connects"

# --- signaling: B listens in background, A sends ---------------------------
"$SMOKE" signal-listen --server "$BASE" --dir "$DIR_B" --from "$ID_A" \
    --expect-data "smoke-offer-sdp" --reply-data "smoke-answer-sdp" \
    >"$WORK/listener.log" 2>&1 &
LISTENER_PID=$!

i=0
while [ $i -lt 50 ]; do
    if grep -q "PASS signal-connected" "$WORK/listener.log" 2>/dev/null; then break; fi
    kill -0 "$LISTENER_PID" 2>/dev/null || fail "listener exited early"
    i=$((i + 1)); sleep 0.2
done
grep -q "PASS signal-connected" "$WORK/listener.log" || fail "listener never connected"

# B holds an authenticated signaling connection now: presence flips online.
"$SMOKE" presence --server "$BASE" --dir "$DIR_A" --id "$ID_B" --expect online \
    || fail "presence B should be online while signaling is connected"

"$SMOKE" signal-send --server "$BASE" --dir "$DIR_A" --to "$ID_B" \
    --data "smoke-offer-sdp" --expect-reply "smoke-answer-sdp" \
    || fail "signal-send"

wait "$LISTENER_PID" || fail "listener failed"
LISTENER_PID=""
cat "$WORK/listener.log"

# A learned the pairing from the relayed reply envelope as well.
"$SMOKE" pair-list --server "$BASE" --dir "$DIR_A" | grep -q "peers=$ID_B" \
    || fail "A's local pairing record does not list B"

echo "SMOKE RESULT: PASS"
