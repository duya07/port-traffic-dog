# ── 交互菜单 ──────────────────────────────────────────────────────
# 所有子菜单都是循环，返回即回到上一级（1.5.x 的菜单互相递归调用，层数越用越深）。

menu_text_width() {
    local text="$1" index character code width=0 LC_CTYPE=C.UTF-8
    for ((index=0; index<${#text}; index++)); do
        character="${text:index:1}"
        printf -v code '%d' "'$character"
        if (( code >= 0x300 && code <= 0x36f )); then continue; fi
        if (( code >= 0x1100 && (code <= 0x115f || code >= 0x2e80) )); then
            width=$((width+2))
        else width=$((width+1)); fi
    done
    printf '%s' "$width"
}

menu_columns() {
    local columns="${COLUMNS:-80}" size
    if [ -t 1 ]; then
        size=$(stty size 2>/dev/null) || size=''
        [ -z "$size" ] || columns="${size##* }"
    fi
    [[ "$columns" =~ ^[0-9]+$ ]] && [ "$columns" -ge 20 ] && [ "$columns" -le 500 ] || columns=80
    printf '%s' "$columns"
}

menu_item() {
    local number="$1" text="$2" columns="${3:-80}" index character width=4 amount
    local LC_CTYPE=C.UTF-8
    printf '%b%2s.%b ' "$BLUE" "$number" "$NC"
    for ((index=0; index<${#text}; index++)); do
        character="${text:index:1}"
        amount=$(menu_text_width "$character")
        if [ "$((width+amount))" -gt "$columns" ]; then printf '\n    '; width=4; fi
        printf '%s' "$character"
        width=$((width+amount))
    done
    printf '\n'
}

readonly -a MAIN_MENU_LABELS=(
    '添加监控项' '修改端口（加/减/替换/拆分/合并）'
    '删除监控项' '配额与自动重置'
    '带宽限制' '服务到期'
    '计费模式与备注' '立即重置流量'
    '通知管理' '系统自检/修复'
    'TC 冲突处理/自动恢复' '在线 IP / 并发限制（测试中）'
    '依赖检测/安装/卸载' '配置导出/导入'
    '查看日志' '更新脚本'
    '卸载'
)

show_main_menu_options() {
    local columns index left right width n="${#MAIN_MENU_LABELS[@]}" lw=0 rw=0
    columns=$(menu_columns)
    # 左列宽度取最长左侧标签，保证右列对齐；两列放不下时改为单列。
    for ((index = 0; index < n; index++)); do
        width=$(menu_text_width "${MAIN_MENU_LABELS[index]}")
        if ((index % 2 == 0)); then ((width > lw)) && lw=$width; else ((width > rw)) && rw=$width; fi
    done
    if [ $((4 + lw + 2 + 4 + rw)) -le "$columns" ]; then
        for ((index = 0; index < n; index += 2)); do
            left="${MAIN_MENU_LABELS[index]}"
            if [ $((index + 1)) -lt "$n" ]; then
                right="${MAIN_MENU_LABELS[index + 1]}"
                width=$(menu_text_width "$left")
                printf '%b%2d.%b %s%*s%b%2d.%b %s\n' "$BLUE" "$((index + 1))" "$NC" "$left" "$((lw - width + 2))" '' \
                    "$BLUE" "$((index + 2))" "$NC" "$right"
            else
                menu_item "$((index + 1))" "$left" "$columns"
            fi
        done
    else
        for ((index = 0; index < n; index++)); do menu_item "$((index + 1))" "${MAIN_MENU_LABELS[index]}" "$columns"; done
    fi
    menu_item 0 退出 "$columns"
}

# 监控项汇总表（只读一次 nft）。
show_monitor_table() {
    local values id idx=0 in_b out_b mult billed limit pct usage ports n
    if ! has_monitors; then
        echo "  （暂无监控项）"
        return 1
    fi
    values=$(nft_read_values 2>/dev/null || echo '{}')
    printf '  %-3s %-5s %-34s %-12s %s\n' '#' 'ID' '端口 / 备注' '周期流量' '配额 / 状态'
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        idx=$((idx + 1))
        read -r in_b out_b < <(jq -r --arg id "$id" '.[$id] // {} | "\(.in // 0) \(.out // 0)"' <<< "$values")
        mult=$(monitor_billing_multiplier "$id")
        billed=$(( (in_b + out_b) * mult ))
        ports=$(monitor_label "$id")
        n=$(monitor_ports "$id" | wc -l)
        [ "$n" -gt 1 ] && ports="$ports [${n}项]"
        usage="不限额"
        limit=$(mget "$id" .quota.monthly_limit unlimited)
        if [ "$(mget "$id" .quota.enabled false)" = "true" ] && [ "$limit" != "unlimited" ]; then
            pct=$(( billed * 100 / $(parse_size_to_bytes "$limit") ))
            usage="${limit} ${pct}%"
        fi
        monitor_is_expired "$id" && usage+=" 已到期"
        monitor_tc_rate "$id" >/dev/null && usage+=" 限速$(monitor_tc_rate "$id")"
        jq -e --arg id "$id" 'has($id)' <<< "$values" >/dev/null || usage+=" ⚠计数缺失"
        printf '  %-3s %-5s %-34s %-12s %s\n' "$idx" "$id" "$ports" "$(format_bytes "$billed")" "$usage"
    done < <(monitor_ids)
}

# 交互选择监控项：接受序号、ID（m3）或成员端口（8031）。输出 ID。
select_monitor() {
    local prompt="${1:-请选择监控项}" input ids id
    mapfile -t ids < <(monitor_ids)
    [ "${#ids[@]}" -gt 0 ] || { echo -e "${YELLOW}暂无监控项${NC}" >&2; return 1; }
    show_monitor_table >&2 || true
    read -r -p "$prompt（序号 / ID / 端口，回车取消）: " input
    [ -n "$input" ] || return 1
    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "${#ids[@]}" ] && [ "$input" -le 999 ]; then
        echo "${ids[$((input - 1))]}"
        return 0
    fi
    if id=$(resolve_monitor "$input"); then echo "$id"; return 0; fi
    echo -e "${RED}找不到监控项：$input${NC}" >&2
    return 1
}

menu_add_monitor() {
    local input units unit remark id
    echo -e "${BLUE}=== 添加监控项 ===${NC}"
    show_listening_ports
    echo
    echo -e "格式：${GREEN},${NC} 组合多个端口为一个监控项（共享统计/配额/限速），${GREEN};${NC} 分隔多个独立监控项，${GREEN}-${NC} 表示端口段"
    echo -e "例：${GREEN}80,443${NC} 一个监控项；${GREEN}80,443;8080-8090${NC} 两个监控项"
    read -r -p "端口: " input
    [ -n "$input" ] || return 0
    parse_monitor_units "$input" units || { pause; return 1; }
    read -r -p "备注（可留空）: " remark
    for unit in "${units[@]}"; do
        if id=$(monitor_add "$unit" "$remark"); then
            echo -e "${GREEN}已添加 $id：$unit${NC}"
        else
            echo -e "${RED}添加 $unit 失败${NC}"
        fi
    done
    cron_sync || true
    if [ "${#units[@]}" -eq 1 ] && [ -n "${id:-}" ] && confirm "现在设置配额与自动重置"; then
        menu_quota_for "$id"
    fi
}

menu_edit_ports() {
    local id choice input target remark copy
    id=$(select_monitor "要修改的监控项") || return 0
    while monitor_exists "$id"; do
        echo
        echo -e "${BLUE}=== 修改端口：$id $(monitor_label "$id") ===${NC}"
        echo "当前成员：$(monitor_ports_csv "$id")"
        echo "1. 添加端口/端口段（流量继续累计）"
        echo "2. 删除端口（已统计流量保留在本项）"
        echo "3. 整组替换端口"
        echo "4. 拆出部分端口为新监控项（新项从 0 开始计）"
        echo "5. 把本项合并到另一个监控项（流量相加）"
        echo "0. 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1) read -r -p "要添加的端口（逗号分隔）: " input
               [ -n "$input" ] && input=$(parse_port_list "$input" | paste -sd,) && monitor_edit_ports "$id" "$input" "" "" &&
                   echo -e "${GREEN}已更新：$(monitor_ports_csv "$id")${NC}" ;;
            2) read -r -p "要删除的成员（逗号分隔，端口段按原样写）: " input
               [ -n "$input" ] && input=$(parse_port_list "$input" | paste -sd,) && monitor_edit_ports "$id" "" "$input" "" &&
                   echo -e "${GREEN}已更新：$(monitor_ports_csv "$id")${NC}" ;;
            3) read -r -p "新的完整端口列表: " input
               [ -n "$input" ] && input=$(parse_port_list "$input" | paste -sd,) && monitor_edit_ports "$id" "" "" "$input" &&
                   echo -e "${GREEN}已更新：$(monitor_ports_csv "$id")${NC}" ;;
            4) read -r -p "要拆出的成员（逗号分隔）: " input
               [ -n "$input" ] || continue
               input=$(parse_port_list "$input" | paste -sd,) || continue
               read -r -p "新监控项备注（可留空）: " remark
               copy=""; confirm "新项是否复制本项的配额、重置策略和到期日" && copy=copy
               if target=$(monitor_split "$id" "$input" "$remark" "$copy"); then
                   echo -e "${GREEN}已拆出新监控项 $target${NC}"
               fi ;;
            5) target=$(select_monitor "合并到哪个监控项") || continue
               [ "$target" != "$id" ] || { echo -e "${RED}不能合并到自身${NC}"; continue; }
               echo "将把 $id 的端口与流量并入 $target，$id 的配额/限速/到期设置作废，以 $target 为准。"
               confirm "确认合并" || continue
               if monitor_merge "$id" "$target"; then
                   echo -e "${GREEN}已合并到 $target${NC}"
                   return 0
               fi ;;
            0|"") return 0 ;;
        esac
    done
}

