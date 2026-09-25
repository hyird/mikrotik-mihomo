#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -f "$test_dir/base.yaml" "$test_dir/clash.yaml" "$test_dir/functions.sh" "$test_dir/subscription.yaml"; rmdir "$test_dir"' EXIT

# Load the startup functions without running main.
sed '$d' "$repo_dir/entrypoint.sh" > "$test_dir/functions.sh"
. "$test_dir/functions.sh"
cp "$repo_dir/clash/base.yaml" "$test_dir/base.yaml"

CLASH_CONFIG_DIR="$test_dir"
FAKE_CIDR="198.19.0.0/16"
CLASH_WEB_PORT="9090"
CLASH_WEB_PASSWORD=""
SUBURL=""
LOG_LEVEL="info"
generate_clash_config
grep -q 'name: "Proxy"' "$test_dir/clash.yaml"

cat > "$test_dir/clash.yaml" <<'EOF'
proxy-groups:
  - name: Custom
    type: select
    proxies: [DIRECT]
rules:
  - "DOMAIN,example.org,Custom"
  - "MATCH,DIRECT"
EOF

generate_clash_config
grep -q 'name: Custom' "$test_dir/clash.yaml"
grep -q 'DOMAIN,example.org,Custom' "$test_dir/clash.yaml"
grep -q 'external-controller: 0.0.0.0:9090' "$test_dir/clash.yaml"
grep -q 'fake-ip-range: 198.19.0.0/16' "$test_dir/clash.yaml"
! grep -q 'name: "Proxy"' "$test_dir/clash.yaml"
! grep -q 'GEOIP,CN,DIRECT' "$test_dir/clash.yaml"

cat > "$test_dir/subscription.yaml" <<'EOF'
proxies:
  - name: upstream-node
    type: direct
proxy-groups:
  - { name: UPSTREAM, type: select, proxies: [upstream-node] }
rules:
  - "MATCH,UPSTREAM"
EOF
curl() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--output" ]; then
            shift
            cp "$test_dir/subscription.yaml" "$1"
            return 0
        fi
        shift
    done
    return 1
}
SUBURL="https://example.com/sub"
generate_clash_config
grep -q 'name: upstream-node' "$test_dir/clash.yaml"
grep -q 'name: UPSTREAM' "$test_dir/clash.yaml"
grep -q 'MATCH,UPSTREAM' "$test_dir/clash.yaml"
! grep -q '^proxy-providers:' "$test_dir/clash.yaml"
! grep -q 'name: Custom' "$test_dir/clash.yaml"
! grep -q 'DOMAIN,example.org,Custom' "$test_dir/clash.yaml"
