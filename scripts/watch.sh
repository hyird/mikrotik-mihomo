#!/bin/bash
set -uo pipefail

CLASH_CONFIG_DIR="${CLASH_CONFIG_DIR:-/etc/config/clash}"
CHECK_INTERVAL="${SLEEPTIME:-30}"
CLASH_WEB_PORT="${CLASH_WEB_PORT:-80}"
CLASH_WEB_PASSWORD="${CLASH_WEB_PASSWORD:-clashpass}"

api_version_ok() {
    curl -s -H "Authorization: Bearer $CLASH_WEB_PASSWORD" "http://127.0.0.1:$CLASH_WEB_PORT/api/version" >/dev/null 2>&1
}

reload_clash() {
    echo "[$(date '+%H:%M:%S')] Reloading Clash configuration..."
    curl -s -X PUT -H "Authorization: Bearer $CLASH_WEB_PASSWORD" "http://127.0.0.1:$CLASH_WEB_PORT/api/configs" -d '{}' >/dev/null 2>&1 || return 1
    return 0
}

start_clash_only() {
    local config_file="$CLASH_CONFIG_DIR/clash.yaml"
    if [ ! -f "$config_file" ] && [ -f "$CLASH_CONFIG_DIR/config.yaml" ]; then
        config_file="$CLASH_CONFIG_DIR/config.yaml"
    fi

    if [ ! -f "$config_file" ]; then
        echo "[$(date '+%H:%M:%S')] No clash config found, skip restart"
        return 1
    fi

    pkill -f "clash" 2>/dev/null || true
    sleep 2
    clash -d "$CLASH_CONFIG_DIR" -f "$config_file" &

    local i=0
    while [ "$i" -lt 15 ]; do
        if api_version_ok; then
            echo "[$(date '+%H:%M:%S')] Clash restarted"
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done

    echo "[$(date '+%H:%M:%S')] Clash restart failed"
    return 1
}

periodic_monitor() {
    local reload_interval=$((CHECK_INTERVAL * 6))
    local elapsed=0

    echo "[$(date '+%H:%M:%S')] Monitor started (check=${CHECK_INTERVAL}s, reload=${reload_interval}s)"

    while true; do
        sleep "$CHECK_INTERVAL"
        elapsed=$((elapsed + CHECK_INTERVAL))

        if ! api_version_ok; then
            echo "[$(date '+%H:%M:%S')] Clash unhealthy, restarting..."
            start_clash_only || true
            elapsed=0
            continue
        fi

        if [ "$elapsed" -ge "$reload_interval" ]; then
            if ! reload_clash; then
                echo "[$(date '+%H:%M:%S')] Reload failed, restarting Clash..."
                start_clash_only || true
            fi
            elapsed=0
        fi
    done
}

trap 'echo "Monitor exiting"; exit 0' SIGTERM SIGINT
periodic_monitor