menu_remove_monitor() {
    local id
    id=$(select_monitor "要删除的监控项") || return 0
    confirm "确认删除 $id（$(monitor_label "$id")）及其统计、配额、限速与到期设置" || return 0
    monitor_remove "$id" && echo -e "${GREEN}已删除 $id${NC}"
    cron_sync || true
}

menu_quota_for() {
    local id="$1" limit policy
    echo "当前配额：$(mget "$id" .quota.monthly_limit unlimited)（$(mget "$id" .billing_mode double) 计费）"
    read -r -p "流量配额（如 500GB、1.5TB；0 取消；回车不变）: " limit
    if [ -n "$limit" ]; then
        monitor_set_quota "$id" "$limit" && echo -e "${GREEN}配额已更新${NC}"
    fi
    if confirm "设置自动重置策略（当前：$(monitor_reset_label "$id" 2>/dev/null || echo 不自动重置)）"; then
        policy=$(prompt_reset_policy "$(mget "$id" .reset_policy.day 1)") || return 0
        monitor_set_reset_policy "$id" "$policy" && echo -e "${GREEN}重置策略已更新：$(monitor_reset_label "$id" 2>/dev/null || echo 不自动重置)${NC}"
    fi
}

menu_quota_reset() {
    local id
    id=$(select_monitor "设置配额/重置的监控项") || return 0
    menu_quota_for "$id"
}

