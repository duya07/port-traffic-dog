#!/bin/bash
# Dog 2.0 核心集成测试。
# 在独立网络命名空间（unshare -n）中运行，nftables 规则与宿主完全隔离；
# crontab 用基于文件的桩，tc/systemctl 用空桩，不触碰宿主的定时任务与流量整形。
# 用法：sudo tests/v2/core.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "${PTD_IN_NETNS:-}" != 1 ]; then
    exec unshare -n env PTD_IN_NETNS=1 bash "$0" "$@"
fi
ip link set lo up

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/bin"
export PORT_TRAFFIC_DOG_CONFIG_DIR="$T/etc"
export PORT_TRAFFIC_DOG_LOCK_FILE="$T/dog.lock"
export PORT_TRAFFIC_DOG_SHORTCUT_PATH="$T/bin/dog"
# 安装路径同样指向临时目录：否则自检/定时任务会优先使用宿主 /usr/local/bin 里已装的版本（测试不封闭）。
export PORT_TRAFFIC_DOG_INSTALL_PATH="$T/bin/port-traffic-dog.sh"
export TRAFFIC_TOOLS_TC_LOCK_FILE="$T/tc.lock"
export TRAFFICCOP_TC_STATE_FILE="$T/ntc.state"
export TRAFFICCOP_CONFIG_FILE="$T/ntc.conf"
export TRAFFIC_TOOLS_TC_RECOVERY_RUNNER="$T/runner.sh"
export TRAFFIC_TOOLS_TC_RECOVERY_UNIT_FILE="$T/runner.service"
export NO_COLOR=1

cat > "$T/stub/crontab" <<EOF
#!/bin/bash
f="$T/crontab"
case "\${1:-}" in
    -l) [ -f "\$f" ] && cat "\$f" || { echo "no crontab for root" >&2; exit 1; } ;;
    -) cat > "\$f" ;;
    *) cp "\$1" "\$f" ;;
esac
EOF
printf '#!/bin/sh\ncase "$*" in *-j*) echo "[]" ;; esac\nexit 0\n' > "$T/stub/tc"
for c in systemctl service rc-service rc-update cron crond modprobe; do printf '#!/bin/sh\nexit 1\n' > "$T/stub/$c"; done
chmod +x "$T/stub/"*
export PATH="$T/stub:$PATH"
printf 'PATH=/usr/local/bin:/usr/bin:/bin\n0 3 * * * /root/backup.sh\n' > "$T/crontab"

DOG=(bash "$ROOT/port-traffic-dog.sh")
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $*"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
nft_bytes() { nft -j list counter inet port_traffic_monitor "$1" 2>/dev/null | jq -r '.nftables[] | .counter? // empty | .bytes'; }
quota_json() { nft -j list quota inet port_traffic_monitor "$1" 2>/dev/null | jq -c '.nftables[] | .quota? // empty | {bytes, used}'; }
cfg() { jq -r "$1" "$PORT_TRAFFIC_DOG_CONFIG_DIR/config.json"; }

# 在回环上向端口发送 UDP：$1=端口 $2=负载字节 $3=次数；接收端原样回一个 100 字节的包。
send_udp() {
    python3 - "$@" <<'PY'
import socket, sys
port, size, count = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); r.bind(("127.0.0.1", port)); r.settimeout(1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1)
for _ in range(count):
    s.sendto(b"x" * size, ("127.0.0.1", port))
    try:
        data, addr = r.recvfrom(65535); r.sendto(b"y" * 100, addr); s.recvfrom(65535)
    except socket.timeout:
        pass
PY
}

