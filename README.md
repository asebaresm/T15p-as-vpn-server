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
                           │
              ┌────────────┴────────────┐
              │                         │
        enp0s31f6                 wg0 (10.100.0.2)
     192.168.10.0/24                   │
              │                   WireGuard tunnel
           ethernet                    │
              │                 VPS (10.100.0.1)
            MR550                Marseille, relay
              │                        │
     IoT WiFi (2.4/5 GHz)       wg0 (10.100.0.3)
                                       │
                                    MacBook
                                   (anywhere)


MacBook internet path (double-hop):

  ┌─────────┐       ┌─────────┐       ┌─────────┐       ┌──────────┐
  │ MacBook │──wg──▶│   VPS   │──wg──▶│  T15p   │──────▶│ Internet │
  │10.100.0.3│      │10.100.0.1│      │10.100.0.2│      │          │
  └─────────┘       └─────────┘       └─────────┘       └──────────┘
                     relay only        NAT + exit
                    (forwards to       (apartment IP)
                     T15p, does
                     not exit here)
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
# Switch T15p to server mode (automatic after hardening, manual otherwise)
sudo bash ops/server-Lenovo-T15p/mode.sh server

# Switch back to regular laptop
sudo bash ops/server-Lenovo-T15p/mode.sh laptop

# Check health of all components
sudo bash ops/server-Lenovo-T15p/status.sh

# Harden for always-on operation (auto-start, watchdog, no suspend, no auto-reboot)
sudo bash ops/server-Lenovo-T15p/harden.sh

# Undo hardening
sudo bash ops/server-Lenovo-T15p/harden.sh undo

# Undo install and restore original networking
sudo bash ops/server-Lenovo-T15p/install.sh rollback

# SSH into T15p from MacBook (VPN must be active)
ssh as@10.100.0.2
```

---

## Limitations

**Bandwidth**: MacBook internet traffic traverses the VPS twice (in + out) before reaching
the T15p, making the VPS the bottleneck. The building WiFi upload speed is the second
bottleneck — all MacBook download traffic must be uploaded from the T15p to the VPS.

**Latency**: The double-hop adds ~25-30ms regardless of VPS provider. Every packet travels
MacBook → VPS → T15p → internet and back the same way. This overhead is inherent to the
architecture and cannot be reduced without removing the relay hop.

**T15p availability**: All MacBook internet depends on the T15p being online and connected
to building WiFi. If the T15p loses power, crashes, or loses WiFi, the MacBook has no
internet while the VPN is active. LTE failover (planned) would mitigate WiFi outages.

**MR550 throughput**: The MR550 is a budget 4G router repurposed as a WiFi AP. Its weak CPU
and radio limit IoT WiFi throughput to ~22/22 Mbps (measured via 5GHz), despite the gigabit
ethernet link to the T15p. This is fine for IoT devices but not for high-bandwidth clients.
The MacBook should always connect directly to the building WiFi for speed, not through the
MR550. A dedicated AP (e.g. TP-Link EAP225, ~€40) would improve IoT WiFi to 200+ Mbps.

### Estimated throughput per VPN client

Building WiFi measured at 176/6.56 Mbps (peak 578/323 Mbps). Direct connection baseline: ~27ms latency.

| Scenario | Download | Upload | Latency | Bottleneck |
|---|---|---|---|---|
| Direct (no VPN) | 578 Mbps | 323 Mbps | 27 ms | — |
| Oracle Free, 1 user | ~71 Mbps | ~41 Mbps | ~53 ms | VPS bandwidth |
| Oracle Free, 2 users | ~35 Mbps | ~20 Mbps | ~53 ms | VPS bandwidth |
| Hetzner CX22, 1 user | ~300-400 Mbps | ~200-280 Mbps | ~55-65 ms | Building WiFi |
| Hetzner CX22, 2 users | ~150-200 Mbps | ~100-140 Mbps | ~55-65 ms | Building WiFi |
| Building WiFi at 6.56 Mbps up, 1 user | ~5-6 Mbps | ~5-6 Mbps | ~53 ms | WiFi upload |
| Building WiFi at 6.56 Mbps up, 2 users | ~3 Mbps | ~3 Mbps | ~53 ms | WiFi upload |

All estimates assume simultaneous sustained load. Bursty usage (normal browsing) is less affected.

---

## Repository Structure

```
src/
  server-Lenovo-T15p/   config files deployed to /etc/ on the T15p
  server-VPS/           WireGuard config for the VPS
  client-macos/         WireGuard config for the MacBook
ops/
  server-Lenovo-T15p/   install.sh, mode.sh, status.sh, harden.sh, watchdog.sh
  server-VPS/           provision-vps.sh (Oracle Cloud provisioning)
docs/
  STATUS.md             current state of each component
  NEXT.md               planned improvements
```

---

## Setup from Scratch

This guide assumes a fresh Ubuntu Lenovo T15p, a new Oracle VPS, a TP-Link MR550, and a
MacBook client. You will need the repo cloned on the T15p.

### Prerequisites

1. Clone this repo on the T15p
2. Copy `.env.local.example` to `.env.local` and fill in all values (see below)
3. Connect the T15p to the building WiFi (the WAN connection)

### Step 1 — Generate WireGuard keys

On the T15p, generate three key pairs (VPS, T15p, MacBook):

```bash
for name in vps t15p macbook; do
  wg genkey | tee /tmp/${name}.key | wg pubkey > /tmp/${name}.pub
  echo "$name private: $(cat /tmp/${name}.key)"
  echo "$name public:  $(cat /tmp/${name}.pub)"
