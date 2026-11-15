# ── 状态报告与通知（Telegram / 企业微信，已内置，不再下载外部模块） ──
# 关键约束：读数失败时绝不发送“空报告”。要么发送完整报告，要么发送带原因的告警并返回非零。

readonly NOTIFY_RETRIES=2
readonly NOTIFY_CONNECT_TIMEOUT=10
readonly NOTIFY_MAX_TIME=30

monitor_status_tags() {
    local id="$1" tags="" remark mode limit label exp rate
    remark=$(mget "$id" .remark "")
    [ -n "$remark" ] && tags+="[备注:${remark}]"
    mode=$(mget "$id" .billing_mode double)
    limit=$(mget "$id" .quota.monthly_limit unlimited)
    [ "$(mget "$id" .quota.enabled false)" = "true" ] || limit=unlimited
    if [ "$limit" != "unlimited" ]; then
        if [ "$mode" = "single" ]; then tags+="[单向${limit}]"; else tags+="[双向${limit}]"; fi
    else
        if [ "$mode" = "single" ]; then tags+="[单向计费]"; else tags+="[双向计费]"; fi
    fi
    label=$(monitor_reset_label "$id" 2>/dev/null) && tags+="[${label}]"
    exp=$(monitor_expiry_label "$id" 2>/dev/null) && tags+="[${exp}]"
    rate=$(monitor_tc_rate "$id" 2>/dev/null) && tags+="[限速:${rate}]"
    printf '%s' "$tags"
}

