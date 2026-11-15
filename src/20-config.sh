# ── 配置（schema 2） ──────────────────────────────────────────────
# 监控项以稳定 ID（m1、m2…）为身份，端口只是成员列表：
#   .monitors.m1 = { ports:["8031","8032"], remark, billing_mode, quota, bandwidth_limit, expiry_date, created_at }
# 所有 nft/tc/统计/历史的名字都从 ID 派生，所以加减端口不会改变身份。

default_config_json() {
    jq -n --argjson schema "$CONFIG_SCHEMA" '{
        schema: $schema,
        global: { billing_mode: "double", next_monitor_id: 1, data_retention_days: 400 },
        monitors: {},
        notifications: {
            telegram: { enabled: false, bot_token: "", chat_id: "", server_name: "",
                        api_route: "official", custom_api_base: "",
                        status_notifications: { enabled: false, interval: "1h" } },
            wecom: { enabled: false, webhook_url: "", server_name: "",
                     status_notifications: { enabled: false, interval: "1h" } }
        }
    }'
}

# jq 程序：校验 schema 2 配置。输出错误字符串数组，空数组表示通过。
readonly CONFIG_VALIDATOR_JQ='
def leap($y): (($y % 4 == 0) and ($y % 100 != 0)) or ($y % 400 == 0);
def mdays($y; $m): if $m == 2 then (if leap($y) then 29 else 28 end)
                   elif ([4,6,9,11] | index($m)) then 30 else 31 end;
def valid_date: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") and
    ((.[0:4] | tonumber) as $y | (.[5:7] | tonumber) as $m | (.[8:10] | tonumber) as $d |
     $m >= 1 and $m <= 12 and $d >= 1 and $d <= mdays($y; $m));
def day_ok: type == "number" and . >= 1 and . <= 31 and floor == .;
def size_ok: type == "string" and (. == "unlimited" or test("^[0-9]+(\\.[0-9]+)?(K|KB|M|MB|G|GB|T|TB)$"; "i"));
def rate_ok: type == "string" and (. == "unlimited" or test("^[1-9][0-9]*(kbit|mbit|gbit)$"));
def interval_ok: type == "string" and IN("1m","15m","30m","1h","2h","6h","12h","24h");
def spec_bounds: if test("^[0-9]+$") then [tonumber, tonumber]
                 elif test("^[0-9]+-[0-9]+$") then (split("-") | map(tonumber))
                 else null end;
