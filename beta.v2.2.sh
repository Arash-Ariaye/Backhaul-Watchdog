#!/usr/bin/env bash

CONFIG_DIR="/root/backhaul-core"
COOLDOWN=30
CHECK_INTERVAL=5

LOCK_DIR="/tmp/backhaul-locks"
STATE_DIR="/tmp/backhaul-state"

mkdir -p "$LOCK_DIR" "$STATE_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

monitor_service() {
    local FULL_SERVICE="$1"
    local SERVICE="${FULL_SERVICE%.service}"
    local NAME="${SERVICE#backhaul-}"
    local TOML_FILE="${CONFIG_DIR}/${NAME}.toml"

    local LOCK_FILE="${LOCK_DIR}/${SERVICE}.lock"
    local LAST_ACTION_FILE="${STATE_DIR}/${SERVICE}.last_action"
    local LAST_CURSOR_FILE="${STATE_DIR}/${SERVICE}.cursor"

    [[ ! -f "$TOML_FILE" ]] && return

    log "[$SERVICE] Monitoring started"

    while true; do
        NOW=$(date +%s)

        #################################
        # 1. systemd state check
        #################################
        if ! systemctl is-active --quiet "$SERVICE"; then
            log "[$SERVICE] Service inactive → action"
            NEED_ACTION=1
        else
            NEED_ACTION=0
        fi

        #################################
        # 2. check NEW error logs only
        #################################
        if [[ -f "$LAST_CURSOR_FILE" ]]; then
            CURSOR=$(cat "$LAST_CURSOR_FILE")
            LOGS=$(journalctl -u "$SERVICE" --after-cursor "$CURSOR" -o cat 2>/dev/null)
        else
            LOGS=$(journalctl -u "$SERVICE" -n 50 -o cat 2>/dev/null)
        fi

        journalctl -u "$SERVICE" -n 1 --show-cursor 2>/dev/null | \
        sed -n 's/^-- cursor: //p' > "$LAST_CURSOR_FILE"

        if echo "$LOGS" | grep -Eqi \
            "heartbeat.*timeout|disconnected|invalid packet|connection lost"; then
            log "[$SERVICE] Error log detected"
            NEED_ACTION=1
        fi

        #################################
        # 3. cooldown
        #################################
        if [[ "$NEED_ACTION" -eq 1 ]]; then
            if [[ -f "$LAST_ACTION_FILE" ]]; then
                LAST=$(cat "$LAST_ACTION_FILE")
                (( NOW - LAST < COOLDOWN )) && NEED_ACTION=0
            fi
        fi

        #################################
        # 4. perform action
        #################################
        if [[ "$NEED_ACTION" -eq 1 ]]; then
            [[ -f "$LOCK_FILE" ]] && sleep "$CHECK_INTERVAL" && continue
            touch "$LOCK_FILE"

            CURRENT_PROFILE=$(awk -F'"' '/^[[:space:]]*profile[[:space:]]*=/{print $2; exit}' "$TOML_FILE")

            case "$CURRENT_PROFILE" in
                tcp) NEW_PROFILE="bip" ;;
                bip) NEW_PROFILE="tcp" ;;
                *) rm -f "$LOCK_FILE"; sleep "$CHECK_INTERVAL"; continue ;;
            esac

            log "[$SERVICE] Switching profile $CURRENT_PROFILE → $NEW_PROFILE"

            sed -i "s/^[[:space:]]*profile[[:space:]]*=.*/profile = \"$NEW_PROFILE\"/" "$TOML_FILE"

            systemctl restart "$SERVICE" && \
            log "[$SERVICE] Restarted successfully"

            echo "$NOW" > "$LAST_ACTION_FILE"
            rm -f "$LOCK_FILE"
        fi

        sleep "$CHECK_INTERVAL"
    done
}

#####################################
# main
#####################################
while true; do
    SERVICES=$(systemctl list-units --type=service --no-legend \
        | awk '{print $1}' | grep '^backhaul-' | grep -v watchdog)

    for S in $SERVICES; do
        if ! pgrep -f "monitor_service $S" >/dev/null; then
            monitor_service "$S" &
            log "Started monitor for $S"
        fi
    done

    sleep 10
done
