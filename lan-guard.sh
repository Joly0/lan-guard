#!/bin/sh
# lan-guard: keeps every container that shares this network namespace
# (network_mode: "service:lan-guard") away from private and local networks,
# while leaving the public internet reachable.
#
# Usage:
#   lan-guard run      apply the rules, then stay running (container entrypoint)
#   lan-guard health   exit 0 only if every rule is still in place and the
#                      Docker host is actually unreachable
#
# The rules are applied atomically with iptables-restore. Any failure exits
# non-zero, so the container never becomes healthy and the containers that
# depend on it never start: lan-guard fails closed, never open.

set -eu

STATE_DIR=/run/lan-guard

DEFAULT_BLOCK_SUBNETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 fc00::/7 fe80::/10"

BLOCK_SUBNETS="${BLOCK_SUBNETS:-$DEFAULT_BLOCK_SUBNETS}"
ALLOW_SUBNETS="${ALLOW_SUBNETS:-}"
LOG_BLOCKED="${LOG_BLOCKED:-false}"
BACKEND="${BACKEND:-auto}"

log() { echo "lan-guard: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Lists may be separated by commas, spaces or newlines.
words() { echo "$1" | tr ',\n' '  '; }

is_v6() { case "$1" in *:*) return 0 ;; *) return 1 ;; esac; }

# family_of <subnet>: prints 4 or 6.
family_of() { if is_v6 "$1"; then echo 6; else echo 4; fi; }

# --- Backend -----------------------------------------------------------------
#
# The kernel evaluates nft and legacy rules side by side, so the choice only
# decides where the rules are stored. Prefer nft, fall back to legacy on
# kernels without nf_tables.
pick_backend() {
  case "$BACKEND" in
    nft|legacy) echo "$BACKEND"; return ;;
    auto) ;;
    *) die "BACKEND must be auto, nft or legacy (got '$BACKEND')" ;;
  esac
  for b in nft legacy; do
    if iptables-$b -t filter -S >/dev/null 2>&1; then echo "$b"; return; fi
  done
  die "no working iptables backend. Is the container started with cap_add: NET_ADMIN?"
}

ipv6_present() { [ -s /proc/net/if_inet6 ]; }

# --- Ruleset -----------------------------------------------------------------

# ruleset <4|6> <REJECT|DROP>: prints an iptables-restore document.
ruleset() {
  fam=$1 action=$2
  if [ "$action" = REJECT ]; then
    if [ "$fam" = 4 ]; then target="REJECT --reject-with icmp-admin-prohibited"
    else target="REJECT --reject-with adm-prohibited"; fi
  else
    target=DROP
  fi

  echo "*filter"
  echo ":INPUT ACCEPT [0:0]"
  echo ":FORWARD ACCEPT [0:0]"
  echo ":OUTPUT ACCEPT [0:0]"
  echo "-A OUTPUT -o lo -j ACCEPT"
  echo "-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
  for net in $(words "$ALLOW_SUBNETS"); do
    if [ "$(family_of "$net")" = "$fam" ]; then
      echo "-A OUTPUT -d $net -j ACCEPT"
    fi
  done
  for net in $(words "$BLOCK_SUBNETS"); do
    if [ "$(family_of "$net")" = "$fam" ]; then
      if [ "$LOG_BLOCKED" = true ]; then
        echo "-A OUTPUT -d $net -m limit --limit 6/min -j LOG --log-prefix \"lan-guard blocked: \""
      fi
      echo "-A OUTPUT -d $net -j $target"
    fi
  done
  echo "COMMIT"
}

# apply <4|6> <backend>: tries REJECT, falls back to DROP when the host kernel
# cannot provide the REJECT target to this namespace. Records what it applied
# so the health check can compare against it.
apply() {
  fam=$1 be=$2
  if [ "$fam" = 4 ]; then tool=iptables-$be; else tool=ip6tables-$be; fi
  for action in REJECT DROP; do
    if ruleset "$fam" "$action" | $tool-restore 2>"$STATE_DIR/err.v$fam"; then
      [ "$action" = DROP ] && log "IPv$fam: REJECT unavailable, blocking with DROP ($(cat "$STATE_DIR/err.v$fam"))"
      # Snapshot the rules as the kernel reports them: iptables-save rewrites
      # option order and quoting, so comparing against our own text would fail.
      $tool-save -t filter 2>/dev/null | grep '^-A' >"$STATE_DIR/expected.v$fam"
      log "IPv$fam: $(grep -c ' -j \(REJECT\|DROP\)' "$STATE_DIR/expected.v$fam") subnets blocked ($action)"
      return 0
    fi
  done
  die "IPv$fam: could not apply rules: $(cat "$STATE_DIR/err.v$fam")"
}

