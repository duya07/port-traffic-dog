#!/bin/bash

set -euo pipefail

REPO="${REPO:-duya07/port-traffic-dog}"
BRANCH="${BRANCH:-main}"

SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/port-traffic-dog.sh"
TELEGRAM_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/telegram.sh"
WECOM_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/wecom.sh"

INSTALLED_SCRIPT_PATH="/usr/local/bin/port-traffic-dog.sh"
DOG_PATH="/usr/local/bin/dog"
CONFIG_DIR="/etc/port-traffic-dog"
NOTIFICATIONS_DIR="${CONFIG_DIR}/notifications"

timestamp="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/etc/port-traffic-dog-migration-backup/${timestamp}"

download_to() {
    local url="$1"
    local out="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url"
    else
        echo "错误: 需要 curl 或 wget"
        return 1
    fi
}

if [ "${EUID}" -ne 0 ]; then
    echo "错误: 请使用 root 运行"
    exit 1
fi

echo "=== 迁移到自定义仓库版本 ==="
echo "目标仓库: ${REPO}"
echo "目标分支: ${BRANCH}"
echo

echo "[1/4] 备份旧配置与通知模块..."
mkdir -p "${BACKUP_DIR}"

if [ -d "${CONFIG_DIR}" ]; then
    cp -a "${CONFIG_DIR}" "${BACKUP_DIR}/port-traffic-dog-config"
    echo "已备份: ${CONFIG_DIR} -> ${BACKUP_DIR}/port-traffic-dog-config"
else
    echo "未发现配置目录: ${CONFIG_DIR} (跳过)"
fi

if [ -f "${INSTALLED_SCRIPT_PATH}" ]; then
    cp -a "${INSTALLED_SCRIPT_PATH}" "${BACKUP_DIR}/port-traffic-dog.sh.bak"
    echo "已备份: ${INSTALLED_SCRIPT_PATH} -> ${BACKUP_DIR}/port-traffic-dog.sh.bak"
fi

if [ -f "${DOG_PATH}" ]; then
    cp -a "${DOG_PATH}" "${BACKUP_DIR}/dog.bak"
    echo "已备份: ${DOG_PATH} -> ${BACKUP_DIR}/dog.bak"
fi

echo
echo "[2/4] 下载并覆盖主脚本..."
tmp_main="$(mktemp)"
download_to "${SCRIPT_URL}" "${tmp_main}"
install -m 755 "${tmp_main}" "${INSTALLED_SCRIPT_PATH}"
rm -f "${tmp_main}"
echo "已更新: ${INSTALLED_SCRIPT_PATH}"

echo
echo "[3/4] 下载并覆盖通知模块..."
mkdir -p "${NOTIFICATIONS_DIR}"
tmp_tg="$(mktemp)"
tmp_wc="$(mktemp)"
download_to "${TELEGRAM_URL}" "${tmp_tg}"
download_to "${WECOM_URL}" "${tmp_wc}"
install -m 755 "${tmp_tg}" "${NOTIFICATIONS_DIR}/telegram.sh"
install -m 755 "${tmp_wc}" "${NOTIFICATIONS_DIR}/wecom.sh"
rm -f "${tmp_tg}" "${tmp_wc}"
echo "已更新: ${NOTIFICATIONS_DIR}/telegram.sh"
echo "已更新: ${NOTIFICATIONS_DIR}/wecom.sh"

echo
echo "[4/4] 重建 dog 快捷命令..."
cat > "${DOG_PATH}" <<'EOF'
#!/bin/bash
exec bash /usr/local/bin/port-traffic-dog.sh "$@"
EOF
chmod +x "${DOG_PATH}"
echo "已更新: ${DOG_PATH}"

echo
echo "迁移完成。"
echo "备份目录: ${BACKUP_DIR}"
echo
echo "建议执行自检："
echo "  dog --self-check"
