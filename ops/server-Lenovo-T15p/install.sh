#!/usr/bin/env bash
# Applies all T15p router configs to the system.
# Run as root (or with sudo) from the project root.
# Usage: sudo bash ops/server-Lenovo-T15p/install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../../src/server-Lenovo-T15p"
CONFIGS="$SRC"
SYSTEMD_DIR="$SRC/systemd"
DISPATCHER_DIR="$SRC/nm-dispatcher"

echo "==> Installing packages..."
apt-get update -qq
apt-get install -y hostapd dnsmasq wireguard nftables iw

# Prevent hostapd and dnsmasq from auto-starting with their default (empty) configs
systemctl unmask hostapd 2>/dev/null || true
systemctl stop hostapd dnsmasq 2>/dev/null || true

echo "==> Setting up WireGuard..."
cp "$CONFIGS/wg0.conf" /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

echo "==> Setting up hostapd..."
mkdir -p /etc/hostapd
cp "$CONFIGS/hostapd.conf" /etc/hostapd/hostapd.conf
# Point hostapd to its config
sed -i 's|#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

echo "==> Setting up dnsmasq..."
cp "$CONFIGS/dnsmasq-iot.conf" /etc/dnsmasq.d/iot.conf

echo "==> Setting up nftables..."
cp "$CONFIGS/nftables.conf" /etc/nftables.conf

echo "==> Setting up sysctl (IP forwarding)..."
cp "$CONFIGS/sysctl-router.conf" /etc/sysctl.d/99-router.conf
sysctl --system

echo "==> Configuring NetworkManager..."
mkdir -p /etc/NetworkManager/conf.d
cp "$CONFIGS/nm-unmanaged.conf"    /etc/NetworkManager/conf.d/unmanaged.conf
cp "$CONFIGS/nm-connectivity.conf" /etc/NetworkManager/conf.d/connectivity.conf

echo "==> Installing NM dispatcher script..."
cp "$DISPATCHER_DIR/99-hostapd-channel" /etc/NetworkManager/dispatcher.d/99-hostapd-channel
chmod 755 /etc/NetworkManager/dispatcher.d/99-hostapd-channel

echo "==> Installing systemd service for ap0 interface..."
cp "$SYSTEMD_DIR/create-ap0.service" /etc/systemd/system/create-ap0.service
systemctl daemon-reload
systemctl enable create-ap0.service

echo "==> Enabling services..."
systemctl enable wg-quick@wg0
systemctl enable nftables
systemctl enable dnsmasq
# hostapd is started by the NM dispatcher when wlp0s20f3 comes up, not directly
# but enable it so dispatcher's `systemctl restart hostapd` works
systemctl enable hostapd

echo "==> Reloading NetworkManager..."
systemctl reload NetworkManager

echo ""
echo "============================================"
echo "  Install complete. Please reboot."
echo ""
echo "  After reboot, verify with:"
echo "    systemctl status create-ap0 wg-quick@wg0 hostapd dnsmasq nftables"
echo "    iw dev"
echo "    wg show"
echo "============================================"
echo ""
echo "  REMINDER: Set your IoT WiFi passphrase before rebooting:"
echo "    /etc/hostapd/hostapd.conf → wpa_passphrase=..."
echo "============================================"
