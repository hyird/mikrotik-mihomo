#!/bin/bash
set -euo pipefail

log() {
    local level=$1
    shift
    case "$level" in
        info) echo "[$(date +'%H:%M:%S')] [INFO] $*" >&2 ;;
        warn) echo "[$(date +'%H:%M:%S')] [WARN] $*" >&2 ;;
        error) echo "[$(date +'%H:%M:%S')] [ERROR] $*" >&2 ;;
        *) echo "[$(date +'%H:%M:%S')] [LOG] $*" >&2 ;;
    esac
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

init_system() {
    log info "Initializing system configuration..."

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
    sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null
    echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true

    log info "System configuration completed"
}

load_config() {
    export FAKE_CIDR="${FAKE_CIDR:-198.18.0.0/16}"
    export TPROXY_PORT="${TPROXY_PORT:-1082}"
    export CLASH_WEB_PORT="${CLASH_WEB_PORT:-80}"
    export CLASH_WEB_PASSWORD="${CLASH_WEB_PASSWORD:-clashpass}"
    export SLEEPTIME="${SLEEPTIME:-30}"
    export SUBURL="${SUBURL:-}"
    export BLOCK_QUIC="${BLOCK_QUIC:-true}"

    log info "Configuration loaded"
    log info "FakeIP CIDR: $FAKE_CIDR"
    log info "TProxy Port: $TPROXY_PORT"
    log info "Clash Web Port: $CLASH_WEB_PORT"
    log info "Block QUIC: $BLOCK_QUIC"
    log info "Update Interval: $SLEEPTIME seconds"
}

generate_clash_config() {
    local clash_config_dir="${CLASH_CONFIG_DIR:-/etc/config/clash}"
    local base_yaml="$clash_config_dir/base.yaml"
    local output_yaml="$clash_config_dir/clash.yaml"
    local fallback_yaml="$clash_config_dir/config.yaml"

    if [ -f "$base_yaml" ]; then
        log info "Generating Clash configuration from base.yaml"
        cp "$base_yaml" "$output_yaml"
        sed -i "s|{fake_cidr}|$FAKE_CIDR|g" "$output_yaml"
        sed -i "s|{tproxy_port}|$TPROXY_PORT|g" "$output_yaml"
        sed -i "s|{clash_web_port}|$CLASH_WEB_PORT|g" "$output_yaml"
        local escaped_secret
        escaped_secret="$(escape_sed_replacement "$CLASH_WEB_PASSWORD")"
        sed -i "s|{clash_web_password}|$escaped_secret|g" "$output_yaml"

        if [ -n "$SUBURL" ]; then
            local escaped_suburl
            escaped_suburl="$(escape_sed_replacement "$SUBURL")"
            sed -i "s|{suburl}|$escaped_suburl|g" "$output_yaml"

            # Extract domain from SUBURL and set it to DIRECT
            local suburl_domain
            suburl_domain="$(echo "$SUBURL" | sed -E 's|^https?://||' | cut -d'/' -f1 | cut -d':' -f1)"
            if [ -n "$suburl_domain" ]; then
                sed -i "s|{suburl_domain}|$suburl_domain|g" "$output_yaml"
                log info "Subscription domain '$suburl_domain' set to DIRECT"
            fi
        else
            log warn "SUBURL not set, leaving provider url placeholder as-is"
            # Remove suburl_domain placeholder lines when no SUBURL is set
            sed -i '/{suburl_domain}/d' "$output_yaml"
        fi
        return 0
    fi

    if [ -f "$output_yaml" ]; then
        log warn "base.yaml not found, using existing clash.yaml"
        return 0
    fi

    if [ -f "$fallback_yaml" ]; then
        log warn "base.yaml/clash.yaml not found, using config.yaml as clash.yaml"
        cp "$fallback_yaml" "$output_yaml"
        return 0
    fi

    log error "No usable Clash configuration found under $clash_config_dir"
    return 1
}

start_clash() {
    local config_path=$1
    local clash_config_dir="${CLASH_CONFIG_DIR:-/etc/config/clash}"

    if [ ! -f "$config_path" ]; then
        log error "Clash configuration file not found: $config_path"
        return 1
    fi

    if pgrep -f "clash" >/dev/null 2>&1; then
        log warn "Clash is already running"
        return 0
    fi

    log info "Starting Clash core..."
    clash -d "$clash_config_dir" -f "$config_path" &

    local attempt=0
    while [ "$attempt" -lt 30 ]; do
        if curl -s -H "Authorization: Bearer $CLASH_WEB_PASSWORD" "http://127.0.0.1:$CLASH_WEB_PORT/api/version" >/dev/null 2>&1; then
            log info "Clash started successfully"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    log error "Clash startup failed"
    return 1
}

apply_nft_rules() {
    log info "Applying nftables rules..."
    if ! command -v nft >/dev/null 2>&1; then
        log error "nftables is not available"
        return 1
    fi

    bash /opt/ppgw/scripts/nft_full.sh
    log info "nftables rules applied successfully"
}

cleanup() {
    log info "Shutting down..."
    kill -- -$$ 2>/dev/null || true
    exit 0
}

trap cleanup SIGTERM SIGINT

main() {
    log info "========================================="
    log info "Mihomo startup starting..."
    log info "========================================="

    init_system
    load_config
    generate_clash_config
    start_clash "/etc/config/clash/clash.yaml"
    apply_nft_rules

    log info "========================================="
    log info "Mihomo startup completed!"
    log info "========================================="

    log info "Starting monitoring script..."
    bash /opt/ppgw/scripts/watch.sh &
    wait || true
}

main "$@"
