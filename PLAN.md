# T15p Router + VPN Server — Architecture Plan

## Hardware Overview

- **Device**: Lenovo ThinkPad T15p Gen2
- **WAN1**: Building shared WiFi (NAT'd, no port-forward access)
- **WAN2**: SIM tray WWAN card (LTE, 10GB/month, CGNAT)
- **OS**: Ubuntu 24.04 LTS (Server)

---

## Network Topology

```
                        INTERNET
                            |
          +-----------------+------------------+
          |                                    |
   Building WiFi (WAN1)               LTE WWAN (WAN2)
   wlan0 — STA mode                   wwan0 (ModemManager)
   192.168.x.x (DHCP from AP)         10.x.x.x (carrier NAT)
          |                                    |
          +------------- T15p ----------------+
                            |
          +-----------------+------------------+
          |                                    |
   wlan1 (AP mode)                      wg0 (WireGuard)
   IoT LAN: 192.168.10.0/24             VPN: 10.100.0.0/24
   hostapd + dnsmasq                         |
                                     VPS relay (public IP)
                                             |
                                    MacBook VPN client
```

---

## The NAT Problem & Solution

Both WAN paths are behind NAT (building router + carrier CGNAT). The T15p has no
reachable public IP. To be reachable from the internet, two viable approaches:

### Option A — VPS Relay (Recommended)
A cheap VPS ($3–5/month, e.g. Hetzner CX11 or Oracle Free Tier) acts as a
WireGuard relay with a public IP. Both the T15p and the MacBook connect **outbound**
to the VPS as WireGuard peers. The VPS routes VPN traffic between them.

```
MacBook  --[WireGuard]--> VPS (public IP) --[WireGuard]--> T15p
```

The T15p initiates the connection to the VPS (NAT hole-punch via `PersistentKeepalive`),
so no inbound ports need to be opened.

### Option B — Tailscale (Simpler, SaaS dependency)
Tailscale handles NAT traversal automatically using its coordination server.
Free tier supports up to 100 devices. Adds a dependency on Tailscale's
infrastructure. Good fallback if managing a VPS is unwanted.

**This plan uses Option A (VPS relay) as the primary design.**

---

## Interface Layout

| Interface | Mode         | Role                          | Address              |
|-----------|-------------|-------------------------------|----------------------|
| `wlan0`   | STA          | WAN1 — connects to building WiFi | DHCP from building  |
| `wlan1`   | AP           | LAN — IoT access point        | 192.168.10.1/24      |
| `wwan0`   | WWAN modem   | WAN2 — LTE backup             | DHCP from carrier    |
| `wg0`     | WireGuard    | VPN tunnel to VPS relay       | 10.100.0.2/32        |
| `wg1`     | WireGuard    | (optional) direct peer links  | —                    |

### WiFi AP Interface Note
The T15p Gen2 has an Intel WiFi 6 AX200/AX201. This card **can** run simultaneous
STA (connect to building WiFi) + AP (host IoT network) using virtual interfaces on
different bands (e.g. STA on 5 GHz, AP on 2.4 GHz). This avoids needing a USB dongle.

**Check at runtime:**
```bash
iw list | grep -A10 "valid interface combinations"
```

If the card reports `#{ managed } <= 1, #{ AP } <= 1` across separate channel
contexts, dual-band STA+AP is supported. If not, use a USB WiFi adapter for the AP.

---

## Software Stack

| Layer             | Tool                      | Purpose                                    |
|-------------------|---------------------------|--------------------------------------------|
| Network mgmt      | `NetworkManager`          | Manages wlan0 STA + wwan0 LTE connections  |
| Modem mgmt        | `ModemManager`            | Controls the WWAN SIM/LTE card             |
| WiFi AP           | `hostapd`                 | Creates the IoT access point on wlan1      |
| DHCP + DNS        | `dnsmasq`                 | Serves DHCP and local DNS on IoT LAN       |
| Firewall + NAT    | `nftables`                | Masquerade, forward, input rules           |
| VPN               | `WireGuard`               | Encrypted tunnel to VPS relay              |
| Failover          | `NetworkManager` + script | Switches default route WAN1 → WAN2         |
| Remote SSH        | Via WireGuard VPN         | SSH over the established VPN tunnel        |

---

## Service Configurations

### 1. hostapd — IoT Access Point

File: `/etc/hostapd/hostapd.conf`
```
interface=wlan1
driver=nl80211
ssid=apartment-iot
hw_mode=g          # 2.4 GHz (change to 'a' for 5 GHz)
channel=6
wpa=2
wpa_passphrase=<STRONG_PASSPHRASE>
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
```

### 2. dnsmasq — DHCP + DNS for IoT LAN

File: `/etc/dnsmasq.d/iot-lan.conf`
```
interface=wlan1
bind-interfaces
dhcp-range=192.168.10.50,192.168.10.200,24h
dhcp-option=3,192.168.10.1          # default gateway
dhcp-option=6,192.168.10.1          # DNS server
domain=iot.local
```

### 3. nftables — Firewall + NAT

File: `/etc/nftables.conf`
```nft
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iifname lo accept
    ct state established,related accept
    iifname wlan1 accept          # allow IoT LAN → router
    iifname wg0 tcp dport 22 accept  # SSH via VPN only
    drop
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    iifname wlan1 oifname { wlan0, wwan0 } accept   # IoT → WAN
    ct state established,related accept
  }
}

table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname { wlan0, wwan0 } masquerade
  }
}
```

Enable IP forwarding in `/etc/sysctl.d/99-router.conf`:
```
net.ipv4.ip_forward = 1
```

### 4. WireGuard — Tunnel to VPS Relay

The T15p acts as a **spoke** connecting outbound to the VPS **hub**.

File: `/etc/wireguard/wg0.conf`
```ini
[Interface]
PrivateKey = <T15p_PRIVATE_KEY>
Address = 10.100.0.2/24
DNS = 1.1.1.1

[Peer]
# VPS relay
PublicKey = <VPS_PUBLIC_KEY>
Endpoint = <VPS_PUBLIC_IP>:51820
AllowedIPs = 10.100.0.0/24
PersistentKeepalive = 25
```

On the VPS, `/etc/wireguard/wg0.conf`:
```ini
[Interface]
PrivateKey = <VPS_PRIVATE_KEY>
Address = 10.100.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# T15p
PublicKey = <T15P_PUBLIC_KEY>
AllowedIPs = 10.100.0.2/32
PersistentKeepalive = 25

[Peer]
# MacBook
PublicKey = <MACBOOK_PUBLIC_KEY>
AllowedIPs = 10.100.0.3/32
```

On the MacBook, `/etc/wireguard/wg0.conf`:
```ini
[Interface]
PrivateKey = <MACBOOK_PRIVATE_KEY>
Address = 10.100.0.3/24
DNS = 10.100.0.2              # use T15p as DNS when connected

[Peer]
# VPS relay
PublicKey = <VPS_PUBLIC_KEY>
Endpoint = <VPS_PUBLIC_IP>:51820
AllowedIPs = 0.0.0.0/0        # route all traffic through VPN
PersistentKeepalive = 25
```

### 5. WAN Failover

NetworkManager handles both WAN connections. Set connection priorities:
```bash
nmcli connection modify "building-wifi" connection.autoconnect-priority 100
nmcli connection modify "lte-sim"       connection.autoconnect-priority 10
```

Add a connectivity check so NM detects when building WiFi has no actual internet
(it may be associated but captive-portaled or dead):

File: `/etc/NetworkManager/conf.d/connectivity.conf`
```ini
[connectivity]
uri=http://networkcheck.kde.org/
interval=60
```

NM will automatically fail over to LTE when the primary WAN loses connectivity.

### 6. SSH Access

SSH is accessible **only via the WireGuard VPN** (no direct SSH exposure to building WiFi or LTE). Once the MacBook connects to the WireGuard VPN:

```bash
ssh user@10.100.0.2
```

Harden `/etc/ssh/sshd_config`:
```
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers <your-username>
ListenAddress 10.100.0.2    # listen only on WireGuard interface
```

---

## IP Address Summary

| Host       | WireGuard IP  | Role            |
|------------|---------------|-----------------|
| VPS relay  | 10.100.0.1    | Hub / relay     |
| T15p       | 10.100.0.2    | Router / server |
| MacBook    | 10.100.0.3    | Road warrior    |

IoT LAN: `192.168.10.0/24` — gateway at `192.168.10.1` (T15p wlan1)

---

## Boot / Systemd Service Order

```
ModemManager.service
  └─> NetworkManager.service  (manages wlan0 STA + wwan0 LTE)
        └─> wg-quick@wg0.service   (WireGuard to VPS)
              └─> hostapd.service
              └─> dnsmasq.service
              └─> nftables.service
```

Key: WireGuard should start after NM has a default route; use `After=network-online.target`.

---

## Security Considerations

- SSH never exposed directly to internet — only reachable through WireGuard
- nftables drops all unsolicited inbound on WAN interfaces
- IoT devices are NATd and isolated on their own LAN; they cannot initiate connections to the WireGuard VPN subnet
- WireGuard keys are never committed to version control (use `.env.local`, already in `.gitignore`)
- LTE SIM is backup only — keep an eye on data usage; automate alerts if possible

---

## Implementation Steps

1. **Install OS**: Ubuntu 24.04 LTS Server on T15p
2. **Provision VPS**: Hetzner CX11 or Oracle Always Free (ARM) — install WireGuard, open UDP 51820
3. **Generate WireGuard keypairs**: T15p, VPS, MacBook
4. **Configure WireGuard on all three nodes** and verify connectivity
5. **Configure wlan1 AP**: hostapd + bring up interface with static IP 192.168.10.1
6. **Configure dnsmasq**: DHCP for IoT LAN
7. **Apply nftables rules** and enable ip_forward
8. **Test IoT LAN internet access** (connect a device, verify NAT)
9. **Test VPN from MacBook** (outside network, verify tunnel to T15p)
10. **Test SSH** over VPN
11. **Verify LTE failover**: disable wlan0, confirm wwan0 takes over
12. **Harden SSH** (keys only, listen on wg0 only)
13. **Set services to start on boot** via systemd

---

## Files in This Repo

```
configs/
  hostapd.conf          # AP configuration
  dnsmasq-iot.conf      # DHCP/DNS for IoT LAN
  nftables.conf         # Firewall + NAT rules
  wg0-t15p.conf         # WireGuard config for T15p (keys in .env.local)
  wg0-vps.conf          # WireGuard config for VPS (keys in .env.local)
  wg0-macbook.conf      # WireGuard config for MacBook client
  sshd_config.patch     # SSH hardening diff
  sysctl-router.conf    # ip_forward + related kernel params
  nm-connectivity.conf  # NetworkManager connectivity check
scripts/
  install.sh            # Applies all configs to the T15p
  keygen.sh             # Generates all WireGuard keypairs
.env.local              # Secret keys (never committed)
```
