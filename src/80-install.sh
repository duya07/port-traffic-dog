# ── 安装、更新、卸载 ──────────────────────────────────────────────
# 更新只接受 GitHub Release 资产，并用同一 Release 的 SHA256SUMS 校验；镜像只用于加速，
# 不论从哪个源下载都必须通过哈希校验。

readonly SHORTCUT_MARKER="# port-traffic-dog shortcut"

release_asset_url() {
    printf 'https://github.com/%s/releases/latest/download/%s\n' "$DOG_REPO" "$1"
}

# 下载到文件：先直连，失败再走镜像（PORT_TRAFFIC_DOG_MIRROR，默认 gh-proxy）。
download_url() {
    local url="$1" out="$2" mirror="${PORT_TRAFFIC_DOG_MIRROR:-https://v6.gh-proxy.org}" src
    for src in "$url" "${mirror%/}/$url"; do
        if curl -fsSL --connect-timeout "$SHORT_CONNECT_TIMEOUT" --max-time 120 "$src" -o "$out" 2>/dev/null && [ -s "$out" ]; then
            return 0
        fi
    done
    return 1
}

# 下载 Release 资产并校验；$3 为已下载的 SHA256SUMS 文件。
release_download_verified() {
    local name="$1" out="$2" sums="$3" want got
    download_url "$(release_asset_url "$name")" "$out" || { dog_error "下载 $name 失败"; return 1; }
    want=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$sums")
    [ -n "$want" ] || { dog_error "SHA256SUMS 中没有 $name"; return 1; }
    got=$(sha256sum "$out" | awk '{print $1}')
    [ "$want" = "$got" ] || { dog_error "$name 校验失败（期望 $want，实际 $got），已拒绝安装"; return 1; }
}

get_script_version_from_file() {
    awk -F'"' '/^readonly SCRIPT_VERSION="[0-9]+(\.[0-9]+)+"/ { print $2; exit }' "$1" 2>/dev/null
}

# $1 < $2 时返回 0。
version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# 归属判断：2.0 标记、指向安装路径的软链接，或 1.4/1.5 生成的单行包装脚本（exec bash <安装路径>）。
shortcut_is_ours() {
    [ ! -e "$SHORTCUT_PATH" ] && return 0
    grep -qF "$SHORTCUT_MARKER" "$SHORTCUT_PATH" 2>/dev/null && return 0
    [ "$(readlink -f "$SHORTCUT_PATH" 2>/dev/null)" = "$INSTALLED_SCRIPT_PATH" ] && return 0
    [ -f "$SHORTCUT_PATH" ] && [ ! -L "$SHORTCUT_PATH" ] && [ "$(stat -c %s "$SHORTCUT_PATH" 2>/dev/null || echo 9999)" -lt 512 ] &&
        [ "$(grep -Evc '^[[:space:]]*(#.*)?$' "$SHORTCUT_PATH" 2>/dev/null)" = 1 ] &&
        grep -Eq "^exec bash \"?${INSTALLED_SCRIPT_PATH//./\\.}\"? \"\\\$@\"\$" "$SHORTCUT_PATH" 2>/dev/null
}

create_shortcut() {
    if ! shortcut_is_ours; then
        echo -e "${YELLOW}$SHORTCUT_PATH 已被其他程序占用，未创建快捷命令；请使用 $INSTALLED_SCRIPT_PATH${NC}" >&2
        return 0
    fi
    printf '#!/bin/sh\n%s\nexec %s "$@"\n' "$SHORTCUT_MARKER" "$INSTALLED_SCRIPT_PATH" | atomic_write "$SHORTCUT_PATH" 755
}

# 把当前运行的脚本安装到固定位置（首次运行下载的脚本时自动调用）。
install_self() {
    if [ "$SCRIPT_PATH" != "$INSTALLED_SCRIPT_PATH" ]; then
        bash -n "$SCRIPT_PATH" || { dog_error "脚本语法检查失败，未安装"; return 1; }
        cat "$SCRIPT_PATH" | atomic_write "$INSTALLED_SCRIPT_PATH" 755 || return 1
    fi
    create_shortcut || true
    ensure_config || return 1
    if [ -f "$SCRIPT_PATH" ] && [ -f "$(dirname "$SCRIPT_PATH")/port-ip-guard.sh" ] && [ ! -f "$IP_GUARD_SCRIPT_PATH" ]; then
        install_ip_guard_script_file "$(dirname "$SCRIPT_PATH")/port-ip-guard.sh" >/dev/null 2>&1 || true
    fi
    dog_log_event install 0
}

# 更新后由新版本执行的维护：迁移、恢复规则、刷新定时任务。
post_update() {
    local rc=0
    ensure_config || return 1
    if legacy_needs_migration; then
        migrate_from_legacy || return 1
    fi
    validate_config_file "$CONFIG_FILE" || return 1
    restore_runtime || rc=1
    cron_sync || rc=1
    tc_write_interop || true
    return "$rc"
}

