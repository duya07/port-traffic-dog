# ── 按监控项的带宽限制 ────────────────────────────────────────────
# 出向：nft 的 ptd_<id>_mark 链给命中端口的包打 mark（只占高 20 位，保留低 12 位），
#       物理网卡上一条 fw 过滤器按 mark 把包归入该项的 HTB 子类。端口增删只改 nft 映射，TC 不动。
# 入向：ingress 先于 nft，拿不到 mark；ifb0 上按成员端口用 flower 精确匹配（每成员 8 条：
#       IPv4/IPv6 × TCP/UDP × 源/目的），端口增删时只重建该项的入向过滤器。
# class minor = 0x4000 + 监控项编号，mark = 0x50000000 | (minor << 12)，均为确定值，无需哈希。

tc_minor_for() {
    local n="${1#m}"
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le 49151 ] || return 1
    echo $((0x4000 + n))
}

tc_class_for() {
    local minor
    minor=$(tc_minor_for "$1") || return 1
    printf '1:%x\n' "$minor"
}

tc_mark_for() {
    local minor
    minor=$(tc_minor_for "$1") || return 1
    echo $(( TC_MARK_BASE | (minor << 12) ))
}

# 监控项的 tc 速率（如 100mbit）；未启用限速返回 1。
monitor_tc_rate() {
    local id="$1" rate
    [ "$(mget "$id" .bandwidth_limit.enabled false)" = "true" ] || return 1
    rate=$(mget "$id" .bandwidth_limit.rate unlimited)
    [ "$rate" != "unlimited" ] || return 1
    echo "$rate"
}

# 已安装的 TrafficCop Lite 是否理解 Dog 2.0 的类清单（tc-interop.json）。
# 未安装 NTC 视为兼容；旧版 NTC 会按 1.5.x 的 .ports 反推 Dog 的类，必须先升级。
tc_ntc_compatible() {
    local monitor="$TRAFFICCOP_MONITOR_SCRIPT"
    [ -e "$monitor" ] || return 0
    grep -qF "$TC_CLASS_MANIFEST_SCHEMA" "$monitor" 2>/dev/null
}

tc_require_ntc_compatible() {
    tc_ntc_compatible && return 0
    dog_error "检测到旧版 TrafficCop Lite：它无法识别 Dog 2.0 的限速类，同时运行会互相误判。请先把 TrafficCop Lite 升级到 1.2.0 或更高版本，再设置带宽限制。"
    return 1
}

# 写入供 NTC 读取的类清单（原子替换，root 0644）。
# $1（可选）：要排除的监控项 ID——删除/合并时在持锁移除 TC 对象后、改配置前调用。
tc_write_interop() {
    local exclude="${1:-}" iface id rate classes="[]"
    iface=$(get_default_interface 2>/dev/null || echo "")
    while IFS= read -r id; do
        [ -n "$id" ] && [ "$id" != "$exclude" ] || continue
        rate=$(monitor_tc_rate "$id") || continue
        classes=$(jq -c --arg id "$id" --arg c "$(tc_class_for "$id")" --arg r "$rate" \
            --argjson m "$(tc_mark_for "$id")" --argjson n "$(jq 'length' <<< "$(jq -c --arg id "$id" '.monitors[$id].ports' "$CONFIG_FILE")")" \
            '. + [{id: $id, class_id: $c, rate: $r, mark: $m, mark_mask: 4294963200,
                   egress: "fw", ingress: "flower", ingress_filters: ($n * 8)}]' <<< "$classes")
    done < <(monitor_ids)
    jq -n --arg s "$TC_CLASS_MANIFEST_SCHEMA" --arg v "$SCRIPT_VERSION" --arg i "$iface" \
          --arg at "$(date -u +%FT%TZ)" --argjson c "$classes" \
        '{schema: $s, dog_version: $v, interface: $i, updated_at: $at, classes: $c}' |
        atomic_write "$TC_INTEROP_FILE" 644
}

tc_class_args() {
    local rate="$1" kbps burst
    kbps=$(parse_tc_rate_to_kbps "$rate")
    burst=$(format_tc_burst "$(calculate_tc_burst "$kbps")")
    printf 'rate %s ceil %s burst %s' "$TC_PORT_CLASS_RATE" "$rate" "$burst"
}

