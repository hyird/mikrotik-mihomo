#!/bin/sh
set -eu

normalize_log_level() {
    case "$1" in
        debug) printf '%s' "debug" ;;
        info) printf '%s' "info" ;;
        warn|warning) printf '%s' "warning" ;;
        error) printf '%s' "error" ;;
        silent) printf '%s' "silent" ;;
        *) printf '%s' "error" ;;
    esac
}

log_level_rank() {
    case "$1" in
        debug) printf '%s' "0" ;;
        info) printf '%s' "1" ;;
        warn|warning) printf '%s' "2" ;;
        error) printf '%s' "3" ;;
        silent) printf '%s' "4" ;;
        *) return 1 ;;
    esac
}

log() {
    local level=$1
    local threshold
    local level_rank
    local threshold_rank
    local tag
    shift

    threshold="$(normalize_log_level "${LOG_LEVEL:-error}")"
    level_rank="$(log_level_rank "$level" 2>/dev/null || printf '%s' "1")"
    threshold_rank="$(log_level_rank "$threshold" 2>/dev/null || printf '%s' "3")"
    if [ "$level_rank" -lt "$threshold_rank" ]; then
        return 0
    fi

    case "$level" in
        debug) tag="DEBUG" ;;
        info) tag="INFO" ;;
        warn|warning) tag="WARN" ;;
        error) tag="ERROR" ;;
        *) tag="LOG" ;;
    esac

    echo "[$(date +'%H:%M:%S')] [$tag] $*" >&2
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

escape_js_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

detect_backend_url() {
    local ip_addr
    local backend_url

    ip_addr="$(hostname -i 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n 1 || true)"
    if [ -z "$ip_addr" ]; then
        ip_addr="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | head -n 1 || true)"
    fi
    if [ -z "$ip_addr" ]; then
        ip_addr="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
    fi

    if [ -z "$ip_addr" ]; then
        log warn "Unable to detect backend IP, falling back to window.location.origin"
        printf '%s' "window.location.origin"
        return 0
    fi

    if [ "$CLASH_WEB_PORT" = "80" ]; then
        backend_url="http://$ip_addr"
    else
        backend_url="http://$ip_addr:$CLASH_WEB_PORT"
    fi

    printf '%s' "$backend_url"
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
    export CLASH_WEB_PASSWORD="${CLASH_WEB_PASSWORD:-}"
    export SLEEPTIME="${SLEEPTIME:-30}"
    export SUBURL="${SUBURL:-}"
    export BLOCK_QUIC="${BLOCK_QUIC:-true}"
    export LOG_LEVEL="$(normalize_log_level "${LOG_LEVEL:-error}")"
    export DEFAULT_BACKEND_URL="${DEFAULT_BACKEND_URL:-auto}"
    if [ -z "$DEFAULT_BACKEND_URL" ] || [ "$DEFAULT_BACKEND_URL" = "auto" ]; then
        DEFAULT_BACKEND_URL="$(detect_backend_url)"
        export DEFAULT_BACKEND_URL
    fi

    log info "Configuration loaded"
    log info "FakeIP CIDR: $FAKE_CIDR"
    log info "TProxy Port: $TPROXY_PORT"
    log info "Clash Web Port: $CLASH_WEB_PORT"
    log info "Block QUIC: $BLOCK_QUIC"
    log info "Log Level: $LOG_LEVEL"
    log info "Update Interval: $SLEEPTIME seconds"
    log info "Default Web UI backend: $DEFAULT_BACKEND_URL"
}

configure_web_ui() {
    local clash_config_dir="${CLASH_CONFIG_DIR:-/etc/mihomo}"
    local target_ui_dir="$clash_config_dir/ui/xd"

    if [ ! -d "$target_ui_dir" ]; then
        log warn "MetaCubeXD web UI not found"
        mkdir -p "$target_ui_dir"
    fi

    local default_backend_js
    if [ "$DEFAULT_BACKEND_URL" = "window.location.origin" ]; then
        default_backend_js="window.location.origin"
    else
        default_backend_js="\"$(escape_js_string "$DEFAULT_BACKEND_URL")\""
    fi

    cat > "$target_ui_dir/config.js" << EOF
window.__METACUBEXD_CONFIG__ = {
  defaultBackendURL: $default_backend_js,
}
EOF
}

generate_clash_config() {
    local clash_config_dir="${CLASH_CONFIG_DIR:-/etc/mihomo}"
    local base_yaml="$clash_config_dir/base.yaml"
    local output_yaml="$clash_config_dir/clash.yaml"
    local fallback_yaml="$clash_config_dir/config.yaml"

    if [ -f "$base_yaml" ]; then
        log info "Generating Clash configuration from base.yaml"
        cp "$base_yaml" "$output_yaml"
        sed -i "s|{fake_cidr}|$FAKE_CIDR|g" "$output_yaml"
        sed -i "s|{tproxy_port}|$TPROXY_PORT|g" "$output_yaml"
        sed -i "s|{clash_web_port}|$CLASH_WEB_PORT|g" "$output_yaml"
        sed -i "s|{log_level}|$LOG_LEVEL|g" "$output_yaml"
        if [ -n "$CLASH_WEB_PASSWORD" ]; then
            local escaped_secret
            escaped_secret="$(escape_sed_replacement "$CLASH_WEB_PASSWORD")"
            sed -i "s|{clash_web_password}|$escaped_secret|g" "$output_yaml"
        else
            sed -i '/^[[:space:]]*secret:[[:space:]]*{clash_web_password}[[:space:]]*$/d' "$output_yaml"
        fi

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
    local clash_config_dir="${CLASH_CONFIG_DIR:-/etc/mihomo}"
    local existing_pid

    if [ ! -f "$config_path" ]; then
        log error "Clash configuration file not found: $config_path"
        return 1
    fi

    existing_pid="$(pidof clash 2>/dev/null | awk '{print $1}' || true)"
    if [ -n "$existing_pid" ]; then
        log warn "Clash is already running"
        CLASH_PID="$existing_pid"
        return 0
    fi

    log info "Starting Clash core..."
    clash -d "$clash_config_dir" -f "$config_path" &
    CLASH_PID="$!"
    log info "Clash process started with PID $CLASH_PID"
}

apply_nft_rules() {
    log info "Applying nftables rules..."
    if ! command -v nft >/dev/null 2>&1; then
        log error "nftables is not available"
        return 1
    fi

    sh /opt/mihomo/scripts/nft_full.sh
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
    configure_web_ui
    generate_clash_config
    start_clash "${CLASH_CONFIG_DIR:-/etc/mihomo}/clash.yaml"
    apply_nft_rules

    log info "========================================="
    log info "Mihomo startup completed!"
    log info "========================================="

    wait "$CLASH_PID"
}

main "$@"