update_dog() {
    local force="${1:-}" tmp sums new cur ver backup guard_installed=false rc=0
    tmp=$(mktemp -d) || return 1
    sums="$tmp/SHA256SUMS"; new="$tmp/port-traffic-dog.sh"
    echo "正在从 GitHub Release 获取最新版本（$DOG_REPO）..."
    if ! download_url "$(release_asset_url SHA256SUMS)" "$sums"; then
        rm -rf "$tmp"; dog_error "无法下载 SHA256SUMS（仓库尚无 Release 或网络不可达）"; return 1
    fi
    release_download_verified port-traffic-dog.sh "$new" "$sums" || { rm -rf "$tmp"; return 1; }
    bash -n "$new" || { rm -rf "$tmp"; dog_error "新脚本语法检查失败"; return 1; }
    ver=$(get_script_version_from_file "$new")
    cur="$SCRIPT_VERSION"
    echo "当前版本 $cur，最新版本 ${ver:-未知}"
    if [ -z "$ver" ]; then rm -rf "$tmp"; dog_error "无法识别新脚本版本"; return 1; fi
    if [ "$ver" = "$cur" ] && [ "$force" != "--force" ]; then rm -rf "$tmp"; echo "已是最新版本"; return 0; fi
    if version_lt "$ver" "$cur" && [ "$force" != "--force" ]; then
        rm -rf "$tmp"; dog_error "Release 版本 $ver 低于当前 $cur，已拒绝降级（如确需降级请加 --force）"; return 1
    fi
    [ -f "$IP_GUARD_SCRIPT_PATH" ] && guard_installed=true
    # 只在服务原本运行时才重启（与 1.5.x 一致）；状态无法确认时不动任何文件。
    local guard_state=absent
    if ! guard_state=$(get_ip_guard_service_state); then
        rm -rf "$tmp"; dog_error "无法确认 IP Guard 服务状态，已停止更新"; return 1
    fi
    if [ "$guard_installed" = "true" ]; then
        release_download_verified port-ip-guard.sh "$tmp/port-ip-guard.sh" "$sums" || { rm -rf "$tmp"; return 1; }
    fi
    backup="$BACKUP_DIR/update-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup" && chmod 700 "$backup"
    cp -p "$INSTALLED_SCRIPT_PATH" "$backup/" 2>/dev/null || true
    cp -p "$CONFIG_FILE" "$TRAFFIC_DATA_FILE" "$TRAFFIC_STATS_FILE" "$backup/" 2>/dev/null || true
    cp -p "$IP_GUARD_SCRIPT_PATH" "$backup/" 2>/dev/null || true
    crontab -l > "$backup/crontab.txt" 2>/dev/null || true
    atomic_write "$INSTALLED_SCRIPT_PATH" 755 < "$new" || { rm -rf "$tmp"; return 1; }
    if [ "$guard_installed" = "true" ]; then
        if ! install_ip_guard_script_file "$tmp/port-ip-guard.sh"; then
            rc=1
        elif [ "$guard_state" = active ] && ! restart_ip_guard_after_update; then
            rc=1; dog_error "IP Guard 服务重启或自检失败，请执行 systemctl status $IP_GUARD_SERVICE 检查"
        fi
    fi
    create_shortcut || true
    if ! "$INSTALLED_SCRIPT_PATH" --post-update; then
        echo -e "${RED}新版本维护失败，正在恢复更新前的文件...${NC}" >&2
        cp -p "$backup/port-traffic-dog.sh" "$INSTALLED_SCRIPT_PATH" 2>/dev/null || true
        for f in config.json traffic_data.json traffic_stats.json; do
            [ -f "$backup/$f" ] && cp -p "$backup/$f" "$CONFIG_DIR/$f"
        done
        [ -f "$backup/port-ip-guard.sh" ] && cp -p "$backup/port-ip-guard.sh" "$IP_GUARD_SCRIPT_PATH"
        [ -f "$backup/crontab.txt" ] && crontab "$backup/crontab.txt" 2>/dev/null || true
        rm -rf "$tmp"
        dog_log_event install_rollback 0
        dog_error "已恢复到 $cur（备份 $backup）"
        return 1
    fi
    rm -rf "$tmp"
    dog_log_event install "$rc"
    echo -e "${GREEN}已更新到 $ver（更新前备份：$backup）${NC}"
    return "$rc"
}

uninstall_dog() {
    local keep_config="${1:-}" iface id rc=0
    echo -e "${YELLOW}将删除全部端口监控规则、限速、定时任务和 Dog 程序文件。${NC}"
    if [ "$keep_config" = "--keep-config" ]; then
        echo "配置与统计将保留在 $CONFIG_DIR"
    else
        echo "配置与统计也会删除（可加 --keep-config 保留）"
    fi
    confirm "确认卸载" || { echo "已取消"; return 0; }
    dog_lock || return 75
    cron_remove_all || rc=1
    if config_exists && [ "$(config_schema)" = "2" ]; then
        begin_tc_update && {
            while IFS= read -r id; do
                [ -n "$id" ] || continue
                monitor_tc_rate "$id" >/dev/null && { tc_remove_monitor_locked "$id" || rc=1; }
            done < <(monitor_ids)
            iface=$(get_default_interface 2>/dev/null) && cleanup_owned_tc_root_if_unused_locked "$iface"
            finish_tc_update
        }
    fi
    if nft_table_exists; then nft delete table "$NFT_FAMILY" "$NFT_TABLE" || rc=1; fi
    if [ -f "$IP_GUARD_SCRIPT_PATH" ]; then
        bash "$IP_GUARD_SCRIPT_PATH" --uninstall --yes || rc=1
    fi
    rm -f "$TC_INTEROP_FILE"
    dog_unlock
    if [ "$keep_config" != "--keep-config" ]; then
        rm -rf "$CONFIG_DIR" || rc=1
    fi
    shortcut_is_ours && rm -f "$SHORTCUT_PATH"
    rm -f "$INSTALLED_SCRIPT_PATH" || rc=1
    cleanup_tc_recovery_files_if_unused || true
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}卸载完成。依赖软件包未删除，如需移除可运行：bash port-traffic-dog.sh --dependencies remove${NC}"
    else
        echo -e "${YELLOW}卸载完成，但有部分清理步骤失败，请检查 nft list ruleset 与 tc qdisc show${NC}"
    fi
    return "$rc"
}