# 删除 ifb0 上指向该类的全部 flower 过滤器（不依赖成员数，端口变化后也能清干净）。
tc_remove_ingress_filters_locked() {
    local id="$1" class json
    class=$(tc_class_for "$id") || return 1
    ip link show "$TC_IFB_DEVICE" >/dev/null 2>&1 || return 0
    json=$(tc -j filter show dev "$TC_IFB_DEVICE" parent 1:0 2>/dev/null) || return 0
    jq -r --arg c "$class" '.[] | select(.options.handle? != null and (.options.classid? // .options.flowid? // "") == $c) |
        "\(.protocol) \(.pref) \(.options.handle)"' <<< "$json" 2>/dev/null |
    while read -r proto pref handle; do
        tc filter del dev "$TC_IFB_DEVICE" parent 1:0 protocol "$proto" pref "$pref" handle "$handle" flower 2>/dev/null || true
    done
}

tc_apply_ingress_locked() {
    local id="$1" rate="$2" iface="$3" class minor ports index=0 port offset pref family proto key handle
    class=$(tc_class_for "$id"); minor=$(tc_minor_for "$id")
    ensure_ifb_hierarchy_locked "$iface" || return 1
    ensure_ingress_redirect_locked "$iface" || return 1
    tc_remove_ingress_filters_locked "$id"
    # shellcheck disable=SC2046
    tc class replace dev "$TC_IFB_DEVICE" parent 1:1 classid "$class" htb $(tc_class_args "$rate") || return 1
    mapfile -t ports < <(monitor_ports "$id")
    for port in "${ports[@]}"; do
        index=$((index + 1))
        handle=$(printf '0x%x' $(( (minor << 16) | index )))
        for offset in 0 1 2 3 4 5 6 7; do
            pref=$((100 + offset))
            family=ip; [ "$offset" -lt 4 ] || family=ipv6
            proto=tcp; [ $((offset % 4)) -lt 2 ] || proto=udp
            key=src_port; [ $((offset % 2)) -eq 0 ] || key=dst_port
            tc filter add dev "$TC_IFB_DEVICE" protocol "$family" parent 1:0 pref "$pref" \
                handle "$handle" flower ip_proto "$proto" "$key" "$port" classid "$class" || {
                tc_remove_ingress_filters_locked "$id"
                return 1
            }
        done
    done
}

tc_egress_filter_handle() {
    printf '0x%x/0x%x' "$(tc_mark_for "$1")" "$TC_MARK_MASK"
}

# 施加/更新一个监控项的限速（调用方持有 TC 锁与 Dog 锁）。
tc_apply_monitor_locked() {
    local id="$1" rate="$2" iface class mark
    iface=$(get_default_interface) || return 1
    ensure_owned_tc_hierarchy_locked "$iface" || return 1
    class=$(tc_class_for "$id") || return 1
    mark=$(tc_mark_for "$id")
    # shellcheck disable=SC2046
    tc class replace dev "$iface" parent 1:1 classid "$class" htb $(tc_class_args "$rate") || {
        log_notification "监控项 $id 无法创建 TC 分类 $class"; return 1; }
    tc filter del dev "$iface" parent 1:0 protocol all prio 1 handle "$(tc_egress_filter_handle "$id")" fw 2>/dev/null || true
    tc filter add dev "$iface" parent 1:0 protocol all prio 1 handle "$(tc_egress_filter_handle "$id")" fw flowid "$class" || {
        log_notification "监控项 $id 无法创建出向 fw 过滤器"; return 1; }
    config_update '.monitors[$id].bandwidth_limit.class_id = $c | .monitors[$id].bandwidth_limit.mark_id = $m' \
        --arg id "$id" --arg c "$class" --argjson m "$mark" || return 1
    nft_sync_monitor "$id" || return 1
    tc_apply_ingress_locked "$id" "$rate" "$iface" || { log_notification "监控项 $id 入向限速创建失败"; return 1; }
    tc_monitor_complete "$id" "$iface"
}

