#!/bin/bash
# 1.5.23 → 2.0 原地升级测试：直接运行 1.5.23 自带的更新器（--install-local，与 --update 同一实现），
# 把当前构建的 2.0 作为本地安装包交给它，验证成功路径与“新版维护失败 → 旧版回滚”路径。
#
# 隔离方式：unshare -m -n 私有挂载 + 独立网络命名空间；/etc、/usr/local、/var/lib 用 overlay
# 覆盖（写入只落在临时目录），/run/lock 挂 tmpfs；crontab 用基于文件的桩，tc/systemctl/apt 用桩。
# 宿主的文件、定时任务、nftables 与软件包均不受影响。
# 用法：sudo tests/v2/upgrade-1.5.sh
#   LEGACY_SCRIPT=路径        指定旧版脚本（默认取 git 提交 1.5.23）
#   PTD_TEST_DEPS_ROOT=目录   宿主缺 bc/conntrack/libnetfilter-queue1 时使用的解包目录
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly LEGACY_COMMIT="8371863ef724e88e0b8187b8c44fff2fb70b1e18"   # Dog 1.5.23

if [ "${PTD_UPGRADE_NS:-}" != 1 ]; then
    [ "$(id -u)" -eq 0 ] || { echo "需要 root" >&2; exit 1; }
    exec unshare -m -n --propagation private env PTD_UPGRADE_NS=1 bash "$0" "$@"
fi
ip link set lo up

T=$(mktemp -d)
cleanup() {
    local m
    for m in /etc /usr/local /var/lib /run/lock; do umount -l "$m" 2>/dev/null || true; done
    rm -rf "$T"
}
trap cleanup EXIT

for m in etc usr-local var-lib; do mkdir -p "$T/ov/$m/up" "$T/ov/$m/work"; done
mount -t overlay overlay -o "lowerdir=/etc,upperdir=$T/ov/etc/up,workdir=$T/ov/etc/work" /etc
mount -t overlay overlay -o "lowerdir=/usr/local,upperdir=$T/ov/usr-local/up,workdir=$T/ov/usr-local/work" /usr/local
mount -t overlay overlay -o "lowerdir=/var/lib,upperdir=$T/ov/var-lib/up,workdir=$T/ov/var-lib/work" /var/lib
mount -t tmpfs tmpfs /run/lock

LEGACY="$T/legacy.sh"
if [ -n "${LEGACY_SCRIPT:-}" ]; then
    cp "$LEGACY_SCRIPT" "$LEGACY"
else
    git -c safe.directory="$ROOT" -C "$ROOT" show "$LEGACY_COMMIT:port-traffic-dog.sh" > "$LEGACY" || {
        echo "无法取得 1.5.23 脚本；请设置 LEGACY_SCRIPT" >&2; exit 1; }
fi
grep -q 'readonly SCRIPT_VERSION="1.5' "$LEGACY" || { echo "LEGACY_SCRIPT 不是 1.5.x" >&2; exit 1; }

mkdir -p "$T/stub"
cat > "$T/stub/crontab" <<EOF
#!/bin/bash
f="$T/crontab"
case "\${1:-}" in
    -l) [ -f "\$f" ] && cat "\$f" || { echo "no crontab for root" >&2; exit 1; } ;;
    -r) rm -f "\$f" ;;
    -) cat > "\$f" ;;
    *) cp "\$1" "\$f" ;;
esac
EOF
printf '#!/bin/sh\ncase "$*" in *-j*) echo "[]" ;; esac\nexit 0\n' > "$T/stub/tc"
# 软件包管理一律失败：测试绝不能改动宿主 dpkg 状态。
for c in systemctl service rc-service rc-update cron crond modprobe apt-get apt dpkg; do
    printf '#!/bin/sh\nexit 1\n' > "$T/stub/$c"
done
chmod +x "$T/stub/"*
export PATH="$T/stub:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# 1.5.23 安装前会检查 bc/conntrack/libnetfilter-queue1；宿主缺少时，可用 PTD_TEST_DEPS_ROOT 指向
# 用 dpkg-deb -x 解出的目录（只取文件，不安装软件包）。
if [ -n "${PTD_TEST_DEPS_ROOT:-}" ]; then
    PATH="$T/stub:$PTD_TEST_DEPS_ROOT/usr/bin:$PTD_TEST_DEPS_ROOT/usr/sbin:${PATH#"$T/stub:"}"
    export LD_LIBRARY_PATH="$PTD_TEST_DEPS_ROOT/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
