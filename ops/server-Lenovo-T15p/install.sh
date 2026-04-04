#!/usr/bin/env bash
# Applies all T15p router configs to the system.
# Run as root (or with sudo) from the project root.
#
# Usage:
#   sudo bash ops/server-Lenovo-T15p/install.sh           — install
#   sudo bash ops/server-Lenovo-T15p/install.sh rollback  — undo install, restore networking

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
SRC="$ROOT/src/server-Lenovo-T15p"
BACKUP_DIR="/var/backups/t15p-router"

# Load secrets from .env.local
ENV_FILE="$ROOT/.env.local"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.local.example and fill in the values."
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

for VAR in VPS_SERVER_PUBLIC_IP VPS_PRIVATE_KEY VPS_PUBLIC_KEY T15P_PRIVATE_KEY T15P_PUBLIC_KEY MACBOOK_PUBLIC_KEY; do
  if [[ -z "${!VAR:-}" ]]; then
    echo "ERROR: $VAR is not set in .env.local"
    exit 1
  fi
done

# Substitutes all {{VAR}} placeholders in a template file
render_template() {
  local src="$1"
  sed -e "s|{{VPS_SERVER_PUBLIC_IP}}|$VPS_SERVER_PUBLIC_IP|g" \
      -e "s|{{VPS_PRIVATE_KEY}}|$VPS_PRIVATE_KEY|g" \
      -e "s|{{VPS_PUBLIC_KEY}}|$VPS_PUBLIC_KEY|g" \
      -e "s|{{T15P_PRIVATE_KEY}}|$T15P_PRIVATE_KEY|g" \
      -e "s|{{T15P_PUBLIC_KEY}}|$T15P_PUBLIC_KEY|g" \
      -e "s|{{MACBOOK_PRIVATE_KEY}}|$MACBOOK_PRIVATE_KEY|g" \
      -e "s|{{MACBOOK_PUBLIC_KEY}}|$MACBOOK_PUBLIC_KEY|g" \
      "$src"
}

# Saves the original file before we overwrite it.
# Marks absent files with a sentinel so rollback knows to delete them.
# Skips if a backup already exists (re-running install won't lose the original).
backup() {
  local src="$1"
  local bdir="$BACKUP_DIR/$(dirname "$src")"
  local base="$(basename "$src")"
  mkdir -p "$bdir"
  [[ -f "$bdir/${base}.orig" || -f "$bdir/${base}.absent" ]] && return
  if [[ -f "$src" ]]; then
    cp "$src" "$bdir/${base}.orig"
  else
    touch "$bdir/${base}.absent"
  fi
}

# Restores a single file from backup (or removes it if it was absent before install).
restore() {
  local dest="$1"
  local bdir="$BACKUP_DIR/$(dirname "$dest")"
  local base="$(basename "$dest")"
  if [[ -f "$bdir/${base}.orig" ]]; then
    cp "$bdir/${base}.orig" "$dest"
    echo "    restored $dest"
  elif [[ -f "$bdir/${base}.absent" ]]; then
    rm -f "$dest"
    echo "    removed  $dest (was not present before install)"
  else
    echo "    no backup for $dest — skipping"
  fi
}

# ── ROLLBACK ──────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "rollback" ]]; then
  echo "==> Rolling back T15p router install..."

  echo "  [1/6] Stopping router services..."
  systemctl stop  wg-quick@wg0 2>/dev/null || true
  systemctl stop  dnsmasq      2>/dev/null || true
  systemctl stop  nftables     2>/dev/null || true

  echo "  [2/6] Flushing firewall rules..."
  nft flush ruleset 2>/dev/null || true

  echo "  [3/6] Returning enp0s31f6 to NetworkManager..."
  ip addr flush dev enp0s31f6 2>/dev/null || true
  nmcli device set enp0s31f6 managed yes 2>/dev/null || true

  echo "  [4/6] Disabling router services..."
  systemctl disable wg-quick@wg0 2>/dev/null || true
  systemctl disable nftables     2>/dev/null || true

  echo "  [5/6] Restoring config files..."
  if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "  WARNING: no backup found at $BACKUP_DIR — skipping file restore."
  else
    restore /etc/wireguard/wg0.conf
    restore /etc/dnsmasq.d/iot.conf
    restore /etc/nftables.conf
    restore /etc/sysctl.d/99-router.conf
    restore /etc/NetworkManager/conf.d/unmanaged.conf
    restore /etc/NetworkManager/conf.d/connectivity.conf
  fi

  echo "  [6/6] Reloading sysctl and NetworkManager..."
  sysctl --system > /dev/null
  systemctl daemon-reload
  systemctl reload NetworkManager

  echo ""
  echo "  Rollback complete."
  echo "  WiFi should reconnect within a few seconds."
  echo "  If it does not, reboot: sudo reboot"
  exit 0
fi

# ── INSTALL ───────────────────────────────────────────────────────────────────

echo "==> Backing up existing configs to $BACKUP_DIR ..."
backup /etc/wireguard/wg0.conf
backup /etc/dnsmasq.d/iot.conf
backup /etc/nftables.conf
backup /etc/sysctl.d/99-router.conf
backup /etc/NetworkManager/conf.d/unmanaged.conf
backup /etc/NetworkManager/conf.d/connectivity.conf

echo "==> Installing packages..."
apt-get update -qq
apt-get install -y dnsmasq wireguard nftables iw openssh-server

echo "==> Setting up WireGuard..."
render_template "$SRC/wg0.conf" > /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

echo "==> Setting up dnsmasq..."
cp "$SRC/dnsmasq-iot.conf" /etc/dnsmasq.d/iot.conf

echo "==> Setting up nftables..."
cp "$SRC/nftables.conf" /etc/nftables.conf

echo "==> Setting up sysctl (IP forwarding)..."
cp "$SRC/sysctl-router.conf" /etc/sysctl.d/99-router.conf
sysctl --system

echo "==> Configuring NetworkManager..."
mkdir -p /etc/NetworkManager/conf.d
cp "$SRC/nm-unmanaged.conf"    /etc/NetworkManager/conf.d/unmanaged.conf
cp "$SRC/nm-connectivity.conf" /etc/NetworkManager/conf.d/connectivity.conf

echo "==> Cleaning up legacy ap0/hostapd config (if present)..."
systemctl disable --now hostapd 2>/dev/null || true
systemctl disable --now create-ap0.service 2>/dev/null || true
rm -f /etc/systemd/system/create-ap0.service
rm -f /etc/NetworkManager/dispatcher.d/99-hostapd-channel
systemctl daemon-reload

echo "==> Enabling services..."
systemctl enable wg-quick@wg0
systemctl enable nftables
# dnsmasq is started by mode.sh in server mode, not at boot
systemctl disable dnsmasq 2>/dev/null || true

echo "==> Reloading NetworkManager..."
systemctl reload NetworkManager

echo ""
echo "============================================"
echo "  Install complete. Please reboot."
echo ""
echo "  Before switching to server mode:"
echo "    1. Connect MR550 ethernet cable to enp0s31f6"
echo "    2. Configure MR550 WAN as Dynamic IP (web UI)"
echo "    3. Run: sudo bash ops/server-Lenovo-T15p/mode.sh server"
echo ""
echo "  To undo this install:"
echo "    sudo bash ops/server-Lenovo-T15p/install.sh rollback"
echo "============================================"
