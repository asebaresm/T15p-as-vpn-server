#!/usr/bin/env bash
# Provisions a VPS and configures it as a WireGuard relay.
# Reads VPS_PROVIDER from .env.local to select the provider.
#
# Usage:
#   bash ops/server-VPS/provision-vps.sh              — provision + configure
#   bash ops/server-VPS/provision-vps.sh provision     — provision only (create VM)
#   bash ops/server-VPS/provision-vps.sh configure     — configure only (WireGuard + firewall)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

# Load .env.local
ENV_FILE="$ROOT/.env.local"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.local.example and fill in."
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

PROVIDER="${VPS_PROVIDER:-}"
ACTION="${1:-all}"

if [[ -z "$PROVIDER" ]]; then
  echo "ERROR: VPS_PROVIDER not set in .env.local (ORACLE or HETZNER)"
  exit 1
fi

# Substitutes all {{VAR}} placeholders in a template file
render_template() {
  local src="$1"
  sed -e "s|{{VPS_SERVER_PUBLIC_IP}}|$VPS_SERVER_PUBLIC_IP|g" \
      -e "s|{{VPS_PRIVATE_KEY}}|$VPS_PRIVATE_KEY|g" \
      -e "s|{{VPS_PUBLIC_KEY}}|$VPS_PUBLIC_KEY|g" \
      -e "s|{{T15P_PRIVATE_KEY}}|$T15P_PRIVATE_KEY|g" \
      -e "s|{{T15P_PUBLIC_KEY}}|$T15P_PUBLIC_KEY|g" \
      -e "s|{{MACBOOK_PRIVATE_KEY}}|$MACBOOK_PRIVATE_KEY|g" \
      -e "s|{{MACBOOK_PUBLIC_KEY}}|$MACBOOK_PUBLIC_KEY|g" \
      "$src"
}

# Update .env.local: set the active VPS_* variables from the provider-specific ones
activate_provider() {
  local ip_var="${PROVIDER}_VPS_SERVER_PUBLIC_IP"
  local priv_var="${PROVIDER}_VPS_PRIVATE_KEY"
  local pub_var="${PROVIDER}_VPS_PUBLIC_KEY"

  export VPS_SERVER_PUBLIC_IP="${!ip_var}"
  export VPS_PRIVATE_KEY="${!priv_var}"
  export VPS_PUBLIC_KEY="${!pub_var}"

  # Write active values back to .env.local
  sed -i \
    -e "s|^VPS_SERVER_PUBLIC_IP=.*|VPS_SERVER_PUBLIC_IP=$VPS_SERVER_PUBLIC_IP|" \
    -e "s|^VPS_PRIVATE_KEY=.*|VPS_PRIVATE_KEY=$VPS_PRIVATE_KEY|" \
    -e "s|^VPS_PUBLIC_KEY=.*|VPS_PUBLIC_KEY=$VPS_PUBLIC_KEY|" \
    "$ENV_FILE"

  echo "  Active VPS set to $PROVIDER ($VPS_SERVER_PUBLIC_IP)"
}

# ── ORACLE PROVISIONING ──────────────────────────────────────────────────────
provision_oracle() {
  echo "==> Provisioning Oracle VPS..."

  local TENANCY="${ORACLE_TENANCY_OCID:?Set ORACLE_TENANCY_OCID in .env.local}"
  local SUBNET_ID="${ORACLE_SUBNET_OCID:?Set ORACLE_SUBNET_OCID in .env.local}"
  local IMAGE_ID="${ORACLE_IMAGE_OCID:?Set ORACLE_IMAGE_OCID in .env.local}"
  local SSH_PUB_FILE="$SCRIPT_DIR/oracle/vps-ssh-key.pub"
  local OCI="$ROOT/venv/bin/oci"

  while true; do
    echo "[$(date)] Attempting to launch VM.Standard.E2.1.Micro..."

    OUTPUT=$($OCI compute instance launch \
      --compartment-id "$TENANCY" \
      --availability-domain "ACUB:EU-MARSEILLE-1-AD-1" \
      --display-name "vpn-relay" \
      --image-id "$IMAGE_ID" \
      --shape "VM.Standard.E2.1.Micro" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip true \
      --ssh-authorized-keys-file "$SSH_PUB_FILE" \
      --query 'data.{id:id, state:"lifecycle-state"}' \
      --output table 2>&1 || true)

    if echo "$OUTPUT" | grep -q "PROVISIONING\|RUNNING"; then
      echo "$OUTPUT"
      INSTANCE_ID=$($OCI compute instance list \
        --compartment-id "$TENANCY" --display-name "vpn-relay" \
        --query 'data[0].id' --raw-output 2>/dev/null)

      echo "Waiting for RUNNING state..."
      for i in $(seq 1 20); do
        STATE=$($OCI compute instance get --instance-id "$INSTANCE_ID" \
          --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "UNKNOWN")
        echo "  State: $STATE"
        [[ "$STATE" == "RUNNING" ]] && break
        sleep 15
      done

      PUBLIC_IP=$($OCI compute instance list-vnics \
        --instance-id "$INSTANCE_ID" \
        --query 'data[0]."public-ip"' --raw-output 2>/dev/null)

      # Save IP to .env.local
      sed -i "s|^ORACLE_VPS_SERVER_PUBLIC_IP=.*|ORACLE_VPS_SERVER_PUBLIC_IP=$PUBLIC_IP|" "$ENV_FILE"
      export ORACLE_VPS_SERVER_PUBLIC_IP="$PUBLIC_IP"

      SSH_KEY="$SCRIPT_DIR/oracle/vps-ssh-key"
      SSH_USER="ubuntu"
      echo "  Oracle VPS: $PUBLIC_IP"
      return 0
    elif echo "$OUTPUT" | grep -q "Out of host capacity"; then
      echo "  Out of capacity. Retrying in 120s..."
      sleep 120
    else
      echo "  Unexpected: $OUTPUT"
      sleep 120
    fi
  done
}