echo "# 添加与重叠校验"
check "添加 m1（8031,8032）" "${DOG[@]}" add "8031,8032" --remark web1
check "一次添加两项（3001-3009;8080）" "${DOG[@]}" add "3001-3009;8080"
[ "$(cfg '.monitors | keys | join(",")')" = "m1,m2,m3" ] && ok "ID 为 m1,m2,m3" || bad "ID 分配：$(cfg '.monitors | keys')"
if "${DOG[@]}" add 8032 >/dev/null 2>&1; then bad "重叠端口应被拒绝"; else ok "重叠端口被拒绝"; fi
if "${DOG[@]}" add "3005" >/dev/null 2>&1; then bad "落入端口段的端口应被拒绝"; else ok "落入端口段的端口被拒绝"; fi
[ "$(nft list chain inet port_traffic_monitor input | grep -c vmap)" -eq 1 ] && ok "input 链只有 1 条 vmap 规则" || bad "input 规则数"

echo "# 计数与加减端口"
send_udp 8031 972 3
in1=$(nft_bytes ptd_m1_in); out1=$(nft_bytes ptd_m1_out)
[ "$in1" -eq 3000 ] && ok "m1 入站 3000 字节" || bad "m1 入站=$in1（期望 3000）"
[ "$out1" -eq 384 ] && ok "m1 出站 384 字节" || bad "m1 出站=$out1（期望 384）"
check "给 m1 加端口 8033" "${DOG[@]}" edit m1 --add 8033
[ "$(nft_bytes ptd_m1_in)" -eq "$in1" ] && ok "加端口后计数不变" || bad "加端口后计数变化"
send_udp 8033 972 1
[ "$(nft_bytes ptd_m1_in)" -eq $((in1 + 1000)) ] && ok "新端口流量计入 m1" || bad "新端口流量未计入"
check "按端口引用删除成员（8031 → 删 8032）" "${DOG[@]}" edit 8031 --del 8032
[ "$(cfg '.monitors.m1.ports | join(",")')" = "8031,8033" ] && ok "m1 成员为 8031,8033" || bad "成员=$(cfg '.monitors.m1.ports')"
send_udp 8032 972 1
[ "$(nft_bytes ptd_m1_in)" -eq $((in1 + 1000)) ] && ok "删除的端口不再计入" || bad "删除后仍计数"
if "${DOG[@]}" edit m1 --del 8031,8033 >/dev/null 2>&1; then bad "删光端口应被拒绝"; else ok "删光端口被拒绝"; fi
if "${DOG[@]}" edit m1 --add 8080 >/dev/null 2>&1; then bad "加入他项端口应被拒绝"; else ok "加入他项端口被拒绝"; fi
check "整组替换为 8031,8033-8035" "${DOG[@]}" edit m1 --set 8031,8033-8035
[ "$(nft_bytes ptd_m1_in)" -eq $((in1 + 1000)) ] && ok "整组替换后计数不变" || bad "替换后计数变化"

echo "# 配额"
check "设置配额 1MB（双向计费）" "${DOG[@]}" edit m1 --quota 1MB
q=$(quota_json ptd_m1_quota)
[ "$(jq '.bytes' <<< "$q")" -eq 524288 ] && ok "配额阈值 = 1MB ÷ 2" || bad "配额阈值：$q"
check "切换为单向计费" "${DOG[@]}" edit m1 --billing single
[ "$(jq '.bytes' <<< "$(quota_json ptd_m1_quota)")" -eq 1048576 ] && ok "单向计费阈值 = 1MB" || bad "单向阈值"
[ "$(nft_bytes ptd_m1_in)" -eq $((in1 + 1000)) ] && ok "切换计费不改写计数" || bad "切换计费改写了计数"
send_udp 8031 60000 25
used=$(jq '.used' <<< "$(quota_json ptd_m1_quota)")
[ "$used" -ge 1048576 ] && ok "超额后配额 used 达到阈值（内核导出时封顶）" || bad "配额 used=$used"
before=$(nft_bytes ptd_m1_in); send_udp 8031 972 2
[ "$(nft_bytes ptd_m1_in)" -eq "$before" ] && ok "超额后流量被丢弃且不计数" || bad "超额后仍计数"
check "取消配额" "${DOG[@]}" edit m1 --quota 0
[ -z "$(quota_json ptd_m1_quota)" ] && ok "配额对象已删除" || bad "配额对象仍在"

