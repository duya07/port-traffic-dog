#!/bin/bash
# Dog 2.0 单元测试：只 source 函数，不调用 nft/tc/crontab，状态全部在临时目录。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export PORT_TRAFFIC_DOG_CONFIG_DIR="$T/etc" PORT_TRAFFIC_DOG_LOCK_FILE="$T/lock" NO_COLOR=1
mkdir -p "$T/etc" "$T/stub"
# shellcheck disable=SC1090
source <(sed '$d' "$ROOT/port-traffic-dog.sh")
set +e +u

PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL - $1：期望 [$3]，实际 [$2]"; fi; }
yes_() { if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL - 应成功：$*"; fi; }
no_() { if "$@" >/dev/null 2>&1; then FAIL=$((FAIL + 1)); echo "FAIL - 应失败：$*"; else PASS=$((PASS + 1)); fi; }

# 日期
eq "月末钳制" "$(calculate_monthly_next_date 31 2026-02-10)" "2026-02-28"
eq "跨年" "$(calculate_monthly_next_date 1 2026-12-02)" "2027-01-01"
eq "当天" "$(calculate_monthly_next_date 15 2026-11-15)" "2026-11-15"
eq "加月" "$(add_months_to_date 2026-01-31 1 31)" "2026-02-28"
eq "每 30 天" "$(calculate_interval_days_next_date 2026-11-01 30 2026-11-15)" "2026-12-01"
eq "每 3 个月" "$(calculate_interval_months_next_date 2026-01-15 3 15 2026-05-01)" "2026-07-15"
eq "每年" "$(calculate_yearly_next_date 2 29 2027-03-01)" "2028-02-29"
eq "加天" "$(add_days_to_date 2026-12-31 1)" "2027-01-01"
eq "减天" "$(add_days_to_date 2026-03-01 -1)" "2026-02-28"

# 端口与大小
eq "端口段规范化" "$(port_spec_normalize ' 8000-8000 ')" "8000"
no_ port_spec_normalize 70000
no_ port_spec_normalize 90-80
eq "排序去重" "$(parse_port_list '443,80,443,8000-8010' | paste -sd,)" "80,443,8000-8010"
no_ parse_port_list '80,70-90'
parse_monitor_units '80,443;8080-8090' units
# shellcheck disable=SC2154  # units 由 parse_monitor_units 通过 nameref 赋值
eq "多项拆分" "${units[*]}" "80,443 8080-8090"
no_ parse_monitor_units '80;70-90' units
eq "GB" "$(parse_size_to_bytes 240GB)" "257698037760"
eq "小数 TB" "$(parse_size_to_bytes 1.5t)" "1649267441664"
eq "KB" "$(parse_size_to_bytes 800KB)" "819200"
no_ parse_size_to_bytes 12XB
eq "格式化" "$(format_bytes 1310720)" "1.25MB"
eq "格式化 B" "$(format_bytes 512)" "512B"
eq "带宽转换" "$(convert_bandwidth_to_tc 100Mbps)" "100mbit"
no_ validate_bandwidth 100mb

# 重置策略简写
eq "monthly" "$(parse_reset_spec monthly:15)" '{"type":"monthly","day":15}'
eq "days" "$(parse_reset_spec days:30@2026-11-01)" '{"type":"interval_days","every":30,"anchor_date":"2026-11-01"}'
eq "months" "$(parse_reset_spec months:3@2026-01-20:5)" '{"type":"interval_months","every":3,"anchor_date":"2026-01-20","day":5}'
eq "yearly" "$(parse_reset_spec yearly:2-29)" '{"type":"yearly","month":2,"day":29}'
eq "once" "$(parse_reset_spec once:2027-01-01)" '{"type":"fixed_date","date":"2027-01-01"}'
no_ parse_reset_spec monthly:32

# 配置与监控项访问
cat > "$CONFIG_FILE" <<'JSON'
{"schema":2,"global":{"next_monitor_id":3},
 "monitors":{"m1":{"ports":["8031","8032"],"remark":"web1","billing_mode":"double",
   "quota":{"enabled":true,"monthly_limit":"240GB"},"bandwidth_limit":{"enabled":false,"rate":"unlimited"},
   "reset_policy":{"type":"monthly","day":1,"next_reset_date":"2026-12-01","last_reset_date":"2026-11-01"},
   "expiry_date":"2027-02-15","created_at":"2026-11-14T17:58:24+08:00"},
  "m2":{"ports":["3001-3009"],"billing_mode":"single","quota":{"enabled":false,"monthly_limit":"unlimited"},
   "reset_policy":{"type":"none"}}},
 "notifications":{"telegram":{"enabled":true,"bot_token":"123456:SECRETTOKEN","chat_id":"42","server_name":"demo-node",
   "api_route":"official","status_notifications":{"enabled":true,"interval":"12h"}},
  "wecom":{"enabled":false,"status_notifications":{"enabled":false,"interval":"1h"}}}}
JSON
yes_ validate_config_file "$CONFIG_FILE"
eq "按端口定位" "$(resolve_monitor 3005)" "m2"
eq "按 ID 定位" "$(resolve_monitor M1)" "m1"
no_ resolve_monitor 9999
eq "下一个 ID" "$(next_monitor_id)" "m3"
eq "倍率" "$(monitor_billing_multiplier m2)" "1"
eq "配额阈值（双向）" "$(monitor_quota_raw_limit m1)" "128849018880"
eq "周期" "$(monitor_cycle_range m1)" "2026-11-01~2026-11-30"
eq "冲突检测" "$(find_port_conflict '["3005"]')" "m2 3001-3009 3005"
eq "冲突排除自身" "$(find_port_conflict '["8031"]' m1)" ""

# cron 期望行
cron_lines=$(desired_dog_cron_lines)
eq "cron 行数" "$(wc -l <<< "$cron_lines")" "3"
grep -q '^0 \*/12 \* \* \* .* --send-status telegram' <<< "$cron_lines"; eq "推送周期" "$?" "0"

# 截断不切断多字节字符
long=$(for i in $(seq 1 400); do echo "第${i}行：端口流量统计测试"; done)
cut=$(printf '%s\n' "$long" | truncate_lines_bytes 3900)
eq "截断后字节数 ≤ 3900+尾注" "$([ "$(printf '%s' "$cut" | wc -c)" -le 3940 ] && echo y)" "y"
printf '%s' "$cut" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; eq "截断后仍是合法 UTF-8" "$?" "0"
tail -n1 <<< "$cut" | grep -q '已截断'; eq "截断尾注" "$?" "0"

# Telegram：token 不出现在 curl 参数中
cat > "$T/stub/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$T/curl.args"
cat > "$T/curl.stdin"
echo '{"ok":true}'
EOF
chmod +x "$T/stub/curl"
PATH="$T/stub:$PATH" telegram_send "测试消息"; eq "发送成功" "$?" "0"
grep -q SECRETTOKEN "$T/curl.args"; eq "token 不在参数中" "$?" "1"
grep -q 'url = "https://api.telegram.org/bot123456:SECRETTOKEN/sendMessage"' "$T/curl.stdin"; eq "URL 经 stdin 传入" "$?" "0"
grep -q 'SECRETTOKEN' "$NOTIFY_LOG_FILE"; eq "日志中 token 已掩码" "$?" "1"

# 读数失败：发送告警并返回 2
nft_available() { return 1; }
PATH="$T/stub:$PATH" send_status_report telegram; eq "读数失败返回 2" "$?" "2"
grep -q '流量读取失败' "$T/curl.args"; eq "告警正文已发送" "$?" "0"

# TC 速率换算
eq "gbit→kbps" "$(parse_tc_rate_to_kbps 2gbit)" "2000000"
eq "mbit→kbps" "$(parse_tc_rate_to_kbps 100mbit)" "100000"
eq "kbit→kbps" "$(parse_tc_rate_to_kbps 512kbit)" "512"

# 快捷命令归属：只接管 2.0 标记、软链接或 1.4/1.5 的单行包装脚本
sc_case() {
    printf '#!/bin/bash\n%s\n' "$1" > "$T/dog-sc"
    PORT_TRAFFIC_DOG_SHORTCUT_PATH="$T/dog-sc" bash -c 'source <(sed "\$d" "$1"); shortcut_is_ours' _ "$ROOT/port-traffic-dog.sh" && echo ours || echo foreign
}
eq "1.5 包装脚本" "$(sc_case "exec bash \"$INSTALLED_SCRIPT_PATH\" \"\$@\"")" "ours"
eq "1.4 包装脚本" "$(sc_case "exec bash $INSTALLED_SCRIPT_PATH \"\$@\"")" "ours"
eq "他人脚本" "$(sc_case 'exec bash /opt/other.sh "$@"')" "foreign"
eq "夹带其他命令" "$(sc_case "$(printf 'echo hi\nexec bash %s "$@"' "$INSTALLED_SCRIPT_PATH")")" "foreign"

