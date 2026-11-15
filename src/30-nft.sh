# ── nftables 后端 ─────────────────────────────────────────────────
# 表结构（每个监控项的规则数固定，与端口数量无关）：
#
#   map ptd_in_dport   { inet_service : verdict; interval }   端口 → jump ptd_<id>_in
#   map ptd_out_sport  { inet_service : verdict; interval }   端口 → jump ptd_<id>_out
#   map ptd_mark_sport / ptd_mark_dport                       启用限速时：端口 → jump ptd_<id>_mark
#   chain input   : meta l4proto {tcp,udp} th dport vmap @ptd_in_dport
#   chain output  : … th sport vmap @ptd_out_sport ; … th sport vmap @ptd_mark_sport
#   chain forward : … th dport vmap @ptd_in_dport ; … th sport vmap @ptd_out_sport ;
#                   … th dport vmap @ptd_mark_dport ; … th sport vmap @ptd_mark_sport
#   chain ptd_<id>_in / _out : [到期 drop] [quota … drop] counter name ptd_<id>_in|out
#   chain ptd_<id>_mark      : meta mark set meta mark & 0xfff | <mark>
#
# 计数器只记原始字节；计费倍率（双向 ×2 / 单向 ×1）在软件中计算，配额阈值 = 限额 ÷ 倍率。
# 加减端口只增删 map 元素，counter/quota 对象不受影响，因此流量与已用配额完整保留。

nft_t() { printf '%s %s' "$NFT_FAMILY" "$NFT_TABLE"; }

nft_available() {
    command -v nft >/dev/null 2>&1
}

nft_table_exists() {
    nft list table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1
}

