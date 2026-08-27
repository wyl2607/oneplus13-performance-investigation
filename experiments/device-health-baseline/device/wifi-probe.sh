#!/system/bin/sh
set -eu

kv() { printf '%s=%s\n' "$1" "$2"; }

kv wifi_enabled "$(settings get global wifi_on 2>/dev/null || printf 'UNKNOWN')"
kv wlan_operstate "$(cat /sys/class/net/wlan0/operstate 2>/dev/null || printf 'UNKNOWN')"
kv wlan_rx_bytes "$(cat /sys/class/net/wlan0/statistics/rx_bytes 2>/dev/null || printf 'UNKNOWN')"
kv wlan_tx_bytes "$(cat /sys/class/net/wlan0/statistics/tx_bytes 2>/dev/null || printf 'UNKNOWN')"

STATUS="$(cmd wifi status 2>/dev/null || true)"
RSSI="$(printf '%s\n' "$STATUS" | grep -Eo 'RSSI: -?[0-9]+' | head -n1 | grep -Eo -- '-?[0-9]+' || true)"
LINK="$(printf '%s\n' "$STATUS" | grep -Eo 'Link speed: [0-9]+' | head -n1 | grep -Eo '[0-9]+' || true)"
TXLINK="$(printf '%s\n' "$STATUS" | grep -Eo 'Tx Link speed: [0-9]+' | head -n1 | grep -Eo '[0-9]+' || true)"
RXLINK="$(printf '%s\n' "$STATUS" | grep -Eo 'Rx Link speed: [0-9]+' | head -n1 | grep -Eo '[0-9]+' || true)"
FREQ="$(printf '%s\n' "$STATUS" | grep -Eo 'Frequency: [0-9]+' | head -n1 | grep -Eo '[0-9]+' || true)"

kv wifi_rssi_dbm "${RSSI:-UNKNOWN}"
kv wifi_link_mbps "${LINK:-UNKNOWN}"
kv wifi_tx_link_mbps "${TXLINK:-UNKNOWN}"
kv wifi_rx_link_mbps "${RXLINK:-UNKNOWN}"
kv wifi_frequency_mhz "${FREQ:-UNKNOWN}"

PING="$(ping -c 20 -W 2 1.1.1.1 2>/dev/null || true)"
LOSS="$(printf '%s\n' "$PING" | grep -Eo '[0-9]+% packet loss' | head -n1 | grep -Eo '[0-9]+' || true)"
RTT="$(printf '%s\n' "$PING" | awk -F'=' '/min\/avg\/max/ {gsub(/ ms/,"",$2); gsub(/^ /,"",$2); print $2}' | head -n1)"
kv ping_target "1.1.1.1"
kv ping_loss_pct "${LOSS:-UNKNOWN}"
kv ping_min_avg_max_ms "${RTT:-UNKNOWN}"
kv privacy "no_ssid_bssid_ip_or_mac_emitted"