menu_bandwidth() {
    local id input rate
    id=$(select_monitor "设置带宽限制的监控项") || return 0
    echo "当前：$(monitor_tc_rate "$id" 2>/dev/null || echo 不限速)（上下行分别限制，同项端口共享）"
    read -r -p "带宽（如 100Mbps、1Gbps；0 取消）: " input
    [ -n "$input" ] || return 0
    validate_bandwidth "$input" || { echo -e "${RED}格式无效${NC}"; return 1; }
    if [ "$input" = "0" ]; then rate=0; else rate=$(convert_bandwidth_to_tc "$input"); fi
    if [ "$rate" != "0" ] && [ "$(tc_auto_recovery_state 2>/dev/null || echo disabled)" != "enabled" ]; then
        show_tc_auto_recovery_notice 2>/dev/null || true
    fi
    tc_set_monitor_limit "$id" "$rate" && echo -e "${GREEN}带宽限制已更新${NC}"
}

menu_expiry() {
    local id input
    id=$(select_monitor "设置服务到期的监控项") || return 0
    echo "当前：$(monitor_expiry_label "$id" 2>/dev/null || echo 未设置)"
    read -r -p "到期日 YYYY-MM-DD（输入 0 取消到期）: " input
    [ -n "$input" ] || return 0
    [ "$input" = "0" ] && input=""
    monitor_set_expiry "$id" "$input" && echo -e "${GREEN}到期设置已更新${NC}"
}

