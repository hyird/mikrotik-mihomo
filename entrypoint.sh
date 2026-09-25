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

delete_quic_filter_rule() {
    while iptables -C FORWARD "$@" >/dev/null 2>&1; do
        iptables -D FORWARD "$@" >/dev/null 2>&1 || break
    done
}

clear_quic_filter() {
    delete_quic_filter_rule -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
    delete_quic_filter_rule -p udp --dport 443 -j DROP
    # Remove leftover interface-bound rules from older images.
    delete_quic_filter_rule -i eth0 -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
    delete_quic_filter_rule -i eth0 -p udp --dport 443 -j DROP
}

configure_quic_filter() {
    clear_quic_filter

    # Always block standard HTTP/3 (QUIC) traffic on UDP port 443.
    if ! iptables -I FORWARD 1 -p udp --dport 443 \
        -j REJECT --reject-with icmp-port-unreachable; then
        log warn "iptables REJECT is unavailable, falling back to DROP"
        iptables -I FORWARD 1 -p udp --dport 443 -j DROP
    fi
    log info "HTTP/3 (QUIC) blocking enabled on UDP/443 traffic through iptables"
}

load_config() {
    export FAKE_CIDR="${FAKE_CIDR:-198.18.0.0/16}"
    export CLASH_WEB_PORT="${CLASH_WEB_PORT:-80}"
    export CLASH_WEB_PASSWORD="${CLASH_WEB_PASSWORD:-}"
    export SUBURL="${SUBURL:-}"
    export LOG_LEVEL="$(normalize_log_level "${LOG_LEVEL:-error}")"
    export DEFAULT_BACKEND_URL="${DEFAULT_BACKEND_URL:-auto}"
    if [ -z "$DEFAULT_BACKEND_URL" ] || [ "$DEFAULT_BACKEND_URL" = "auto" ]; then
        DEFAULT_BACKEND_URL="$(detect_backend_url)"
        export DEFAULT_BACKEND_URL
    fi

    log info "Configuration loaded"
    log info "FakeIP CIDR: $FAKE_CIDR"
    log info "Clash Web Port: $CLASH_WEB_PORT"
    log info "Log Level: $LOG_LEVEL"
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

merge_config_sections() {
    local source_yaml=$1
    local generated_yaml=$2
    local merged_yaml=$3
    local section_names=$4

    awk -v source_yaml="$source_yaml" -v section_names="|$section_names|" '
        function top_level_key(line, key) {
            if (line !~ /^[^[:space:]#][^:]*:/) return ""
            key = line
            sub(/:.*/, "", key)
            return key
        }
        function selected(key) {
            return index(section_names, "|" key "|") != 0
        }
        FILENAME == source_yaml {
            key = top_level_key($0)
            if (key != "") section = key
            if (selected(section)) {
                saved[section] = saved[section] $0 "\n"
            }
            next
        }
        {
            key = top_level_key($0)
            if (key != "") {
                section = key
                if (selected(key) && saved[key] != "") {
                    printf "%s", saved[key]
                    printed[key] = 1
                }
            }
            if (selected(section) && saved[section] != "") next
            print
        }
        END {
            count = split(section_names, names, "|")
            for (i = 1; i <= count; i++) {
                key = names[i]
                if (key != "" && saved[key] != "" && !printed[key]) printf "%s", saved[key]
            }
        }
    ' "$source_yaml" "$generated_yaml" > "$merged_yaml"
}

remove_config_section() {
    local section_name=$1
    local input_yaml=$2
    local output_yaml=$3

    awk -v section_name="$section_name" '
        /^[^[:space:]#][^:]*:/ {
            key = $0
            sub(/:.*/, "", key)
            skip = (key == section_name)
        }
        !skip { print }
    ' "$input_yaml" > "$output_yaml"
}

generate_clash_config() {
    local clash_config_dir="${CLASH_CONFIG_DIR:-/etc/mihomo}"
    local base_yaml="$clash_config_dir/base.yaml"
    local output_yaml="$clash_config_dir/clash.yaml"
    local fallback_yaml="$clash_config_dir/config.yaml"

    if [ -f "$base_yaml" ]; then
        log info "Generating Clash configuration from base.yaml"
        local generated_yaml
        local merged_yaml
        local subscription_yaml
        local subscription_loaded=0
        generated_yaml="$(mktemp "$clash_config_dir/.clash-generated.XXXXXX")"
        merged_yaml="$(mktemp "$clash_config_dir/.clash-merged.XXXXXX")"
        subscription_yaml="$(mktemp "$clash_config_dir/.clash-subscription.XXXXXX")"
        cp -p "$base_yaml" "$generated_yaml"
        sed -i "s|{fake_cidr}|$FAKE_CIDR|g" "$generated_yaml"
        sed -i "s|{clash_web_port}|$CLASH_WEB_PORT|g" "$generated_yaml"
        sed -i "s|{log_level}|$LOG_LEVEL|g" "$generated_yaml"
        if [ -n "$CLASH_WEB_PASSWORD" ]; then
            local escaped_secret
            escaped_secret="$(escape_sed_replacement "$CLASH_WEB_PASSWORD")"
            sed -i "s|{clash_web_password}|$escaped_secret|g" "$generated_yaml"
        else
            sed -i '/^[[:space:]]*secret:[[:space:]]*{clash_web_password}[[:space:]]*$/d' "$generated_yaml"
        fi

        if [ -n "$SUBURL" ]; then
            local escaped_suburl
            escaped_suburl="$(escape_sed_replacement "$SUBURL")"
            sed -i "s|{suburl}|$escaped_suburl|g" "$generated_yaml"

            # Extract domain from SUBURL and set it to DIRECT
            local suburl_domain
            suburl_domain="$(echo "$SUBURL" | sed -E 's|^https?://||' | cut -d'/' -f1 | cut -d':' -f1)"
            if [ -n "$suburl_domain" ]; then
                sed -i "s|{suburl_domain}|$suburl_domain|g" "$generated_yaml"
                log info "Subscription domain '$suburl_domain' set to DIRECT"
            fi
        else
            log warn "SUBURL not set, leaving provider url placeholder as-is"
            # Remove suburl_domain placeholder lines when no SUBURL is set
            sed -i '/{suburl_domain}/d' "$generated_yaml"
        fi

        if [ -n "$SUBURL" ]; then
            if curl --fail --location --silent --show-error --retry 3 --max-time 45 \
                --user-agent clash.meta --output "$subscription_yaml" "$SUBURL" \
                && grep -q '^proxies:' "$subscription_yaml" \
                && grep -q '^proxy-groups:' "$subscription_yaml" \
                && grep -q '^rules:' "$subscription_yaml"; then
                merge_config_sections "$subscription_yaml" "$generated_yaml" "$merged_yaml" \
                    'proxies|proxy-providers|proxy-groups|rule-providers|rules'
                if grep -q '^proxy-providers:' "$subscription_yaml"; then
                    mv "$merged_yaml" "$generated_yaml"
                else
                    remove_config_section 'proxy-providers' "$merged_yaml" "$generated_yaml"
                fi
                subscription_loaded=1
                log info "Loaded proxies, groups, and rules from subscription"
            else
                log error "Subscription did not provide a complete Clash configuration"
            fi
        fi

        if [ "$subscription_loaded" -eq 0 ] && [ -f "$output_yaml" ]; then
            cp -p "$output_yaml" "$merged_yaml"
            merge_config_sections "$output_yaml" "$generated_yaml" "$merged_yaml" \
                'proxy-groups|rules'
            mv "$merged_yaml" "$output_yaml"
            log info "Preserved existing proxy-groups and rules"
        else
            mv "$generated_yaml" "$output_yaml"
        fi
        rm -f "$generated_yaml" "$merged_yaml" "$subscription_yaml"
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

cleanup() {
    log info "Shutting down..."
    kill -- -$$ 2>/dev/null || true
    exit 0
}

trap clear_quic_filter EXIT
trap cleanup SIGTERM SIGINT

main() {
    log info "========================================="
    log info "Mihomo startup starting..."
    log info "========================================="

    init_system
    load_config
    configure_quic_filter
    configure_web_ui
    generate_clash_config
    start_clash "${CLASH_CONFIG_DIR:-/etc/mihomo}/clash.yaml"

    log info "========================================="
    log info "Mihomo startup completed!"
    log info "========================================="

    wait "$CLASH_PID"
}

main "$@"