build_usage_progress_bar() {
    local percent="${1:-0}" width=20 filled i bar=""
    [ "$percent" -gt 100 ] && percent=100
    filled=$((percent * width / 100))
    for ((i = 0; i < width; i++)); do
        if [ "$i" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
    done
    printf '%s' "$bar"
}

# 生成状态报告正文。读数失败时输出告警正文并返回 2。
build_status_report() {
    local server="${1:-$(hostname)}" now values total=0 count=0 body="" id idx=0
    local in_b out_b mult billed_in billed_out billed ports limit lbytes pct
    now=$(beijing_date '+%Y-%m-%d %H:%M:%S')
    count=$(monitor_ids | grep -c . || true)
    if ! nft_available; then
        printf '⚠️ 服务器: %s | ⏰ %s\n流量读取失败：找不到 nft 命令（PATH=%s）\n请登录服务器运行 dog --self-check\n' "$server" "$now" "$PATH"
        return 2
    fi
    if ! nft_table_exists; then
        printf '⚠️ 服务器: %s | ⏰ %s\n流量读取失败：nftables 表 %s 不存在（规则可能被清空或重启后未恢复）\n请运行 dog --repair\n' "$server" "$now" "$NFT_TABLE"
        return 2
    fi
    values=$(nft_read_values)
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        if ! jq -e --arg id "$id" 'has($id)' <<< "$values" >/dev/null; then
            printf '⚠️ 服务器: %s | ⏰ %s\n流量读取失败：监控项 %s 的计数器缺失\n请运行 dog --repair\n' "$server" "$now" "$id"
            return 2
        fi
        idx=$((idx + 1))
        read -r in_b out_b < <(jq -r --arg id "$id" '.[$id] | "\(.in) \(.out)"' <<< "$values")
        mult=$(monitor_billing_multiplier "$id")
        billed_in=$((in_b * mult)); billed_out=$((out_b * mult)); billed=$((billed_in + billed_out))
        total=$((total + billed))
        ports=$(monitor_ports_csv "$id")
        [ -n "$body" ] && body+=$'\n\n'
        body+="${idx}. [${id}]$(monitor_status_tags "$id") | 端口:${ports}"$'\n'
        body+="总流量:$(format_bytes "$billed") | 入站(下载):$(format_bytes "$billed_in") | 出站(上传):$(format_bytes "$billed_out")"
        limit=$(mget "$id" .quota.monthly_limit unlimited)
        if [ "$(mget "$id" .quota.enabled false)" = "true" ] && [ "$limit" != "unlimited" ] &&
           lbytes=$(parse_size_to_bytes "$limit") && [ "$lbytes" -gt 0 ]; then
            pct=$((billed * 100 / lbytes))
            body+=$'\n'"$(format_bytes "$billed")/${limit} | ${pct}%$([ "$pct" -ge 100 ] && echo ' (超限)') | $(monitor_cycle_range "$id")"
            body+=$'\n'"[$(build_usage_progress_bar "$pct")]"
        fi
    done < <(monitor_ids)
    printf '🔗 服务器: %s | ⏰ %s\n' "$server" "$now"
    printf '────────────────────────────────────────\n'
    printf '状态: 监控中 | 监控项: %s个 | 周期总流量: %s\n' "$count" "$(format_bytes "$total")"
    printf '────────────────────────────────────────\n'
    printf '%s\n' "$body"
}

# 按行截断到不超过 max_bytes 字节，不会切断多字节字符。
truncate_lines_bytes() {
    local max="$1"
    LC_ALL=C awk -v max="$max" 'BEGIN { n = 0 }
        { len = length($0) + 1 }
        n + len > max { print "[消息过长，已截断]"; exit }
        { print; n += len }'
}

# ── Telegram ──

telegram_api_base() {
    local route base
    route=$(cfg '.notifications.telegram.api_route // "official"')
    if [ "$route" != "custom" ]; then echo "https://api.telegram.org"; return 0; fi
    base=$(cfg '.notifications.telegram.custom_api_base // ""' | tr -d ' ')
    base="${base%/}"
    [[ "$base" =~ ^https:// ]] || [[ "$base" =~ ^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/|$) ]] || return 1
    echo "$base"
}

telegram_send() {
    local text="$1" token chat base url resp rc attempt=0 masked
    token=$(cfg '.notifications.telegram.bot_token // ""')
    chat=$(cfg '.notifications.telegram.chat_id // ""')
    if [ -z "$token" ] || [ -z "$chat" ]; then log_notification "Telegram 配置不完整"; return 1; fi
    base=$(telegram_api_base) || { log_notification "Telegram 自定义线路无效（必须是 https://，http 仅限本机回环）"; return 1; }
    if [[ "$base" =~ /bot$ ]]; then url="${base}${token}/sendMessage"; else url="${base}/bot${token}/sendMessage"; fi
    masked="${url//$token/${token:0:6}***}"
    text=$(printf '%s\n' "$text" | truncate_lines_bytes 3900)
    while [ "$attempt" -le "$NOTIFY_RETRIES" ]; do
        rc=0
        # URL（含 token）经 -K - 从标准输入传给 curl，不出现在进程参数里。
        resp=$(printf 'url = "%s"\n' "$url" | curl -sS -K - --connect-timeout "$NOTIFY_CONNECT_TIMEOUT" \
            --max-time "$NOTIFY_MAX_TIME" --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}" 2>&1) || rc=$?
        if [ "$rc" -eq 0 ] && jq -e '.ok == true' <<< "$resp" >/dev/null 2>&1; then
            log_notification "Telegram 发送成功（$masked）"
            return 0
        fi
        local migrated
        migrated=$(jq -r '.parameters.migrate_to_chat_id // empty' <<< "$resp" 2>/dev/null || true)
        if [ -n "$migrated" ] && [ "$migrated" != "$chat" ]; then
            chat="$migrated"
            config_update '.notifications.telegram.chat_id = $c' --arg c "$migrated" || true
            log_notification "Telegram 群已升级为超级群，chat_id 已更新为 $migrated"
            continue
        fi
        log_notification "Telegram 发送失败（curl=$rc，$masked）：$(tr '\n' ' ' <<< "$resp" | cut -c1-200)"
        attempt=$((attempt + 1))
        [ "$attempt" -le "$NOTIFY_RETRIES" ] && sleep 2
    done
    return 1
}

# ── 企业微信 ──

wecom_send() {
    local text="$1" hook payload resp rc attempt=0
    hook=$(cfg '.notifications.wecom.webhook_url // ""')
    [ -n "$hook" ] || { log_notification "企业微信 Webhook 未配置"; return 1; }
    [[ "$hook" =~ ^https:// ]] || { log_notification "企业微信 Webhook 必须使用 https://"; return 1; }
    text=$(printf '%s\n' "$text" | truncate_lines_bytes 2000)
    payload=$(jq -cn --arg c "$text" '{msgtype: "text", text: {content: $c}}')
    while [ "$attempt" -le "$NOTIFY_RETRIES" ]; do
        rc=0
        resp=$(printf 'url = "%s"\n' "$hook" | curl -sS -K - --connect-timeout "$NOTIFY_CONNECT_TIMEOUT" \
            --max-time "$NOTIFY_MAX_TIME" -H 'Content-Type: application/json' -d "$payload" 2>&1) || rc=$?
        if [ "$rc" -eq 0 ] && jq -e '.errcode == 0' <<< "$resp" >/dev/null 2>&1; then
            log_notification "企业微信发送成功"
            return 0
        fi
        log_notification "企业微信发送失败（curl=$rc）：$(tr '\n' ' ' <<< "$resp" | cut -c1-200)"
        attempt=$((attempt + 1))
        [ "$attempt" -le "$NOTIFY_RETRIES" ] && sleep 2
    done
    return 1
}

channel_enabled() {
    local c="$1"
    [ "$(cfg ".notifications.${c}.enabled // false")" = "true" ]
}

channel_status_enabled() {
    local c="$1"
    channel_enabled "$c" && [ "$(cfg ".notifications.${c}.status_notifications.enabled // false")" = "true" ]
}

channel_server_name() {
    local n
    n=$(cfg ".notifications.${1}.server_name // \"\"")
    [ -n "$n" ] || n=$(hostname)
    echo "$n"
}

# 发送状态报告到指定通道（telegram|wecom）。返回码：0 成功，1 发送失败，2 已发送读数告警。
send_status_report() {
    local channel="$1" report rc=0 send_rc=0
    has_monitors || return 0
    report=$(build_status_report "$(channel_server_name "$channel")") || rc=$?
    case "$channel" in
        telegram) telegram_send "$report" || send_rc=1 ;;
        wecom) wecom_send "$report" || send_rc=1 ;;
        *) return 1 ;;
    esac
    if [ "$rc" -ne 0 ]; then
        log_notification "$channel 状态报告读数失败，已发送告警：$(head -n 2 <<< "$report" | tail -n 1)"
        return 2
    fi
    return "$send_rc"
}

notification_interval_cron_expression() {
    case "$1" in
        1m) echo "* * * * *" ;;
        15m) echo "*/15 * * * *" ;;
        30m) echo "*/30 * * * *" ;;
        1h) echo "0 * * * *" ;;
        2h) echo "0 */2 * * *" ;;
        6h) echo "0 */6 * * *" ;;
        12h) echo "0 */12 * * *" ;;
        24h) echo "0 0 * * *" ;;
        *) return 1 ;;
    esac
}

