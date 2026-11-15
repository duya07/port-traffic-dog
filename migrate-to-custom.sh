#!/bin/bash
# 从上游 realm-xwPF（1.4.x）或本仓库 1.5.x 迁移 / 重装到本仓库 Dog 2.x。
#
# 本脚本只负责：下载并用 SHA256SUMS 校验 Release 资产 → 完整备份 → 安装 → 调用新脚本
# --post-update（迁移配置与流量、恢复规则、刷新定时任务）→ 失败时整体回滚。
# 迁移逻辑本身只在主脚本里实现一份。
#
# 用法：bash migrate-to-custom.sh [--yes] [--from-dir 目录]
#   --yes            不询问，直接执行（上游 1.4.x 的提示也视为已确认）
#   --from-dir 目录  不联网，使用目录中的 port-traffic-dog.sh、port-ip-guard.sh 与 SHA256SUMS
# 环境变量：REPO（默认 duya07/port-traffic-dog）、PORT_TRAFFIC_DOG_MIRROR（默认 https://v6.gh-proxy.org）
#
# 已在 1.5.x 上的用户也可以直接用旧版菜单里的“更新脚本”升级，效果相同。

set -euo pipefail
umask 077

REPO="${REPO:-duya07/port-traffic-dog}"
MIRROR="${PORT_TRAFFIC_DOG_MIRROR:-https://v6.gh-proxy.org}"
INSTALLED_SCRIPT_PATH="/usr/local/bin/port-traffic-dog.sh"
DOG_PATH="/usr/local/bin/dog"
CONFIG_DIR="/etc/port-traffic-dog"
IP_GUARD_PATH="$CONFIG_DIR/port-ip-guard.sh"
IP_GUARD_SERVICE="port-traffic-dog-ip-guard.service"
IP_GUARD_SERVICE_FILE="/etc/systemd/system/$IP_GUARD_SERVICE"
NFT_TABLE=(inet port_traffic_monitor)
BACKUP_DIR="/etc/port-traffic-dog-migration-backup/$(date +%Y%m%d-%H%M%S)"

ASSUME_YES=false
FROM_DIR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y) ASSUME_YES=true; shift ;;
        --from-dir) [ -n "${2:-}" ] || { echo "用法：$0 [--yes] [--from-dir 目录]" >&2; exit 2; }; FROM_DIR="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

die() { echo "错误：$*" >&2; exit 1; }
confirm() {
    [ "$ASSUME_YES" = true ] && return 0
    local answer=""
    read -r -p "$1 [y/N]：" answer || return 1
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

[ "$(id -u)" -eq 0 ] || die "请以 root 运行"
for cmd in bash jq nft sha256sum crontab; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少命令 $cmd（Alpine 可先运行 alpine-port-traffic-dog-preinstall.sh）"
done
[ -n "$FROM_DIR" ] || command -v curl >/dev/null 2>&1 || die "缺少 curl"

TMP_DIR=$(mktemp -d)
install_started=false
done_ok=false
had_script=false; had_dog=false; had_config=false; had_crontab=false; had_nft=false
guard_state=absent

guard_service_state() {
    [ -e "$IP_GUARD_SERVICE_FILE" ] || { echo absent; return 0; }
    command -v systemctl >/dev/null 2>&1 || return 1
    case "$(systemctl show "$IP_GUARD_SERVICE" --property=ActiveState --value 2>/dev/null)" in
        active|activating|reloading|deactivating) echo active ;;
        inactive|failed) echo inactive ;;
        *) return 1 ;;
    esac
}

