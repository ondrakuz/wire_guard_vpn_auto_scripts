#!/usr/bin/env bash

# Proton VPN Auto WireGuard trigger

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
        # Run auto selection script
        systemctl restart --no-block wg-vpn-auto.service
        result="$?"
        
        log "AUTO SCRIPT TRIGGERED"
        log "RESULT: $result"
    fi

    if [[ "$2" == "down" ]]; then
        if [[ -f /run/wg-vpn-auto.active ]]; then
            systemctl stop wg-vpn-auto
            ACTIVE_CONN=$(cat /run/wg-vpn-auto.active)
            nmcli connection down "$ACTIVE_CONN"
            rm -f /run/wg-vpn-auto.active
        fi
    fi

fi