export NO_COLOR=1 TERM=dumb
export TRAFFICCOP_TC_STATE_FILE="$T/ntc.state" TRAFFICCOP_CONFIG_FILE="$T/ntc.conf"
export TRAFFIC_TOOLS_TC_RECOVERY_RUNNER="$T/runner.sh" TRAFFIC_TOOLS_TC_RECOVERY_UNIT_FILE="$T/runner.service"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $*"; }
nft_bytes() { nft -j list counter inet port_traffic_monitor "$1" 2>/dev/null | jq -r '.nftables[] | .counter? // empty | .bytes'; }
cfg() { jq -r "$1" /etc/port-traffic-dog/config.json; }
installed_version() { awk -F'"' '/^readonly SCRIPT_VERSION=/ { print $2; exit }' /usr/local/bin/port-traffic-dog.sh; }

# 本地安装包：1.5.x 更新器要求四个文件齐全。
make_bundle() {
    local dir="$1"
    mkdir -p "$dir"
    cp "$ROOT/port-traffic-dog.sh" "$ROOT/port-ip-guard.sh" "$ROOT/telegram.sh" "$ROOT/wecom.sh" "$dir/"
}

# 1.5.23 安装状态：脚本、配置、旧格式计数器与旧定时任务。
setup_legacy() {
    nft delete table inet port_traffic_monitor 2>/dev/null || true
    rm -rf /etc/port-traffic-dog /usr/local/bin/port-traffic-dog.sh /usr/local/bin/dog
    install -m 755 "$LEGACY" /usr/local/bin/port-traffic-dog.sh
    mkdir -p /etc/port-traffic-dog/notifications
    cp "$ROOT/telegram.sh" "$ROOT/wecom.sh" /etc/port-traffic-dog/notifications/
    cat > /etc/port-traffic-dog/config.json <<'JSON'
{"global":{"billing_mode":"double"},
 "ports":{"8031,8032":{"name":"端口8031,8032","enabled":true,"billing_mode":"double",
    "bandwidth_limit":{"enabled":false,"rate":"unlimited"},
    "quota":{"enabled":true,"monthly_limit":"240GB","reset_day":1,
             "reset_policy":{"type":"monthly","day":1,"instance_id":"x-1","next_reset_date":"2099-12-01"}},
    "expiry_date":"2099-02-15","remark":"demo-node@example","created_at":"2026-11-14T17:58:24+08:00"},
  "443":{"name":"端口443","enabled":true,"billing_mode":"single","quota":{"enabled":false,"monthly_limit":"unlimited"},
    "bandwidth_limit":{"enabled":false,"rate":"unlimited"},"remark":""}},
 "nftables":{"table_name":"port_traffic_monitor","family":"inet"},
 "notifications":{"telegram":{"enabled":false,"bot_token":"","chat_id":"","server_name":"t",
    "status_notifications":{"enabled":false,"interval":"12h"}},
  "wecom":{"enabled":false,"webhook_url":"","status_notifications":{"enabled":false,"interval":"1h"}}}}
JSON
    chmod 600 /etc/port-traffic-dog/config.json
    # 由 1.5.23 自己建表，计数器名与规则都是真实旧格式。
    bash /usr/local/bin/port-traffic-dog.sh --repair-traffic-rules >/dev/null 2>&1 || true
    printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n0 3 * * * /root/backup.sh\n' > "$T/crontab"
    bash /usr/local/bin/port-traffic-dog.sh --refresh-all-cron >/dev/null 2>&1 || true
}

# 往旧计数器灌流量（回环 UDP，入方向命中 8031）。
send_udp() {
    python3 - "$@" <<'PY'
import socket, sys
port, size, count = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); r.bind(("127.0.0.1", port))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for _ in range(count):
    s.sendto(b"x" * size, ("127.0.0.1", port)); r.recvfrom(65535)
PY
}

echo "# 准备 1.5.23 环境"
setup_legacy
if grep -q 'port_g8031_8032_in' <<< "$(nft list table inet port_traffic_monitor 2>/dev/null)"; then
    ok "1.5.23 已建立旧格式计数器"
else
    bad "1.5.23 未建立旧计数器"; nft list table inet port_traffic_monitor 2>&1 | head -20
