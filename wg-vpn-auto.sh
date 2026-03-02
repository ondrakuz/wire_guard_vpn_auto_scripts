#!/bin/bash

# ProtonVPN Auto Orchestrator
# Deterministic version with scoring engine, hysteresis and cooldown
# Compatible with NetworkManager runtime (/run) and persistent (/etc) storage

LOG_FILE="/tmp/nm-dispatch.log"

log() {
    echo "[$(date +%y-%m-%d-%H:%M:%S)] $1" >> "$LOG_FILE"
    echo "$1"
}

# ------------------------------------------------------------
# Detect NetworkManager storage directory
# ------------------------------------------------------------

detect_nm_storage() {

    if [ -d "/run/NetworkManager/system-connections" ] && \
       [ "$(ls -A /run/NetworkManager/system-connections 2>/dev/null)" ]; then
        echo "/run/NetworkManager/system-connections"
        return
    fi

    if [ -d "/etc/NetworkManager/system-connections" ] && \
       [ "$(ls -A /etc/NetworkManager/system-connections 2>/dev/null)" ]; then
        echo "/etc/NetworkManager/system-connections"
        return
    fi

    echo ""
}

NM_STORAGE=$(detect_nm_storage)

if [ -z "$NM_STORAGE" ]; then
    log "No NetworkManager system connection storage found."
    exit 1
fi

log "Using NM storage: $NM_STORAGE"

# ------------------------------------------------------------
# Default configuration (override in /etc/wg-vpn-auto.conf)
# ------------------------------------------------------------

PREFERRED_COUNTRIES=nl,de

# Maximum allowed latency in ms
MAX_LATENCY_MS=80

# Blacklisted countries
BLACKLIST=jp

# Monitor interval (seconds)
CHECK_INTERVAL=30

# Switching policy
MIN_SCORE_IMPROVEMENT=15
SWITCH_COOLDOWN=180

# Threshold safety caps
MAX_LATENCY_MS=250
MAX_PACKET_LOSS=40

# Weights
W_LAT=1
W_LOSS=5
W_STALE=1


# --------------------------------------------------------------------
# Resolve config path deterministically and read it
# --------------------------------------------------------------------

ACTIVE_USER=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | head -n1)
USER_HOME=$(getent passwd "$ACTIVE_USER" 2>/dev/null | cut -d: -f6)

if [ -n "$USER_HOME" ]; then
    CONFIG="$USER_HOME/.config/wg-vpn-auto.conf"
else
    CONFIG="/etc/wg-vpn-auto.conf"
fi

if [ -f "$CONFIG" ]
then
  . "$CONFIG"
  log "Using config: $CONFIG"
fi

# ------------------------------------------------------------
# Utility: find config file by connection ID
# ------------------------------------------------------------

find_conf_file() {
    local name="$1"
    grep -l "^\s*id\s*=\s*${name}\s*$" \
        "$NM_STORAGE"/*.nmconnection 2>/dev/null | head -n1
}

# ------------------------------------------------------------
# Utility: extract endpoint IP
# ------------------------------------------------------------

extract_endpoint() {

    local conf="$1"

    awk -F= '
        /^\[wireguard-peer/ {inpeer=1; next}
        /^\[/ {inpeer=0}
        inpeer && $1 ~ /^[[:space:]]*endpoint[[:space:]]*$/ {
            gsub(/^[ \t]+|[ \t]+$/, "", $2)
            split($2,a,":")
            print a[1]
            exit
        }
    ' "$conf"
}

# ------------------------------------------------------------
# Score calculation
# ------------------------------------------------------------

calculate_score() {

    local endpoint="$1"

    ping_out=$(ping -c4 -W1 "$endpoint" 2>/dev/null)

    loss=$(echo "$ping_out" | awk -F',' '/packet loss/ {print int($3)}')
    avg=$(echo "$ping_out" | awk -F'/' '/rtt/ {print int($5)}')

    [ -z "$loss" ] && loss=100
    [ -z "$avg" ] && avg=9999

    hs_age=$(wg show 2>/dev/null | awk '/latest handshake/ {print $(NF-1)}' | head -n1)
    [ -z "$hs_age" ] && hs_age=999

    score=$(( avg * W_LAT + loss * W_LOSS + hs_age * W_STALE ))

    echo "$score"
}

# ------------------------------------------------------------
# Evaluate all WireGuard connections
# ------------------------------------------------------------

evaluate_all_servers() {

    best_score=999999
    best_conn=""

    CONNECTION_LIST=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null)

    while IFS=: read -r NAME TYPE; do

        [ "$TYPE" != "wireguard" ] && continue
        [ "$NAME" = "$ACTIVE_CONN" ] && continue
        
        log "Evaluating connection $NAME"

        CONF_FILE=$(find_conf_file "$NAME")
        [ -z "$CONF_FILE" ] && continue

        endpoint=$(extract_endpoint "$CONF_FILE")
        [ -z "$endpoint" ] && continue

        score=$(calculate_score "$endpoint")
        log "Connection $NAME evaluated: $score"

        if [ "$score" -lt "$best_score" ]; then
            best_score="$score"
            best_conn="$NAME"
        fi

    done <<< "$CONNECTION_LIST"
    
    log "Best connection evaluated: $best_conn, score: $best_score."

}

# ------------------------------------------------------------
# Initial selection
# ------------------------------------------------------------

initial_select() {

    ACTIVE_CONN=$(cat /run/wg-vpn-auto.active 2>/dev/null)

    evaluate_all_servers

    if [ -n "$best_conn" ]; then
        log "Initial connect to $best_conn"
        nmcli connection up "$best_conn"
        echo "$best_conn" > /run/wg-vpn-auto.active
        date +%s > /run/wg-vpn-auto.lastswitch
    else
        log "No suitable ProtonVPN server found."
    fi
}

# ------------------------------------------------------------
# Monitor loop
# ------------------------------------------------------------

monitor_loop() {

    while true; do

        ACTIVE_CONN=$(cat /run/wg-vpn-auto.active 2>/dev/null)
        [ -z "$ACTIVE_CONN" ] && continue

        CONF_FILE=$(find_conf_file "$ACTIVE_CONN")
        [ -z "$CONF_FILE" ] && continue

        endpoint=$(extract_endpoint "$CONF_FILE")
        [ -z "$endpoint" ] && continue

        current_score=$(calculate_score "$endpoint")

        now=$(date +%s)
        last=0
        [ -f /run/wg-vpn-auto.lastswitch ] && last=$(cat /run/wg-vpn-auto.lastswitch)

        evaluate_all_servers
        [ -z "$best_conn" ] && continue

        improvement=$(( current_score - best_score ))

        if [ "$improvement" -gt "$MIN_SCORE_IMPROVEMENT" ] && \
           [ $((now - last)) -gt "$SWITCH_COOLDOWN" ]; then

            log "Switching $ACTIVE_CONN -> $best_conn (improvement $improvement)"

            nmcli connection up "$best_conn"
            nmcli connection down "$ACTIVE_CONN"

            echo "$best_conn" > /run/wg-vpn-auto.active
            echo "$now" > /run/wg-vpn-auto.lastswitch
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# ------------------------------------------------------------
# Entry
# ------------------------------------------------------------

if [ "$1" = "--daemon" ]; then
    log "Starting monitor daemon"
    initial_select
    monitor_loop
    exit 0
fi

initial_select
