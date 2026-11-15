validate_ip_guard_script_file() {
    local candidate="$1"
    [ -s "$candidate" ] &&
        grep -Fq '# PORT_TRAFFIC_DOG_IP_GUARD' "$candidate" 2>/dev/null &&
        bash -n "$candidate" >/dev/null 2>&1
}

install_ip_guard_script_file() {
    local source_file="$1"
    local temp_file
    mkdir -p "$CONFIG_DIR" || return 1
    temp_file=$(mktemp "$CONFIG_DIR/.port-ip-guard.sh.XXXXXX") || return 1
    if ! install -m 755 "$source_file" "$temp_file" ||
       ! mv -f "$temp_file" "$IP_GUARD_SCRIPT_PATH"; then
        rm -f "$temp_file"
        return 1
    fi
}

get_ip_guard_service_state() {
    if [ ! -e "$IP_GUARD_SERVICE_FILE" ]; then
        echo "absent"
        return 0
    fi
    command -v "$IP_GUARD_SYSTEMCTL" >/dev/null 2>&1 || return 1

    local active_state
    active_state=$("$IP_GUARD_SYSTEMCTL" show "$IP_GUARD_SERVICE" \
        --property=ActiveState --value 2>/dev/null) || return 1
    case "$active_state" in
        active|activating|reloading|deactivating) echo "active" ;;
        inactive|failed) echo "inactive" ;;
        *) return 1 ;;
    esac
}

restart_ip_guard_after_update() {
    validate_ip_guard_script_file "$IP_GUARD_SCRIPT_PATH" || return 1
    command -v "$IP_GUARD_SYSTEMCTL" >/dev/null 2>&1 || return 1
    "$IP_GUARD_SYSTEMCTL" daemon-reload >/dev/null 2>&1 || return 1
    "$IP_GUARD_SYSTEMCTL" restart "$IP_GUARD_SERVICE" >/dev/null 2>&1 || return 1
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if "$IP_GUARD_SYSTEMCTL" is-active --quiet "$IP_GUARD_SERVICE" >/dev/null 2>&1 &&
           bash "$IP_GUARD_SCRIPT_PATH" --self-check >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

ensure_ip_guard_script() {
    if validate_ip_guard_script_file "$IP_GUARD_SCRIPT_PATH"; then
        chmod 755 "$IP_GUARD_SCRIPT_PATH" 2>/dev/null || true
        return 0
    fi

    local script_dir
    local bundled_script
    script_dir=$(dirname "$SCRIPT_PATH")
    bundled_script="$script_dir/port-ip-guard.sh"
    if validate_ip_guard_script_file "$bundled_script"; then
        install_ip_guard_script_file "$bundled_script"
        return $?
    fi

    local tmp rc=0
    tmp=$(mktemp -d) || return 1
    if download_url "$(release_asset_url SHA256SUMS)" "$tmp/SHA256SUMS" &&
       release_download_verified port-ip-guard.sh "$tmp/port-ip-guard.sh" "$tmp/SHA256SUMS" &&
       validate_ip_guard_script_file "$tmp/port-ip-guard.sh"; then
        install_ip_guard_script_file "$tmp/port-ip-guard.sh" || rc=1
    else
        rc=1
    fi
    rm -rf "$tmp"
    return "$rc"
}

manage_ip_guard() {
    menu_clear
    echo -e "${BLUE}=== 在线 IP / 并发连接限制（测试中） ===${NC}"
    echo -e "${YELLOW}独立实验组件，按本机 TCP 服务端口限制在线 IP 数和并发连接数。${NC}"
    echo "IPv4/IPv6 合计，两项可分别设置，0 表示不限；不处理内核 FORWARD 流量。"
    echo "NAT/代理后可能共用一个来源 IP；同 IP 的多条连接仍分别计入连接数。"
    echo "规则采用故障解封设计，但仍不建议直接限制当前 SSH 端口。"
    echo
    if ! dependency_install_missing false all; then
        echo '依赖未就绪；可在主菜单“依赖管理”中安装。未启用新的防火墙限制。' >&2
        read -r -p '按回车返回主菜单...' || return 0
        return 0
    fi
    if ! ensure_ip_guard_script; then
        echo -e "${RED}独立组件下载或校验失败，未修改防火墙。${NC}"
    elif ! bash "$IP_GUARD_SCRIPT_PATH"; then
        echo -e "${RED}在线 IP / 并发连接限制组件执行失败。${NC}"
    fi
    echo
    pause
}
