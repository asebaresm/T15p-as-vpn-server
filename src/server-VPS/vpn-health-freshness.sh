#!/usr/bin/env bash
#
# /usr/local/sbin/vpn-health-freshness.sh — deployed by setup-status-dashboard.sh
#
# Writes /var/www/vpn-health/freshness.html, an SSI fragment that index.html
# (pushed by the T15) includes at the very top. Runs ON THE VPS every 30s, so it
# stays live even when the T15 stops pushing — the whole point: a push-only
# dashboard freezes silently when the pusher dies, still showing all-green.
#
# It reports TWO independent signals that test DIFFERENT network paths, so a
# failure localises the fault:
#
#   1. PUSH freshness   — age of index.html mtime. Path: T15 → public internet
#                         → VPS:22 (the SSH push). Tells us the snapshot pipeline
#                         is alive.
#   2. TUNNEL probe     — VPS actively pings the T15 at 10.100.0.2 over wg, and
#                         reads the T15 peer's last handshake age. Path: VPS →
#                         wg tunnel → T15. The VPS's OWN direct opinion of the
#                         T15, independent of whether the T15 is pushing.
#
# Fault localisation from the combination:
#   push OK   + tunnel OK   → fully healthy
#   push STALE+ tunnel OK   → T15 + tunnel are UP, but the SSH push is broken
#                             (snapshot timer/key/disk). Narrow problem.
#   push STALE+ tunnel DOWN → T15 is down or its WAN is down (both paths dead).
#   push OK   + tunnel DOWN → wg/routing problem (rare; push uses public path).
#
# Overall banner colour = worst of the two signals.

set -uo pipefail

DOCROOT=/var/www/vpn-health
INDEX="$DOCROOT/index.html"
OUT="$DOCROOT/freshness.html"
T15_WG_IP=10.100.0.2
WARN_S=120        # push amber after 2 min (push every 60s → 2 missed)
STALE_S=300       # push red after 5 min
HS_STALE_S=300    # wg handshake red after 5 min

now=$(date +%s)

# ── Signal 1: push freshness (index.html mtime age) ──────────────────────────
if [[ -f "$INDEX" ]]; then
  age=$(( now - $(stat -c %Y "$INDEX" 2>/dev/null || echo 0) ))
else
  age=999999
fi
fmt_age() {  # seconds → human
  local s=$1
  if   (( s < 90 ));   then echo "${s}s"
  elif (( s < 5400 )); then echo "$(( s/60 ))m $(( s%60 ))s"
  else                      echo "$(( s/3600 ))h $(( (s%3600)/60 ))m"
  fi
}
push_human=$(fmt_age "$age")
if   (( age >= STALE_S )); then push_sev=2; push_txt="STALE — no push for ${push_human}"
elif (( age >= WARN_S ));  then push_sev=1; push_txt="LAGGING — last push ${push_human} ago"
else                            push_sev=0; push_txt="LIVE — pushed ${push_human} ago"
fi

# ── Signal 2: VPS actively probes the T15 over wg ────────────────────────────
# Ping (2 quick tries) = is the T15 reachable through the tunnel right now.
if ping -c2 -W2 -n "$T15_WG_IP" &>/dev/null; then
  ping_ok=1
else
  ping_ok=0
fi
# Handshake age of the T15 peer (the one whose allowed-ips include 0.0.0.0/0).
hs_age=""
t15_pk=$(wg show wg0 allowed-ips 2>/dev/null | awk '/0\.0\.0\.0\/0/{print $1; exit}')
if [[ -n "$t15_pk" ]]; then
  hs_ts=$(wg show wg0 latest-handshakes 2>/dev/null | awk -v k="$t15_pk" '$1==k{print $2}')
  [[ -n "$hs_ts" && "$hs_ts" != "0" ]] && hs_age=$(( now - hs_ts ))
fi

if (( ping_ok == 1 )); then
  tun_sev=0; tun_txt="T15 reachable over wg"
  [[ -n "$hs_age" ]] && tun_txt="$tun_txt (handshake $(fmt_age "$hs_age") ago)"
else
  tun_sev=2; tun_txt="T15 UNREACHABLE over wg"
  if [[ -n "$hs_age" ]]; then
    tun_txt="$tun_txt — last handshake $(fmt_age "$hs_age") ago"
  else
    tun_txt="$tun_txt — no handshake on record"
  fi
fi
# A very old handshake but still ping-OK shouldn't happen, but flag it amber.
if (( ping_ok == 1 )) && [[ -n "$hs_age" ]] && (( hs_age >= HS_STALE_S )); then
  tun_sev=1
fi

# ── Combine ──────────────────────────────────────────────────────────────────
sev=$(( push_sev > tun_sev ? push_sev : tun_sev ))
case "$sev" in
  2) bg="#5a1111"; fg="#ff6b6b"; icon="⛔"; head="PROBLEM" ;;
  1) bg="#4a3a11"; fg="#ffcf6b"; icon="◌"; head="DEGRADED" ;;
  *) bg="#11331a"; fg="#7CFC9B"; icon="●"; head="HEALTHY" ;;
esac
# Per-signal mini-markers (sev 0/1/2 → ✓/◌/✗)
sevsym() { case "$1" in 2) echo "✗";; 1) echo "◌";; *) echo "✓";; esac; }
psym=$(sevsym "$push_sev")
tsym=$(sevsym "$tun_sev")

# Atomic write so nginx never serves a half-written fragment.
tmp="$OUT.tmp"
cat > "$tmp" <<HTML
<div style="background:$bg;color:$fg;font-weight:bold;padding:0.6rem 0.8rem;
            border-radius:4px;margin:0 0 0.8rem;font-size:0.95rem;line-height:1.5;">
  $icon FRESHNESS — $head <span style="float:right;font-weight:normal;opacity:0.7;">checked by VPS @ $(date '+%H:%M:%S %Z')</span><br>
  <span style="font-weight:normal;">&nbsp;&nbsp;$psym push pipeline: $push_txt</span><br>
  <span style="font-weight:normal;">&nbsp;&nbsp;$tsym tunnel (VPS→T15): $tun_txt</span>
</div>
HTML
mv "$tmp" "$OUT"
chmod 644 "$OUT"