# 导入：危险路径排在最前、清单远超管道缓冲区时也必须拒绝（pipefail + grep -q 会让 tar 收到 SIGPIPE）。
python3 - "$T/evil.tgz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    def add(name, data=b"{}"):
        i = tarfile.TarInfo(name); i.size = len(data); t.addfile(i, io.BytesIO(data))
    add("port-traffic-dog-config/../../ptd-evil")
    for n in range(6000):
        add("port-traffic-dog-config/pad-%05d-%s" % (n, "x" * 40))
    add("port-traffic-dog-config/config.json", b'{"schema":2,"monitors":{}}')
PY
import_out=$(import_config "$T/evil.tgz" 2>&1); eq "危险路径归档被拒绝" "$?" "1"
grep -q '不安全路径' <<< "$import_out"; eq "拒绝原因为不安全路径" "$?" "0"

# --repair 的依赖步骤：只检测一次；缺失时按 DOG_NONINTERACTIVE 决定是否免确认，不得调用自带安装的 check_dependencies。
# shellcheck disable=SC2034  # DOG_NONINTERACTIVE 由被测函数读取
(
    calls=""
    dependency_report() { calls+="report;"; return 1; }
    check_dependencies() { calls+="check;"; return 0; }
    dependency_install_missing() { calls+="install:$1;"; return 1; }
    ensure_config() { return 1; }
    DOG_NONINTERACTIVE=false; system_check_and_repair >/dev/null 2>&1
    echo "$calls"
    DOG_NONINTERACTIVE=true; calls=""; system_check_and_repair >/dev/null 2>&1
    echo "$calls"
    dependency_report() { calls+="report;"; return 0; }
    calls=""; system_check_and_repair >/dev/null 2>&1
    echo "$calls"
) > "$T/repair-deps.out"
eq "repair 依赖：交互模式询问" "$(sed -n 1p "$T/repair-deps.out")" "report;install:false;"
eq "repair 依赖：--yes 免确认且只装一次" "$(sed -n 2p "$T/repair-deps.out")" "report;install:true;"
eq "repair 依赖：齐全时不安装" "$(sed -n 3p "$T/repair-deps.out")" "report;"

