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

# Fan % is derived from RPM / FAN_MAX_RPM (ThinkPads don't expose a max RPM, and
# in 'auto' mode the PWM level isn't a number). Tune this once you've seen the
# fan max out under sustained load: watch the dashboard's "fan" rpm during a
# stress run and set this to the highest value observed.
FAN_MAX_RPM=4500

NOW_HUMAN=$(date '+%Y-%m-%d %H:%M:%S %Z')
HOSTNAME=$(hostname)

# ── Helpers ──────────────────────────────────────────────────────────────────
# HTML-escape stdin (< > & only — sufficient for our content)
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Colorize already-escaped text: wrap whole lines that signal trouble in a
# coloured span. MUST run AFTER html_escape (it injects real <span> tags). The
# marker chars (✗ ⚠ ✓) survive html_escape since they aren't < > &.
#   red   ← any line with ✗, FAIL, DEGRADED/degraded, "not active", "could not"
#   amber ← any line with ⚠ or "WARN"
# Probes that emit only numbers (thermals, top5) append a ✗/⚠ marker themselves
# when a threshold is crossed, so this one filter colours every section.
colorize() {
  sed -E \
    -e 's@^(.*(✗|FAIL|DEGRADED|degraded|not active|could not|unreachable|failed).*)$@<span class="bad">\1</span>@' \
    -e 's@^(.*(⚠|WARN).*)$@<span class="warn">\1</span>@'
}

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
# relay_fetch MUST run in the main shell (not inside a pipe/subshell), or the
# RELAY_RAW it sets won't survive for the invariants section. relay_line only
# formats the one-line summary and can run anywhere (it just reads RELAY_RAW).
relay_fetch() {
  RELAY_RAW=$(ssh -i "$RELAY_CHECK_KEY" -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
    root@"$VPS_WG_IP" 2>/dev/null)
}
relay_line() {
  if [[ -z "$RELAY_RAW" ]]; then
    echo "  ✗ VPS relay forwarding → could not query (key missing or VPS unreachable)"
  elif grep -q '^RELAY: ok' <<<"$RELAY_RAW"; then
    echo "  ✓ VPS relay forwarding → all invariants hold (clients can exit)"
  else
    local n; n=$(grep -c 'FAIL' <<<"$RELAY_RAW")
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

# Thermals + fan. Fan RPM from thinkpad_acpi; CPU package temp from lm-sensors
# (the temp is what drives the fan, so showing both explains spin-ups). Fan % is
# an estimate vs FAN_MAX_RPM — see the note at that constant.
thermals_probe() {
  local rpm pct temp loadavg z
  rpm=$(awk '/^speed:/{print $2; exit}' /proc/acpi/ibm/fan 2>/dev/null)
  # CPU package temp. /proc/acpi/ibm/thermal field 1 is NOT the package (it read
  # ~54°C while cores were at 88°C) — use the x86_pkg_temp thermal zone, located
  # by type since the zone NUMBER isn't stable across reboots. No lm-sensors here.
  for z in /sys/class/thermal/thermal_zone*; do
    if [[ "$(cat "$z/type" 2>/dev/null)" == "x86_pkg_temp" ]]; then
      temp=$(( $(cat "$z/temp" 2>/dev/null) / 1000 )); break
    fi
  done
  loadavg=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
  # Threshold markers (✗=bad ⚠=warn) appended to a line so colorize() colours it.
  if [[ -n "$rpm" ]]; then
    pct=$(( rpm * 100 / FAN_MAX_RPM ))
    (( pct > 100 )) && pct=100
    local fmark=""
    if   (( pct >= 98 )); then fmark="  ✗"
    elif (( pct >= 90 )); then fmark="  ⚠"
    fi
    printf '  fan          : %s rpm  (~%s%% of %s assumed max)%s\n' "$rpm" "$pct" "$FAN_MAX_RPM" "$fmark"
  else
    printf '  fan          : (unavailable — thinkpad_acpi not loaded?)\n'
  fi
  if [[ -n "$temp" ]]; then
    local tmark=""
    if   (( temp >= 90 )); then tmark="  ✗"
    elif (( temp >= 80 )); then tmark="  ⚠"
    fi
    printf '  cpu          : %s °C%s\n' "$temp" "$tmark"
  fi
  [[ -n "$loadavg" ]] && printf '  load (1/5/15): %s\n' "$loadavg"
  # Memory: used / total and percent (MiB). ⚠ >=80%, ✗ >=90%.
  free -m 2>/dev/null | awk '/^Mem:/{
    p=($3*100/$2); m=(p>=90?"  ✗":(p>=80?"  ⚠":""))
    printf "  memory       : %d / %d MiB used (%d%%)%s\n", $3, $2, p, m
  }'
  # Swap, only if any is configured. Any swap-in-use on a 16GB box is notable.
  free -m 2>/dev/null | awk '/^Swap:/ && $2>0 {
    p=($3*100/$2); m=(p>=50?"  ✗":(p>=10?"  ⚠":""))
    printf "  swap         : %d / %d MiB used (%d%%)%s\n", $3, $2, p, m
  }'
}

