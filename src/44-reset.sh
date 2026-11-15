# ── 周期重置 ──────────────────────────────────────────────────────
# 策略保存在 .monitors[id].reset_policy：
#   monthly{day} | interval_days{every,anchor_date} | interval_months{every,anchor_date,day}
#   yearly{month,day} | fixed_date{date} | none
# 运行时字段：next_reset_date、last_reset_date。
# 重置历史 reset_history.json：{id:[{due,at,in,out}]}，同一 due 只清零一次。

reset_policy_type() {
    local t
    t=$(mget "$1" .reset_policy.type none)
    case "$t" in monthly|interval_days|interval_months|yearly|fixed_date) echo "$t" ;; *) echo none ;; esac
}

monitor_has_auto_reset() {
    [ "$(reset_policy_type "$1")" != "none" ]
}

monitor_created_date() {
    local c
    c=$(mget "$1" .created_at "")
    if [[ "$c" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then echo "${c:0:10}"; else get_current_date; fi
}

calculate_monthly_next_date() {
    local day="$1"
    local from_date="$2"
    local -a parts; read -ra parts <<< "$(date_parts "$from_date")"
    local year="${parts[0]}"
    local month="${parts[1]}"
    local candidate_day
    candidate_day=$(clamp_day_to_month "$year" "$month" "$day")
    local candidate
    candidate=$(format_date "$year" "$month" "$candidate_day")

    if date_lt "$candidate" "$from_date"; then
        local -a next; read -ra next <<< "$(normalize_year_month "$year" "$((month + 1))")"
        year="${next[0]}"
        month="${next[1]}"
        candidate_day=$(clamp_day_to_month "$year" "$month" "$day")
        candidate=$(format_date "$year" "$month" "$candidate_day")
    fi

    echo "$candidate"
}

calculate_interval_days_next_date() {
    local anchor_date="$1"
    local every_days="$2"
    local from_date="$3"
    [[ "$every_days" =~ ^[0-9]+$ ]] && [ "$every_days" -ge 1 ] || return 1
    local anchor_ordinal
    local from_ordinal
    anchor_ordinal=$(date_to_ordinal "$anchor_date") || return 1
    from_ordinal=$(date_to_ordinal "$from_date") || return 1
    if [ "$anchor_ordinal" -ge "$from_ordinal" ]; then
        echo "$anchor_date"
        return
    fi
    local distance=$((from_ordinal - anchor_ordinal))
    local steps=$(((distance + every_days - 1) / every_days))
    ordinal_to_date "$((anchor_ordinal + steps * every_days))"
}

calculate_interval_months_next_date() {
    local anchor_date="$1"
    local every_months="$2"
    local desired_day="$3"
    local from_date="$4"
    [[ "$every_months" =~ ^[0-9]+$ ]] && [ "$every_months" -ge 1 ] || return 1
    if ! date_lt "$anchor_date" "$from_date"; then
        echo "$anchor_date"
        return
    fi

    local -a anchor_parts; read -ra anchor_parts <<< "$(date_parts "$anchor_date")"
    local -a from_parts; read -ra from_parts <<< "$(date_parts "$from_date")"
    local anchor_month_index=$((anchor_parts[0] * 12 + anchor_parts[1] - 1))
    local from_month_index=$((from_parts[0] * 12 + from_parts[1] - 1))
    local month_distance=$((from_month_index - anchor_month_index))
    local steps=$((month_distance / every_months))
    local candidate
    candidate=$(add_months_to_date "$anchor_date" "$((steps * every_months))" "$desired_day")
    if date_lt "$candidate" "$from_date"; then
        candidate=$(add_months_to_date "$anchor_date" "$(((steps + 1) * every_months))" "$desired_day")
    fi
    echo "$candidate"
}

calculate_yearly_next_date() {
    local month="$1"
    local day="$2"
    local from_date="$3"
    local -a parts; read -ra parts <<< "$(date_parts "$from_date")"
    local year="${parts[0]}"
    local candidate_day
    candidate_day=$(clamp_day_to_month "$year" "$month" "$day")
    local candidate
    candidate=$(format_date "$year" "$month" "$candidate_day")

    if date_lt "$candidate" "$from_date"; then
        year=$((year + 1))
        candidate_day=$(clamp_day_to_month "$year" "$month" "$day")
        candidate=$(format_date "$year" "$month" "$candidate_day")
    fi

    echo "$candidate"
}


# 从 from_date（含）起计算下一次重置日期。
monitor_compute_next_reset() {
    local id="$1" from="${2:-$(get_current_date)}" type every anchor day month
    type=$(reset_policy_type "$id")
    case "$type" in
        monthly)
            day=$(mget "$id" .reset_policy.day 1)
            calculate_monthly_next_date "$day" "$from" ;;
        interval_days)
            every=$(mget "$id" .reset_policy.every 30)
            anchor=$(mget "$id" .reset_policy.anchor_date "")
            is_valid_date "$anchor" || anchor=$(monitor_created_date "$id")
            calculate_interval_days_next_date "$anchor" "$every" "$from" ;;
        interval_months)
            every=$(mget "$id" .reset_policy.every 1)
            anchor=$(mget "$id" .reset_policy.anchor_date "")
            is_valid_date "$anchor" || anchor=$(monitor_created_date "$id")
            day=$(mget "$id" .reset_policy.day "${anchor:8:2}")
            calculate_interval_months_next_date "$anchor" "$every" "$((10#$day))" "$from" ;;
        yearly)
            calculate_yearly_next_date "$(mget "$id" .reset_policy.month 1)" "$(mget "$id" .reset_policy.day 1)" "$from" ;;
        fixed_date)
            mget "$id" .reset_policy.date "" ;;
        *) return 1 ;;
    esac
}