echo "# 拆分与合并"
m1_before=$(nft_bytes ptd_m1_in)
check "拆出 8033-8035 为新项" "${DOG[@]}" split m1 8033-8035 --remark split
[ "$(cfg '.monitors.m4.ports | join(",")')" = "8033-8035" ] && ok "新项 m4 = 8033-8035" || bad "拆分结果 $(cfg '.monitors | keys')"
[ "$(nft_bytes ptd_m4_in)" -eq 0 ] && ok "新项从 0 开始" || bad "新项计数非 0"
[ "$(nft_bytes ptd_m1_in)" -eq "$m1_before" ] && ok "原项计数保留" || bad "原项计数变化"
send_udp 8034 972 2
check "合并 m4 → m1" "${DOG[@]}" merge m4 m1
[ "$(nft_bytes ptd_m1_in)" -eq $((m1_before + 2000)) ] && ok "合并后计数相加" || bad "合并后=$(nft_bytes ptd_m1_in)"
[ "$(cfg '.monitors | has("m4")')" = "false" ] && ok "源项已删除" || bad "源项仍在"
[ "$(cfg '.monitors.m1.ports | join(",")')" = "8031,8033-8035" ] && ok "端口已并入" || bad "合并端口 $(cfg '.monitors.m1.ports')"

echo "# 到期封锁"
check "设置已过期日期" "${DOG[@]}" edit m1 --expiry 2020-01-01
grep -q ptd_expired <<< "$(nft list chain inet port_traffic_monitor ptd_m1_in 2>/dev/null)" && ok "链首有到期 drop" || bad "缺到期规则"
before=$(nft_bytes ptd_m1_in); send_udp 8031 972 2
[ "$(nft_bytes ptd_m1_in)" -eq "$before" ] && ok "到期后流量被封锁" || bad "到期后仍有流量"
check "取消到期" "${DOG[@]}" edit m1 --expiry 0
grep -q ptd_expired <<< "$(nft list chain inet port_traffic_monitor ptd_m1_in 2>/dev/null)" && bad "到期规则未解除" || ok "到期规则已解除"

echo "# tick、灾备与重启恢复"
check "tick 运行" "${DOG[@]}" --tick
[ -s "$PORT_TRAFFIC_DOG_CONFIG_DIR/traffic_data.json" ] && ok "灾备文件已写" || bad "无灾备"
[ "$(jq '.monitors.m1.last.in' "$PORT_TRAFFIC_DOG_CONFIG_DIR/traffic_stats.json")" -eq "$(nft_bytes ptd_m1_in)" ] && ok "统计基线 = 当前计数" || bad "统计基线"
saved=$(nft_bytes ptd_m1_in)
nft delete table inet port_traffic_monitor
check "开机恢复（--boot）" "${DOG[@]}" --boot
[ "$(nft_bytes ptd_m1_in)" -eq "$saved" ] && ok "重启后计数从灾备恢复" || bad "恢复后=$(nft_bytes ptd_m1_in)，期望 $saved"
nft flush chain inet port_traffic_monitor ptd_m2_in
check "tick 自动修复被清空的链" "${DOG[@]}" --tick
[ "$(nft list chain inet port_traffic_monitor ptd_m2_in | grep -c counter)" -eq 1 ] && ok "漂移已修复" || bad "漂移未修复"

echo "# 定时任务"
grep -q -- '--tick' "$T/crontab" && grep -q -- '--boot' "$T/crontab" && ok "生成 tick/boot 任务" || bad "cron 缺任务"
grep -q '^PATH=/usr/local/bin:/usr/bin:/bin$' "$T/crontab" && grep -q '/root/backup.sh' "$T/crontab" && ok "PATH 行与无关任务保留" || bad "破坏了无关 cron"
[ "$(grep -c port-traffic-dog "$T/crontab")" -eq 2 ] && ok "无重复 Dog 任务" || bad "Dog 任务数 $(grep -c port-traffic-dog "$T/crontab")"

