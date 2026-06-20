#!/bin/sh
set -eu

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

escape_js_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

replace_placeholder() {
    local placeholder=$1
    local value=$2
    local file=$3
    local escaped_value

    escaped_value="$(escape_sed_replacement "$value")"
    sed -i "s|{$placeholder}|$escaped_value|g" "$file"
}

curl_api() {
    if [ -n "$CLASH_WEB_PASSWORD" ]; then
        curl -s -H "Authorization: Bearer $CLASH_WEB_PASSWORD" "$@"
    else
        curl -s "$@"
    fi
}

init_system() {
    log info "Initializing system configuration..."

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null
    echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true

    if [ ! -c /dev/net/tun ]; then
        log info "Creating /dev/net/tun"
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null || true
        chmod 600 /dev/net/tun 2>/dev/null || true
    fi

    log info "System configuration completed"
}

load_config() {
    export FAKE_CIDR="${FAKE_CIDR:-198.18.0.0/16}"
    export CLASH_WEB_PORT="${CLASH_WEB_PORT:-80}"
    export CLASH_WEB_PASSWORD="${CLASH_WEB_PASSWORD:-}"
    export SLEEPTIME="${SLEEPTIME:-30}"
    export SUBURL="${SUBURL:-}"
    export DEFAULT_BACKEND_URL="${DEFAULT_BACKEND_URL:-window.location.origin}"
    export TUN_STACK="${TUN_STACK:-mixed}"
    export TUN_DEVICE="${TUN_DEVICE:-mihomo}"
    export TUN_AUTO_ROUTE="${TUN_AUTO_ROUTE:-true}"
    export TUN_AUTO_REDIRECT="${TUN_AUTO_REDIRECT:-false}"
    export TUN_AUTO_DETECT_INTERFACE="${TUN_AUTO_DETECT_INTERFACE:-true}"
    export TUN_STRICT_ROUTE="${TUN_STRICT_ROUTE:-true}"
    export TUN_INET4_ADDRESS="${TUN_INET4_ADDRESS:-172.19.0.1/30}"
    export TUN_MTU="${TUN_MTU:-9000}"
    export TUN_GSO="${TUN_GSO:-true}"
    export TUN_GSO_MAX_SIZE="${TUN_GSO_MAX_SIZE:-65536}"
    export TUN_IPROUTE2_TABLE_INDEX="${TUN_IPROUTE2_TABLE_INDEX:-2022}"
    export TUN_IPROUTE2_RULE_INDEX="${TUN_IPROUTE2_RULE_INDEX:-9000}"
    export TUN_ENDPOINT_INDEPENDENT_NAT="${TUN_ENDPOINT_INDEPENDENT_NAT:-true}"
    export TUN_UDP_TIMEOUT="${TUN_UDP_TIMEOUT:-300}"

    log info "Configuration loaded"
    log info "FakeIP CIDR: $FAKE_CIDR"
    log info "Clash Web Port: $CLASH_WEB_PORT"
    log info "TUN Stack: $TUN_STACK"
    log info "TUN Device: $TUN_DEVICE"
    log info "TUN Auto Route: $TUN_AUTO_ROUTE"
    log info "TUN Auto Redirect: $TUN_AUTO_REDIRECT"
    log info "TUN Strict Route: $TUN_STRICT_ROUTE"
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
        replace_placeholder "fake_cidr" "$FAKE_CIDR" "$output_yaml"
        replace_placeholder "clash_web_port" "$CLASH_WEB_PORT" "$output_yaml"
        replace_placeholder "tun_stack" "$TUN_STACK" "$output_yaml"
        replace_placeholder "tun_device" "$TUN_DEVICE" "$output_yaml"
        replace_placeholder "tun_auto_route" "$TUN_AUTO_ROUTE" "$output_yaml"
        replace_placeholder "tun_auto_redirect" "$TUN_AUTO_REDIRECT" "$output_yaml"
        replace_placeholder "tun_auto_detect_interface" "$TUN_AUTO_DETECT_INTERFACE" "$output_yaml"
        replace_placeholder "tun_strict_route" "$TUN_STRICT_ROUTE" "$output_yaml"
        replace_placeholder "tun_inet4_address" "$TUN_INET4_ADDRESS" "$output_yaml"
        replace_placeholder "tun_mtu" "$TUN_MTU" "$output_yaml"
        replace_placeholder "tun_gso" "$TUN_GSO" "$output_yaml"
        replace_placeholder "tun_gso_max_size" "$TUN_GSO_MAX_SIZE" "$output_yaml"
        replace_placeholder "tun_iproute2_table_index" "$TUN_IPROUTE2_TABLE_INDEX" "$output_yaml"
        replace_placeholder "tun_iproute2_rule_index" "$TUN_IPROUTE2_RULE_INDEX" "$output_yaml"
        replace_placeholder "tun_endpoint_independent_nat" "$TUN_ENDPOINT_INDEPENDENT_NAT" "$output_yaml"
        replace_placeholder "tun_udp_timeout" "$TUN_UDP_TIMEOUT" "$output_yaml"
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

    if [ ! -f "$config_path" ]; then
        log error "Clash configuration file not found: $config_path"
        return 1
    fi

    if pidof clash >/dev/null 2>&1; then
        log warn "Clash is already running"
        return 0
    fi

    log info "Starting Clash core..."
    clash -d "$clash_config_dir" -f "$config_path" &

    local attempt=0
    while [ "$attempt" -lt 30 ]; do
        if curl_api "http://127.0.0.1:$CLASH_WEB_PORT/api/version" >/dev/null 2>&1; then
            log info "Clash started successfully"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    log error "Clash startup failed"
    return 1
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

    log info "========================================="
    log info "Mihomo startup completed!"
    log info "========================================="

    log info "Starting monitoring script..."
    sh /opt/mihomo/scripts/watch.sh &
    wait || true
}

main "$@"
