#!/bin/bash

set -euo pipefail
umask 077

REPO="${REPO:-duya07/port-traffic-dog}"
BRANCH="${BRANCH:-main}"

SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/port-traffic-dog.sh"
TELEGRAM_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/telegram.sh"
WECOM_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/wecom.sh"

INSTALLED_SCRIPT_PATH="/usr/local/bin/port-traffic-dog.sh"
DOG_PATH="/usr/local/bin/dog"
CONFIG_DIR="/etc/port-traffic-dog"
NOTIFICATIONS_DIR="${CONFIG_DIR}/notifications"
CRON_LOCK_DIR="${CONFIG_DIR}/cron.lock"
CRON_LOCK_MAX_AGE=86400

timestamp="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/etc/port-traffic-dog-migration-backup/${timestamp}"
had_config=false
had_script=false
had_dog=false
had_crontab=false
install_started=false
migration_complete=false
nft_family="inet"
nft_table="port_traffic_monitor"
cron_lock_held=false

download_to() {
    local url="$1"
    local out="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$out"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 60 -O "$out" "$url"
    else
        echo "错误: 需要 curl 或 wget"
        return 1
    fi
}

acquire_cron_lock() {
    local current_pid="${BASHPID:-$$}"
    mkdir -p "${CONFIG_DIR}"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if mkdir "${CRON_LOCK_DIR}" 2>/dev/null; then
            local current_boot_id="-"
            local current_start_time="-"
            [ -r /proc/sys/kernel/random/boot_id ] && \
                current_boot_id=$(tr -d '\r\n' < /proc/sys/kernel/random/boot_id)
            [ -r "/proc/${current_pid}/stat" ] && \
                current_start_time=$(awk '{print $22}' "/proc/${current_pid}/stat" 2>/dev/null || echo "-")
            if printf '%s %s %s %s\n' \
                "${current_pid}" "$(date +%s)" "${current_boot_id}" "${current_start_time}" \
                > "${CRON_LOCK_DIR}/owner"; then
                cron_lock_held=true
                return 0
            fi
            rm -f "${CRON_LOCK_DIR}/owner" 2>/dev/null || true
            rmdir "${CRON_LOCK_DIR}" 2>/dev/null || true
        else
            local owner_pid=""
            local owner_time=""
            local owner_boot_id=""
            local owner_start_time=""
            local stale_lock=false
            if read -r owner_pid owner_time owner_boot_id owner_start_time \
                2>/dev/null < "${CRON_LOCK_DIR}/owner"; then
                local now current_boot_id="" current_start_time="" boot_epoch=""
                now=$(date +%s)
                if ! [[ "${owner_pid}" =~ ^[0-9]+$ ]] || \
                   ! [[ "${owner_time}" =~ ^[0-9]+$ ]] || \
                   ! kill -0 "${owner_pid}" 2>/dev/null || \
                   [ "${now}" -lt "${owner_time}" ]; then
                    stale_lock=true
                else
                    [ -r /proc/sys/kernel/random/boot_id ] && \
                        current_boot_id=$(tr -d '\r\n' < /proc/sys/kernel/random/boot_id)
                    [ -r "/proc/${owner_pid}/stat" ] && \
                        current_start_time=$(awk '{print $22}' "/proc/${owner_pid}/stat" 2>/dev/null || true)
                    if [ -n "${owner_boot_id}" ] && [ "${owner_boot_id}" != "-" ] && \
                       [ -n "${current_boot_id}" ] && [ "${owner_boot_id}" != "${current_boot_id}" ]; then
                        stale_lock=true
                    elif [ -n "${owner_start_time}" ] && [ "${owner_start_time}" != "-" ] && \
                         [ -n "${current_start_time}" ] && [ "${owner_start_time}" != "${current_start_time}" ]; then
                        stale_lock=true
                    elif [ -z "${owner_boot_id}" ] || [ "${owner_boot_id}" = "-" ]; then
                        boot_epoch=$(awk '$1 == "btime" {print $2; exit}' /proc/stat 2>/dev/null || true)
                        if [[ "${boot_epoch}" =~ ^[0-9]+$ ]] && [ "${owner_time}" -lt "${boot_epoch}" ]; then
                            stale_lock=true
                        elif [ $((now - owner_time)) -gt "${CRON_LOCK_MAX_AGE}" ]; then
                            stale_lock=true
                        fi
                    fi
                fi
            else
                sleep 1
                [ -s "${CRON_LOCK_DIR}/owner" ] || stale_lock=true
            fi
            if [ "${stale_lock}" = "true" ]; then
                rm -f "${CRON_LOCK_DIR}/owner" 2>/dev/null || true
                rmdir "${CRON_LOCK_DIR}" 2>/dev/null || true
                continue
            fi
        fi
        sleep 1
    done
    return 1
}

