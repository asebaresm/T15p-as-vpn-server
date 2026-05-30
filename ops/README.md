# Operations

The T15 is driven by a single binary, `t15`, that lives at `/usr/local/bin/t15`
after bootstrap. The source of truth is this repo — `t15 deploy` re-renders
the configs in [`src/server-Lenovo-T15/`](../src/server-Lenovo-T15/) into
`/etc/` and restarts everything.

---

## Quick reference

```bash
# First time, from the project root on the T15:
sudo ./ops/server-Lenovo-T15/t15 bootstrap

# Anytime after, from anywhere:
sudo t15 deploy        # re-apply configs from src/ to /etc/, restart everything
sudo t15 start         # start the VPN/router (t15.target)
sudo t15 stop          # stop everything in t15.target
sudo t15 restart       # stop + start
     t15 status        # health check (no sudo needed; richer output with sudo)
     t15 logs [unit]   # journalctl -fu <unit>; default = all t15 units
sudo t15 uninstall     # restore originals + remove the tool
```

`bootstrap` writes the project path into `/etc/t15/config`, installs the tool,
deploys configs, applies hardening (no-suspend, no auto-reboot, password SSH
off, snap refresh window), enables every unit, and starts the target.

---

## Systemd layout

```
t15.target ───── pulls in (Wants= + After=) ─────┐
                                                 │
                                            ┌────┴─────┐
                                            ▼          ▼
                              t15-lan.service     wg-quick@wg0.service ◄─┐
                              (192.168.10.1/24                            │ Restart=
                               on enp0s31f6)     ┌─── After= ────────────┘ on-failure
                                                 │
                                                 ▼
                                          dnsmasq.service
                                          (DHCP+DNS, needs both
                                           wg0 and LAN IP first)

Independent (always enabled at boot, NOT in t15.target):
  nftables.service ─── firewall + NAT (must stay up even when t15.target is stopped)
  ssh.service     ─── reachable on WAN + wg0; key-only auth
  t15-watchdog.timer ─ fires every 2 min; runs `t15 _watchdog`
```

Drop-ins added by `t15 deploy`:
- `dnsmasq.service.d/10-t15.conf` — `Requires=` + `After=` for wg0 and LAN, `Restart=on-failure`
- `wg-quick@.service.d/10-t15.conf` — `PartOf=t15.target`, `Restart=on-failure`
- `nftables.service.d/10-t15.conf` — `Restart=on-failure` (no `PartOf` — firewall stays up regardless)

The watchdog (`t15 _watchdog`) only patches things systemd can't reason about:
WireGuard handshake staleness (>5 min), LAN IP drift on `enp0s31f6`, and the
`net.ipv4.ip_forward` sysctl. Routine service crashes are systemd's job via the
`Restart=on-failure` drop-ins.

---

## Daily-ops recipes

### Push a config change

```bash
$EDITOR src/server-Lenovo-T15/nftables.conf
sudo t15 deploy
t15 status              # confirm all ✓
```

`deploy` is always-restart: it re-renders templates, copies every file in the
manifest to `/etc/`, reloads systemd + sysctl, sets `wifi.powersave=disable` on
every stored NM wifi connection profile (so the conf.d default applies without a
reboot), restarts `t15.target`, and bounces
`nftables` + `ssh`. VPN clients drop for a few seconds.

### Restart just one component

```bash
sudo systemctl restart wg-quick@wg0     # WireGuard tunnel only
sudo systemctl restart dnsmasq          # DHCP/DNS only
sudo systemctl restart t15-lan          # re-assert the LAN IP
sudo systemctl restart nftables         # reload firewall ruleset
```

Useful when you want to verify a single moving part without bouncing the whole
target.

### Tail logs

```bash
t15 logs                # all t15-related units, follow mode
t15 logs wg-quick@wg0   # just WireGuard
t15 logs dnsmasq        # DHCP leases + DNS queries
t15 logs t15-watchdog   # what the watchdog has been patching
```

### Add or remove a peer

1. Edit `src/server-Lenovo-T15/wg0.conf` (add/remove `[Peer]` block).
2. Edit `src/server-VPS/wg0.conf` similarly on the VPS side.
3. `sudo t15 deploy` on the T15.
4. SCP the VPS config and `systemctl restart wg-quick@wg0` on the VPS.
5. Hand the client a rendered `wg0.conf` (rendered manually — no client renderer
   is checked in).

### Swap VPS provider

