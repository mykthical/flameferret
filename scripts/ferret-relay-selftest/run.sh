#!/bin/bash
# End-to-end test of Ferret's NordVPN relay on macOS: real Network.framework relay code, a fake
# credential-checking proxy, and curl traffic through it. Run from the repository root.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../firefox-ios/Client/Frontend/Browser/NordProxy"
WORK="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"' EXIT

# Same strictness as the app target.
swiftc -swift-version 6 -parse-as-library -typecheck "$SRC/NordProxyRelay.swift" "$SRC/NordProxyWire.swift"
swiftc -O -o "$WORK/relaytest" "$HERE/main.swift" "$SRC/NordProxyRelay.swift" "$SRC/NordProxyWire.swift"

mkdir -p "$WORK/site"
echo "ferret-relay-ok" > "$WORK/site/ok.txt"
head -c 8000000 /dev/urandom > "$WORK/site/big.bin"
(cd "$WORK/site" && python3 -m http.server 18080 --bind 127.0.0.1 >/dev/null 2>&1) &
python3 "$HERE/fake_nord_proxy.py" 18089 user 'pa:ss!' &
sleep 2

start_relay() {
    "$WORK/relaytest" relay 18089 "$1" "$2" > "$WORK/$3.out" 2> "$WORK/$3.log" &
    for _ in $(seq 1 50); do
        if grep -q "PORT=" "$WORK/$3.out" 2>/dev/null; then break; fi
        sleep 0.1
    done
    grep -o "PORT=[0-9a-z]*" "$WORK/$3.out" | cut -d= -f2
}

fail() {
    echo "::error title=Relay self-test::$1"
    echo "SELFTEST FAILED: $1"
    for log in "$WORK"/*.log; do [ -f "$log" ] && { echo "--- $log"; tail -40 "$log"; }; done
    exit 1
}
step() { echo "::notice title=Relay self-test::$1"; echo "STEP: $1"; }

step "starting relay"
GOOD=$(start_relay user 'pa:ss!' good)
step "relay listening on $GOOD"
[ "$GOOD" != "none" ] && [ -n "$GOOD" ] || fail "relay did not start"

BODY=$(curl -s --noproxy '' --max-time 10 --proxytunnel -x "http://127.0.0.1:$GOOD" http://127.0.0.1:18080/ok.txt) \
    || fail "page through relay: curl exit $? (relay output: $(cat "$WORK/good.out"))"
[ "$BODY" = "ferret-relay-ok" ] || fail "page through relay: got '$BODY'"

curl -s --noproxy '' --max-time 30 --proxytunnel -x "http://127.0.0.1:$GOOD" http://127.0.0.1:18080/big.bin -o "$WORK/big.out" \
    || fail "8 MB download through relay: curl exit $?"
cmp -s "$WORK/site/big.bin" "$WORK/big.out" || fail "8 MB download through relay was corrupted"

for i in $(seq 1 12); do
    curl -s --noproxy '' --max-time 10 --proxytunnel -x "http://127.0.0.1:$GOOD" http://127.0.0.1:18080/ok.txt -o "$WORK/p$i" &
done
wait_for=0
for i in $(seq 1 12); do
    while [ ! -s "$WORK/p$i" ] && [ $wait_for -lt 100 ]; do sleep 0.1; wait_for=$((wait_for + 1)); done
    [ "$(cat "$WORK/p$i" 2>/dev/null)" = "ferret-relay-ok" ] || fail "parallel request $i failed"
done

CODE=$(curl -s --noproxy '' -o /dev/null -w "%{http_code}" --max-time 10 -x "http://127.0.0.1:$GOOD" http://127.0.0.1:18080/ok.txt || true)
[ "$CODE" = "405" ] || fail "plain GET to the relay should get 405, got $CODE"

BAD=$(start_relay user wrong bad)
if curl -s --noproxy '' --max-time 10 --proxytunnel -x "http://127.0.0.1:$BAD" http://127.0.0.1:18080/ok.txt -o /dev/null; then
    fail "wrong credentials still loaded the page"
fi

step "local checks passed; probing"
PROBE=$("$WORK/relaytest" probe 18089 user 'pa:ss!' 18080)
[ "$PROBE" = "PROBE=ok" ] || fail "probe with good credentials: $PROBE"
PROBE=$("$WORK/relaytest" probe 18089 user wrong 18080)
[ "$PROBE" = "PROBE=rejected(status: 407)" ] || fail "probe with wrong credentials: $PROBE"

# A real NordVPN HTTPS proxy, through Apple's TLS stack: the certificate must verify and the server must ask
# for credentials (407). Skipped if NordVPN's server list can't be fetched.
HOST=$(curl -s --noproxy '' --max-time 20 "https://api.nordvpn.com/v1/servers/recommendations?filters%5Bservers_technologies%5D%5Bidentifier%5D=proxy_ssl&limit=1" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['hostname'])" 2>/dev/null || true)
if [ -n "$HOST" ]; then
    PROXY_HOST="${HOST%.nordvpn.com}.proxy.nordvpn.com"
    PROBE=$("$WORK/relaytest" realprobe "$PROXY_HOST")
    [ "$PROBE" = "PROBE=rejected(status: 407)" ] || fail "real NordVPN proxy $PROXY_HOST: $PROBE"
    echo "Real NordVPN proxy $PROXY_HOST: TLS verified, credentials requested"
else
    echo "::warning title=Relay self-test::Couldn't fetch NordVPN's server list; skipped the live proxy check"
fi

echo "Relay self-test passed"
