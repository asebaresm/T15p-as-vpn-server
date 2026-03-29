# Project Status — 2026-03-29

## VPS (Oracle Cloud, Marseille) ✅ Done

- **Instance**: VM.Standard.E2.1.Micro (AMD), Ubuntu 24.04
- **Public IP**: 130.110.246.244
- **WireGuard**: running, listening on UDP 51820, enabled on boot
- **Peers registered**: T15p (10.100.0.2), MacBook (10.100.0.3)
- **SSH access**: `ssh -i ops/server-VPS/oracle/vps-ssh-key ubuntu@130.110.246.244`

---

## T15p (Lenovo ThinkPad T15p Gen2) ✅ Done

- **Mode**: server mode active (`sudo bash ops/server-Lenovo-T15p/mode.sh server`)
- **WireGuard**: tunnel to VPS up, handshake confirmed
- **LAN**: enp0s31f6 → MR550, IP 192.168.10.1/24, dnsmasq serving DHCP+DNS
- **Firewall**: nftables — NAT on wlp0s20f3, SSH + DNS allowed on wg0
- **SSH**: openssh-server installed, key-based auth from MacBook configured
- **Revert**: `sudo bash ops/server-Lenovo-T15p/install.sh rollback`

---

## MR550 (TP-Link Archer MR550) ✅ Done

- **Mode**: Wireless Router Mode (WAN = T15p enp0s31f6 via ethernet)
- **WAN**: Dynamic IP, got lease 192.168.10.131 from T15p dnsmasq
- **IoT WiFi**: 2.4GHz + 5GHz broadcasting, internet access confirmed

---

## MacBook (client-macos) ✅ Done

- **WireGuard**: tunnel active, peer = VPS (130.110.246.244:51820)
- **Internet**: full tunnel (0.0.0.0/0), exit IP = Marseille (VPS)
- **DNS**: 10.100.0.2 (T15p dnsmasq), working
- **SSH to T15p**: `ssh as@10.100.0.2`, key-based auth configured

---

## End-to-end ✅ All tested

- [x] T15p in server mode: MR550 gets DHCP, IoT devices reach internet
- [x] MacBook VPN → VPS → internet (exit IP Marseille)
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