```bash
$EDITOR .env.local                              # set VPS_PROVIDER=ORACLE (or HETZNER)
bash ops/server-VPS/provision-vps.sh            # provision + install wg on the new VPS
$EDITOR .env.local                              # update VPS_SERVER_PUBLIC_IP if needed
sudo t15 deploy                                 # re-render with the new endpoint
# update MacBook + Android client configs with the new endpoint IP
```

### Rotate keys

```bash
wg genkey | tee /tmp/t15.key | wg pubkey > /tmp/t15.pub
$EDITOR .env.local                              # T15_PRIVATE_KEY=... T15_PUBLIC_KEY=...
$EDITOR src/server-VPS/wg0.conf                 # update the T15 peer's PublicKey
sudo t15 deploy                                 # T15 side
# scp + restart wg-quick@wg0 on the VPS
```

### Check the vpn-health dashboard

From anywhere with a browser: https://vpn-health.mydomain.tld/ (basic auth, user
`as`, password in `.env.local` as `VPN_HEALTH_BASIC_AUTH_PASS`). Page is pushed
from T15 every 60 s; the "last push" timestamp is your heartbeat. If it stops
moving, the T15 isn't pushing — either the WAN is down or the snapshot timer
is broken.

Force an immediate push from the T15 (useful for debugging the dashboard
itself, e.g. after editing `t15-snapshot.sh`):
```bash
sudo systemctl start t15-snapshot.service
sudo journalctl -t t15-snapshot --since='1 min ago'
```

Setup-from-scratch / rotate the push key: see [docs/STATUS.md](../docs/STATUS.md)
"Remote observability" section.

### Reboot safely

```bash
sudo reboot
# Wait ~90s, then from your phone tethered or the apartment WiFi:
ssh as@<apartment-LAN-or-wg-IP>
t15 status
```

The `t15.target` is enabled at boot, so everything restarts unattended.
`NetworkManager-wait-online.service` blocks the chain until WAN is up.

---

## When things break

Most symptoms map to a single `t15 status` line:

| Symptom in `t15 status`            | Most likely cause | First thing to try |
|---|---|---|
| `✗ t15.target NOT active` | Bootstrap not applied or target masked | `sudo t15 start` |
| `✗ wlp0s20f3 has no IP` / `no internet` | Building WiFi disconnected or captive-portaled | Check NetworkManager: `nmcli connection show --active` |
| `✗ enp0s31f6 not configured` | LAN service died | `sudo systemctl restart t15-lan` |
| `✗ dnsmasq not running` | Started before `wg0` had its IP (race) | `sudo systemctl restart dnsmasq` (the drop-in ordering should prevent this) |
| `✗ wg0 not up` / `no handshake with VPS` | Tunnel down or VPS unreachable | `sudo systemctl restart wg-quick@wg0`; check VPS: `ssh -i ops/server-VPS/hetzner/vps-ssh-key root@<VPS-IP> systemctl status wg-quick@wg0` |
| `✗ VPS unreachable at 10.100.0.1` | Handshake works but no ping — usually VPS routing/firewall | SSH the VPS and re-check its firewall (`nft list ruleset`) |
| `✗ nftables ruleset empty` | Something flushed the rules | `sudo nft -f /etc/nftables.conf` and `sudo systemctl restart nftables` |
| `✗ IP forwarding disabled` | sysctl drift | `sudo sysctl -p /etc/sysctl.d/99-router.conf` — watchdog should auto-fix within 2 min |
| `✗ sshd not running` | Service crashed | `sudo systemctl restart ssh` — drop-in has `Restart=on-failure` so this is rare |
| `~ password auth still enabled` | sshd_config.d/ drop-in didn't reload | `sudo systemctl reload ssh` |

If you've lost SSH over the VPN, the apartment-side fallbacks (in order of pain):
1. SSH from the local network (192.168.10.x via MR550, or building WiFi)
2. Plug a keyboard + monitor into the T15 directly
3. `t15 stop` to drop everything to a vanilla laptop and then debug

---

## What gets installed