menu_billing_remark() {
    local id choice input
    id=$(select_monitor "要修改的监控项") || return 0
    echo "1. 计费模式（当前：$(mget "$id" .billing_mode double)）"
    echo "2. 备注（当前：$(mget "$id" .remark "")）"
    read -r -p "请选择: " choice
    case "$choice" in
        1) echo "double：入站+出站，各按 2 倍计（与上游一致）；single：入站+出站按 1 倍计"
           read -r -p "模式 [double/single]: " input
           [ -n "$input" ] && monitor_set_billing "$id" "$input" && echo -e "${GREEN}已切换${NC}" ;;
        2) read -r -p "新备注（最长 64 字符，留空清除）: " input
           monitor_set_remark "$id" "$input" && echo -e "${GREEN}已更新${NC}" ;;
    esac
}

menu_reset_now() {
    local id
    id=$(select_monitor "要立即清零流量的监控项") || return 0
    confirm "确认清零 $id 的本周期流量与已用配额（自动重置日程不变）" || return 0
    reset_monitor "$id" manual && echo -e "${GREEN}已清零${NC}"
}

menu_config_io() {
    local choice file
    echo "1. 导出配置与统计"
    echo "2. 导入配置包"
    read -r -p "请选择: " choice
    case "$choice" in
        1) export_config ;;
        2) read -r -p "配置包路径: " file; [ -n "$file" ] && import_config "$file" ;;
    esac
}

show_dashboard() {
    local total=0 values id machine
    echo -e "${BLUE}=== ${SCRIPT_NAME} v${SCRIPT_VERSION} ===${NC}"
    if has_monitors; then
        values=$(nft_read_values 2>/dev/null || echo '{}')
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            total=$(( total + $(jq -r --arg id "$id" '.[$id] // {} | ((.in // 0) + (.out // 0))' <<< "$values") * $(monitor_billing_multiplier "$id") ))
        done < <(monitor_ids)
        echo -e "${GREEN}状态: 监控中${NC} | 监控项 $(monitor_ids | grep -c .) 个 | 周期总流量 $(format_bytes "$total")"
    else
        echo -e "${YELLOW}状态: 未添加监控项${NC}"
    fi
    machine=$(machine_traffic_summary 2>/dev/null || true)
    [ -n "$machine" ] && echo "$machine"
    show_monitor_table >/dev/null 2>&1 && show_monitor_table
    if ! nft_runtime_drift >/dev/null 2>&1 && has_monitors; then
        echo -e "${YELLOW}⚠ nftables 规则与配置不一致，建议执行 10. 系统自检/修复${NC}"
    fi
    if has_monitors && ! cron_in_sync 2>/dev/null; then
        echo -e "${YELLOW}⚠ 定时任务与配置不一致，建议执行 10. 系统自检/修复${NC}"
    fi
}

show_main_menu() {
    local choice
    while true; do
        menu_clear
        show_dashboard
        echo
        show_main_menu_options
        read -r -p "请选择操作: " choice || exit 0
        case "$choice" in
            1) menu_add_monitor ;;
            2) menu_edit_ports ;;
            3) menu_remove_monitor ;;
            4) menu_quota_reset ;;
            5) menu_bandwidth ;;
            6) menu_expiry ;;
            7) menu_billing_remark ;;
            8) menu_reset_now ;;
            9) manage_notifications; continue ;;
            10) system_check_and_repair ;;
            11) manage_tc_recovery ;;
            12) manage_ip_guard; continue ;;
            13) dependency_menu ;;
            14) menu_config_io ;;
            15) show_operation_logs ;;
            16) update_dog ;;
            17) uninstall_dog && exit 0 ;;
            0) exit 0 ;;
            *) continue ;;
        esac
        pause
    done
}
