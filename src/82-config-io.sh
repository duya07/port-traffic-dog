# ── 配置导出 / 导入 ───────────────────────────────────────────────
# 配置包是 tar.gz，根目录 port-traffic-dog-config/。导入只读取白名单中的 JSON 数据文件，
# 不会导入任何可执行内容（1.5.x 会把包内的通知脚本复制进来并由 root cron 执行）。

readonly CONFIG_IO_FILES="config.json traffic_data.json traffic_stats.json reset_history.json"

export_config() {
    local out_dir="${1:-/root}" ts tmp pkg archive f
    ts=$(date +%Y%m%d-%H%M%S)
    archive="$out_dir/port-traffic-dog-config-$ts.tar.gz"
    dog_lock || return 75
    if has_monitors && ! stats_snapshot; then
        echo -e "${YELLOW}警告：刷新内核计数失败，导出的流量为最近一次灾备值${NC}" >&2
    fi
    tmp=$(mktemp -d); pkg="$tmp/port-traffic-dog-config"
    mkdir -p "$pkg"
    for f in $CONFIG_IO_FILES; do
        [ -f "$CONFIG_DIR/$f" ] && cp -p "$CONFIG_DIR/$f" "$pkg/"
    done
    dog_unlock
    printf 'version=%s\nexported_at=%s\nhost=%s\nmonitors=%s\n' "$SCRIPT_VERSION" "$(date -u +%FT%TZ)" \
        "$(hostname)" "$(jq -r '[.monitors | keys[]] | join(" ")' "$CONFIG_FILE" 2>/dev/null)" > "$pkg/package_info.txt"
    ( umask 077; tar -czf "$archive" -C "$tmp" port-traffic-dog-config ) || { rm -rf "$tmp"; dog_error "打包失败"; return 1; }
    rm -rf "$tmp"
    chmod 600 "$archive"
    dog_log_event export_config 0
    echo -e "${GREEN}已导出：$archive（包含 Telegram/企业微信凭据，请妥善保管）${NC}"
}

import_config() {
    local archive="$1" tmp src backup f schema rc=0
    [ -f "$archive" ] || { dog_error "文件不存在：$archive"; return 1; }
    tmp=$(mktemp -d)
    # 只提取白名单文件；拒绝绝对路径、.. 与非普通文件。
    if tar -tvzf "$archive" 2>/dev/null | awk 'substr($1,1,1) !~ /^[-d]$/ {bad=1} END {exit !bad}'; then
        rm -rf "$tmp"; dog_error "配置包含有链接或设备文件，已拒绝"; return 1
    fi
    local listing
    # 先完整取出清单再匹配：管道里 grep -q 提前退出会让 tar 收到 SIGPIPE，pipefail 下整个判断变假，
    # 不安全路径反而被放行。
    listing=$(tar -tzf "$archive" 2>/dev/null) || { rm -rf "$tmp"; dog_error "无法读取归档：$archive"; return 1; }
    if grep -Eq '(^/|(^|/)\.\.(/|$))' <<< "$listing"; then
        rm -rf "$tmp"; dog_error "配置包含有不安全路径，已拒绝"; return 1
    fi
    for f in $CONFIG_IO_FILES; do
        tar -xzf "$archive" -C "$tmp" "port-traffic-dog-config/$f" 2>/dev/null || true
    done
    src="$tmp/port-traffic-dog-config"
    [ -s "$src/config.json" ] || { rm -rf "$tmp"; dog_error "配置包中没有 config.json"; return 1; }
    schema=$(jq -r '.schema // (if has("ports") then 1 else 0 end)' "$src/config.json" 2>/dev/null || echo 0)
    case "$schema" in
        2) validate_config_file "$src/config.json" || { rm -rf "$tmp"; dog_error "配置无效，未导入"; return 1; } ;;
        1) echo -e "${YELLOW}这是 1.5.x 导出的配置包，将按旧格式迁移（流量取包内灾备值）${NC}" ;;
        *) rm -rf "$tmp"; dog_error "无法识别的配置格式"; return 1 ;;
    esac
    if [ "$schema" = "1" ] && jq -e '[.ports[] | select((.bandwidth_limit.enabled // false))] | length > 0' "$src/config.json" >/dev/null; then
        tc_require_ntc_compatible || { rm -rf "$tmp"; return 1; }
    fi
    if has_monitors; then
        echo -e "${YELLOW}导入会替换当前全部 $(monitor_ids | grep -c .) 个监控项及其统计。${NC}"
    fi
    confirm "确认导入" || { rm -rf "$tmp"; return 0; }

    dog_lock || { rm -rf "$tmp"; return 75; }
    backup="$BACKUP_DIR/import-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup" && chmod 700 "$backup"
    has_monitors && stats_snapshot >/dev/null 2>&1 || true
    for f in $CONFIG_IO_FILES; do [ -f "$CONFIG_DIR/$f" ] && cp -p "$CONFIG_DIR/$f" "$backup/"; done
    teardown_runtime
    for f in $CONFIG_IO_FILES; do
        rm -f "$CONFIG_DIR/$f"
        [ -f "$src/$f" ] && install -m 600 "$src/$f" "$CONFIG_DIR/$f"
    done
    rm -rf "$tmp"
    if [ "$schema" = "1" ]; then
        migrate_from_legacy || rc=1
    else
        nft_rebuild_all || rc=1
        [ "$rc" -eq 0 ] && { stats_rebaseline_all || true; tc_restore_all || rc=1; }
    fi
    if [ "$rc" -ne 0 ]; then
        echo -e "${RED}导入失败，正在恢复原配置...${NC}" >&2
        teardown_runtime
        for f in $CONFIG_IO_FILES; do
            rm -f "$CONFIG_DIR/$f"
            [ -f "$backup/$f" ] && cp -p "$backup/$f" "$CONFIG_DIR/$f"
        done
        config_exists || ensure_config
        nft_rebuild_all || true
        tc_restore_all || true
    fi
    dog_unlock
    cron_sync || true
    dog_log_event import_config "$rc"
    [ "$rc" -eq 0 ] && echo -e "${GREEN}导入完成（原配置备份：$backup）${NC}"
    return "$rc"
}

# 拆除当前全部运行状态（TC 限速与 nft 表），不改配置文件。调用方持有 Dog 锁。
teardown_runtime() {
    local id iface
    if config_exists && [ "$(config_schema)" = "2" ]; then
        if begin_tc_update; then
            while IFS= read -r id; do
                [ -n "$id" ] || continue
                monitor_tc_rate "$id" >/dev/null && tc_remove_monitor_locked "$id" >/dev/null 2>&1
            done < <(monitor_ids)
            iface=$(get_default_interface 2>/dev/null) && cleanup_owned_tc_root_if_unused_locked "$iface" >/dev/null 2>&1
            finish_tc_update
        fi
    fi
    nft_table_exists && nft delete table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null || true
}
