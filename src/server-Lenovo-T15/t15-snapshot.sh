#!/usr/bin/env bash
#
# /usr/local/sbin/t15-snapshot.sh — managed by t15 deploy
#
# Renders an HTML status page for https://vpn-health.<domain>/ and pushes it
# to the Hetzner VPS via SSH. Run every 60 seconds by t15-snapshot.timer.
#
# Push transport: ssh -i /root/.ssh/t15-snapshot-vps-key root@<vps>, where the
# VPS-side /root/.ssh/authorized_keys has a forced-command clause that pipes
# stdin into /var/www/vpn-health/index.html atomically. See
# ops/server-VPS/setup-status-dashboard.sh for the authorization.
#
# {{VPS_SERVER_PUBLIC_IP}} is substituted at deploy time by the t15 tool.
# Re-deploy (sudo t15 deploy) after any change to this file or after a VPS
# provider swap.

# Intentionally NOT -e: a single probe failing should still produce a (degraded)
# snapshot. Push failure is logged via journald but the timer continues firing.
set -uo pipefail

VPS_IP={{VPS_SERVER_PUBLIC_IP}}
PUSH_KEY=/root/.ssh/t15-snapshot-vps-key
DEST_USER=root

# Read-only forced-command key that runs /usr/local/sbin/vpn-relay-health.sh on
# the VPS, queried over the wg tunnel (reachable even when client-relay
# forwarding is broken — the exact blind spot this was added to cover).
RELAY_CHECK_KEY=/root/.ssh/t15-relay-check-key

# Heartbeat targets
LAN_IFACE=enp0s31f6
MR550_HOSTNAME=Archer_MR550   # match against dnsmasq.leases column 4
VPS_WG_IP=10.100.0.1
INTERNET_IP=1.1.1.1
DNS_NAME=google.com

NOW_HUMAN=$(date '+%Y-%m-%d %H:%M:%S %Z')
HOSTNAME=$(hostname)

# ── Helpers ──────────────────────────────────────────────────────────────────
# HTML-escape stdin (< > & only — sufficient for our content)
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Ping a target, parse RTT. Emits one line: "  ✓ <name> → <target> (X ms)"
# or "  ✗ <name> → <target> (unreachable)".
ping_probe() {
  local target="$1" name="$2" rtt
  rtt=$(ping -c1 -W1 -n "$target" 2>/dev/null \
    | awk -F'time=' '/time=/{split($2,a," "); print a[1]; exit}')
  if [[ -n "$rtt" ]]; then
    echo "  ✓ $name → $target ($rtt ms)"
  else
    echo "  ✗ $name → $target (unreachable)"
  fi
}

# Query the VPS relay invariants over the wg tunnel (read-only forced-command
# key). Caches the raw output in RELAY_RAW for the detail section below.
# IdentitiesOnly=yes is REQUIRED: without it ssh also offers the snapshot push
# key (also authorized on the VPS), the VPS may match THAT key first and run its
# push forced-command (which reads stdin → empty) instead of vpn-relay-health.sh,
# yielding a spurious "could not query".
RELAY_RAW=""
relay_probe() {
  RELAY_RAW=$(ssh -i "$RELAY_CHECK_KEY" -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
    root@"$VPS_WG_IP" 2>/dev/null)
  if [[ -z "$RELAY_RAW" ]]; then
    echo "  ✗ VPS relay forwarding → could not query (key missing or VPS unreachable)"
  elif grep -q '^RELAY: ok' <<<"$RELAY_RAW"; then
    echo "  ✓ VPS relay forwarding → all invariants hold (clients can exit)"
  else
    local n
    n=$(grep -c 'FAIL' <<<"$RELAY_RAW")
    echo "  ✗ VPS relay forwarding → DEGRADED ($n broken) — clients have NO internet"
  fi
}

# LAN check for the MR550. Layered probe:
#   1. Ethernet link state (link DOWN → cable unplugged)
#   2. DHCP lease present in dnsmasq.leases (no lease → MR550 never asked)
#   3. ICMP ping (primary liveness signal; requires "ICMP Ping: Remote"
#      enabled in the MR550 admin UI: System Tools → Administration)
# On ping failure, we report the ARP state to narrow down whether the MR550
# is fully gone (no ARP) vs silent at L3 only (ARP REACHABLE, no ping).
mr550_probe() {
  local lan_state lease ip mac rtt arp_state
  lan_state=$(ip -o link show "$LAN_IFACE" 2>/dev/null \
    | grep -oE 'state [A-Z]+' | awk '{print $2}')
  if [[ "$lan_state" != "UP" ]]; then
    echo "  ✗ LAN ($LAN_IFACE) — link ${lan_state:-MISSING} (MR550 cable unplugged?)"
    return
  fi
  lease=$(awk -v h="$MR550_HOSTNAME" '$4==h {print; exit}' /var/lib/misc/dnsmasq.leases 2>/dev/null)
  if [[ -z "$lease" ]]; then
    echo "  ✗ LAN — link UP but no DHCP lease for '$MR550_HOSTNAME' in dnsmasq.leases"
    return
  fi
  ip=$(echo "$lease"  | awk '{print $3}')
  mac=$(echo "$lease" | awk '{print $2}')

  rtt=$(ping -c1 -W1 -n "$ip" 2>/dev/null \
    | awk -F'time=' '/time=/{split($2,a," "); print a[1]; exit}')
  if [[ -n "$rtt" ]]; then
    echo "  ✓ LAN → MR550 ($ip, $mac) — link UP, ping $rtt ms"
    return
  fi

  # Ping failed — annotate with ARP state for diagnostic context.
  arp_state=$(ip -o neigh show "$ip" dev "$LAN_IFACE" 2>/dev/null | awk '{print $NF}')
  echo "  ✗ LAN → MR550 ($ip) — link UP, ping FAILED, ARP ${arp_state:-absent} (re-enable 'ICMP Ping: Remote' in MR550 admin?)"
}