# --- Health ------------------------------------------------------------------

rules_intact() {
  fam=$1 be=$2
  [ -f "$STATE_DIR/expected.v$fam" ] || return 1
  if [ "$fam" = 4 ]; then save=iptables-$be-save; else save=ip6tables-$be-save; fi
  current=$($save -t filter 2>/dev/null) || return 1
  while IFS= read -r rule; do
    echo "$current" | grep -qxF -- "$rule" || { log "IPv$fam rule missing: $rule"; return 1; }
  done <"$STATE_DIR/expected.v$fam"
}

# A live probe on top of the rule comparison: the default gateway is the Docker
# host. Connect to it and require the block rules' packet counters to rise,
# which proves the packet was stopped here rather than reaching the host. The
# connect result alone cannot tell: busybox nc fails the same way whether the
# packet was blocked or the host refused it.
gateway_blocked() {
  be=$1
  gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
  [ -n "$gw" ] || return 0
  if ! is_blocked_v4 "$gw"; then return 0; fi
  before=$(blocked_packets "$be")
  if nc -w 2 "$gw" 1 </dev/null >/dev/null 2>&1; then
    log "gateway $gw reachable"; return 1
  fi
  after=$(blocked_packets "$be")
  [ "$after" -gt "$before" ] || { log "probe to gateway $gw was not stopped by lan-guard"; return 1; }
}

# Total packets matched by the IPv4 block rules.
blocked_packets() {
  iptables-$1 -L OUTPUT -n -v -x 2>/dev/null |
    awk '$3 == "REJECT" || $3 == "DROP" { n += $1 } END { print n + 0 }'
}

# Whether an IPv4 address falls in a blocked and not allowed subnet, so the
# probe is skipped when the user deliberately allowed the gateway.
is_blocked_v4() {
  ip=$1
  for net in $(words "$ALLOW_SUBNETS"); do
    if ! is_v6 "$net" && in_subnet "$ip" "$net"; then return 1; fi
  done
  for net in $(words "$BLOCK_SUBNETS"); do
    if ! is_v6 "$net" && in_subnet "$ip" "$net"; then return 0; fi
  done
  return 1
}

ip2int() { echo "$1" | awk -F. '{print (($1*256+$2)*256+$3)*256+$4}'; }

in_subnet() {
  addr=${2%/*} bits=${2#*/}
  [ "$bits" = "$2" ] && bits=32
  awk -v a="$(ip2int "$1")" -v n="$(ip2int "$addr")" -v b="$bits" 'BEGIN {
    m = 2^(32-b); exit !(int(a/m) == int(n/m))
  }'
}

# --- Main --------------------------------------------------------------------

cmd_run() {
  mkdir -p "$STATE_DIR"
  be=$(pick_backend)
  echo "$be" >"$STATE_DIR/backend"
  log "backend: iptables-$be"
  apply 4 "$be"
  if ipv6_present; then
    apply 6 "$be"
  else
    log "IPv6: not present in this namespace, nothing to block"
    : >"$STATE_DIR/expected.v6"
  fi
  [ -n "$ALLOW_SUBNETS" ] && log "allowed exceptions: $(words "$ALLOW_SUBNETS")"
  cmd_health || die "rules applied but the health check fails"
  log "active"
  trap 'log "stopping"; exit 0' TERM INT
  while :; do sleep 3600 & wait $!; done
}

cmd_health() {
  be=$(cat "$STATE_DIR/backend" 2>/dev/null) || { log "not started"; return 1; }
  rules_intact 4 "$be" || return 1
  if [ -s "$STATE_DIR/expected.v6" ]; then rules_intact 6 "$be" || return 1; fi
  gateway_blocked "$be" || return 1
}

case "${1:-run}" in
  run) cmd_run ;;
  health) cmd_health ;;
  *) die "unknown command '$1' (use: run, health)" ;;
esac
