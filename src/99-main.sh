# ── 命令行入口 ────────────────────────────────────────────────────

show_usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

用法：dog                         打开交互菜单
      dog list [--json]           列出监控项
      dog status                  打印状态报告（与推送内容相同：只含开启推送的监控项）
      dog add <端口> [--remark R]  添加监控项；"80,443" 为一项，"80;443" 为两项，"8000-8010" 为端口段
      dog edit <ID|端口> [选项]    修改监控项：
          --add P,P   --del P,P   --set P,P        增加 / 删除 / 整组替换端口（流量连续）
          --remark R  --quota 500GB|0  --billing double|single
          --limit 100Mbps|0  --expiry YYYY-MM-DD|0  --notify on|off（是否出现在状态推送中）
          --reset monthly:1 | days:30[@YYYY-MM-DD] | months:3[@YYYY-MM-DD][:15] | yearly:1-1 | once:YYYY-MM-DD | none
      dog split <ID> <端口> [--remark R] [--copy]   拆出为新监控项（--copy 复制配额/重置/到期）
      dog merge <源ID> <目标ID>                     合并（流量相加，保留目标设置）
      dog remove <ID|端口>        删除监控项
      dog reset <ID|端口>         立即清零本周期流量
      --yes                       非交互确认

维护：--self-check  --repair  --restore-runtime  --tc-status  --recover-tc --manual|--auto
      --update [--force]  --uninstall [--keep-config]  --export [目录]  --import <文件>
      --dependencies check|install|owned|remove [--all] [--yes]  --logs  --version
EOF
}

# "monthly:1" 等简写 → 重置策略 JSON
parse_reset_spec() {
    local s="$1" today
    today=$(get_current_date)
    case "$s" in
        none) echo '{"type":"none"}' ;;
        monthly:*) validate_day_1_31 "${s#*:}" && jq -cn --argjson d "${s#*:}" '{type:"monthly",day:$d}' ;;
        days:*)
            local rest="${s#days:}" n a
            n="${rest%%@*}"; a="$today"; [[ "$rest" == *@* ]] && a="${rest#*@}"
            [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && is_valid_date "$a" &&
                jq -cn --argjson e "$n" --arg a "$a" '{type:"interval_days",every:$e,anchor_date:$a}' ;;
        months:*)
            local rest="${s#months:}" n a d
            n="${rest%%[@:]*}"; a="$today"; d=""
            if [[ "$rest" == *@* ]]; then a="${rest#*@}"; a="${a%%:*}"; fi
            [[ "$rest" =~ :([0-9]+)$ ]] && d="${BASH_REMATCH[1]}"
            [ -n "$d" ] || d=$((10#${a:8:2}))
            [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && is_valid_date "$a" && validate_day_1_31 "$d" &&
                jq -cn --argjson e "$n" --arg a "$a" --argjson d "$d" '{type:"interval_months",every:$e,anchor_date:$a,day:$d}' ;;
        yearly:*-*)
            local m="${s#yearly:}"; local d="${m#*-}"; m="${m%-*}"
            validate_month_1_12 "$m" && validate_day_1_31 "$d" && jq -cn --argjson m "$m" --argjson d "$d" '{type:"yearly",month:$m,day:$d}' ;;
        once:*) is_valid_date "${s#once:}" && jq -cn --arg d "${s#once:}" '{type:"fixed_date",date:$d}' ;;
        *) return 1 ;;
    esac
}

cli_list() {
    if [ "${1:-}" = "--json" ]; then
        jq -n --argjson c "$(jq '.monitors' "$CONFIG_FILE")" --argjson v "$(nft_read_values)" '
            $c | to_entries | map(.value + {id: .key, notify: (.value.notify != false), counters: ($v[.key] // null)})'
    else
        show_monitor_table || true
    fi
}

cli_edit() {
    local ref="$1" id add="" del="" set="" rc=0
    shift
    id=$(resolve_monitor "$ref") || { dog_error "找不到监控项：$ref"; return 1; }
    local -a ops=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --add|--del|--set) [ -n "${2:-}" ] || { show_usage; return 2; }
                local v; v=$(parse_port_list "$2" | paste -sd,) || return 1
                case "$1" in --add) add="$v" ;; --del) del="$v" ;; --set) set="$v" ;; esac; shift 2 ;;
            --remark|--quota|--billing|--limit|--expiry|--reset|--notify)
                [ "$#" -ge 2 ] || { show_usage; return 2; }
                ops+=("$1" "$2"); shift 2 ;;
            *) dog_error "未知选项：$1"; return 2 ;;
        esac
    done
    if [ -n "$add$del$set" ]; then
        monitor_edit_ports "$id" "$add" "$del" "$set" || rc=1
    fi
    local i
    for ((i = 0; i < ${#ops[@]}; i += 2)); do
        local opt="${ops[i]}" val="${ops[i+1]}"
        case "$opt" in
            --remark) monitor_set_remark "$id" "$val" || rc=1 ;;
            --quota) monitor_set_quota "$id" "$val" || rc=1 ;;
            --billing) monitor_set_billing "$id" "$val" || rc=1 ;;
            --notify) monitor_set_notify "$id" "$val" || rc=1 ;;
            --expiry) [ "$val" = "0" ] && val=""; monitor_set_expiry "$id" "$val" || rc=1 ;;
            --limit)
                if [ "$val" = "0" ]; then tc_set_monitor_limit "$id" 0 || rc=1
                elif validate_bandwidth "$val"; then tc_set_monitor_limit "$id" "$(convert_bandwidth_to_tc "$val")" || rc=1
                else dog_error "带宽格式无效：$val"; rc=1; fi ;;
            --reset)
                local p; p=$(parse_reset_spec "$val") || { dog_error "重置策略格式无效：$val"; rc=1; continue; }
                monitor_set_reset_policy "$id" "$p" || rc=1 ;;
        esac
    done
    [ "$rc" -eq 0 ] && echo "$id: $(monitor_ports_csv "$id")"
    return "$rc"
}

