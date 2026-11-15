# ── 服务到期 ──────────────────────────────────────────────────────
# 到期日（北京时间）当天起，ptd_<id>_in/_out 链首插入 drop（comment "ptd_expired"），
# 覆盖该项全部端口的入站、出站和转发流量；规则引用端口映射，加减端口自动生效。
# 延期或取消后立即解除。每分钟 tick 检查一次，开机恢复时随整表重建。

monitor_set_expiry() {
    local id="$1" date="$2" rc=0
    if [ -n "$date" ] && ! is_valid_date "$date"; then
        dog_error "到期日格式应为 YYYY-MM-DD"
        return 1
    fi
    dog_lock || return 75
    config_update '.monitors[$id].expiry_date = $d' --arg id "$id" --arg d "$date" || rc=1
    [ "$rc" -eq 0 ] && { nft_sync_monitor "$id" || rc=1; }
    dog_unlock
    if monitor_is_expired "$id"; then
        dog_log_event expiry_apply "$rc" "id=$id"
    else
        dog_log_event expiry_clear "$rc" "id=$id"
    fi
    return "$rc"
}

# 对比配置与内核中的到期封锁状态，只同步不一致的监控项。
check_expirations() {
    local rt id want have failed=0
    rt=$(nft_runtime_json 2>/dev/null) || return 1
    [ "$rt" != "null" ] || return 1
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        want=false; monitor_is_expired "$id" && want=true
        have=$(jq -r --arg c "ptd_${id}_in" '(.chains[$c] // []) | any(. == "drop#ptd_expired")' <<< "$rt")
        [ "$want" = "$have" ] && continue
        if nft_sync_monitor "$id"; then
            if [ "$want" = "true" ]; then
                log_notification "监控项 $id（$(monitor_label "$id")）已到期，已封锁其端口流量"
                dog_log_event expiry_apply 0 "id=$id"
            else
                log_notification "监控项 $id（$(monitor_label "$id")）到期封锁已解除"
                dog_log_event expiry_clear 0 "id=$id"
            fi
        else
            failed=1
        fi
    done < <(monitor_ids)
    return "$failed"
}

monitor_expiry_label() {
    local id="$1" exp today days
    exp=$(mget "$id" .expiry_date "")
    [ -n "$exp" ] || return 1
    today=$(get_current_date)
    if date_le "$exp" "$today"; then
        echo "已到期:${exp}"
    else
        days=$(( $(date_to_ordinal "$exp") - $(date_to_ordinal "$today") ))
        echo "到期:${exp}(剩${days}天)"
    fi
}
