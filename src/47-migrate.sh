# ── 1.5.x → 2.0 迁移 ──────────────────────────────────────────────
# 1.5.x 以端口串为 key（.ports["8031,8032"]），计数器名由 key 派生，且“双倍计费”靠重复规则实现，
# 内核计数已包含倍率。迁移把计数除以旧倍率得到原始字节，在新结构中以初值原样恢复。
# 迁移前完整备份；任何一步失败都恢复旧配置、旧 nft 表与 crontab。

legacy_counter_prefix() {
    local key="$1"
    if [[ "$key" == *,* ]]; then
        echo "port_g$(printf '%s' "$key" | tr ',-' '__')"
    else
        echo "port_${key//-/_}"
    fi
}

legacy_rate_to_tc() {
    local v="${1,,}"
    case "$v" in
        unlimited|"") echo unlimited ;;
        *kbps|*mbps|*gbps) convert_bandwidth_to_tc "$v" ;;
        *kbit|*mbit|*gbit) echo "$v" ;;
        *) echo unlimited ;;
    esac
}

# 读取旧计数：{key:{in,out,quota_used}}（原始字节，已除以倍率）。
legacy_read_values() {
    local old_cfg="$1" old_data="$2" nft_json key prefix mult in_b out_b used values="{}" src
    nft_json=$(nft -j list table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null || echo '{"nftables":[]}')
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        prefix=$(legacy_counter_prefix "$key")
        mult=$(jq -r --arg k "$key" 'if (.ports[$k].billing_mode // "double") == "single" then 1 else 2 end' <<< "$old_cfg")
        read -r in_b out_b used < <(jq -r --arg p "$prefix" '
            [.nftables[] | .counter? // empty] as $c | [.nftables[] | .quota? // empty] as $q |
            "\(($c[] | select(.name == "\($p)_in") | .bytes) // "x") \(($c[] | select(.name == "\($p)_out") | .bytes) // "x") \(($q[] | select(.name == "\($p)_quota") | .used) // 0)"
        ' <<< "$nft_json")
        src=kernel
        if [ "$in_b" = "x" ] || [ "$out_b" = "x" ]; then
            # 内核里没有（如重启后未恢复）：用旧灾备文件。
            read -r in_b out_b < <(jq -r --arg k "$key" '.[$k] // {} | "\(.input // 0) \(.output // 0)"' <<< "$old_data")
            used=$((in_b + out_b))
            src=backup
        fi
        values=$(jq -c --arg k "$key" --argjson i "$((in_b / mult))" --argjson o "$((out_b / mult))" \
            --argjson u "$((used / mult))" --arg s "$src" '. + {($k): {in: $i, out: $o, quota_used: $u, source: $s}}' <<< "$values")
    done < <(jq -r '.ports | keys[] | select(. != "00")' <<< "$old_cfg" | sort -t, -k1,1n)
    echo "$values"
}

# 由旧配置生成 schema 2 配置；输出 {config, idmap:{key:id}}。
legacy_build_config() {
    local old_cfg="$1"
    # 上游 1.4.x 的 "00" 是整机流量伪端口，2.0 由独立的整机统计负责，不迁移为监控项。
    jq -c --argjson keys "$(jq -c '[.ports | keys[] | select(. != "00")] | sort_by(split(",")[0] | split("-")[0] | tonumber)' <<< "$old_cfg")" '
        def rate_tc: ascii_downcase |
            if test("^[0-9]+kbps$") then sub("kbps$"; "kbit") elif test("^[0-9]+mbps$") then sub("mbps$"; "mbit")
            elif test("^[0-9]+gbps$") then sub("gbps$"; "gbit") elif test("^[0-9]+(kbit|mbit|gbit)$") then .
            else "unlimited" end;
        . as $o |
        ([range(0; $keys | length) | {($keys[.]): "m\(. + 1)"}] | add // {}) as $idmap |
        { idmap: $idmap,
          config: {
            schema: 2,
            global: { billing_mode: ($o.global.billing_mode // "double"),
                      next_monitor_id: (($keys | length) + 1),
                      data_retention_days: ($o.global.data_retention_days // 400) },
            monitors: ([$keys[] as $k | $o.ports[$k] as $p |
                (($p.quota.enabled // true) and (($p.quota.monthly_limit // "unlimited") != "unlimited")) as $q |
                ($p.quota.reset_policy // (if ($p.quota.reset_day // null) != null then {type: "monthly", day: $p.quota.reset_day} else {type: "none"} end)) as $rp |
                { ($idmap[$k]): {
                    ports: ($k | split(",")),
                    remark: (($p.remark // "") | if . == "" then (($p.name // "") | if startswith("端口") then "" else . end) else . end | .[0:64]),
                    billing_mode: ($p.billing_mode // "double"),
                    quota: { enabled: $q, monthly_limit: (if $q then ($p.quota.monthly_limit | ascii_upcase) else "unlimited" end) },
                    bandwidth_limit: ((($p.bandwidth_limit.rate // "unlimited") | rate_tc) as $r |
                        { enabled: (($p.bandwidth_limit.enabled // false) and $r != "unlimited"), rate: $r }),
                    reset_policy: (if $q and (($rp.type // "none") != "none") then ($rp | del(.instance_id, .reset_now) |
                                     if .type == "interval_days" or .type == "interval_months" then .anchor_date = (.anchor_date // .date) else . end)
                                   else {type: "none"} end),
                    expiry_date: ($p.expiry_date // $p.expiry.expire_date // ""),   # 上游 1.4.x：.expiry.expire_date
                    created_at: ($p.created_at // "")
                } }] | add // {}),
            notifications: ($o.notifications // {} | del(.email))
          } }
    ' <<< "$old_cfg"
}

legacy_build_stats() {
    local old_stats="$1" idmap="$2" old_cfg="$3"
    jq -c --argjson m "$idmap" --argjson cfg "$old_cfg" '
        {schema: 2, monitors: ([ $m | to_entries[] | .key as $k | .value as $id |
            (if ($cfg.ports[$k].billing_mode // "double") == "single" then 1 else 2 end) as $mult |
            { ($id): { last: null,
                daily: ((.daily[$k]? // {}) | with_entries(.value = {in: ((.value.input // 0) / $mult | floor), out: ((.value.output // 0) / $mult | floor)})) } }
        ] | add // {})}
    ' <<< "$old_stats" 2>/dev/null || stats_empty
}

legacy_needs_migration() {
    config_exists && [ "$(config_schema)" = "1" ]
}

migrate_from_legacy() {
    local ts dir old_cfg old_data old_stats built idmap new_cfg values new_values legacy_tc=false rc=0
    legacy_needs_migration || return 0
    old_cfg=$(cat "$CONFIG_FILE")
    if ! jq -e '.ports | type == "object"' <<< "$old_cfg" >/dev/null 2>&1; then
        dog_error "旧配置无法解析，已停止迁移：$CONFIG_FILE"
        return 1
    fi
    if jq -e '[.ports[] | select((.bandwidth_limit.enabled // false) and ((.bandwidth_limit.rate // "unlimited") != "unlimited"))] | length > 0' \
        <<< "$old_cfg" >/dev/null; then
        legacy_tc=true
        tc_require_ntc_compatible || { dog_error "迁移已中止，未做任何修改"; return 1; }
    fi
    echo -e "${BLUE}检测到 1.5.x 配置，开始迁移到 2.0（监控项改为稳定 ID，可直接增删端口）...${NC}"
    dog_lock || return 75
    ts=$(date +%Y%m%d-%H%M%S)
    dir="$BACKUP_DIR/migrate-1.5-$ts"
    mkdir -p "$dir" && chmod 700 "$dir"
    cp -p "$CONFIG_FILE" "$dir/" 2>/dev/null || true
    local f
    for f in "$TRAFFIC_DATA_FILE" "$TRAFFIC_STATS_FILE" "$CONFIG_DIR/reset_history.log"; do
        [ -f "$f" ] && cp -p "$f" "$dir/"
    done
    [ -d "$CONFIG_DIR/notifications" ] && cp -rp "$CONFIG_DIR/notifications" "$dir/"
    crontab -l > "$dir/crontab.txt" 2>/dev/null || true
    nft list table "$NFT_FAMILY" "$NFT_TABLE" > "$dir/nft-table.nft" 2>/dev/null || true
    { iface=$(get_default_interface 2>/dev/null) && tc -s class show dev "$iface" && tc filter show dev "$iface" parent 1:0; } \
        > "$dir/tc-state.txt" 2>/dev/null || true

    old_data=$(cat "$TRAFFIC_DATA_FILE" 2>/dev/null || echo '{}')
    old_stats=$(cat "$TRAFFIC_STATS_FILE" 2>/dev/null || echo '{}')
    values=$(legacy_read_values "$old_cfg" "$old_data")
    built=$(legacy_build_config "$old_cfg") || { dog_unlock; dog_error "生成新配置失败"; return 1; }
    idmap=$(jq -c '.idmap' <<< "$built")
    new_cfg=$(jq '.config' <<< "$built")
    local errors
    errors=$(jq -c "$CONFIG_VALIDATOR_JQ" <<< "$new_cfg")
    if [ "$errors" != "[]" ]; then
        dog_unlock
        jq -r '.[]' <<< "$errors" | sed 's/^/迁移后配置错误：/' >&2
        dog_error "迁移已中止，旧配置未改动（备份：$dir）"
        return 1
    fi
    new_values=$(jq -c --argjson m "$idmap" 'with_entries(.key = $m[.key] | .value |= del(.source))' <<< "$values")

    _migrate_rollback() {
        cp -p "$dir/config.json" "$CONFIG_FILE" 2>/dev/null || true
        [ -f "$dir/traffic_data.json" ] && cp -p "$dir/traffic_data.json" "$TRAFFIC_DATA_FILE"
        [ -f "$dir/traffic_stats.json" ] && cp -p "$dir/traffic_stats.json" "$TRAFFIC_STATS_FILE"
        if [ -s "$dir/nft-table.nft" ]; then
            { printf 'add table %s\ndelete table %s\n' "$(nft_t)" "$(nft_t)"; cat "$dir/nft-table.nft"; } | nft -f - 2>/dev/null || true
        fi
        [ -f "$dir/crontab.txt" ] && crontab "$dir/crontab.txt" 2>/dev/null || true
    }

    printf '%s\n' "$new_cfg" | atomic_write "$CONFIG_FILE" 600 || { dog_unlock; return 1; }
    if ! nft_render_table "$new_values" | nft_apply; then
        _migrate_rollback
        dog_unlock
        dog_error "nftables 新规则写入失败，已恢复 1.5.x 状态（备份：$dir）"
        dog_log_event migrate 1
        return 1
    fi
    traffic_backup_write "$new_values" || rc=1
    legacy_build_stats "$old_stats" "$idmap" "$old_cfg" | atomic_write "$TRAFFIC_STATS_FILE" 600 || rc=1
    stats_rebaseline_all || true
    # 当期已完成的重置记录（防止迁移后对同一到期日重复清零）
    if [ -f "$CONFIG_DIR/reset_history.log" ]; then
        local hist="{}" line key due id next
        while IFS='|' read -r _ key _ due _; do
            id=$(jq -r --arg k "$key" '.[$k] // empty' <<< "$idmap")
            [ -n "$id" ] && is_valid_date "$due" || continue
            next=$(jq -r --arg id "$id" '.monitors[$id].reset_policy.next_reset_date // ""' <<< "$new_cfg")
            [ "$due" = "$next" ] || continue
            hist=$(jq -c --arg id "$id" --arg d "$due" '.[$id] = [{due: $d, at: "migrated", in: 0, out: 0}]' <<< "$hist")
        done < "$CONFIG_DIR/reset_history.log"
        printf '%s\n' "$hist" | atomic_write "$RESET_HISTORY_FILE" 600 || true
        rm -f "$CONFIG_DIR/reset_history.log"
    fi
    if [ "$legacy_tc" = "true" ]; then
        legacy_remove_tc_objects "$old_cfg" || rc=1
        tc_restore_all || { rc=1; dog_error "限速规则迁移未完成，请运行 dog --repair"; }
    else
        tc_write_interop || true
    fi
    rm -rf "$CONFIG_DIR/notifications"
    dog_unlock
    cron_sync || rc=1
    dog_log_event migrate "$rc"
    echo -e "${GREEN}迁移完成：$(jq '.monitors | length' <<< "$new_cfg") 个监控项，流量计数与配额已按原值保留。备份位于 $dir${NC}"
    jq -r --argjson v "$values" 'to_entries[] | "  \(.value)  ←  端口 \(.key)（计数来源：\($v[.key].source)）"' <<< "$idmap"
    return "$rc"
}

# 删除 1.5.x 创建的 TC 子类与过滤器（按旧配置记录的 class_id）。
legacy_remove_tc_objects() {
    local old_cfg="$1" iface class dev json
    iface=$(get_default_interface 2>/dev/null) || return 0
    begin_tc_update || return 1
    while IFS= read -r class; do
        [[ "$class" =~ ^1:[0-9a-fA-F]+$ ]] || continue
        for dev in "$iface" "$TC_IFB_DEVICE"; do
            ip link show "$dev" >/dev/null 2>&1 || continue
            json=$(tc -j filter show dev "$dev" parent 1:0 2>/dev/null || echo '[]')
            jq -r --arg c "$class" '.[] | select((.options.classid? // .options.flowid? // "") == $c and .options.handle? != null) |
                "\(.protocol) \(.pref) \(.kind) \(.options.handle)"' <<< "$json" 2>/dev/null |
            while read -r proto pref kind handle; do
                tc filter del dev "$dev" parent 1:0 protocol "$proto" pref "$pref" handle "$handle" "$kind" 2>/dev/null || true
            done
            # u32 过滤器的 handle 形如 800::800，按 pref 整组删除更可靠
            tc filter show dev "$dev" parent 1:0 2>/dev/null | awk -v c="$class" '$0 ~ "flowid " c "( |$)" {
                for (i = 1; i <= NF; i++) if ($i == "pref") print $(i + 1) }' | sort -u |
            while read -r pref; do
                tc filter del dev "$dev" parent 1:0 pref "$pref" 2>/dev/null || true
            done
            tc class del dev "$dev" classid "$class" 2>/dev/null || true
        done
    done < <(jq -r '.ports[] | .bandwidth_limit.class_id // empty' <<< "$old_cfg")
    finish_tc_update
}