def monitor_errors($id):
    . as $m |
    [ (if ($id | test("^m[1-9][0-9]{0,5}$")) | not then "监控项 ID 无效: \($id)" else empty end),
      (if ($m | type) != "object" then "监控项 \($id) 不是对象" else empty end),
      (if ($m.ports | type) != "array" or ($m.ports | length) == 0 then "监控项 \($id) 没有端口"
       else ($m.ports[] | select(type != "string" or spec_bounds == null or
               (spec_bounds | .[0] < 1 or .[1] > 65535 or .[0] > .[1])) |
             "监控项 \($id) 的端口无效: \(.)") end),
      (if (($m.billing_mode // "double") | IN("single", "double")) | not then "监控项 \($id) 计费模式无效" else empty end),
      (if (($m.remark // "") | type) != "string" or (($m.remark // "") | length) > 64 then "监控项 \($id) 备注无效（最长 64 字符）" else empty end),
      (if ($m.quota // {}) | type != "object" then "监控项 \($id) quota 无效" else empty end),
      (if (($m.quota.enabled // false) | type) != "boolean" then "监控项 \($id) 配额开关无效" else empty end),
      (if (($m.quota.monthly_limit // "unlimited") | size_ok) | not then "监控项 \($id) 配额大小无效" else empty end),
      (if (($m.bandwidth_limit.enabled // false) | type) != "boolean" then "监控项 \($id) 限速开关无效" else empty end),
      (if (($m.bandwidth_limit.rate // "unlimited") | rate_ok) | not then "监控项 \($id) 限速值无效" else empty end),
      (if ($m.expiry_date // "") != "" and (($m.expiry_date | valid_date) | not) then "监控项 \($id) 到期日无效（YYYY-MM-DD）" else empty end),
      ( ($m.reset_policy // null) as $p |
        if $p == null then empty
        elif ($p | type) != "object" then "监控项 \($id) 重置策略无效"
        else
          (if ($p.type | IN("none","monthly","interval_days","interval_months","yearly","fixed_date")) | not
             then "监控项 \($id) 重置策略类型无效" else empty end),
          (if $p.type == "monthly" and ((($p.day // 1) | day_ok) | not) then "监控项 \($id) 每月重置日无效" else empty end),
          (if ($p.type | IN("interval_days","interval_months")) and
              (($p.every | type) != "number" or $p.every < 1 or $p.every > 36500 or ((($p.date // $p.anchor_date) | valid_date) | not))
             then "监控项 \($id) 周期重置参数无效" else empty end),
          (if $p.type == "yearly" and ((($p.month | type) != "number") or $p.month < 1 or $p.month > 12 or (($p.day | day_ok) | not))
             then "监控项 \($id) 每年重置日期无效" else empty end),
          (if $p.type == "fixed_date" and ((($p.date | valid_date) | not)) then "监控项 \($id) 一次性重置日期无效" else empty end),
          (if ($p.next_reset_date // "") != "" and (($p.next_reset_date | valid_date) | not) then "监控项 \($id) 下次重置日期无效" else empty end)
        end )
    ];
if type != "object" then ["配置根不是对象"]
elif .schema != 2 then ["配置 schema 不是 2"]
elif (.monitors | type) != "object" then ["monitors 不是对象"]
else
  [ (.monitors | to_entries[] | .value as $v | .key as $k | $v | monitor_errors($k)[]),
    ( [ .monitors | to_entries[] | .key as $k | .value.ports[]? | select(type == "string") |
        spec_bounds | select(. != null) | {k: $k, s: .[0], e: .[1]} ] | sort_by(.s) as $iv |
      range(1; $iv | length) | select($iv[.].s <= $iv[. - 1].e) |
      "端口重叠：\($iv[. - 1].k) 与 \($iv[.].k)" ),
    (if ((.global.next_monitor_id // 1) | type) != "number" then "global.next_monitor_id 无效" else empty end),
    (.notifications // {} | to_entries[] | select(.key | IN("telegram","wecom")) |
      .key as $c | .value |
      (if ((.enabled // false) | type) != "boolean" then "\($c) 开关无效" else empty end),
      (if ((.status_notifications.interval // "1h") | interval_ok) | not then "\($c) 推送周期无效" else empty end))
  ]
end
'

# 校验配置文件；有错误时逐条打印到 stderr 并返回 1。
# 1.5.x 配置（有 .ports、无 .schema）按“迁移后能否通过校验”判断：1.5.x 的 --update 会先用新脚本
# 校验当前配置再安装，这里拒绝就会让旧版无法原地升级。
validate_config_file() {
    local file="$1" errors input
    if ! input=$(jq -c '.' "$file" 2>/dev/null) || [ -z "$input" ]; then
        echo "配置文件不是有效 JSON: $file" >&2
        return 1
    fi
    if jq -e 'type == "object" and (has("schema") | not) and (.ports | type) == "object"' <<< "$input" >/dev/null 2>&1; then
        input=$(legacy_build_config "$input" 2>/dev/null | jq -c '.config' 2>/dev/null) || input=""
        if [ -z "$input" ] || [ "$input" = "null" ]; then
            echo "1.5.x 配置无法转换为 2.0 格式: $file" >&2
            return 1
        fi
    fi
    errors=$(jq -c "$CONFIG_VALIDATOR_JQ" <<< "$input" 2>/dev/null) || errors='["配置校验器执行失败"]'
    [ "$errors" = "[]" ] && return 0
    jq -r '.[]' <<< "$errors" | sed 's/^/配置错误：/' >&2
    return 1
}

config_exists() {
    [ -s "$CONFIG_FILE" ]
}

config_schema() {
    jq -r '.schema // (if has("ports") then 1 else 0 end)' "$CONFIG_FILE" 2>/dev/null || echo 0
}

# 读取配置字段：cfg '<jq 过滤器>' [jq 参数...]；输出原始字符串。
cfg() {
    local filter="$1"
    shift
    jq -r "$@" "$filter" "$CONFIG_FILE"
}

# 在 Dog 锁内修改配置，并在写入前校验结果，非法结果不会落盘。
config_update() {
    local filter="$1" out rc=0
    shift
    dog_lock || return 75
    if ! out=$(jq "$@" "$filter" "$CONFIG_FILE"); then
        dog_unlock; dog_log_event config_update 1; return 1
    fi
    # 内容未变化：不写文件、不记日志。
    if [ "$(jq -cS . <<< "$out")" = "$(jq -cS . "$CONFIG_FILE" 2>/dev/null)" ]; then
        dog_unlock; return 0
    fi
    local errors
    errors=$(jq -c "$CONFIG_VALIDATOR_JQ" <<< "$out" 2>/dev/null || echo '["jq 失败"]')
    if [ "$errors" != "[]" ]; then
        jq -r '.[]' <<< "$errors" 2>/dev/null | sed 's/^/配置错误：/' >&2
        dog_unlock; dog_log_event config_update 1; return 1
    fi
    printf '%s\n' "$out" | atomic_write "$CONFIG_FILE" 600 || rc=1
    dog_unlock
    dog_log_event config_update "$rc"
    return "$rc"
}

ensure_config() {
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$BACKUP_DIR"
    chmod 700 "$CONFIG_DIR" 2>/dev/null || true
    if ! config_exists; then
        default_config_json | atomic_write "$CONFIG_FILE" 600 || return 1
    fi
}

# 监控项 ID 列表，按数字顺序。
monitor_ids() {
    jq -r '.monitors | keys[]' "$CONFIG_FILE" 2>/dev/null | sort -t m -k2 -n
}

has_monitors() {
    jq -e '(.monitors // {}) | length > 0' "$CONFIG_FILE" >/dev/null 2>&1
}

monitor_exists() {
    [[ "$1" =~ ^m[0-9]+$ ]] && jq -e --arg id "$1" '.monitors | has($id)' "$CONFIG_FILE" >/dev/null 2>&1
}

# 读取监控项字段：mget <id> <jq 路径（相对监控项）> [默认值]
mget() {
    local id="$1" path="$2" default="${3:-}"
    jq -r --arg id "$id" --arg d "$default" ".monitors[\$id]${path} // \$d" "$CONFIG_FILE"
}

monitor_ports() {
    jq -r --arg id "$1" '.monitors[$id].ports[]?' "$CONFIG_FILE"
}

monitor_ports_csv() {
    jq -r --arg id "$1" '(.monitors[$id].ports // []) | join(",")' "$CONFIG_FILE"
}

# 显示用标签：备注 + 端口，端口过多时截断。
monitor_label() {
    jq -r --arg id "$1" '
        .monitors[$id] as $m |
        ($m.ports | join(",")) as $p |
        (if ($p | length) > 40 then ($p[0:37] + "…") else $p end) as $ps |
        if ($m.remark // "") != "" then "\($m.remark)（\($ps)）" else $ps end
    ' "$CONFIG_FILE"
}

monitor_billing_multiplier() {
    [ "$(mget "$1" .billing_mode double)" = "single" ] && echo 1 || echo 2
}

# 分配新 ID（调用方需持有 Dog 锁，并在同一次 config_update 中写回 next_monitor_id）。
next_monitor_id() {
    jq -r '
        ([.monitors | keys[] | ltrimstr("m") | tonumber] | max // 0) as $max |
        [(.global.next_monitor_id // 1), $max + 1] | max | "m\(.)"
    ' "$CONFIG_FILE"
}

# 把 "m3" 或成员端口 "8031" 解析为监控项 ID。
resolve_monitor() {
    local ref="$1" id
    if [[ "$ref" =~ ^[mM]([0-9]+)$ ]]; then
        id="m${BASH_REMATCH[1]}"
        monitor_exists "$id" && { echo "$id"; return 0; }
        return 1
    fi
    [[ "$ref" =~ ^[0-9]+$ ]] || return 1
    id=$(jq -r --argjson p "$ref" '
        .monitors | to_entries[] | select(any(.value.ports[];
            (if test("-") then (split("-") | map(tonumber)) else [tonumber, tonumber] end) as $b |
            $p >= $b[0] and $p <= $b[1])) | .key' "$CONFIG_FILE" | head -n1)
    [ -n "$id" ] || return 1
    echo "$id"
}
