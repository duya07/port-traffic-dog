#!/bin/sh
# Alpine Linux 预装：安装 Dog 2.x 运行所需的软件包，并启动 crond。
# 之后运行：bash port-traffic-dog.sh
# 可选：加 --ip-guard 同时安装测试中的“在线 IP / 并发限制”所需的 python3 与 libnetfilter_queue。

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请以 root 运行"
    exit 1
fi

if ! command -v apk >/dev/null 2>&1; then
    echo "错误：未找到 apk，本脚本仅适用于 Alpine Linux"
    exit 1
fi

with_guard=false
[ "${1:-}" = "--ip-guard" ] && with_guard=true

echo "[1/4] 安装依赖..."
apk update
# nftables ≥ 0.9.2（verdict map）；iproute2 提供 tc；util-linux-misc 提供 flock；tzdata 用于北京时间显示。
apk add --no-cache \
    bash \
    nftables \
    iproute2 \
    iproute2-ss \
    jq \
    gawk \
    coreutils \
    dcron \
    ca-certificates \
    curl \
    util-linux-misc \
    tzdata
if [ "$with_guard" = true ]; then
    apk add --no-cache python3 libnetfilter_queue
fi

echo "[2/4] cron 命令兼容..."
if ! command -v cron >/dev/null 2>&1; then
    mkdir -p /usr/local/bin
    ln -sf /usr/sbin/crond /usr/local/bin/cron
fi

echo "[3/4] 启动并设置 crond 开机自启..."
if command -v rc-update >/dev/null 2>&1; then
    rc-update add crond default >/dev/null 2>&1 || true
fi
if command -v rc-service >/dev/null 2>&1; then
    rc-service crond start >/dev/null 2>&1 || true
fi
if ! pgrep -x crond >/dev/null 2>&1; then
    crond -b
fi

echo "[4/4] 检查命令..."
missing=""
for tool in bash nft tc ss jq awk cron crontab curl flock sha256sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing="$missing $tool"
    fi
done

nft_version=$(nft --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)
if [ -n "$nft_version" ] && [ "$(printf '%s\n0.9.2\n' "$nft_version" | sort -V | head -n1)" != "0.9.2" ]; then
    missing="$missing nftables>=0.9.2(当前$nft_version)"
fi

if [ -n "$missing" ]; then
    echo "预装完成，但仍缺少：$missing"
    echo "请手动安装或修复后再运行 port-traffic-dog.sh"
    exit 1
fi

echo "Alpine 预装完成。现在可以运行：bash port-traffic-dog.sh"