echo "# 状态报告"
report=$("${DOG[@]}" status)
grep -q '周期总流量' <<< "$report" && grep -q 'm1' <<< "$report" && ok "报告包含总量与监控项" || bad "报告内容"
# cron 最小环境：PATH 只有 /usr/bin:/bin（nft 在 /usr/sbin）、没有任何 locale 变量；只保留测试隔离用的路径变量。
mapfile -t keep_env < <(env | grep -E '^(PORT_TRAFFIC_DOG|TRAFFIC_TOOLS|TRAFFICCOP)_')
cron_report=$(env -i HOME=/root PATH=/usr/bin:/bin "${keep_env[@]}" bash "$ROOT/port-traffic-dog.sh" status 2>&1)
if grep -q '周期总流量' <<< "$cron_report" && grep -q 'm1' <<< "$cron_report" &&
   [ "$(grep -c . <<< "$cron_report")" -eq "$(grep -c . <<< "$report")" ]; then
    ok "cron 最小环境（无 PATH 系统目录、无 locale）下报告完整"
else
    bad "cron 最小环境报告：$cron_report"
fi

echo "# 按监控项开关推送（2.1）"
send_udp 8080 972 3   # 让 m3 有流量，才能验证总量不含它
check "关闭 m3 推送（edit --notify off）" "${DOG[@]}" edit m3 --notify off
[ "$(cfg '.monitors.m3.notify')" = "false" ] && ok "配置写入 notify=false" || bad "notify=$(cfg '.monitors.m3.notify')"
grep -q '设置监控项推送开关：成功 id=m3 mode=off' "$PORT_TRAFFIC_DOG_CONFIG_DIR/logs/traffic.log" && ok "审计日志记录推送开关" || bad "审计日志缺推送开关记录"
if "${DOG[@]}" edit m3 --notify maybe >/dev/null 2>&1; then bad "非法开关值应被拒绝"; else ok "非法开关值被拒绝"; fi
[ "$(cfg '.monitors.m3.notify')" = "false" ] && ok "非法值不改配置" || bad "非法值改了配置"
mult() { [ "$(cfg ".monitors.$1.billing_mode")" = single ] && echo 1 || echo 2; }
billed() { echo $(( ($(nft_bytes "ptd_$1_in") + $(nft_bytes "ptd_$1_out")) * $(mult "$1") )); }
fmt_bytes() { bash -c 'source <(sed "\$d" "$1"); format_bytes "$2"' _ "$ROOT/port-traffic-dog.sh" "$1"; }
[ "$(billed m3)" -gt 0 ] && ok "m3 有计费流量 $(billed m3)" || bad "m3 无流量，下一条没有区分力"
want_total=$(fmt_bytes $(( $(billed m1) + $(billed m2) )))
report=$("${DOG[@]}" status)
if grep -q "监控项: 2个 | 周期总流量: $want_total" <<< "$report" && grep -q '\[m1\]' <<< "$report" && ! grep -q '\[m3\]' <<< "$report"; then
    ok "status 不含 m3，头部数量与总量只算 m1、m2（$want_total）"
else
    bad "status：$(head -n 4 <<< "$report")（期望总量 $want_total）"
fi
lj=$("${DOG[@]}" list --json)
[ "$(jq -r '.[] | select(.id == "m3") | .notify' <<< "$lj")" = false ] && [ "$(jq -r '.[] | select(.id == "m1") | .notify' <<< "$lj")" = true ] &&
    ok "list --json 输出实际生效的 notify" || bad "list --json：$(jq -c 'map({id, notify})' <<< "$lj")"