| Path | Purpose |
|---|---|
| `/usr/local/bin/t15` | The tool itself |
| `/etc/t15/config` | Records `PROJECT_ROOT` so `t15 deploy` knows where the source lives |
| `/etc/wireguard/wg0.conf` | Rendered from `src/.../wg0.conf` with keys from `.env.local` (0600) |
| `/etc/dnsmasq.d/iot.conf` | DHCP/DNS for the IoT LAN |
| `/etc/nftables.conf` | Firewall + NAT |
| `/etc/sysctl.d/99-router.conf` | `ip_forward`, rp_filter, ICMP-redirect handling |
| `/etc/NetworkManager/conf.d/unmanaged.conf` | `wg0` + `enp0s31f6` marked NM-unmanaged |
| `/etc/NetworkManager/conf.d/connectivity.conf` | Connectivity probe (for future LTE failover) |
| `/etc/NetworkManager/conf.d/wifi-powersave.conf` | Disables WiFi power-save (default for new connections). `t15 deploy` also runs `nmcli connection modify` on every existing wifi connection so the setting takes effect without a reboot. |
| `/etc/ssh/sshd_config.d/10-t15.conf` | Password auth off, keyboard-interactive off |
| `/etc/systemd/system/t15.target` | Groups t15-lan + wg-quick@wg0 + dnsmasq |
| `/etc/systemd/system/t15-lan.service` | Assigns 192.168.10.1/24 to enp0s31f6 |
| `/etc/systemd/system/t15-watchdog.{service,timer}` | Patches things systemd can't see |
| `/etc/systemd/system/t15-snapshot.{service,timer}` | Builds + pushes the vpn-health dashboard HTML every 60 s |
| `/usr/local/sbin/t15-snapshot.sh` | The script the snapshot timer runs (templated: VPS IP baked in at deploy) |
| `/root/.ssh/t15-snapshot-vps-key{,.pub}` | Push-only SSH key (generated on first deploy, not removed by `t15 uninstall`) |
| `/etc/systemd/system/{dnsmasq,wg-quick@,nftables}.service.d/10-t15.conf` | Ordering + `Restart=on-failure` drop-ins |
| `/etc/apt/apt.conf.d/99-no-auto-reboot` | unattended-upgrades won't reboot the box |
| `/etc/systemd/logind.conf.d/no-suspend.conf` | Lid close / idle / power button ignored |
| `/var/backups/t15-router/` | Originals of every file `t15` overwrote (kept after `uninstall`) |

---

## Reverting

```bash
sudo t15 uninstall      # restore all originals, remove units + tool + /etc/t15/
```

Backups remain under `/var/backups/t15-router/` after uninstall — wipe manually
when you're sure you won't roll back. `uninstall` does **not** undo the
WireGuard package install or remove `/etc/wireguard/wg0.conf` (it's restored to
whatever was there before bootstrap — for a fresh box, that means removed).

---

## VPS — `provision-vps.sh`

Provisions a Hetzner CX23 (default) or Oracle Always Free instance and lays down
`/etc/wireguard/wg0.conf` on the new VPS. Reads `VPS_PROVIDER` from `.env.local`.

```bash
bash ops/server-VPS/provision-vps.sh
```

Credentials and SSH keys live under `ops/server-VPS/{hetzner,oracle}/`
(gitignored). Full setup steps are in the main [README.md](../README.md)
"Setup from Scratch".

### VPS relay guard (self-heal) + health reporter

`provision-vps.sh` also installs, on the VPS:

| Path | Purpose |
|---|---|
| `/usr/local/sbin/vpn-relay-guard.sh` + `vpn-relay-guard.{service,timer}` | Re-asserts the relay routing invariants (`ip_forward`, `ip rule from 10.100.0.0/24 lookup 100`, table-100 default route, FORWARD wg0 accepts) every 60s. Idempotent; logs to `journalctl -t vpn-relay-guard` only on repair. |
| `/usr/local/sbin/vpn-relay-health.sh` | Read-only reporter of those same invariants. Queried by the T15 dashboard over the wg tunnel via a forced-command SSH key. |

Why: installing Docker (or other netfilter churn) on the VPS silently wiped the
`ip rule`, killing the double-hop while every health check still showed green —
see [docs/STATUS.md](../docs/STATUS.md) "Known gotchas". The guard repairs it
within 60s; the dashboard's **"VPS relay invariants"** section makes the break
visible. Manual check anytime:

```bash
ssh -i ops/server-VPS/hetzner/vps-ssh-key root@<VPS_IP> /usr/local/sbin/vpn-relay-health.sh
```

---

## Component overview

| Component | WireGuard IP | Role |
|---|---|---|
| VPS (Hetzner, active) | `10.100.0.1` | WireGuard relay (public endpoint) |
| T15 | `10.100.0.2` | Router + VPN exit |
| MacBook | `10.100.0.3` | VPN client |
| Android | `10.100.0.4` | VPN client |
| MR550 | DHCP from T15 | IoT WiFi AP, downstream of `enp0s31f6` |

See also: [docs/STATUS.md](../docs/STATUS.md) — single source of truth for
architecture, current state, secrets/restore guide, known gotchas, and next steps.
