#!/usr/bin/env bash
#
# /usr/local/sbin/vpn-relay-health.sh — deployed by provision-vps.sh
#
# READ-ONLY reporter of the VPS relay routing invariants. Invoked over SSH by
# the T15 snapshot via a forced-command key (command="/usr/local/sbin/vpn-relay-
# health.sh",restrict), so it must never mutate anything and never take args.
#
# Prints one line per invariant plus a final summary line the T15 parses:
#   RELAY: ok        — all invariants hold
#   RELAY: degraded  — at least one is broken (clients likely have no internet)
#
# This is the detection counterpart to vpn-relay-guard.sh: the guard repairs,
# this reports. Both check the same four invariants.

set -uo pipefail

WG_IF=wg0
VPN_SUBNET=10.100.0.0/24
T15_WG_IP=10.100.0.2
RT_TABLE=100

bad=0
ck() { # ck "label" "condition-cmd..."  → prints OK/FAIL
  if eval "$2" &>/dev/null; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n' "$1"
    bad=$((bad+1))
  fi
}

if ! ip link show "$WG_IF" &>/dev/null; then
  echo "  FAIL $WG_IF interface (wg-quick@wg0 down)"
  echo "RELAY: degraded"
  exit 0
fi

ck "ip_forward enabled"                 '[[ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]]'
ck "ip rule from $VPN_SUBNET -> t.$RT_TABLE" "ip rule show | grep -q 'from $VPN_SUBNET lookup $RT_TABLE'"
ck "table $RT_TABLE default via $T15_WG_IP"  "ip route show table $RT_TABLE | grep -q 'default via $T15_WG_IP'"
ck "FORWARD accept -i $WG_IF"           "iptables -C FORWARD -i $WG_IF -j ACCEPT 2>/dev/null"
ck "FORWARD accept -o $WG_IF"           "iptables -C FORWARD -o $WG_IF -j ACCEPT 2>/dev/null"

# Guard liveness — if the timer is dead, invariants won't self-heal.
if systemctl is-active --quiet vpn-relay-guard.timer; then
  echo "  ok   vpn-relay-guard.timer active"
else
  echo "  FAIL vpn-relay-guard.timer inactive (no self-heal)"
  bad=$((bad+1))
fi

if (( bad == 0 )); then echo "RELAY: ok"; else echo "RELAY: degraded"; fi
exit 0
