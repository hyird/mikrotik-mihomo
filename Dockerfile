FROM alpine:latest

ARG TARGETARCH
ARG TARGETVARIANT
ARG MIHOMO_VERSION=v1.19.27
ARG METACUBEXD_REF=640e8cbc3472bfc913bfc3296df1f1fda0d607f3

# Install dependencies and fetch architecture-specific Mihomo binary in one layer.
RUN set -eux; \
    apk add --no-cache \
        bash \
        curl \
        ca-certificates \
        nftables \
        iproute2 \
        procps \
        tzdata \
        tini; \
    mkdir -p /etc/config/clash /opt/ppgw; \
    if [ "$MIHOMO_VERSION" = "latest" ]; then \
        MIHOMO_VERSION="$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep 'tag_name' | cut -d'"' -f4)"; \
    fi; \
    case "${TARGETARCH}${TARGETVARIANT}" in \
        amd64) CLASH_ASSET="mihomo-linux-amd64-${MIHOMO_VERSION}.gz" ;; \
        arm64) CLASH_ASSET="mihomo-linux-arm64-${MIHOMO_VERSION}.gz" ;; \
        armv7) CLASH_ASSET="mihomo-linux-armv7-${MIHOMO_VERSION}.gz" ;; \
        *) echo "Unsupported target: ${TARGETARCH}/${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${CLASH_ASSET}" -o /tmp/clash.gz; \
    gunzip /tmp/clash.gz; \
    install -m 0755 /tmp/clash /usr/local/bin/clash; \
    rm -f /tmp/clash; \
    # Pre-bundle metacubexd web UI
    apk add --no-cache --virtual .ui-deps unzip; \
    curl -fsSL "https://github.com/MetaCubeX/metacubexd/archive/${METACUBEXD_REF}.zip" -o /tmp/ui.zip; \
    mkdir -p /opt/ppgw/ui; \
    unzip -q /tmp/ui.zip -d /tmp/ui; \
    mv "$(find /tmp/ui -mindepth 1 -maxdepth 1 -type d | head -n 1)" /opt/ppgw/ui/xd; \
    printf '%s\n' "$METACUBEXD_REF" > /opt/ppgw/ui/xd/.metacubexd-ref; \
    rm -rf /tmp/ui /tmp/ui.zip; \
    apk del .ui-deps

WORKDIR /opt/ppgw

COPY --chmod=755 scripts/ /opt/ppgw/scripts/
COPY clash/ /etc/config/clash/
COPY --chmod=755 entrypoint.sh /opt/ppgw/entrypoint.sh

# Environment variables
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/ppgw/scripts" \
    CLASH_CONFIG="/etc/config/clash" \
    CLASH_HOME="/etc/config/clash"

# Entry point
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/opt/ppgw/entrypoint.sh"]
