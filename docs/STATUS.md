# Project Status — 2026-03-30

## VPS (Oracle Cloud, Marseille) ✅ Done

- **Instance**: VM.Standard.E2.1.Micro (AMD), Ubuntu 24.04
- **Public IP**: <VPS_SERVER_PUBLIC_IP>
- **WireGuard**: running, listening on UDP 51820, enabled on boot
- **Role**: relay only — MacBook traffic is forwarded to T15p (policy routing, table 100)
- **Peers registered**: T15p (10.100.0.2), MacBook (10.100.0.3)
- **SSH access**: `ssh -i ops/server-VPS/oracle/vps-ssh-key ubuntu@<VPS_SERVER_PUBLIC_IP>`

---

## T15p (Lenovo ThinkPad T15p Gen2) ✅ Done

- **Mode**: server mode active (`sudo bash ops/server-Lenovo-T15p/mode.sh server`)
- **WireGuard**: tunnel to VPS up, handshake confirmed
- **LAN**: enp0s31f6 → MR550, IP 192.168.10.1/24, dnsmasq serving DHCP+DNS
- **Firewall**: nftables — NAT on wlp0s20f3, SSH + DNS allowed on wg0, wg0 → WAN forwarding for double-hop
- **SSH**: openssh-server installed, key-based auth from MacBook configured
- **Revert**: `sudo bash ops/server-Lenovo-T15p/install.sh rollback`

---

## MR550 (TP-Link Archer MR550) ✅ Done

- **Mode**: Wireless Router Mode (WAN = T15p enp0s31f6 via ethernet)
- **WAN**: Dynamic IP, got lease 192.168.10.131 from T15p dnsmasq
- **IoT WiFi**: 2.4GHz + 5GHz broadcasting, internet access confirmed

---

## MacBook (client-macos) ✅ Done

- **WireGuard**: tunnel active, peer = VPS (<VPS_SERVER_PUBLIC_IP>:51820)
- **Internet**: full tunnel (0.0.0.0/0), double-hop via T15p — exit IP = apartment
- **DNS**: 10.100.0.2 (T15p dnsmasq), working
- **SSH to T15p**: `ssh as@10.100.0.2`, key-based auth configured

---

## End-to-end ✅ All tested

- [x] T15p in server mode: MR550 gets DHCP, IoT devices reach internet
- [x] MacBook VPN → VPS → T15p → internet (double-hop, exit IP apartment)
- [x] DNS via T15p (ping google.com works on MacBook over VPN)
- [x] SSH from MacBook to T15p over VPN (`ssh as@10.100.0.2`)

---

## Pending / Future

- [ ] LTE failover (SIM card not yet installed — see `src/server-Lenovo-T15p/lte/README.md`)
- [ ] Auto-start server mode on boot (currently requires manual `mode.sh server`)

---

## Keys & Secrets

All WireGuard private keys stored in `.env.local` (gitignored).
Oracle credentials in `ops/server-VPS/oracle/` (gitignored).
