# T15p VPN Server

Always-on router and VPN server running in an apartment, accessible from anywhere.

---

## Components

| Component | Role |
|-----------|------|
| **Lenovo ThinkPad T15p Gen2** | Router + VPN server. Connects to building shared WiFi as WAN, routes traffic to IoT devices, maintains VPN tunnel to the relay |
| **TP-Link Archer MR550** | IoT WiFi access point. Connected to the T15p via ethernet; provides 2.4GHz + 5GHz WiFi to IoT devices |
| **Oracle VPS** (Marseille, Always Free) | WireGuard relay. Bridges the T15p and MacBook — both connect outbound to it, solving NAT traversal. Does not terminate traffic — forwards MacBook internet to T15p |
| **MacBook** | Remote client. Connects to the VPN from anywhere; all internet traffic double-hops through VPS → T15p and exits via the apartment |

The ethernet cable between the T15p and the MR550 is required because the T15p's WiFi card is single-radio — it cannot simultaneously connect to the building WiFi and host a hotspot.

---

## Network Layout

```
Internet
   │
Building shared WiFi  (WAN, apartment public IP)
   │
T15p (wlp0s20f3)
   ├── 192.168.10.0/24
   │   T15p (enp0s31f6) ──── ethernet ──── MR550 ──── IoT WiFi (2.4 / 5 GHz)
   │
   └── wg0 (10.100.0.2)
       │  WireGuard tunnel
       VPS (10.100.0.1) ── Marseille, relay only
       │
       wg0 (10.100.0.3)
       │
       MacBook  (anywhere)

MacBook internet path (double-hop):
  MacBook → VPS (relay) → T15p → building WiFi → internet (exit IP: apartment)
```

---

## Software

| Software | Where | Purpose |
|----------|-------|---------|
| **WireGuard** | T15p, VPS, MacBook | VPN tunnels |
| **nftables** | T15p | Firewall and NAT (masquerade IoT traffic to WAN) |
| **dnsmasq** | T15p | DHCP server for MR550 + DNS for VPN clients |
| **NetworkManager** | T15p | Manages WAN (building WiFi connection) |
| **OpenSSH server** | T15p | SSH access from MacBook over VPN |
| **wg-quick** | T15p, VPS | WireGuard interface lifecycle management |

---

## Operations

```bash
# Switch T15p to server mode (run after boot)
sudo bash ops/server-Lenovo-T15p/mode.sh server

# Switch back to regular laptop
sudo bash ops/server-Lenovo-T15p/mode.sh laptop

# Check health of all components
bash ops/server-Lenovo-T15p/status.sh

# Undo install and restore original networking
sudo bash ops/server-Lenovo-T15p/install.sh rollback

# SSH into T15p from MacBook (VPN must be active)
ssh as@10.100.0.2
```

---

## Repository Structure

```
src/
  server-Lenovo-T15p/   config files deployed to /etc/ on the T15p
  server-VPS/           WireGuard config for the VPS
  client-macos/         WireGuard config for the MacBook
ops/
  server-Lenovo-T15p/   install.sh, mode.sh, status.sh
  server-VPS/           provision-vps.sh (Oracle Cloud provisioning)
docs/
  STATUS.md             current state of each component
  NEXT.md               planned improvements
```
