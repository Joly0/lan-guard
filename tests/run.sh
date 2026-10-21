#!/bin/sh
# End-to-end test: starts lan-guard with a client behind it and checks that
# private targets are blocked, the internet is reachable, and the health check
# notices tampering. Needs Docker with compose and internet access.
#
#   IMAGE=lan-guard:dev tests/run.sh
set -u

IMAGE="${IMAGE:-lan-guard:dev}"
PROJECT=lgtest-$$
DIR=$(mktemp -d)
fails=0

pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; fails=$((fails + 1)); }

cleanup() {
  docker compose -p "$PROJECT" -f "$DIR/compose.yml" down --timeout 1 >/dev/null 2>&1
  docker rm "$PROJECT-target" >/dev/null 2>&1
  rm -r "$DIR"
}
trap cleanup EXIT

cat >"$DIR/compose.yml" <<EOF
services:
  guard:
    image: $IMAGE
    cap_add: [NET_ADMIN]
  client:
    image: busybox:1.37
    command: sleep 600
    network_mode: "service:guard"
    depends_on:
      guard: { condition: service_healthy }
  # Same network, no guard: proves the targets are reachable at all, so a
  # "blocked" result below is the guard's doing and not Docker's isolation.
  control:
    image: busybox:1.37
    command: sleep 600
EOF

# A web server published on the host stands in for a service on the LAN.
docker run -d --name "$PROJECT-target" -p 18080:8080 busybox:1.37 httpd -f -p 8080 >/dev/null

docker compose -p "$PROJECT" -f "$DIR/compose.yml" up -d --wait >/dev/null 2>&1 \
  && pass "guard became healthy and the client started" \
  || { fail "stack did not come up"; docker compose -p "$PROJECT" -f "$DIR/compose.yml" logs guard; exit 1; }

client() { docker compose -p "$PROJECT" -f "$DIR/compose.yml" exec -T client "$@"; }
guard() { docker compose -p "$PROJECT" -f "$DIR/compose.yml" exec -T guard "$@"; }

control() { docker compose -p "$PROJECT" -f "$DIR/compose.yml" exec -T control "$@"; }

gw=$(client ip route | awk '/^default/ {print $3}')
control nc -w 3 "$gw" 18080 </dev/null >/dev/null 2>&1 \
  && pass "control: host service $gw:18080 reachable without the guard" \
  || fail "control cannot reach $gw:18080, so the blocked check below proves nothing"

client nc -w 3 "$gw" 18080 </dev/null >/dev/null 2>&1 \
  && fail "host service $gw:18080 reachable through the guard" || pass "host service $gw:18080 blocked"

client nc -w 5 1.1.1.1 443 </dev/null >/dev/null 2>&1 \
  && pass "internet (1.1.1.1:443) reachable" || fail "internet unreachable"

client nslookup github.com >/dev/null 2>&1 \
  && pass "DNS works" || fail "DNS broken"

guard lan-guard health >/dev/null 2>&1 && pass "health ok" || fail "health fails on an intact guard"

backend=$(guard cat /run/lan-guard/backend)
guard iptables-"$backend" -I OUTPUT 1 -d 172.16.0.0/12 -j ACCEPT
guard lan-guard health >/dev/null 2>&1 \
  && fail "health passes with a bypass rule inserted" || pass "health catches a bypass rule"

guard iptables-"$backend" -F OUTPUT
guard lan-guard health >/dev/null 2>&1 \
  && fail "health passes with rules flushed" || pass "health catches flushed rules"

echo
[ "$fails" -eq 0 ] && echo "all tests passed" || echo "$fails test(s) failed"
[ "$fails" -eq 0 ]
