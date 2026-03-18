#!/bin/bash
set -euo pipefail

IPREX4='([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])'

dns1=$(grep nameserver /etc/resolv.conf | grep -Eo "$IPREX4" | head -1)
dns2=$(grep nameserver /etc/resolv.conf | grep -Eo "$IPREX4" | tail -1)

DNS_IP="8.8.8.8"
DNS_PORT="53"
TPROXY_PORT="${TPROXY_PORT:-1082}"
BLOCK_QUIC="${BLOCK_QUIC:-true}"

/usr/sbin/nft -f - << EOF
flush ruleset

define DNS_O1 = ${dns1:-8.8.8.8}
define DNS_O2 = ${dns2:-8.8.4.4}
define DNS_R_IP = $DNS_IP
define DNS_R_PORT = $DNS_PORT

table ip ppgw {
        set localnetwork {
                typeof ip daddr
                flags interval
                elements = {
                        0.0.0.0/8,
                        127.0.0.0/8,
                        10.0.0.0/8,
                        169.254.0.0/16,
                        172.16.0.0/12,
                        192.168.0.0/16,
                        224.0.0.0/4,
                        240.0.0.0-255.255.255.255
                }
        }
        set original_dns {
                type ipv4_addr
                elements = { \$DNS_O1, \$DNS_O2 }
        }
        chain clashboth {
                type filter hook prerouting priority mangle; policy accept;
                ip daddr @localnetwork return
$([ "$BLOCK_QUIC" = "true" ] && echo '                ip protocol udp udp dport 443 drop')
                ip protocol tcp tproxy to 127.0.0.1:$TPROXY_PORT meta mark set 1
                ip protocol udp tproxy to 127.0.0.1:$TPROXY_PORT meta mark set 1
        }

        chain fakeping {
                type nat hook prerouting priority 0; policy accept;
                ip protocol icmp dnat to 127.0.0.1
        }

        chain hijackdns {
                type nat hook output priority dstnat; policy accept;
                meta skuid 65534 accept
                ip daddr @original_dns udp dport 53 dnat to \$DNS_R_IP:\$DNS_R_PORT
        }
}
EOF

ip rule add fwmark 1 lookup 100 2>/dev/null || ip rule add fwmark 1 table 100 2>/dev/null || true
ip route add local default dev lo table 100 2>/dev/null || true
ip route add default via 127.0.0.1 table 100 2>/dev/null || true

echo "TCP+UDP rules applied successfully"
