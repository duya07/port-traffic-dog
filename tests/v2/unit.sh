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

echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
