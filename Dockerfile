FROM --platform=$BUILDPLATFORM alpine:3.22 AS fetcher

ARG TARGETARCH
ARG TARGETVARIANT
ARG MIHOMO_VERSION=v1.19.27
ARG METACUBEXD_REF=640e8cbc3472bfc913bfc3296df1f1fda0d607f3
ARG COUNTRY_MMDB_URL=https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb

RUN set -eux; \
    apk add --no-cache ca-certificates curl gzip unzip; \
    mkdir -p /out/ui /out/geo; \
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
    install -m 0755 /tmp/mihomo /out/mihomo; \
    curl -fsSL "https://github.com/MetaCubeX/metacubexd/archive/${METACUBEXD_REF}.zip" -o /tmp/ui.zip; \
    unzip -q /tmp/ui.zip -d /tmp/ui; \
    mv "$(find /tmp/ui -mindepth 1 -maxdepth 1 -type d | head -n 1)" /out/ui/xd; \
    find /out/ui/xd -type f -name '*.map' -delete; \
    printf '%s\n' "$METACUBEXD_REF" > /out/ui/xd/.metacubexd-ref; \
    curl -fsSL "$COUNTRY_MMDB_URL" -o /out/geo/country.mmdb; \
    rm -rf /tmp/mihomo /tmp/ui /tmp/ui.zip

FROM alpine:3.22

RUN set -eux; \
    apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        iproute2 \
        nftables \
        procps \
        tini \
        tzdata; \
    mkdir -p /etc/mihomo/ui /opt/mihomo

COPY --from=fetcher /out/mihomo /usr/local/bin/clash
COPY --from=fetcher /out/ui/xd /etc/mihomo/ui/xd
COPY --from=fetcher /out/geo/country.mmdb /etc/mihomo/country.mmdb

RUN ln -sf country.mmdb /etc/mihomo/Country.mmdb

WORKDIR /opt/mihomo

COPY --chmod=755 scripts/ /opt/mihomo/scripts/
COPY clash/ /etc/mihomo/
COPY --chmod=755 entrypoint.sh /opt/mihomo/entrypoint.sh

ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/mihomo/scripts" \
    CLASH_CONFIG="/etc/mihomo" \
    CLASH_HOME="/etc/mihomo"

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/opt/mihomo/entrypoint.sh"]
