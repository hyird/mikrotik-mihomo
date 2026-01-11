# mihomo Docker 镜像 - 用于 RouterOS
# 使用 iptables-legacy 作为默认后端

FROM alpine:latest

LABEL maintainer="mikrotik-mihomo"
LABEL description="mihomo for RouterOS with iptables-legacy"

# 安装依赖包
RUN apk add --no-cache \
    ca-certificates \
    iptables \
    ip6tables \
    curl \
    wget \
    tzdata \
    && rm -rf /var/cache/apk/*

# 设置 iptables-legacy 为默认后端
# RouterOS 容器环境需要使用 legacy 版本
RUN ln -sf /sbin/iptables-legacy /sbin/iptables \
    && ln -sf /sbin/iptables-legacy-save /sbin/iptables-save \
    && ln -sf /sbin/iptables-legacy-restore /sbin/iptables-restore \
    && ln -sf /sbin/ip6tables-legacy /sbin/ip6tables \
    && ln -sf /sbin/ip6tables-legacy-save /sbin/ip6tables-save \
    && ln -sf /sbin/ip6tables-legacy-restore /sbin/ip6tables-restore

# 设置时区
ENV TZ=Asia/Shanghai

# 创建工作目录
RUN mkdir -p /root/.config/mihomo

# 下载最新版本的 mihomo
# 使用 ARG 支持构建时指定架构
ARG TARGETARCH
ARG TARGETVARIANT

RUN set -ex; \
    # 获取最新版本号
    LATEST_VERSION=$(wget -qO- "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'); \
    echo "Latest version: ${LATEST_VERSION}"; \
    # 根据架构确定下载文件名
    case "${TARGETARCH}" in \
        amd64) \
            ARCH="linux-amd64" \
            ;; \
        arm64) \
            ARCH="linux-arm64" \
            ;; \
        arm) \
            case "${TARGETVARIANT}" in \
                v7) ARCH="linux-armv7" ;; \
                v6) ARCH="linux-armv6" ;; \
                *) ARCH="linux-armv7" ;; \
            esac \
            ;; \
        386) \
            ARCH="linux-386" \
            ;; \
        *) \
            echo "Unsupported architecture: ${TARGETARCH}"; \
            exit 1 \
            ;; \
    esac; \
    # 下载并解压 mihomo
    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/mihomo-${ARCH}-${LATEST_VERSION}.gz"; \
    echo "Downloading from: ${DOWNLOAD_URL}"; \
    wget -O /tmp/mihomo.gz "${DOWNLOAD_URL}"; \
    gunzip /tmp/mihomo.gz; \
    mv /tmp/mihomo /usr/local/bin/mihomo; \
    chmod +x /usr/local/bin/mihomo; \
    # 验证安装
    mihomo -v

# 配置文件目录
VOLUME ["/root/.config/mihomo"]

# 暴露端口
# 混合代理端口
EXPOSE 7890
# SOCKS5 代理端口
EXPOSE 7891
# HTTP 代理端口
EXPOSE 7892
# RESTful API 端口
EXPOSE 9090
# DNS 端口
EXPOSE 53/udp
EXPOSE 53/tcp
# TProxy 端口
EXPOSE 7893/tcp
EXPOSE 7893/udp

# 直接运行 mihomo
ENTRYPOINT ["/usr/local/bin/mihomo"]
CMD ["-d", "/root/.config/mihomo"]