done
```

Add all six values to `.env.local`.

### Step 2 — Provision the Oracle VPS

Set up an Oracle Cloud Always Free account (eu-marseille-1 region). Place the API key PEM
and SSH key in `ops/server-VPS/oracle/`, then:

```bash
python3 -m venv venv
venv/bin/pip install oci-cli
bash ops/server-VPS/provision-vps.sh
```

Once the instance is running, note its public IP and add it to `.env.local` as
`VPS_SERVER_PUBLIC_IP`. Reserve the IP in Oracle Cloud Console
(Networking → Reserved IPs) so it survives instance restarts.

### Step 3 — Configure the VPS

SSH into the VPS and install WireGuard:

```bash
ssh -i ops/server-VPS/oracle/vps-ssh-key ubuntu@<VPS_IP>
sudo apt update && sudo apt install -y wireguard
```

Copy `src/server-VPS/wg0.conf` to the VPS (substitute keys from `.env.local`):

```bash
scp -i ops/server-VPS/oracle/vps-ssh-key src/server-VPS/wg0.conf ubuntu@<VPS_IP>:/tmp/
ssh -i ops/server-VPS/oracle/vps-ssh-key ubuntu@<VPS_IP> \
  'sudo cp /tmp/wg0.conf /etc/wireguard/ && sudo chmod 600 /etc/wireguard/wg0.conf'
```

Enable and start WireGuard on the VPS:

```bash
ssh -i ops/server-VPS/oracle/vps-ssh-key ubuntu@<VPS_IP> \
  'sudo systemctl enable --now wg-quick@wg0'
```

Open UDP 51820 in the Oracle Cloud VCN security list (Networking → Virtual Cloud
Networks → Security Lists → Add Ingress Rule: UDP, port 51820, source 0.0.0.0/0).

On the VPS, allow UDP 51820 through the OS firewall:

```bash
ssh -i ops/server-VPS/oracle/vps-ssh-key ubuntu@<VPS_IP> \
  'sudo nft insert rule ip filter INPUT index 4 udp dport 51820 counter accept && \
   sudo nft insert rule ip filter FORWARD index 0 oifname "wg0" counter accept && \
   sudo nft insert rule ip filter FORWARD index 0 iifname "wg0" counter accept && \
   sudo sh -c "nft list ruleset > /etc/nftables.conf" && \
   sudo systemctl enable nftables'
```

### Step 4 — Install and configure the T15p

On the T15p, run the install script (deploys all configs, installs packages):

```bash
sudo bash ops/server-Lenovo-T15p/install.sh
sudo reboot
```

### Step 5 — Configure the MR550

1. Connect a laptop/phone to the MR550's WiFi (default SSID on the label)
2. Open `192.168.1.1` in a browser, log in with the default password
3. Set **Operation Mode** to **Wireless Router Mode**
4. Go to **Advanced → Network → Internet**: set **Internet Connection Type** to **Dynamic IP**
5. Configure WiFi SSIDs and passwords for 2.4GHz and 5GHz as desired
6. Connect an ethernet cable from the MR550's **WAN port** (labeled LAN/WAN) to the T15p's
   ethernet port (`enp0s31f6`)

### Step 6 — Start server mode and test

```bash
sudo bash ops/server-Lenovo-T15p/mode.sh server
sudo bash ops/server-Lenovo-T15p/status.sh
```

Verify all checks pass. Then test:

- Connect a phone to the MR550 WiFi — it should have internet
- From the T15p: `ping 10.100.0.1` — should reach the VPS through the tunnel

### Step 7 — Configure the MacBook

Substitute the keys and VPS IP into `src/client-macos/wg0.conf`, then import it into the
WireGuard app on macOS. Activate the tunnel and test:

```bash
ping 8.8.8.8           # internet via double-hop
ping google.com        # DNS via T15p
ssh as@10.100.0.2      # SSH into T15p
curl ifconfig.me       # should show the apartment's public IP
```

Set up SSH key-based auth:

```bash
ssh-copy-id as@10.100.0.2
```

### Step 8 — Harden for always-on operation

On the T15p:

```bash
sudo bash ops/server-Lenovo-T15p/harden.sh
```

This enables:
- Auto-start server mode on boot (no manual `mode.sh` needed)
- Watchdog timer that checks health every 2 min and restarts failed services
- No auto-reboot from apt security updates
- No suspend on lid close, idle, or power button
- Snap refresh limited to Sunday 4 AM

**Reboot to verify** — after reboot, run `sudo bash ops/server-Lenovo-T15p/status.sh` and
confirm all checks pass without manual intervention.

### Step 9 — Verify end-to-end

From the MacBook with VPN active:

- [ ] `curl ifconfig.me` shows the apartment's public IP (not the VPS IP)
- [ ] `ping google.com` works (DNS through T15p)
- [ ] `ssh as@10.100.0.2` connects (SSH over VPN)
- [ ] Phone on MR550 WiFi has internet
- [ ] Reboot T15p — all services recover automatically within ~2 minutes