# nft 表不存在：nft_runtime_json 不得输出内容；调用方 `|| echo null` 必须得到单个 null，
# 漂移检测必须明确报告“表不存在”（曾输出两行 null，jq 失败，开机日志里漂移明细为空）。
(
    nft() { return 1; }
    has_monitors() { return 0; }
    echo "json=[$(nft_runtime_json 2>/dev/null)]"
    echo "fallback=[$(nft_runtime_json 2>/dev/null || echo null)]"
    d=$(nft_runtime_drift 2>/dev/null); echo "drift=$? $d"
) > "$T/drift.out"
eq "缺表：runtime_json 无输出" "$(sed -n 1p "$T/drift.out")" "json=[]"
eq "缺表：调用方得到单个 null" "$(sed -n 2p "$T/drift.out")" "fallback=[null]"
eq "缺表：漂移明细为表不存在" "$(sed -n 3p "$T/drift.out")" "drift=1 nftables 表 port_traffic_monitor 不存在"

# 2.1：按监控项开关推送（.notify 缺省为 true）
for v in true false; do
    jq --argjson v "$v" '.monitors.m2.notify = $v' "$CONFIG_FILE" > "$T/n.json"; yes_ validate_config_file "$T/n.json"
done
for v in '"no"' 1 null; do
    jq --argjson v "$v" '.monitors.m2.notify = $v' "$CONFIG_FILE" > "$T/n.json"; no_ validate_config_file "$T/n.json"