list_out=$("${DOG[@]}" list)
grep -q '不推送' <<< "$list_out" && ok "dog list 状态列显示 不推送" || bad "dog list 未显示不推送"
for d in in out; do nft flush chain inet port_traffic_monitor "ptd_m3_$d"; nft delete counter inet port_traffic_monitor "ptd_m3_$d"; done
rc=0; "${DOG[@]}" status >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "关闭推送的 m3 缺计数器时不告警" || bad "m3 缺计数器时 status rc=$rc"
check "重新开启 m3 推送" "${DOG[@]}" edit m3 --notify on
rc=0; out=$("${DOG[@]}" status 2>&1) || rc=$?
[ "$rc" -eq 2 ] && grep -q '监控项 m3 的计数器缺失' <<< "$out" && ok "开启推送后 m3 缺计数器即告警（rc=2）" || bad "开启后 status rc=$rc：$out"
check "tick 修复缺失的计数器" "${DOG[@]}" --tick
[ -n "$(nft_bytes ptd_m3_in)" ] && ok "m3 计数器已重建" || bad "m3 计数器未重建"
cp "$PORT_TRAFFIC_DOG_CONFIG_DIR/config.json" "$T/config-before-notify.json"
jq '.notifications.telegram += {enabled: true, bot_token: "123:T", chat_id: "1", status_notifications: {enabled: true, interval: "12h"}}' \
    "$T/config-before-notify.json" > "$PORT_TRAFFIC_DOG_CONFIG_DIR/config.json"
mkdir -p "$T/tgstub"
cat > "$T/tgstub/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$T/tg.args"
cat > /dev/null
echo '{"ok":true}'
EOF
chmod +x "$T/tgstub/curl"
for id in m1 m2 m3; do "${DOG[@]}" edit "$id" --notify off >/dev/null 2>&1 || bad "关闭 $id 推送失败"; done
rc=0; env PATH="$T/tgstub:$PATH" "${DOG[@]}" --send-status telegram >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$T/tg.args" ] &&
   grep -q 'telegram 状态报告未发送：所有监控项均已关闭推送' "$PORT_TRAFFIC_DOG_CONFIG_DIR/logs/notification.log"; then
    ok "全部关闭推送：--send-status 返回 0、未调用 curl、通知日志记录跳过"
else
    bad "全部关闭推送：rc=$rc，curl $( [ -e "$T/tg.args" ] && echo 被调用 || echo 未调用)"
fi
rc=0; out=$("${DOG[@]}" status 2>&1) || rc=$?
[ "$rc" -eq 0 ] && grep -q '所有监控项均已关闭推送' <<< "$out" && ok "全部关闭时 status 打印说明并返回 0" || bad "全部关闭 status rc=$rc：$out"
sc_out=$("${DOG[@]}" --self-check 2>&1)   # 先取完整输出再匹配：pipefail 下自检的非 0 返回码会让 `| grep -q` 判失败
grep -q '所有监控项均已关闭推送' <<< "$sc_out" && ok "自检提示定时报告不会发送" || bad "自检未提示全部关闭"
check "重新开启 m1 推送" "${DOG[@]}" edit m1 --notify on
rc=0; env PATH="$T/tgstub:$PATH" "${DOG[@]}" --send-status telegram >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && grep -q '\[m1\]' "$T/tg.args" 2>/dev/null && ! grep -q '\[m2\]' "$T/tg.args" && ! grep -q '\[m3\]' "$T/tg.args" &&
    ok "推送只包含开启的监控项" || bad "推送内容 rc=$rc：$(grep -o '\[m[0-9]*\]' "$T/tg.args" 2>/dev/null | paste -sd,)"
check "关闭 m1 推送（准备拆分）" "${DOG[@]}" edit m1 --notify off
sid=$("${DOG[@]}" split m1 8033-8035 2>/dev/null | tail -n1)
[ -n "$sid" ] && [ "$(cfg ".monitors.$sid.notify")" = "false" ] && ok "拆出的新项 $sid 继承 notify=false" || bad "拆分后 $sid notify=$(cfg ".monitors.${sid:-x}.notify")"
check "合并回 m1" "${DOG[@]}" merge "$sid" m1
for id in m1 m2 m3; do "${DOG[@]}" edit "$id" --notify on >/dev/null 2>&1 || bad "开启 $id 推送失败"; done
jq '.notifications = $n' --argjson n "$(jq '.notifications' "$T/config-before-notify.json")" \
    "$PORT_TRAFFIC_DOG_CONFIG_DIR/config.json" > "$T/cfg.tmp" && cat "$T/cfg.tmp" > "$PORT_TRAFFIC_DOG_CONFIG_DIR/config.json"
