# ── 监控项增删改 ──────────────────────────────────────────────────
# 所有操作在 Dog 锁内执行：先校验 → 写配置 → 提交 nft 事务；nft 失败时恢复原配置。
# 端口变化只增删 nft 映射元素，因此流量计数与已用配额保持连续。

# 备份当前配置文本，供失败时恢复。
_config_snapshot() { cat "$CONFIG_FILE"; }
_config_restore() { printf '%s\n' "$1" | atomic_write "$CONFIG_FILE" 600; }

# 新建监控项。$1=规范化逗号串，$2=备注。成功时输出新 ID。
monitor_add() {
    local csv="$1" remark="${2:-}" ports conflict id snap now
    ports=$(ports_csv_to_json "$csv")
    dog_lock || return 75
    if conflict=$(find_port_conflict "$ports") && [ -n "$conflict" ]; then
        dog_unlock
        read -r cid cport cnew <<< "$conflict"
        dog_error "端口 $cnew 与监控项 $cid 的 $cport 重叠"
        return 1
    fi
    snap=$(_config_snapshot)
    id=$(next_monitor_id)
    now=$(beijing_date '+%Y-%m-%dT%H:%M:%S+08:00')
    if ! config_update '
        .monitors[$id] = {ports: $p, remark: $r, billing_mode: (.global.billing_mode // "double"),
                          quota: {enabled: false, monthly_limit: "unlimited"},
                          bandwidth_limit: {enabled: false, rate: "unlimited"},
                          reset_policy: {type: "none"}, expiry_date: "", created_at: $now} |
        .global.next_monitor_id = (($id | ltrimstr("m") | tonumber) + 1)
    ' --arg id "$id" --argjson p "$ports" --arg r "$remark" --arg now "$now"; then
        dog_unlock; return 1
    fi
    if ! nft_add_monitor "$id"; then
        _config_restore "$snap"
        dog_unlock
        dog_log_event monitor_add 1 "id=$id" "ports=$csv"
        return 1
    fi
    stats_rebaseline "$id" 0 0 || true
    dog_unlock
    dog_log_event monitor_add 0 "id=$id" "ports=$csv"
    echo "$id"
}

monitor_remove() {
    local id="$1" rc=0 snap
    dog_lock || return 75
    monitor_exists "$id" || { dog_unlock; dog_error "监控项 $id 不存在"; return 1; }
    stats_snapshot >/dev/null 2>&1 || true
    snap=$(_config_snapshot)
    if monitor_tc_rate "$id" >/dev/null; then
        # 拿不到共享 TC 锁就中止：否则配置删掉了、内核里留下孤儿类。
        begin_tc_update || { dog_unlock; dog_error "无法取得 TC 锁，未删除 $id"; return 1; }
        tc_remove_monitor_locked "$id" || true
        tc_write_interop "$id" || true
        finish_tc_update
    fi
    if ! nft_remove_monitor "$id"; then
        dog_unlock; dog_log_event monitor_remove 1 "id=$id"; return 1
    fi
    if ! config_update 'del(.monitors[$id])' --arg id "$id"; then
        _config_restore "$snap"; nft_rebuild_all || true
        dog_unlock; dog_log_event monitor_remove 1 "id=$id"; return 1
    fi
    stats_drop_monitor "$id" || true
    traffic_backup_drop_monitor "$id" || true
    reset_history_drop "$id" || true
    tc_write_interop || true
    dog_unlock
    dog_log_event monitor_remove "$rc" "id=$id"
    return "$rc"
}

# 修改端口。$2=要加的逗号串，$3=要删的逗号串，$4=整组替换的逗号串（非空时忽略 2/3）。
monitor_edit_ports() {
    local id="$1" add_csv="${2:-}" del_csv="${3:-}" set_csv="${4:-}" old new tmp conflict snap missing
    dog_lock || return 75
    monitor_exists "$id" || { dog_unlock; dog_error "监控项 $id 不存在"; return 1; }
    old=$(jq -c --arg id "$id" '.monitors[$id].ports' "$CONFIG_FILE")
    if [ -n "$set_csv" ]; then
        new=$(ports_csv_to_json "$set_csv")
    else
        new="$old"
        if [ -n "$del_csv" ]; then
            tmp=$(ports_csv_to_json "$del_csv")
            missing=$(jq -rn --argjson a "$tmp" --argjson b "$old" '$a - $b | join(",")')
            if [ -n "$missing" ]; then
                dog_unlock
                dog_error "监控项 $id 不包含成员：$missing（端口段需按原样整体删除，如 8000-8010）"
                return 1
            fi
            new=$(ports_json_minus "$new" "$tmp")
        fi
        [ -n "$add_csv" ] && new=$(ports_json_union "$new" "$(ports_csv_to_json "$add_csv")")
    fi
    if [ "$(jq 'length' <<< "$new")" -eq 0 ]; then
        dog_unlock
        dog_error "监控项至少保留一个端口；如需移除整个监控项，请使用删除"
        return 1
    fi
    if ! new=$(ports_json_normalize "$new"); then
        dog_unlock; return 1
    fi
    if conflict=$(find_port_conflict "$new" "$id") && [ -n "$conflict" ]; then
        dog_unlock
        read -r cid cport cnew <<< "$conflict"
        dog_error "端口 $cnew 与监控项 $cid 的 $cport 重叠"
        return 1
    fi
    if [ "$new" = "$old" ]; then
        dog_unlock; echo "端口未变化"; return 0
    fi
    snap=$(_config_snapshot)
    config_update '.monitors[$id].ports = $p' --arg id "$id" --argjson p "$new" || { dog_unlock; return 1; }
    if ! nft_change_ports "$id" "$old" "$new"; then
        _config_restore "$snap"
        dog_unlock
        dog_log_event monitor_edit 1 "id=$id"
        return 1
    fi
    tc_refresh_monitor_ports "$id" || log_notification "监控项 $id 端口已更新，但入向限速过滤器刷新失败，请运行 dog --repair"
    tc_write_interop || true
    dog_unlock
    dog_log_event monitor_edit 0 "id=$id" "ports=$(jq -r 'join(",")' <<< "$new")"
}

# 拆分：把 $2（成员逗号串）移到新监控项。$3=备注，$4=copy 时复制配额/重置/到期设置。
# 计费模式与推送开关总是继承：拆分不改变“谁能看到这些端口”，已关闭推送的端口拆出后不应突然出现在推送里。
monitor_split() {
    local id="$1" move_csv="$2" remark="${3:-}" copy="${4:-}" old move rest new_id snap rt now missing
    dog_lock || return 75
    monitor_exists "$id" || { dog_unlock; dog_error "监控项 $id 不存在"; return 1; }
    old=$(jq -c --arg id "$id" '.monitors[$id].ports' "$CONFIG_FILE")
    move=$(ports_csv_to_json "$move_csv")
    missing=$(jq -rn --argjson a "$move" --argjson b "$old" '$a - $b | join(",")')
    if [ -n "$missing" ]; then
        dog_unlock; dog_error "监控项 $id 不包含成员：$missing"; return 1
    fi
    rest=$(ports_json_minus "$old" "$move")
    if [ "$(jq 'length' <<< "$rest")" -eq 0 ]; then
        dog_unlock; dog_error "拆分后原监控项不能为空"; return 1
    fi
    snap=$(_config_snapshot)
    new_id=$(next_monitor_id)
    now=$(beijing_date '+%Y-%m-%dT%H:%M:%S+08:00')
    config_update '
        .monitors[$id] as $src |
        .monitors[$id].ports = $rest |
        .monitors[$nid] = {ports: $move, remark: $r, billing_mode: ($src.billing_mode // "double"),
            quota: (if $copy then ($src.quota // {enabled: false, monthly_limit: "unlimited"}) else {enabled: false, monthly_limit: "unlimited"} end),
            bandwidth_limit: {enabled: false, rate: "unlimited"},
            reset_policy: (if $copy then ($src.reset_policy // {type: "none"}) else {type: "none"} end),
            expiry_date: (if $copy then ($src.expiry_date // "") else "" end), created_at: $now} +
            (if $src.notify == false then {notify: false} else {} end) |
        .global.next_monitor_id = (($nid | ltrimstr("m") | tonumber) + 1)
    ' --arg id "$id" --arg nid "$new_id" --argjson rest "$rest" --argjson move "$move" \
      --arg r "$remark" --arg now "$now" --argjson copy "$([ "$copy" = copy ] && echo true || echo false)" ||
        { dog_unlock; return 1; }
    rt=$(nft_runtime_json 2>/dev/null || echo null)
    if [ "$rt" = "null" ] || ! {
            nft_render_elements delete "$id" "$move" "$(monitor_tc_mark "$id" >/dev/null && echo with_mark)"
            nft_render_monitor "$new_id" 0 0 0
        } | nft_apply; then
        _config_restore "$snap"
        dog_unlock; dog_log_event monitor_split 1 "id=$id"; return 1
    fi
    stats_rebaseline "$new_id" 0 0 || true
    tc_refresh_monitor_ports "$id" || true
    tc_write_interop || true
    dog_unlock
    dog_log_event monitor_split 0 "id=$id" "ports=$(jq -r 'join(",")' <<< "$move")"
    echo "$new_id"
}

# 合并：把 $1 并入 $2。计数与已用配额相加，日统计按日期相加；$2 的配额/限速/到期设置保留。
monitor_merge() {
    local src="$1" dst="$2" snap rt sv dv si so su di dout du merged src_tc=false
    [ "$src" != "$dst" ] || { dog_error "不能合并到自身"; return 1; }
    dog_lock || return 75
    monitor_exists "$src" && monitor_exists "$dst" || { dog_unlock; dog_error "监控项不存在"; return 1; }
    stats_snapshot >/dev/null 2>&1 || true
    rt=$(nft_runtime_json 2>/dev/null || echo null)
    [ "$rt" != "null" ] || { dog_unlock; dog_error "nftables 规则缺失，请先运行 dog --repair"; return 1; }
    sv=$(nft_read_monitor "$src" 2>/dev/null || echo "0 0 0"); read -r si so su <<< "$sv"
    dv=$(nft_read_monitor "$dst" 2>/dev/null || echo "0 0 0"); read -r di dout du <<< "$dv"
    monitor_tc_rate "$src" >/dev/null && src_tc=true
    snap=$(_config_snapshot)
    merged=$(jq -c --arg s "$src" --arg d "$dst" '.monitors[$d].ports + .monitors[$s].ports' "$CONFIG_FILE")
    merged=$(ports_json_normalize "$merged") || { dog_unlock; return 1; }
    config_update '.monitors[$d].ports = $p | del(.monitors[$s])' \
        --arg s "$src" --arg d "$dst" --argjson p "$merged" || { dog_unlock; return 1; }
    if ! {
            nft_render_remove_monitor "$src" "$rt"
            nft_render_sync_monitor "$dst" $((si + di)) $((so + dout)) $((su + du)) "$rt"
        } | nft_apply; then
        _config_restore "$snap"
        dog_unlock; dog_log_event monitor_merge 1 "id=$dst"; return 1
    fi
    if [ "$src_tc" = "true" ] && begin_tc_update; then
        # 合并后源监控项已不在配置中；若锁暂不可得，孤儿类由下次 --repair 清理。
        tc_remove_monitor_locked "$src" || true
        tc_write_interop "$src" || true
        finish_tc_update
    fi
    tc_refresh_monitor_ports "$dst" || true
    stats_merge_monitor "$src" "$dst" || true
    stats_rebaseline "$dst" $((si + di)) $((so + dout)) || true
    traffic_backup_save || true
    reset_history_drop "$src" || true
    tc_write_interop || true
    dog_unlock
    dog_log_event monitor_merge 0 "id=$dst"
}

monitor_set_remark() {
    local id="$1" remark="$2"
    [ "${#remark}" -le 64 ] || { dog_error "备注最长 64 个字符"; return 1; }
    config_update '.monitors[$id].remark = $r' --arg id "$id" --arg r "$remark"
}

# 设置配额：$2 为 "300GB" 之类或 0（取消）。
monitor_set_quota() {
    local id="$1" limit="$2" rc=0
    if [ "$limit" != "0" ]; then
        validate_quota "$limit" || { dog_error "配额格式无效，示例：500GB、1.5TB、800MB"; return 1; }
        limit="${limit^^}"
    fi
    dog_lock || return 75
    if [ "$limit" = "0" ]; then
        config_update '.monitors[$id].quota.enabled = false | .monitors[$id].quota.monthly_limit = "unlimited"' --arg id "$id" || rc=1
    else
        config_update '.monitors[$id].quota.enabled = true | .monitors[$id].quota.monthly_limit = $l' \
            --arg id "$id" --arg l "$limit" || rc=1
    fi
    [ "$rc" -eq 0 ] && { nft_sync_monitor "$id" || rc=1; }
    dog_unlock
    dog_log_event quota_apply "$rc" "id=$id"
    return "$rc"
}

# 计费模式：double（入站+出站，各×2，与上游一致）| single（入站+出站，×1）。
# 计数器只记原始字节，切换模式只改倍率与配额阈值，不改写计数。
monitor_set_billing() {
    local id="$1" mode="$2" rc=0
    case "$mode" in single|double) ;; *) dog_error "计费模式只能是 single 或 double"; return 1 ;; esac
    dog_lock || return 75
    config_update '.monitors[$id].billing_mode = $m' --arg id "$id" --arg m "$mode" || rc=1
    [ "$rc" -eq 0 ] && { nft_sync_monitor "$id" || rc=1; }
    dog_unlock
    dog_log_event config_update "$rc" "id=$id" "mode=$mode"
    return "$rc"
}

# 推送开关：$2 = on | off。只影响状态报告是否包含该监控项，不改变统计、配额与定时任务。
monitor_set_notify() {
    local id="$1" value rc=0
    case "$2" in on) value=true ;; off) value=false ;; *) dog_error "推送开关只能是 on 或 off"; return 1 ;; esac
    monitor_exists "$id" || { dog_error "监控项 $id 不存在"; return 1; }
    config_update '.monitors[$id].notify = $v' --arg id "$id" --argjson v "$value" || rc=1
    dog_log_event monitor_notify "$rc" "id=$id" "mode=$2"
    return "$rc"
}

# 批量设置推送开关（菜单勾选用，一次写入）：$1 = {"m1":true,"m2":false}，只传有变化的项。
monitors_set_notify() {
    local changes="$1" rc=0 id value
    config_update 'reduce ($c | to_entries[]) as $e (.;
        if .monitors[$e.key] != null then .monitors[$e.key].notify = $e.value else . end)' --argjson c "$changes" || rc=1
    while IFS=$'\t' read -r id value; do
        [ -n "$id" ] || continue
        if [ "$value" = true ]; then value=on; else value=off; fi
        dog_log_event monitor_notify "$rc" "id=$id" "mode=$value"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<< "$changes")
    return "$rc"
}