select_notification_interval() {
    local choice
    {
        echo "推送周期：1) 1分钟  2) 15分钟  3) 30分钟  4) 1小时  5) 2小时  6) 6小时  7) 12小时  8) 24小时"
    } >&2
    read -r -p "请选择 [1-8，默认 4]: " choice
    case "${choice:-4}" in
        1) echo 1m ;; 2) echo 15m ;; 3) echo 30m ;; 4) echo 1h ;;
        5) echo 2h ;; 6) echo 6h ;; 7) echo 12h ;; 8) echo 24h ;;
        *) return 1 ;;
    esac
}

manage_notification_channel() {
    local c="$1" title choice v interval
    [ "$c" = telegram ] && title="Telegram" || title="企业微信"
    while true; do
        echo
        echo -e "${BLUE}=== ${title} 通知 ===${NC}"
        echo "状态：通道 $(channel_enabled "$c" && echo 开启 || echo 关闭) | 定时报告 $(channel_status_enabled "$c" && echo "开启（$(cfg ".notifications.${c}.status_notifications.interval // \"1h\"")）" || echo 关闭)"
        if [ "$c" = telegram ]; then
            echo "1. 设置 Bot Token 与 Chat ID"
            echo "5. 切换 API 线路（当前：$(cfg '.notifications.telegram.api_route // "official"')）"
        else
            echo "1. 设置 Webhook 地址"
        fi
        echo "2. 设置服务器名称（当前：$(channel_server_name "$c")）"
        echo "3. 开关定时报告并设置周期"
        echo "4. 立即发送一次测试报告"
        echo "6. 关闭此通道"
        echo "0. 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1)
                if [ "$c" = telegram ]; then
                    read -r -p "Bot Token: " v
                    [ -n "$v" ] || continue
                    local chat
                    read -r -p "Chat ID: " chat
                    config_update '.notifications.telegram.bot_token = $t | .notifications.telegram.chat_id = $c | .notifications.telegram.enabled = true' \
                        --arg t "$v" --arg c "$chat" && echo -e "${GREEN}已保存${NC}"
                else
                    read -r -p "Webhook 地址（https://qyapi.weixin.qq.com/...）: " v
                    [[ "$v" =~ ^https:// ]] || { echo -e "${RED}必须是 https:// 地址${NC}"; continue; }
                    config_update '.notifications.wecom.webhook_url = $u | .notifications.wecom.enabled = true' --arg u "$v" &&
                        echo -e "${GREEN}已保存${NC}"
                fi ;;
            2)
                read -r -p "服务器名称: " v
                config_update ".notifications.${c}.server_name = \$n" --arg n "$v" ;;
            3)
                if channel_status_enabled "$c" && confirm "定时报告已开启，是否关闭"; then
                    config_update ".notifications.${c}.status_notifications.enabled = false"
                else
                    interval=$(select_notification_interval) || { echo -e "${RED}无效选择${NC}"; continue; }
                    config_update ".notifications.${c}.status_notifications = {enabled: true, interval: \$i}" --arg i "$interval"
                fi
                cron_sync || true ;;
            4)
                local rc=0
                send_status_report "$c" || rc=$?
                case "$rc" in
                    0) echo -e "${GREEN}发送成功${NC}" ;;
                    2) echo -e "${YELLOW}读数失败，已发送告警，请运行 dog --self-check${NC}" ;;
                    *) echo -e "${RED}发送失败，详见 $NOTIFY_LOG_FILE${NC}" ;;
                esac ;;
            5)
                [ "$c" = telegram ] || continue
                echo "1) 官方 api.telegram.org  2) 自定义反代地址"
                read -r -p "请选择: " v
                if [ "$v" = 2 ]; then
                    local base
                    read -r -p "API 基础地址（https://example.com）: " base
                    base="${base%/}"
                    [[ "$base" =~ ^https:// ]] || [[ "$base" =~ ^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/|$) ]] ||
                        { echo -e "${RED}远程地址必须使用 https://${NC}"; continue; }
                    config_update '.notifications.telegram.api_route = "custom" | .notifications.telegram.custom_api_base = $b' --arg b "$base"
                else
                    config_update '.notifications.telegram.api_route = "official"'
                fi ;;
            6)
                config_update ".notifications.${c}.enabled = false" && cron_sync || true ;;
            0|"") return 0 ;;
        esac
    done
}

manage_notifications() {
    local choice
    while true; do
        echo
        echo -e "${BLUE}=== 通知管理 ===${NC}"
        echo "1. Telegram"
        echo "2. 企业微信"
        echo "3. 查看通知日志"
        echo "0. 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1) manage_notification_channel telegram ;;
            2) manage_notification_channel wecom ;;
            3) tail -n 40 "$NOTIFY_LOG_FILE" 2>/dev/null || echo "暂无日志"; pause ;;
            0|"") return 0 ;;
        esac
    done
}
