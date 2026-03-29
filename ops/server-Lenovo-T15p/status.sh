#!/usr/bin/env bash
# Reports the health of all T15p server components.
# Run from the T15p (no root required for most checks).
#
# Usage: bash ops/server-Lenovo-T15p/status.sh

PASS="✓"
FAIL="✗"
WARN="~"

ok()   { echo "  $PASS $1"; }
fail() { echo "  $FAIL $1"; }
warn() { echo "  $WARN $1"; }
header() { echo; echo "── $1 ──────────────────────────────"; }

# ── WAN ───────────────────────────────────────────────────────────────────────
header "WAN (building WiFi)"

WAN_IFACE=wlp0s20f3
WAN_IP=$(ip -4 addr show "$WAN_IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
if [[ -n "$WAN_IP" ]]; then
  ok "$WAN_IFACE up — $WAN_IP"
else
  fail "$WAN_IFACE has no IP (not connected to building WiFi)"
fi

if ping -c 1 -W 2 -I "$WAN_IFACE" 8.8.8.8 &>/dev/null; then
  ok "internet reachable via $WAN_IFACE"
else
  fail "no internet via $WAN_IFACE"
fi

# ── LAN / MR550 ───────────────────────────────────────────────────────────────
header "LAN (enp0s31f6 → MR550)"

LAN_IFACE=enp0s31f6
LAN_IP=$(ip -4 addr show "$LAN_IFACE" 2>/dev/null | awk '/inet / {print $2}' | head -1)
if [[ "$LAN_IP" == "192.168.10.1/24" ]]; then
  ok "$LAN_IFACE up — $LAN_IP"
else
  fail "$LAN_IFACE not configured (expected 192.168.10.1/24, got '${LAN_IP:-none}')"
fi

if systemctl is-active --quiet dnsmasq; then
  ok "dnsmasq running"
  LEASES=$(cat /var/lib/misc/dnsmasq.leases 2>/dev/null | wc -l)
  if [[ "$LEASES" -gt 0 ]]; then
    ok "$LEASES DHCP lease(s) active"
    cat /var/lib/misc/dnsmasq.leases | awk '{printf "      %s  %s  %s\n", $3, $4, $2}'
  else
    warn "no DHCP leases yet (MR550 not connected or not requesting?)"
  fi
else
  fail "dnsmasq not running"
fi

# ── WIREGUARD ─────────────────────────────────────────────────────────────────
header "WireGuard (wg0)"

WG_IP=$(ip -4 addr show wg0 2>/dev/null | awk '/inet / {print $2}' | head -1)
if [[ -n "$WG_IP" ]]; then
  ok "wg0 up — $WG_IP"
else
  fail "wg0 interface not up"
fi

if command -v wg &>/dev/null; then
  HANDSHAKE=$(sudo wg show wg0 2>/dev/null | awk '/latest handshake/ {$1=$2=""; sub(/^ +/,""); print}')
  TRANSFER=$(sudo wg show wg0 2>/dev/null | awk '/transfer/ {print $2, $3, "rx /", $5, $6, "tx"}')
  ENDPOINT=$(sudo wg show wg0 2>/dev/null | awk '/endpoint/ {print $2}')
  if [[ -n "$HANDSHAKE" ]]; then
    ok "VPS handshake: $HANDSHAKE ago"
    ok "endpoint: $ENDPOINT"
    ok "transfer: $TRANSFER"
  else
    fail "no handshake with VPS yet"
  fi

  if ping -c 1 -W 2 10.100.0.1 &>/dev/null; then
    ok "VPS reachable at 10.100.0.1"
  else
    fail "VPS not reachable at 10.100.0.1"
  fi
fi

# ── FIREWALL ──────────────────────────────────────────────────────────────────
header "Firewall (nftables)"

if sudo nft list ruleset 2>/dev/null | grep -q "hook input"; then
  ok "nftables ruleset loaded"
else
  fail "nftables ruleset not loaded"
fi

if [[ $(cat /proc/sys/net/ipv4/ip_forward) == "1" ]]; then
  ok "IP forwarding enabled"
else
  fail "IP forwarding disabled"
fi

# ── SSH ───────────────────────────────────────────────────────────────────────
header "SSH"

if systemctl is-active --quiet ssh; then
  ok "sshd running"
  SSH_LISTEN=$(ss -tlpn sport = :22 2>/dev/null | awk 'NR>1 {print $4}' | tr '\n' ' ')
  ok "listening on: $SSH_LISTEN"
else
  fail "sshd not running"
fi

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo
echo "────────────────────────────────────────"
if ! (systemctl is-active --quiet dnsmasq && \
      systemctl is-active --quiet wg-quick@wg0 && \
      [[ -n "$WAN_IP" ]] && [[ -n "$WG_IP" ]]); then
  echo "  STATUS: degraded — check failures above"
  echo "  To restart server mode: sudo bash ops/server-Lenovo-T15p/mode.sh server"
else
  echo "  STATUS: all systems nominal"
fi
echo
