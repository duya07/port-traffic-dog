# ── 端口解析 ──────────────────────────────────────────────────────
# 输入语法：`;` 分隔多个独立监控项；`,` 分隔同一监控项的成员；`-` 表示端口段。
# 例：`80,443;8080-8090` → 两个监控项 [80,443] 与 [8080-8090]。

# 规范化单个端口或端口段；非法时返回 1。
port_spec_normalize() {
    local s="${1//[[:space:]]/}" a b
    if [[ "$s" =~ ^[0-9]+$ ]]; then
        a=$((10#$s))
        [ "$a" -ge 1 ] && [ "$a" -le 65535 ] || return 1
        echo "$a"
    elif [[ "$s" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
        [ "$a" -ge 1 ] && [ "$b" -le 65535 ] && [ "$a" -le "$b" ] || return 1
        if [ "$a" -eq "$b" ]; then echo "$a"; else echo "$a-$b"; fi
    else
        return 1
    fi
}

port_spec_start() { echo "${1%%-*}"; }
port_spec_end() { echo "${1##*-}"; }

# 把 "443,80,8000-8010" 解析为规范化、排序后的成员（每行一个）。
# 成员之间重叠时报错；完全重复的成员自动去重。
parse_port_list() {
    local input="$1" item norm
    local -a specs=()
    IFS=',' read -ra _ppl_items <<< "$input"
    for item in "${_ppl_items[@]}"; do
        [ -n "${item//[[:space:]]/}" ] || continue
        if ! norm=$(port_spec_normalize "$item"); then
            echo -e "${RED}无效端口或端口段：$item（范围 1-65535，端口段写作 起始-结束）${NC}" >&2
            return 1
        fi
        specs+=("$norm")
    done
    [ "${#specs[@]}" -gt 0 ] || { echo -e "${RED}没有输入端口${NC}" >&2; return 1; }
    local sorted prev_end=0 prev="" spec s e
    sorted=$(printf '%s\n' "${specs[@]}" | sort -t- -k1,1n -k2,2n -u)
    while IFS= read -r spec; do
        s=$(port_spec_start "$spec"); e=$(port_spec_end "$spec")
        if [ -n "$prev" ] && [ "$s" -le "$prev_end" ]; then
            echo -e "${RED}端口 $prev 与 $spec 重叠${NC}" >&2
            return 1
        fi
        prev="$spec"; prev_end="$e"
        echo "$spec"
    done <<< "$sorted"
}

# 把 "a;b;c" 拆成若干监控项，每项是规范化后的逗号串，写入 nameref 数组。
parse_monitor_units() {
    local input="$1" unit members
    local -n _pmu_out=$2
    _pmu_out=()
    IFS=';' read -ra _pmu_units <<< "$input"
    for unit in "${_pmu_units[@]}"; do
        [ -n "${unit//[[:space:]]/}" ] || continue
        members=$(parse_port_list "$unit") || return 1
        _pmu_out+=("$(paste -sd, <<< "$members")")
    done
    [ "${#_pmu_out[@]}" -gt 0 ] || { echo -e "${RED}没有输入端口${NC}" >&2; return 1; }
    # 新输入的各项之间也不能重叠
    local all
    all=$(IFS=,; echo "${_pmu_out[*]}")
    parse_port_list "$all" >/dev/null || return 1
}

# 逗号串 → JSON 数组
ports_csv_to_json() {
    jq -cn --arg s "$1" '$s | split(",") | map(select(length > 0))'
}

# 检查端口（JSON 数组）是否与现有监控项冲突；$2 为要排除的监控项 ID。
# 冲突时输出 "监控项ID 端口" 并返回 0；无冲突返回 1。
find_port_conflict() {
    local ports_json="$1" exclude="${2:-}"
    jq -r --argjson new "$ports_json" --arg ex "$exclude" '
        def b: if test("-") then (split("-") | map(tonumber)) else [tonumber, tonumber] end;
        [ .monitors | to_entries[] | select(.key != $ex) | .key as $k | .value.ports[] |
          {k: $k, p: ., r: b} ] as $old |
        [ $new[] | b as $n | . as $np | $old[] |
          select(.r[0] <= $n[1] and $n[0] <= .r[1]) | "\(.k) \(.p) \($np)" ] | first // empty
    ' "$CONFIG_FILE"
}

# 端口集合运算：在 JSON 数组上做并/差（按规范化字符串精确匹配成员）。
ports_json_union() {
    jq -cn --argjson a "$1" --argjson b "$2" '$a + $b | unique'
}

ports_json_minus() {
    jq -cn --argjson a "$1" --argjson b "$2" '$a - $b'
}

# 端口 JSON 数组按数值排序并检查内部重叠；输出排序后的 JSON。
ports_json_normalize() {
    local csv members
    csv=$(jq -r 'join(",")' <<< "$1")
    members=$(parse_port_list "$csv") || return 1
    jq -cRn '[inputs | select(length > 0)]' <<< "$members"
}

# 渲染为 nft 集合元素："8031, 9000-9010"
ports_json_to_nft_elements() {
    jq -r 'join(", ")' <<< "$1"
}

# 当前系统监听端口（程序名 → 端口），添加监控时作参考。
show_listening_ports() {
    command -v ss >/dev/null 2>&1 || return 0
    echo -e "${GREEN}当前监听端口：${NC}"
    ss -tulnpH 2>/dev/null | awk '
        {
            n = split($5, a, ":"); port = a[n]
            prog = "-"
            if (match($0, /users:\(\("[^"]+"/)) { prog = substr($0, RSTART + 9, RLENGTH - 10) }
            if (port ~ /^[0-9]+$/ && !seen[prog SUBSEP port]++) list[prog] = list[prog] (list[prog] ? "," : "") port
        }
        END { for (p in list) printf "  %-18s %s\n", p, list[p] }
    ' | sort | head -n 30
}