# Top 5 processes by instantaneous CPU. Uses top -bn2 (two samples) and parses
# the SECOND iteration, so values are real-time — a process that just started
# pegging a core (e.g. a firefox/snap update) shows up immediately. ps pcpu is a
# lifetime average and would under-report exactly that case. Columns: %CPU %MEM.
topcpu_probe() {
  printf '   %%CPU   %%MEM  USER       COMMAND\n'
  top -bn2 -d 0.4 2>/dev/null | awk '
    /^[[:space:]]*PID[[:space:]]+USER/ { n=0; delete r; cap=1; next }
    cap && NF>=12 { r[++n]=$0 }
    END {
      for (i=1; i<=n && i<=5; i++) {
        c=r[i]; split(c, f, " ")
        # top columns: 9=%CPU 10=%MEM 2=USER 12=COMMAND. top prints %CPU with a
        # decimal comma in some locales — normalise to a dot for the compare.
        cpu=f[9]; gsub(",", ".", cpu); cpu+=0
        # ✗ if a single process is pegging ~a full core or more, ⚠ at half.
        mark=(cpu>=90?"  ✗":(cpu>=50?"  ⚠":""))
        printf "  %5s%%  %5s%%  %-9s %s%s\n", f[9], f[10], f[2], f[12], mark
      }
    }'
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
.bad  { color: #ff5c5c; font-weight: bold; }
.warn { color: #ffb454; }
details { margin: 0.3rem 0; }
summary { cursor: pointer; padding: 0.25rem 0; color: #bbb; }
summary:hover { color: #fff; }
</style>
</head>
<body>
<!--#include file="freshness.html"-->
<h1>vpn-health · $HOSTNAME</h1>
<p class="meta">last push: <strong>$NOW_HUMAN</strong> · page auto-refreshes every 30 s.
The green/red FRESHNESS banner above is written by the VPS, not the T15 — so it
stays live and turns red even when this whole page is a frozen snapshot.</p>

<h2>Heartbeats</h2>
<pre>
EOF

  # Fetch the relay status in THIS shell first — relay_line/the invariants
  # section both read RELAY_RAW, and a pipe (| colorize) would run the fetch in a
  # subshell where the assignment wouldn't survive.
  relay_fetch
  # Heartbeat probes emit ✓/✗ lines; group + colorize so ✗ lines render red.
  { mr550_probe
    ping_probe "$VPS_WG_IP"   "T15 → VPS over wg"
    ping_probe "$VPS_IP"      "T15 → VPS over WAN"
    ping_probe "$INTERNET_IP" "T15 → internet"
    dns_probe  "$DNS_NAME"
    relay_line
  } | colorize

  cat <<EOF
</pre>

<h2>VPS relay invariants</h2>
<pre>
EOF
  if [[ -n "$RELAY_RAW" ]]; then
    html_escape <<<"$RELAY_RAW" | colorize
  else
    echo '<span class="bad">  ✗ no data — relay-check key missing or VPS unreachable over wg</span>'
  fi

  cat <<EOF
</pre>

<h2>System — thermals &amp; fan</h2>
<pre>
EOF
  thermals_probe | colorize

  cat <<EOF
</pre>

<h2>Top 5 processes by CPU</h2>
<pre>
EOF
  topcpu_probe | html_escape | colorize

  cat <<EOF
</pre>

<h2>t15 status</h2>
<pre>
EOF
  /usr/local/bin/t15 status 2>&1 | html_escape | colorize

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