# DNS resolution check (via the system resolver, which goes through dnsmasq on wg0).
dns_probe() {
  local name="$1" addr
  addr=$(getent ahosts "$name" 2>/dev/null | awk 'NR==1{print $1}')
  if [[ -n "$addr" ]]; then
    echo "  ✓ DNS → $name (resolved to $addr)"
  else
    echo "  ✗ DNS → $name (resolution failed)"
  fi
}

# journalctl tail for a unit, HTML-escaped.
journal_tail() {
  local unit="$1" lines="${2:-30}"
  journalctl --no-pager -n "$lines" -u "$unit" 2>&1 | html_escape
}

# dnsmasq tail, with per-query DNS noise stripped (privacy + signal).
journal_tail_dnsmasq() {
  local lines="${1:-30}"
  journalctl --no-pager -n 200 -u dnsmasq 2>&1 \
    | grep -vE 'query\[|reply [0-9a-f.:]+ is ' \
    | tail -n "$lines" | html_escape
}

# ── Build the page into a tmp file, then push ────────────────────────────────
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

{
  cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>vpn-health · $HOSTNAME</title>
<style>
body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; margin: 1rem;
       background: #111; color: #ddd; line-height: 1.4; }
h1 { font-size: 1.1rem; margin: 0 0 0.25rem; color: #fff; }
h2 { font-size: 0.95rem; margin: 1.2rem 0 0.4rem; color: #fff;
     border-bottom: 1px solid #333; padding-bottom: 0.25rem; }
p.meta { font-size: 0.85rem; color: #888; margin: 0 0 1rem; }
pre { background: #1a1a1a; padding: 0.75rem; overflow-x: auto;
      white-space: pre-wrap; word-break: break-word; font-size: 0.8rem;
      margin: 0.3rem 0; border-radius: 3px; }
details { margin: 0.3rem 0; }
summary { cursor: pointer; padding: 0.25rem 0; color: #bbb; }
summary:hover { color: #fff; }
</style>
</head>
<body>
<h1>vpn-health · $HOSTNAME</h1>
<p class="meta">last push: <strong>$NOW_HUMAN</strong> · page auto-refreshes every 30 s.
If the push timestamp stops moving, the snapshot timer or the WAN on $HOSTNAME has stalled.</p>

<h2>Heartbeats</h2>
<pre>
EOF

  mr550_probe
  ping_probe "$VPS_WG_IP"   "T15 → VPS over wg"
  ping_probe "$VPS_IP"      "T15 → VPS over WAN"
  ping_probe "$INTERNET_IP" "T15 → internet"
  dns_probe  "$DNS_NAME"
  relay_probe

  cat <<EOF
</pre>

<h2>VPS relay invariants</h2>
<pre>
EOF
  if [[ -n "$RELAY_RAW" ]]; then
    html_escape <<<"$RELAY_RAW"
  else
    echo "  (no data — relay-check key missing or VPS unreachable over wg)"
  fi

  cat <<EOF
</pre>

<h2>t15 status</h2>
<pre>
EOF
  /usr/local/bin/t15 status 2>&1 | html_escape

  cat <<EOF
</pre>

<h2>Recent logs</h2>

<details open><summary>t15-watchdog (last 20)</summary><pre>
EOF
  journal_tail t15-watchdog.service 20

  cat <<EOF
</pre></details>

<details><summary>wg-quick@wg0 (last 30)</summary><pre>
EOF
  journal_tail "wg-quick@wg0.service" 30

  cat <<EOF
</pre></details>

<details><summary>dnsmasq (last 30, DNS queries filtered)</summary><pre>
EOF
  journal_tail_dnsmasq 30

  cat <<EOF
</pre></details>

<details><summary>NetworkManager (last 30)</summary><pre>
EOF
  journal_tail NetworkManager.service 30

  cat <<EOF
</pre></details>

<details><summary>t15-lan (last 10)</summary><pre>
EOF
  journal_tail t15-lan.service 10

  cat <<EOF
</pre></details>

<details><summary>nftables (last 5)</summary><pre>
EOF
  journal_tail nftables.service 5

  cat <<EOF
</pre></details>

<details><summary>ssh (last 10)</summary><pre>
EOF
  journal_tail ssh.service 10

  cat <<EOF
</pre></details>

</body>
</html>
EOF
} > "$TMP"

# ── Push to VPS via the forced-command SSH key ──────────────────────────────
# The remote's authorized_keys has command="cat > .tmp && mv .tmp index.html",
# so whatever we "run" is ignored; only our stdin matters.
if ssh -i "$PUSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
       "$DEST_USER@$VPS_IP" < "$TMP" >/dev/null 2>&1; then
  logger -t t15-snapshot "pushed $(wc -c < "$TMP") bytes"
else
  rc=$?
  logger -t t15-snapshot "push FAILED (ssh exit $rc)"
fi