# 读取（必要时计算并保存）下一次重置日期。
monitor_next_reset() {
    local id="$1" next
    monitor_has_auto_reset "$id" || return 1
    next=$(mget "$id" .reset_policy.next_reset_date "")
    if ! is_valid_date "$next"; then
        local from
        from=$(get_current_date)
        [ "$(reset_policy_type "$id")" = "fixed_date" ] || from=$(add_days_to_date "$from" 1)
        next=$(monitor_compute_next_reset "$id" "$from") || return 1
        is_valid_date "$next" || return 1
        config_update '.monitors[$id].reset_policy.next_reset_date = $n' --arg id "$id" --arg n "$next" || return 1
    fi
    echo "$next"
}

# 设置新策略：$2 为策略 JSON；立即计算 next_reset_date。
monitor_set_reset_policy() {
    local id="$1" policy="$2" next=""
    config_update '.monitors[$id].reset_policy = $p' --arg id "$id" --argjson p "$policy" || return 1
    if monitor_has_auto_reset "$id"; then
        local from
        from=$(get_current_date)
        [ "$(reset_policy_type "$id")" = "fixed_date" ] || from=$(add_days_to_date "$from" 1)
        next=$(monitor_compute_next_reset "$id" "$from") || return 1
        config_update '.monitors[$id].reset_policy.next_reset_date = $n' --arg id "$id" --arg n "$next" || return 1
    fi
}

# 重置完成后推进日期：一次性策略改为 none。
monitor_advance_reset() {
    local id="$1" today="${2:-$(get_current_date)}" next
    if [ "$(reset_policy_type "$id")" = "fixed_date" ]; then
        config_update '.monitors[$id].reset_policy = {type: "none", last_reset_date: $d}' \
            --arg id "$id" --arg d "$today"
        return
    fi
    next=$(monitor_compute_next_reset "$id" "$(add_days_to_date "$today" 1)") || return 1
    config_update '.monitors[$id].reset_policy.last_reset_date = $l | .monitors[$id].reset_policy.next_reset_date = $n' \
        --arg id "$id" --arg l "$today" --arg n "$next"
}

