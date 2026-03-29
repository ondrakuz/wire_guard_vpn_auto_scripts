#!/usr/bin/env bash

# WireGuard VPN Auto trigger

LOG_FILE="/tmp/nm-dispatch.log"

log() {
  echo "[$(date +%y-%m-%d-%H:%M:%S)] $1" >> "$LOG_FILE"
  echo "$1"
}

log "CONNECTION_ID='$CONNECTION_ID' ACTION='$2'"

# --------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------

log "Dispatcher running as: $(whoami)"

if [[ "$1" == "wg-auto" ]]; then

    if [[ "$2" == "up" ]]; then
        mkdir -p /var/lib/wg-vpn-auto
        touch /var/lib/wg-vpn-auto/enabled

        systemctl restart --no-block wg-vpn-auto.service
        result="$?"

        log "AUTO SCRIPT TRIGGERED"
        log "RESULT: $result"
    fi

    if [[ "$2" == "down" ]]; then
        rm -f /var/lib/wg-vpn-auto/enabled
        systemctl stop wg-vpn-auto
        log "AUTO SCRIPT STOPPED"
    fi

fi
