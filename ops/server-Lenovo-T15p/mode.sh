#!/usr/bin/env bash
# Switches the Lenovo T15p between operating modes.
#
# Usage:
#   sudo bash ops/server-Lenovo-T15p/mode.sh server   — VPN server + router + AP
#   sudo bash ops/server-Lenovo-T15p/mode.sh laptop   — regular laptop, everything torn down
#
# LAN is provided by the TP-Link MR550 connected via enp0s31f6 (ethernet).
# The MR550 must be configured in AP mode (web UI, one-time setup).

set -euo pipefail

MODE=${1:-}
LAN_IFACE=enp0s31f6
LAN_IP=192.168.10.1/24

if [[ "$MODE" != "server" && "$MODE" != "laptop" ]]; then
  echo "Usage: sudo bash ops/server-Lenovo-T15p/mode.sh <server|laptop>"
  exit 1
fi

# ── SERVER MODE ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "server" ]]; then
  echo "==> Switching to SERVER mode..."

  echo "  [1/4] Loading nftables firewall rules..."
  nft -f /etc/nftables.conf

  echo "  [2/4] Enabling IP forwarding..."
  sysctl -w net.ipv4.ip_forward=1 > /dev/null

  echo "  [3/4] Bringing up LAN interface ($LAN_IFACE → MR550)..."
  # Hand enp0s31f6 over from NetworkManager to manual management
  nmcli device set "$LAN_IFACE" managed no
  ip addr flush dev "$LAN_IFACE" 2>/dev/null || true
  ip addr add "$LAN_IP" dev "$LAN_IFACE"
  ip link set "$LAN_IFACE" up

  echo "  [4/4] Starting WireGuard tunnel..."
  systemctl restart wg-quick@wg0

  # Wait for wg0 to get its IP (dnsmasq needs it for bind-interfaces)
  for i in $(seq 1 10); do
    if ip -4 addr show wg0 2>/dev/null | grep -q "10.100.0.2"; then
      break
    fi
    sleep 1
  done

  systemctl restart dnsmasq
  systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true

  echo ""
  echo "  SERVER mode active."
  echo "  IoT LAN : 192.168.10.0/24 via $LAN_IFACE (MR550 AP)"
  echo "  WireGuard: $(wg show wg0 2>/dev/null | grep endpoint || echo 'wg0 up')"
fi

# ── LAPTOP MODE ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "laptop" ]]; then
  echo "==> Switching to LAPTOP mode..."

  echo "  [1/4] Stopping dnsmasq..."
  systemctl stop dnsmasq 2>/dev/null || true

  echo "  [2/4] Releasing LAN interface ($LAN_IFACE)..."
  ip addr flush dev "$LAN_IFACE" 2>/dev/null || true
  # Return enp0s31f6 to NetworkManager (for regular ethernet use)
  nmcli device set "$LAN_IFACE" managed yes

  echo "  [3/4] Stopping WireGuard tunnel..."
  systemctl stop wg-quick@wg0 2>/dev/null || true

  echo "  [4/4] Flushing firewall rules..."
  nft flush ruleset

  echo ""
  echo "  LAPTOP mode active."
  echo "  All server/router services stopped. wlp0s20f3 and enp0s31f6 are normal interfaces."
fi