done
cp "$CONFIG_FILE" "$T/config-base.json"
jq '.monitors.m2.notify = false' "$T/config-base.json" > "$CONFIG_FILE"
yes_ monitor_notify_enabled m1
no_ monitor_notify_enabled m2
eq "推送项不含 notify:false" "$(notify_monitor_ids | paste -sd,)" "m1"
# 对照：jq 的 `//` 把 false 当成“没有值”，所以不能用 mget 读缺省为真的布尔字段。
eq "mget 读 notify 的坑（对照）" "$(mget m2 .notify true)" "true"
report_case() {   # $1=nft 读数 JSON；输出报告正文与返回码
    (
        values_json="$1"
        nft_available() { return 0; }
        nft_table_exists() { return 0; }
        nft_read_values() { echo "$values_json"; }
        build_status_report demo-node; echo "rc=$?"
    )
}
out=$(report_case '{"m1":{"in":1000,"out":2000,"quota_used":0},"m2":{"in":5000,"out":5000,"quota_used":0}}')
grep -q '\[m1\]' <<< "$out" && ! grep -q '\[m2\]' <<< "$out"; eq "报告不含关闭推送的 m2" "$?" "0"
grep -q '监控项: 1个 | 周期总流量: 5.86KB' <<< "$out"; eq "报告头的数量与总量只算开启推送的项" "$?" "0"
eq "报告正常返回 0" "$(tail -n1 <<< "$out")" "rc=0"
out=$(report_case '{"m1":{"in":1,"out":1,"quota_used":0}}')
eq "关闭推送的项缺计数不告警" "$(tail -n1 <<< "$out")" "rc=0"
jq '.monitors.m1.notify = false | .monitors.m2.notify = false' "$T/config-base.json" > "$CONFIG_FILE"
out=$(report_case '{}')
eq "全部关闭：报告返回 3" "$(tail -n1 <<< "$out")" "rc=3"
grep -q '所有监控项均已关闭推送' <<< "$out"; eq "全部关闭：说明文字" "$?" "0"
rm -f "$T/curl.args"; : > "$NOTIFY_LOG_FILE"
PATH="$T/stub:$PATH" send_status_report telegram; eq "全部关闭：推送返回 0" "$?" "0"
eq "全部关闭：未调用 curl" "$([ -e "$T/curl.args" ] && echo called || echo none)" "none"
grep -q 'telegram 状态报告未发送：所有监控项均已关闭推送' "$NOTIFY_LOG_FILE"; eq "全部关闭：通知日志记录跳过" "$?" "0"
cp "$T/config-base.json" "$CONFIG_FILE"