# ── HETZNER PROVISIONING ─────────────────────────────────────────────────────
provision_hetzner() {
  echo "==> Provisioning Hetzner VPS..."

  if [[ -z "${HETZNER_API_KEY:-}" ]]; then
    echo "ERROR: HETZNER_API_KEY not set in .env.local"
    exit 1
  fi

  # Generate SSH key for Hetzner if it doesn't exist
  local SSH_KEY_DIR="$SCRIPT_DIR/hetzner"
  mkdir -p "$SSH_KEY_DIR"
  if [[ ! -f "$SSH_KEY_DIR/vps-ssh-key" ]]; then
    echo "  Generating SSH key..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_DIR/vps-ssh-key" -N "" -q
  fi

  local SSH_PUB
  SSH_PUB=$(cat "$SSH_KEY_DIR/vps-ssh-key.pub")

  # Upload SSH key to Hetzner
  echo "  Uploading SSH key..."
  local KEY_RESPONSE
  KEY_RESPONSE=$(curl -s -X POST "https://api.hetzner.cloud/v1/ssh_keys" \
    -H "Authorization: Bearer $HETZNER_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"vpn-relay\", \"public_key\": \"$SSH_PUB\"}" 2>&1)

  local SSH_KEY_ID
  SSH_KEY_ID=$(echo "$KEY_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ssh_key',{}).get('id',''))" 2>/dev/null || true)

  # If key already exists, find its ID
  if [[ -z "$SSH_KEY_ID" ]]; then
    SSH_KEY_ID=$(curl -s "https://api.hetzner.cloud/v1/ssh_keys" \
      -H "Authorization: Bearer $HETZNER_API_KEY" | \
      python3 -c "import sys,json; keys=json.load(sys.stdin)['ssh_keys']; print(next((k['id'] for k in keys if k['name']=='vpn-relay'),''))" 2>/dev/null || true)
  fi

  if [[ -z "$SSH_KEY_ID" ]]; then
    echo "ERROR: Failed to upload/find SSH key"
    echo "$KEY_RESPONSE"
    exit 1
  fi
  echo "  SSH key ID: $SSH_KEY_ID"

  # Create server (CX23, Falkenstein, Ubuntu 24.04)
  echo "  Creating CX23 instance in Nuremberg..."
  local SERVER_RESPONSE
  SERVER_RESPONSE=$(curl -s -X POST "https://api.hetzner.cloud/v1/servers" \
    -H "Authorization: Bearer $HETZNER_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"vpn-relay\",
      \"server_type\": \"cx23\",
      \"image\": \"ubuntu-24.04\",
      \"location\": \"nbg1\",
      \"ssh_keys\": [$SSH_KEY_ID],
      \"public_net\": {\"enable_ipv4\": true, \"enable_ipv6\": true}
    }" 2>&1)

  local SERVER_ID PUBLIC_IP
  SERVER_ID=$(echo "$SERVER_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('server',{}).get('id',''))" 2>/dev/null || true)
  PUBLIC_IP=$(echo "$SERVER_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('server',{}).get('public_net',{}).get('ipv4',{}).get('ip',''))" 2>/dev/null || true)

  if [[ -z "$SERVER_ID" || -z "$PUBLIC_IP" ]]; then
    echo "ERROR: Failed to create server"
    echo "$SERVER_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$SERVER_RESPONSE"
    exit 1
  fi

  echo "  Server ID: $SERVER_ID"
  echo "  Public IP: $PUBLIC_IP"

  # Save IP to .env.local
  sed -i "s|^HETZNER_VPS_SERVER_PUBLIC_IP=.*|HETZNER_VPS_SERVER_PUBLIC_IP=$PUBLIC_IP|" "$ENV_FILE"
  export HETZNER_VPS_SERVER_PUBLIC_IP="$PUBLIC_IP"

  # Wait for server to be reachable
  echo "  Waiting for SSH to become available..."
  for i in $(seq 1 30); do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -i "$SSH_KEY_DIR/vps-ssh-key" "root@$PUBLIC_IP" 'echo ok' &>/dev/null; then
      echo "  SSH reachable."
      break
    fi
    sleep 5
  done

  SSH_KEY="$SSH_KEY_DIR/vps-ssh-key"
  SSH_USER="root"
  echo "  Hetzner VPS: $PUBLIC_IP"
}

