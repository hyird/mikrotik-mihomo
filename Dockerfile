FROM --platform=$BUILDPLATFORM alpine:latest AS assets

ARG TARGETARCH
ARG TARGETVARIANT
ARG MIHOMO_VERSION=latest
ARG METACUBEXD_REF=refs/heads/gh-pages
ARG COUNTRY_MMDB_URL=https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb
ARG UPSTREAM_CACHE_BUST=manual
ARG UPX_COMPRESS=true

RUN set -eux; \
    apk add --no-cache ca-certificates-bundle curl upx; \
    echo "Upstream cache bust: $UPSTREAM_CACHE_BUST"; \
    mkdir -p \
        /rootfs/etc/mihomo/ui \
        /rootfs/opt/mihomo \
        /rootfs/usr/local/bin; \
    if [ "$MIHOMO_VERSION" = "latest" ]; then \
        MIHOMO_VERSION="$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep 'tag_name' | cut -d'"' -f4)"; \
    fi; \
    case "${TARGETARCH}${TARGETVARIANT}" in \
        amd64) MIHOMO_ASSET="mihomo-linux-amd64-${MIHOMO_VERSION}.gz" ;; \
        arm64) MIHOMO_ASSET="mihomo-linux-arm64-${MIHOMO_VERSION}.gz" ;; \
        armv7) MIHOMO_ASSET="mihomo-linux-armv7-${MIHOMO_VERSION}.gz" ;; \
        *) echo "Unsupported target: ${TARGETARCH}/${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${MIHOMO_ASSET}" -o /tmp/mihomo.gz; \
    gunzip /tmp/mihomo.gz; \
    install -m 0755 /tmp/mihomo /rootfs/usr/local/bin/clash; \
    if [ "$UPX_COMPRESS" = "true" ]; then \
        upx --best --lzma /rootfs/usr/local/bin/clash; \
    fi; \
    curl -fsSL "https://github.com/MetaCubeX/metacubexd/archive/${METACUBEXD_REF}.zip" -o /tmp/ui.zip; \
    unzip -q /tmp/ui.zip -d /tmp/ui; \
    mv "$(find /tmp/ui -mindepth 1 -maxdepth 1 -type d | head -n 1)" /rootfs/etc/mihomo/ui/xd; \
    find /rootfs/etc/mihomo/ui/xd -type f -name '*.map' -delete; \
    printf '%s\n' "$METACUBEXD_REF" > /rootfs/etc/mihomo/ui/xd/.metacubexd-ref; \
    curl -fsSL "$COUNTRY_MMDB_URL" -o /rootfs/etc/mihomo/country.mmdb; \
    ln -sf country.mmdb /rootfs/etc/mihomo/Country.mmdb; \
    rm -rf /tmp/mihomo /tmp/ui /tmp/ui.zip

COPY --chmod=755 scripts/ /rootfs/opt/mihomo/scripts/
COPY clash/ /rootfs/etc/mihomo/
COPY --chmod=755 entrypoint.sh /rootfs/opt/mihomo/entrypoint.sh

FROM alpine:latest

ARG RUNTIME_TZ=Asia/Shanghai

RUN set -eux; \
    apk add --no-cache \
        ca-certificates-bundle \
        iproute2-minimal \
        nftables \
        tini; \
    apk add --no-cache --virtual .tzdata tzdata; \
    tz_dir="$(dirname "$RUNTIME_TZ")"; \
    cp "/usr/share/zoneinfo/$RUNTIME_TZ" /tmp/localtime; \
    apk del .tzdata; \
    mkdir -p "/usr/share/zoneinfo/$tz_dir"; \
    mv /tmp/localtime "/usr/share/zoneinfo/$RUNTIME_TZ"; \
    ln -sf "/usr/share/zoneinfo/$RUNTIME_TZ" /etc/localtime; \
    rm -rf /tmp/* /var/cache/apk/*

COPY --from=assets /rootfs/ /

ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/mihomo/scripts" \
    CLASH_CONFIG="/etc/mihomo" \
    CLASH_HOME="/etc/mihomo" \
    TZ="${RUNTIME_TZ}"

WORKDIR /opt/mihomo

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/opt/mihomo/entrypoint.sh"]