# 开机恢复日志措辞：开机缺表记为“开机恢复”；真正的漂移明细用“；”连接，末尾没有多余分隔符。
(
    has_monitors() { return 0; }
    nft_rebuild_all() { return 0; }
    nft_table_exists() { return 0; }
    nft_runtime_drift() { printf '缺少链 ptd_m1_in\n缺少计数器 ptd_m1_out\n'; return 1; }
    runtime_ensure_nft quiet; tail -n1 "$NOTIFY_LOG_FILE"
    nft_table_exists() { return 1; }
    nft_runtime_drift() { echo "nftables 表 port_traffic_monitor 不存在"; return 1; }
    printf '{"schema":2,"saved_at":"2026-11-18T04:59:01Z","monitors":{}}\n' > "$TRAFFIC_DATA_FILE"
    runtime_ensure_nft quiet boot; tail -n1 "$NOTIFY_LOG_FILE"
    rm -f "$TRAFFIC_DATA_FILE"
    runtime_ensure_nft quiet boot; tail -n1 "$NOTIFY_LOG_FILE"
    runtime_ensure_nft quiet; tail -n1 "$NOTIFY_LOG_FILE"
) | sed 's/^\[[^]]*\] //' > "$T/boot.out"
eq "漂移日志：明细连接" "$(sed -n 1p "$T/boot.out")" "nftables 规则漂移，已自动重建：缺少链 ptd_m1_in；缺少计数器 ptd_m1_out"
eq "开机恢复日志（灾备时间为北京时间）" "$(sed -n 2p "$T/boot.out")" "开机恢复：已按配置重建 nftables 规则，计数从灾备恢复（灾备时间 2026-11-18 12:59:01）"
eq "开机恢复日志（无灾备）" "$(sed -n 3p "$T/boot.out")" "开机恢复：已按配置重建 nftables 规则（没有可用灾备，计数从 0 开始）"
eq "非开机缺表仍按漂移记录" "$(sed -n 4p "$T/boot.out")" "nftables 规则漂移，已自动重建：nftables 表 port_traffic_monitor 不存在"

# 界面：宽度按显示列数（中文与全角标点 2 列；方框线、省略号、用量条 1 列）
eq "宽度：ASCII" "$(ui_width 'abc 12')" "6"
eq "宽度：中文与全角标点" "$(ui_width '东京（主线）')" "12"
eq "宽度：符号" "$(ui_width '─…·█░●✓')" "7"
eq "补齐按显示宽度" "$(ui_pad '中a' 6)|" "中a   |"
eq "超宽截断加省略号" "$(ui_truncate '东京主线（8023）' 9)" "东京主线…"
eq "不超宽不截断" "$(ui_truncate '8443' 9)" "8443"
eq "tc 速率显示" "$(format_tc_rate 100mbit)" "100Mbps"
eq "宽度：emoji 与符号（交通、扩展、杂项）" "$(ui_width '🚀🪐⌚✅')" "8"
eq "宽度：组合附加符不占列" "$(ui_width $'e\u0301')" "1"
eq "宽度：拉丁扩展" "$(ui_width 'é')" "1"

# 重建失败时日志不能写“已重建”，并返回非 0。
(
    has_monitors() { return 0; }
    nft_rebuild_all() { return 1; }
    nft_table_exists() { return 1; }
    nft_runtime_drift() { echo "nftables 表 port_traffic_monitor 不存在"; return 1; }
    runtime_ensure_nft quiet boot; echo "rc=$?"; tail -n1 "$NOTIFY_LOG_FILE"
    nft_table_exists() { return 0; }
    runtime_ensure_nft quiet; echo "rc=$?"; tail -n1 "$NOTIFY_LOG_FILE"
) | sed 's/^\[[^]]*\] //' > "$T/rebuild-fail.out"
eq "开机重建失败：返回非 0" "$(sed -n 1p "$T/rebuild-fail.out")" "rc=1"
eq "开机重建失败：日志" "$(sed -n 2p "$T/rebuild-fail.out")" "开机恢复失败：按配置重建 nftables 规则未成功（返回码 1），请运行 dog --repair"
eq "漂移重建失败：返回非 0" "$(sed -n 3p "$T/rebuild-fail.out")" "rc=1"
eq "漂移重建失败：日志" "$(sed -n 4p "$T/rebuild-fail.out")" "nftables 规则漂移，自动重建失败（返回码 1）：nftables 表 port_traffic_monitor 不存在"

# 序号带前导 0 按十进制：08、09 曾按八进制报错并中止整个命令（|| true 也拦不住），010 会选成 m8。
jq '.monitors = ([range(1; 11)] | map({key: "m\(.)", value: {ports: ["\(8000 + .)"], billing_mode: "double",
    quota: {enabled: false, monthly_limit: "unlimited"}, reset_policy: {type: "none"}}}) | from_entries) |
    .global.next_monitor_id = 11' "$T/config-base.json" > "$CONFIG_FILE"
