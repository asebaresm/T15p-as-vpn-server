# Project Status — 2026-04-04

## VPS (Oracle Cloud, Marseille) ✅ Done

- **Instance**: VM.Standard.E2.1.Micro (AMD), Ubuntu 24.04
- **Public IP**: `<VPS_SERVER_PUBLIC_IP>` (reserved, permanent)
- **WireGuard**: running, listening on UDP 51820, enabled on boot, `Table = off`
- **Role**: relay only — MacBook traffic is forwarded to T15p (policy routing, table 100)
- **Peers registered**: T15p (10.100.0.2), MacBook (10.100.0.3)
- **SSH access**: `ssh -i ops/server-VPS/oracle/vps-ssh-key ubuntu@<VPS_SERVER_PUBLIC_IP>`

---

## T15p (Lenovo ThinkPad T15p Gen2) ✅ Done

- **Mode**: server mode — auto-starts on boot via `t15p-server.service`
- **WireGuard**: tunnel to VPS up, handshake confirmed
- **LAN**: enp0s31f6 → MR550, IP 192.168.10.1/24, dnsmasq serving DHCP+DNS
- **Firewall**: nftables — NAT on wlp0s20f3, SSH + DNS allowed on wg0, wg0 → WAN forwarding for double-hop
- **SSH**: openssh-server installed and enabled at boot, key-based auth from MacBook
- **Hardening**: auto-start on boot, watchdog every 2 min, no auto-reboot, no suspend on lid close, snap refresh limited to Sunday 4 AM
- **Revert**: `sudo bash ops/server-Lenovo-T15p/install.sh rollback` / `sudo bash ops/server-Lenovo-T15p/harden.sh undo`

---

## MR550 (TP-Link Archer MR550) ✅ Done

- **Mode**: Wireless Router Mode (WAN = T15p enp0s31f6 via ethernet)
- **WAN**: Dynamic IP, lease from T15p dnsmasq
- **IoT WiFi**: 2.4GHz + 5GHz broadcasting, internet access confirmed

---

## MacBook (client-macos) ✅ Done

- **WireGuard**: tunnel active, peer = VPS (`<VPS_SERVER_PUBLIC_IP>:51820`)
- **Internet**: full tunnel (0.0.0.0/0), double-hop via T15p — exit IP = apartment
- **DNS**: 10.100.0.2 (T15p dnsmasq), working
- **SSH to T15p**: `ssh as@10.100.0.2`, key-based auth configured

---

## End-to-end ✅ All tested

- [x] T15p auto-starts server mode on boot (no manual intervention)
- [x] T15p survives reboot — all services come up automatically
- [x] Watchdog restarts failed services within 2 minutes
- [x] MR550 gets DHCP, IoT devices reach internet
- [x] MacBook VPN → VPS → T15p → internet (double-hop, exit IP apartment)
- [x] DNS via T15p (ping google.com works on MacBook over VPN)
- [x] SSH from MacBook to T15p over VPN (`ssh as@10.100.0.2`)

---

## Keys & Secrets

All WireGuard private keys and the VPS public IP stored in `.env.local` (gitignored).
Oracle credentials in `ops/server-VPS/oracle/` (gitignored).
