# ── 自检与修复 ────────────────────────────────────────────────────

SC_ERRORS=0
SC_WARNINGS=0
sc_ok() { echo -e "  ${GREEN}✓${NC} $*"; }
sc_warn() { echo -e "  ${YELLOW}!${NC} $*"; SC_WARNINGS=$((SC_WARNINGS + 1)); }
sc_err() { echo -e "  ${RED}✗${NC} $*"; SC_ERRORS=$((SC_ERRORS + 1)); }

nft_version_ok() {
    local v
    v=$(nft --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
    [ -n "$v" ] && ! version_lt "$v" "0.9.2"
}

# 只读自检；有错误返回 1。
self_check() {
    local exe cmd rt drift id age saved c
    SC_ERRORS=0; SC_WARNINGS=0
    echo -e "${BLUE}=== Dog 自检（v${SCRIPT_VERSION}） ===${NC}"

    echo "[运行环境]"
    for cmd in nft jq tc ip crontab curl flock awk ss sha256sum; do
        if command -v "$cmd" >/dev/null 2>&1; then :; else sc_err "缺少命令：$cmd"; fi
    done
    if nft_version_ok; then sc_ok "nftables $(nft --version 2>/dev/null | awk '{print $2}')（需要 ≥ 0.9.2）"; else sc_err "nftables 版本过低或不可用（需要 ≥ 0.9.2）"; fi
    exe=$(get_script_exec_path)
    # 用 cron 的最小环境运行一次，确认脚本自身能找到 nft（1.5.x 的空推送就是在这里失败）。
    if env -i HOME=/root PATH=/usr/bin:/bin "$exe" --cron-env-probe >/dev/null 2>&1; then
        sc_ok "cron 最小环境（PATH=/usr/bin:/bin）下可找到 nft 与 jq"
    else
        sc_err "cron 最小环境下脚本无法运行或找不到 nft：$exe"
    fi
    if cron_service_is_running; then sc_ok "cron 服务运行中"; else sc_err "cron 服务未运行，定时统计/重置/推送不会执行"; fi

    echo "[配置]"
    if ! config_exists; then
        sc_warn "尚未创建配置"
    elif [ "$(config_schema)" = "1" ]; then
        sc_err "仍是 1.5.x 配置，请运行 dog --repair 完成迁移"
    else
        # 校验错误直接收进变量：不在 /tmp 用可预测文件名（root 写入可被符号链接劫持）。
        local verr
        if verr=$(validate_config_file "$CONFIG_FILE" 2>&1 >/dev/null); then
            sc_ok "配置有效：$(monitor_ids | grep -c .) 个监控项"
        else
            while IFS= read -r c; do [ -n "$c" ] && sc_err "$c"; done <<< "$verr"
        fi
    fi
    [ "$(config_schema)" = "2" ] || { echo; echo "错误 $SC_ERRORS，警告 $SC_WARNINGS"; [ "$SC_ERRORS" -eq 0 ]; return; }

    echo "[nftables 计数与配额]"
    if has_monitors; then
        rt=$(nft_runtime_json 2>/dev/null || echo null)
        if [ "$rt" = "null" ]; then
            sc_err "表 $NFT_FAMILY $NFT_TABLE 不存在"
        elif drift=$(nft_runtime_drift "$rt"); then
            sc_ok "规则、计数器、配额、到期封锁与配置一致"
        else
            while IFS= read -r c; do sc_err "$c"; done <<< "$drift"
        fi
    else
        sc_ok "无监控项"
    fi

    echo "[带宽限制]"
    local any_tc=false
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        monitor_tc_rate "$id" >/dev/null || continue
        any_tc=true
        if tc_monitor_complete "$id"; then sc_ok "$id 限速 $(monitor_tc_rate "$id") 完整"; else sc_err "$id 限速对象缺失或不一致"; fi
    done < <(monitor_ids)
    [ "$any_tc" = "true" ] || sc_ok "未设置限速"
    if [ -e /etc/trafficcop-lite/trafficcop-lite-monitor.sh ]; then
        if tc_ntc_compatible; then sc_ok "TrafficCop Lite 已安装且支持 Dog 2.0 类清单"
        elif [ "$any_tc" = "true" ]; then sc_err "TrafficCop Lite 版本过旧（不识别 $TC_CLASS_MANIFEST_SCHEMA），请升级到 1.2.0+"
        else sc_warn "TrafficCop Lite 版本过旧；设置限速前需先升级"; fi
    fi
    if [ "$any_tc" = "true" ] && [ ! -s "$TC_INTEROP_FILE" ]; then sc_err "缺少类清单 $TC_INTEROP_FILE"; fi

    echo "[定时任务与数据]"
    if cron_in_sync; then sc_ok "Dog 定时任务与配置一致"; else sc_err "Dog 定时任务缺失或与配置不一致"; fi
    if has_monitors; then
        saved=$(jq -r '.saved_at // empty' "$TRAFFIC_DATA_FILE" 2>/dev/null || true)
        if [ -n "$saved" ]; then
            age=$(( $(date +%s) - $(date -d "$saved" +%s 2>/dev/null || echo 0) ))
            if [ "$age" -le 300 ]; then sc_ok "流量灾备 ${age}s 前更新"; else sc_warn "流量灾备已 $((age / 60)) 分钟未更新（定时任务可能未执行）"; fi
        else
            sc_warn "尚无流量灾备文件"
        fi
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            monitor_has_auto_reset "$id" || continue
            monitor_next_reset "$id" >/dev/null 2>&1 || sc_err "$id 无法计算下次重置日期"
        done < <(monitor_ids)
    fi

    echo "[通知]"
    for c in telegram wecom; do
        channel_enabled "$c" || continue
        if [ "$c" = telegram ]; then
            [ -n "$(cfg '.notifications.telegram.bot_token // ""')" ] && [ -n "$(cfg '.notifications.telegram.chat_id // ""')" ] &&
                sc_ok "Telegram 已配置（推送 $(channel_status_enabled telegram && cfg '.notifications.telegram.status_notifications.interval' || echo 关闭)）" ||
                sc_err "Telegram 已开启但 Token/Chat ID 不完整"
            telegram_api_base >/dev/null || sc_err "Telegram 自定义线路无效"
        else
            [ -n "$(cfg '.notifications.wecom.webhook_url // ""')" ] && sc_ok "企业微信已配置" || sc_err "企业微信已开启但未设置 Webhook"
        fi
    done

    echo
    if [ "$SC_ERRORS" -eq 0 ]; then
        echo -e "${GREEN}自检通过${NC}（警告 $SC_WARNINGS）"
    else
        echo -e "${RED}发现 $SC_ERRORS 个错误${NC}（警告 $SC_WARNINGS），可运行 dog --repair 自动修复"
    fi
    [ "$SC_ERRORS" -eq 0 ]
}

# 修复：补依赖、迁移、重建规则与限速、刷新定时任务，然后自检。
system_check_and_repair() {
    echo -e "${BLUE}=== 系统修复 ===${NC}"
    # 只检测一次；缺失时交给 dependency_install_missing（--yes 时自动装，否则询问）。
    # check_dependencies 自带无确认安装，不能与之串用（会绕过确认并重复执行 apt）。
    dependency_report core >/dev/null 2>&1 || dependency_install_missing "$DOG_NONINTERACTIVE" core || true
    ensure_config || return 1
    if legacy_needs_migration; then migrate_from_legacy || return 1; fi
    validate_config_file "$CONFIG_FILE" || { dog_error "配置无效，请先修正 $CONFIG_FILE"; return 1; }
    create_shortcut || true
    if [ "$SCRIPT_PATH" != "$INSTALLED_SCRIPT_PATH" ] && [ ! -f "$INSTALLED_SCRIPT_PATH" ]; then install_self || true; fi
    dog_lock || return 75
    echo "· 修复 nftables 规则"; runtime_ensure_nft || true
    echo "· 同步到期封锁"; check_expirations || true
    echo "· 刷新统计与灾备"; stats_snapshot || true
    dog_unlock
    echo "· 恢复带宽限制"; tc_restore_all || true
    echo "· 刷新定时任务"; cron_sync || true
    echo
    self_check
}
