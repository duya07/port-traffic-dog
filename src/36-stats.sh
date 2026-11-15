# ── 自然日统计 ────────────────────────────────────────────────────
# traffic_stats.json：
#   {schema:2, monitors:{id:{last:{in,out}, daily:{"YYYY-MM-DD":{in,out}}}}}
# 每分钟快照：增量 = 当前计数 − 上次读数（计数回落视为被清零，增量取当前值）。
# 所有值都是原始字节，展示时乘当前计费倍率。周期流量以 nft 计数为准，日统计只用于历史展示。

stats_empty() { echo '{"schema":2,"monitors":{}}'; }

stats_load() {
    if [ ! -s "$TRAFFIC_STATS_FILE" ]; then
        stats_empty
        return 0
    fi
    if jq -e '.schema == 2 and (.monitors | type == "object")' "$TRAFFIC_STATS_FILE" >/dev/null 2>&1; then
        cat "$TRAFFIC_STATS_FILE"
        return 0
    fi
    # 损坏或旧格式：保留副本并告警，不静默清零。
    local keep
    keep="$TRAFFIC_STATS_FILE.corrupt.$(date +%Y%m%d%H%M%S)"
    cp -p "$TRAFFIC_STATS_FILE" "$keep" 2>/dev/null || true
    log_notification "traffic_stats.json 无法解析，已保留副本 $keep 并从空统计继续"
    stats_empty
}

stats_retention_days() {
    local d
    d=$(cfg '.global.data_retention_days // empty' 2>/dev/null || true)
    [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -ge 1 ] || d="$DEFAULT_TRAFFIC_RETENTION_DAYS"
    echo "$d"
}

# 执行一次快照：更新日统计、刷新灾备。调用方持有 Dog 锁。
stats_snapshot() {
    local values stats today cutoff ids
    nft_table_exists || return 1
    values=$(nft_read_values)
    ids=$(jq -c '.monitors | keys' "$CONFIG_FILE") || return 1
    # 有监控项却一个计数都读不到：规则异常，禁止用 0 覆盖统计与灾备。
    if [ "$ids" != "[]" ] && [ "$values" = "{}" ]; then
        return 1
    fi
    stats=$(stats_load)
    today=$(get_current_date)
    cutoff=$(add_days_to_date "$today" "-$(stats_retention_days)")
    jq -n --argjson s "$stats" --argjson v "$values" --argjson ids "$ids" \
          --arg today "$today" --arg cutoff "$cutoff" '
        def delta($cur; $last): if $last == null or $cur < $last then $cur else $cur - $last end;
        $s | .monitors = (
            reduce $ids[] as $id ((.monitors // {}) | with_entries(select(.key as $k | $ids | index($k)));
                if $v[$id] == null then .
                else
                    (.[$id] // {last: null, daily: {}}) as $m |
                    delta($v[$id].in; $m.last.in) as $di |
                    delta($v[$id].out; $m.last.out) as $do |
                    .[$id] = ($m
                        | .last = {in: $v[$id].in, out: $v[$id].out}
                        | .daily[$today].in = ((.daily[$today].in // 0) + $di)
                        | .daily[$today].out = ((.daily[$today].out // 0) + $do)
                        | .daily = (.daily | with_entries(select(.key >= $cutoff))))
                end))
    ' | atomic_write "$TRAFFIC_STATS_FILE" 600 || return 1
    traffic_backup_write "$values"
}

# 把统计基线对齐到当前计数（重置、合并、恢复之后调用，避免把计数变化算成流量）。
stats_rebaseline() {
    local id="$1" in_b="$2" out_b="$3" stats
    stats=$(stats_load)
    jq -n --argjson s "$stats" --arg id "$id" --argjson i "$in_b" --argjson o "$out_b" \
        '$s | .monitors[$id] = ((.monitors[$id] // {daily: {}}) | .last = {in: $i, out: $o})' |
        atomic_write "$TRAFFIC_STATS_FILE" 600
}

stats_rebaseline_all() {
    local values stats
    nft_table_exists || return 0
    values=$(nft_read_values)
    stats=$(stats_load)
    jq -n --argjson s "$stats" --argjson v "$values" '
        $s | reduce ($v | to_entries[]) as $e (.;
            .monitors[$e.key] = ((.monitors[$e.key] // {daily: {}}) | .last = {in: $e.value.in, out: $e.value.out}))
    ' | atomic_write "$TRAFFIC_STATS_FILE" 600
}

stats_drop_monitor() {
    [ -s "$TRAFFIC_STATS_FILE" ] || return 0
    json_update "$TRAFFIC_STATS_FILE" 'del(.monitors[$id])' --arg id "$1"
}

# 合并历史：把 $1 的日统计按日期加到 $2。
stats_merge_monitor() {
    local src="$1" dst="$2"
    [ -s "$TRAFFIC_STATS_FILE" ] || return 0
    json_update "$TRAFFIC_STATS_FILE" '
        (.monitors[$s].daily // {}) as $sd |
        .monitors[$d] = ((.monitors[$d] // {daily: {}}) |
            .daily = reduce ($sd | to_entries[]) as $e (.daily // {};
                .[$e.key].in = ((.[$e.key].in // 0) + $e.value.in) |
                .[$e.key].out = ((.[$e.key].out // 0) + $e.value.out))) |
        del(.monitors[$s])
    ' --arg s "$src" --arg d "$dst"
}

# 某监控项在日期区间 [from, to] 内的日统计（原始字节），输出 "in out"。
stats_sum_range() {
    local id="$1" from="$2" to="$3"
    [ -s "$TRAFFIC_STATS_FILE" ] || { echo "0 0"; return 0; }
    jq -r --arg id "$id" --arg f "$from" --arg t "$to" '
        [(.monitors[$id].daily // {}) | to_entries[] | select(.key >= $f and .key <= $t) | .value] |
        "\(map(.in) | add // 0) \(map(.out) | add // 0)"
    ' "$TRAFFIC_STATS_FILE" 2>/dev/null || echo "0 0"
}
