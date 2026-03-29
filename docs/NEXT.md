# Next Steps

## LTE Failover + Direct Reachability

- Install SIM card in the Lenovo T15p's LTE slot
- Activate `wwan0` as a secondary WAN (see `src/server-Lenovo-T15p/lte/README.md` for the
  steps: uncomment wwan0 in nftables.conf, sysctl-router.conf, set NM connection priorities)
- **Direct reachability if VPS goes down**: when on LTE, the T15p gets a public IP (or
  carrier-grade NAT). Options to handle this:
  - If the carrier assigns a public IP: expose WireGuard directly on wwan0 (no VPS needed)
  - If behind CGNAT: set up a second relay (e.g. another Oracle Always Free instance) or use
    a dynamic DNS + port-forward workaround
  - Simplest fallback: keep the VPS as primary relay; if VPS is down, SSH in via the SIM's
    public IP directly (works only if carrier gives a real public IP)

## Reserve VPS Public IP ✅

- Assign a Reserved IP in Oracle Cloud so the VPS IP never changes on instance restart
- Without this, the IP is ephemeral and could change, breaking WireGuard on T15p and MacBook

## Disable Password-based SSH

- On T15p: set `PasswordAuthentication no` in `/etc/ssh/sshd_config` and restart sshd
- Ensures only key-based auth is accepted — prevents brute-force attacks if the T15p is
  ever directly reachable from the internet (e.g. via LTE with a public IP)
- Prerequisite: confirm your SSH key is working (`ssh as@10.100.0.2`) before disabling
  passwords to avoid locking yourself out

## VPS Location — Move Exit IP to Apartment ✅

- Implemented double-hop: MacBook → VPS → T15p → building WiFi → internet
- VPS uses policy routing (`ip rule from 10.100.0.3 table 100`) to forward MacBook traffic
  to T15p instead of masquerading out ens3
- T15p nftables allows wg0 → wlp0s20f3 forwarding and masquerades on wlp0s20f3
- Exit IP is now the apartment's building WiFi public IP

## Auto-start Server Mode on Boot

- Currently `mode.sh server` must be run manually after each reboot
- To automate: create a systemd service that runs `mode.sh server` after NetworkManager
  brings up `wlp0s20f3` (building WiFi) — needs an `After=` + `Wants=` dependency on the
  NM connection unit so the WAN is up before the server stack starts
- Risk: if WiFi fails at boot, the service will start without a working WAN — add a
  connectivity check or make the service restart on failure

## Disable any Ubuntu bullshit that may crash the services on the Lenovo

- What the title says

## Setup lenovo-to-lenovo VPN tunnel, so that no IP leaks when connecting to the VPN from the Macbook

- Create the tunnel between two independent machines. The Macbook connects to serving one and its already on the LAN on the other side of the tunnel (VLAN)?