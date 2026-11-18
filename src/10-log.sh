# ── 日志 ──────────────────────────────────────────────────────────
# traffic.log 是结构化操作日志：只接收固定事件名、返回码和经过白名单校验的标量，
# 不写入通知正文、token 等敏感内容。notification.log 记录推送与告警摘要。

dog_write_event() (
    umask 077
    local event="$1" result="$2" field safe_fields="" directory index description
    [[ "$event" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || return 0
    [[ "$result" =~ ^[0-9]{1,3}$ ]] || return 0
    shift 2
    for field in "$@"; do
        case "$field" in
            id=*) [[ "${field#*=}" =~ ^m[0-9]{1,6}$ ]] || continue ;;
            port=*|ports=*) [[ "${field#*=}" =~ ^[0-9,-]{1,256}$ ]] || continue ;;
            rate=*) [[ "${field#*=}" =~ ^[0-9]+([kKmMgG]?[bB]it|[KMG]bps)?$ ]] || continue ;;
            mode=*|step=*) [[ "${field#*=}" =~ ^[a-z_-]{1,32}$ ]] || continue ;;
            *) continue ;;
        esac
        safe_fields+=" $field"
    done
    directory=$(dirname "$LOG_FILE")
    [ ! -L "$directory" ] && [ ! -L "$LOG_FILE" ] && [ ! -L "$LOG_FILE.lock" ] || return 1
    mkdir -p "$directory" || return 1
    chmod 700 "$directory" || return 1
    exec 7>>"$LOG_FILE.lock" || return 1
    chmod 600 "$LOG_FILE.lock" || return 1
    flock -x -w 2 7 || return 1
    for index in 1 2 3; do [ ! -L "$LOG_FILE.$index" ] || return 1; done
    if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE")" -ge 1048576 ]; then
        rm -f "$LOG_FILE.3" || return 1
        for index in 2 1; do
            if [ -f "$LOG_FILE.$index" ]; then mv -f "$LOG_FILE.$index" "$LOG_FILE.$((index+1))" || return 1; fi
        done
        mv -f "$LOG_FILE" "$LOG_FILE.1" || return 1
    fi
    case "$event" in
        config_update) description="保存配置" ;;
        monitor_add) description="添加监控项" ;;
        monitor_remove) description="删除监控项" ;;
        monitor_edit) description="修改监控项端口" ;;
        monitor_split) description="拆分监控项" ;;
        monitor_merge) description="合并监控项" ;;
        monitor_notify) description="设置监控项推送开关" ;;
        tc_apply) description="应用带宽限制" ;;
        tc_clear) description="撤销带宽限制" ;;
        expiry_apply) description="应用服务到期封锁" ;;
        expiry_clear) description="解除服务到期封锁" ;;
        traffic_reset) description="重置流量" ;;
        quota_apply) description="应用流量配额" ;;
        install) description="安装或更新 Dog" ;;
        install_rollback) description="恢复更新前的 Dog 文件和状态" ;;
        migrate) description="从 1.5.x 迁移配置与流量" ;;
        runtime_restore) description="恢复监控规则和限速" ;;
        import_config) description="导入配置并恢复运行状态" ;;
        export_config) description="导出配置备份" ;;
        cron_task) description="定时任务" ;;
        dependency_install) description="安装并复检缺失依赖" ;;
        dependency_remove) description="按确认计划卸载依赖" ;;
        *) description="记录操作" ;;
    esac
    if [ "$result" -eq 0 ]; then description+="：成功"; else description+="：失败（返回码 $result）"; fi
    printf '%s %s%s event=%s result=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$description" "$safe_fields" "$event" "$result" >> "$LOG_FILE" || return 1
    chmod 600 "$LOG_FILE" || return 1
)

dog_log_event() {
    if ! dog_write_event "$@"; then
        echo "警告：Dog 操作日志写入失败，业务返回状态保持原值。" >&2
    fi
    return 0
}

# 通知与告警摘要日志（人类可读，按大小轮转）。
log_notification() {
    local message="$1"
    mkdir -p "$LOG_DIR" 2>/dev/null || return 0
    if [ -f "$NOTIFY_LOG_FILE" ] && [ "$(stat -c %s "$NOTIFY_LOG_FILE" 2>/dev/null || echo 0)" -ge 524288 ]; then
        tail -n 1000 "$NOTIFY_LOG_FILE" 2>/dev/null | atomic_write "$NOTIFY_LOG_FILE" 600 || true
    fi
    printf '[%s] %s\n' "$(beijing_date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$NOTIFY_LOG_FILE" 2>/dev/null || true
    chmod 600 "$NOTIFY_LOG_FILE" 2>/dev/null || true
}

# 打印错误到 stderr，并写入通知日志，cron 下失败也能看到原因。
dog_error() {
    echo -e "${RED}$*${NC}" >&2
    log_notification "错误：$*"
}

show_operation_logs() {
    local file
    for file in "$LOG_FILE" "$LOG_DIR/ip-guard.log" "$NOTIFY_LOG_FILE"; do
        ui_title "${file##*/}" "最近 50 条"
        if [ -f "$file" ] && [ ! -L "$file" ]; then
            if [[ "$file" == */ip-guard.log ]]; then
                tail -n 50 -- "$file" | jq -r '"\(.time) \(.message // .event)"' 2>/dev/null || tail -n 50 -- "$file"
            else tail -n 50 -- "$file"; fi
        else echo '  暂无日志'; fi
    done
}
