#!/usr/bin/env bash

CONFIG_DIR="/root/backhaul-core"
CHECK_INTERVAL=5
COOLDOWN=30

STATE_DIR="/tmp/backhaul-state"
mkdir -p "$STATE_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

get_profile() {
    awk -F'"' '/^[[:space:]]*profile[[:space:]]*=/{print $2; exit}'
}

switch_profile() {
    local SERVICE="$1"
    local TOML="$2"

    CURRENT=$(get_profile < "$TOML")

    case "$CURRENT" in
        tcp) NEW="bip" ;;
        bip) NEW="tcp" ;;
        *) return 1 ;;
    esac

    sed -i "s/^[[:space:]]*profile[[:space:]]*=.*/profile = \"$NEW\"/" "$TOML"
    log "[$SERVICE] Profile switched $CURRENT → $NEW"
}

while true; do
    SERVICES=$(systemctl list-units --type=service --no-legend \
        | awk '{print $1}' | grep '^backhaul-' | grep -v watchdog)

    for FULL in $SERVICES; do
        SERVICE="${FULL%.service}"
        NAME="${SERVICE#backhaul-}"
        TOML="${CONFIG_DIR}/${NAME}.toml"

        [[ ! -f "$TOML" ]] && continue

        NOW=$(date +%s)
        LAST_ACTION_FILE="$STATE_DIR/$SERVICE.last"

        NEED_ACTION=0

        # 1. systemd state
        if ! systemctl is-active --quiet "$SERVICE"; then
            NEED_ACTION=1
            REASON="service inactive"
        fi

        # 2. error logs (last 20)
        if journalctl -u "$SERVICE" -n 20 -o cat 2>/dev/null | \
           grep -Eqi "heartbeat.*timeout|disconnected|invalid packet|connection lost"; then
            NEED_ACTION=1
            REASON="error log detected"
        fi

        # 3. cooldown
        if [[ -f "$LAST_ACTION_FILE" ]]; then
            LAST=$(cat "$LAST_ACTION_FILE")
            (( NOW - LAST < COOLDOWN )) && NEED_ACTION=0
        fi

        # 4. action
        if [[ "$NEED_ACTION" -eq 1 ]]; then
            log "[$SERVICE] Action triggered ($REASON)"
            switch_profile "$SERVICE" "$TOML" || continue
            systemctl restart "$SERVICE"
            echo "$NOW" > "$LAST_ACTION_FILE"
        fi
    done

    sleep "$CHECK_INTERVAL"
done