# ── CONFIGURE VPS (provider-independent) ──────────────────────────────────────
configure_vps() {
  echo "==> Configuring VPS as WireGuard relay..."

  # Determine SSH details from provider
  if [[ "$PROVIDER" == "ORACLE" ]]; then
    SSH_KEY="$SCRIPT_DIR/oracle/vps-ssh-key"
    SSH_USER="ubuntu"
    local IP="$ORACLE_VPS_SERVER_PUBLIC_IP"
  elif [[ "$PROVIDER" == "HETZNER" ]]; then
    SSH_KEY="$SCRIPT_DIR/hetzner/vps-ssh-key"
    SSH_USER="root"
    local IP="$HETZNER_VPS_SERVER_PUBLIC_IP"
  fi

  local SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY $SSH_USER@$IP"
  local SUDO=""
  [[ "$SSH_USER" != "root" ]] && SUDO="sudo"

  # Activate this provider's keys/IP as the active VPS
  activate_provider

  echo "  [1/4] Installing WireGuard..."
  $SSH_CMD "$SUDO apt-get update -qq && $SUDO apt-get install -y wireguard nftables" 2>/dev/null

  echo "  [2/4] Deploying WireGuard config..."
  render_template "$ROOT/src/server-VPS/wg0.conf" | \
    $SSH_CMD "$SUDO tee /etc/wireguard/wg0.conf > /dev/null && $SUDO chmod 600 /etc/wireguard/wg0.conf"

  echo "  [3/4] Enabling WireGuard..."
  $SSH_CMD "$SUDO systemctl enable --now wg-quick@wg0" 2>/dev/null

  echo "  [4/4] Configuring firewall..."
  if [[ "$PROVIDER" == "ORACLE" ]]; then
    # Oracle has a default nftables ruleset with REJECT rules — insert before them
    $SSH_CMD "$SUDO bash -c '
      nft insert rule ip filter INPUT index 4 udp dport 51820 counter accept 2>/dev/null || true
      nft insert rule ip filter FORWARD index 0 oifname \"wg0\" counter accept 2>/dev/null || true
      nft insert rule ip filter FORWARD index 0 iifname \"wg0\" counter accept 2>/dev/null || true
      nft list ruleset > /etc/nftables.conf
      systemctl enable nftables
    '"
  elif [[ "$PROVIDER" == "HETZNER" ]]; then
    # Hetzner has no default firewall rules — just enable IP forwarding
    $SSH_CMD "$SUDO bash -c '
      echo net.ipv4.ip_forward=1 > /etc/sysctl.d/99-wireguard.conf
      sysctl -w net.ipv4.ip_forward=1
    '"
  fi

  echo ""
  echo "============================================"
  echo "  VPS configured ($PROVIDER)"
  echo "  Public IP : $VPS_SERVER_PUBLIC_IP"
  echo "  WireGuard : 10.100.0.1/24, UDP 51820"
  echo "  SSH       : ssh -i $SSH_KEY $SSH_USER@$VPS_SERVER_PUBLIC_IP"
  echo ""
  echo "  Next: re-run install.sh on the T15p to update the endpoint"
  echo "    sudo bash ops/server-Lenovo-T15p/install.sh"
  echo "============================================"
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
echo "Provider: $PROVIDER"

if [[ "$ACTION" == "all" || "$ACTION" == "provision" ]]; then
  if [[ "$PROVIDER" == "ORACLE" ]]; then
    provision_oracle
  elif [[ "$PROVIDER" == "HETZNER" ]]; then
    provision_hetzner
  else
    echo "ERROR: Unknown provider '$PROVIDER'. Use ORACLE or HETZNER."
    exit 1
  fi
fi

if [[ "$ACTION" == "all" || "$ACTION" == "configure" ]]; then
  configure_vps
fi
