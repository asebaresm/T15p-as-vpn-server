# Operations

Scripts for managing the T15p VPN server / router setup.

## Modes (server-Lenovo-T15p)

The T15p can run in two modes, switched on demand:

```bash
sudo bash ops/server-Lenovo-T15p/mode.sh server
sudo bash ops/server-Lenovo-T15p/mode.sh laptop
```

### `server` mode
Activates the full router + VPN server stack:
- Creates `ap0` virtual WiFi interface and brings up the IoT LAN (`192.168.10.0/24`)
- Starts `hostapd` → broadcasts the `Huawey-5` access point
- Starts `dnsmasq` → serves DHCP/DNS to IoT devices
- Loads `nftables` firewall and NAT rules
- Starts the WireGuard tunnel (`wg0`) to the VPS relay

**Requirement:** `wlp0s20f3` must already be connected to WiFi before switching to server mode. The script reads the active channel and configures hostapd to use the same one (hardware constraint on Intel AX201 CNVi).

### `laptop` mode
Tears everything down — the T15p behaves as a regular laptop:
- Stops `hostapd` and `dnsmasq`
- Deletes the `ap0` interface
- Stops the WireGuard tunnel
- Flushes all nftables rules

---

## Install (server-Lenovo-T15p)

First-time setup — applies all configs to the system. Run once after a fresh OS install:

```bash
sudo bash ops/server-Lenovo-T15p/install.sh
```

Then reboot. After reboot, use `mode.sh` to activate server mode.

---

## VPS Provisioning (server-VPS)

Provisions the Oracle Always Free AMD micro instance used as the WireGuard relay.
Only needed if the VPS needs to be reprovisioned from scratch.

```bash
bash ops/server-VPS/provision-vps.sh
```

Retries automatically every 120s until Oracle has available capacity.
Credentials and SSH keys are in `ops/server-VPS/oracle/` (gitignored).

---

## Component overview

| Component | IP | Role |
|---|---|---|
| VPS (`<VPS_SERVER_PUBLIC_IP>`) | `10.100.0.1` | WireGuard relay (public endpoint) |
| T15p | `10.100.0.2` | Router + VPN server |
| MacBook | `10.100.0.3` | Road warrior VPN client |
| IoT LAN | `192.168.10.0/24` | Devices connected to `Huawey-5` AP |