fi
send_udp 8031 972 100   # 每包 1000 字节（含 IP/UDP 头），双倍计费下旧计数 = 200000
old_in=$(nft_bytes port_g8031_8032_in)
[ "${old_in:-0}" -gt 0 ] && ok "旧计数器有流量（$old_in）" || bad "旧计数器无流量"
grep -q 'port-traffic-dog' "$T/crontab" && ok "旧定时任务已写入" || bad "旧定时任务缺失"

echo "# 回滚路径：新版 --finalize-update 失败"
make_bundle "$T/bundle-bad"
sed -i 's/^        --post-update|--finalize-update) post_update ;;$/        --post-update|--finalize-update) return 9 ;;/' "$T/bundle-bad/port-traffic-dog.sh"
grep -q 'finalize-update) return 9' "$T/bundle-bad/port-traffic-dog.sh" || bad "未能构造失败安装包"
cron_before=$(cat "$T/crontab")
bash /usr/local/bin/port-traffic-dog.sh --install-local "$T/bundle-bad" > "$T/bad.out" 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "失败安装包返回非 0（$rc）" || bad "失败安装包竟然成功"
[ "$(installed_version)" = "1.5.23" ] && ok "旧版脚本已恢复" || bad "回滚后版本=$(installed_version)"
[ "$(cfg '.ports | keys | length')" = "2" ] && [ "$(cfg '.schema // "none"')" = "none" ] && ok "旧配置保持 1.5 格式" || bad "回滚后配置已被改动"
[ "$(nft_bytes port_g8031_8032_in)" = "$old_in" ] && ok "旧计数器未受影响" || bad "回滚后计数=$(nft_bytes port_g8031_8032_in)"
[ "$(cat "$T/crontab")" = "$cron_before" ] && ok "定时任务已恢复" || bad "回滚后定时任务变化"