monitor_reset_label() {
    local id="$1" next type
    next=$(monitor_next_reset "$id" 2>/dev/null) || return 1
    type=$(reset_policy_type "$id")
    case "$type" in
        monthly) echo "每月$(mget "$id" .reset_policy.day 1)日，下次${next}" ;;
        interval_days) echo "每$(mget "$id" .reset_policy.every 30)天，下次${next}" ;;
        interval_months) echo "每$(mget "$id" .reset_policy.every 1)个月，下次${next}" ;;
        yearly) echo "每年，下次${next}" ;;
        fixed_date) echo "${next}清零一次" ;;
    esac
}

# 当前计费周期起止（YYYY-MM-DD~YYYY-MM-DD 或 起点~未设置）。
monitor_cycle_range() {
    local id="$1" start next end
    start=$(mget "$id" .reset_policy.last_reset_date "")
    if ! is_valid_date "$start"; then
        start=$(mget "$id" .reset_policy.anchor_date "")
        is_valid_date "$start" && date_le "$start" "$(get_current_date)" || start=$(monitor_created_date "$id")
    fi
    if next=$(monitor_next_reset "$id" 2>/dev/null); then
        end=$(add_days_to_date "$next" -1)
        date_lt "$end" "$start" && end="$next"
        echo "${start}~${end}"
    else
        echo "${start}~不自动重置"
    fi
}

reset_history_has() {
    local id="$1" due="$2"
    [ -s "$RESET_HISTORY_FILE" ] || return 1
    jq -e --arg id "$id" --arg due "$due" 'any((.[$id] // [])[]; .due == $due)' "$RESET_HISTORY_FILE" >/dev/null 2>&1
}

reset_history_record() {
    local id="$1" due="$2" in_b="$3" out_b="$4"
    [ -s "$RESET_HISTORY_FILE" ] || echo '{}' | atomic_write "$RESET_HISTORY_FILE" 600
    json_update "$RESET_HISTORY_FILE" \
        '.[$id] = (((.[$id] // []) + [{due: $due, at: $at, in: $i, out: $o}]) | .[-24:])' \
        --arg id "$id" --arg due "$due" --arg at "$(date -u +%FT%TZ)" --argjson i "$in_b" --argjson o "$out_b"
}

reset_history_drop() {
    [ -s "$RESET_HISTORY_FILE" ] || return 0
    json_update "$RESET_HISTORY_FILE" 'del(.[$id])' --arg id "$1"
}

# 清零一个监控项的计数与配额。$2 为到期日（手动重置传 manual）。
reset_monitor() {
    local id="$1" due="${2:-manual}" cur in_b out_b used rc=0
    dog_lock || return 75
    stats_snapshot >/dev/null 2>&1 || true
    cur=$(nft_read_monitor "$id" 2>/dev/null || echo "0 0 0")
    read -r in_b out_b used <<< "$cur"
    if nft_reset_monitor "$id"; then
        reset_history_record "$id" "$due" "$in_b" "$out_b" || true
        stats_rebaseline "$id" 0 0 || true
        traffic_backup_save || true
        log_notification "监控项 $id（$(monitor_label "$id")）流量已重置（${due}），重置前 入站 $(format_bytes "$in_b") 出站 $(format_bytes "$out_b")（原始字节）"
    else
        rc=1
    fi
    dog_unlock
    dog_log_event traffic_reset "$rc" "id=$id"
    return "$rc"
}

# 检查并执行到期的自动重置（每分钟 tick 调用）。
check_due_resets() {
    local id today next failed=0
    today=$(get_current_date)
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        monitor_has_auto_reset "$id" || continue
        next=$(monitor_next_reset "$id" 2>/dev/null) || { failed=1; continue; }
        date_le "$next" "$today" || continue
        if reset_history_has "$id" "$next"; then
            # 已清零但日期推进失败：只补推进，避免重复清零。
            monitor_advance_reset "$id" "$today" || failed=1
            continue
        fi
        if reset_monitor "$id" "$next"; then
            monitor_advance_reset "$id" "$today" || failed=1
        else
            failed=1
        fi
    done < <(monitor_ids)
    return "$failed"
}

