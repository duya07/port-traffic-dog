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

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=== 迁移到自定义仓库版本 ==="
echo "目标仓库: ${REPO}"
echo "目标分支: ${BRANCH}"
echo

echo "[1/5] 备份旧配置与通知模块..."
mkdir -p "${BACKUP_DIR}"

if [ -d "${CONFIG_DIR}" ]; then
    cp -a "${CONFIG_DIR}" "${BACKUP_DIR}/port-traffic-dog-config"
    rm -rf "${BACKUP_DIR}/port-traffic-dog-config/config.lock" \
        "${BACKUP_DIR}/port-traffic-dog-config/traffic_stats.lock"
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

if crontab -l > "${BACKUP_DIR}/root.crontab.bak" 2>/dev/null; then
    echo "已备份: root crontab -> ${BACKUP_DIR}/root.crontab.bak"
else
    rm -f "${BACKUP_DIR}/root.crontab.bak"
fi

ports_before="[]"
if [ -f "${CONFIG_DIR}/config.json" ]; then
    if ! jq empty "${CONFIG_DIR}/config.json" >/dev/null 2>&1; then
        echo "错误: 现有配置不是有效 JSON，已停止迁移"
        exit 1
    fi
    ports_before="$(jq -cS '.ports // {} | keys' "${CONFIG_DIR}/config.json")"

    nft_family="$(jq -r '.nftables.family // "inet"' "${CONFIG_DIR}/config.json")"
    nft_table="$(jq -r '.nftables.table_name // "port_traffic_monitor"' "${CONFIG_DIR}/config.json")"
    if command -v nft >/dev/null 2>&1; then
        nft list table "${nft_family}" "${nft_table}" \
            > "${BACKUP_DIR}/nftables-table.bak" 2>/dev/null || \
            rm -f "${BACKUP_DIR}/nftables-table.bak"
    fi
fi

echo
echo "[2/5] 下载并校验全部目标文件..."
tmp_main="${TMP_DIR}/port-traffic-dog.sh"
tmp_tg="${TMP_DIR}/telegram.sh"
tmp_wc="${TMP_DIR}/wecom.sh"
download_to "${SCRIPT_URL}" "${tmp_main}"
download_to "${TELEGRAM_URL}" "${tmp_tg}"
download_to "${WECOM_URL}" "${tmp_wc}"

for script_file in "${tmp_main}" "${tmp_tg}" "${tmp_wc}"; do
    if [ ! -s "${script_file}" ] || ! bash -n "${script_file}"; then
        echo "错误: 下载文件为空或语法校验失败: ${script_file}"
        exit 1
    fi
done
if ! grep -q 'readonly SCRIPT_VERSION=' "${tmp_main}" || \
   ! grep -q '^setup_traffic_snapshot_cron()' "${tmp_main}"; then
    echo "错误: 主脚本内容校验失败"
    exit 1
fi
if ! grep -q '^telegram_send_status_notification()' "${tmp_tg}"; then
    echo "错误: Telegram 模块内容校验失败"
    exit 1
fi
if ! grep -q '^wecom_send_status_notification()' "${tmp_wc}"; then
    echo "错误: 企业微信模块内容校验失败"
    exit 1
fi
echo "下载与语法校验通过"

echo
echo "[3/5] 安装主脚本与通知模块..."
mkdir -p "${NOTIFICATIONS_DIR}"
install -m 755 "${tmp_main}" "${INSTALLED_SCRIPT_PATH}"
install -m 755 "${tmp_tg}" "${NOTIFICATIONS_DIR}/telegram.sh"
install -m 755 "${tmp_wc}" "${NOTIFICATIONS_DIR}/wecom.sh"
echo "已更新: ${INSTALLED_SCRIPT_PATH}"
echo "已更新: ${NOTIFICATIONS_DIR}/telegram.sh"
echo "已更新: ${NOTIFICATIONS_DIR}/wecom.sh"

echo
echo "[4/5] 重建 dog 快捷命令..."
cat > "${DOG_PATH}" <<'EOF'
#!/bin/bash
exec bash /usr/local/bin/port-traffic-dog.sh "$@"
EOF
chmod 755 "${DOG_PATH}"
echo "已更新: ${DOG_PATH}"

echo
echo "[5/5] 刷新定时任务、修复流量规则并执行自检..."
bash "${INSTALLED_SCRIPT_PATH}" --refresh-notification-cron >/dev/null
bash "${INSTALLED_SCRIPT_PATH}" --repair-traffic-rules >/dev/null
echo "已执行: --refresh-notification-cron"
echo "已执行: --repair-traffic-rules"

if crontab -l 2>/dev/null | grep -Eq \
    'port-traffic-dog.*--(send-snapshot|create-snapshot)|/etc/port-traffic-dog/data/snapshots'; then
    echo "错误: 仍检测到旧快照定时任务，已停止并保留备份供排查"
    exit 1
fi

ports_after="[]"
if [ -f "${CONFIG_DIR}/config.json" ]; then
    ports_after="$(jq -cS '.ports // {} | keys' "${CONFIG_DIR}/config.json")"
fi
if [ "${ports_before}" != "${ports_after}" ]; then
    echo "错误: 迁移前后端口清单不一致"
    echo "迁移前: ${ports_before}"
    echo "迁移后: ${ports_after}"
    exit 1
fi

if ! bash "${INSTALLED_SCRIPT_PATH}" --self-check; then
    echo "错误: 迁移后自检失败，备份目录: ${BACKUP_DIR}"
    exit 1
fi

echo
echo "迁移完成。"
echo "备份目录: ${BACKUP_DIR}"
echo
echo "当前版本："
bash "${INSTALLED_SCRIPT_PATH}" --version || true
echo
echo "建议执行自检："
echo "  dog --self-check"