[ "$(cfg '[.monitors[] | .notify] | all')" = true ] && [ "$(cfg '.notifications.telegram.enabled')" = false ] && ok "推送设置已复原" || bad "复原失败"
nft delete table inet port_traffic_monitor
rc=0; report=$("${DOG[@]}" status) || rc=$?
[ "$rc" -eq 2 ] && grep -q '流量读取失败' <<< "$report" && ok "规则缺失时报告为告警（rc=2）而非空内容" || bad "缺表报告 rc=$rc"
"${DOG[@]}" --boot >/dev/null 2>&1

echo "# 重置与删除"
check "立即重置 m1" "${DOG[@]}" reset m1 --yes
[ "$(nft_bytes ptd_m1_in)" -eq 0 ] && ok "重置后计数为 0" || bad "重置后=$(nft_bytes ptd_m1_in)"
check "删除 m2" "${DOG[@]}" remove m2 --yes
nft list chain inet port_traffic_monitor ptd_m2_in >/dev/null 2>&1 && bad "m2 链残留" || ok "m2 规则已清除"
sc_out=$("${DOG[@]}" --self-check 2>&1); sc_rc=$?
sc_errs=$(grep '✗' <<< "$sc_out")
if [ "$sc_rc" -eq 0 ]; then
    ok "自检通过"
elif ! pgrep -x cron >/dev/null 2>&1 && ! pgrep -x crond >/dev/null 2>&1 &&
     [ "$sc_errs" = "$(grep '✗ cron 服务未运行' <<< "$sc_out")" ]; then
    ok "自检通过（本环境看不到 cron 进程，仅此一项按预期报错）"
else
    bad "自检：$sc_errs"
fi

echo "# 1.5.x 迁移"
nft delete table inet port_traffic_monitor
rm -rf "$PORT_TRAFFIC_DOG_CONFIG_DIR"; mkdir -p "$PORT_TRAFFIC_DOG_CONFIG_DIR"
cat > "$PORT_TRAFFIC_DOG_CONFIG_DIR/config.json" <<'JSON'
{"global":{"billing_mode":"double"},
 "ports":{"8031,8032":{"name":"端口8031,8032","enabled":true,"billing_mode":"double",
    "bandwidth_limit":{"enabled":false,"rate":"unlimited"},
    "quota":{"enabled":true,"monthly_limit":"240GB","reset_day":1,
             "reset_policy":{"type":"monthly","day":1,"instance_id":"x-1","next_reset_date":"2099-12-01"}},
    "expiry_date":"2099-02-15","remark":"demo-node@example","created_at":"2026-11-14T17:58:24+08:00"},
  "443":{"name":"端口443","billing_mode":"single","quota":{"enabled":false,"monthly_limit":"unlimited"},
    "bandwidth_limit":{"enabled":false,"rate":"unlimited"},"remark":""}},
 "nftables":{"table_name":"port_traffic_monitor","family":"inet"},
 "notifications":{"telegram":{"enabled":true,"bot_token":"t","chat_id":"c","server_name":"demo-node",
    "api_route":"custom","custom_api_base":"https://tg.example.com","status_notifications":{"enabled":true,"interval":"12h"}},
  "email":{"enabled":false},"wecom":{"enabled":false,"webhook_url":"","status_notifications":{"enabled":false,"interval":"1h"}}}}
