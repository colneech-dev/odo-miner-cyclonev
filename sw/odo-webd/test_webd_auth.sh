#!/bin/bash
# test_webd_auth.sh — endpoint regression for odo-webd's opt-in auth (added in
# the 2026-06-28 review pass). Builds the server, runs it unprivileged on a high
# port with ODO_WEB_CONF pointing at a temp config, and asserts the gate +
# session behaviour — especially the bypass cases the review closed:
#   * cookie token must come from the Cookie header, not the body (C1),
#   * empty/forged tokens rejected (C2),
#   * /logout requires auth (H2),
#   * wrong password issues no cookie; correct password gates the dashboard.
# Needs only cc + curl. Safe for CI.
set -u
cd "$(dirname "$0")"

PORT=${PORT:-18080}
PW='s3cr3t-pw'
TMP=$(mktemp -d)
BIN="$TMP/odo-webd"
PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

echo "=== building odo-webd ==="
cc -O2 -Wall -o "$BIN" odo_webd.c || { echo "build failed"; exit 1; }

start_server() {   # $1 = conf path ("" for auth-disabled)
    [ -n "$PID" ] && { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }
    ODO_WEB_CONF="$1" "$BIN" "$PORT" >/dev/null 2>&1 &
    PID=$!
    sleep 0.5
}

B="http://127.0.0.1:$PORT"
fails=0
ok()   { echo "  ok:   $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

# ---- auth ENABLED ----
printf 'PASSWORD=%s\n' "$PW" > "$TMP/conf"
start_server "$TMP/conf"
echo "=== auth enabled ==="

curl -s "$B/status.json"            | grep -qi "Sign in" && ok "unauth route gated" || fail "unauth route NOT gated"
curl -s -i -X POST -d "password=nope" "$B/login" | grep -qi "set-cookie" && fail "wrong password set a cookie" || ok "wrong password no cookie"

TOK=$(curl -s -i -X POST -d "password=$PW" "$B/login" | sed -n 's/.*odosession=\([0-9a-f]\{32\}\).*/\1/p')
[ -n "$TOK" ] && ok "correct login issues 32-hex token" || fail "login issued no token"

curl -s --cookie "odosession=$TOK" "$B/status.json" | grep -qi "Sign in" && fail "valid session blocked" || ok "valid session passes gate"

# C1: token in the BODY (no Cookie header) must NOT authenticate
curl -s -X POST --data "odosession=$TOK&action=fan_auto" "$B/action" | grep -qi "Sign in" && ok "token-in-body rejected (C1)" || fail "token-in-body ACCEPTED (C1 bypass)"

# C2: empty / forged tokens
curl -s --cookie "odosession=" "$B/status.json" | grep -qi "Sign in" && ok "empty token rejected" || fail "empty token accepted"
FORGE=$(printf 'a%.0s' $(seq 1 32))
curl -s --cookie "odosession=$FORGE" "$B/status.json" | grep -qi "Sign in" && ok "forged token rejected" || fail "forged token accepted"

# H2: unauthenticated logout must be refused (not a 303 redirect)
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/logout")
[ "$code" != "303" ] && ok "unauth /logout refused (H2)" || fail "unauth /logout accepted (H2)"

# logout with the valid cookie invalidates the token
curl -s -X POST --cookie "odosession=$TOK" "$B/logout" >/dev/null
curl -s --cookie "odosession=$TOK" "$B/status.json" | grep -qi "Sign in" && ok "token invalid after logout" || fail "token still valid after logout"

# ---- auth DISABLED (default) ----
: > "$TMP/conf_open"   # no PASSWORD line
start_server "$TMP/conf_open"
echo "=== auth disabled (default) ==="
curl -s "$B/status.json" | grep -qi "Sign in" && fail "open mode still gated" || ok "open mode serves without login"

echo "==========================================="
if [ "$fails" -eq 0 ]; then echo "WEBD AUTH TEST: PASS"; exit 0; fi
echo "WEBD AUTH TEST: FAIL ($fails)"; exit 1
