# ── 交互菜单 ──────────────────────────────────────────────────────
# 所有子菜单都是循环，返回即回到上一级（1.5.x 的菜单互相递归调用，层数越用越深）。
# 标题、分隔线、选项与宽度计算见 16-ui.sh。

readonly -a MAIN_MENU_LABELS=(
    '添加监控项' '修改端口（加/减/替换/拆分/合并）' '删除监控项' '配额与自动重置' '带宽限制'
    '服务到期' '计费模式与备注' '立即重置流量' '通知管理'
    '系统自检/修复' 'TC 冲突处理/自动恢复' '在线 IP / 并发限制（测试中）' '依赖检测/安装/卸载'
    '配置导出/导入' '查看日志' '更新脚本' '卸载'
)
# 两列即两组：左列“监控项”1–9，右列“系统维护”10–17；编号先竖排左列、再竖排右列。
# 编号与功能的对应关系与 2.0 相同。
readonly MAIN_MENU_SPLIT=9

show_main_menu_options() {
    local columns n=${#MAIN_MENU_LABELS[@]} split=$MAIN_MENU_SPLIT rows i lw=0 rw=0 w cell
    columns=$(ui_columns)
    for ((i = 0; i < n; i++)); do
        ui_measure w "${MAIN_MENU_LABELS[i]}"
        if [ "$i" -lt "$split" ]; then [ "$w" -le "$lw" ] || lw=$w; else [ "$w" -le "$rw" ] || rw=$w; fi
    done
    cell=$((4 + lw + 4))   # 左列：编号“ 1. ”4 列 + 最长标签 + 列间距
    if [ $((3 + cell + 4 + rw)) -le "$columns" ]; then
        printf '   %b%s%s%b\n' "$DIM" "$(ui_pad 监控项 "$cell")" 系统维护 "$NC"
        rows=$(( split > n - split ? split : n - split ))
        for ((i = 0; i < rows; i++)); do
            printf '   '
            if [ "$i" -lt "$split" ]; then
                printf '%b%2d.%b ' "$CYAN" $((i + 1)) "$NC"
                if [ $((split + i)) -lt "$n" ]; then
                    printf '%s' "$(ui_pad "${MAIN_MENU_LABELS[i]}" $((lw + 4)))"
                else
                    printf '%s' "${MAIN_MENU_LABELS[i]}"
                fi
            else
                printf '%*s' "$cell" ''
            fi
            [ $((split + i)) -ge "$n" ] || printf '%b%2d.%b %s' "$CYAN" $((split + i + 1)) "$NC" "${MAIN_MENU_LABELS[split + i]}"
            printf '\n'
        done
    else
        printf '   %b监控项%b\n' "$DIM" "$NC"
        for ((i = 0; i < split; i++)); do ui_option $((i + 1)) "${MAIN_MENU_LABELS[i]}"; done
        printf '   %b系统维护%b\n' "$DIM" "$NC"
        for ((i = split; i < n; i++)); do ui_option $((i + 1)) "${MAIN_MENU_LABELS[i]}"; done
    fi
    ui_rule
    ui_option 0 退出
}

billing_mode_label() {
    if [ "$1" = single ]; then echo "单向计费"; else echo "双向计费"; fi
}

# 配额列：$1=配额（空为不限额） $2=百分比 $3=wide|compact $4=宽屏时百分比的数字位数（默认 3）。
# 输出“纯文本<US>带颜色文本”，纯文本用于计算宽度。
_table_quota_cell() {
    local limit="$1" pct="$2" mode="$3" color="" filled i bar="" cbar="" ptxt
    if [ -z "$limit" ]; then printf '%s\037%s' 不限额 不限额; return 0; fi
    if [ "$pct" -ge 100 ]; then color="$RED"; elif [ "$pct" -ge 90 ]; then color="$YELLOW"; fi
    if [ "$mode" = compact ]; then
        printf '%s\037%s' "$limit $pct%" "$limit ${color}${pct}%${color:+$NC}"
        return 0
    fi
    filled=$(( (pct * 10 + 50) / 100 )); [ "$filled" -le 10 ] || filled=10
    for ((i = 0; i < 10; i++)); do if [ "$i" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi; done
    cbar="${color:-$GREEN}${bar:0:filled}${NC}${DIM}${bar:filled}${NC}"
    printf -v ptxt '%*d%%' "${4:-3}" "$pct"
    printf '%s\037%s' "$limit $bar $ptxt" "$limit $cbar ${color}${ptxt}${color:+$NC}"
}

# 监控项表格（只读一次 nft）。$1 为 nft_read_values 的结果，省略时现读。
# 按终端宽度选布局：放得下时配额带用量条；稍窄时配额只显示百分比并截断备注；再窄时每项占两行。
show_monitor_table() {
    local values="${1:-}" columns today id label mult limit expiry rate notify in_b out_b billed lbytes pct
    local n=0 i w plain colored q layout wl want fixed indent cell cell_plain cell_color wq line
    local -a r_id=() r_label=() r_used=() r_limit=() r_pct=() r_tags=() r_ctags=() t_plain=() t_color=()
    local -A cin=() cout=()
    if ! has_monitors; then echo "  （暂无监控项）"; return 1; fi
    [ -n "$values" ] || values=$(nft_read_values 2>/dev/null || echo '{}')
    while read -r id in_b out_b; do
        [ -n "$id" ] || continue
        cin[$id]=$in_b; cout[$id]=$out_b
    done < <(jq -r 'to_entries[] | "\(.key) \(.value.in // 0) \(.value.out // 0)"' <<< "$values" 2>/dev/null)
    today=$(get_current_date)
    # 字段用 0x1f 分隔：制表符属于 IFS 空白，连续的空字段会被 read 合并而错位。
    while IFS=$'\037' read -r id label mult limit expiry rate notify; do
        [ -n "$id" ] || continue
        billed=$(( (${cin[$id]:-0} + ${cout[$id]:-0}) * mult ))
        pct=""
        if [ "$limit" != unlimited ] && lbytes=$(parse_size_to_bytes "$limit") && [ "$lbytes" -gt 0 ]; then
            pct=$(( billed * 100 / lbytes ))
        else
            limit=""
        fi
        t_plain=(); t_color=()
        if [ -n "$pct" ] && [ "$pct" -ge 100 ]; then t_plain+=("超额"); t_color+=("${RED}超额${NC}"); fi
        if [ -n "$expiry" ] && date_le "$expiry" "$today"; then t_plain+=("已到期"); t_color+=("${RED}已到期${NC}"); fi
        if [ "$rate" != unlimited ]; then t_plain+=("限速 $(format_tc_rate "$rate")"); t_color+=("限速 $(format_tc_rate "$rate")"); fi
        if [ "$notify" = false ]; then t_plain+=("不推送"); t_color+=("${DIM}不推送${NC}"); fi
        if [ -z "${cin[$id]+x}" ]; then t_plain+=("计数缺失"); t_color+=("${YELLOW}计数缺失${NC}"); fi
        plain=""; colored=""
        for ((i = 0; i < ${#t_plain[@]}; i++)); do
            [ "$i" -eq 0 ] || { plain+=" · "; colored+=" · "; }
            plain+="${t_plain[i]}"; colored+="${t_color[i]}"
        done
        r_id+=("$id"); r_label+=("$label"); r_used+=("$(format_bytes "$billed")")
        r_limit+=("$limit"); r_pct+=("$pct"); r_tags+=("$plain"); r_ctags+=("$colored")
        n=$((n + 1))
    done < <(jq -r "$MONITOR_LABEL_JQ"'
        .monitors | to_entries | sort_by(.key | ltrimstr("m") | tonumber)[] | .key as $id | .value as $m |
        [$id, ($m | monitor_label | gsub("[[:cntrl:]]"; " ")),
         (if ($m.billing_mode // "double") == "single" then 1 else 2 end),
         (if ($m.quota.enabled // false) then ($m.quota.monthly_limit // "unlimited") else "unlimited" end),
         ($m.expiry_date // ""),
         (if ($m.bandwidth_limit.enabled // false) then ($m.bandwidth_limit.rate // "unlimited") else "unlimited" end),
         ($m.notify != false)] | map(tostring) | join("\u001f")' "$CONFIG_FILE")

    # 列宽：取表头与内容的较大者（表头：# ID 端口/备注 周期流量 配额 状态）。
    local w_idx=${#n} w_id=2 w_lab=11 w_use=8 w_lim=0 w_pd=3 w_qw=6 w_qc=6 w_st=4
    for ((i = 0; i < n; i++)); do
        [ "${#r_id[i]}" -le "$w_id" ] || w_id=${#r_id[i]}
        ui_measure w "${r_label[i]}"; [ "$w" -le "$w_lab" ] || w_lab=$w
        [ "${#r_used[i]}" -le "$w_use" ] || w_use=${#r_used[i]}
        [ "${#r_limit[i]}" -le "$w_lim" ] || w_lim=${#r_limit[i]}
        ui_measure w "${r_tags[i]}"; [ "$w" -le "$w_st" ] || w_st=$w
        if [ -n "${r_pct[i]}" ]; then
            q="${r_limit[i]} ${r_pct[i]}%"; [ "${#q}" -le "$w_qc" ] || w_qc=${#q}
            [ "${#r_pct[i]}" -le "$w_pd" ] || w_pd=${#r_pct[i]}
        fi
    done
    # 宽屏配额列“300GB █░░░░░░░░░   7%”：配额 + 空格 + 10 格用量条 + 空格 + 百分比（至少 3 位，超额到 1000% 以上时按最长的算）。
    [ "$w_lim" -eq 0 ] || [ $((w_lim + 13 + w_pd)) -le "$w_qw" ] || w_qw=$((w_lim + 13 + w_pd))
    want=$w_lab; [ "$want" -le 40 ] || want=40
    columns=$(ui_columns)
    fixed=$(( 2 + w_idx + 2 + w_id + 2 + 2 + w_use + 2 + w_qw + 2 + w_st ))
    if [ $((fixed + want)) -le "$columns" ]; then
        layout=wide; wl=$want; wq=$w_qw
    else
        fixed=$(( 2 + w_idx + 2 + w_id + 2 + 2 + w_use + 2 + w_qc + 2 + w_st ))
        wl=$((columns - fixed)); [ "$wl" -le "$want" ] || wl=$want
        if [ "$wl" -ge 11 ]; then layout=compact; wq=$w_qc; else layout=card; fi
    fi

    if [ "$layout" = card ]; then
        indent=$(( 2 + w_idx + 2 + w_id + 2 ))
        w=$((columns - indent)); [ "$w" -ge 4 ] || w=4
        for ((i = 0; i < n; i++)); do
            printf '  %s  %s  %s\n' "$(ui_pad $((i + 1)) "$w_idx")" "$(ui_pad "${r_id[i]}" "$w_id")" "$(ui_truncate "${r_label[i]}" "$w")"
            cell=$(_table_quota_cell "${r_limit[i]}" "${r_pct[i]}" compact)
            cell_plain="${cell%%$'\037'*}"; cell_color="${cell#*$'\037'}"
            line="${r_used[i]} · $cell_plain"
            if [ -z "${r_tags[i]}" ]; then
                printf '%*s%b\n' "$indent" '' "${r_used[i]} · $cell_color"
            elif ui_measure q "$line · ${r_tags[i]}" && [ "$q" -le "$w" ]; then
                printf '%*s%b\n' "$indent" '' "${r_used[i]} · $cell_color · ${r_ctags[i]}"
            else
                printf '%*s%b\n%*s%b\n' "$indent" '' "${r_used[i]} · $cell_color" "$indent" '' "${r_ctags[i]}"
            fi
        done
        return 0
    fi

    printf '  %b%s  %s  %s  %s  %s  %s%b\n' "$DIM" "$(ui_pad '#' "$w_idx")" "$(ui_pad ID "$w_id")" \
        "$(ui_pad '端口 / 备注' "$wl")" "$(ui_pad 周期流量 "$w_use")" "$(ui_pad 配额 "$wq")" 状态 "$NC"
    for ((i = 0; i < n; i++)); do
        if [ -z "${r_limit[i]}" ]; then
            cell=$(_table_quota_cell "" "" "$layout")
        elif [ "$layout" = wide ]; then
            cell=$(_table_quota_cell "$(ui_pad "${r_limit[i]}" "$w_lim")" "${r_pct[i]}" wide "$w_pd")   # 补齐配额与百分比，用量条和状态列对齐
        else
            cell=$(_table_quota_cell "${r_limit[i]}" "${r_pct[i]}" compact)
        fi
        cell_plain="${cell%%$'\037'*}"; cell_color="${cell#*$'\037'}"
        printf '  %s  %s  %s  %s  ' "$(ui_pad $((i + 1)) "$w_idx")" "$(ui_pad "${r_id[i]}" "$w_id")" \
            "$(ui_pad "$(ui_truncate "${r_label[i]}" "$wl")" "$wl")" "$(ui_pad "${r_used[i]}" "$w_use")"
        if [ -z "${r_tags[i]}" ]; then
            printf '%b\n' "$cell_color"
        else
            ui_measure w "$cell_plain"
            [ "$w" -le "$wq" ] || w=$wq
            printf '%b%*s  %b\n' "$cell_color" $((wq - w)) '' "${r_ctags[i]}"
        fi
    done
}

# 交互选择监控项：接受序号、ID（m3）或成员端口（7031）。输出 ID；表格与提示写到 stderr。
select_monitor() {
    local prompt="${1:-请选择监控项}" input ids id
    mapfile -t ids < <(monitor_ids)
    [ "${#ids[@]}" -gt 0 ] || { echo -e "  ${YELLOW}暂无监控项，请先添加${NC}" >&2; return 1; }
    show_monitor_table >&2 || true
    read -r -p " $prompt（序号 / ID / 端口，回车取消）: " input || return 1
    [ -n "$input" ] || return 1
    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "${#ids[@]}" ] && [ "$input" -le 999 ]; then
        echo "${ids[$((10#$input - 1))]}"   # 10#：08、010 按十进制解析，不当八进制
        return 0
    fi
    if id=$(resolve_monitor "$input"); then echo "$id"; return 0; fi
    echo -e "${RED}找不到监控项：$input${NC}" >&2
    return 1
}

# 已选监控项的抬头。
_menu_monitor_header() {
    echo
    ui_kv "监控项" "$1 $(monitor_label "$1")"
}

menu_add_monitor() {
    local input units unit remark id="" added=0
    ui_title "添加监控项"
    show_listening_ports
    echo
    ui_note "逗号把多个端口组合成一个监控项（共享统计/配额/限速）；分号分隔多个监控项；- 表示端口段"
    ui_note "例：80,443 为一个监控项；80,443;8080-8090 为两个监控项"
    read -r -p " 端口（回车取消）: " input || return 0
    [ -n "$input" ] || return 0
    parse_monitor_units "$input" units || return 1
    read -r -p " 备注（可留空）: " remark || return 0
    for unit in "${units[@]}"; do
        if id=$(monitor_add "$unit" "$remark"); then
            echo -e "${GREEN}已添加 $id：$unit${NC}"
            added=$((added + 1))
        else
            echo -e "${RED}添加 $unit 失败${NC}"
        fi
    done
    cron_sync || true
    if [ "${#units[@]}" -eq 1 ] && [ "$added" -eq 1 ] && confirm " 现在设置配额与自动重置"; then
        menu_quota_for "$id"
    fi
}

menu_edit_ports() {
    local id choice input target remark copy
    ui_title "修改端口"
    id=$(select_monitor "要修改的监控项") || return 0
    while monitor_exists "$id"; do
        _menu_monitor_header "$id"
        ui_kv "当前成员" "$(monitor_ports_csv "$id")"
        echo
        ui_option 1 "添加端口/端口段（流量继续累计）"
        ui_option 2 "删除端口（已统计流量保留在本项）"
        ui_option 3 "整组替换端口"
        ui_option 4 "拆出部分端口为新监控项（新项从 0 开始计）"
        ui_option 5 "把本项合并到另一个监控项（流量相加）"
        ui_option 0 "返回"
        ui_prompt 5 choice || return 0
        case "$choice" in
            1) read -r -p " 要添加的端口（逗号分隔）: " input || return 0
               [ -n "$input" ] && input=$(parse_port_list "$input" | paste -sd,) && monitor_edit_ports "$id" "$input" "" "" &&
                   echo -e "${GREEN}已更新：$(monitor_ports_csv "$id")${NC}" ;;
            2) read -r -p " 要删除的成员（逗号分隔，端口段按原样写）: " input || return 0
               [ -n "$input" ] && input=$(parse_port_list "$input" | paste -sd,) && monitor_edit_ports "$id" "" "$input" "" &&
                   echo -e "${GREEN}已更新：$(monitor_ports_csv "$id")${NC}" ;;
            3) read -r -p " 新的完整端口列表: " input || return 0
               [ -n "$input" ] && input=$(parse_port_list "$input" | paste -sd,) && monitor_edit_ports "$id" "" "" "$input" &&
                   echo -e "${GREEN}已更新：$(monitor_ports_csv "$id")${NC}" ;;
            4) read -r -p " 要拆出的成员（逗号分隔）: " input || return 0
               [ -n "$input" ] || continue
               input=$(parse_port_list "$input" | paste -sd,) || continue
               read -r -p " 新监控项备注（可留空）: " remark || return 0
               copy=""; confirm " 新项是否复制本项的配额、重置策略和到期日" && copy=copy
               if target=$(monitor_split "$id" "$input" "$remark" "$copy"); then
                   echo -e "${GREEN}已拆出新监控项 $target${NC}"
               fi ;;
            5) target=$(select_monitor "合并到哪个监控项") || continue
               [ "$target" != "$id" ] || { echo -e "${RED}不能合并到自身${NC}"; continue; }
               echo "将把 $id 的端口与流量并入 $target，$id 的配额/限速/到期设置作废，以 $target 为准。"
               confirm " 确认合并" || continue
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
    ui_title "删除监控项"
    id=$(select_monitor "要删除的监控项") || return 0
    confirm " 确认删除 $id（$(monitor_label "$id")）及其统计、配额、限速与到期设置" || return 0
    monitor_remove "$id" && echo -e "${GREEN}已删除 $id${NC}"
    cron_sync || true
}

menu_quota_for() {
    local id="$1" limit policy quota
    quota=$(mget "$id" .quota.monthly_limit unlimited)
    [ "$(mget "$id" .quota.enabled false)" = "true" ] || quota=unlimited
    [ "$quota" != unlimited ] || quota="不限额"
    _menu_monitor_header "$id"
    ui_kv "当前配额" "$quota（$(billing_mode_label "$(mget "$id" .billing_mode double)")）"
    ui_kv "自动重置" "$(monitor_reset_label "$id" 2>/dev/null || echo 不自动重置)"
    echo
    read -r -p " 流量配额（如 500GB、1.5TB；0 取消配额；回车不变）: " limit || return 0
    if [ -n "$limit" ]; then
        monitor_set_quota "$id" "$limit" && echo -e "${GREEN}配额已更新${NC}"
    fi
    if confirm " 修改自动重置策略"; then
        policy=$(prompt_reset_policy "$(mget "$id" .reset_policy.day 1)") || return 0
        monitor_set_reset_policy "$id" "$policy" &&
            echo -e "${GREEN}重置策略已更新：$(monitor_reset_label "$id" 2>/dev/null || echo 不自动重置)${NC}"
    fi
}

menu_quota_reset() {
    local id
    ui_title "配额与自动重置"
    id=$(select_monitor "要设置的监控项") || return 0
    menu_quota_for "$id"
}

menu_bandwidth() {
    local id input rate current
    ui_title "带宽限制"
    id=$(select_monitor "要设置的监控项") || return 0
    if current=$(monitor_tc_rate "$id"); then current=$(format_tc_rate "$current"); else current="不限速"; fi
    _menu_monitor_header "$id"
    ui_kv "当前限速" "$current"
    ui_note "上下行分别限制，同一监控项的端口共享带宽"
    echo
    read -r -p " 带宽（如 100Mbps、1Gbps；0 取消限速；回车不变）: " input || return 0
    [ -n "$input" ] || return 0
    validate_bandwidth "$input" || { echo -e "${RED}格式无效，示例：100Mbps、1Gbps${NC}"; return 1; }
    if [ "$input" = "0" ]; then rate=0; else rate=$(convert_bandwidth_to_tc "$input"); fi
    if [ "$rate" != "0" ] && [ "$(tc_auto_recovery_state 2>/dev/null || echo 未启用)" != "已启用" ]; then
        show_tc_auto_recovery_notice 2>/dev/null || true
    fi
    tc_set_monitor_limit "$id" "$rate" && echo -e "${GREEN}带宽限制已更新${NC}"
}

menu_expiry() {
    local id input
    ui_title "服务到期"
    id=$(select_monitor "要设置的监控项") || return 0
    _menu_monitor_header "$id"
    ui_kv "当前到期" "$(monitor_expiry_label "$id" 2>/dev/null || echo 未设置)"
    echo
    read -r -p " 到期日 YYYY-MM-DD（0 取消到期；回车不变）: " input || return 0
    [ -n "$input" ] || return 0
    [ "$input" = "0" ] && input=""
    monitor_set_expiry "$id" "$input" && echo -e "${GREEN}到期设置已更新${NC}"
}

menu_billing_remark() {
    local id choice input remark
    ui_title "计费模式与备注"
    id=$(select_monitor "要修改的监控项") || return 0
    remark=$(mget "$id" .remark "")
    _menu_monitor_header "$id"
    echo
    ui_option 1 "计费模式（当前：$(billing_mode_label "$(mget "$id" .billing_mode double)")）"
    ui_option 2 "备注（当前：${remark:-无}）"
    ui_option 0 "返回"
    ui_prompt 2 choice || return 0
    case "$choice" in
        1) ui_note "double 双向：入站+出站，各按 2 倍计（与上游一致）；single 单向：入站+出站按 1 倍计"
           read -r -p " 模式 [double/single]: " input || return 0
           [ -n "$input" ] && monitor_set_billing "$id" "$input" && echo -e "${GREEN}已切换为$(billing_mode_label "$input")${NC}" ;;
        2) read -r -p " 新备注（最长 64 字符，留空清除）: " input || return 0
           monitor_set_remark "$id" "$input" && echo -e "${GREEN}备注已更新${NC}" ;;
    esac
}

menu_reset_now() {
    local id
    ui_title "立即重置流量"
    id=$(select_monitor "要清零的监控项") || return 0
    confirm " 确认清零 $id 的本周期流量与已用配额（自动重置日程不变）" || return 0
    reset_monitor "$id" manual && echo -e "${GREEN}已清零${NC}"
}

menu_config_io() {
    local choice file
    ui_title "配置导出/导入"
    ui_option 1 "导出配置与统计"
    ui_option 2 "导入配置包"
    ui_option 0 "返回"
    ui_prompt 2 choice || return 0
    case "$choice" in
        1) export_config ;;
        2) read -r -p " 配置包路径: " file || return 0
           [ -n "$file" ] && import_config "$file" ;;
    esac
}

show_dashboard() {
    local values='{}' total=0 count=0 machine state w
    printf '\n %b%s v%s%b %b·%b %s\n' "$BOLD_CYAN" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$NC" "$DIM" "$NC" "$(hostname)"
    ui_rule
    if has_monitors; then
        values=$(nft_read_values 2>/dev/null || echo '{}')
        count=$(monitor_ids | grep -c . || true)
        total=$(jq -rn --slurpfile c "$CONFIG_FILE" --argjson v "$values" '
            $c[0].monitors | to_entries | map(((($v[.key].in // 0) + ($v[.key].out // 0)) *
                (if (.value.billing_mode // "double") == "single" then 1 else 2 end))) | add // 0' 2>/dev/null || echo 0)
        if nft_table_exists; then state="${GREEN}● 监控中${NC}"; else state="${RED}● 规则缺失${NC}"; fi
        total=$(format_bytes "$total")
        ui_measure w "● 监控中   $count 个监控项   周期总流量 $total"
        if [ $((w + 2)) -le "$(ui_columns)" ]; then
            printf '  %b   %s 个监控项   周期总流量 %s\n' "$state" "$count" "$total"
        else
            printf '  %b   %s 个监控项\n  周期总流量 %s\n' "$state" "$count" "$total"
        fi
    else
        printf '  %b○ 未添加监控项%b   输入 1 添加\n' "$YELLOW" "$NC"
    fi
    machine=$(machine_traffic_summary 2>/dev/null || true)
    [ -z "$machine" ] || printf '  %b本机网卡本月%b  %s\n' "$DIM" "$NC" "$machine"
    has_monitors || return 0
    echo
    show_monitor_table "$values" || true
    if ! nft_runtime_drift >/dev/null 2>&1; then
        echo -e "  ${YELLOW}⚠ nftables 规则与配置不一致，建议执行 10. 系统自检/修复${NC}"
    fi
    if ! cron_in_sync 2>/dev/null; then
        echo -e "  ${YELLOW}⚠ 定时任务与配置不一致，建议执行 10. 系统自检/修复${NC}"
    fi
}

# 菜单动作在子 shell 中运行并重新打开 errexit：动作中途出错只结束这一个动作、回到菜单
# （2.0.0 中带宽格式错误、导入文件不存在等会让 set -e 直接结束整个菜单）。
# 必须作为普通命令调用：写成 `menu_run x || true` 或放进 if 条件时，bash 会连同其中的子 shell
# 一起忽略 set -e，动作出错后仍继续往下执行。动作对变量的修改不会带回菜单（菜单每轮重新读配置）。
menu_run() {
    local errexit=false
    case $- in *e*) errexit=true ;; esac
    set +e
    ( set -e; "$@" )
    [ "$errexit" = false ] || set -e
    return 0
}

show_main_menu() {
    local choice rc
    while true; do
        menu_clear
        show_dashboard
        ui_rule
        show_main_menu_options
        ui_prompt 17 choice || exit 0
        case "$choice" in
            1) menu_run menu_add_monitor ;;
            2) menu_run menu_edit_ports; continue ;;
            3) menu_run menu_remove_monitor ;;
            4) menu_run menu_quota_reset ;;
            5) menu_run menu_bandwidth ;;
            6) menu_run menu_expiry ;;
            7) menu_run menu_billing_remark ;;
            8) menu_run menu_reset_now ;;
            9) menu_run manage_notifications; continue ;;
            10) menu_run system_check_and_repair ;;
            11) menu_run manage_tc_recovery ;;
            12) menu_run manage_ip_guard; continue ;;
            13) menu_run dependency_menu; continue ;;
            14) menu_run menu_config_io ;;
            15) menu_run show_operation_logs ;;
            16) menu_run update_dog ;;
            17) # 卸载在当前 shell 运行：一旦开始（不论是否全部成功）程序文件已删除，直接退出菜单；
                # 取消卸载则回到菜单（2.0.0 取消后也会退出菜单）。
                DOG_UNINSTALL_STARTED=false; rc=0
                uninstall_dog || rc=$?
                [ "$DOG_UNINSTALL_STARTED" = false ] || exit "$rc" ;;
            0) exit 0 ;;
            *) continue ;;
        esac
        pause
    done
}