JSON
nft -f - <<'NFT'
table inet port_traffic_monitor {
    counter port_g8031_8032_in { packets 10 bytes 2863350496 }
    counter port_g8031_8032_out { packets 10 bytes 492600652 }
    quota port_g8031_8032_quota { over 245760 mbytes used 3355951148 bytes }
    counter port_443_in { packets 1 bytes 1000 }
    counter port_443_out { packets 1 bytes 500 }
    chain input { type filter hook input priority filter; policy accept;
        tcp dport 8031 counter name "port_g8031_8032_in"
        tcp dport 8031 counter name "port_g8031_8032_in"
    }
}
NFT
printf '0 */12 * * * /usr/local/bin/port-traffic-dog.sh --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知\n* * * * * /usr/local/bin/port-traffic-dog.sh --snapshot-traffic >/dev/null 2>&1  # port-traffic-dog traffic snapshot\n0 3 * * * /root/backup.sh\n' > "$T/crontab"
# 1.5.23 的 --update：先用新脚本 --validate-config 校验旧配置，装好后再调 --finalize-update。
check "旧配置可通过 --validate-config（按迁移结果校验）" "${DOG[@]}" --validate-config "$PORT_TRAFFIC_DOG_CONFIG_DIR/config.json"
jq '.ports["99999"] = {}' "$PORT_TRAFFIC_DOG_CONFIG_DIR/config.json" > "$T/bad-legacy.json"
"${DOG[@]}" --validate-config "$T/bad-legacy.json" >/dev/null 2>&1 && bad "非法旧配置未被拒绝" || ok "非法旧配置被拒绝"
printf '{"ports":{"abc":{}}}' > "$T/bad-legacy2.json"
"${DOG[@]}" --validate-config "$T/bad-legacy2.json" >/dev/null 2>&1 && bad "无法转换的旧配置未被拒绝" || ok "无法转换的旧配置被拒绝"
[ "$(cfg '.ports | keys | length')" = "2" ] && ok "--validate-config 不改动旧配置" || bad "validate 改动了配置"
check "迁移（1.5.x 更新器调用 --finalize-update）" "${DOG[@]}" --finalize-update
check "迁移后 list 正常" "${DOG[@]}" list
[ "$(cfg '.schema')" = "2" ] && ok "schema=2" || bad "schema=$(cfg '.schema')"
[ "$(cfg '.monitors.m1.ports | join(",")')" = "443" ] && [ "$(cfg '.monitors.m2.ports | join(",")')" = "8031,8032" ] && ok "按端口排序分配 ID" || bad "ID 映射 $(cfg '.monitors')"
[ "$(nft_bytes ptd_m2_in)" -eq 1431675248 ] && ok "双向计数 ÷2 迁移（2863350496 → 1431675248）" || bad "m2 in=$(nft_bytes ptd_m2_in)"
[ "$(nft_bytes ptd_m1_out)" -eq 500 ] && ok "单向计数原样迁移" || bad "m1 out=$(nft_bytes ptd_m1_out)"
[ "$(jq '.used' <<< "$(quota_json ptd_m2_quota)")" -eq 1677975574 ] && ok "已用配额 ÷2 迁移" || bad "quota $(quota_json ptd_m2_quota)"
[ "$(cfg '.monitors.m2.remark')" = "demo-node@example" ] && [ "$(cfg '.monitors.m2.reset_policy.next_reset_date')" = "2099-12-01" ] &&
    [ "$(cfg '.monitors.m2.expiry_date')" = "2099-02-15" ] && ok "备注/重置/到期保留" || bad "字段迁移"
[ "$(cfg '.notifications.telegram.custom_api_base')" = "https://tg.example.com" ] && ok "通知配置保留" || bad "通知配置"
grep -q 'send-status telegram' "$T/crontab" && ! grep -q 'snapshot-traffic' "$T/crontab" && grep -q backup.sh "$T/crontab" && ok "旧 cron 替换为新任务" || bad "cron 迁移：$(cat "$T/crontab")"
ls "$PORT_TRAFFIC_DOG_CONFIG_DIR"/backups/migrate-1.5-*/config.json >/dev/null 2>&1 && ok "迁移备份存在" || bad "无迁移备份"
grep -q 'port_g8031' <<< "$(nft list table inet port_traffic_monitor 2>/dev/null)" && bad "旧对象残留" || ok "旧对象已清除"