guard_restart() {
    systemctl daemon-reload >/dev/null 2>&1 && systemctl restart "$IP_GUARD_SERVICE" >/dev/null 2>&1 || return 1
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        systemctl is-active --quiet "$IP_GUARD_SERVICE" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

rollback() {
    set +e
    echo
    echo "迁移失败，正在恢复迁移前状态..." >&2
    [ "$guard_state" = active ] && systemctl stop "$IP_GUARD_SERVICE" >/dev/null 2>&1
    rm -f "$INSTALLED_SCRIPT_PATH"
    [ "$had_script" = true ] && cp -p "$BACKUP_DIR/port-traffic-dog.sh" "$INSTALLED_SCRIPT_PATH"
    if [ "$had_dog" = true ]; then cp -p "$BACKUP_DIR/dog" "$DOG_PATH"; else rm -f "$DOG_PATH"; fi
    rm -rf "$CONFIG_DIR"
    [ "$had_config" = true ] && cp -a "$BACKUP_DIR/config" "$CONFIG_DIR"
    if [ "$had_crontab" = true ]; then crontab "$BACKUP_DIR/root.crontab"; else crontab -r 2>/dev/null; fi
    nft delete table "${NFT_TABLE[@]}" >/dev/null 2>&1
    [ "$had_nft" = true ] && nft -f "$BACKUP_DIR/nft-table.nft"
    [ "$guard_state" = active ] && { guard_restart || echo "警告：IP Guard 服务未能恢复运行，请手动检查" >&2; }
    echo "已恢复。备份保留在：$BACKUP_DIR" >&2
}

cleanup() {
    local rc=$?
    if [ "$install_started" = true ] && [ "$done_ok" != true ]; then rollback; fi
    rm -rf "$TMP_DIR"
    exit "$rc"
}
trap cleanup EXIT

fetch() {   # $1=资产名 $2=输出
    if [ -n "$FROM_DIR" ]; then
        [ -f "$FROM_DIR/$1" ] && cp "$FROM_DIR/$1" "$2"
        return
    fi
    local url="https://github.com/$REPO/releases/latest/download/$1" src
    for src in "$url" "${MIRROR%/}/$url"; do
        curl -fsSL --connect-timeout 10 --max-time 120 "$src" -o "$2" 2>/dev/null && [ -s "$2" ] && return 0
    done
    return 1
}

verify() {   # $1=资产名
    local want got
    want=$(awk -v n="$1" '$2 == n || $2 == "*" n { print $1; exit }' "$TMP_DIR/SHA256SUMS")
    [ -n "$want" ] || die "SHA256SUMS 中没有 $1"
    got=$(sha256sum "$TMP_DIR/$1" | awk '{print $1}')
    [ "$want" = "$got" ] || die "$1 校验失败（期望 $want，实际 $got）"
}

echo "=== 迁移到 $REPO（Dog 2.x） ==="
echo "[1/5] 获取并校验发布文件..."
fetch SHA256SUMS "$TMP_DIR/SHA256SUMS" || die "无法获取 SHA256SUMS"
for asset in port-traffic-dog.sh port-ip-guard.sh; do
    fetch "$asset" "$TMP_DIR/$asset" || die "无法获取 $asset"
    verify "$asset"
    bash -n "$TMP_DIR/$asset" || die "$asset 语法检查失败"
done
new_version=$(awk -F'"' '/^readonly SCRIPT_VERSION="[0-9]+(\.[0-9]+)+"/ { print $2; exit }' "$TMP_DIR/port-traffic-dog.sh")
[ -n "$new_version" ] || die "无法识别新脚本版本"
grep -Fq '# PORT_TRAFFIC_DOG_IP_GUARD' "$TMP_DIR/port-ip-guard.sh" || die "IP Guard 组件内容校验失败"

echo "[2/5] 检查当前安装..."
old_version=""
[ -f "$INSTALLED_SCRIPT_PATH" ] &&
    old_version=$(awk -F'"' '/^readonly SCRIPT_VERSION=/ { print $2; exit }' "$INSTALLED_SCRIPT_PATH" 2>/dev/null || true)
echo "当前版本：${old_version:-未安装}，目标版本：$new_version"
if [ -f "$CONFIG_DIR/config.json" ]; then
    jq empty "$CONFIG_DIR/config.json" 2>/dev/null || die "现有配置不是有效 JSON：$CONFIG_DIR/config.json"
    bash "$TMP_DIR/port-traffic-dog.sh" --validate-config "$CONFIG_DIR/config.json" ||
        die "当前配置无法被 $new_version 读取，未做任何改动"
    if jq -e 'has("ports") and (has("schema") | not)' "$CONFIG_DIR/config.json" >/dev/null; then
        case "$old_version" in
            1.5.*) echo "检测到 1.5.x 配置：流量计数、配额、重置与到期设置将无损迁移。" ;;
            *)
                echo "注意：当前不是本仓库 1.5.x（版本 ${old_version:-未知}）。"
                echo "  单端口与端口段的计数可直接接上；端口组在上游使用不同的计数器命名，"
                echo "  将改用 traffic_data.json 中最近一次备份的数值，可能少计最近一段时间的流量。"
                confirm "确认继续迁移？" || die "已取消，未做任何改动"
                ;;
        esac
    fi
fi
guard_state=$(guard_service_state) || die "无法确认 IP Guard 服务状态，已停止"
confirm "将安装 Dog $new_version 并迁移现有配置，继续？" || die "已取消，未做任何改动"

echo "[3/5] 备份到 $BACKUP_DIR ..."
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
[ -f "$INSTALLED_SCRIPT_PATH" ] && { cp -p "$INSTALLED_SCRIPT_PATH" "$BACKUP_DIR/port-traffic-dog.sh"; had_script=true; }
[ -e "$DOG_PATH" ] && { cp -p "$DOG_PATH" "$BACKUP_DIR/dog"; had_dog=true; }
[ -d "$CONFIG_DIR" ] && { cp -a "$CONFIG_DIR" "$BACKUP_DIR/config"; had_config=true; }
if crontab -l > "$BACKUP_DIR/root.crontab" 2>/dev/null; then had_crontab=true; else rm -f "$BACKUP_DIR/root.crontab"; fi
if nft list table "${NFT_TABLE[@]}" > "$BACKUP_DIR/nft-table.nft" 2>/dev/null; then had_nft=true; else rm -f "$BACKUP_DIR/nft-table.nft"; fi

echo "[4/5] 安装并迁移..."
install_started=true
install -m 755 "$TMP_DIR/port-traffic-dog.sh" "$INSTALLED_SCRIPT_PATH.new.$$"
mv -f "$INSTALLED_SCRIPT_PATH.new.$$" "$INSTALLED_SCRIPT_PATH"
mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
install -m 755 "$TMP_DIR/port-ip-guard.sh" "$IP_GUARD_PATH.new.$$"
mv -f "$IP_GUARD_PATH.new.$$" "$IP_GUARD_PATH"
# --post-update：迁移 1.x 配置与计数、恢复 nft/TC 规则、重写定时任务（只动带 Dog 标记的行）。
bash "$INSTALLED_SCRIPT_PATH" --post-update || die "新版本迁移/恢复失败"
[ "$(jq -r '.schema // empty' "$CONFIG_DIR/config.json" 2>/dev/null)" = 2 ] || die "迁移后配置不是 schema 2"
bash "$INSTALLED_SCRIPT_PATH" --install >/dev/null || die "快捷命令或定时任务写入失败"
if [ "$guard_state" = active ]; then
    guard_restart || die "IP Guard 服务重启失败"
fi
done_ok=true

echo "[5/5] 自检..."
if bash "$INSTALLED_SCRIPT_PATH" --self-check; then
    echo "迁移完成：Dog $new_version。备份目录：$BACKUP_DIR"
else
    echo "迁移已完成，但自检报告了问题（见上）；可按提示处理后运行 dog --self-check。备份目录：$BACKUP_DIR"
fi