for v in 08 010 9; do
    ( nft_read_values() { echo '{}'; }; echo "pick=$(select_monitor 选择 <<< "$v" 2>/dev/null)" )
done > "$T/zero.out" 2>&1
for v in 08 '09 010'; do
    (
        monitors_set_notify() { echo "set=$(jq -c . <<< "$1")"; }
        notify_scope_summary() { :; }
        menu_notify_monitors <<< "$v" 2>&1 | grep '^set=' || echo "set=<none>"
    )
done >> "$T/zero.out" 2>&1
eq "选择监控项：08 → m8" "$(sed -n 1p "$T/zero.out")" "pick=m8"
eq "选择监控项：010 → m10" "$(sed -n 2p "$T/zero.out")" "pick=m10"
eq "选择监控项：9 → m9" "$(sed -n 3p "$T/zero.out")" "pick=m9"
eq "推送勾选：08 切换 m8" "$(sed -n 4p "$T/zero.out")" 'set={"m8":false}'
eq "推送勾选：09 010 切换 m9、m10" "$(sed -n 5p "$T/zero.out")" 'set={"m9":false,"m10":false}'

# 宽屏表格：超额到 1000% 以上时百分比多一位，状态列仍与表头对齐，行宽不超过终端。
jq '.monitors.m1.quota.monthly_limit = "1GB" | .monitors.m2.notify = false' "$T/config-base.json" > "$CONFIG_FILE"
(
    nft_read_values() { echo '{"m1":{"in":6442450944,"out":0},"m2":{"in":1048576,"out":0}}'; }
    COLUMNS=120 show_monitor_table < /dev/null 2>/dev/null
) > "$T/wide.out"
status_col() { local line; line=$(grep -m1 -- "$1" "$T/wide.out") || { echo none; return; }; ui_width "${line%%"$2"*}"; }
eq "宽屏：带用量条" "$(grep -c '█' "$T/wide.out")" "1"
eq "宽屏：1200% 行的状态列与表头对齐" "$(status_col 'm1 ' 超额)" "$(status_col '端口 / 备注' 状态)"
eq "宽屏：另一行的状态列与表头对齐" "$(status_col 'm2 ' 不推送)" "$(status_col '端口 / 备注' 状态)"
grep -q '1200%' "$T/wide.out"; eq "宽屏：显示 1200%" "$?" "0"
eq "宽屏：行宽不超过 120" "$(while IFS= read -r l; do ui_width "$l"; echo; done < "$T/wide.out" | sort -n | tail -n1 | awk '{print ($1 <= 120) ? "ok" : $1}')" "ok"
cp "$T/config-base.json" "$CONFIG_FILE"

# 导入：备份目录建不起来时，必须在拆除运行状态、删除现有文件之前停止（回滚全靠这份备份）。
jq '.monitors.m1.remark = "imported"' "$T/config-base.json" > "$T/import-config.json"
python3 - "$T/ok.tgz" "$T/import-config.json" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    t.add(sys.argv[2], arcname="port-traffic-dog-config/config.json")
PY
# shellcheck disable=SC2034  # DOG_NONINTERACTIVE 由被测函数读取
(
    DOG_NONINTERACTIVE=true
    teardown_runtime() { echo TEARDOWN; }
    rm -rf "$BACKUP_DIR"; touch "$BACKUP_DIR"   # 让 mkdir -p 失败
    import_config "$T/ok.tgz"; echo "rc=$?"
    rm -f "$BACKUP_DIR"
) > "$T/import-backup.out" 2>&1
grep -q TEARDOWN "$T/import-backup.out"; eq "导入备份失败：未拆除运行状态" "$?" "1"
eq "导入备份失败：返回 1" "$(tail -n1 "$T/import-backup.out")" "rc=1"
cmp -s "$CONFIG_FILE" "$T/config-base.json"; eq "导入备份失败：现有配置未改动" "$?" "0"

echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
