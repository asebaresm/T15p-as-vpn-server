#!/usr/bin/env bash
# Retries Oracle instance launch until capacity is available.
# Runs until the instance is provisioned or manually killed.

set -euo pipefail

TENANCY=ocid1.tenancy.oc1..aaaaaaaa6zl2cnka3fn5nwljzaxpmeeqi56t6ydnxrm4uqa4cryzavkm4sqq
SUBNET_ID=ocid1.subnet.oc1.eu-marseille-1.aaaaaaaa62esde6hjsxspjdbyaz3i7j7gh5p47fvvxmtfz4bhf4jozamsgga
IMAGE_ID=ocid1.image.oc1.eu-marseille-1.aaaaaaaapoz5xinc2hfbcd6hrb22x6hef5dlqevxhsht2xsscynjdi23uonq
SSH_PUB_FILE="$(dirname "$0")/oracle/vps-ssh-key.pub"
OCI="$(dirname "$0")/../../venv/bin/oci"
RETRY_INTERVAL=120  # seconds between attempts

echo "[$(date)] Starting Oracle provisioning loop (retrying every ${RETRY_INTERVAL}s)..."

while true; do
  echo "[$(date)] Attempting to launch VM.Standard.E2.1.Micro in EU-MARSEILLE-1-AD-1..."

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
    echo "[$(date)] SUCCESS! Instance launched:"
    echo "$OUTPUT"

    # Extract instance OCID and wait for public IP
    INSTANCE_ID=$($OCI compute instance list \
      --compartment-id "$TENANCY" \
      --display-name "vpn-relay" \
      --query 'data[0].id' --raw-output 2>/dev/null)

    echo "[$(date)] Waiting for instance to reach RUNNING state..."
    for i in $(seq 1 20); do
      STATE=$($OCI compute instance get --instance-id "$INSTANCE_ID" \
        --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "UNKNOWN")
      echo "[$(date)] State: $STATE"
      [ "$STATE" = "RUNNING" ] && break
      sleep 15
    done

    PUBLIC_IP=$($OCI compute instance list-vnics \
      --instance-id "$INSTANCE_ID" \
      --query 'data[0]."public-ip"' --raw-output 2>/dev/null)

    echo ""
    echo "============================================"
    echo "  VPS provisioned successfully!"
    echo "  Instance OCID : $INSTANCE_ID"
    echo "  Public IP     : $PUBLIC_IP"
    echo "  SSH            : ssh -i oracle/vps-ssh-key ubuntu@$PUBLIC_IP"
    echo "============================================"
    exit 0
  elif echo "$OUTPUT" | grep -q "Out of host capacity"; then
    echo "[$(date)] Out of capacity. Retrying in ${RETRY_INTERVAL}s..."
    sleep "$RETRY_INTERVAL"
  else
    echo "[$(date)] Unexpected response:"
    echo "$OUTPUT"
    echo "Retrying in ${RETRY_INTERVAL}s..."
    sleep "$RETRY_INTERVAL"
  fi
done