release_cron_lock() {
    local current_pid="${BASHPID:-$$}"
    local owner_pid=""
    local owner_time=""
    local owner_boot_id=""
    local owner_start_time=""
    [ "${cron_lock_held}" = "true" ] || return 0
    read -r owner_pid owner_time owner_boot_id owner_start_time \
        2>/dev/null < "${CRON_LOCK_DIR}/owner" || true
    if [ "${owner_pid}" = "${current_pid}" ] && \
       { [ -z "${owner_boot_id}" ] || [ "${owner_boot_id}" = "-" ] || \
         [ ! -r /proc/sys/kernel/random/boot_id ] || \
         [ "${owner_boot_id}" = "$(tr -d '\r\n' < /proc/sys/kernel/random/boot_id)" ]; } && \
       { [ -z "${owner_start_time}" ] || [ "${owner_start_time}" = "-" ] || \
         [ ! -r "/proc/${current_pid}/stat" ] || \
         [ "${owner_start_time}" = "$(awk '{print $22}' "/proc/${current_pid}/stat" 2>/dev/null)" ]; }; then
        rm -f "${CRON_LOCK_DIR}/owner" 2>/dev/null || true
        rmdir "${CRON_LOCK_DIR}" 2>/dev/null || true
    fi
    cron_lock_held=false
}

if [ "${EUID}" -ne 0 ]; then
    echo "错误: 请使用 root 运行"
    exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
    local result=$?
    release_cron_lock
    if [ "${install_started}" = "true" ] && [ "${migration_complete}" != "true" ]; then
        set +e
        echo
        echo "迁移失败，正在恢复迁移前状态..."

        rm -f "${INSTALLED_SCRIPT_PATH}" "${DOG_PATH}"
        rm -rf "${CONFIG_DIR}"
        [ "${had_script}" = "true" ] &&
            cp -a "${BACKUP_DIR}/port-traffic-dog.sh.bak" "${INSTALLED_SCRIPT_PATH}"
        [ "${had_dog}" = "true" ] && cp -a "${BACKUP_DIR}/dog.bak" "${DOG_PATH}"
        [ "${had_config}" = "true" ] &&
            cp -a "${BACKUP_DIR}/port-traffic-dog-config" "${CONFIG_DIR}"
        rm -rf "${CONFIG_DIR}/config.lock" "${CONFIG_DIR}/traffic_stats.lock" \
            "${CONFIG_DIR}/reset.lock"

        if acquire_cron_lock; then
            if [ "${had_crontab}" = "true" ]; then
                crontab "${BACKUP_DIR}/root.crontab.bak"
            else
                crontab -r 2>/dev/null || true
            fi
            release_cron_lock
        fi

        if command -v nft >/dev/null 2>&1; then
            nft delete table "${nft_family}" "${nft_table}" >/dev/null 2>&1 || true
            [ -f "${BACKUP_DIR}/nftables-table.bak" ] &&
                nft -f "${BACKUP_DIR}/nftables-table.bak" >/dev/null 2>&1
        fi
        echo "已尝试恢复；迁移备份保留在: ${BACKUP_DIR}"
    fi
    rm -rf "${TMP_DIR}"
    return "${result}"
}
trap cleanup EXIT

