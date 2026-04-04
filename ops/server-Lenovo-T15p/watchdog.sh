#!/usr/bin/env bash
# Watchdog — checks T15p server health every 2 minutes (via systemd timer).
# Restarts failed services. Logs to journald.

set -euo pipefail

LOG_TAG="t15p-watchdog"
FIXED=0

log() { logger -t "$LOG_TAG" "$1"; }

# Only run if t15p-server.service is active (server mode)
if ! systemctl is-active --quiet t15p-server.service; then
  exit 0
fi

# Check WireGuard
if ! systemctl is-active --quiet wg-quick@wg0; then
  log "wg-quick@wg0 is down — restarting"
  systemctl restart wg-quick@wg0
  FIXED=$((FIXED + 1))
fi

# Check dnsmasq
if ! systemctl is-active --quiet dnsmasq; then
  log "dnsmasq is down — restarting"
  systemctl restart dnsmasq
  FIXED=$((FIXED + 1))
fi

# Check sshd
if ! systemctl is-active --quiet ssh && ! systemctl is-active --quiet sshd; then
  log "sshd is down — starting"
  systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true
  FIXED=$((FIXED + 1))
fi

# Check WireGuard handshake (no handshake in 5 min = stale tunnel)
if command -v wg &>/dev/null && systemctl is-active --quiet wg-quick@wg0; then
  LAST=$(wg show wg0 2>/dev/null | awk '/latest handshake/ {
    s=0
    for(i=3;i<=NF;i++) {
      if($(i+1)=="seconds") s+=$i
      if($(i+1)=="minutes" || $(i+1)=="minute,") s+=$i*60
      if($(i+1)=="hours" || $(i+1)=="hour,") s+=$i*3600
    }
    print s
  }')
  if [[ -n "$LAST" && "$LAST" -gt 300 ]]; then
    log "WireGuard handshake stale (${LAST}s ago) — restarting wg0"
    systemctl restart wg-quick@wg0
    sleep 5
    systemctl restart dnsmasq
    FIXED=$((FIXED + 1))
  fi
fi

# Check LAN interface has correct IP
LAN_IP=$(ip -4 addr show enp0s31f6 2>/dev/null | awk '/inet / {print $2}')
if [[ "$LAN_IP" != "192.168.10.1/24" ]]; then
  log "LAN interface lost IP (got '${LAN_IP:-none}') — reconfiguring"
  ip addr flush dev enp0s31f6 2>/dev/null || true
  ip addr add 192.168.10.1/24 dev enp0s31f6
  ip link set enp0s31f6 up
  FIXED=$((FIXED + 1))
fi

# Check nftables has rules loaded
if ! nft list chain inet filter input &>/dev/null; then
  log "nftables ruleset missing — reloading"
  nft -f /etc/nftables.conf
  FIXED=$((FIXED + 1))
fi

# Check IP forwarding
if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]]; then
  log "IP forwarding disabled — re-enabling"
  sysctl -w net.ipv4.ip_forward=1 > /dev/null
  FIXED=$((FIXED + 1))
fi

# Check VPS reachability via WireGuard tunnel
if ip link show wg0 &>/dev/null; then
  if ! ping -c 1 -W 5 10.100.0.1 &>/dev/null; then
    log "VPS (10.100.0.1) unreachable via wg0 — restarting tunnel"
    systemctl restart wg-quick@wg0
    sleep 5
    # Verify it came back
    if ! ping -c 1 -W 5 10.100.0.1 &>/dev/null; then
      log "VPS still unreachable after wg0 restart — may be a VPS-side issue"
    fi
    systemctl restart dnsmasq
    FIXED=$((FIXED + 1))
  fi
fi

if [[ "$FIXED" -gt 0 ]]; then
  log "Fixed $FIXED issue(s)"
fi