echo "# 更新（Release + SHA256SUMS，curl 桩按文件名供给）"
export PORT_TRAFFIC_DOG_INSTALL_PATH="$T/bin/port-traffic-dog.sh" PORT_TRAFFIC_DOG_MIRROR="https://mirror.invalid"
REL="$T/release"; mkdir -p "$REL" "$T/curlstub"
cat > "$T/curlstub/curl" <<EOF
#!/bin/bash
out=""; url=""
while [ "\$#" -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; http*) url="\$1"; shift ;; *) shift ;; esac; done
f="$REL/\${url##*/}"; [ -n "\$out" ] && [ -f "\$f" ] || exit 22
cp "\$f" "\$out"
EOF
chmod +x "$T/curlstub/curl"
UPD=(env PATH="$T/curlstub:$PATH" bash "$PORT_TRAFFIC_DOG_INSTALL_PATH")
check "安装到测试路径" "${DOG[@]}" --install
make_release() {   # $1=版本 [$2=sed 额外改动]
    sed -e "s/^readonly SCRIPT_VERSION=\".*\"/readonly SCRIPT_VERSION=\"$1\"/" ${2:+-e "$2"} "$ROOT/port-traffic-dog.sh" > "$REL/port-traffic-dog.sh"
    cp "$ROOT/port-ip-guard.sh" "$REL/"
    (cd "$REL" && sha256sum port-traffic-dog.sh port-ip-guard.sh > SHA256SUMS)
}
inst_ver() { awk -F'"' '/^readonly SCRIPT_VERSION=/ { print $2; exit }' "$PORT_TRAFFIC_DOG_INSTALL_PATH"; }
CUR_VER=$(awk -F'"' '/^readonly SCRIPT_VERSION=/ { print $2; exit }' "$ROOT/port-traffic-dog.sh")
NEXT_VER="${CUR_VER%.*}.$(( ${CUR_VER##*.} + 1 ))"
make_release "$NEXT_VER"; echo "# tampered" >> "$REL/port-traffic-dog.sh"
"${UPD[@]}" --update >/dev/null 2>&1 && bad "校验失败仍安装" || ok "SHA256 不符时拒绝更新"
[ "$(inst_ver)" = "$(awk -F'"' '/^readonly SCRIPT_VERSION=/ { print $2; exit }' "$ROOT/port-traffic-dog.sh")" ] && ok "拒绝后版本不变" || bad "版本=$(inst_ver)"
make_release "$NEXT_VER" 's/^        --post-update|--finalize-update) post_update ;;$/        --post-update|--finalize-update) return 9 ;;/'
cfg_before=$(sha256sum < "$PORT_TRAFFIC_DOG_CONFIG_DIR/config.json")
"${UPD[@]}" --update > "$T/upd-bad.out" 2>&1 && bad "维护失败仍返回成功" || ok "新版维护失败时返回非 0"
grep -q '正在恢复更新前的文件' "$T/upd-bad.out" && ok "失败发生在新版维护阶段（走到了回滚）" || { bad "未走到回滚"; tail -5 "$T/upd-bad.out"; }
[ "$(inst_ver)" != "$NEXT_VER" ] && [ "$(sha256sum < "$PORT_TRAFFIC_DOG_CONFIG_DIR/config.json")" = "$cfg_before" ] && ok "已回滚到更新前文件" || bad "回滚失败：$(inst_ver)"
make_release 1.9.9
"${UPD[@]}" --update >/dev/null 2>&1 && bad "允许了降级" || ok "拒绝降级"
make_release "$NEXT_VER"
"${UPD[@]}" --update > "$T/upd.out" 2>&1 && ok "正常更新" || { bad "正常更新"; tail -15 "$T/upd.out"; }
[ "$(inst_ver)" = "$NEXT_VER" ] && ok "已更新到 $NEXT_VER" || bad "版本=$(inst_ver)"
ls -d "$PORT_TRAFFIC_DOG_CONFIG_DIR"/backups/update-* >/dev/null 2>&1 && ok "更新前备份存在" || bad "无更新备份"
grep -q "$PORT_TRAFFIC_DOG_INSTALL_PATH --tick" "$T/crontab" && ok "定时任务指向已安装脚本" || bad "cron：$(cat "$T/crontab")"
unset PORT_TRAFFIC_DOG_INSTALL_PATH PORT_TRAFFIC_DOG_MIRROR

echo
echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
