list_machine_interfaces() {
    # 只取有 device 链接的真物理网卡。隧道（warp、wg*）、网桥（docker0、br-*）、
    # veth、lo、ifb 都没有这个链接——用黑名单会漏掉非标准命名的隧道接口，
    # 导致同一条流量在物理网卡和隧道上被重复计数。
    local path iface
    for path in /sys/class/net/*; do
        [ -e "$path/device" ] || continue
        iface=${path##*/}
        printf '%s\n' "$iface"
    done
}

collect_machine_traffic() {
    local interfaces=()
    mapfile -t interfaces < <(list_machine_interfaces)
    [ "${#interfaces[@]}" -gt 0 ] || return 0

    mkdir -p "$CONFIG_DIR" 2>/dev/null || return 1
    exec 6>"$CONFIG_DIR/.machine_traffic.lock" 2>/dev/null || return 1
    if ! flock -n 6 2>/dev/null; then
        exec 6>&-
        return 0
    fi

    local current_boot_id
    current_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
    local now
    now=$(date +%s)

    local data="{}"
    local first_run=false
    if [ -f "$MACHINE_TRAFFIC_FILE" ]; then
        data=$(cat "$MACHINE_TRAFFIC_FILE" 2>/dev/null || echo "{}")
    else
        first_run=true
    fi

    local last_boot_id
    last_boot_id=$(printf '%s' "$data" | jq -r '.lifetime_raw.boot_id // ""' 2>/dev/null || echo "")
    local new_data="$data"
    local iface line rx tx last_rx last_tx delta_rx delta_tx

    for iface in "${interfaces[@]}"; do
        line=$(awk -v dev="${iface}:" '$1 == dev {print $2" "$10; exit}' /proc/net/dev 2>/dev/null)
        [ -n "$line" ] || continue
        rx=${line%% *}
        tx=${line##* }
        [[ "$rx" =~ ^[0-9]+$ ]] || continue
        [[ "$tx" =~ ^[0-9]+$ ]] || continue

        last_rx=$(printf '%s' "$new_data" | jq -r --arg i "$iface" '.lifetime_raw.ifaces[$i].rx_bytes // 0' 2>/dev/null || echo 0)
        last_tx=$(printf '%s' "$new_data" | jq -r --arg i "$iface" '.lifetime_raw.ifaces[$i].tx_bytes // 0' 2>/dev/null || echo 0)
        [[ "$last_rx" =~ ^[0-9]+$ ]] || last_rx=0
        [[ "$last_tx" =~ ^[0-9]+$ ]] || last_tx=0

        if [ "$first_run" = "true" ]; then
            # 首次采集只记基准：安装之前的历史流量不计入
            delta_rx=0
            delta_tx=0
        elif [ -n "$last_boot_id" ] && [ "$last_boot_id" != "$current_boot_id" ]; then
            # 宿主机重启：开机至今的计数全部计入累计
            delta_rx=$rx
            delta_tx=$tx
        elif [ "$rx" -lt "$last_rx" ] || [ "$tx" -lt "$last_tx" ]; then
            # 未重启但计数回退（网卡重建等）：按当前值重新校准基准
            delta_rx=$rx
            delta_tx=$tx
        else
            delta_rx=$((rx - last_rx))
            delta_tx=$((tx - last_tx))
        fi

        new_data=$(printf '%s' "$new_data" | jq -c --arg i "$iface" \
            --argjson lrx "$rx" --argjson ltx "$tx" \
            --argjson drx "$delta_rx" --argjson dtx "$delta_tx" '
            .lifetime_raw.ifaces[$i] = {"rx_bytes": $lrx, "tx_bytes": $ltx} |
            .monthly.ifaces[$i] = ((.monthly.ifaces[$i] // {"rx_bytes": 0, "tx_bytes": 0}) |
                .rx_bytes += $drx | .tx_bytes += $dtx)' 2>/dev/null) || new_data="$data"
    done

    new_data=$(printf '%s' "$new_data" | jq -c --arg boot "$current_boot_id" --argjson now "$now" '
        .lifetime_raw.boot_id = $boot |
        .lifetime_raw.updated_at = $now |
        .monthly.reset_at = (.monthly.reset_at // $now)' 2>/dev/null) || new_data=""

    if [ -n "$new_data" ]; then
        local tmp_file="${MACHINE_TRAFFIC_FILE}.tmp.$$"
        if printf '%s\n' "$new_data" > "$tmp_file" 2>/dev/null; then
            chmod 600 "$tmp_file" 2>/dev/null || true
            mv -f "$tmp_file" "$MACHINE_TRAFFIC_FILE" 2>/dev/null || rm -f "$tmp_file"
        else
            rm -f "$tmp_file"
        fi
    fi

    flock -u 6 2>/dev/null || true
    exec 6>&-
    return 0
}

machine_traffic_summary() {
    [ -f "$MACHINE_TRAFFIC_FILE" ] || return 0
    local rx tx
    rx=$(jq -r '[.monthly.ifaces[]?.rx_bytes] | add // 0' "$MACHINE_TRAFFIC_FILE" 2>/dev/null || echo 0)
    tx=$(jq -r '[.monthly.ifaces[]?.tx_bytes] | add // 0' "$MACHINE_TRAFFIC_FILE" 2>/dev/null || echo 0)
    [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
    [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
    printf '入 %s / 出 %s' "$(format_bytes "$rx")" "$(format_bytes "$tx")"
}
