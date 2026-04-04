#!/usr/bin/env bash
# Hardens the T15p for always-on server operation.
# Run as root (or with sudo) from the project root.
#
# What it does:
#   1. Deploys mode.sh + watchdog.sh to /opt/t15p-vpn/
#   2. Installs systemd services: auto-start on boot + watchdog timer
#   3. Prevents unattended-upgrades from rebooting
#   4. Limits snapd refresh to 4 AM Sunday (least disruptive)
#   5. Disables suspend/sleep (lid close, idle, power button)
#   6. Enables NetworkManager-wait-online (needed for boot ordering)
#
# Usage:
#   sudo bash ops/server-Lenovo-T15p/harden.sh
#   sudo bash ops/server-Lenovo-T15p/harden.sh undo   — revert all changes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
SRC="$ROOT/src/server-Lenovo-T15p"

# ── UNDO ──────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "undo" ]]; then
  echo "==> Undoing T15p hardening..."

  echo "  [1/5] Removing systemd services..."
  systemctl disable --now t15p-server.service 2>/dev/null || true
  systemctl disable --now t15p-watchdog.timer 2>/dev/null || true
  rm -f /etc/systemd/system/t15p-server.service
  rm -f /etc/systemd/system/t15p-watchdog.service
  rm -f /etc/systemd/system/t15p-watchdog.timer
  systemctl daemon-reload

  echo "  [2/5] Removing /opt/t15p-vpn/..."
  rm -rf /opt/t15p-vpn

  echo "  [3/5] Restoring unattended-upgrades defaults..."
  rm -f /etc/apt/apt.conf.d/99-no-auto-reboot

  echo "  [4/5] Restoring snapd defaults..."
  snap set system refresh.timer="" 2>/dev/null || true

  echo "  [5/5] Restoring suspend/sleep defaults..."
  rm -f /etc/systemd/logind.conf.d/no-suspend.conf
  systemctl restart systemd-logind
  systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

  echo ""
  echo "  Hardening undone. Reboot recommended."
  exit 0
fi

# ── HARDEN ────────────────────────────────────────────────────────────────────

echo "==> Hardening T15p for always-on server operation..."

# ── 1. Deploy scripts to /opt/t15p-vpn/ ──────────────────────────────────────
echo "  [1/6] Deploying scripts to /opt/t15p-vpn/..."
mkdir -p /opt/t15p-vpn
cp "$ROOT/ops/server-Lenovo-T15p/mode.sh"     /opt/t15p-vpn/mode.sh
cp "$ROOT/ops/server-Lenovo-T15p/watchdog.sh"  /opt/t15p-vpn/watchdog.sh
chmod +x /opt/t15p-vpn/mode.sh /opt/t15p-vpn/watchdog.sh

# ── 2. Install systemd services ──────────────────────────────────────────────
echo "  [2/6] Installing systemd services..."
cp "$SRC/systemd/t15p-server.service"    /etc/systemd/system/
cp "$SRC/systemd/t15p-watchdog.service"  /etc/systemd/system/
cp "$SRC/systemd/t15p-watchdog.timer"    /etc/systemd/system/
systemctl daemon-reload

# Ensure NM waits for connectivity before our service starts
systemctl enable NetworkManager-wait-online.service 2>/dev/null || true

systemctl enable t15p-server.service
systemctl enable t15p-watchdog.timer

# ── 3. Prevent unattended-upgrades from rebooting ────────────────────────────
echo "  [3/6] Preventing auto-reboot from unattended-upgrades..."
cat > /etc/apt/apt.conf.d/99-no-auto-reboot << 'EOF'
// Prevent unattended-upgrades from rebooting automatically.
// Security updates still install, but reboot is manual only.
Unattended-Upgrade::Automatic-Reboot "false";

// Don't remove unused kernels automatically (can break boot)
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
EOF

# ── 4. Limit snapd refresh to Sunday 4 AM ────────────────────────────────────
echo "  [4/6] Setting snapd refresh to Sunday 4:00 AM only..."
snap set system refresh.timer="sun,04:00" 2>/dev/null || true

# ── 5. Disable suspend/sleep ─────────────────────────────────────────────────
echo "  [5/6] Disabling suspend, sleep, and lid-close actions..."
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/no-suspend.conf << 'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKey=ignore
IdleAction=ignore
EOF
# NOTE: not restarting systemd-logind here — it kills the GUI session.
# Changes take effect on next reboot, or run: sudo systemctl restart systemd-logind
# from a TTY (Ctrl+Alt+F2), not from the desktop.

# Mask sleep targets so nothing can trigger them
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# Ensure sshd starts at boot
systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true

# ── 6. Enable the services now ────────────────────────────────────────────────
echo "  [6/6] Starting watchdog timer..."
systemctl start t15p-watchdog.timer

echo ""
echo "============================================"
echo "  Hardening complete."
echo ""
echo "  What changed:"
echo "    - Server mode starts automatically on boot"
echo "    - Watchdog checks health every 2 min"
echo "    - No auto-reboots from apt upgrades"
echo "    - Snap refresh limited to Sunday 4 AM"
echo "    - Lid close / idle / power button won't suspend"
echo ""
echo "  To undo: sudo bash ops/server-Lenovo-T15p/harden.sh undo"
echo "  To test: sudo reboot"
echo "============================================"