# 交互选择重置策略，结果 JSON 输出到 stdout（提示走 stderr）。
prompt_reset_policy() {
    local default_day="${1:-1}" choice day every anchor month date today
    today=$(get_current_date)
    while true; do
        {
            echo
            echo -e "${BLUE}=== 自动重置策略 ===${NC}"
            echo "1. 每月几号重置（默认每月${default_day}日）"
            echo "2. 每隔多少天重置"
            echo "3. 每隔多少个月重置"
            echo "4. 每年几月几号重置"
            echo "5. 指定日期清零一次"
            echo "0. 不自动重置"
        } >&2
        read -r -p "请选择(回车默认1) [0-5]: " choice
        case "$choice" in
            1|"")
                read -r -p "每月几号重置(回车默认${default_day}) [1-31]: " day
                day="${day:-$default_day}"
                validate_day_1_31 "$day" || { echo -e "${RED}日期必须是 1-31${NC}" >&2; continue; }
                jq -cn --argjson d "$day" '{type: "monthly", day: $d}'; return 0 ;;
            2|3)
                if [ "$choice" = 2 ]; then
                    read -r -p "每隔多少天重置 [1-3650]: " every
                    [[ "$every" =~ ^[0-9]+$ ]] && [ "$every" -ge 1 ] && [ "$every" -le 3650 ] || { echo -e "${RED}天数无效${NC}" >&2; continue; }
                else
                    read -r -p "每隔多少个月重置 [1-120]: " every
                    [[ "$every" =~ ^[0-9]+$ ]] && [ "$every" -ge 1 ] && [ "$every" -le 120 ] || { echo -e "${RED}月数无效${NC}" >&2; continue; }
                fi
                read -r -p "起算日期(回车默认今天 ${today}) [YYYY-MM-DD]: " anchor
                anchor="${anchor:-$today}"
                is_valid_date "$anchor" || { echo -e "${RED}日期格式应为 YYYY-MM-DD${NC}" >&2; continue; }
                if [ "$choice" = 2 ]; then
                    jq -cn --argjson e "$every" --arg a "$anchor" '{type: "interval_days", every: $e, anchor_date: $a}'
                else
                    read -r -p "每次按几号重置(回车默认 $((10#${anchor:8:2}))) [1-31]: " day
                    day="${day:-$((10#${anchor:8:2}))}"
                    validate_day_1_31 "$day" || { echo -e "${RED}日期必须是 1-31${NC}" >&2; continue; }
                    jq -cn --argjson e "$every" --arg a "$anchor" --argjson d "$day" \
                        '{type: "interval_months", every: $e, anchor_date: $a, day: $d}'
                fi
                return 0 ;;
            4)
                read -r -p "每年几月 [1-12]: " month
                read -r -p "几号 [1-31]: " day
                validate_month_1_12 "$month" && validate_day_1_31 "$day" || { echo -e "${RED}月份或日期无效${NC}" >&2; continue; }
                jq -cn --argjson m "$month" --argjson d "$day" '{type: "yearly", month: $m, day: $d}'; return 0 ;;
            5)
                read -r -p "清零日期 [YYYY-MM-DD]: " date
                is_valid_date "$date" && ! date_lt "$date" "$today" || { echo -e "${RED}日期无效或早于今天${NC}" >&2; continue; }
                jq -cn --arg d "$date" '{type: "fixed_date", date: $d}'; return 0 ;;
            0) echo '{"type":"none"}'; return 0 ;;
            *) echo -e "${RED}请输入 0-5${NC}" >&2 ;;
        esac
    done
}
