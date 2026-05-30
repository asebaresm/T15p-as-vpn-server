#!/usr/bin/env bash
#
# /usr/local/sbin/vpn-relay-guard.sh — deployed by provision-vps.sh
#
# Re-asserts the VPS relay's routing invariants every 60s (via
# vpn-relay-guard.timer). These are the same things wg-quick's PostUp sets, but
# PostUp only runs at tunnel up/down — so anything that churns the network state
# WITHOUT bouncing wg (installing docker.io, apt netfilter upgrades, a manual
# `ip rule flush`, etc.) silently breaks the double-hop and nothing repairs it.
#
# Real incident this guards against: installing Docker on the VPS reset the
# policy-routing rule table to defaults, dropping `from 10.100.0.0/24 lookup
# 100`. The route in table 100 survived, so `ip route show table 100` looked
# fine, but every VPN client lost internet. The T15-side watchdog couldn't see
# it (its own path to the internet was unaffected).
#
# Invariants (all idempotent — a healthy run changes nothing and logs nothing):
#   1. net.ipv4.ip_forward = 1
#   2. ip rule:  from 10.100.0.0/24 lookup 100
#   3. table 100: default via 10.100.0.2 dev wg0
#   4. iptables FORWARD: accept i/o wg0  (Docker prepends its own chains; the
#      wg0 accepts must still exist somewhere in the chain)
#
# Exits 0 always (it's a repair loop, not a health gate). Logs fixes to journald
# under tag "vpn-relay-guard".

set -uo pipefail

WG_IF=wg0
VPN_SUBNET=10.100.0.0/24
T15_WG_IP=10.100.0.2
RT_TABLE=100

log() { logger -t vpn-relay-guard "$1"; }
fixed=0

# wg0 must exist; if not, wg-quick is down — let its own unit handle recovery.
if ! ip link show "$WG_IF" &>/dev/null; then
  log "$WG_IF absent — wg-quick@wg0 is down; not repairing routing without the tunnel"
  exit 0
fi

# 1. IP forwarding
if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]]; then
  sysctl -w net.ipv4.ip_forward=1 >/dev/null && { log "ip_forward was off — re-enabled"; fixed=$((fixed+1)); }
fi

# 2. policy-routing rule  (the one Docker wiped)
if ! ip rule show | grep -q "from $VPN_SUBNET lookup $RT_TABLE"; then
  ip rule add from "$VPN_SUBNET" table "$RT_TABLE" && { log "ip rule 'from $VPN_SUBNET lookup $RT_TABLE' missing — re-added"; fixed=$((fixed+1)); }
fi

# 3. default route in the policy table
if ! ip route show table "$RT_TABLE" 2>/dev/null | grep -q "default via $T15_WG_IP"; then
  ip route replace default via "$T15_WG_IP" dev "$WG_IF" table "$RT_TABLE" && { log "table $RT_TABLE default route missing — re-added via $T15_WG_IP"; fixed=$((fixed+1)); }
fi

# 4. FORWARD accepts for wg0 (idempotent check-then-add)
if ! iptables -C FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null; then
  iptables -A FORWARD -i "$WG_IF" -j ACCEPT && { log "FORWARD -i $WG_IF ACCEPT missing — re-added"; fixed=$((fixed+1)); }
fi
if ! iptables -C FORWARD -o "$WG_IF" -j ACCEPT 2>/dev/null; then
  iptables -A FORWARD -o "$WG_IF" -j ACCEPT && { log "FORWARD -o $WG_IF ACCEPT missing — re-added"; fixed=$((fixed+1)); }
fi

(( fixed > 0 )) && log "re-asserted $fixed relay invariant(s)"
exit 0
