#!/usr/bin/env bash
#
# setup-status-dashboard.sh — idempotent setup of the T15 VPN-health dashboard
# on the Hetzner VPS.
#
# What this does:
#   1. Ensures a Cloudflare A record for $DOMAIN points at the VPS public IP
#   2. Installs nginx + certbot + the Cloudflare DNS plugin on the VPS
#   3. Drops Cloudflare credentials into /root/.secrets/cloudflare.ini on the VPS
#   4. Requests / verifies a Let's Encrypt cert via DNS-01 (no port 80 needed)
#   5. Ensures the basic-auth user exists (password persisted in .env.local)
#   6. Writes the nginx vhost (HTTPS + HSTS + auth + DNS-only)
#   7. Drops a placeholder /var/www/<docroot>/index.html until first push
#   8. (Optional) Authorizes a T15 push-only SSH key with a forced-command
#      clause that ONLY allows writing the dashboard's index.html
#
# Re-runs are safe: every step checks current state before mutating. The
# basic-auth password is generated once and stored in .env.local as
# VPN_HEALTH_BASIC_AUTH_PASS; subsequent runs reuse it.
#
# Usage:
#   bash ops/server-VPS/setup-status-dashboard.sh [domain] [auth_user] [push_key_pub_file]
#
# Defaults:
#   domain             = vpn-health.mydomain.tld
#   auth_user          = as
#   push_key_pub_file  = (none — step 8 skipped if not given)
#
# Reads from .env.local at repo root:
#   CLOUDFLARE_EMAIL              — account email paired with the global API key
#   CLOUDFLARE_GLOBAL_API_KEY     — Cloudflare global API key
#   HETZNER_VPS_SERVER_PUBLIC_IP  — VPS IP the A record will point at
#   ROOT                          — optional, only used if sudo prompts locally
# Writes back to .env.local on first run:
#   VPN_HEALTH_BASIC_AUTH_PASS    — random password for $AUTH_USER

set -euo pipefail

DOMAIN="${1:-vpn-health.mydomain.tld}"
AUTH_USER="${2:-as}"
PUSH_KEY_PUB_FILE="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$ROOT_DIR/.env.local"

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n'  "$*"; }
warn() { printf '!   %s\n'  "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "$ENV_FILE missing — run from project root"
set -a; source "$ENV_FILE"; set +a

for v in CLOUDFLARE_EMAIL CLOUDFLARE_GLOBAL_API_KEY HETZNER_VPS_SERVER_PUBLIC_IP; do
  [[ -n "${!v:-}" ]] || die "$v not set in $ENV_FILE"
done
command -v curl >/dev/null  || die "curl required locally"
command -v jq   >/dev/null  || die "jq required locally (sudo apt install jq)"

VPS_IP="$HETZNER_VPS_SERVER_PUBLIC_IP"
SSH_KEY="$ROOT_DIR/ops/server-VPS/hetzner/vps-ssh-key"
[[ -f "$SSH_KEY" ]] || die "SSH key not found at $SSH_KEY"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
ssh_vps() { ssh "${SSH_OPTS[@]}" "root@$VPS_IP" "$@"; }

# Parent zone for the domain (last two labels) — e.g. vpn-health.mydomain.tld → mydomain.tld
ZONE_DOMAIN=$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')

# ── Cloudflare API helpers ──────────────────────────────────────────────────
cf_api() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -X "$method" "https://api.cloudflare.com/client/v4$path"
              -H "X-Auth-Email: $CLOUDFLARE_EMAIL"
              -H "X-Auth-Key: $CLOUDFLARE_GLOBAL_API_KEY"
              -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}"
}

cf_must_succeed() {
  local resp="$1" context="$2"
  if ! echo "$resp" | jq -e '.success' >/dev/null 2>&1; then
    die "Cloudflare API call failed ($context): $(echo "$resp" | jq -c '.errors // .')"
  fi
}

# ── Step 1: Cloudflare DNS A record ─────────────────────────────────────────
log "[1/8] Cloudflare A record  $DOMAIN → $VPS_IP  (zone $ZONE_DOMAIN)"

ZONE_RESP=$(cf_api GET "/zones?name=$ZONE_DOMAIN")
cf_must_succeed "$ZONE_RESP" "zone lookup"
ZONE_ID=$(echo "$ZONE_RESP" | jq -r '.result[0].id // empty')
[[ -n "$ZONE_ID" ]] || die "Cloudflare zone '$ZONE_DOMAIN' not found on this account"
info "zone id: $ZONE_ID"