# 撤销一个监控项的 TC 对象（不改配置开关；调用方持有 TC 锁）。
tc_remove_monitor_locked() {
    local id="$1" iface class
    iface=$(get_default_interface 2>/dev/null) || return 0
    class=$(tc_class_for "$id") || return 1
    tc_remove_ingress_filters_locked "$id"
    tc class del dev "$TC_IFB_DEVICE" classid "$class" 2>/dev/null || true
    tc filter del dev "$iface" parent 1:0 protocol all prio 1 handle "$(tc_egress_filter_handle "$id")" fw 2>/dev/null || true
    tc class del dev "$iface" classid "$class" 2>/dev/null || true
    cleanup_owned_tc_root_if_unused_locked "$iface" || true
    ! tc class show dev "$iface" 2>/dev/null | awk -v c="$class" '$3 == c {f=1} END {exit !f}'
}

# 删除 2.0 号段（1:4001-1:ffff）里没有对应限速监控项的孤儿类及其过滤器（调用方持有 TC 锁）。
# 孤儿类会让 NTC 判定“存在无法证明归属的 Dog 类”而拒绝操作，必须由 Dog 自己清掉。
tc_remove_orphan_classes_locked() {
    local iface="$1" dev class minor id removed=0
    for dev in "$iface" "$TC_IFB_DEVICE"; do
        ip link show "$dev" >/dev/null 2>&1 || continue
        while read -r class; do
            [[ "$class" =~ ^1:([0-9a-f]+)$ ]] || continue
            minor=$((16#${BASH_REMATCH[1]}))
            [ "$minor" -ge $((0x4001)) ] && [ "$minor" -le $((0xffff)) ] || continue
            id="m$((minor - 0x4000))"
            monitor_exists "$id" && monitor_tc_rate "$id" >/dev/null && continue
            if [ "$dev" = "$TC_IFB_DEVICE" ]; then
                tc_remove_ingress_filters_locked "$id"
            else
                tc filter del dev "$dev" parent 1:0 protocol all prio 1 handle "$(tc_egress_filter_handle "$id")" fw 2>/dev/null || true
            fi
            tc class del dev "$dev" classid "$class" 2>/dev/null && removed=$((removed + 1))
        done < <(tc class show dev "$dev" 2>/dev/null | awk '$1 == "class" && $2 == "htb" && $5 == "1:1" { print $3 }')
    done
    [ "$removed" -eq 0 ] || log_notification "已清理 $removed 个无对应监控项的 TC 分类"
    return 0
}

# 一个监控项的 TC 运行状态是否完整。
tc_monitor_complete() {
    local id="$1" iface="${2:-}" rate class handle want have
    rate=$(monitor_tc_rate "$id") || return 0
    [ -n "$iface" ] || iface=$(get_default_interface 2>/dev/null) || return 1
    class=$(tc_class_for "$id")
    tc_class_rate_matches "$iface" "$class" "$TC_PORT_CLASS_RATE" "$rate" || return 1
    tc_class_rate_matches "$TC_IFB_DEVICE" "$class" "$TC_PORT_CLASS_RATE" "$rate" || return 1
    handle=$(printf '0x%x' "$(tc_mark_for "$id")")
    grep -Eq "handle ${handle}/0xfffff000 classid ${class}( |$)" <<< "$(tc filter show dev "$iface" parent 1:0 2>/dev/null)" || return 1
    want=$(( $(monitor_ports "$id" | wc -l) * 8 ))
    have=$(tc -j filter show dev "$TC_IFB_DEVICE" parent 1:0 2>/dev/null |
        jq --arg c "$class" '[.[] | select(.options.handle? != null and (.options.classid? // .options.flowid? // "") == $c)] | length' 2>/dev/null || echo 0)
    [ "$have" -eq "$want" ]
}

# 0=全部完整，1=有冲突或缺失，2=Dog/NTC 都没有 TC 需求。
dog_tc_runtime_complete_all() {
    local interface="$1" expected=false ntc_rate="" ntc_status=0 id
    ntc_rate=$(trafficcop_unified_state_rate "$interface" 2>/dev/null) || ntc_status=$?
    case "$ntc_status" in
        0)
            expected=true
            tc_root_is_managed "$interface" || return 1
            tc_class_rate_matches "$interface" "1:1" "$ntc_rate" "$ntc_rate" || return 1
            tc_class_rate_matches "$interface" "1:30" "$TC_DEFAULT_CLASS_RATE" "$ntc_rate" || return 1
            ;;
        1|4|5) ;;
        *) [ -e "$TRAFFICCOP_TC_STATE_FILE" ] && return 1 ;;
    esac
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        monitor_tc_rate "$id" >/dev/null || continue
        expected=true
        tc_monitor_complete "$id" "$interface" || return 1
    done < <(monitor_ids)
    [ "$expected" = "true" ] && return 0
    return 2
}

