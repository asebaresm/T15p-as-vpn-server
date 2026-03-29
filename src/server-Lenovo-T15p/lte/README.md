# LTE / WWAN Backup — Activation Guide

When you have the SIM card and WWAN modem installed, follow these steps.

## 1. Verify the modem is detected

```bash
mmcli -L          # should list the modem
nmcli device      # should show a wwan0 or similar device
```

## 2. Activate wwan0 in nftables

In `../nftables.conf`, uncomment the two wwan0 lines:
```
iifname ap0 oifname wwan0 accept
oifname wwan0 masquerade
```
Then reload: `sudo nft -f /etc/nftables.conf`

## 3. Activate wwan0 in sysctl

In `../sysctl-router.conf`, uncomment:
```
net.ipv4.conf.wwan0.rp_filter = 2
```
Then reload: `sudo sysctl --system`

## 4. Set connection priorities in NetworkManager

```bash
# Building WiFi stays primary
nmcli connection modify "$(nmcli -g NAME,DEVICE connection show --active | grep wlp0s20f3 | cut -d: -f1)" \
  connection.autoconnect-priority 100

# LTE is backup
nmcli connection modify "$(mmcli -L | awk '{print $1}' | head -1)" \
  connection.autoconnect-priority 10
```

## 5. Configure the APN

```bash
# Replace APN with your carrier's value
nmcli connection modify <lte-connection-name> \
  gsm.apn "internet"
```

NetworkManager + ModemManager will handle automatic failover once priorities are set.