echo "# 成功路径：1.5.23 --install-local 安装 2.0"
make_bundle "$T/bundle"
bash /usr/local/bin/port-traffic-dog.sh --install-local "$T/bundle" > "$T/ok.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "1.5.23 更新器安装 2.0 成功" || { bad "安装失败 rc=$rc"; tail -30 "$T/ok.out"; }
[ "$(installed_version)" = "$(awk -F'"' '/^readonly SCRIPT_VERSION=/ { print $2; exit }' "$ROOT/port-traffic-dog.sh")" ] &&
    ok "已安装版本 $(installed_version)" || bad "已安装版本=$(installed_version)"
[ "$(cfg '.schema')" = "2" ] && ok "配置迁移为 schema 2" || bad "schema=$(cfg '.schema')"
id=$(jq -r '.monitors | to_entries[] | select(.value.ports == ["8031","8032"]) | .key' /etc/port-traffic-dog/config.json)
[ -n "$id" ] && ok "8031,8032 → $id" || bad "找不到 8031,8032 监控项"
new_in=$(nft_bytes "ptd_${id}_in")
[ "${new_in:-x}" = "$((old_in / 2))" ] && ok "计数按旧倍率换算（$old_in ÷ 2 = $new_in）" || bad "新计数=$new_in，期望 $((old_in / 2))"
grep -q 'port_g8031' <<< "$(nft list table inet port_traffic_monitor 2>/dev/null)" && bad "旧对象残留" || ok "旧 nft 对象已清除"
grep -q -- '--tick' "$T/crontab" && ! grep -q -- '--snapshot-traffic' "$T/crontab" && grep -q backup.sh "$T/crontab" &&
    head -n1 "$T/crontab" | grep -q '^PATH=' && ok "定时任务已换成 2.0 格式，用户行与 PATH 行保留" || bad "定时任务：$(cat "$T/crontab")"
[ ! -d /etc/port-traffic-dog/notifications ] && ok "旧通知模块目录已移除" || bad "notifications 目录残留"
ls /etc/port-traffic-dog/backups/migrate-1.5-*/config.json >/dev/null 2>&1 && ok "迁移备份存在" || bad "无迁移备份"
bash /usr/local/bin/port-traffic-dog.sh list >/dev/null 2>&1 && ok "升级后 dog list 正常" || bad "升级后 list 失败"
send_udp 8032 972 10
[ "$(nft_bytes "ptd_${id}_in")" -gt "$new_in" ] && ok "升级后继续计数" || bad "升级后计数未增长"

# migrate-to-custom.sh 使用的离线发布目录（与 tools/release.sh 产物同结构）。
DIST="$T/dist"; mkdir -p "$DIST"
cp "$ROOT/port-traffic-dog.sh" "$ROOT/port-ip-guard.sh" "$DIST/"
(cd "$DIST" && sha256sum port-traffic-dog.sh port-ip-guard.sh > SHA256SUMS)
MIGRATE=(bash "$ROOT/migrate-to-custom.sh" --from-dir "$DIST")

echo "# migrate-to-custom.sh：校验不符时拒绝且不改动"
setup_legacy
send_udp 8031 972 50
old_in=$(nft_bytes port_g8031_8032_in)
cp -a "$DIST" "$T/dist-bad"; echo '# x' >> "$T/dist-bad/port-traffic-dog.sh"
bash "$ROOT/migrate-to-custom.sh" --from-dir "$T/dist-bad" --yes > "$T/m-bad.out" 2>&1 && bad "篡改的安装包被接受" || ok "篡改的安装包被拒绝"
[ "$(installed_version)" = "1.5.23" ] && [ "$(nft_bytes port_g8031_8032_in)" = "$old_in" ] && ok "拒绝后 1.5.23 原样" || bad "拒绝后状态变化"

echo "# migrate-to-custom.sh：1.5.23 → 2.0"
"${MIGRATE[@]}" --yes > "$T/m.out" 2>&1 && ok "迁移脚本返回 0" || { bad "迁移脚本失败"; tail -20 "$T/m.out"; }
[ "$(installed_version)" != "1.5.23" ] && [ "$(cfg '.schema')" = "2" ] && ok "已安装 2.x 且配置为 schema 2" || bad "版本/配置：$(installed_version) $(cfg '.schema')"
id=$(jq -r '.monitors | to_entries[] | select(.value.ports == ["8031","8032"]) | .key' /etc/port-traffic-dog/config.json)
[ "$(nft_bytes "ptd_${id}_in")" = "$((old_in / 2))" ] && ok "计数无损（$old_in ÷ 2）" || bad "计数=$(nft_bytes "ptd_${id}_in")"
grep -q '# port-traffic-dog shortcut' /usr/local/bin/dog && ok "dog 快捷命令已换成 2.0 版" || bad "dog 快捷命令未更新：$(cat /usr/local/bin/dog)"
[ -x /etc/port-traffic-dog/port-ip-guard.sh ] && ok "IP Guard 组件已安装" || bad "IP Guard 组件缺失"
ls -d /etc/port-traffic-dog-migration-backup/*/config >/dev/null 2>&1 && ok "迁移脚本备份存在" || bad "无迁移脚本备份"
grep -q -- '--tick' "$T/crontab" && grep -q backup.sh "$T/crontab" && ok "定时任务已更新且保留用户行" || bad "定时任务：$(cat "$T/crontab")"

echo "# migrate-to-custom.sh：新版迁移失败时整体回滚"
setup_legacy
send_udp 8031 972 20
old_in=$(nft_bytes port_g8031_8032_in); cron_before=$(cat "$T/crontab"); dog_before=$( { sha256sum < /usr/local/bin/dog; } 2>/dev/null || echo none)
cp -a "$DIST" "$T/dist-fail"
sed -i 's/^        --post-update|--finalize-update) post_update ;;$/        --post-update|--finalize-update) return 9 ;;/' "$T/dist-fail/port-traffic-dog.sh"
(cd "$T/dist-fail" && sha256sum port-traffic-dog.sh port-ip-guard.sh > SHA256SUMS)
bash "$ROOT/migrate-to-custom.sh" --from-dir "$T/dist-fail" --yes > "$T/m-fail.out" 2>&1 && bad "失败未报告" || ok "新版失败时返回非 0"
[ "$(installed_version)" = "1.5.23" ] && [ "$(cfg '.schema // "none"')" = "none" ] && ok "脚本与配置已回滚" || bad "回滚后：$(installed_version) $(cfg '.schema')"
[ "$(nft_bytes port_g8031_8032_in)" = "$old_in" ] && ok "旧 nft 表已恢复" || bad "回滚后计数=$(nft_bytes port_g8031_8032_in)"
[ "$(cat "$T/crontab")" = "$cron_before" ] && [ "$( { sha256sum < /usr/local/bin/dog; } 2>/dev/null || echo none)" = "$dog_before" ] && ok "定时任务与快捷命令已恢复" || bad "定时任务/快捷命令未恢复"

echo "# migrate-to-custom.sh：上游 1.4.x 格式"
nft delete table inet port_traffic_monitor 2>/dev/null || true
rm -rf /etc/port-traffic-dog /usr/local/bin/port-traffic-dog.sh /usr/local/bin/dog
printf '#!/bin/bash\nreadonly SCRIPT_VERSION="1.4.3"\necho upstream\n' > /usr/local/bin/port-traffic-dog.sh
chmod 755 /usr/local/bin/port-traffic-dog.sh
printf '#!/bin/bash\nexec bash "/usr/local/bin/port-traffic-dog.sh" "$@"\n' > /usr/local/bin/dog; chmod 755 /usr/local/bin/dog
mkdir -p /etc/port-traffic-dog
cat > /etc/port-traffic-dog/config.json <<'JSON'
{"global":{"billing_mode":"double"},
 "ports":{"00":{"billing_mode":"double","quota":{"enabled":false,"monthly_limit":"unlimited"}},
  "8443":{"billing_mode":"double","quota":{"enabled":true,"monthly_limit":"100GB","reset_day":5},
          "bandwidth_limit":{"enabled":false,"rate":"unlimited"},"expiry":{"expire_date":"2099-03-01"},"remark":"edge"},
  "9001,9002":{"billing_mode":"single","quota":{"enabled":false,"monthly_limit":"unlimited"},
          "bandwidth_limit":{"enabled":false,"rate":"unlimited"},"remark":"grp"}},
 "nftables":{"table_name":"port_traffic_monitor","family":"inet"},"notifications":{}}
JSON
printf '{"9001,9002":{"input":0,"output":7777,"backup_time":"2026-11-14T00:00:00+08:00"}}\n' > /etc/port-traffic-dog/traffic_data.json
nft -f - <<'NFT'
table inet port_traffic_monitor {
    counter port_8443_in { packets 1 bytes 4000 }
    counter port_8443_out { packets 1 bytes 2000 }
    quota port_8443_quota { over 102400 mbytes used 6000 bytes }
    counter port_gab12cd34_in { packets 1 bytes 1 }
    counter port_gab12cd34_out { packets 1 bytes 9999 }
}
NFT
printf '0 3 * * * /root/backup.sh\n' > "$T/crontab"
cfg_before=$(sha256sum < /etc/port-traffic-dog/config.json)
"${MIGRATE[@]}" < /dev/null > "$T/m14-no.out" 2>&1 && bad "未确认却执行了迁移" || ok "未确认时拒绝（非交互无 --yes）"
grep -q '端口组' "$T/m14-no.out" && ok "提示端口组计数将回退到备份" || bad "缺少 1.4.x 提示"
[ "$(sha256sum < /etc/port-traffic-dog/config.json)" = "$cfg_before" ] && [ "$(installed_version)" = "1.4.3" ] && ok "拒绝时未改动" || bad "拒绝时有改动"
"${MIGRATE[@]}" --yes > "$T/m14.out" 2>&1 && ok "1.4.x 迁移成功" || { bad "1.4.x 迁移失败"; tail -20 "$T/m14.out"; }
[ "$(cfg '.monitors | length')" = "2" ] && ok "\"00\" 伪端口未迁移为监控项" || bad "监控项：$(cfg '.monitors | keys')"
sid=$(jq -r '.monitors | to_entries[] | select(.value.ports == ["8443"]) | .key' /etc/port-traffic-dog/config.json)
gid=$(jq -r '.monitors | to_entries[] | select(.value.ports == ["9001","9002"]) | .key' /etc/port-traffic-dog/config.json)
[ "$(nft_bytes "ptd_${sid}_in")" = 2000 ] && [ "$(nft_bytes "ptd_${sid}_out")" = 1000 ] && ok "单端口计数取自内核并 ÷2" || bad "8443：$(nft_bytes "ptd_${sid}_in")/$(nft_bytes "ptd_${sid}_out")"
[ "$(nft_bytes "ptd_${gid}_out")" = 7777 ] && ok "端口组计数回退到 traffic_data.json 备份" || bad "端口组 out=$(nft_bytes "ptd_${gid}_out")"
[ "$(cfg ".monitors.$sid.expiry_date")" = "2099-03-01" ] && ok "上游 .expiry.expire_date 已保留" || bad "到期日=$(cfg ".monitors.$sid.expiry_date")"
grep -q '# port-traffic-dog shortcut' /usr/local/bin/dog && ok "上游 dog 包装脚本已替换" || bad "dog 未替换"

echo
echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ]