REC_RESP=$(cf_api GET "/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN")
cf_must_succeed "$REC_RESP" "record lookup"
REC_ID=$(echo      "$REC_RESP" | jq -r '.result[0].id      // empty')
REC_CONTENT=$(echo "$REC_RESP" | jq -r '.result[0].content // empty')

RECORD_BODY=$(jq -nc --arg name "$DOMAIN" --arg content "$VPS_IP" \
  '{type:"A",name:$name,content:$content,ttl:300,proxied:false}')

if [[ -z "$REC_ID" ]]; then
  info "creating new A record (DNS-only, TTL 300)"
  RESP=$(cf_api POST "/zones/$ZONE_ID/dns_records" "$RECORD_BODY")
  cf_must_succeed "$RESP" "record create"
elif [[ "$REC_CONTENT" == "$VPS_IP" ]]; then
  info "A record already at $VPS_IP — no change"
else
  info "updating A record from $REC_CONTENT to $VPS_IP"
  RESP=$(cf_api PUT "/zones/$ZONE_ID/dns_records/$REC_ID" "$RECORD_BODY")
  cf_must_succeed "$RESP" "record update"
fi

# ── Step 2: install VPS packages ────────────────────────────────────────────
log "[2/8] install nginx + certbot + Cloudflare plugin on VPS"
ssh_vps 'set -e
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
  needed=""
  for p in nginx certbot python3-certbot-dns-cloudflare apache2-utils jq; do
    dpkg -s "$p" &>/dev/null || needed="$needed $p"
  done
  if [[ -n "$needed" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $needed >/dev/null
    printf "    installed:%s\n" "$needed"
  else
    printf "    all packages already present\n"
  fi'

# ── Step 3: Cloudflare credentials file on VPS (used by certbot) ────────────
log "[3/8] write /root/.secrets/cloudflare.ini on VPS"
ssh_vps "mkdir -p /root/.secrets && chmod 700 /root/.secrets"
printf 'dns_cloudflare_email = %s\ndns_cloudflare_api_key = %s\n' \
  "$CLOUDFLARE_EMAIL" "$CLOUDFLARE_GLOBAL_API_KEY" \
  | ssh_vps 'cat > /root/.secrets/cloudflare.ini && chmod 600 /root/.secrets/cloudflare.ini'

# ── Step 4: cert via DNS-01 (idempotent — certbot's own timer handles renewal) ──
log "[4/8] Let's Encrypt cert for $DOMAIN (DNS-01)"
if ssh_vps "test -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem"; then
  info "cert already present — certbot's systemd timer renews automatically"
else
  ssh_vps "certbot certonly --non-interactive --agree-tos --email '$CLOUDFLARE_EMAIL' \
    --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30 \
    -d '$DOMAIN'"
fi

# ── Step 5: basic auth (password lives in .env.local) ───────────────────────
HTPASSWD=/etc/nginx/htpasswd-vpn-health
log "[5/8] basic-auth user '$AUTH_USER' in $HTPASSWD"

if [[ -z "${VPN_HEALTH_BASIC_AUTH_PASS:-}" ]]; then
  VPN_HEALTH_BASIC_AUTH_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
  echo "VPN_HEALTH_BASIC_AUTH_PASS=$VPN_HEALTH_BASIC_AUTH_PASS" >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  info "generated VPN_HEALTH_BASIC_AUTH_PASS, appended to .env.local"
else
  info "reusing VPN_HEALTH_BASIC_AUTH_PASS from .env.local"
fi

# Always reconcile the htpasswd entry to match the password in .env.local.
# File mode 640 + group www-data so nginx workers can read it (otherwise the
# location 401-checks succeed but content fetch 500s on permission denied).
ssh_vps "test -f $HTPASSWD || install -o root -g www-data -m 640 /dev/null $HTPASSWD
         htpasswd -b $HTPASSWD '$AUTH_USER' '$VPN_HEALTH_BASIC_AUTH_PASS' 2>&1 | sed 's/^/    /'
         chown root:www-data $HTPASSWD
         chmod 640 $HTPASSWD"

# ── Step 6: nginx vhost ─────────────────────────────────────────────────────
log "[6/8] write nginx vhost /etc/nginx/sites-available/vpn-health"
cat <<EOF | ssh_vps 'cat > /etc/nginx/sites-available/vpn-health'
# /etc/nginx/sites-available/vpn-health — managed by setup-status-dashboard.sh
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    # nginx <1.25 needs the legacy 'http2' on the listen line; the standalone
    # 'http2 on;' directive was added in 1.25. Ubuntu 24.04 ships 1.24, so we
    # use the legacy form for compatibility.
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;

    root /var/www/vpn-health;
    index index.html;
    autoindex off;

    location / {
        auth_basic           "vpn-health";
        auth_basic_user_file $HTPASSWD;
        try_files \$uri \$uri/ =404;
    }
}
EOF

ssh_vps 'ln -sf /etc/nginx/sites-available/vpn-health /etc/nginx/sites-enabled/vpn-health
         rm -f /etc/nginx/sites-enabled/default
         nginx -t 2>&1 | sed "s/^/    /"
         systemctl enable nginx --now >/dev/null 2>&1
         systemctl reload nginx'

# ── Step 7: placeholder content ─────────────────────────────────────────────
log "[7/8] /var/www/vpn-health (placeholder until first push)"
ssh_vps "mkdir -p /var/www/vpn-health
         if [[ ! -s /var/www/vpn-health/index.html ]]; then
           cat > /var/www/vpn-health/index.html <<'HTML'
<!doctype html><html><head><title>vpn-health</title></head><body>
<pre>vpn-health dashboard initialized.
Waiting for first push from T15 (every 1 min)...
If you keep seeing this after 2 min, the T15 push key is not authorized on
the VPS yet, or the t15-snapshot.timer hasn't been deployed/enabled.</pre>
</body></html>
HTML
         fi"

# ── Step 8: optional push-key authorization ─────────────────────────────────
log "[8/8] T15 push-key authorization"
if [[ -z "$PUSH_KEY_PUB_FILE" ]]; then
  info "no push-key file given — skip (re-run with the pub-key path as arg 3 later)"
else
  [[ -f "$PUSH_KEY_PUB_FILE" ]] || die "push key file '$PUSH_KEY_PUB_FILE' not found"
  PUSH_KEY=$(< "$PUSH_KEY_PUB_FILE")
  PUSH_KEY_BLOB=$(echo "$PUSH_KEY" | awk '{print $2}')
  if [[ -z "$PUSH_KEY_BLOB" ]]; then
    die "push key file doesn't look like an SSH pubkey: '$PUSH_KEY_PUB_FILE'"
  fi
  if ssh_vps "grep -qF '$PUSH_KEY_BLOB' /root/.ssh/authorized_keys 2>/dev/null"; then
    info "push key already authorized"
  else
    # Forced command: only allows uploading via stdin to the dashboard's index.html.
    AUTH_LINE='command="cat > /var/www/vpn-health/.tmp && mv /var/www/vpn-health/.tmp /var/www/vpn-health/index.html",restrict '"$PUSH_KEY"
    printf '%s\n' "$AUTH_LINE" | ssh_vps 'cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'
    info "push key authorized with restricted forced-command"
  fi
fi

# ── Verification ────────────────────────────────────────────────────────────
log "Verifying https://$DOMAIN/ end-to-end"
# Use --resolve so the test works even if local DNS hasn't propagated yet.
# Curl exits non-zero on 4xx/5xx only with -f; we don't use -f so the body of
# %{http_code} is always populated and there's no need for an echo fallback.
verify() {
  local label="$1" expect="$2"; shift 2
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "$DOMAIN:443:$VPS_IP" "https://$DOMAIN/" "$@" 2>/dev/null)
  [[ -n "$code" ]] || code="connection-failed"
  if [[ "$code" == "$expect" ]]; then
    printf '    ✓ %-18s HTTP %s\n' "$label" "$code"
  else
    printf '    ✗ %-18s HTTP %s  (expected %s)\n' "$label" "$code" "$expect"
  fi
}
verify "unauthenticated"  "401"
verify "with credentials" "200" -u "$AUTH_USER:$VPN_HEALTH_BASIC_AUTH_PASS"

# Separate: did local DNS pick up the new record yet? Informational only —
# certbot used DNS-01, so the cert and the HTTP path don't depend on it.
RESOLVED=$(dig +short "$DOMAIN" @1.1.1.1 2>/dev/null | head -1)
if [[ "$RESOLVED" == "$VPS_IP" ]]; then
  info "DNS: $DOMAIN → $RESOLVED (authoritative)"
else
  info "DNS: authoritative returned '$RESOLVED' (expected $VPS_IP). Propagation may still be in flight."
fi

echo
echo "Dashboard URL:        https://$DOMAIN/"
echo "Basic-auth user:      $AUTH_USER"
echo "Basic-auth password:  (stored in .env.local as VPN_HEALTH_BASIC_AUTH_PASS)"
echo "Done."
