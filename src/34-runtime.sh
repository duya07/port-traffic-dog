# ── 运行状态灾备与恢复 ────────────────────────────────────────────
# traffic_data.json：{schema:2, saved_at, monitors:{id:{in,out,quota_used}}}（原始字节）。
# 重启后 nft 计数丢失，按此文件恢复。任何读取失败都不会删除或清空该文件。

traffic_backup_values() {
    [ -s "$TRAFFIC_DATA_FILE" ] || { echo '{}'; return 0; }
    jq -c 'if .schema == 2 then (.monitors // {}) else {} end' "$TRAFFIC_DATA_FILE" 2>/dev/null || echo '{}'
}

# 写入灾备。$1 为 nft_read_values 的结果；只保留配置中存在的监控项。
traffic_backup_write() {
    local values="$1" ids
    ids=$(jq -c '.monitors | keys' "$CONFIG_FILE" 2>/dev/null) || return 1
    jq -n --argjson v "$values" --argjson ids "$ids" --arg at "$(date -u +%FT%TZ)" \
        '{schema: 2, saved_at: $at, monitors: ($v | with_entries(select(.key as $k | $ids | index($k))))}' |
        atomic_write "$TRAFFIC_DATA_FILE" 600
}

traffic_backup_save() {
    nft_table_exists || return 1
    traffic_backup_write "$(nft_read_values)"
}

traffic_backup_drop_monitor() {
    [ -s "$TRAFFIC_DATA_FILE" ] || return 0
    json_update "$TRAFFIC_DATA_FILE" 'del(.monitors[$id])' --arg id "$1"
}

# 规则缺失或与配置不一致时按配置重建（保留计数）。$1=quiet 时不打印；$2=boot 表示开机恢复。
# 开机时表本来就不存在：记为“开机恢复”而不是“规则漂移”，免得每天的重启日志读起来像故障。
# 先重建、再按结果记日志：重建失败时不能写“已重建”。
runtime_ensure_nft() {
    local drift saved="" rc=0
    has_monitors || return 0
    drift=$(nft_runtime_drift 2>/dev/null) && return 0
    if [ "${2:-}" = boot ] && ! nft_table_exists; then
        saved=$(jq -r 'if .schema == 2 then (.saved_at // empty) else empty end' "$TRAFFIC_DATA_FILE" 2>/dev/null || true)
        nft_rebuild_all || rc=$?
        if [ "$rc" -ne 0 ]; then
            log_notification "开机恢复失败：按配置重建 nftables 规则未成功（返回码 $rc），请运行 dog --repair"
        elif [ -n "$saved" ]; then
            saved=$(beijing_date -d "$saved" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$saved")
            log_notification "开机恢复：已按配置重建 nftables 规则，计数从灾备恢复（灾备时间 $saved）"
        else
            log_notification "开机恢复：已按配置重建 nftables 规则（没有可用灾备，计数从 0 开始）"
        fi
        return "$rc"
    fi
    [ "${1:-}" = "quiet" ] || echo -e "${YELLOW}检测到 nftables 规则与配置不一致，正在按配置修复：${NC}\n$drift" >&2
    nft_rebuild_all || rc=$?
    if [ "$rc" -eq 0 ]; then
        log_notification "nftables 规则漂移，已自动重建：${drift//$'\n'/；}"
    else
        log_notification "nftables 规则漂移，自动重建失败（返回码 $rc）：${drift//$'\n'/；}"
    fi
    return "$rc"
}

# 完整恢复：nft 计数/配额/到期 + TC 限速。
restore_runtime() {
    local rc=0
    dog_lock || return 75
    runtime_ensure_nft quiet || rc=1
    stats_rebaseline_all || true
    if [ "$rc" -eq 0 ]; then
        tc_restore_all || rc=1
    fi
    dog_unlock
    dog_log_event runtime_restore "$rc"
    return "$rc"
}

# 开机恢复：只恢复 nft（TC 交给共享恢复服务）。
restore_runtime_nft_only() {
    local rc=0
    dog_lock || return 75
    runtime_ensure_nft quiet boot || rc=1
    stats_rebaseline_all || true
    dog_unlock
    dog_log_event runtime_restore "$rc" mode=nft-only
    return "$rc"
}
