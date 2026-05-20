# T15 VPN Server

Always-on router and VPN server running in an apartment, accessible from anywhere.

---

## Components

| Component | Role |
|-----------|------|
| **Lenovo ThinkPad T15 Gen2** | Router + VPN server. Connects to building shared WiFi as WAN, routes traffic to IoT devices, maintains VPN tunnel to the relay |
| **TP-Link Archer MR550** | IoT WiFi access point. Connected to the T15 via ethernet; provides 2.4GHz + 5GHz WiFi to IoT devices |
| **Oracle VPS** (Marseille, Always Free) | WireGuard relay. Bridges the T15 and MacBook — both connect outbound to it, solving NAT traversal. Does not terminate traffic — forwards MacBook internet to T15 |
| **MacBook** | Remote client. Connects to the VPN from anywhere; all internet traffic double-hops through VPS → T15 and exits via the apartment |

The ethernet cable between the T15 and the MR550 is required because the T15's WiFi card is single-radio — it cannot simultaneously connect to the building WiFi and host a hotspot.

---

## Network Layout

```
                        Internet
                           │
                  Building shared WiFi  (WAN, apartment public IP)
                           │
                    T15 (wlp0s20f3)
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
  │ MacBook │──wg──▶│   VPS   │──wg──▶│  T15   │──────▶│ Internet │
  │10.100.0.3│      │10.100.0.1│      │10.100.0.2│      │          │
  └─────────┘       └─────────┘       └─────────┘       └──────────┘
                     relay only        NAT + exit
                    (forwards to       (apartment IP)
                     T15, does
                     not exit here)
```

---

## Software

| Software | Where | Purpose |
|----------|-------|---------|
| **WireGuard** | T15, VPS, MacBook | VPN tunnels |
| **nftables** | T15 | Firewall and NAT (masquerade IoT traffic to WAN) |
| **dnsmasq** | T15 | DHCP server for MR550 + DNS for VPN clients |
| **NetworkManager** | T15 | Manages WAN (building WiFi connection) |
| **OpenSSH server** | T15 | SSH access from MacBook over VPN |
| **wg-quick** | T15, VPS | WireGuard interface lifecycle management |

---

## Operations

After the first-time bootstrap (see "Setup from Scratch" below), everything is driven
through the `t15` system binary — no need to be in the project directory:

```bash
sudo t15 deploy        # re-apply configs after editing anything in src/
sudo t15 start         # start the VPN/router (t15.target)
sudo t15 stop          # stop everything in t15.target (SSH + nftables stay up)
sudo t15 restart       # stop + start
     t15 status        # health check (no sudo needed)
     t15 logs          # tail journalctl for all t15 units
sudo t15 uninstall     # restore original /etc/ files, remove everything

ssh as@10.100.0.2       # SSH into T15 from MacBook (VPN must be active)
```

The router auto-starts on boot via `t15.target`. A watchdog (`t15-watchdog.timer`)
runs every 2 min and patches the things systemd can't see by itself (WireGuard
handshake staleness, LAN IP drift, `ip_forward` sysctl drift). Routine service
crashes are handled by per-service `Restart=on-failure` drop-ins.

---

## Limitations

**Bandwidth**: MacBook internet traffic traverses the VPS twice (in + out) before reaching
the T15, making the VPS the bottleneck. The building WiFi upload speed is the second
bottleneck — all MacBook download traffic must be uploaded from the T15 to the VPS.

**Latency**: The double-hop adds ~25-30ms regardless of VPS provider. Every packet travels
MacBook → VPS → T15 → internet and back the same way. This overhead is inherent to the
architecture and cannot be reduced without removing the relay hop.

**T15 availability**: All MacBook internet depends on the T15 being online and connected
to building WiFi. If the T15 loses power, crashes, or loses WiFi, the MacBook has no
internet while the VPN is active. LTE failover (planned) would mitigate WiFi outages.

**MR550 throughput**: The MR550 is a budget 4G router repurposed as a WiFi AP. Its weak CPU
and radio limit IoT WiFi throughput to ~22/22 Mbps (measured via 5GHz), despite the gigabit
ethernet link to the T15. This is fine for IoT devices but not for high-bandwidth clients.
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
  server-Lenovo-T15/   configs + systemd units deployed to /etc/ on the T15
  server-VPS/           WireGuard config for the VPS
  client-macos/         WireGuard config for the MacBook
  client-android/       WireGuard config for the Android phone
ops/
  server-Lenovo-T15/   t15  — single control-plane script (installed as /usr/local/bin/t15)
  server-VPS/           provision-vps.sh (Oracle + Hetzner provisioning)
docs/
  STATUS.md             single source of truth — architecture, current state,
                        secrets/restore guide, known gotchas, next steps
```

---

## Setup from Scratch

This guide assumes a fresh Ubuntu Lenovo T15, a new Oracle VPS, a TP-Link MR550, and a
MacBook client. You will need the repo cloned on the T15.

### Prerequisites

1. Clone this repo on the T15
2. Copy `.env.local.example` to `.env.local` and fill in all values (see below)
3. Connect the T15 to the building WiFi (the WAN connection)

### Step 1 — Generate WireGuard keys

On the T15, generate three key pairs (VPS, T15, MacBook):

```bash
for name in vps t15 macbook; do
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

### Step 4 — Bootstrap the T15

From the project root on the T15, run the single bootstrap command. It installs the
`t15` binary into `/usr/local/bin/`, records the project path in `/etc/t15/config`,
deploys all configs to `/etc/`, enables the systemd units, and applies the always-on
hardening (no suspend, no auto-reboot, snap refresh window, password SSH off):

```bash
sudo ./ops/server-Lenovo-T15/t15 bootstrap
sudo reboot
```

From now on, you can run `sudo t15 deploy` from anywhere when you change anything
in `src/`.

### Step 5 — Configure the MR550

1. Connect a laptop/phone to the MR550's WiFi (default SSID on the label)
2. Open `192.168.1.1` in a browser, log in with the default password
3. Set **Operation Mode** to **Wireless Router Mode**
4. Go to **Advanced → Network → Internet**: set **Internet Connection Type** to **Dynamic IP**
5. Configure WiFi SSIDs and passwords for 2.4GHz and 5GHz as desired
6. Connect an ethernet cable from the MR550's **WAN port** (labeled LAN/WAN) to the T15's
   ethernet port (`enp0s31f6`)

### Step 6 — Verify

```bash
t15 status        # all sections should report ✓
```

Then test:

- Connect a phone to the MR550 WiFi — it should have internet
- From the T15: `ping 10.100.0.1` — should reach the VPS through the tunnel

### Step 7 — Configure the MacBook

Substitute the keys and VPS IP into `src/client-macos/wg0.conf`, then import it into the
WireGuard app on macOS. Activate the tunnel and test:

```bash
ping 8.8.8.8           # internet via double-hop
ping google.com        # DNS via T15
ssh as@10.100.0.2      # SSH into T15
curl ifconfig.me       # should show the apartment's public IP
```

Set up SSH key-based auth **before** the next reboot, because the bootstrap already
disabled password SSH:

```bash
ssh-copy-id as@10.100.0.2     # do this from the T15 locally if you haven't already
```

### Step 8 — Verify end-to-end

From the MacBook with VPN active:

- [ ] `curl ifconfig.me` shows the apartment's public IP (not the VPS IP)
- [ ] `ping google.com` works (DNS through T15)
- [ ] `ssh as@10.100.0.2` connects (SSH over VPN)
- [ ] Phone on MR550 WiFi has internet
- [ ] Reboot T15 — all services recover automatically within ~2 minutes
