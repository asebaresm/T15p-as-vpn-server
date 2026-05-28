# T15 VPN Server — Status, Context & Next Steps

Last updated: 2026-05-20. Single source of truth for this project — replaces the
older STATUS / CONTEXT / PLAN / NEXT split.

For operating the system day-to-day, see [ops/README.md](../ops/README.md). For
setup-from-scratch, see [README.md](../README.md).

---

## What this project is

An always-on VPN server running on a **Lenovo ThinkPad T15** in an apartment.
A **Hetzner VPS in Nuremberg** acts as a WireGuard relay (Oracle Always-Free in
Marseille is kept as an inactive fallback). All VPN client traffic
(MacBook, Android) double-hops through `VPS → T15 → building WiFi → internet`,
so the exit IP is the apartment's public IP. A TP-Link MR550 connected via
ethernet to the T15 provides IoT WiFi.

```
MacBook / Android ──wg──▶ VPS (relay, 10.100.0.1) ──wg──▶ T15 (10.100.0.2)
                                                              │
                                                              ├── enp0s31f6 ── MR550 (IoT WiFi)
                                                              └── wlp0s20f3 ── building WiFi ── internet
```

- VPS does NOT exit traffic — it forwards VPN clients to T15 via policy routing (`ip rule from 10.100.0.0/24 table 100`).
- T15 masquerades VPN traffic out its WiFi (`wlp0s20f3`). Exit IP = apartment.
- `Table = off` on the VPS's `wg0.conf` prevents `wg-quick` from hijacking the VPS default route when the T15 peer has `AllowedIPs = 0.0.0.0/0`.
- The "Option A" framing from the original design: a VPS relay is required because both the apartment WAN (building WiFi) and the planned LTE backup are NAT'd with no inbound port-forward access — neither can host a directly-reachable WireGuard endpoint. Tailscale was considered as Option B and rejected (extra SaaS dependency).

## IP assignments

| Device | WireGuard IP | Role |
|---|---|---|
| VPS (Hetzner) | `10.100.0.1` | Relay hub, public endpoint on UDP/51820 |
| T15 | `10.100.0.2` | Router + VPN exit + DNS for clients |
| MacBook | `10.100.0.3` | VPN client |
| Android | `10.100.0.4` | VPN client |
| IoT LAN | `192.168.10.0/24` | T15 enp0s31f6 = `.1`, MR550 lease = `.131` |

## VPS providers

| Provider | Location | Plan | Status |
|---|---|---|---|
| Hetzner | Nuremberg (nbg1) | CX23, €3.99/mo | **Active** |
| Oracle | Marseille | E2.1.Micro, Always Free | Inactive fallback (reactivate via `VPS_PROVIDER=ORACLE` in `.env.local` + `provision-vps.sh` + `t15 deploy`) |

---

## Component status

### VPS (Hetzner Cloud, Nuremberg) — ✅ Active

- **Instance**: CX23, Ubuntu, €3.99/mo. Public IP is static (does not change on instance restart).
- **WireGuard**: `wg-quick@wg0` enabled at boot, listening UDP/51820, `Table = off`.
- **Role**: relay only — VPN client traffic is policy-routed to T15 (table 100), not masqueraded out `ens3`.
- **Peers registered**: T15 (`10.100.0.2`), MacBook (`10.100.0.3`), Android (`10.100.0.4`).
- **SSH access**: `ssh -i ops/server-VPS/hetzner/vps-ssh-key root@<HETZNER_VPS_SERVER_PUBLIC_IP>`.

### T15 (Lenovo ThinkPad T15) — ✅ Done

