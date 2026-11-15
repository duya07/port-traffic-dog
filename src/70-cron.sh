# ── 定时任务 ──────────────────────────────────────────────────────
# cron_sync 是唯一写入 Dog 定时任务的入口：先移除所有 Dog 行（含 1.5.x 旧格式），
# 再按当前配置生成。不碰其他任务，也不增删 PATH= 行（脚本自身已固定 PATH）。
#   * * * * *  --tick                每分钟：规则自检修复、到期封锁、周期重置、日统计、整机流量
#   @reboot    --boot                开机恢复 nft 计数与配额
#   <周期>     --send-status <通道>  状态报告（通道与定时报告均开启时）

readonly DOG_CRON_TAG="# port-traffic-dog"

read_root_crontab() {
    local out rc=0
    out=$(crontab -l 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        grep -qi "no crontab" <<< "$out" && return 0
        echo "读取 root crontab 失败：$out" >&2
        return 1
    fi
    printf '%s\n' "$out"
}

# 过滤掉 Dog 自己的行（新旧格式）。
filter_dog_cron_lines() {
    awk '
        /# port-traffic-dog/ { next }
        /端口流量狗/ { next }
        /port-traffic-dog\.sh[[:space:]]+--/ { next }
        /\/usr\/local\/bin\/dog[[:space:]]+--/ { next }
        { print }
    '
}

desired_dog_cron_lines() {
    local exe c expr
    has_monitors || return 0
    exe=$(get_script_exec_path)
    printf '* * * * * %s --tick >/dev/null 2>&1  %s tick\n' "$exe" "$DOG_CRON_TAG"
    printf '@reboot %s --boot >/dev/null 2>&1  %s boot\n' "$exe" "$DOG_CRON_TAG"
    for c in telegram wecom; do
        channel_status_enabled "$c" || continue
        expr=$(notification_interval_cron_expression "$(cfg ".notifications.${c}.status_notifications.interval // \"1h\"")") || continue
        printf '%s %s --send-status %s >/dev/null 2>&1  %s %s\n' "$expr" "$exe" "$c" "$DOG_CRON_TAG" "$c"
    done
}

cron_sync() {
    command -v crontab >/dev/null 2>&1 || { dog_error "未找到 crontab 命令，定时任务无法配置"; return 1; }
    local current desired next rc=0
    dog_lock || return 75
    if ! current=$(read_root_crontab); then
        dog_unlock; return 1
    fi
    desired=$(desired_dog_cron_lines)
    next=$(printf '%s\n' "$current" | filter_dog_cron_lines)
    if [ -n "$desired" ]; then
        if [ -n "$next" ]; then next=$(printf '%s\n%s' "$next" "$desired"); else next="$desired"; fi
    fi
    if [ "$next" != "$current" ]; then
        printf '%s\n' "$next" | crontab - || rc=1
    fi
    dog_unlock
    [ -n "$desired" ] && { ensure_cron_service_running || dog_error "cron 服务未运行，定时任务不会执行"; }
    return "$rc"
}

cron_remove_all() {
    command -v crontab >/dev/null 2>&1 || return 0
    local current
    current=$(read_root_crontab) || return 1
    printf '%s\n' "$current" | filter_dog_cron_lines | crontab -
}

# 自检：Dog 定时任务是否与期望一致。
cron_in_sync() {
    local current desired actual
    current=$(read_root_crontab 2>/dev/null) || return 1
    desired=$(desired_dog_cron_lines)
    actual=$(printf '%s\n' "$current" | grep -F "$DOG_CRON_TAG" || true)
    [ "$actual" = "$desired" ]
}

# 每分钟任务。任何一步失败都写入日志，不影响其他步骤。
cron_tick() {
    local failed=0 step
    config_exists || return 0
    validate_config_file "$CONFIG_FILE" 2>/dev/null || { log_notification "定时任务跳过：配置文件校验失败"; return 1; }
    has_monitors || { collect_machine_traffic >/dev/null 2>&1 || true; return 0; }
    # 交互操作持锁时最多等 40 秒，避免与菜单修改冲突；仍拿不到则跳过本轮。
    dog_lock 40 || { log_notification "定时任务跳过：另一个 Dog 进程持有锁"; return 0; }
    for step in runtime_ensure_nft check_expirations check_due_resets stats_snapshot; do
        if ! "$step" quiet >/dev/null 2>&1; then
            failed=1
            dog_log_event cron_task 1 "step=${step//_/-}"
        fi
    done
    dog_unlock
    collect_machine_traffic >/dev/null 2>&1 || true
    return "$failed"
}

cron_service_is_running() {
    if command -v systemctl >/dev/null 2>&1 &&
       (systemctl is-active --quiet cron 2>/dev/null ||
        systemctl is-active --quiet crond 2>/dev/null); then
        return 0
    fi
    command -v pgrep >/dev/null 2>&1 &&
        (pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1)
}

ensure_cron_service_running() {
    # Debian/Ubuntu
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable cron >/dev/null 2>&1 || systemctl enable crond >/dev/null 2>&1 || true
        systemctl start cron >/dev/null 2>&1 || systemctl start crond >/dev/null 2>&1 || true
        if systemctl is-active --quiet cron 2>/dev/null ||
           systemctl is-active --quiet crond 2>/dev/null; then
            return 0
        fi
    fi

    if command -v service >/dev/null 2>&1; then
        service cron start >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
    fi

    # Alpine/OpenRC
    if command -v rc-update >/dev/null 2>&1; then
        rc-update add crond default >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service crond start >/dev/null 2>&1 || true
        rc-service crond status >/dev/null 2>&1 && return 0
    fi
    if command -v crond >/dev/null 2>&1 && ! pgrep -x crond >/dev/null 2>&1; then
        crond -b >/dev/null 2>&1 || true
    fi
    # Debian 的 cron 在没有 systemd/service 入口的隔离或容器环境中仍可直接后台启动。
    if command -v cron >/dev/null 2>&1 && ! pgrep -x cron >/dev/null 2>&1; then
        cron >/dev/null 2>&1 || true
    fi

    cron_service_is_running
}
