# mihomo Docker 镜像 - 用于 RouterOS
# 使用 nftables 作为防火墙后端

FROM alpine:latest

LABEL maintainer="mikrotik-mihomo"
LABEL description="mihomo for RouterOS with nftables"

ARG TARGETARCH
ARG TARGETVARIANT

# 单层 RUN 减少镜像层数
RUN set -ex; \
    # 安装运行时必需的包（使用 nftables）
    apk add --no-cache \
        ca-certificates \
        nftables \
        tzdata; \
    # 创建配置目录
    mkdir -p /root/.config/mihomo; \
    # 获取最新版本号
    LATEST_VERSION=$(wget -qO- "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'); \
    echo "Latest version: ${LATEST_VERSION}"; \
    # 根据架构确定下载文件名
    case "${TARGETARCH}" in \
        amd64) ARCH="linux-amd64" ;; \
        arm64) ARCH="linux-arm64" ;; \
        arm) \
            case "${TARGETVARIANT}" in \
                v7) ARCH="linux-armv7" ;; \
                v6) ARCH="linux-armv6" ;; \
                *) ARCH="linux-armv7" ;; \
            esac ;; \
        386) ARCH="linux-386" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}"; exit 1 ;; \
    esac; \
    # 下载并解压 mihomo
    wget -O /tmp/mihomo.gz "https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/mihomo-${ARCH}-${LATEST_VERSION}.gz"; \
    gunzip /tmp/mihomo.gz; \
    mv /tmp/mihomo /usr/local/bin/mihomo; \
    chmod +x /usr/local/bin/mihomo; \
    # 验证安装
    mihomo -v; \
    # 清理
    rm -rf /tmp/* /var/cache/apk/*

ENV TZ=Asia/Shanghai

VOLUME ["/root/.config/mihomo"]

EXPOSE 7890 7891 7892 9090 53/udp 53/tcp 7893/tcp 7893/udp

ENTRYPOINT ["/usr/local/bin/mihomo"]
CMD ["-d", "/root/.config/mihomo"]