# 原子执行一段 nft 脚本（标准输入）。失败时把错误和脚本保存到日志目录，便于排查。
nft_apply() {
    local script err rc=0
    script=$(cat)
    [ -n "$script" ] || return 0
    err=$(printf '%s\n' "$script" | nft -f - 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        { echo "# $(date -u +%FT%TZ) rc=$rc"; echo "$err" | sed 's/^/# /'; echo "$script"; } \
            > "$LOG_DIR/nft-last-failure.nft" 2>/dev/null || true
        chmod 600 "$LOG_DIR/nft-last-failure.nft" 2>/dev/null || true
        dog_error "nftables 事务失败：$(head -n 3 <<< "$err" | tr '\n' ' ')（详见 $LOG_DIR/nft-last-failure.nft）"
        return 1
    fi
}

# 当前运行状态摘要（一次 nft 调用）：
# {counters:{name:bytes}, quotas:{name:{limit,used}}, chains:{name:[rule 摘要]}, maps:{name:{key:target}}}
nft_runtime_json() {
    local raw
    # 表不存在时只返回 1、不输出：调用方统一用 `$(nft_runtime_json || echo null)` 取得单个 null
    #（若这里也输出 null，会得到两行 null，jq 解析失败，漂移检测结果变空）。
    raw=$(nft -j list table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null) || return 1
    jq -c '
        def key: if type == "object" and has("range") then "\(.range[0])-\(.range[1])" else tostring end;
        .nftables as $o |
        { counters: ([$o[] | .counter? // empty | {(.name): .bytes}] | add // {}),
          quotas:   ([$o[] | .quota? // empty | {(.name): {limit: .bytes, used: .used}}] | add // {}),
          chains:   ([$o[] | .chain? // empty | {(.name): []}] | add // {}),
          rules:    ([$o[] | .rule? // empty | {chain, comment: (.comment // ""),
                        kind: ([.expr[] | keys[0]] | join("+"))}] ),
          maps:     ([$o[] | .map? // empty | {(.name): ([(.elem // [])[] | {(.[0] | key): (.[1].jump.target // "")}] | add // {})}] | add // {})
        } | .chains = (reduce .rules[] as $r (.chains; .[$r.chain] += [($r.kind + (if $r.comment != "" then "#" + $r.comment else "" end))])) | del(.rules)
    ' <<< "$raw"
}

# 期望的配额原始字节阈值：限额 ÷ 倍率（向上取整）。不启用配额时输出空。
monitor_quota_raw_limit() {
    local id="$1" enabled limit bytes mult
    enabled=$(mget "$id" .quota.enabled false)
    limit=$(mget "$id" .quota.monthly_limit unlimited)
    [ "$enabled" = "true" ] && [ "$limit" != "unlimited" ] || return 0
    bytes=$(parse_size_to_bytes "$limit") || return 0
    mult=$(monitor_billing_multiplier "$id")
    echo $(( (bytes + mult - 1) / mult ))
}

monitor_is_expired() {
    local id="$1" exp
    exp=$(mget "$id" .expiry_date "")
    [ -n "$exp" ] && date_le "$exp" "$(get_current_date)"
}

monitor_tc_mark() {
    local id="$1"
    [ "$(mget "$id" .bandwidth_limit.enabled false)" = "true" ] || return 1
    local mark
    mark=$(mget "$id" .bandwidth_limit.mark_id "")
    [[ "$mark" =~ ^[0-9]+$ ]] && [ "$mark" -gt 0 ] || return 1
    echo "$mark"
}

# 渲染监控项链内规则（假定链已存在且为空）。
nft_render_monitor_rules() {
    local id="$1" t dir quota mark
    t=$(nft_t)
    quota=$(monitor_quota_raw_limit "$id")
    for dir in in out; do
        if monitor_is_expired "$id"; then
            printf 'add rule %s ptd_%s_%s drop comment "ptd_expired"\n' "$t" "$id" "$dir"
        fi
        if [ -n "$quota" ]; then
            printf 'add rule %s ptd_%s_%s quota name "ptd_%s_quota" drop\n' "$t" "$id" "$dir" "$id"
        fi
        printf 'add rule %s ptd_%s_%s counter name "ptd_%s_%s"\n' "$t" "$id" "$dir" "$id" "$dir"
    done
    if mark=$(monitor_tc_mark "$id"); then
        printf 'add rule %s ptd_%s_mark meta mark set meta mark and %s or %s\n' \
            "$t" "$id" "$TC_MARK_PRESERVE_MASK" "$(printf '0x%08x' "$mark")"
    fi
}

# 渲染 map 元素（add 或 delete）。$3 为端口 JSON 数组。
nft_render_elements() {
    local op="$1" id="$2" ports_json="$3" t elems
    t=$(nft_t)
    [ "$(jq 'length' <<< "$ports_json")" -gt 0 ] || return 0
    if [ "$op" = "add" ]; then
        elems=$(jq -r --arg id "$id" 'map("\(.) : jump ptd_\($id)_DIR") | join(", ")' <<< "$ports_json")
        printf 'add element %s %s { %s }\n' "$t" "$NFT_MAP_IN" "${elems//_DIR/_in}"
        printf 'add element %s %s { %s }\n' "$t" "$NFT_MAP_OUT" "${elems//_DIR/_out}"
        if monitor_tc_mark "$id" >/dev/null; then
            printf 'add element %s %s { %s }\n' "$t" "$NFT_MAP_MARK_SPORT" "${elems//_DIR/_mark}"
            printf 'add element %s %s { %s }\n' "$t" "$NFT_MAP_MARK_DPORT" "${elems//_DIR/_mark}"
        fi
    else
        elems=$(ports_json_to_nft_elements "$ports_json")
        printf 'delete element %s %s { %s }\n' "$t" "$NFT_MAP_IN" "$elems"
        printf 'delete element %s %s { %s }\n' "$t" "$NFT_MAP_OUT" "$elems"
        if [ "${4:-}" = "with_mark" ]; then
            printf 'delete element %s %s { %s }\n' "$t" "$NFT_MAP_MARK_SPORT" "$elems"
            printf 'delete element %s %s { %s }\n' "$t" "$NFT_MAP_MARK_DPORT" "$elems"
        fi
    fi
}

# 渲染一个监控项的对象、链与规则（不含映射元素）。$2..$4 为初始 in/out/quota_used 原始字节。
nft_render_monitor_objects() {
    local id="$1" in_b="${2:-0}" out_b="${3:-0}" used="${4:-0}" t quota
    t=$(nft_t)
    printf 'add counter %s ptd_%s_in { packets 0 bytes %s }\n' "$t" "$id" "$in_b"
    printf 'add counter %s ptd_%s_out { packets 0 bytes %s }\n' "$t" "$id" "$out_b"
    quota=$(monitor_quota_raw_limit "$id")
    if [ -n "$quota" ]; then
        printf 'add quota %s ptd_%s_quota { over %s bytes used %s bytes }\n' "$t" "$id" "$quota" "$used"
    fi
    printf 'add chain %s ptd_%s_in\n' "$t" "$id"
    printf 'add chain %s ptd_%s_out\n' "$t" "$id"
    if monitor_tc_mark "$id" >/dev/null; then
        printf 'add chain %s ptd_%s_mark\n' "$t" "$id"
    fi
    nft_render_monitor_rules "$id"
}

monitor_ports_json() {
    jq -c --arg id "$1" '.monitors[$id].ports' "$CONFIG_FILE"
}

# 渲染一个监控项的全部对象与映射元素（用于向已有表中添加：映射已存在）。
nft_render_monitor() {
    nft_render_monitor_objects "$@"
    nft_render_elements add "$1" "$(monitor_ports_json "$1")"
}

# 渲染整张表。$1 为初始值 JSON：{id:{in,out,quota_used}}。
# 顺序有讲究：同一事务内 interval verdict map 若先于被 jump 的链创建，nft 1.0.x 会拒绝
# 添加元素（No such file or directory），因此先建全部监控项链，再建映射，最后加元素。
nft_render_table() {
    local values="${1:-}" t id v in_b out_b used
    [ -n "$values" ] || values='{}'
    t=$(nft_t)
    local l4='meta l4proto { tcp, udp }'
    local -a ids=()
    mapfile -t ids < <(monitor_ids)
    printf 'add table %s\ndelete table %s\nadd table %s\n' "$t" "$t" "$t"
    for id in "${ids[@]}"; do
        [ -n "$id" ] || continue
        read -r in_b out_b used < <(jq -r --arg id "$id" \
            '.[$id] // {} | "\(.in // 0) \(.out // 0) \(.quota_used // 0)"' <<< "$values")
        nft_render_monitor_objects "$id" "$in_b" "$out_b" "$used"
    done
    for v in "$NFT_MAP_IN" "$NFT_MAP_OUT" "$NFT_MAP_MARK_SPORT" "$NFT_MAP_MARK_DPORT"; do
        printf 'add map %s %s { type inet_service : verdict; flags interval; }\n' "$t" "$v"
    done
    for id in "${ids[@]}"; do
        [ -n "$id" ] || continue
        nft_render_elements add "$id" "$(monitor_ports_json "$id")"
    done
    printf 'add chain %s input { type filter hook input priority 0; policy accept; }\n' "$t"
    printf 'add chain %s output { type filter hook output priority 0; policy accept; }\n' "$t"
    printf 'add chain %s forward { type filter hook forward priority 0; policy accept; }\n' "$t"
    printf 'add rule %s input %s th dport vmap @%s\n' "$t" "$l4" "$NFT_MAP_IN"
    printf 'add rule %s output %s th sport vmap @%s\n' "$t" "$l4" "$NFT_MAP_OUT"
    printf 'add rule %s output %s th sport vmap @%s\n' "$t" "$l4" "$NFT_MAP_MARK_SPORT"
    printf 'add rule %s forward %s th dport vmap @%s\n' "$t" "$l4" "$NFT_MAP_IN"
    printf 'add rule %s forward %s th sport vmap @%s\n' "$t" "$l4" "$NFT_MAP_OUT"
    printf 'add rule %s forward %s th dport vmap @%s\n' "$t" "$l4" "$NFT_MAP_MARK_DPORT"
    printf 'add rule %s forward %s th sport vmap @%s\n' "$t" "$l4" "$NFT_MAP_MARK_SPORT"
}

# 读取全部监控项当前原始计数：{id:{in,out,quota_used}}；表不存在时输出 {}。
nft_read_values() {
    local rt
    rt=$(nft_runtime_json 2>/dev/null) || { echo '{}'; return 0; }
    [ "$rt" != "null" ] || { echo '{}'; return 0; }
    jq -c '
        .counters as $c | .quotas as $q |
        [ $c | keys[] | capture("^ptd_(?<id>m[0-9]+)_(in|out)$")? | .id ] | unique |
        map({(.): {in: ($c["ptd_\(.)_in"] // 0), out: ($c["ptd_\(.)_out"] // 0),
                   quota_used: ($q["ptd_\(.)_quota"].used // 0)}}) | add // {}
    ' <<< "$rt"
}

# 读取单个监控项原始计数，输出 "in out quota_used"；不存在返回 1。
nft_read_monitor() {
    local id="$1" values
    values=$(nft_read_values)
    jq -e -r --arg id "$id" '.[$id] | select(. != null) | "\(.in) \(.out) \(.quota_used)"' <<< "$values"
}

# 期望的运行状态与实际是否一致；不一致时把原因逐行输出并返回 1。
nft_runtime_drift() {
    local rt="${1:-}" desired
    [ -n "$rt" ] || rt=$(nft_runtime_json 2>/dev/null || echo null)
    if [ "$rt" = "null" ]; then
        has_monitors && { echo "nftables 表 $NFT_TABLE 不存在"; return 1; }
        return 0
    fi
    desired=$(nft_desired_json)
    jq -rn --argjson rt "$rt" --argjson want "$desired" '
        [ ($want.chains | to_entries[] | . as $e |
            if ($rt.chains[$e.key] // null) == null then "缺少链 \($e.key)"
            elif $rt.chains[$e.key] != $e.value then "链 \($e.key) 规则与配置不一致" else empty end),
          ($want.counters[] | select(($rt.counters[.] // null) == null) | "缺少计数器 \(.)"),
          ($want.quotas | to_entries[] | . as $e |
            if ($rt.quotas[$e.key] // null) == null then "缺少配额对象 \($e.key)"
            elif $rt.quotas[$e.key].limit != $e.value then "配额 \($e.key) 阈值与配置不一致" else empty end),
          ($rt.quotas | keys[] | select(($want.quotas[.] // null) == null) | "多余的配额对象 \(.)"),
          ($want.maps | to_entries[] | . as $m |
            if (($rt.maps[$m.key] // {}) != $m.value) then "映射 \($m.key) 元素与配置不一致" else empty end),
          (["input","output","forward"][] | select(($rt.chains[.] // null) == null) | "缺少基础链 \(.)")
        ] | .[]
    ' | { local any=false; while IFS= read -r line; do any=true; echo "$line"; done; [ "$any" = false ]; }
}

# 按配置生成期望状态（与 nft_runtime_json 同构，用于比较）。
nft_desired_json() {
    local today
    today=$(get_current_date)
    jq -c --arg today "$today" '
        def bytes($s): ($s | ascii_upcase | capture("^(?<n>[0-9]+(\\.[0-9]+)?)(?<u>[KMGT])") ) as $c |
            ($c.n | tonumber) * ({"K":1024,"M":1048576,"G":1073741824,"T":1099511627776}[$c.u]) | floor;
        .monitors as $ms |
        ($ms | to_entries | map(
            .key as $id | .value as $m |
            (if ($m.billing_mode // "double") == "single" then 1 else 2 end) as $mult |
            (($m.quota.enabled // false) and (($m.quota.monthly_limit // "unlimited") != "unlimited")) as $hasq |
            (($m.expiry_date // "") != "" and $m.expiry_date <= $today) as $exp |
            (($m.bandwidth_limit.enabled // false) and (($m.bandwidth_limit.mark_id // 0) > 0)) as $tc |
            { id: $id, ports: $m.ports, tc: $tc,
              quota: (if $hasq then ((bytes($m.quota.monthly_limit) + $mult - 1) / $mult | floor) else null end),
              chain: ((if $exp then ["drop#ptd_expired"] else [] end) +
                      (if $hasq then ["quota+drop"] else [] end) + ["counter"]) })) as $list |
        { counters: [$list[] | "ptd_\(.id)_in", "ptd_\(.id)_out"],
          quotas: ([$list[] | select(.quota != null) | {("ptd_\(.id)_quota"): .quota}] | add // {}),
          chains: ([$list[] | {("ptd_\(.id)_in"): .chain}, {("ptd_\(.id)_out"): .chain},
                    (select(.tc) | {("ptd_\(.id)_mark"): ["mangle"]})] | add // {}),
          maps: {
            ptd_in_dport: ([$list[] | .id as $id | .ports[] | {(.): "ptd_\($id)_in"}] | add // {}),
            ptd_out_sport: ([$list[] | .id as $id | .ports[] | {(.): "ptd_\($id)_out"}] | add // {}),
            ptd_mark_sport: ([$list[] | select(.tc) | .id as $id | .ports[] | {(.): "ptd_\($id)_mark"}] | add // {}),
            ptd_mark_dport: ([$list[] | select(.tc) | .id as $id | .ports[] | {(.): "ptd_\($id)_mark"}] | add // {})
          } }
    ' "$CONFIG_FILE"
}

# 整表重建：优先保留内核当前计数，缺失的再从灾备文件补。调用方持有 Dog 锁。
nft_rebuild_all() {
    local values backup
    values=$(nft_read_values)
    backup=$(traffic_backup_values)
    values=$(jq -cn --argjson cur "$values" --argjson bak "$backup" '$bak + $cur')
    nft_render_table "$values" | nft_apply || return 1
    dog_log_event runtime_restore 0
}

nft_add_monitor() {
    local id="$1"
    { nft_runtime_json >/dev/null 2>&1 && nft_table_exists; } || { nft_rebuild_all; return; }
    nft_render_monitor "$id" 0 0 0 | nft_apply
}

# 渲染：删除监控项的全部运行对象（只删实际存在的，避免事务因对象不存在而整体失败）。
nft_render_remove_monitor() {
    local id="$1" rt="$2" t obj
    t=$(nft_t)
    jq -r --arg id "$id" --arg t "$t" '
        .maps | to_entries[] | .key as $map |
        [.value | to_entries[] | select(.value | test("^ptd_\($id)_")) | .key] |
        select(length > 0) | "delete element \($t) \($map) { \(join(", ")) }"
    ' <<< "$rt"
    for obj in in out mark; do
        if jq -e --arg c "ptd_${id}_$obj" '.chains | has($c)' <<< "$rt" >/dev/null; then
            printf 'flush chain %s ptd_%s_%s\ndelete chain %s ptd_%s_%s\n' "$t" "$id" "$obj" "$t" "$id" "$obj"
        fi
    done
    for obj in in out; do
        if jq -e --arg c "ptd_${id}_$obj" '.counters | has($c)' <<< "$rt" >/dev/null; then
            printf 'delete counter %s ptd_%s_%s\n' "$t" "$id" "$obj"
        fi
    done
    if jq -e --arg c "ptd_${id}_quota" '.quotas | has($c)' <<< "$rt" >/dev/null; then
        printf 'delete quota %s ptd_%s_quota\n' "$t" "$id"
    fi
}

nft_remove_monitor() {
    local id="$1" rt
    rt=$(nft_runtime_json 2>/dev/null || echo null)
    [ "$rt" != "null" ] || return 0
    nft_render_remove_monitor "$id" "$rt" | nft_apply
}

# 端口变更：只增删 map 元素（单事务）。计数与配额对象不动。
nft_change_ports() {
    local id="$1" old_json="$2" new_json="$3" added removed with_mark=""
    added=$(jq -cn --argjson a "$new_json" --argjson b "$old_json" '$a - $b')
    removed=$(jq -cn --argjson a "$old_json" --argjson b "$new_json" '$a - $b')
    monitor_tc_mark "$id" >/dev/null && with_mark=with_mark
    {
        nft_render_elements delete "$id" "$removed" "$with_mark"
        nft_render_elements add "$id" "$added"
    } | nft_apply
}

# 渲染：按配置重建监控项的链、映射元素与 counter/quota（以指定初值）。要求链已存在。
nft_render_sync_monitor() {
    local id="$1" in_b="$2" out_b="$3" used="$4" rt="$5" t quota ports
    t=$(nft_t)
    quota=$(monitor_quota_raw_limit "$id")
    ports=$(jq -c --arg id "$id" '.monitors[$id].ports' "$CONFIG_FILE")
    jq -r --arg id "$id" --arg t "$t" '
        .maps | to_entries[] | .key as $map |
        [.value | to_entries[] | select(.value | test("^ptd_\($id)_")) | .key] |
        select(length > 0) | "delete element \($t) \($map) { \(join(", ")) }"
    ' <<< "$rt"
    printf 'flush chain %s ptd_%s_in\nflush chain %s ptd_%s_out\n' "$t" "$id" "$t" "$id"
    if jq -e --arg c "ptd_${id}_mark" '.chains | has($c)' <<< "$rt" >/dev/null; then
        printf 'flush chain %s ptd_%s_mark\ndelete chain %s ptd_%s_mark\n' "$t" "$id" "$t" "$id"
    fi
    printf 'delete counter %s ptd_%s_in\ndelete counter %s ptd_%s_out\n' "$t" "$id" "$t" "$id"
    printf 'add counter %s ptd_%s_in { packets 0 bytes %s }\n' "$t" "$id" "$in_b"
    printf 'add counter %s ptd_%s_out { packets 0 bytes %s }\n' "$t" "$id" "$out_b"
    if jq -e --arg c "ptd_${id}_quota" '.quotas | has($c)' <<< "$rt" >/dev/null; then
        printf 'delete quota %s ptd_%s_quota\n' "$t" "$id"
    fi
    if [ -n "$quota" ]; then
        printf 'add quota %s ptd_%s_quota { over %s bytes used %s bytes }\n' "$t" "$id" "$quota" "$used"
    fi
    if monitor_tc_mark "$id" >/dev/null; then
        printf 'add chain %s ptd_%s_mark\n' "$t" "$id"
    fi
    nft_render_monitor_rules "$id"
    nft_render_elements add "$id" "$ports"
}

# 重新生成监控项链内容（配额/到期/限速/计费变化后调用）。$2..$4 为 counter/quota 初值，
# 省略时保留当前值。全部在一个事务内完成。
nft_sync_monitor() {
    local id="$1" in_b="${2:-}" out_b="${3:-}" used="${4:-}" rt cur
    rt=$(nft_runtime_json 2>/dev/null || echo null)
    if [ "$rt" = "null" ] || ! jq -e --arg c "ptd_${id}_in" '.chains | has($c)' <<< "$rt" >/dev/null; then
        nft_rebuild_all; return
    fi
    if [ -z "$in_b" ]; then
        cur=$(nft_read_monitor "$id" 2>/dev/null || echo "0 0 0")
        read -r in_b out_b used <<< "$cur"
    fi
    nft_render_sync_monitor "$id" "$in_b" "$out_b" "$used" "$rt" | nft_apply
}

# 清零监控项计数与配额（周期重置）。
nft_reset_monitor() {
    nft_sync_monitor "$1" 0 0 0
}