echo "=== 迁移到自定义仓库版本 ==="
echo "目标仓库: ${REPO}"
echo "目标分支: ${BRANCH}"
echo

echo "[1/5] 备份旧配置与通知模块..."
mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

if [ -d "${CONFIG_DIR}" ]; then
    had_config=true
    cp -a "${CONFIG_DIR}" "${BACKUP_DIR}/port-traffic-dog-config"
    rm -rf "${BACKUP_DIR}/port-traffic-dog-config/config.lock" \
        "${BACKUP_DIR}/port-traffic-dog-config/traffic_stats.lock" \
        "${BACKUP_DIR}/port-traffic-dog-config/reset.lock" \
        "${BACKUP_DIR}/port-traffic-dog-config/cron.lock"
    chmod 600 "${BACKUP_DIR}/port-traffic-dog-config/config.json" 2>/dev/null || true
    echo "已备份: ${CONFIG_DIR} -> ${BACKUP_DIR}/port-traffic-dog-config"
else
    echo "未发现配置目录: ${CONFIG_DIR} (跳过)"
fi

if [ -f "${INSTALLED_SCRIPT_PATH}" ]; then
    had_script=true
    cp -a "${INSTALLED_SCRIPT_PATH}" "${BACKUP_DIR}/port-traffic-dog.sh.bak"
    echo "已备份: ${INSTALLED_SCRIPT_PATH} -> ${BACKUP_DIR}/port-traffic-dog.sh.bak"
fi

if [ -f "${DOG_PATH}" ]; then
    had_dog=true
    cp -a "${DOG_PATH}" "${BACKUP_DIR}/dog.bak"
    echo "已备份: ${DOG_PATH} -> ${BACKUP_DIR}/dog.bak"
fi

acquire_cron_lock || { echo "错误: 无法取得Dog crontab锁"; exit 1; }
if crontab -l > "${BACKUP_DIR}/root.crontab.bak" 2>/dev/null; then
    had_crontab=true
    echo "已备份: root crontab -> ${BACKUP_DIR}/root.crontab.bak"
else
    rm -f "${BACKUP_DIR}/root.crontab.bak"
fi
release_cron_lock

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
if [ -f "${CONFIG_DIR}/config.json" ] &&
   ! bash "${tmp_main}" --validate-config "${CONFIG_DIR}/config.json"; then
    echo "错误: 当前配置无法被目标版本安全读取，已停止迁移"
    exit 1
fi
echo "下载与语法校验通过"

echo
echo "[3/5] 安装主脚本与通知模块..."
install_started=true
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
bash "${INSTALLED_SCRIPT_PATH}" --refresh-all-cron >/dev/null
bash "${INSTALLED_SCRIPT_PATH}" --repair-traffic-rules >/dev/null
bash "${INSTALLED_SCRIPT_PATH}" --restore-runtime >/dev/null
echo "已执行: --refresh-all-cron"
echo "已执行: --repair-traffic-rules"
echo "已执行: --restore-runtime"

acquire_cron_lock || { echo "错误: 无法取得Dog crontab锁"; exit 1; }
current_root_cron=$(crontab -l 2>/dev/null || true)
release_cron_lock
if printf '%s\n' "${current_root_cron}" | grep -Eq \
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
if [ "$(jq 'length' <<< "${ports_after}")" -gt 0 ] &&
   ! printf '%s\n' "${current_root_cron}" | grep -q 'port-traffic-dog.*--restore-runtime'; then
    echo "错误: 迁移后缺少开机运行时恢复任务"
    exit 1
fi

if ! bash "${INSTALLED_SCRIPT_PATH}" --self-check; then
    echo "错误: 迁移后自检失败，备份目录: ${BACKUP_DIR}"
    exit 1
fi

migration_complete=true
echo
echo "迁移完成。"
echo "备份目录: ${BACKUP_DIR}"
echo
echo "当前版本："
bash "${INSTALLED_SCRIPT_PATH}" --version || true
echo
echo "建议执行自检："
echo "  dog --self-check"