# 端口变化后刷新入向过滤器（出向随 nft 映射自动生效）。
tc_refresh_monitor_ports() {
    local id="$1" rate iface rc=0
    rate=$(monitor_tc_rate "$id") || return 0
    iface=$(get_default_interface) || return 1
    begin_tc_update || return 1
    tc_apply_ingress_locked "$id" "$rate" "$iface" || rc=1
    finish_tc_update
    return "$rc"
}

# 设置或取消限速：rate 为 tc 速率（100mbit）或 0。
tc_set_monitor_limit() {
    local id="$1" rate="$2" rc=0 prev_enabled prev_rate
    if [ "$rate" != "0" ]; then
        tc_require_ntc_compatible || return 1
    fi
    dog_lock || return 75
    prev_enabled=$(mget "$id" .bandwidth_limit.enabled false)
    prev_rate=$(mget "$id" .bandwidth_limit.rate unlimited)
    begin_tc_update || { dog_unlock; return 1; }
    if [ "$rate" = "0" ]; then
        config_update '.monitors[$id].bandwidth_limit = {enabled: false, rate: "unlimited"}' --arg id "$id" || rc=1
        [ "$rc" -eq 0 ] && { tc_remove_monitor_locked "$id" || rc=1; }
        [ "$rc" -eq 0 ] && { nft_sync_monitor "$id" || rc=1; }
        dog_log_event tc_clear "$rc" "id=$id"
    else
        config_update '.monitors[$id].bandwidth_limit.enabled = true | .monitors[$id].bandwidth_limit.rate = $r' \
            --arg id "$id" --arg r "$rate" || rc=1
        if [ "$rc" -eq 0 ] && ! tc_apply_monitor_locked "$id" "$rate"; then
            rc=1
            # 回滚到原设置，避免配置声称已限速而内核没有对应对象。
            tc_remove_monitor_locked "$id" >/dev/null 2>&1 || true
            config_update '.monitors[$id].bandwidth_limit.enabled = ($e == "true") | .monitors[$id].bandwidth_limit.rate = $r' \
                --arg id "$id" --arg e "$prev_enabled" --arg r "$prev_rate" >/dev/null 2>&1 || true
            nft_sync_monitor "$id" >/dev/null 2>&1 || true
            if [ "$prev_enabled" = "true" ] && [ "$prev_rate" != "unlimited" ]; then
                tc_apply_monitor_locked "$id" "$prev_rate" >/dev/null 2>&1 || true
            fi
        fi
        dog_log_event tc_apply "$rc" "id=$id" "rate=$rate"
    fi
    # 清单在释放共享 TC 锁之前写入：NTC 持锁读取时，内核对象与清单一致。
    tc_write_interop || true
    finish_tc_update
    dog_unlock
    return "$rc"
}

# 按配置恢复全部限速（缺失或不完整的才重建）。
tc_restore_all() {
    local id rate iface rc=0 any=false
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        monitor_tc_rate "$id" >/dev/null && { any=true; break; }
    done < <(monitor_ids)
    iface=$(get_default_interface 2>/dev/null) || iface=""
    if [ "$any" != "true" ]; then
        if [ -n "$iface" ] && begin_tc_update; then
            tc_remove_orphan_classes_locked "$iface"
            tc_write_interop || true
            finish_tc_update
        else
            tc_write_interop || true
        fi
        return 0
    fi
    tc_ntc_compatible || { tc_require_ntc_compatible; return 1; }
    [ -n "$iface" ] || return 1
    begin_tc_update || return 1
    tc_remove_orphan_classes_locked "$iface"
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        rate=$(monitor_tc_rate "$id") || continue
        tc_monitor_complete "$id" "$iface" && continue
        tc_apply_monitor_locked "$id" "$rate" || rc=1
    done < <(monitor_ids)
    tc_write_interop || true
    finish_tc_update
    return "$rc"
}