- **Control plane**: single `t15` binary at `/usr/local/bin/t15`. Subcommands: `deploy`, `start`, `stop`, `restart`, `status`, `logs`, `uninstall`. Source: [ops/server-Lenovo-T15/t15](../ops/server-Lenovo-T15/t15).
- **Boot-time activation**: `t15.target` enabled — pulls in `wg-quick@wg0`, `dnsmasq`, `t15-lan` via `Wants=`. The `wireguard` kernel module is force-loaded early via `/etc/modules-load.d/wireguard.conf` so wg-quick never races on-demand modprobe.
- **WireGuard**: tunnel to Hetzner VPS up, fresh handshake.
- **LAN**: enp0s31f6 → MR550, IP `192.168.10.1/24` assigned by `t15-lan.service` (interface declared NM-unmanaged in `/etc/NetworkManager/conf.d/unmanaged.conf`). `dnsmasq` serves DHCP+DNS to the IoT LAN and to VPN clients on `wg0`.
- **Firewall**: `nftables` — NAT on `wlp0s20f3`, SSH + DNS allowed on `wg0`, `wg0 → wlp0s20f3` forwarding for the double-hop.
- **SSH**: `openssh-server` enabled at boot, **key-based auth only** (`PasswordAuthentication no` + `KbdInteractiveAuthentication no` via `/etc/ssh/sshd_config.d/10-t15.conf`).
- **Hardening**: no auto-reboot from `unattended-upgrades`, no suspend (lid close, idle, power button all ignored, sleep targets masked), snap refresh window Sun 04:00.
- **Self-healing**: per-service `Restart=on-failure` drop-ins handle routine crashes. `t15-watchdog.timer` runs every 2 min and patches things systemd can't see — handshake staleness (>5 min), LAN IP drift, `ip_forward` sysctl drift, **and now also starts `wg-quick@wg0` / `dnsmasq` if `t15.target` is active but they're dead** (covers the case where systemd silently dropped a service's start job at boot — see Gotchas).
- **Revert**: `sudo t15 uninstall` restores all original `/etc/` files (backed up under `/var/backups/t15-router/`).

### MR550 (TP-Link Archer MR550) — ✅ Done

Wireless Router Mode. WAN = T15 `enp0s31f6` via ethernet, getting DHCP from T15. 2.4 + 5 GHz broadcasting, IoT devices reaching internet.

### MacBook (client-macos) — ✅ Done

WireGuard tunnel active, peer = Hetzner VPS, full tunnel (`0.0.0.0/0`), double-hop via T15. DNS = `10.100.0.2`. SSH to T15 over VPN works (`ssh as@10.100.0.2`). Config: `src/client-macos/wg0-hetzner.conf` (rendered manually; `wg0-oracle.conf` kept for the fallback).

### Android (client-android) — ✅ Done

WireGuard Android app, peer = Hetzner VPS, full tunnel via T15. Config: `src/client-android/wg0-hetzner.conf` imported into the app.

### End-to-end verification

- [x] T15 auto-starts everything on boot, survives reboot unattended
- [x] Watchdog restarts failed services within 2 min
- [x] MR550 gets DHCP, IoT devices reach internet
- [x] MacBook + Android VPN → VPS → T15 → internet (exit IP = apartment)
- [x] DNS via T15 works on clients over VPN
- [x] SSH from MacBook to T15 over VPN

---

## Secrets + restore guide

Secrets are gitignored. The canonical snapshot lives in `t15-secrets-backup.tar.gz` at the repo root (also gitignored). The tarball contains:

```
.env.local                           — all WireGuard keys, IPs, API tokens, ROOT password
ops/server-VPS/hetzner/vps-ssh-key{,.pub}
ops/server-VPS/oracle/vps-ssh-key{,.pub}
ops/server-VPS/oracle/*.pem          — Oracle API certs
ops/server-VPS/oracle/configuration-file
src/client-macos/wg0-{hetzner,oracle}.conf   — rendered MacBook configs
src/client-android/wg0-hetzner.conf  — rendered Android config
```

### Restoring on a new machine

```bash
git clone <repo-url> && cd T15p-as-vpn-server
tar xzf t15-secrets-backup.tar.gz
chmod 600 .env.local ops/server-VPS/*/vps-ssh-key ops/server-VPS/oracle/*.pem \
          src/client-*/wg0-*.conf

# If this *is* the new T15 server, one-line bootstrap:
sudo ./ops/server-Lenovo-T15/t15 bootstrap
t15 status

# For full from-scratch (provisioning VPS + MR550 + clients): see README.md.
```

After bootstrap, install your client's SSH pubkey into `/home/as/.ssh/authorized_keys` — password SSH is disabled by the deploy. Without a pre-installed key you'll be locked out of SSH-over-VPN until you add one from the local terminal.

### SSH cheat sheet

```bash
# Hetzner VPS (from anywhere)
ssh -i ops/server-VPS/hetzner/vps-ssh-key root@<HETZNER_VPS_SERVER_PUBLIC_IP>

# Oracle VPS (from anywhere, if reactivated)
ssh -i ops/server-VPS/oracle/vps-ssh-key ubuntu@<ORACLE_VPS_SERVER_PUBLIC_IP>

# T15 from MacBook/Android (VPN must be active)
ssh as@10.100.0.2
```

### Switching VPS provider

1. Set `VPS_PROVIDER=HETZNER` or `VPS_PROVIDER=ORACLE` in `.env.local`.
2. `bash ops/server-VPS/provision-vps.sh` (provisions if needed + configures).
3. On the T15: `sudo t15 deploy`.
4. Update client configs (MacBook/Android) with the new endpoint IP + VPS public key.

---

## Known gotchas (lessons learned)

These bit us at least once. Listed for next time.

- **systemd boot-time dependency cycles are silent killers.** dnsmasq's default `Before=nss-lookup.target` + wg-quick's default `After=nss-lookup.target` + our drop-in `dnsmasq After=wg-quick@wg0` formed the cycle `dnsmasq → nss-lookup → wg-quick → dnsmasq`. systemd broke it by **deleting the wg-quick@wg0 start job** at boot. Result: no service in the `failed` state, no error logs about wg-quick — just a silent absence. After a dirty power loss we discovered the VPN never came up.
  - **Fix**: switched dnsmasq to `bind-dynamic` so it doesn't need `wg0` to exist at start time, then removed `Requires=/After=wg-quick@wg0` from dnsmasq's drop-in. Cycle gone.
  - **Detection**: `systemd-analyze verify t15.target wg-quick@wg0.service dnsmasq.service` reports cycles non-silently. Run after editing any unit / drop-in.
  - **Defense in depth**: the watchdog now also self-heals `wg-quick@wg0` and `dnsmasq` if `t15.target` is active but they're dead — covers any future "silently dropped" scenario within 2 min.

- **wireguard kernel module autoload races wg-quick at boot.** On some boots (especially after dirty shutdowns), wg-quick would fire before the kernel had loaded `wireguard.ko` on demand. Forced early load via `/etc/modules-load.d/wireguard.conf` (managed by `t15 deploy`).

- **Intel iwlwifi power-save + multi-BSSID roaming SSIDs = ~5-minute WAN blackouts.** Building Wi-Fi networks broadcast the same SSID across multiple APs (different BSSIDs). When the T15's WiFi card was in power-save it would miss beacons, fail to roam between BSSIDs, and get stuck in an authentication-timeout loop (3 retries × ~10s × several BSSIDs ≈ 4–5 min of dead WAN). During the outage the VPN tunnel to the VPS was dead, every client lost internet, and `t15 status` looked fine because *systemd* was happy — the WiFi card was just unresponsive. The watchdog couldn't see it either.
  - **Detection from outside**: this is exactly the scenario remote heartbeat monitoring (e.g. healthchecks.io) catches that the on-box watchdog can't.
  - **Fix**: disable WiFi power-save. `t15 deploy` ships `/etc/NetworkManager/conf.d/wifi-powersave.conf` setting `wifi.powersave = 2` (default for new connection profiles) AND runs `nmcli connection modify '<wifi-conn>' 802-11-wireless.powersave 2` on every existing wifi connection (since the conf.d default only applies to *new* profiles). After deploy: `iw dev wlp0s20f3 get power_save` should report `off`.
  - **Verification**: `for c in $(nmcli -t -f NAME,TYPE connection show | awk -F: '$2=="802-11-wireless"{print $1}'); do nmcli -t -g 802-11-wireless.powersave connection show "$c"; done` should print `disable` for every wifi connection.

- **`set -euo pipefail` + a failing `ip -4 addr show wg0 | awk | head` pipeline silently exits the script.** `cmd_status` lost its last sections when `wg0` was missing because of this. All such interface-read pipelines are now wrapped in `{ ... } || true`.

- **VPS `wg0.conf` must have `Table = off`.** Without it, `AllowedIPs = 0.0.0.0/0` on the T15 peer makes wg-quick hijack the VPS default route — you lock yourself out.

- **Don't `systemctl restart systemd-logind` from the desktop session.** It kills your GUI. Do it from a TTY (Ctrl+Alt+F2) or let it take effect on the next reboot. (Comes up after deploying logind drop-ins.)

- **Oracle VPS nftables has REJECT rules.** When adding firewall rules on the Oracle VPS, **insert before the reject** (`nft insert rule ... index N`), never append.

- **`AP_PASSPHRASE` in `.env.local` needs quotes.** Contains `;@` which the shell mangles otherwise.

- **`t15 deploy` runs the OLD in-memory script even though it replaces `/usr/local/bin/t15` first.** If you add a new `MANAGED_FILES` entry, the first `t15 deploy` won't pick it up — the new entry only takes effect on the *next* deploy. Workaround: just run `sudo t15 deploy` twice the first time, or `bash /usr/local/bin/t15 deploy` to force a fresh read.

- **MacBook host-key mismatch after T15 hardware swap.** New T15 = new SSH host keys. On the MacBook: `ssh-keygen -R 10.100.0.2` then re-connect and accept the new fingerprint. Verify the new ED25519 fingerprint out-of-band via the local terminal on the T15 first.

---

## Next steps

### LTE failover + direct reachability

- Install SIM card in the T15's LTE slot.
- Activate `wwan0` as a secondary WAN (scaffolding in [src/server-Lenovo-T15/lte/README.md](../src/server-Lenovo-T15/lte/README.md): uncomment `wwan0` blocks in `nftables.conf` + `sysctl-router.conf`, set NM connection priorities so building WiFi is primary and LTE is the failover).
- **Direct reachability when VPS is down**: when on LTE, the T15 gets a public-ish IP (or CGNAT). Options:
  - Carrier gives a real public IP → expose WireGuard directly on `wwan0`, no VPS needed.
  - CGNAT → stand up a second relay (another Oracle Always Free) or use a DDNS + port-forward workaround.
  - Simplest fallback: keep VPS as the primary relay; if VPS is down, SSH in via the SIM's IP directly (only useful if the carrier gives a public IP).

### Lenovo-to-Lenovo tunnel (no-IP-leak design)

Idea: VPN between two independent machines so the MacBook is "already on the LAN" on the apartment side (VLAN-like), and traffic never has the chance to leak. Mostly a thought experiment at this point — would need a second always-on box in the apartment.

### Done so far (history)

- ✅ **VPS exit IP moved to apartment** — implemented double-hop via VPS policy routing (`ip rule from 10.100.0.0/24 table 100`), T15 nftables masquerades on `wlp0s20f3`.
- ✅ **Reserved VPS public IP** — survives instance restarts.
- ✅ **Auto-start on boot** — was `t15-server.service` running `mode.sh server`, now superseded by `t15.target` pulling in member units directly. Watchdog timer every 2 min.
- ✅ **T15 hardening** — was `harden.sh`, now folded into `t15 deploy`: no auto-reboot, snap refresh window, lid/idle/power ignored, sleep targets masked.
- ✅ **Password-based SSH disabled** — `/etc/ssh/sshd_config.d/10-t15.conf`.
- ✅ **Single control-plane script** — `install.sh`/`mode.sh`/`harden.sh`/`status.sh`/`watchdog.sh` collapsed into one `t15` binary with subcommands.
- ✅ **Dependency-cycle resolved** — bind-dynamic + drop-in trimming + early module load + watchdog self-heal (see Gotchas).
