#!/bin/sh

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: please run as root"
    exit 1
fi

if ! command -v apk >/dev/null 2>&1; then
    echo "Error: apk not found, this script is only for Alpine Linux"
    exit 1
fi

echo "[1/4] Installing Alpine dependencies for port-traffic-dog..."
apk update
apk add --no-cache \
    bash \
    nftables \
    iproute2 \
    iproute2-ss \
    jq \
    gawk \
    bc \
    unzip \
    dcron \
    ca-certificates \
    curl \
    tzdata

echo "[2/4] Ensuring cron command compatibility..."
if ! command -v cron >/dev/null 2>&1; then
    mkdir -p /usr/local/bin
    ln -sf /usr/sbin/crond /usr/local/bin/cron
fi

echo "[3/4] Starting and enabling crond..."
if command -v rc-update >/dev/null 2>&1; then
    rc-update add crond default >/dev/null 2>&1 || true
fi
if command -v rc-service >/dev/null 2>&1; then
    rc-service crond start >/dev/null 2>&1 || true
fi
if ! pgrep -x crond >/dev/null 2>&1; then
    crond -b
fi

echo "[4/4] Verifying required commands..."
missing=""
for tool in nft tc ss jq awk bc unzip cron crontab curl bash; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing="$missing $tool"
    fi
done

if [ -n "$missing" ]; then
    echo "Preinstall finished with missing commands:$missing"
    echo "Please install/repair them manually before running port-traffic-dog.sh"
    exit 1
fi

echo "Alpine preinstall complete. You can now run: ./port-traffic-dog.sh"