main() {
    local args=() a
    for a in "$@"; do
        if [ "$a" = "--yes" ] || [ "$a" = "-y" ]; then DOG_NONINTERACTIVE=true; else args+=("$a"); fi
    done
    set -- "${args[@]+"${args[@]}"}"

    case "${1:-}" in
        --version|-v) echo "$SCRIPT_NAME v$SCRIPT_VERSION"; return 0 ;;
        --help|-h|help) show_usage; return 0 ;;
        --cron-env-probe) command -v nft >/dev/null && command -v jq >/dev/null; return ;;
        --validate-config) [ -n "${2:-}" ] || return 2; validate_config_file "$2"; return ;;
    esac
    check_root

    case "${1:-}" in
        --dependencies) shift; dependency_cli "$@"; return ;;
        --uninstall) uninstall_dog "${2:-}"; return ;;
        --logs) show_operation_logs; return ;;   # 只读，不创建配置目录
    esac

    if ! command -v jq >/dev/null 2>&1 || ! command -v nft >/dev/null 2>&1; then
        if is_interactive; then
            dependency_install_missing false core || { dog_error "缺少 jq/nft，无法继续"; return 1; }
        else
            dog_error "缺少 jq 或 nft，无法继续（PATH=$PATH）"; return 1
        fi
    fi
    ensure_config || return 1
    if legacy_needs_migration; then
        migrate_from_legacy || return 1
    fi

    local cmd="${1:-}"
    [ "$#" -gt 0 ] && shift
    case "$cmd" in
        "")
            [ -f "$INSTALLED_SCRIPT_PATH" ] && [ -x "$SHORTCUT_PATH" ] || install_self || true
            validate_config_file "$CONFIG_FILE" || { dog_error "配置无效，请修正 $CONFIG_FILE 或运行 dog --repair"; return 1; }
            show_main_menu ;;
        list) cli_list "$@" ;;
        status)
            local src=0
            build_status_report "$(hostname)" || src=$?
            [ "$src" -ne 3 ] || src=0   # 没有开启推送的监控项：已打印说明，不算失败
            return "$src" ;;
        add)
            [ -n "${1:-}" ] || { show_usage; return 2; }
            local input="$1" remark="" units u rc=0
            [ "${2:-}" = "--remark" ] && remark="${3:-}"
            parse_monitor_units "$input" units || return 1
            for u in "${units[@]}"; do monitor_add "$u" "$remark" || rc=1; done
            cron_sync || true
            return "$rc" ;;
        edit) [ -n "${1:-}" ] || { show_usage; return 2; }; cli_edit "$@" ;;
        split)
            [ -n "${2:-}" ] || { show_usage; return 2; }
            local sid sp sr="" sc=""
            sid=$(resolve_monitor "$1") || { dog_error "找不到监控项：$1"; return 1; }
            sp=$(parse_port_list "$2" | paste -sd,) || return 1
            shift 2
            while [ "$#" -gt 0 ]; do
                case "$1" in --remark) sr="${2:-}"; shift 2 ;; --copy) sc=copy; shift ;; *) return 2 ;; esac
            done
            monitor_split "$sid" "$sp" "$sr" "$sc" ;;
        merge)
            [ -n "${2:-}" ] || { show_usage; return 2; }
            local ms md
            ms=$(resolve_monitor "$1") && md=$(resolve_monitor "$2") || { dog_error "找不到监控项"; return 1; }
            monitor_merge "$ms" "$md" ;;
        remove|rm)
            local rid; rid=$(resolve_monitor "${1:-}") || { dog_error "找不到监控项：${1:-}"; return 1; }
            confirm "确认删除 $rid（$(monitor_label "$rid")）" || return 1
            monitor_remove "$rid" && cron_sync ;;
        reset)
            local zid; zid=$(resolve_monitor "${1:-}") || { dog_error "找不到监控项：${1:-}"; return 1; }
            confirm "确认清零 $zid 本周期流量" || return 1
            reset_monitor "$zid" manual ;;

        # 定时任务入口
        --tick) cron_tick ;;
        --boot|--restore-nft-runtime) restore_runtime_nft_only ;;
        --send-status) send_status_report "${1:-telegram}" ;;
        --send-telegram-status) send_status_report telegram ;;
        --send-wecom-status) send_status_report wecom ;;
        # 1.5.x 旧定时任务兼容（cron 刷新前仍可能被调用）
        --snapshot-traffic|--check-scheduled-resets|--check-port-expirations|--collect-machine-traffic)
            cron_tick ;;

        --self-check) self_check ;;
        --repair|--repair-traffic-rules|--refresh-all-cron) system_check_and_repair ;;
        --refresh-notification-cron|--refresh-port-reset-cron) cron_sync ;;
        --sync-notification-modules) echo "2.0 起通知功能已内置，无需同步模块" ;;
        --restore-runtime) restore_runtime ;;
        --tc-status) dog_tc_status ;;
        --recover-tc) recover_tc_runtime "${1:---manual}" ;;
        --install) install_self && cron_sync ;;
        # --finalize-update：1.5.x 的 --update 装好新脚本后调用的入口，失败时由旧版负责回滚。
        --post-update|--finalize-update) post_update ;;
        --update) update_dog "${1:-}" ;;
        --export) export_config "${1:-/root}" ;;
        --import) [ -n "${1:-}" ] || return 2; import_config "$1" ;;
        *) show_usage; return 2 ;;
    esac
}
