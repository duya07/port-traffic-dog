#!/bin/bash
# 端口流量狗（Port Traffic Dog）——由 src/ 下的模块经 tools/build.sh 拼接生成，请勿直接编辑本文件。

set -euo pipefail

# cron、systemd、ssh 非交互会话的 PATH/locale 各不相同。脚本自己固定运行环境，
# 不再依赖 crontab 首行的 PATH=（1.5.x 曾因该行丢失导致 nft 找不到、推送内容为空）。
# 只补齐缺失的系统目录（追加在末尾），不打乱调用方已有的 PATH 顺序。
for _ptd_dir in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    case ":${PATH:-}:" in *":$_ptd_dir:"*) ;; *) PATH="${PATH:+$PATH:}$_ptd_dir" ;; esac
done
export PATH
unset _ptd_dir
for _ptd_locale in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if grep -qxF "$_ptd_locale" <<< "$(locale -a 2>/dev/null)"; then
        export LC_ALL="$_ptd_locale"
        break
    fi
done
unset _ptd_locale
# 北京时间使用固定偏移，不依赖 tzdata（缺 tzdata 时 Asia/Shanghai 会静默退回 UTC）。
readonly DOG_TZ="CST-8"

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="端口流量狗"
readonly CONFIG_SCHEMA=2
_ptd_self=$(realpath "$0" 2>/dev/null || printf '%s' "$0")
readonly SCRIPT_PATH="$_ptd_self"
unset _ptd_self
readonly INSTALLED_SCRIPT_PATH="${PORT_TRAFFIC_DOG_INSTALL_PATH:-/usr/local/bin/port-traffic-dog.sh}"
readonly CONFIG_DIR="${PORT_TRAFFIC_DOG_CONFIG_DIR:-/etc/port-traffic-dog}"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly TRAFFIC_DATA_FILE="$CONFIG_DIR/traffic_data.json"
readonly TRAFFIC_STATS_FILE="$CONFIG_DIR/traffic_stats.json"
readonly RESET_HISTORY_FILE="$CONFIG_DIR/reset_history.json"
readonly TC_INTEROP_FILE="$CONFIG_DIR/tc-interop.json"
readonly MACHINE_TRAFFIC_FILE="$CONFIG_DIR/machine_traffic.json"
readonly BACKUP_DIR="$CONFIG_DIR/backups"
readonly LOG_DIR="$CONFIG_DIR/logs"
readonly LOG_FILE="${PORT_TRAFFIC_DOG_LOG_FILE:-$LOG_DIR/traffic.log}"
readonly NOTIFY_LOG_FILE="$LOG_DIR/notification.log"
readonly IP_GUARD_SCRIPT_PATH="$CONFIG_DIR/port-ip-guard.sh"
readonly IP_GUARD_SERVICE_FILE="/etc/systemd/system/port-traffic-dog-ip-guard.service"
readonly IP_GUARD_SERVICE="port-traffic-dog-ip-guard.service"
readonly IP_GUARD_SYSTEMCTL="${PORT_TRAFFIC_DOG_IP_GUARD_SYSTEMCTL:-systemctl}"

# Dog 自身状态（配置、统计、nft 对象、cron）只用一把可重入锁，避免多把锁的顺序问题。
readonly DOG_LOCK_FILE="${PORT_TRAFFIC_DOG_LOCK_FILE:-/run/lock/port-traffic-dog.lock}"
readonly DOG_LOCK_WAIT="${PORT_TRAFFIC_DOG_LOCK_WAIT:-30}"

# nftables：表名沿用 1.5.x，便于升级与外部工具识别。
readonly NFT_FAMILY="inet"
readonly NFT_TABLE="port_traffic_monitor"
readonly NFT_MAP_IN="ptd_in_dport"
readonly NFT_MAP_OUT="ptd_out_sport"
readonly NFT_MAP_MARK_SPORT="ptd_mark_sport"
readonly NFT_MAP_MARK_DPORT="ptd_mark_dport"

# 与 TrafficCop Lite（NTC）共享的 TC 契约。
readonly TC_SHARED_LOCK_FILE="${TRAFFIC_TOOLS_TC_LOCK_FILE:-/run/lock/traffic-tools-tc.lock}"
readonly TRAFFICCOP_TC_STATE_FILE="${TRAFFICCOP_TC_STATE_FILE:-/etc/trafficcop-lite/tc_limit_state}"
readonly TRAFFICCOP_CONFIG_FILE="${TRAFFICCOP_CONFIG_FILE:-/etc/trafficcop-lite/traffic_monitor_config.txt}"
readonly TRAFFICCOP_MONITOR_SCRIPT="${TRAFFICCOP_MONITOR_SCRIPT:-/etc/trafficcop-lite/trafficcop-lite-monitor.sh}"
readonly TC_RECOVERY_RUNNER="${TRAFFIC_TOOLS_TC_RECOVERY_RUNNER:-/usr/local/sbin/traffic-tools-tc-recovery.sh}"
readonly TC_RECOVERY_UNIT_FILE="${TRAFFIC_TOOLS_TC_RECOVERY_UNIT_FILE:-/etc/systemd/system/traffic-tools-tc-recovery.service}"
readonly TC_RECOVERY_SERVICE="traffic-tools-tc-recovery.service"
readonly TC_RECOVERY_SYSTEMCTL="${TRAFFIC_TOOLS_SYSTEMCTL:-systemctl}"
readonly TC_INTEROP_SCHEMA="traffic-tools-unified-htb-v1"
readonly TC_CLASS_MANIFEST_SCHEMA="traffic-tools-dog-classes-v1"
readonly TC_PARENT_RATE="100gbit"
readonly TC_DEFAULT_CLASS_RATE="1kbit"
readonly TC_PORT_CLASS_RATE="1kbit"
readonly TC_MARK_BASE=0x50000000
readonly TC_MARK_MASK=0xfffff000
readonly TC_MARK_PRESERVE_MASK=0x00000fff
readonly TC_IFB_DEVICE="ifb0"
readonly TC_IFB_INGRESS_HANDLE="ffff:"

readonly DEFAULT_TRAFFIC_RETENTION_DAYS=400

if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then
    RED='\033[0;31m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; GREEN='\033[0;32m'; NC='\033[0m'
else
    RED=''; YELLOW=''; BLUE=''; GREEN=''; NC=''
fi
readonly RED YELLOW BLUE GREEN NC

readonly SHORT_CONNECT_TIMEOUT=5
readonly DOG_REPO="${PORT_TRAFFIC_DOG_REPO:-duya07/port-traffic-dog}"
readonly SHORTCUT_COMMAND="dog"
readonly SHORTCUT_PATH="${PORT_TRAFFIC_DOG_SHORTCUT_PATH:-/usr/local/bin/$SHORTCUT_COMMAND}"
readonly DEPENDENCY_STATE_DIR="${PORT_TRAFFIC_DOG_DEPENDENCY_STATE_DIR:-/var/lib/port-traffic-dog/dependencies}"

# 运行期全局状态
DOG_LOCK_DEPTH=0
TC_SHARED_LOCK_DEPTH=0
DOG_NONINTERACTIVE=false

# 依赖账本独立于配置；保留现有软件包的归属，不自动认领旧安装。
# 2.0 起不再使用 bc、unzip、conntrack；此前由 Dog 安装并记入账本的仍可用 --dependencies remove 卸载。
dependency_manifest() {
    cat <<'PACKAGES'
nftables|nft|防火墙与流量统计
iproute2|ip tc ss|连接、网卡与限速
jq|jq|配置处理
mawk|awk|文本处理（任意可用 awk 均可）
cron|cron crontab|定时任务
curl|curl|下载与通知
util-linux|flock|并发锁
procps|pgrep|守护进程状态检测
kmod|modprobe|IFB 内核模块加载
ca-certificates|@ca-certificates|HTTPS 证书
PACKAGES
    if [ "${1:-all}" = all ]; then
        printf '%s\n' 'python3|python3|IP Guard 准入引擎' 'libnetfilter-queue1|@nfqueue|IP Guard 首 SYN 准入运行库'
    fi
}

dependency_peer_uses_package() {
    [ -f /etc/trafficcop-lite/trafficcop-lite-monitor.sh ] ||
        [ -f /etc/trafficcop-lite/trafficcop-lite.sh ] || [ -e /usr/local/bin/ntc ] || return 1
    # 保守保留可能的传递依赖，只允许移除明确属于 Dog 的非共享项。
    case "${1%%:*}" in nftables|conntrack|unzip|libnetfilter-queue1) return 1 ;; *) return 0 ;; esac
}

dependency_removal_is_safe() {
    if [ -e "$INSTALLED_SCRIPT_PATH" ] || [ -e "$CONFIG_FILE" ] || [ -e "$IP_GUARD_SERVICE_FILE" ]; then
        dependency_error 'Dog 或 IP Guard 仍已安装；请先卸载脚本，再用下载的脚本执行 --dependencies remove。'
        return 1
    fi
}

dependency_audit() {
    [ ! -d "$CONFIG_DIR" ] || dog_log_event "$@"
    return 0
}

# BEGIN MANAGED DEPENDENCIES
# Adapted from easy_Caddy 843e7b4; embedded so standalone installs need no helper file.
dependency_error() { printf '依赖管理：%s\n' "$*" >&2; }

dependency_package_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9-]+)?$ ]]; }

dependency_installed() {
    local state
    state=$(dpkg-query -W -f='${db:Status-Status}\n' -- "$1" 2>/dev/null) || return 1
    [ "$state" = installed ]
}

dependency_tools_available() {
    local package="$1" tools="$2" tool
    if [ -z "$tools" ]; then dependency_installed "$package"; return; fi
    for tool in $tools; do
        case "$tool" in
            @ca-certificates)
                [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -s /etc/ssl/cert.pem ] || return 1
                ;;
            @nfqueue)
                command -v python3 >/dev/null 2>&1 || return 3
                python3 -c 'import ctypes; ctypes.CDLL("libnetfilter_queue.so.1")' >/dev/null 2>&1 || return 1
                ;;
            *) command -v "$tool" >/dev/null 2>&1 || return 1 ;;
        esac
    done
}

dependency_portable_report() {
    local package tools description status missing=0
    printf '依赖检测（当前平台；包账本安装/卸载仅支持 Debian/Ubuntu）：\n'
    while IFS='|' read -r package tools description; do
        [ -n "$package" ] || continue
        status=0
        if [ -z "$tools" ]; then
            [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -s /etc/ssl/cert.pem ] || status=1
        else dependency_tools_available "$package" "$tools" || status=$?; fi
        if [ "$status" -eq 0 ]; then printf '  [可用] %s\n' "$package"
        else printf '  [缺失] %s：%s\n' "$package" "$description"; DEPENDENCY_MISSING_PACKAGES+=("$package"); missing=1; fi
    done < <(dependency_manifest "${1:-all}")
    return "$missing"
}

dependency_report() {
    local profile="${1:-all}" package tools description status broken=0
    DEPENDENCY_MISSING_PACKAGES=()
    command -v dpkg-query >/dev/null 2>&1 || { dependency_portable_report "$profile"; return $?; }
    printf '依赖检测（命令与运行库实际可用性）：\n'
    dependency_no_pending || broken=1
    while IFS='|' read -r package tools description; do
        [ -n "$package" ] || continue
        status=0
        dependency_tools_available "$package" "$tools" || status=$?
        if [ "$status" -eq 0 ]; then
            printf '  [可用] %s%s\n' "$package" "${description:+：$description}"
        elif [ "$status" -eq 3 ] && dependency_installed "$package"; then
            printf '  [待复检] %s：先安装 Python 3，再验证运行库。\n' "$package"
        elif dependency_installed "$package"; then
            printf '  [异常] %s：包已安装，但命令或运行库不可用；请检查 PATH 或修复软件包。\n' "$package"
            broken=1
        else
            printf '  [缺失] %s%s\n' "$package" "${description:+：$description}"
            DEPENDENCY_MISSING_PACKAGES+=("$package")
        fi
    done < <(dependency_manifest "$profile")
    [ "$broken" -eq 0 ] || return 2
    [ "${#DEPENDENCY_MISSING_PACKAGES[@]}" -eq 0 ]
}

dependency_safe_record() {
    local mode
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u -- "$1")" = 0 ] || return 1
    mode=$(stat -c %a -- "$1") || return 1
    (( (8#$mode & 0022) == 0 ))
}

dependency_prepare_state() {
    local part current='' mode file
    [ "$EUID" -eq 0 ] || { dependency_error '安装或卸载需要 root。'; return 1; }
    command -v apt-get >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || {
        dependency_error '需要 apt-get 和 flock；请先确认系统包管理器及基础工具。'; return 1;
    }
    [[ "$DEPENDENCY_STATE_DIR" == /* && "$DEPENDENCY_STATE_DIR" != / ]] || return 1
    local -a parts=()
    IFS=/ read -r -a parts <<< "$DEPENDENCY_STATE_DIR"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        case "$part" in .|..) return 1 ;; esac
        current+="/$part"
        [ ! -L "$current" ] || { dependency_error '依赖状态路径包含符号链接，已拒绝。'; return 1; }
    done
    if [ -e "$DEPENDENCY_STATE_DIR" ]; then
        [ -d "$DEPENDENCY_STATE_DIR" ] && [ "$(stat -c %u -- "$DEPENDENCY_STATE_DIR")" = 0 ] || return 1
        mode=$(stat -c %a -- "$DEPENDENCY_STATE_DIR") || return 1
        (( (8#$mode & 0022) == 0 )) || { dependency_error '依赖目录可被其他用户写入，已拒绝。'; return 1; }
    else
        mkdir -p -- "$DEPENDENCY_STATE_DIR" || return 1
    fi
    chmod 700 -- "$DEPENDENCY_STATE_DIR" || return 1
    for file in installed-packages pending-before pending-plan lock; do
        if [ -e "$DEPENDENCY_STATE_DIR/$file" ] || [ -L "$DEPENDENCY_STATE_DIR/$file" ]; then
            dependency_safe_record "$DEPENDENCY_STATE_DIR/$file" || { dependency_error "不安全的依赖记录：$file"; return 1; }
        fi
    done
}

dependency_read_owned() {
    local package path="$DEPENDENCY_STATE_DIR/installed-packages"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then return 0; fi
    dependency_safe_record "$path" || { dependency_error '新增包账本不是安全的普通文件。'; return 1; }
    while IFS= read -r package || [ -n "$package" ]; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || { dependency_error '新增包账本含无效包名。'; return 1; }
        printf '%s\n' "$package"
    done < "$path"
}

dependency_snapshot() {
    local rows
    rows=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${Essential}\t${Protected}\n') || return 1
    printf '%s\n' "$rows" | awk -F '\t' -v phase="${2:-after}" '
        (phase == "before" && $2 != "not-installed") || (phase == "after" && $2 == "installed") ||
        (phase == "incomplete" && $2 ~ /^(unpacked|half-installed|half-configured|triggers-awaited|triggers-pending)$/) {print $1}
    ' | LC_ALL=C sort -u > "$1" || return 1
    chmod 600 -- "$1"
}

dependency_save_owned() {
    local stage
    stage=$(mktemp "$DEPENDENCY_STATE_DIR/.owned.XXXXXX") || return 1
    if ! LC_ALL=C sort -u -- "$1" > "$stage" || ! chmod 600 -- "$stage" ||
       ! mv -f -- "$stage" "$DEPENDENCY_STATE_DIR/installed-packages"; then
        rm -f -- "$stage"
        dependency_error '新增包账本保存失败，事务快照已保留。'
        return 1
    fi
}

dependency_no_pending() {
    if [ -e "$DEPENDENCY_STATE_DIR/pending-before" ] || [ -L "$DEPENDENCY_STATE_DIR/pending-before" ] ||
       [ -e "$DEPENDENCY_STATE_DIR/pending-plan" ] || [ -L "$DEPENDENCY_STATE_DIR/pending-plan" ]; then
        dependency_error "发现未完成安装事务；请核对 $DEPENDENCY_STATE_DIR 的 pending-before/pending-plan，本次不自动认领或卸载。"
        return 1
    fi
}

dependency_install_missing() (
    umask 077
    local assume_yes="${1:-false}" profile="${2:-all}" status=0 answer stage plan owned package rc=0 lock_fd incomplete=false
    dependency_report "$profile" || status=$?
    [ "$status" -ne 2 ] || return 1
    [ "${#DEPENDENCY_MISSING_PACKAGES[@]}" -gt 0 ] || { printf '依赖全部可用，无需安装；原有包不会记为新增。\n'; return 0; }
    printf '仅安装缺失项：\n'; printf '  %s\n' "${DEPENDENCY_MISSING_PACKAGES[@]}"
    if [ "$assume_yes" != true ]; then
        read -r -p '确认安装？[y/yes，默认 n]：' answer || return 1
        case "${answer,,}" in y|yes) ;; *) printf '安装已取消。\n'; return 1 ;; esac
    fi
    dependency_prepare_state || return 1
    exec {lock_fd}> "$DEPENDENCY_STATE_DIR/lock" || return 1
    chmod 600 -- "$DEPENDENCY_STATE_DIR/lock" || return 1
    flock -x -w 30 "$lock_fd" || { dependency_error '依赖管理锁暂忙。'; return 1; }
    dependency_no_pending || return 1
    owned=$(dependency_read_owned) || return 1
    status=0; dependency_report "$profile" || status=$?
    [ "$status" -ne 2 ] || return 1
    [ "${#DEPENDENCY_MISSING_PACKAGES[@]}" -gt 0 ] || return 0
    stage=$(mktemp -d "$DEPENDENCY_STATE_DIR/.transaction.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    apt-get update || { dependency_error '软件包索引更新失败，未安装。'; return 1; }
    dependency_snapshot "$stage/before" before || return 1
    plan=$(LC_ALL=C apt-get --simulate --no-remove --no-install-recommends install -- "${DEPENDENCY_MISSING_PACKAGES[@]}") || return 1
    if grep -q '^Remv ' <<< "$plan"; then dependency_error '安装计划包含删除，已停止。'; return 1; fi
    printf '%s\n' "$plan" | awk '$1 == "Inst" {print $2}' | LC_ALL=C sort -u > "$stage/plan"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
    done < "$stage/plan"
    printf '安装计划（含传递依赖）：\n'; cat -- "$stage/plan"
    install -m 600 -- "$stage/before" "$DEPENDENCY_STATE_DIR/pending-before" &&
        install -m 600 -- "$stage/plan" "$DEPENDENCY_STATE_DIR/pending-plan" || return 1
    apt-get --no-remove --no-install-recommends install -y -- "${DEPENDENCY_MISSING_PACKAGES[@]}" || rc=$?
    dependency_snapshot "$stage/after" || { dependency_error '无法读取安装后状态，保留事务快照。'; return 1; }
    dependency_snapshot "$stage/incomplete" incomplete || { dependency_error '无法读取未完成包状态，保留事务快照。'; return 1; }
    printf '%s\n' "$owned" | sed '/^$/d' > "$stage/owned"
    LC_ALL=C comm -13 "$stage/before" "$stage/after" > "$stage/new" || return 1
    local -A planned=()
    while IFS= read -r package; do
        [ -n "$package" ] && planned["${package%%:*}"]=1
    done < "$stage/plan"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        if [ "${planned[${package%%:*}]:-0}" = 1 ]; then incomplete=true; fi
    done < "$stage/incomplete"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        if [ "${planned[${package%%:*}]:-0}" = 1 ]; then
            printf '%s\n' "$package" >> "$stage/owned"
            printf '已记录本脚本新增依赖：%s\n' "$package"
        fi
    done < "$stage/new"
    dependency_save_owned "$stage/owned" || return 1
    if [ "$incomplete" = true ]; then
        dependency_error '安装后仍有未配置完成的计划包；已记录成功新增项并保留事务快照，请人工核对。'
        dependency_audit dependency_install 1
        return 1
    fi
    rm -f -- "$DEPENDENCY_STATE_DIR/pending-before" "$DEPENDENCY_STATE_DIR/pending-plan" || return 1
    if [ "$rc" -ne 0 ]; then
        dependency_error '安装未全部成功；实际已装的新包已记录，可重试或按账本卸载。'
        dependency_audit dependency_install "$rc"
        return "$rc"
    fi
    if ! dependency_report "$profile"; then
        dependency_error '安装命令已完成，但命令/运行库复检失败，未报告成功。'
        dependency_audit dependency_install 1
        return 1
    fi
    dependency_audit dependency_install 0
    printf '依赖安装并复检完成；已有依赖的归属保持不变。\n'
)

dependency_protected() {
    local flags base="${1%%:*}"
    case "$base" in bash|apt|dpkg|systemd*|libsystemd*|libpam*|libudev*|coreutils|findutils|grep|sed|mawk|gawk|util-linux|libc6|libc-bin|libgcc-s1|libstdc++6) return 0 ;; esac
    flags=$(dpkg-query -W -f='${Essential}\t${Protected}\n' -- "$1" 2>/dev/null) || return 0
    [[ "$flags" == *yes* ]]
}

dependency_retained_dependencies() {
    [ "$#" -gt 0 ] || return 0
    local records
    records=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${Pre-Depends}, ${Depends}\n') || return 1
    # 保留受保护包及其已安装的直接/间接依赖；替代依赖保守保留已安装项。
    printf '%s\n' "$records" | awk -F '\t' -v roots="$*" '
        function base(name) { sub(/:[A-Za-z0-9-]+$/, "", name); return name }
        $2 == "installed" { name=base($1); present[name]=1; deps[name]=$3 }
        END {
            count=split(roots, initial, " "); last=0
            for (i=1; i<=count; i++) { name=base(initial[i]); if (!seen[name]++) queue[++last]=name }
            for (first=1; first<=last; first++) {
                name=queue[first]; print name
                count=split(deps[name], edges, /[,|]/)
                for (i=1; i<=count; i++) {
                    gsub(/^[ \t]+|[ \t]+$/, "", edges[i]); split(edges[i], words, /[ \t]+/)
                    child=base(words[1]); if (present[child] && !seen[child]++) queue[++last]=child
                }
            }
        }'
}

dependency_remove() (
    umask 077
    local scope="${1:-owned}" assume_yes="${2:-false}" owned candidates package plan answer stage rc=0 lock_fd
    dependency_removal_is_safe || return 1
    dependency_prepare_state || return 1
    exec {lock_fd}> "$DEPENDENCY_STATE_DIR/lock" || return 1
    chmod 600 -- "$DEPENDENCY_STATE_DIR/lock" || return 1
    flock -x -w 30 "$lock_fd" || return 1
    dependency_no_pending || return 1
    owned=$(dependency_read_owned) || return 1
    if [ "$scope" = all ]; then
        candidates=$(printf '%s\n%s\n' "$(dependency_manifest all | cut -d '|' -f1)" "$owned" | sed '/^$/d' | LC_ALL=C sort -u)
        printf '已选择全部相关依赖，包括安装前已有的包；系统基础包和另一脚本仍使用的包仍会保留。\n'
    else
        candidates="$owned"
        printf '卸载范围：仅本脚本新增并记录的依赖。\n'
    fi
    local -a selected=() removals=() protected_roots=() filtered=()
    local -A allowed=()
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
        dependency_installed "$package" || continue
        if dependency_protected "$package"; then printf '保留系统基础/受保护包：%s\n' "$package"; protected_roots+=("$package"); continue; fi
        if dependency_peer_uses_package "$package"; then printf '保留另一脚本仍需使用的包：%s\n' "$package"; protected_roots+=("$package"); continue; fi
        selected+=("$package"); allowed["${package%%:*}"]=1
    done <<< "$candidates"
    local retained
    retained=$(dependency_retained_dependencies "${protected_roots[@]}") || return 1
    local -A required=()
    while IFS= read -r package; do [ -z "$package" ] || required["${package%%:*}"]=1; done <<< "$retained"
    allowed=()
    for package in "${selected[@]}"; do
        if [ "${required[${package%%:*}]:-0}" = 1 ]; then
            printf '保留受保护/共享组件所需的依赖：%s\n' "$package"
        else filtered+=("$package"); allowed["${package%%:*}"]=1; fi
    done
    selected=("${filtered[@]}")
    [ "${#selected[@]}" -gt 0 ] || { printf '没有可卸载的新依赖；未改动系统软件包。\n'; return 0; }
    plan=$(LC_ALL=C apt-get --simulate -o APT::Get::AutomaticRemove=false remove -- "${selected[@]}") || return 1
    if grep -q '^Inst ' <<< "$plan"; then dependency_error '卸载计划会安装其他包，已停止。'; return 1; fi
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
        if [ "${allowed[${package%%:*}]:-0}" != 1 ] || dependency_protected "$package" || dependency_peer_uses_package "$package"; then
            dependency_error "计划会额外删除范围外/受保护包 $package，已停止。"
            return 1
        fi
        removals+=("$package")
    done < <(printf '%s\n' "$plan" | awk '$1 == "Remv" {print $2}')
    [ "${#removals[@]}" -gt 0 ] || { printf '卸载计划为空，未改动软件包。\n'; return 0; }
    printf '本次将删除以下依赖，不执行 autoremove/purge：\n'; printf '  %s\n' "${removals[@]}"
    if [ "$assume_yes" != true ]; then
        read -r -p '确认卸载上述依赖？[y/yes，默认 n]：' answer || return 0
        case "${answer,,}" in y|yes) ;; *) printf '卸载已取消。\n'; return 0 ;; esac
    fi
    stage=$(mktemp -d "$DEPENDENCY_STATE_DIR/.uninstall.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    apt-get -o APT::Get::AutomaticRemove=false remove -y -- "${removals[@]}" || rc=$?
    : > "$stage/owned"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        if dependency_installed "$package"; then printf '%s\n' "$package" >> "$stage/owned"; fi
    done <<< "$owned"
    dependency_save_owned "$stage/owned" || return 1
    for package in "${removals[@]}"; do
        if dependency_installed "$package"; then rc=1; fi
    done
    dependency_audit dependency_remove "$rc"
    [ "$rc" -eq 0 ] || { dependency_error '卸载未全部完成；剩余新增依赖已保留在账本中。'; return "$rc"; }
    printf '依赖卸载完成；范围外和原有依赖保持不变。\n'
)

dependency_cli() {
    # main() 已把 --yes/-y 从参数中取出并设置 DOG_NONINTERACTIVE；这里两种来源都认。
    local action="${1:-check}" scope=owned yes="${DOG_NONINTERACTIVE:-false}" option
    [ "$#" -eq 0 ] || shift
    for option in "$@"; do
        case "$option" in --yes) yes=true ;; --all) scope=all ;; *) dependency_error "未知参数：$option"; return 2 ;; esac
    done
    case "$action" in
        check) [ "$scope" = owned ] && [ "$yes" = false ] || return 2; dependency_report all ;;
        install) [ "$scope" = owned ] || return 2; dependency_install_missing "$yes" all ;;
        remove) dependency_remove "$scope" "$yes" ;;
        owned) [ "$scope" = owned ] && [ "$yes" = false ] || return 2; dependency_read_owned ;;
        *) dependency_error '用法：--dependencies check|install [--yes]|remove [--all] [--yes]|owned'; return 2 ;;
    esac
}

dependency_menu() {
    local choice scope
    while true; do
        printf '\n=== 依赖检测、安装与卸载 ===\n'
        printf ' 1. 检测全部依赖（只读）\n 2. 仅安装缺失依赖\n 3. 查看本脚本新增包账本\n 4. 卸载依赖\n 0. 返回\n'
        read -r -p '请选择 [0-4]：' choice || return 0
        case "$choice" in
            1) dependency_report all || true ;;
            2) dependency_install_missing false all || true ;;
            3) dependency_read_owned || true; printf '账本位置：%s/installed-packages\n' "$DEPENDENCY_STATE_DIR" ;;
            4)
                read -r -p '范围：1 仅本脚本新增（默认），2 全部相关，0 取消：' scope || return 0
                case "$scope" in ''|1) dependency_remove owned false || true ;; 2) dependency_remove all false || true ;; 0) ;; *) printf '无效范围。\n' ;; esac
                ;;
            0) return 0 ;;
            *) printf '无效选择。\n' ;;
        esac
        read -r -p '按回车返回依赖管理...' choice || return 0
    done
}

detect_system() {
    # Ubuntu优先检测：避免Debian系统误判
    if [ -f /etc/lsb-release ] && grep -q "Ubuntu" /etc/lsb-release 2>/dev/null; then
        echo "ubuntu"
        return
    fi

    if [ -f /etc/debian_version ]; then
        echo "debian"
        return
    fi

    echo "unknown"
}

# 保持原自动检查调用约定；显式更新和 Guard 使用 all，普通监控仅 core。
install_missing_tools() { dependency_install_missing true core; }

check_dependencies() {
    local silent_mode="${1:-false}" profile="${2:-core}" report status=0
    report=$(dependency_report "$profile") || status=$?
    if [ "$status" -eq 2 ]; then
        printf '%s\n' "$report" >&2
        return 1
    fi
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$report"
        dependency_install_missing true "$profile" || return 1
    elif [ "$silent_mode" != true ]; then
        printf '%s\n依赖检查通过。\n' "$report"
    fi
}

# ── 日志 ──────────────────────────────────────────────────────────
# traffic.log 是结构化操作日志：只接收固定事件名、返回码和经过白名单校验的标量，
# 不写入通知正文、token 等敏感内容。notification.log 记录推送与告警摘要。

dog_write_event() (
    umask 077
    local event="$1" result="$2" field safe_fields="" directory index description
    [[ "$event" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || return 0
    [[ "$result" =~ ^[0-9]{1,3}$ ]] || return 0
    shift 2
    for field in "$@"; do
        case "$field" in
            id=*) [[ "${field#*=}" =~ ^m[0-9]{1,6}$ ]] || continue ;;
            port=*|ports=*) [[ "${field#*=}" =~ ^[0-9,-]{1,256}$ ]] || continue ;;
            rate=*) [[ "${field#*=}" =~ ^[0-9]+([kKmMgG]?[bB]it|[KMG]bps)?$ ]] || continue ;;
            mode=*|step=*) [[ "${field#*=}" =~ ^[a-z_-]{1,32}$ ]] || continue ;;
            *) continue ;;
        esac
        safe_fields+=" $field"
    done
    directory=$(dirname "$LOG_FILE")
    [ ! -L "$directory" ] && [ ! -L "$LOG_FILE" ] && [ ! -L "$LOG_FILE.lock" ] || return 1
    mkdir -p "$directory" || return 1
    chmod 700 "$directory" || return 1
    exec 7>>"$LOG_FILE.lock" || return 1
    chmod 600 "$LOG_FILE.lock" || return 1
    flock -x -w 2 7 || return 1
    for index in 1 2 3; do [ ! -L "$LOG_FILE.$index" ] || return 1; done
    if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE")" -ge 1048576 ]; then
        rm -f "$LOG_FILE.3" || return 1
        for index in 2 1; do
            if [ -f "$LOG_FILE.$index" ]; then mv -f "$LOG_FILE.$index" "$LOG_FILE.$((index+1))" || return 1; fi
        done
        mv -f "$LOG_FILE" "$LOG_FILE.1" || return 1
    fi
    case "$event" in
        config_update) description="保存配置" ;;
        monitor_add) description="添加监控项" ;;
        monitor_remove) description="删除监控项" ;;
        monitor_edit) description="修改监控项端口" ;;
        monitor_split) description="拆分监控项" ;;
        monitor_merge) description="合并监控项" ;;
        tc_apply) description="应用带宽限制" ;;
        tc_clear) description="撤销带宽限制" ;;
        expiry_apply) description="应用服务到期封锁" ;;
        expiry_clear) description="解除服务到期封锁" ;;
        traffic_reset) description="重置流量" ;;
        quota_apply) description="应用流量配额" ;;
        install) description="安装或更新 Dog" ;;
        install_rollback) description="恢复更新前的 Dog 文件和状态" ;;
        migrate) description="从 1.5.x 迁移配置与流量" ;;
        runtime_restore) description="恢复监控规则和限速" ;;
        import_config) description="导入配置并恢复运行状态" ;;
        export_config) description="导出配置备份" ;;
        cron_task) description="定时任务" ;;
        dependency_install) description="安装并复检缺失依赖" ;;
        dependency_remove) description="按确认计划卸载依赖" ;;
        *) description="记录操作" ;;
    esac
    if [ "$result" -eq 0 ]; then description+="：成功"; else description+="：失败（返回码 $result）"; fi
    printf '%s %s%s event=%s result=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$description" "$safe_fields" "$event" "$result" >> "$LOG_FILE" || return 1
    chmod 600 "$LOG_FILE" || return 1
)

dog_log_event() {
    if ! dog_write_event "$@"; then
        echo "警告：Dog 操作日志写入失败，业务返回状态保持原值。" >&2
    fi
    return 0
}

# 通知与告警摘要日志（人类可读，按大小轮转）。
log_notification() {
    local message="$1"
    mkdir -p "$LOG_DIR" 2>/dev/null || return 0
    if [ -f "$NOTIFY_LOG_FILE" ] && [ "$(stat -c %s "$NOTIFY_LOG_FILE" 2>/dev/null || echo 0)" -ge 524288 ]; then
        tail -n 1000 "$NOTIFY_LOG_FILE" 2>/dev/null | atomic_write "$NOTIFY_LOG_FILE" 600 || true
    fi
    printf '[%s] %s\n' "$(beijing_date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$NOTIFY_LOG_FILE" 2>/dev/null || true
    chmod 600 "$NOTIFY_LOG_FILE" 2>/dev/null || true
}

# 打印错误到 stderr，并写入通知日志，cron 下失败也能看到原因。
dog_error() {
    echo -e "${RED}$*${NC}" >&2
    log_notification "错误：$*"
}

show_operation_logs() {
    local file
    for file in "$LOG_FILE" "$LOG_DIR/ip-guard.log" "$NOTIFY_LOG_FILE"; do
        printf '\n=== %s ===\n' "${file##*/}"
        if [ -f "$file" ] && [ ! -L "$file" ]; then
            if [[ "$file" == */ip-guard.log ]]; then
                tail -n 50 -- "$file" | jq -r '"\(.time) \(.message // .event)"' 2>/dev/null || tail -n 50 -- "$file"
            else tail -n 50 -- "$file"; fi
        else echo '暂无日志'; fi
    done
}

# ── 锁与原子写入 ──────────────────────────────────────────────────
# fd 约定：7=日志锁（子 shell 内）、8=Dog 状态锁、9=与 NTC 共享的 TC 锁。

# 获取 Dog 状态锁（可重入）。$1 可指定等待秒数，0 表示不等待。
dog_lock() {
    local wait_seconds="${1:-$DOG_LOCK_WAIT}"
    if [ "$DOG_LOCK_DEPTH" -gt 0 ]; then
        DOG_LOCK_DEPTH=$((DOG_LOCK_DEPTH + 1))
        return 0
    fi
    mkdir -p "$(dirname "$DOG_LOCK_FILE")" 2>/dev/null || true
    exec 8>>"$DOG_LOCK_FILE" || return 1
    if [ "$wait_seconds" -eq 0 ]; then
        flock -n 8 || { exec 8>&-; return 1; }
    else
        flock -w "$wait_seconds" 8 || { exec 8>&-; return 1; }
    fi
    DOG_LOCK_DEPTH=1
}

dog_unlock() {
    [ "$DOG_LOCK_DEPTH" -gt 0 ] || return 0
    DOG_LOCK_DEPTH=$((DOG_LOCK_DEPTH - 1))
    if [ "$DOG_LOCK_DEPTH" -eq 0 ]; then
        flock -u 8 2>/dev/null || true
        exec 8>&-
    fi
}

# 在锁内执行一条命令，返回该命令的退出码。
with_dog_lock() {
    dog_lock || { echo -e "${RED}另一个 Dog 进程正在修改配置，请稍后再试${NC}" >&2; return 75; }
    local rc=0
    "$@" || rc=$?
    dog_unlock
    return "$rc"
}

# 把标准输入原子写入目标文件：同目录临时文件 + fsync + rename。
# 用法：producer | atomic_write <目标> [权限]
atomic_write() {
    local target="$1" mode="${2:-600}" dir tmp
    dir=$(dirname "$target")
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.${target##*/}.tmp.XXXXXX") || return 1
    if ! cat > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    chmod "$mode" "$tmp" 2>/dev/null || true
    sync "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

# 对 JSON 文件执行 jq 变换并原子替换；jq 失败或结果不是对象时保持原文件。
# 用法：json_update <文件> <jq 过滤器> [jq 参数...]
json_update() {
    local file="$1" filter="$2" out
    shift 2
    out=$(jq "$@" "$filter" "$file") || return 1
    jq -e 'type == "object"' <<< "$out" >/dev/null 2>&1 || return 1
    printf '%s\n' "$out" | atomic_write "$file" 600
}

# ── 通用工具 ──────────────────────────────────────────────────────

beijing_date() {
    TZ="$DOG_TZ" date "$@"
}

get_current_date() {
    beijing_date +%Y-%m-%d
}

get_script_exec_path() {
    if [ -f "$INSTALLED_SCRIPT_PATH" ]; then
        echo "$INSTALLED_SCRIPT_PATH"
    else
        echo "$SCRIPT_PATH"
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要 root 权限运行${NC}" >&2
        exit 1
    fi
}

is_interactive() {
    [ "$DOG_NONINTERACTIVE" != "true" ] && [ -t 0 ]
}

# 询问 y/N；非交互模式（--yes）直接同意。
confirm() {
    local prompt="$1" answer=""
    [ "$DOG_NONINTERACTIVE" = "true" ] && return 0
    read -r -p "$prompt [y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}

pause() {
    is_interactive || return 0
    read -r -p "按回车继续..." _ || true
}

get_network_interfaces() {
    ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -vx 'lo' || true
}

get_default_interface() {
    local dev
    dev=$(ip -o route show default 2>/dev/null |
        awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [ -n "$dev" ] || dev=$(ip -o -6 route show default 2>/dev/null |
        awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [ -n "$dev" ] || dev=$(get_network_interfaces | head -n1)
    if [ -z "$dev" ]; then
        # 不能猜网卡名：猜错会在错误的设备上重建 HTB。
        echo "无法确定默认出口网卡，已中止 TC 相关操作" >&2
        return 1
    fi
    echo "$dev"
}

# 字节数格式化为二进制单位（KB/MB/GB/TB，1024 进制，保留两位小数）。
format_bytes() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB PB", u, " "); i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%dB\n", b; else printf "%.2f%s\n", b, u[i]
    }'
}

# "240GB" / "1.5T" / "500M" / "800KB" → 字节；无法解析返回 1。
parse_size_to_bytes() {
    local s="${1^^}"
    s="${s// /}"
    [[ "$s" =~ ^([0-9]+(\.[0-9]+)?)(K|KB|M|MB|G|GB|T|TB)$ ]] || return 1
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[3]:0:1}" pow
    case "$unit" in K) pow=1 ;; M) pow=2 ;; G) pow=3 ;; T) pow=4 ;; esac
    awk -v n="$num" -v p="$pow" 'BEGIN { v = n * (1024 ^ p); printf "%.0f\n", v - (v % 1) }'
}

validate_quota() {
    local bytes
    bytes=$(parse_size_to_bytes "$1") || return 1
    [ "$bytes" -gt 0 ]
}

# 带宽：0 或 数字+kbps/mbps/gbps（不区分大小写）。
validate_bandwidth() {
    local v="${1,,}"
    [ "$v" = "0" ] || [[ "$v" =~ ^[1-9][0-9]*(kbps|mbps|gbps)$ ]]
}

# 用户输入的带宽（100Mbps）→ tc 速率（100mbit）。
convert_bandwidth_to_tc() {
    local v="${1,,}"
    case "$v" in
        *kbps) echo "${v%kbps}kbit" ;;
        *mbps) echo "${v%mbps}mbit" ;;
        *gbps) echo "${v%gbps}gbit" ;;
        *) return 1 ;;
    esac
}

validate_day_1_31() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 31 ]
}

validate_month_1_12() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 12 ]
}

# 解析菜单多选输入 "1,3,5" → 去重后的合法序号数组（nameref）。
parse_multi_choice_input() {
    local input="$1" max_choice="$2"
    local -n _pmc_out=$3
    local choice
    _pmc_out=()
    IFS=',' read -ra _pmc_items <<< "$input"
    for choice in "${_pmc_items[@]}"; do
        choice="${choice//[[:space:]]/}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$max_choice" ]; then
            [[ " ${_pmc_out[*]} " == *" $choice "* ]] || _pmc_out+=("$choice")
        elif [ -n "$choice" ]; then
            echo -e "${RED}无效选择: $choice${NC}" >&2
        fi
    done
}

is_leap_year() {
    local year="$1"
    (( (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0) ))
}

get_days_in_month() {
    local year="$1"
    local month="$2"
    case "$month" in
        1|3|5|7|8|10|12) echo 31 ;;
        4|6|9|11) echo 30 ;;
        2)
            if is_leap_year "$year"; then
                echo 29
            else
                echo 28
            fi
            ;;
        *) echo 30 ;;
    esac
}

normalize_year_month() {
    local year="$1"
    local month="$2"

    while [ "$month" -lt 1 ]; do
        month=$((month + 12))
        year=$((year - 1))
    done
    while [ "$month" -gt 12 ]; do
        month=$((month - 12))
        year=$((year + 1))
    done

    echo "$year $month"
}

clamp_day_to_month() {
    local year="$1"
    local month="$2"
    local day="$3"
    local month_days
    month_days=$(get_days_in_month "$year" "$month")

    if [ "$day" -lt 1 ]; then
        day=1
    fi
    if [ "$day" -gt "$month_days" ]; then
        day="$month_days"
    fi

    echo "$day"
}

get_current_date() {
    beijing_date +%Y-%m-%d
}

date_parts() {
    local date_value="$1"
    echo "${date_value:0:4} $((10#${date_value:5:2})) $((10#${date_value:8:2}))"
}

format_date() {
    local year="$1"
    local month="$2"
    local day="$3"
    printf '%04d-%02d-%02d\n' "$year" "$month" "$day"
}

is_valid_date() {
    local date_value="$1"
    [[ "$date_value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1

    local -a parts; read -ra parts <<< "$(date_parts "$date_value")"
    local year="${parts[0]}"
    local month="${parts[1]}"
    local day="${parts[2]}"

    [ "$year" -ge 1 ] && [ "$year" -le 9999 ] || return 1
    [ "$month" -ge 1 ] && [ "$month" -le 12 ] || return 1
    local month_days
    month_days=$(get_days_in_month "$year" "$month")
    [ "$day" -ge 1 ] && [ "$day" -le "$month_days" ]
}

date_lt() {
    [[ "$1" < "$2" ]]
}

date_le() {
    [[ "$1" < "$2" || "$1" = "$2" ]]
}

days_before_year() {
    local year="$1"
    local previous_year=$((year - 1))
    echo $((365 * previous_year + previous_year / 4 - previous_year / 100 + previous_year / 400))
}

date_to_ordinal() {
    local date_value="$1"
    is_valid_date "$date_value" || return 1
    local -a parts; read -ra parts <<< "$(date_parts "$date_value")"
    local year="${parts[0]}"
    local month="${parts[1]}"
    local day="${parts[2]}"
    local month_offsets=(0 0 31 59 90 120 151 181 212 243 273 304 334)
    local ordinal
    ordinal=$(days_before_year "$year")
    ordinal=$((ordinal + month_offsets[month] + day))
    if [ "$month" -gt 2 ] && is_leap_year "$year"; then
        ordinal=$((ordinal + 1))
    fi
    echo "$ordinal"
}

ordinal_to_date() {
    local ordinal="$1"
    local max_ordinal
    max_ordinal=$(date_to_ordinal "9999-12-31")
    [[ "$ordinal" =~ ^[0-9]+$ ]] && [ "$ordinal" -ge 1 ] && [ "$ordinal" -le "$max_ordinal" ] || return 1

    local low=1
    local high=9999
    local year=1
    while [ "$low" -le "$high" ]; do
        local middle=$(((low + high) / 2))
        local first_day=$(( $(days_before_year "$middle") + 1 ))
        if [ "$first_day" -le "$ordinal" ]; then
            year="$middle"
            low=$((middle + 1))
        else
            high=$((middle - 1))
        fi
    done

    local day_of_year=$((ordinal - $(days_before_year "$year")))
    local month=1
    local month_days
    while :; do
        month_days=$(get_days_in_month "$year" "$month")
        [ "$day_of_year" -le "$month_days" ] && break
        day_of_year=$((day_of_year - month_days))
        month=$((month + 1))
    done
    format_date "$year" "$month" "$day_of_year"
}

add_days_to_date() {
    local date_value="$1"
    local days="$2"
    [[ "$days" =~ ^-?[0-9]+$ ]] || return 1
    local ordinal
    ordinal=$(date_to_ordinal "$date_value") || return 1
    ordinal_to_date "$((ordinal + days))"
}

add_months_to_date() {
    local date_value="$1"
    local months="$2"
    local desired_day="${3:-}"
    local -a parts; read -ra parts <<< "$(date_parts "$date_value")"
    local year="${parts[0]}"
    local month="${parts[1]}"
    local day="${parts[2]}"

    if [ -n "$desired_day" ]; then
        day="$desired_day"
    fi

    local -a normalized; read -ra normalized <<< "$(normalize_year_month "$year" "$((month + months))")"
    year="${normalized[0]}"
    month="${normalized[1]}"
    day=$(clamp_day_to_month "$year" "$month" "$day")

    format_date "$year" "$month" "$day"
}

add_years_to_date() {
    local date_value="$1"
    local years="$2"
    local desired_month="${3:-}"
    local desired_day="${4:-}"
    local -a parts; read -ra parts <<< "$(date_parts "$date_value")"
    local year="${parts[0]}"
    local month="${parts[1]}"
    local day="${parts[2]}"

    year=$((year + years))
    if [ -n "$desired_month" ]; then
        month="$desired_month"
    fi
    if [ -n "$desired_day" ]; then
        day="$desired_day"
    fi
    day=$(clamp_day_to_month "$year" "$month" "$day")

    format_date "$year" "$month" "$day"
}

# 清屏只在交互终端、非 dumb、未设置 NO_COLOR 时进行（clear 输出的是控制序列）。
menu_clear() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then clear 2>/dev/null || true; fi
}

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
    raw=$(nft -j list table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null) || { echo 'null'; return 1; }
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

# ── 运行状态灾备与恢复 ────────────────────────────────────────────
# traffic_data.json：{schema:2, saved_at, monitors:{id:{in,out,quota_used}}}（原始字节）。
# 重启后 nft 计数丢失，按此文件恢复。任何读取失败都不会删除或清空该文件。

traffic_backup_values() {
    [ -s "$TRAFFIC_DATA_FILE" ] || { echo '{}'; return 0; }
    jq -c 'if .schema == 2 then (.monitors // {}) else {} end' "$TRAFFIC_DATA_FILE" 2>/dev/null || echo '{}'
}

# 写入灾备。$1 为 nft_read_values 的结果；只保留配置中存在的监控项。
traffic_backup_write() {
    local values="$1" ids
    ids=$(jq -c '.monitors | keys' "$CONFIG_FILE" 2>/dev/null) || return 1
    jq -n --argjson v "$values" --argjson ids "$ids" --arg at "$(date -u +%FT%TZ)" \
        '{schema: 2, saved_at: $at, monitors: ($v | with_entries(select(.key as $k | $ids | index($k))))}' |
        atomic_write "$TRAFFIC_DATA_FILE" 600
}

traffic_backup_save() {
    nft_table_exists || return 1
    traffic_backup_write "$(nft_read_values)"
}

traffic_backup_drop_monitor() {
    [ -s "$TRAFFIC_DATA_FILE" ] || return 0
    json_update "$TRAFFIC_DATA_FILE" 'del(.monitors[$id])' --arg id "$1"
}

# 规则缺失或与配置不一致时按配置重建（保留计数）。$1=quiet 时不打印。
runtime_ensure_nft() {
    local drift
    has_monitors || return 0
    drift=$(nft_runtime_drift 2>/dev/null) && return 0
    [ "${1:-}" = "quiet" ] || echo -e "${YELLOW}检测到 nftables 规则与配置不一致，正在按配置修复：${NC}\n$drift" >&2
    log_notification "nftables 规则漂移，已自动重建：$(tr '\n' ';' <<< "$drift")"
    nft_rebuild_all
}

# 完整恢复：nft 计数/配额/到期 + TC 限速。
restore_runtime() {
    local rc=0
    dog_lock || return 75
    runtime_ensure_nft quiet || rc=1
    stats_rebaseline_all || true
    if [ "$rc" -eq 0 ]; then
        tc_restore_all || rc=1
    fi
    dog_unlock
    dog_log_event runtime_restore "$rc"
    return "$rc"
}

# 开机恢复：只恢复 nft（TC 交给共享恢复服务）。
restore_runtime_nft_only() {
    local rc=0
    dog_lock || return 75
    runtime_ensure_nft quiet || rc=1
    stats_rebaseline_all || true
    dog_unlock
    dog_log_event runtime_restore "$rc" mode=nft-only
    return "$rc"
}

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

# ── 服务到期 ──────────────────────────────────────────────────────
# 到期日（北京时间）当天起，ptd_<id>_in/_out 链首插入 drop（comment "ptd_expired"），
# 覆盖该项全部端口的入站、出站和转发流量；规则引用端口映射，加减端口自动生效。
# 延期或取消后立即解除。每分钟 tick 检查一次，开机恢复时随整表重建。

monitor_set_expiry() {
    local id="$1" date="$2" rc=0
    if [ -n "$date" ] && ! is_valid_date "$date"; then
        dog_error "到期日格式应为 YYYY-MM-DD"
        return 1
    fi
    dog_lock || return 75
    config_update '.monitors[$id].expiry_date = $d' --arg id "$id" --arg d "$date" || rc=1
    [ "$rc" -eq 0 ] && { nft_sync_monitor "$id" || rc=1; }
    dog_unlock
    if monitor_is_expired "$id"; then
        dog_log_event expiry_apply "$rc" "id=$id"
    else
        dog_log_event expiry_clear "$rc" "id=$id"
    fi
    return "$rc"
}

# 对比配置与内核中的到期封锁状态，只同步不一致的监控项。
check_expirations() {
    local rt id want have failed=0
    rt=$(nft_runtime_json 2>/dev/null) || return 1
    [ "$rt" != "null" ] || return 1
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        want=false; monitor_is_expired "$id" && want=true
        have=$(jq -r --arg c "ptd_${id}_in" '(.chains[$c] // []) | any(. == "drop#ptd_expired")' <<< "$rt")
        [ "$want" = "$have" ] && continue
        if nft_sync_monitor "$id"; then
            if [ "$want" = "true" ]; then
                log_notification "监控项 $id（$(monitor_label "$id")）已到期，已封锁其端口流量"
                dog_log_event expiry_apply 0 "id=$id"
            else
                log_notification "监控项 $id（$(monitor_label "$id")）到期封锁已解除"
                dog_log_event expiry_clear 0 "id=$id"
            fi
        else
            failed=1
        fi
    done < <(monitor_ids)
    return "$failed"
}

monitor_expiry_label() {
    local id="$1" exp today days
    exp=$(mget "$id" .expiry_date "")
    [ -n "$exp" ] || return 1
    today=$(get_current_date)
    if date_le "$exp" "$today"; then
        echo "已到期:${exp}"
    else
        days=$(( $(date_to_ordinal "$exp") - $(date_to_ordinal "$today") ))
        echo "到期:${exp}(剩${days}天)"
    fi
}

# ── 周期重置 ──────────────────────────────────────────────────────
# 策略保存在 .monitors[id].reset_policy：
#   monthly{day} | interval_days{every,anchor_date} | interval_months{every,anchor_date,day}
#   yearly{month,day} | fixed_date{date} | none
# 运行时字段：next_reset_date、last_reset_date。
# 重置历史 reset_history.json：{id:[{due,at,in,out}]}，同一 due 只清零一次。

reset_policy_type() {
    local t
    t=$(mget "$1" .reset_policy.type none)
    case "$t" in monthly|interval_days|interval_months|yearly|fixed_date) echo "$t" ;; *) echo none ;; esac
}

monitor_has_auto_reset() {
    [ "$(reset_policy_type "$1")" != "none" ]
}

monitor_created_date() {
    local c
    c=$(mget "$1" .created_at "")
    if [[ "$c" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then echo "${c:0:10}"; else get_current_date; fi
}

calculate_monthly_next_date() {
    local day="$1"
    local from_date="$2"
    local -a parts; read -ra parts <<< "$(date_parts "$from_date")"
    local year="${parts[0]}"
    local month="${parts[1]}"
    local candidate_day
    candidate_day=$(clamp_day_to_month "$year" "$month" "$day")
    local candidate
    candidate=$(format_date "$year" "$month" "$candidate_day")

    if date_lt "$candidate" "$from_date"; then
        local -a next; read -ra next <<< "$(normalize_year_month "$year" "$((month + 1))")"
        year="${next[0]}"
        month="${next[1]}"
        candidate_day=$(clamp_day_to_month "$year" "$month" "$day")
        candidate=$(format_date "$year" "$month" "$candidate_day")
    fi

    echo "$candidate"
}

calculate_interval_days_next_date() {
    local anchor_date="$1"
    local every_days="$2"
    local from_date="$3"
    [[ "$every_days" =~ ^[0-9]+$ ]] && [ "$every_days" -ge 1 ] || return 1
    local anchor_ordinal
    local from_ordinal
    anchor_ordinal=$(date_to_ordinal "$anchor_date") || return 1
    from_ordinal=$(date_to_ordinal "$from_date") || return 1
    if [ "$anchor_ordinal" -ge "$from_ordinal" ]; then
        echo "$anchor_date"
        return
    fi
    local distance=$((from_ordinal - anchor_ordinal))
    local steps=$(((distance + every_days - 1) / every_days))
    ordinal_to_date "$((anchor_ordinal + steps * every_days))"
}

calculate_interval_months_next_date() {
    local anchor_date="$1"
    local every_months="$2"
    local desired_day="$3"
    local from_date="$4"
    [[ "$every_months" =~ ^[0-9]+$ ]] && [ "$every_months" -ge 1 ] || return 1
    if ! date_lt "$anchor_date" "$from_date"; then
        echo "$anchor_date"
        return
    fi

    local -a anchor_parts; read -ra anchor_parts <<< "$(date_parts "$anchor_date")"
    local -a from_parts; read -ra from_parts <<< "$(date_parts "$from_date")"
    local anchor_month_index=$((anchor_parts[0] * 12 + anchor_parts[1] - 1))
    local from_month_index=$((from_parts[0] * 12 + from_parts[1] - 1))
    local month_distance=$((from_month_index - anchor_month_index))
    local steps=$((month_distance / every_months))
    local candidate
    candidate=$(add_months_to_date "$anchor_date" "$((steps * every_months))" "$desired_day")
    if date_lt "$candidate" "$from_date"; then
        candidate=$(add_months_to_date "$anchor_date" "$(((steps + 1) * every_months))" "$desired_day")
    fi
    echo "$candidate"
}

calculate_yearly_next_date() {
    local month="$1"
    local day="$2"
    local from_date="$3"
    local -a parts; read -ra parts <<< "$(date_parts "$from_date")"
    local year="${parts[0]}"
    local candidate_day
    candidate_day=$(clamp_day_to_month "$year" "$month" "$day")
    local candidate
    candidate=$(format_date "$year" "$month" "$candidate_day")

    if date_lt "$candidate" "$from_date"; then
        year=$((year + 1))
        candidate_day=$(clamp_day_to_month "$year" "$month" "$day")
        candidate=$(format_date "$year" "$month" "$candidate_day")
    fi

    echo "$candidate"
}


# 从 from_date（含）起计算下一次重置日期。
monitor_compute_next_reset() {
    local id="$1" from="${2:-$(get_current_date)}" type every anchor day month
    type=$(reset_policy_type "$id")
    case "$type" in
        monthly)
            day=$(mget "$id" .reset_policy.day 1)
            calculate_monthly_next_date "$day" "$from" ;;
        interval_days)
            every=$(mget "$id" .reset_policy.every 30)
            anchor=$(mget "$id" .reset_policy.anchor_date "")
            is_valid_date "$anchor" || anchor=$(monitor_created_date "$id")
            calculate_interval_days_next_date "$anchor" "$every" "$from" ;;
        interval_months)
            every=$(mget "$id" .reset_policy.every 1)
            anchor=$(mget "$id" .reset_policy.anchor_date "")
            is_valid_date "$anchor" || anchor=$(monitor_created_date "$id")
            day=$(mget "$id" .reset_policy.day "${anchor:8:2}")
            calculate_interval_months_next_date "$anchor" "$every" "$((10#$day))" "$from" ;;
        yearly)
            calculate_yearly_next_date "$(mget "$id" .reset_policy.month 1)" "$(mget "$id" .reset_policy.day 1)" "$from" ;;
        fixed_date)
            mget "$id" .reset_policy.date "" ;;
        *) return 1 ;;
    esac
}

# 读取（必要时计算并保存）下一次重置日期。
monitor_next_reset() {
    local id="$1" next
    monitor_has_auto_reset "$id" || return 1
    next=$(mget "$id" .reset_policy.next_reset_date "")
    if ! is_valid_date "$next"; then
        local from
        from=$(get_current_date)
        [ "$(reset_policy_type "$id")" = "fixed_date" ] || from=$(add_days_to_date "$from" 1)
        next=$(monitor_compute_next_reset "$id" "$from") || return 1
        is_valid_date "$next" || return 1
        config_update '.monitors[$id].reset_policy.next_reset_date = $n' --arg id "$id" --arg n "$next" || return 1
    fi
    echo "$next"
}

# 设置新策略：$2 为策略 JSON；立即计算 next_reset_date。
monitor_set_reset_policy() {
    local id="$1" policy="$2" next=""
    config_update '.monitors[$id].reset_policy = $p' --arg id "$id" --argjson p "$policy" || return 1
    if monitor_has_auto_reset "$id"; then
        local from
        from=$(get_current_date)
        [ "$(reset_policy_type "$id")" = "fixed_date" ] || from=$(add_days_to_date "$from" 1)
        next=$(monitor_compute_next_reset "$id" "$from") || return 1
        config_update '.monitors[$id].reset_policy.next_reset_date = $n' --arg id "$id" --arg n "$next" || return 1
    fi
}

# 重置完成后推进日期：一次性策略改为 none。
monitor_advance_reset() {
    local id="$1" today="${2:-$(get_current_date)}" next
    if [ "$(reset_policy_type "$id")" = "fixed_date" ]; then
        config_update '.monitors[$id].reset_policy = {type: "none", last_reset_date: $d}' \
            --arg id "$id" --arg d "$today"
        return
    fi
    next=$(monitor_compute_next_reset "$id" "$(add_days_to_date "$today" 1)") || return 1
    config_update '.monitors[$id].reset_policy.last_reset_date = $l | .monitors[$id].reset_policy.next_reset_date = $n' \
        --arg id "$id" --arg l "$today" --arg n "$next"
}

monitor_reset_label() {
    local id="$1" next type
    next=$(monitor_next_reset "$id" 2>/dev/null) || return 1
    type=$(reset_policy_type "$id")
    case "$type" in
        monthly) echo "每月$(mget "$id" .reset_policy.day 1)日，下次${next}" ;;
        interval_days) echo "每$(mget "$id" .reset_policy.every 30)天，下次${next}" ;;
        interval_months) echo "每$(mget "$id" .reset_policy.every 1)个月，下次${next}" ;;
        yearly) echo "每年，下次${next}" ;;
        fixed_date) echo "${next}清零一次" ;;
    esac
}

# 当前计费周期起止（YYYY-MM-DD~YYYY-MM-DD 或 起点~未设置）。
monitor_cycle_range() {
    local id="$1" start next end
    start=$(mget "$id" .reset_policy.last_reset_date "")
    if ! is_valid_date "$start"; then
        start=$(mget "$id" .reset_policy.anchor_date "")
        is_valid_date "$start" && date_le "$start" "$(get_current_date)" || start=$(monitor_created_date "$id")
    fi
    if next=$(monitor_next_reset "$id" 2>/dev/null); then
        end=$(add_days_to_date "$next" -1)
        date_lt "$end" "$start" && end="$next"
        echo "${start}~${end}"
    else
        echo "${start}~不自动重置"
    fi
}

reset_history_has() {
    local id="$1" due="$2"
    [ -s "$RESET_HISTORY_FILE" ] || return 1
    jq -e --arg id "$id" --arg due "$due" 'any((.[$id] // [])[]; .due == $due)' "$RESET_HISTORY_FILE" >/dev/null 2>&1
}

reset_history_record() {
    local id="$1" due="$2" in_b="$3" out_b="$4"
    [ -s "$RESET_HISTORY_FILE" ] || echo '{}' | atomic_write "$RESET_HISTORY_FILE" 600
    json_update "$RESET_HISTORY_FILE" \
        '.[$id] = (((.[$id] // []) + [{due: $due, at: $at, in: $i, out: $o}]) | .[-24:])' \
        --arg id "$id" --arg due "$due" --arg at "$(date -u +%FT%TZ)" --argjson i "$in_b" --argjson o "$out_b"
}

reset_history_drop() {
    [ -s "$RESET_HISTORY_FILE" ] || return 0
    json_update "$RESET_HISTORY_FILE" 'del(.[$id])' --arg id "$1"
}

# 清零一个监控项的计数与配额。$2 为到期日（手动重置传 manual）。
reset_monitor() {
    local id="$1" due="${2:-manual}" cur in_b out_b used rc=0
    dog_lock || return 75
    stats_snapshot >/dev/null 2>&1 || true
    cur=$(nft_read_monitor "$id" 2>/dev/null || echo "0 0 0")
    read -r in_b out_b used <<< "$cur"
    if nft_reset_monitor "$id"; then
        reset_history_record "$id" "$due" "$in_b" "$out_b" || true
        stats_rebaseline "$id" 0 0 || true
        traffic_backup_save || true
        log_notification "监控项 $id（$(monitor_label "$id")）流量已重置（${due}），重置前 入站 $(format_bytes "$in_b") 出站 $(format_bytes "$out_b")（原始字节）"
    else
        rc=1
    fi
    dog_unlock
    dog_log_event traffic_reset "$rc" "id=$id"
    return "$rc"
}

# 检查并执行到期的自动重置（每分钟 tick 调用）。
check_due_resets() {
    local id today next failed=0
    today=$(get_current_date)
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        monitor_has_auto_reset "$id" || continue
        next=$(monitor_next_reset "$id" 2>/dev/null) || { failed=1; continue; }
        date_le "$next" "$today" || continue
        if reset_history_has "$id" "$next"; then
            # 已清零但日期推进失败：只补推进，避免重复清零。
            monitor_advance_reset "$id" "$today" || failed=1
            continue
        fi
        if reset_monitor "$id" "$next"; then
            monitor_advance_reset "$id" "$today" || failed=1
        else
            failed=1
        fi
    done < <(monitor_ids)
    return "$failed"
}

# 交互选择重置策略，结果 JSON 输出到 stdout（提示走 stderr）。
prompt_reset_policy() {
    local default_day="${1:-1}" choice day every anchor month date today
    today=$(get_current_date)
    while true; do
        {
            echo
            echo -e "${BLUE}=== 自动重置策略 ===${NC}"
            echo "1. 每月几号重置（默认每月${default_day}日）"
            echo "2. 每隔多少天重置"
            echo "3. 每隔多少个月重置"
            echo "4. 每年几月几号重置"
            echo "5. 指定日期清零一次"
            echo "0. 不自动重置"
        } >&2
        read -r -p "请选择(回车默认1) [0-5]: " choice
        case "$choice" in
            1|"")
                read -r -p "每月几号重置(回车默认${default_day}) [1-31]: " day
                day="${day:-$default_day}"
                validate_day_1_31 "$day" || { echo -e "${RED}日期必须是 1-31${NC}" >&2; continue; }
                jq -cn --argjson d "$day" '{type: "monthly", day: $d}'; return 0 ;;
            2|3)
                if [ "$choice" = 2 ]; then
                    read -r -p "每隔多少天重置 [1-3650]: " every
                    [[ "$every" =~ ^[0-9]+$ ]] && [ "$every" -ge 1 ] && [ "$every" -le 3650 ] || { echo -e "${RED}天数无效${NC}" >&2; continue; }
                else
                    read -r -p "每隔多少个月重置 [1-120]: " every
                    [[ "$every" =~ ^[0-9]+$ ]] && [ "$every" -ge 1 ] && [ "$every" -le 120 ] || { echo -e "${RED}月数无效${NC}" >&2; continue; }
                fi
                read -r -p "起算日期(回车默认今天 ${today}) [YYYY-MM-DD]: " anchor
                anchor="${anchor:-$today}"
                is_valid_date "$anchor" || { echo -e "${RED}日期格式应为 YYYY-MM-DD${NC}" >&2; continue; }
                if [ "$choice" = 2 ]; then
                    jq -cn --argjson e "$every" --arg a "$anchor" '{type: "interval_days", every: $e, anchor_date: $a}'
                else
                    read -r -p "每次按几号重置(回车默认 $((10#${anchor:8:2}))) [1-31]: " day
                    day="${day:-$((10#${anchor:8:2}))}"
                    validate_day_1_31 "$day" || { echo -e "${RED}日期必须是 1-31${NC}" >&2; continue; }
                    jq -cn --argjson e "$every" --arg a "$anchor" --argjson d "$day" \
                        '{type: "interval_months", every: $e, anchor_date: $a, day: $d}'
                fi
                return 0 ;;
            4)
                read -r -p "每年几月 [1-12]: " month
                read -r -p "几号 [1-31]: " day
                validate_month_1_12 "$month" && validate_day_1_31 "$day" || { echo -e "${RED}月份或日期无效${NC}" >&2; continue; }
                jq -cn --argjson m "$month" --argjson d "$day" '{type: "yearly", month: $m, day: $d}'; return 0 ;;
            5)
                read -r -p "清零日期 [YYYY-MM-DD]: " date
                is_valid_date "$date" && ! date_lt "$date" "$today" || { echo -e "${RED}日期无效或早于今天${NC}" >&2; continue; }
                jq -cn --arg d "$date" '{type: "fixed_date", date: $d}'; return 0 ;;
            0) echo '{"type":"none"}'; return 0 ;;
            *) echo -e "${RED}请输入 0-5${NC}" >&2 ;;
        esac
    done
}

# ── 监控项增删改 ──────────────────────────────────────────────────
# 所有操作在 Dog 锁内执行：先校验 → 写配置 → 提交 nft 事务；nft 失败时恢复原配置。
# 端口变化只增删 nft 映射元素，因此流量计数与已用配额保持连续。

# 备份当前配置文本，供失败时恢复。
_config_snapshot() { cat "$CONFIG_FILE"; }
_config_restore() { printf '%s\n' "$1" | atomic_write "$CONFIG_FILE" 600; }

# 新建监控项。$1=规范化逗号串，$2=备注。成功时输出新 ID。
monitor_add() {
    local csv="$1" remark="${2:-}" ports conflict id snap now
    ports=$(ports_csv_to_json "$csv")
    dog_lock || return 75
    if conflict=$(find_port_conflict "$ports") && [ -n "$conflict" ]; then
        dog_unlock
        read -r cid cport cnew <<< "$conflict"
        dog_error "端口 $cnew 与监控项 $cid 的 $cport 重叠"
        return 1
    fi
    snap=$(_config_snapshot)
    id=$(next_monitor_id)
    now=$(beijing_date '+%Y-%m-%dT%H:%M:%S+08:00')
    if ! config_update '
        .monitors[$id] = {ports: $p, remark: $r, billing_mode: (.global.billing_mode // "double"),
                          quota: {enabled: false, monthly_limit: "unlimited"},
                          bandwidth_limit: {enabled: false, rate: "unlimited"},
                          reset_policy: {type: "none"}, expiry_date: "", created_at: $now} |
        .global.next_monitor_id = (($id | ltrimstr("m") | tonumber) + 1)
    ' --arg id "$id" --argjson p "$ports" --arg r "$remark" --arg now "$now"; then
        dog_unlock; return 1
    fi
    if ! nft_add_monitor "$id"; then
        _config_restore "$snap"
        dog_unlock
        dog_log_event monitor_add 1 "id=$id" "ports=$csv"
        return 1
    fi
    stats_rebaseline "$id" 0 0 || true
    dog_unlock
    dog_log_event monitor_add 0 "id=$id" "ports=$csv"
    echo "$id"
}

monitor_remove() {
    local id="$1" rc=0 snap
    dog_lock || return 75
    monitor_exists "$id" || { dog_unlock; dog_error "监控项 $id 不存在"; return 1; }
    stats_snapshot >/dev/null 2>&1 || true
    snap=$(_config_snapshot)
    if monitor_tc_rate "$id" >/dev/null; then
        # 拿不到共享 TC 锁就中止：否则配置删掉了、内核里留下孤儿类。
        begin_tc_update || { dog_unlock; dog_error "无法取得 TC 锁，未删除 $id"; return 1; }
        tc_remove_monitor_locked "$id" || true
        tc_write_interop "$id" || true
        finish_tc_update
    fi
    if ! nft_remove_monitor "$id"; then
        dog_unlock; dog_log_event monitor_remove 1 "id=$id"; return 1
    fi
    if ! config_update 'del(.monitors[$id])' --arg id "$id"; then
        _config_restore "$snap"; nft_rebuild_all || true
        dog_unlock; dog_log_event monitor_remove 1 "id=$id"; return 1
    fi
    stats_drop_monitor "$id" || true
    traffic_backup_drop_monitor "$id" || true
    reset_history_drop "$id" || true
    tc_write_interop || true
    dog_unlock
    dog_log_event monitor_remove "$rc" "id=$id"
    return "$rc"
}

# 修改端口。$2=要加的逗号串，$3=要删的逗号串，$4=整组替换的逗号串（非空时忽略 2/3）。
monitor_edit_ports() {
    local id="$1" add_csv="${2:-}" del_csv="${3:-}" set_csv="${4:-}" old new tmp conflict snap missing
    dog_lock || return 75
    monitor_exists "$id" || { dog_unlock; dog_error "监控项 $id 不存在"; return 1; }
    old=$(jq -c --arg id "$id" '.monitors[$id].ports' "$CONFIG_FILE")
    if [ -n "$set_csv" ]; then
        new=$(ports_csv_to_json "$set_csv")
    else
        new="$old"
        if [ -n "$del_csv" ]; then
            tmp=$(ports_csv_to_json "$del_csv")
            missing=$(jq -rn --argjson a "$tmp" --argjson b "$old" '$a - $b | join(",")')
            if [ -n "$missing" ]; then
                dog_unlock
                dog_error "监控项 $id 不包含成员：$missing（端口段需按原样整体删除，如 8000-8010）"
                return 1
            fi
            new=$(ports_json_minus "$new" "$tmp")
        fi
        [ -n "$add_csv" ] && new=$(ports_json_union "$new" "$(ports_csv_to_json "$add_csv")")
    fi
    if [ "$(jq 'length' <<< "$new")" -eq 0 ]; then
        dog_unlock
        dog_error "监控项至少保留一个端口；如需移除整个监控项，请使用删除"
        return 1
    fi
    if ! new=$(ports_json_normalize "$new"); then
        dog_unlock; return 1
    fi
    if conflict=$(find_port_conflict "$new" "$id") && [ -n "$conflict" ]; then
        dog_unlock
        read -r cid cport cnew <<< "$conflict"
        dog_error "端口 $cnew 与监控项 $cid 的 $cport 重叠"
        return 1
    fi
    if [ "$new" = "$old" ]; then
        dog_unlock; echo "端口未变化"; return 0
    fi
    snap=$(_config_snapshot)
    config_update '.monitors[$id].ports = $p' --arg id "$id" --argjson p "$new" || { dog_unlock; return 1; }
    if ! nft_change_ports "$id" "$old" "$new"; then
        _config_restore "$snap"
        dog_unlock
        dog_log_event monitor_edit 1 "id=$id"
        return 1
    fi
    tc_refresh_monitor_ports "$id" || log_notification "监控项 $id 端口已更新，但入向限速过滤器刷新失败，请运行 dog --repair"
    tc_write_interop || true
    dog_unlock
    dog_log_event monitor_edit 0 "id=$id" "ports=$(jq -r 'join(",")' <<< "$new")"
}

# 拆分：把 $2（成员逗号串）移到新监控项。$3=备注，$4=copy 时复制配额/重置/到期设置。
monitor_split() {
    local id="$1" move_csv="$2" remark="${3:-}" copy="${4:-}" old move rest new_id snap rt now missing
    dog_lock || return 75
    monitor_exists "$id" || { dog_unlock; dog_error "监控项 $id 不存在"; return 1; }
    old=$(jq -c --arg id "$id" '.monitors[$id].ports' "$CONFIG_FILE")
    move=$(ports_csv_to_json "$move_csv")
    missing=$(jq -rn --argjson a "$move" --argjson b "$old" '$a - $b | join(",")')
    if [ -n "$missing" ]; then
        dog_unlock; dog_error "监控项 $id 不包含成员：$missing"; return 1
    fi
    rest=$(ports_json_minus "$old" "$move")
    if [ "$(jq 'length' <<< "$rest")" -eq 0 ]; then
        dog_unlock; dog_error "拆分后原监控项不能为空"; return 1
    fi
    snap=$(_config_snapshot)
    new_id=$(next_monitor_id)
    now=$(beijing_date '+%Y-%m-%dT%H:%M:%S+08:00')
    config_update '
        .monitors[$id] as $src |
        .monitors[$id].ports = $rest |
        .monitors[$nid] = {ports: $move, remark: $r, billing_mode: ($src.billing_mode // "double"),
            quota: (if $copy then ($src.quota // {enabled: false, monthly_limit: "unlimited"}) else {enabled: false, monthly_limit: "unlimited"} end),
            bandwidth_limit: {enabled: false, rate: "unlimited"},
            reset_policy: (if $copy then ($src.reset_policy // {type: "none"}) else {type: "none"} end),
            expiry_date: (if $copy then ($src.expiry_date // "") else "" end), created_at: $now} |
        .global.next_monitor_id = (($nid | ltrimstr("m") | tonumber) + 1)
    ' --arg id "$id" --arg nid "$new_id" --argjson rest "$rest" --argjson move "$move" \
      --arg r "$remark" --arg now "$now" --argjson copy "$([ "$copy" = copy ] && echo true || echo false)" ||
        { dog_unlock; return 1; }
    rt=$(nft_runtime_json 2>/dev/null || echo null)
    if [ "$rt" = "null" ] || ! {
            nft_render_elements delete "$id" "$move" "$(monitor_tc_mark "$id" >/dev/null && echo with_mark)"
            nft_render_monitor "$new_id" 0 0 0
        } | nft_apply; then
        _config_restore "$snap"
        dog_unlock; dog_log_event monitor_split 1 "id=$id"; return 1
    fi
    stats_rebaseline "$new_id" 0 0 || true
    tc_refresh_monitor_ports "$id" || true
    tc_write_interop || true
    dog_unlock
    dog_log_event monitor_split 0 "id=$id" "ports=$(jq -r 'join(",")' <<< "$move")"
    echo "$new_id"
}

# 合并：把 $1 并入 $2。计数与已用配额相加，日统计按日期相加；$2 的配额/限速/到期设置保留。
monitor_merge() {
    local src="$1" dst="$2" snap rt sv dv si so su di dout du merged src_tc=false
    [ "$src" != "$dst" ] || { dog_error "不能合并到自身"; return 1; }
    dog_lock || return 75
    monitor_exists "$src" && monitor_exists "$dst" || { dog_unlock; dog_error "监控项不存在"; return 1; }
    stats_snapshot >/dev/null 2>&1 || true
    rt=$(nft_runtime_json 2>/dev/null || echo null)
    [ "$rt" != "null" ] || { dog_unlock; dog_error "nftables 规则缺失，请先运行 dog --repair"; return 1; }
    sv=$(nft_read_monitor "$src" 2>/dev/null || echo "0 0 0"); read -r si so su <<< "$sv"
    dv=$(nft_read_monitor "$dst" 2>/dev/null || echo "0 0 0"); read -r di dout du <<< "$dv"
    monitor_tc_rate "$src" >/dev/null && src_tc=true
    snap=$(_config_snapshot)
    merged=$(jq -c --arg s "$src" --arg d "$dst" '.monitors[$d].ports + .monitors[$s].ports' "$CONFIG_FILE")
    merged=$(ports_json_normalize "$merged") || { dog_unlock; return 1; }
    config_update '.monitors[$d].ports = $p | del(.monitors[$s])' \
        --arg s "$src" --arg d "$dst" --argjson p "$merged" || { dog_unlock; return 1; }
    if ! {
            nft_render_remove_monitor "$src" "$rt"
            nft_render_sync_monitor "$dst" $((si + di)) $((so + dout)) $((su + du)) "$rt"
        } | nft_apply; then
        _config_restore "$snap"
        dog_unlock; dog_log_event monitor_merge 1 "id=$dst"; return 1
    fi
    if [ "$src_tc" = "true" ] && begin_tc_update; then
        # 合并后源监控项已不在配置中；若锁暂不可得，孤儿类由下次 --repair 清理。
        tc_remove_monitor_locked "$src" || true
        tc_write_interop "$src" || true
        finish_tc_update
    fi
    tc_refresh_monitor_ports "$dst" || true
    stats_merge_monitor "$src" "$dst" || true
    stats_rebaseline "$dst" $((si + di)) $((so + dout)) || true
    traffic_backup_save || true
    reset_history_drop "$src" || true
    tc_write_interop || true
    dog_unlock
    dog_log_event monitor_merge 0 "id=$dst"
}

monitor_set_remark() {
    local id="$1" remark="$2"
    [ "${#remark}" -le 64 ] || { dog_error "备注最长 64 个字符"; return 1; }
    config_update '.monitors[$id].remark = $r' --arg id "$id" --arg r "$remark"
}

# 设置配额：$2 为 "240GB" 之类或 0（取消）。
monitor_set_quota() {
    local id="$1" limit="$2" rc=0
    if [ "$limit" != "0" ]; then
        validate_quota "$limit" || { dog_error "配额格式无效，示例：500GB、1.5TB、800MB"; return 1; }
        limit="${limit^^}"
    fi
    dog_lock || return 75
    if [ "$limit" = "0" ]; then
        config_update '.monitors[$id].quota.enabled = false | .monitors[$id].quota.monthly_limit = "unlimited"' --arg id "$id" || rc=1
    else
        config_update '.monitors[$id].quota.enabled = true | .monitors[$id].quota.monthly_limit = $l' \
            --arg id "$id" --arg l "$limit" || rc=1
    fi
    [ "$rc" -eq 0 ] && { nft_sync_monitor "$id" || rc=1; }
    dog_unlock
    dog_log_event quota_apply "$rc" "id=$id"
    return "$rc"
}

# 计费模式：double（入站+出站，各×2，与上游一致）| single（入站+出站，×1）。
# 计数器只记原始字节，切换模式只改倍率与配额阈值，不改写计数。
monitor_set_billing() {
    local id="$1" mode="$2" rc=0
    case "$mode" in single|double) ;; *) dog_error "计费模式只能是 single 或 double"; return 1 ;; esac
    dog_lock || return 75
    config_update '.monitors[$id].billing_mode = $m' --arg id "$id" --arg m "$mode" || rc=1
    [ "$rc" -eq 0 ] && { nft_sync_monitor "$id" || rc=1; }
    dog_unlock
    dog_log_event config_update "$rc" "id=$id" "mode=$mode"
    return "$rc"
}

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

begin_tc_update() {
    if [ "$TC_SHARED_LOCK_DEPTH" -gt 0 ]; then
        TC_SHARED_LOCK_DEPTH=$((TC_SHARED_LOCK_DEPTH + 1))
        return 0
    fi

    mkdir -p "$(dirname "$TC_SHARED_LOCK_FILE")" || return 1
    exec 9>"$TC_SHARED_LOCK_FILE" || return 1
    if ! flock -w 15 9; then
        exec 9>&-
        return 1
    fi
    TC_SHARED_LOCK_DEPTH=1
    TC_UPDATE_MIGRATED_LEGACY_TBF=false
    TC_UPDATE_LEGACY_TBF_RATE=""
}

finish_tc_update() {
    [ "$TC_SHARED_LOCK_DEPTH" -gt 0 ] || return 0
    TC_SHARED_LOCK_DEPTH=$((TC_SHARED_LOCK_DEPTH - 1))
    if [ "$TC_SHARED_LOCK_DEPTH" -eq 0 ]; then
        TC_UPDATE_MIGRATED_LEGACY_TBF=false
        TC_UPDATE_LEGACY_TBF_RATE=""
        flock -u 9 2>/dev/null || true
        exec 9>&-
    fi
}

# 端口段与端口组走同一条 TC 限速路径：nft 侧按端口打 meta mark，tc 侧用一条 fw
# 过滤器按 mark 归入同一个 class。单端口则走 u32/flower 精确匹配。
# 组内成员既可以是单端口也可以是端口段，靠 port_selectors 逐条展开。

# burst速率突发计算
# 注意：不要照搬上游的 10ms/64KB 公式。burst 是相对 class **rate** 的桶，而本项目
# 端口类的 rate 固定为 TC_PORT_CLASS_RATE(1kbit)、只有 ceil 承载限速值，内核会按 rate
# 归一化 burst（实测：rate 1kbit 下传 6250000 显示 6Kb、传 64k 显示 31176b；rate 500Mbit
# 下传 6250000 则原样显示）。上游用 rate=ceil=限速值 的结构，其公式在这里不适用，照搬
# 反而会让高速率下的实际突发从 6Kb 变成 31176b，比原来更宽松。
calculate_tc_burst() {
    local base_rate=$1
    local rate_bytes_per_sec=$((base_rate * 1000 / 8))
    local burst_by_formula=$((rate_bytes_per_sec / 20))  # 50ms缓冲
    local min_burst=$((2 * 1500))                        # 2个MTU最小值

    if [ $burst_by_formula -gt $min_burst ]; then
        echo $burst_by_formula
    else
        echo $min_burst
    fi
}

format_tc_burst() {
    local burst_bytes=$1
    if [ $burst_bytes -lt 1024 ]; then
        echo "${burst_bytes}"
    elif [ $burst_bytes -lt 1048576 ]; then
        echo "$((burst_bytes / 1024))k"
    else
        echo "$((burst_bytes / 1048576))m"
    fi
}

parse_tc_rate_to_kbps() {
    local total_limit="$1"
    case "$total_limit" in
        *gbit) echo $(( ${total_limit%gbit} * 1000000 )) ;;
        *mbit) echo $(( ${total_limit%mbit} * 1000 )) ;;
        *) echo "${total_limit%kbit}" ;;
    esac
}

# 将用户输入的带宽值(Kbps/Mbps/Gbps)转换为TC格式(kbit/mbit/gbit)

# Dog 与 NTC 共用同一个恢复入口和同一个 systemd oneshot，避免两边各自抢 root。
tc_recovery_systemd_available() {
    command -v "$TC_RECOVERY_SYSTEMCTL" >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

tc_recovery_unit_is_owned() {
    [ -f "$TC_RECOVERY_UNIT_FILE" ] &&
        grep -Fqx '# traffic-tools-tc-recovery-v1' "$TC_RECOVERY_UNIT_FILE" 2>/dev/null
}

tc_recovery_runner_is_owned() {
    [ -f "$TC_RECOVERY_RUNNER" ] &&
        grep -Fqx '# traffic-tools-tc-recovery-v1' "$TC_RECOVERY_RUNNER" 2>/dev/null
}

install_tc_recovery_service_files() {
    local runner_dir unit_dir runner_tmp unit_tmp
    runner_dir=$(dirname "$TC_RECOVERY_RUNNER")
    unit_dir=$(dirname "$TC_RECOVERY_UNIT_FILE")
    runner_tmp="${TC_RECOVERY_RUNNER}.tmp.$$"
    unit_tmp="${TC_RECOVERY_UNIT_FILE}.tmp.$$"

    if [ -e "$TC_RECOVERY_RUNNER" ] && ! tc_recovery_runner_is_owned; then
        echo "共享 TC 恢复入口已被其他文件占用: $TC_RECOVERY_RUNNER" >&2
        return 1
    fi
    if [ -e "$TC_RECOVERY_UNIT_FILE" ] && ! tc_recovery_unit_is_owned; then
        echo "共享 TC 恢复服务名已被其他 unit 占用: $TC_RECOVERY_UNIT_FILE" >&2
        return 1
    fi
    mkdir -p "$runner_dir" || return 1
    if ! cat > "$runner_tmp" <<'EOF'
#!/bin/bash
# traffic-tools-tc-recovery-v1
set -euo pipefail

mode="${1:---auto}"
case "$mode" in
    --auto|--manual) ;;
    *) echo "usage: $0 [--auto|--manual]" >&2; exit 2 ;;
esac

dog_script=/usr/local/bin/port-traffic-dog.sh
dog_config=/etc/port-traffic-dog/config.json
ntc_monitor=/etc/trafficcop-lite/trafficcop-lite-monitor.sh
ntc_config=/etc/trafficcop-lite/traffic_monitor_config.txt
handled=false
result=0

# 入口在而配置不可读属于异常：必须报出来，不能静默跳过恢复。
# 此模板由 dog 与 ntc 共用，两边必须逐字一致，否则后运行的一方会覆盖先运行的一方。
if [ -r "$dog_script" ]; then
    if [ -r "$dog_config" ]; then
        bash "$dog_script" --recover-tc "$mode" || result=1
    else
        echo "port-traffic-dog 已安装但配置不可读，跳过 TC 恢复: $dog_config" >&2
        result=1
    fi
    handled=true
fi
if [ -r "$ntc_monitor" ]; then
    if [ -r "$ntc_config" ]; then
        bash "$ntc_monitor" --tc-recover-owned "$mode" || result=1
    else
        echo "trafficcop-lite 已安装但配置不可读，跳过 TC 恢复: $ntc_config" >&2
        result=1
    fi
    handled=true
fi

$handled || exit 0
exit "$result"
EOF
    then
        rm -f "$runner_tmp"
        return 1
    fi
    chmod 755 "$runner_tmp" || { rm -f "$runner_tmp"; return 1; }
    if ! cmp -s "$runner_tmp" "$TC_RECOVERY_RUNNER"; then
        mv -f "$runner_tmp" "$TC_RECOVERY_RUNNER" || { rm -f "$runner_tmp"; return 1; }
    else
        rm -f "$runner_tmp"
    fi

    tc_recovery_systemd_available || return 0
    mkdir -p "$unit_dir" || return 1
    if ! cat > "$unit_tmp" <<EOF
# traffic-tools-tc-recovery-v1
[Unit]
Description=Recover Dog and TrafficCop Lite unified HTB
Wants=network-online.target
After=network-online.target vnstat.service

[Service]
Type=oneshot
ExecStart=$TC_RECOVERY_RUNNER --auto

[Install]
WantedBy=multi-user.target
EOF
    then
        rm -f "$unit_tmp"
        return 1
    fi
    chmod 644 "$unit_tmp" || { rm -f "$unit_tmp"; return 1; }
    if ! cmp -s "$unit_tmp" "$TC_RECOVERY_UNIT_FILE"; then
        mv -f "$unit_tmp" "$TC_RECOVERY_UNIT_FILE" || { rm -f "$unit_tmp"; return 1; }
    else
        rm -f "$unit_tmp"
    fi
    "$TC_RECOVERY_SYSTEMCTL" daemon-reload >/dev/null 2>&1
}

tc_auto_recovery_state() {
    if ! tc_recovery_systemd_available; then
        echo "不可用（当前系统未运行 systemd）"
    elif [ -e "$TC_RECOVERY_UNIT_FILE" ] && ! tc_recovery_unit_is_owned; then
        echo "冲突（同名 unit 不属于 Dog/NTC）"
    elif [ -e "$TC_RECOVERY_RUNNER" ] && ! tc_recovery_runner_is_owned; then
        echo "冲突（恢复入口不属于 Dog/NTC）"
    elif [ -e "$TC_RECOVERY_UNIT_FILE" ] && [ ! -e "$TC_RECOVERY_RUNNER" ]; then
        echo "损坏（恢复入口缺失）"
    elif [ ! -e "$TC_RECOVERY_UNIT_FILE" ]; then
        echo "未启用"
    elif "$TC_RECOVERY_SYSTEMCTL" is-enabled --quiet "$TC_RECOVERY_SERVICE" 2>/dev/null; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

enable_tc_auto_recovery() {
    tc_recovery_systemd_available || {
        echo -e "${RED}当前系统未运行 systemd，无法启用开机自动恢复。${NC}"
        return 1
    }
    install_tc_recovery_service_files || return 1
    "$TC_RECOVERY_SYSTEMCTL" enable "$TC_RECOVERY_SERVICE" >/dev/null
}

disable_tc_auto_recovery() {
    tc_recovery_systemd_available || return 0
    [ ! -e "$TC_RECOVERY_UNIT_FILE" ] && return 0
    if ! tc_recovery_unit_is_owned; then
        echo "同名恢复 unit 不属于 Dog/NTC，拒绝停用: $TC_RECOVERY_UNIT_FILE" >&2
        return 1
    fi
    "$TC_RECOVERY_SYSTEMCTL" disable "$TC_RECOVERY_SERVICE" >/dev/null 2>&1
}

cleanup_tc_recovery_files_if_unused() {
    if { [ -r /usr/local/bin/port-traffic-dog.sh ] && [ -r /etc/port-traffic-dog/config.json ]; } ||
       { [ -r /etc/trafficcop-lite/trafficcop-lite-monitor.sh ] && [ -r /etc/trafficcop-lite/traffic_monitor_config.txt ]; }; then
        return 0
    fi
    if [ -e "$TC_RECOVERY_UNIT_FILE" ]; then
        if ! tc_recovery_unit_is_owned; then
            echo "同名恢复 unit 不属于 Dog/NTC，已保留且未调用 systemctl: $TC_RECOVERY_UNIT_FILE" >&2
            return 1
        fi
        if tc_recovery_systemd_available; then
            "$TC_RECOVERY_SYSTEMCTL" disable --now "$TC_RECOVERY_SERVICE" >/dev/null 2>&1 || return 1
        fi
        rm -f "$TC_RECOVERY_UNIT_FILE" || return 1
    fi
    if tc_recovery_runner_is_owned; then
        rm -f "$TC_RECOVERY_RUNNER" || return 1
    fi
    if tc_recovery_systemd_available; then
        "$TC_RECOVERY_SYSTEMCTL" daemon-reload >/dev/null 2>&1 || return 1
    fi
}

dog_tc_status_label() {
    local status_output=""
    status_output=$(dog_tc_status 2>/dev/null || true)
    case "$status_output" in
        TC_STATUS=OK*) echo "正常" ;;
        TC_STATUS=IDLE*) echo "空闲" ;;
        *REASON=external-root-qdisc*) echo "冲突（外部/未知 TC）" ;;
        TC_STATUS=CONFLICT*) echo "异常（自身规则已失效）" ;;
        *) echo "无法检测" ;;
    esac
}

dog_tc_status_kind() {
    case "${1:-}" in
        TC_STATUS=OK*) echo "ok" ;;
        TC_STATUS=IDLE*) echo "idle" ;;
        TC_STATUS=CONFLICT*) echo "conflict" ;;
        *) echo "error" ;;
    esac
}

show_tc_takeover_warning() {
    echo -e "${RED}检测到当前 TC 配置可能已被其他程序修改。${NC}"
    echo "继续操作将删除当前冲突的 TC/qdisc 配置，"
    echo "并只重新建立 Dog/NTC 体系自身管理的规则。"
    echo "其他程序创建的 TC 配置不会被保留。"
    echo
    echo -e "${YELLOW}如果其他 TC 管理脚本或服务仍然存在，其之后再次启动或重启时，"
    echo -e "仍可能覆盖 Dog/NTC。建议卸载、关闭或禁用这些冲突程序。${NC}"
}

show_tc_auto_recovery_notice() {
    echo "启用后，恢复服务会在开机网络就绪时检查 Dog/NTC TC 规则。"
    echo "规则正常或当前没有需要恢复的规则时，不会修改 TC。"
    echo "自动恢复只会在 root qdisc 为空闲/默认状态时恢复已有 Dog/NTC 规则。"
    echo "检测到外部或未知 TC 时不会自动删除；必须由用户确认后手动重建。"
}

confirm_enable_tc_auto_recovery() {
    local confirm=""

    show_tc_auto_recovery_notice
    echo
    read -r -p "确认启用请输入 ENABLE: " confirm
    if [ "$confirm" != "ENABLE" ]; then
        echo "未启用。"
        return 0
    fi
    if enable_tc_auto_recovery; then
        echo -e "${GREEN}开机自动恢复已启用。${NC}"
    else
        echo -e "${RED}开机自动恢复启用失败。${NC}"
        return 1
    fi
}

run_shared_tc_recovery() {
    local mode="${1:---manual}"
    install_tc_recovery_service_files || return 1
    bash "$TC_RECOVERY_RUNNER" "$mode"
}

manage_tc_recovery() {
    local tc_choice=""
    local confirm=""
    local status_output=""
    local status_kind=""

    menu_clear
    echo -e "${BLUE}=== TC 冲突处理 / 自动恢复 ===${NC}"
    echo "TC 状态: $(dog_tc_status_label)"
    echo "自动恢复: $(tc_auto_recovery_state)"
    echo "恢复方式: 单一 systemd oneshot；启用后在网络就绪时执行一次"
    echo
    echo "1. 检测并按需重建 Dog/NTC 规则"
    echo "2. 检测并按需重建，同时启用开机自动恢复"
    echo "3. 启用开机自动恢复"
    echo "4. 关闭开机自动恢复"
    echo "0. 返回主菜单"
    echo
    read -r -p "请选择操作 [0-4]: " tc_choice
    case "$tc_choice" in
        1|2)
            status_output=$(dog_tc_status 2>/dev/null || true)
            status_kind=$(dog_tc_status_kind "$status_output")
            case "$status_kind" in
                ok)
                    echo -e "${GREEN}当前 TC 状态正常，无需强制重建。${NC}"
                    if [ "$tc_choice" = "2" ]; then
                        echo
                        confirm_enable_tc_auto_recovery || true
                    fi
                    ;;
                idle)
                    echo -e "${YELLOW}当前没有需要恢复的 Dog/NTC TC 规则。${NC}"
                    if [ "$tc_choice" = "2" ]; then
                        echo
                        confirm_enable_tc_auto_recovery || true
                    fi
                    ;;
                conflict)
                    show_tc_takeover_warning
                    echo
                    read -r -p "确认继续请输入 REBUILD: " confirm
                    if [ "$confirm" = "REBUILD" ] && run_shared_tc_recovery --manual; then
                        echo -e "${GREEN}TC 检测/重建完成。${NC}"
                        if [ "$tc_choice" = "2" ]; then
                            if enable_tc_auto_recovery; then
                                echo -e "${GREEN}开机自动恢复已启用。${NC}"
                            else
                                echo -e "${RED}TC 已重建，但开机自动恢复启用失败。${NC}"
                            fi
                        fi
                    elif [ "$confirm" != "REBUILD" ]; then
                        echo "已取消。"
                    else
                        echo -e "${RED}TC 重建失败，请运行 dog --self-check 查看详情。${NC}"
                    fi
                    ;;
                *)
                    echo -e "${RED}无法确认当前 TC 状态，未修改 qdisc。请先运行 dog --self-check。${NC}"
                    ;;
            esac
            ;;
        3)
            confirm_enable_tc_auto_recovery || true
            ;;
        4)
            if disable_tc_auto_recovery; then
                echo -e "${GREEN}开机自动恢复已关闭。${NC}"
            else
                echo -e "${RED}开机自动恢复关闭失败；现有启用状态未被确认改变。${NC}"
            fi
            ;;
        0|"") return 0 ;;
        *) echo -e "${RED}无效选择。${NC}" ;;
    esac
}

get_tc_root_owner_file() {
    echo "$CONFIG_DIR/tc-root-qdisc.owner"
}

mark_tc_root_owned() {
    local interface="$1"
    local machine_id=""
    [ -r /etc/machine-id ] && machine_id=$(tr -d '\r\n' < /etc/machine-id)
    local owner_file
    owner_file=$(get_tc_root_owner_file)
    # 归属标记写不进去就必须报出来：调用方靠它区分“自己的 HTB”和“别人的 HTB”。
    printf '%s|%s\n' "$interface" "$machine_id" > "$owner_file" || return 1
    chmod 600 "$owner_file" 2>/dev/null || true
}

tc_root_owner_marker_matches() {
    local interface="$1"
    local owner_file
    owner_file=$(get_tc_root_owner_file)
    [ -f "$owner_file" ] || return 1
    local recorded_interface recorded_machine_id machine_id=""
    IFS='|' read -r recorded_interface recorded_machine_id < "$owner_file" || return 1
    [ -r /etc/machine-id ] && machine_id=$(tr -d '\r\n' < /etc/machine-id)
    [ "$recorded_interface" = "$interface" ] && [ "$recorded_machine_id" = "$machine_id" ]
}

tc_state_file_is_secure() {
    local state_file="$1"
    local owner_uid
    local mode

    [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
    owner_uid=$(stat -c '%u' "$state_file" 2>/dev/null) || return 1
    [ "$owner_uid" = "$(id -u)" ] || return 1
    mode=$(stat -c '%a' "$state_file" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ $((8#$mode & 8#022)) -eq 0 ]
}

tc_state_unique_value() {
    local state_file="$1"
    local key="$2"
    local count
    count=$(grep -Ec "^${key}=" "$state_file" 2>/dev/null || true)
    [ "$count" -eq 1 ] || return 1
    grep "^${key}=" "$state_file" | cut -d'=' -f2-
}

tc_state_optional_unique_value() {
    local state_file="$1"
    local key="$2"
    local count
    count=$(grep -Ec "^${key}=" "$state_file" 2>/dev/null || true)
    [ "$count" -le 1 ] || return 1
    if [ "$count" -eq 1 ]; then
        grep "^${key}=" "$state_file" | cut -d'=' -f2-
    fi
    return 0
}

# 仅在 NTC 状态存在时读取其启用状态；配置缺失视为旧版/独立状态，异常配置则拒绝使用状态。
# 返回值：0=已禁用；1=未禁用或配置不存在；2=配置无法安全解释。
trafficcop_config_is_disabled() {
    local disabled

    [ -e "$TRAFFICCOP_CONFIG_FILE" ] || return 1
    tc_state_file_is_secure "$TRAFFICCOP_CONFIG_FILE" || return 2
    disabled=$(tc_state_optional_unique_value "$TRAFFICCOP_CONFIG_FILE" "DISABLED") || return 2
    case "$disabled" in
        true) return 0 ;;
        ""|false) return 1 ;;
        *) return 2 ;;
    esac
}

# 返回值：0=当前接口存在有效统一限速；1=无状态；2=状态无效；3=旧版状态；
# 4=其他接口；5=NTC 已明确禁用，残留状态不再授权恢复整机上限。
trafficcop_unified_state_rate() {
    local interface="$1"
    local schema
    local provider
    local state_interface
    local speed

    [ -e "$TRAFFICCOP_TC_STATE_FILE" ] || return 1
    local disabled_status=0
    trafficcop_config_is_disabled || disabled_status=$?
    case "$disabled_status" in
        0) return 5 ;;
        1) ;;
        *) return 2 ;;
    esac
    tc_state_file_is_secure "$TRAFFICCOP_TC_STATE_FILE" || return 2
    if ! schema=$(tc_state_unique_value "$TRAFFICCOP_TC_STATE_FILE" "SCHEMA" 2>/dev/null); then
        if ! grep -q '^SCHEMA=' "$TRAFFICCOP_TC_STATE_FILE" 2>/dev/null; then
            return 3
        fi
        return 2
    fi
    [ "$schema" = "$TC_INTEROP_SCHEMA" ] || return 2
    provider=$(tc_state_unique_value "$TRAFFICCOP_TC_STATE_FILE" "PROVIDER") || return 2
    [ "$provider" = "trafficcop-lite" ] || return 2
    state_interface=$(tc_state_unique_value "$TRAFFICCOP_TC_STATE_FILE" "INTERFACE") || return 2
    [[ "$state_interface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 2
    speed=$(tc_state_unique_value "$TRAFFICCOP_TC_STATE_FILE" "LIMIT_SPEED") || return 2
    [[ "$speed" =~ ^[1-9][0-9]*$ ]] || return 2
    [ "$state_interface" = "$interface" ] || return 4
    printf '%skbit\n' "$speed"
}

trafficcop_legacy_state_rate() {
    local interface="$1"
    local provider
    local state_interface
    local speed

    [ -e "$TRAFFICCOP_TC_STATE_FILE" ] || return 1
    tc_state_file_is_secure "$TRAFFICCOP_TC_STATE_FILE" || return 1
    ! grep -q '^SCHEMA=' "$TRAFFICCOP_TC_STATE_FILE" 2>/dev/null || return 1
    provider=$(tc_state_optional_unique_value "$TRAFFICCOP_TC_STATE_FILE" "PROVIDER") || return 1
    [ -z "$provider" ] || [ "$provider" = "trafficcop-lite" ] || return 1
    state_interface=$(tc_state_unique_value "$TRAFFICCOP_TC_STATE_FILE" "INTERFACE") || return 1
    [ "$state_interface" = "$interface" ] || return 1
    speed=$(tc_state_unique_value "$TRAFFICCOP_TC_STATE_FILE" "LIMIT_SPEED") || return 1
    [[ "$speed" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%skbit\n' "$speed"
}

tc_rate_from_qdisc_line() {
    local qdisc_line="$1"
    printf '%s\n' "$qdisc_line" |
        awk '{for (i=1; i<=NF; i++) if ($i == "rate") {print $(i+1); exit}}'
}

trafficcop_legacy_tbf_rate() {
    local interface="$1"
    local qdisc_line="$2"
    local expected_rate
    local recorded_qdisc
    local actual_rate
    local expected_bps
    local actual_bps

    grep -Eq '^qdisc tbf .* root([[:space:]]|$)' <<< "$qdisc_line" || return 1
    expected_rate=$(trafficcop_legacy_state_rate "$interface") || return 1
    recorded_qdisc=$(tc_state_optional_unique_value "$TRAFFICCOP_TC_STATE_FILE" "QDISC_LINE") || return 1
    if [ -n "$recorded_qdisc" ]; then
        [ "$recorded_qdisc" = "$qdisc_line" ] || return 1
    fi
    actual_rate=$(tc_rate_from_qdisc_line "$qdisc_line")
    expected_bps=$(normalize_tc_rate_to_bps "$expected_rate") || return 1
    actual_bps=$(normalize_tc_rate_to_bps "$actual_rate") || return 1
    [ "$actual_bps" -eq "$expected_bps" ] || return 1
    printf '%s\n' "$expected_rate"
}

tc_root_qdisc_line() {
    local qdisc_state
    qdisc_state=$(tc qdisc show dev "$1" root 2>/dev/null) || return 1
    awk 'NR == 1 { print }' <<< "$qdisc_state"
}

tc_root_matches_unified_contract() {
    local interface="$1"
    local qdisc_line
    local class_state
    qdisc_line=$(tc_root_qdisc_line "$interface") || return 1
    grep -Eq '^qdisc htb 1: root([[:space:]]|$)' <<< "$qdisc_line" || return 1
    grep -Eq ' default (0x)?30([[:space:]]|$)' <<< "$qdisc_line" || return 1
    class_state=$(tc class show dev "$interface" 2>/dev/null) || return 1
    grep -Eq '^class htb 1:1 root([[:space:]]|$)' <<< "$class_state" || return 1
    grep -Eq '^class htb 1:30 parent 1:1([[:space:]]|$)' <<< "$class_state"
}

tc_root_is_owned() {
    local interface="$1"
    tc_root_owner_marker_matches "$interface" || return 1
    tc_root_matches_unified_contract "$interface"
}

tc_root_is_managed() {
    local interface="$1"
    tc_root_matches_unified_contract "$interface" || return 1
    if tc_root_owner_marker_matches "$interface"; then
        return 0
    fi
    trafficcop_unified_state_rate "$interface" >/dev/null 2>&1
}

tc_root_qdisc_is_replaceable() {
    local qdisc_state="$1"
    local qdisc_type
    qdisc_type=$(printf '%s\n' "$qdisc_state" | awk 'NR == 1 {print $2}')
    case "$qdisc_type" in
        noqueue|fq_codel|pfifo_fast|mq|fq) return 0 ;;
        "")
            # 解析不出类型只可能是 tc 查询异常。当成“可替换”会删掉别人的 root qdisc。
            echo "无法识别 root qdisc 类型（tc 查询异常），按不可替换处理" >&2
            return 1
            ;;
        *) return 1 ;;
    esac
}

desired_tc_parent_rate() {
    local interface="$1"
    local rate
    local result=0
    rate=$(trafficcop_unified_state_rate "$interface" 2>/dev/null) || result=$?
    case "$result" in
        0) printf '%s\n' "$rate" ;;
        1|4|5) printf '%s\n' "$TC_PARENT_RATE" ;;
        3)
            if tc_root_owner_marker_matches "$interface" &&
               tc_root_matches_unified_contract "$interface"; then
                trafficcop_legacy_state_rate "$interface"
            else
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

tc_class_rate_and_ceil() {
    local interface="$1"
    local class_id="$2"
    local class_state
    class_state=$(tc class show dev "$interface" 2>/dev/null) || return 1
    awk -v class_id="$class_id" '
            $1 == "class" && $2 == "htb" && $3 == class_id {
                rate=""; ceil=""
                for (i=1; i<=NF; i++) {
                    if ($i == "rate") rate=$(i+1)
                    if ($i == "ceil") ceil=$(i+1)
                }
                if (ceil == "") ceil=rate
                if (rate != "") print rate, ceil
                exit
            }' <<< "$class_state"
}

rollback_legacy_trafficcop_tbf() {
    local interface="$1"
    [ "$TC_UPDATE_MIGRATED_LEGACY_TBF" = "true" ] || return 0
    [ -n "$TC_UPDATE_LEGACY_TBF_RATE" ] || return 1
    if tc qdisc replace dev "$interface" root tbf rate "$TC_UPDATE_LEGACY_TBF_RATE" \
        burst 32kbit latency 400ms 2>/dev/null; then
        rm -f "$(get_tc_root_owner_file)"
        TC_UPDATE_MIGRATED_LEGACY_TBF=false
        TC_UPDATE_LEGACY_TBF_RATE=""
        return 0
    fi
    log_notification "统一HTB迁移失败且无法恢复TrafficCop旧TBF: $interface"
    return 1
}

ensure_owned_tc_hierarchy_locked() {
    local interface="$1"
    local parent_rate=""
    local qdisc_state
    local qdisc_line
    local previous_parent_rate=""
    local previous_parent_ceil=""

    ENSURE_TC_ROOT_CREATED=false
    ENSURE_TC_ROOT_MIGRATED=false
    [ -n "$interface" ] || return 1
    if ! qdisc_state=$(tc qdisc show dev "$interface" 2>/dev/null); then
        log_notification "无法读取网卡TC根队列，已拒绝修改统一HTB: $interface"
        return 1
    fi
    qdisc_line=$(printf '%s\n' "$qdisc_state" | head -n 1)

    if grep -Eq '^qdisc tbf .* root([[:space:]]|$)' <<< "$qdisc_line"; then
        parent_rate=$(trafficcop_legacy_tbf_rate "$interface" "$qdisc_line" 2>/dev/null) || {
            log_notification "检测到无法确认归属的TBF根队列，已拒绝迁移: $interface"
            return 1
        }
        if ! tc qdisc replace dev "$interface" root handle 1: htb default 30 2>/dev/null; then
            log_notification "无法把TrafficCop旧TBF迁移为统一HTB: $interface"
            return 1
        fi
        ENSURE_TC_ROOT_MIGRATED=true
        TC_UPDATE_MIGRATED_LEGACY_TBF=true
        TC_UPDATE_LEGACY_TBF_RATE="$parent_rate"
    else
        parent_rate=$(desired_tc_parent_rate "$interface" 2>/dev/null) || {
            log_notification "TrafficCop TC状态无效，已拒绝修改统一HTB: $interface"
            return 1
        }
    fi
    normalize_tc_rate_to_bps "$parent_rate" >/dev/null 2>&1 || return 1

    if grep -Eq '^qdisc htb 1:' <<< "$qdisc_state"; then
        if ! tc_root_is_managed "$interface"; then
            tc_root_owner_marker_matches "$interface" && rm -f "$(get_tc_root_owner_file)"
            log_notification "检测到不属于Dog/TrafficCop统一协议的HTB根队列，已拒绝接管: $interface"
            return 1
        fi
        if ! read -r previous_parent_rate previous_parent_ceil < <(
            tc_class_rate_and_ceil "$interface" "1:1"
        ); then
            log_notification "无法读取统一HTB父类，已拒绝修改: $interface"
            return 1
        fi
    elif [ "$ENSURE_TC_ROOT_MIGRATED" != "true" ]; then
        if ! tc_root_qdisc_is_replaceable "$qdisc_state"; then
            log_notification "检测到不可安全替换的根qdisc，已拒绝创建统一HTB: $interface"
            return 1
        fi
        if ! tc qdisc replace dev "$interface" root handle 1: htb default 30 2>/dev/null; then
            log_notification "无法创建统一HTB根队列: $interface"
            return 1
        fi
        ENSURE_TC_ROOT_CREATED=true
    fi

    if ! tc class replace dev "$interface" parent 1: classid 1:1 htb \
        rate "$parent_rate" ceil "$parent_rate" 2>/dev/null; then
        if [ "$ENSURE_TC_ROOT_MIGRATED" = "true" ]; then
            rollback_legacy_trafficcop_tbf "$interface" >/dev/null 2>&1 || true
        elif [ "$ENSURE_TC_ROOT_CREATED" = "true" ]; then
            tc qdisc del dev "$interface" root handle 1: 2>/dev/null || true
            rm -f "$(get_tc_root_owner_file)"
        fi
        log_notification "无法创建或更新统一HTB父类: $interface"
        return 1
    fi
    if ! tc class replace dev "$interface" parent 1:1 classid 1:30 htb \
        rate "$TC_DEFAULT_CLASS_RATE" ceil "$parent_rate" 2>/dev/null; then
        if [ "$ENSURE_TC_ROOT_MIGRATED" = "true" ]; then
            rollback_legacy_trafficcop_tbf "$interface" >/dev/null 2>&1 || true
        elif [ "$ENSURE_TC_ROOT_CREATED" = "true" ]; then
            tc qdisc del dev "$interface" root handle 1: 2>/dev/null || true
            rm -f "$(get_tc_root_owner_file)"
        elif [ -n "$previous_parent_rate" ]; then
            tc class replace dev "$interface" parent 1: classid 1:1 htb \
                rate "$previous_parent_rate" ceil "$previous_parent_ceil" 2>/dev/null || true
        fi
        log_notification "无法创建统一HTB默认子类: $interface"
        return 1
    fi
    if ! tc_root_owner_marker_matches "$interface" && ! mark_tc_root_owned "$interface"; then
        if [ "$ENSURE_TC_ROOT_MIGRATED" = "true" ]; then
            rollback_legacy_trafficcop_tbf "$interface" >/dev/null 2>&1 || true
        elif [ "$ENSURE_TC_ROOT_CREATED" = "true" ]; then
            tc qdisc del dev "$interface" root handle 1: 2>/dev/null || true
        fi
        log_notification "无法记录统一HTB根队列归属，已撤销队列: $interface"
        return 1
    fi
}

ensure_owned_tc_hierarchy() {
    local result=0 interface="${1:-$(get_default_interface)}"
    begin_tc_update || return 1
    ensure_owned_tc_hierarchy_locked "$interface" || result=$?
    if [ "$result" -eq 0 ] && ip link show "$TC_IFB_DEVICE" >/dev/null 2>&1; then
        ensure_ifb_hierarchy_locked "$interface" || result=$?
    fi
    finish_tc_update
    return "$result"
}

# 拆掉入向链路：ifb0 上已无端口类、且 TrafficCop 未声明整机限速时才清理。
# 判据与物理网卡保持一致，避免误删 TrafficCop 正在使用的入向层级。
cleanup_ingress_shaping_if_unused_locked() {
    local interface="$1"
    local dev="$TC_IFB_DEVICE"

    [ -n "$interface" ] || return 0
    ip link show "$dev" >/dev/null 2>&1 || return 0

    # ifb0 的合法性从属物理网卡：物理网卡已不属于本脚本时不碰 ifb0
    tc_root_owner_marker_matches "$interface" || return 0

    # 物理网卡的统一 HTB 已经不在了（卸载流程会先删它），说明整条层级正在拆除，
    # 此时 ifb0 上的端口类只是残留，应当一并清掉；否则仍按"有消费者就不动"处理。
    if grep -q '^qdisc htb 1:' <<< "$(tc qdisc show dev "$interface" 2>/dev/null)"; then
        # 1:1 与 1:30 是统一层级的基础分类；其他分类表示端口入向限速仍在使用。
        local class_output
        class_output=$(tc class show dev "$dev" 2>/dev/null) || return 1
        if printf '%s\n' "$class_output" |
           awk '$1 == "class" && $2 == "htb" && $3 != "1:1" && $3 != "1:30" { found=1 } END { exit found ? 0 : 1 }'; then
            return 0
        fi

        local ntc_status=0
        trafficcop_unified_state_rate "$interface" >/dev/null 2>&1 || ntc_status=$?
        if [ "$ntc_status" -eq 0 ]; then
            return 0
        fi
        if [ -e "$TRAFFICCOP_TC_STATE_FILE" ] &&
           [ "$ntc_status" -ne 1 ] && [ "$ntc_status" -ne 4 ] && [ "$ntc_status" -ne 5 ]; then
            # NTC 状态存在但无法安全解释时宁可保留，也不删除它可能正在用的入向层级。
            return 1
        fi
    else
        # 物理网卡的根队列不是本脚本的统一 HTB。这里必须区分两种截然不同的情况：
        #   a) 根队列处于缺省/可替换状态（或已被卸载流程删除，show 不出内容）→ 属残留，清掉 ifb0；
        #   b) 被外部 qdisc 占用（tbf、别的 handle 的 htb 等）→ 说明 eth0 的 ingress 仍归我们，
        #      此时删 ifb0 会连带废掉自己的入向限速，必须原样保留。
        local root_qdisc_state
        root_qdisc_state=$(tc qdisc show dev "$interface" 2>/dev/null) || return 1
        if [ -n "$root_qdisc_state" ] && ! tc_root_qdisc_is_replaceable "$root_qdisc_state"; then
            return 0
        fi
    fi

    tc qdisc del dev "$dev" root 2>/dev/null || true
    tc qdisc del dev "$interface" ingress 2>/dev/null || true
    ip link set "$dev" down 2>/dev/null || true
    ip link del "$dev" 2>/dev/null || true
    return 0
}

cleanup_owned_tc_root_if_unused_locked() {
    local interface="${1:-$(get_default_interface)}"
    [ -n "$interface" ] && tc_root_is_owned "$interface" || return 0

    # 1:1 与 1:30 是统一层级的基础分类；其他分类或过滤器表示端口限速仍在使用。
    local class_output
    local filter_output
    class_output=$(tc class show dev "$interface" 2>/dev/null) || return 1
    if printf '%s\n' "$class_output" |
       awk '$1 == "class" && $2 == "htb" && $3 != "1:1" && $3 != "1:30" { found=1 } END { exit found ? 0 : 1 }'; then
        return 0
    fi
    filter_output=$(tc filter show dev "$interface" parent 1:0 2>/dev/null) || return 1
    if [ -n "$filter_output" ]; then
        return 0
    fi

    local ntc_status=0
    trafficcop_unified_state_rate "$interface" >/dev/null 2>&1 || ntc_status=$?
    if [ "$ntc_status" -eq 0 ]; then
        rm -f "$(get_tc_root_owner_file)"
        return 0
    fi
    if [ -e "$TRAFFICCOP_TC_STATE_FILE" ] &&
       [ "$ntc_status" -ne 1 ] && [ "$ntc_status" -ne 4 ] && [ "$ntc_status" -ne 5 ]; then
        # NTC 状态存在但无法安全解释时宁可保留基础层级，也不删除其全局限速。
        return 1
    fi

    if ! tc qdisc del dev "$interface" root handle 1: 2>/dev/null; then
        return 1
    fi
    # 顺序要紧：先清 ifb0（它要读归属标记），再删归属文件。
    cleanup_ingress_shaping_if_unused_locked "$interface" >/dev/null 2>&1 || true
    rm -f "$(get_tc_root_owner_file)"
}

cleanup_owned_tc_root_if_unused() {
    local result=0
    begin_tc_update || return 1
    cleanup_owned_tc_root_if_unused_locked "$@" || result=$?
    finish_tc_update
    return "$result"
}

ensure_ifb_device_locked() {
    if ! ip link show "$TC_IFB_DEVICE" >/dev/null 2>&1; then
        modprobe ifb numifbs=0 2>/dev/null || true
        ip link add "$TC_IFB_DEVICE" type ifb 2>/dev/null || true
    fi
    ip link set "$TC_IFB_DEVICE" up 2>/dev/null || true
    # ifb 是 NOARP 虚拟设备，operstate 恒为 UNKNOWN，只能判 UP flag
    grep -q "<.*UP.*>" <<< "$(ip link show "$TC_IFB_DEVICE" 2>/dev/null)"
}

ensure_ifb_hierarchy_locked() {
    local interface="$1"
    local dev="$TC_IFB_DEVICE"
    local qdisc_state
    local parent_rate

    tc_root_owner_marker_matches "$interface" || return 1

    ensure_ifb_device_locked || {
        log_notification "ifb0 创建失败，端口入向限速未生效"
        return 1
    }

    if ! qdisc_state=$(tc qdisc show dev "$dev" 2>/dev/null); then
        log_notification "无法读取 ifb0 根队列，已拒绝创建入向统一HTB"
        return 1
    fi
    if ! grep -Eq '^qdisc htb 1:' <<< "$qdisc_state"; then
        if ! tc_root_qdisc_is_replaceable "$qdisc_state"; then
            log_notification "ifb0 上存在不可安全替换的根队列，已拒绝接管"
            return 1
        fi
        tc qdisc replace dev "$dev" root handle 1: htb default 30 2>/dev/null || {
            log_notification "无法在 ifb0 上创建统一HTB根队列"
            return 1
        }
    fi

    parent_rate=$(desired_tc_parent_rate "$interface" 2>/dev/null) || {
        log_notification "TrafficCop TC状态无效，已拒绝修改 ifb0 统一HTB"
        return 1
    }
    tc class replace dev "$dev" parent 1: classid 1:1 htb \
        rate "$parent_rate" ceil "$parent_rate" 2>/dev/null || return 1
    tc class replace dev "$dev" parent 1:1 classid 1:30 htb \
        rate "$TC_DEFAULT_CLASS_RATE" ceil "$parent_rate" 2>/dev/null || return 1
}

ingress_redirect_runtime_complete() {
    local state
    state=$(tc -j filter show dev "$1" parent "$TC_IFB_INGRESS_HANDLE" 2>/dev/null) || return 1
    jq -e --arg dev "$TC_IFB_DEVICE" '
        def redirects($proto): [.[] | select(.protocol == $proto) |
            .options.actions[]? | select(.kind == "mirred" and
            .mirred_action == "redirect" and .direction == "egress" and .to_dev == $dev)] | length;
        redirects("ip") == 1 and redirects("ipv6") == 1
    ' <<< "$state" >/dev/null
}

ensure_ingress_redirect_locked() {
    local interface="$1" state proto count
    state=$(tc qdisc show dev "$interface" 2>/dev/null) || return 1
    if ! grep -q '^qdisc ingress' <<< "$state"; then
        tc qdisc add dev "$interface" handle "$TC_IFB_INGRESS_HANDLE" ingress 2>/dev/null || return 1
    fi
    state=$(tc -j filter show dev "$interface" parent "$TC_IFB_INGRESS_HANDLE" 2>/dev/null) || return 1
    for proto in ip ipv6; do
        count=$(jq --arg proto "$proto" --arg dev "$TC_IFB_DEVICE" '
            [.[] | select(.protocol == $proto) | .options.actions[]? |
             select(.kind == "mirred" and .mirred_action == "redirect" and
                    .direction == "egress" and .to_dev == $dev)] | length
        ' <<< "$state") || return 1
        [ "$count" -le 1 ] || return 1
        if [ "$count" -eq 0 ]; then
            tc filter add dev "$interface" parent "$TC_IFB_INGRESS_HANDLE" protocol "$proto" u32 \
                match u32 0 0 action mirred egress redirect dev "$TC_IFB_DEVICE" 2>/dev/null || return 1
        fi
    done
}

# 删除TC带宽限制

normalize_tc_rate_to_bps() {
    local rate
    rate=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    [[ "$rate" =~ ^([0-9]+)(bit|kbit|mbit|gbit)$ ]] || return 1
    local value="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in
        bit) echo "$value" ;;
        kbit) echo $((value * 1000)) ;;
        mbit) echo $((value * 1000000)) ;;
        gbit) echo $((value * 1000000000)) ;;
    esac
}

tc_class_rate_matches() {
    local interface="$1"
    local class_id="$2"
    local expected_rate="$3"
    local expected_ceil="${4:-$expected_rate}"
    local class_line
    local class_state
    class_state=$(tc class show dev "$interface" 2>/dev/null) || return 1
    class_line=$(awk -v class_id="$class_id" \
        '$1 == "class" && $2 == "htb" && $3 == class_id {print; exit}' <<< "$class_state")
    [ -n "$class_line" ] || return 1

    local actual_rate
    local actual_ceil
    actual_rate=$(printf '%s\n' "$class_line" |
        awk '{for (i=1; i<=NF; i++) if ($i == "rate") {print $(i+1); exit}}')
    actual_ceil=$(printf '%s\n' "$class_line" |
        awk '{for (i=1; i<=NF; i++) if ($i == "ceil") {print $(i+1); exit}}')
    [ -n "$actual_ceil" ] || actual_ceil="$actual_rate"

    local expected_bps
    local expected_ceil_bps
    local actual_rate_bps
    local actual_ceil_bps
    expected_bps=$(normalize_tc_rate_to_bps "$expected_rate") || return 1
    expected_ceil_bps=$(normalize_tc_rate_to_bps "$expected_ceil") || return 1
    actual_rate_bps=$(normalize_tc_rate_to_bps "$actual_rate") || return 1
    actual_ceil_bps=$(normalize_tc_rate_to_bps "$actual_ceil") || return 1
    [ "$actual_rate_bps" -eq "$expected_bps" ] && [ "$actual_ceil_bps" -eq "$expected_ceil_bps" ]
}

# 入向整形链路是否完整：ifb0 存在、ingress 重定向在位、端口类与过滤器齐全。
# class_id 与 expected_rate 与出向同源，保证两侧限速一致。

# 返回值：0=存在且完整；1=存在但失效/状态不可解释；2=当前不需要 TC。

dog_tc_status() {
    local interface
    interface=$(get_default_interface 2>/dev/null || true)
    if [ -z "$interface" ]; then
        echo "TC_STATUS=ERROR REASON=interface-unresolved"
        return 1
    fi
    if ! begin_tc_update; then
        echo "TC_STATUS=ERROR INTERFACE=$interface REASON=lock-timeout"
        return 1
    fi

    local runtime_status=0
    local qdisc_state
    local class_state
    if ! qdisc_state=$(tc qdisc show dev "$interface" 2>/dev/null) ||
       ! class_state=$(tc class show dev "$interface" 2>/dev/null) ||
       ! tc filter show dev "$interface" parent 1:0 >/dev/null 2>&1; then
        finish_tc_update
        echo "TC_STATUS=ERROR INTERFACE=$interface REASON=status-read-failed"
        return 1
    fi
    dog_tc_runtime_complete_all "$interface" || runtime_status=$?

    local result=0
    case "$runtime_status" in
        0)
            echo "TC_STATUS=OK INTERFACE=$interface MODEL=$TC_INTEROP_SCHEMA"
            ;;
        1)
            echo "TC_STATUS=CONFLICT INTERFACE=$interface REASON=managed-rules-invalid"
            result=1
            ;;
        2)
            if tc_root_qdisc_is_replaceable "$qdisc_state"; then
                echo "TC_STATUS=IDLE INTERFACE=$interface"
            elif tc_root_is_managed "$interface"; then
                echo "TC_STATUS=CONFLICT INTERFACE=$interface REASON=orphaned-managed-root"
                result=1
            else
                echo "TC_STATUS=CONFLICT INTERFACE=$interface REASON=external-root-qdisc"
                result=1
            fi
            ;;
        *)
            echo "TC_STATUS=ERROR INTERFACE=$interface REASON=status-unavailable"
            result=1
            ;;
    esac
    finish_tc_update
    return "$result"
}

# 仅供用户确认后的共享恢复入口调用。--auto 只恢复已有 Dog/NTC TC 状态；
# --manual 还允许清除首次安装时发现的外部 root，之后由用户重新配置限速。
recover_tc_runtime() {
    local mode="${1:---manual}"
    case "$mode" in
        --auto|--manual) ;;
        *)
            echo "不支持的 TC 恢复模式: $mode" >&2
            return 2
            ;;
    esac

    validate_config_file "$CONFIG_FILE" 2>/dev/null || {
        echo "Dog 配置无效，拒绝修改 TC。" >&2
        return 1
    }
    local interface
    interface=$(get_default_interface 2>/dev/null || true)
    [ -n "$interface" ] || {
        echo "无法确定默认网卡，未修改 TC。" >&2
        return 1
    }
    if ! begin_tc_update; then
        echo "无法取得共享 TC 锁，未修改 qdisc。" >&2
        return 1
    fi

    local qdisc_state
    local class_state
    if ! qdisc_state=$(tc qdisc show dev "$interface" 2>/dev/null) ||
       ! class_state=$(tc class show dev "$interface" 2>/dev/null) ||
       ! tc filter show dev "$interface" parent 1:0 >/dev/null 2>&1; then
        finish_tc_update
        echo "无法读取完整 TC 状态，未修改 qdisc。" >&2
        return 1
    fi

    local runtime_status=0
    dog_tc_runtime_complete_all "$interface" || runtime_status=$?
    if [ "$runtime_status" -eq 0 ]; then
        finish_tc_update
        echo "Dog/NTC TC 规则完整，无需重建。"
        return 0
    fi

    local ntc_status=0
    trafficcop_unified_state_rate "$interface" >/dev/null 2>&1 || ntc_status=$?
    if [ -e "$TRAFFICCOP_TC_STATE_FILE" ] &&
       [ "$ntc_status" -ne 0 ] && [ "$ntc_status" -ne 1 ] &&
       [ "$ntc_status" -ne 4 ] && [ "$ntc_status" -ne 5 ]; then
        finish_tc_update
        echo "TrafficCop TC 状态文件无法安全解释，拒绝自动删除 qdisc。" >&2
        return 1
    fi
    if [ "$mode" = "--auto" ] && [ "$runtime_status" -eq 2 ]; then
        finish_tc_update
        echo "当前没有需要自动恢复的 Dog/NTC TC 规则。"
        return 0
    fi

    if [ "$mode" = "--auto" ] && ! tc_root_qdisc_is_replaceable "$qdisc_state"; then
        finish_tc_update
        echo "自动恢复检测到外部或未知 root qdisc，拒绝接管；请由用户确认后执行手动重建。" >&2
        return 1
    fi
    if [ "$runtime_status" -eq 2 ] && tc_root_qdisc_is_replaceable "$qdisc_state"; then
        finish_tc_update
        echo "当前 TC 为空闲状态，无需处理。"
        return 0
    fi

    local tc_ports=()
    local tc_limits=()
    local id tc_limit
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        tc_limit=$(monitor_tc_rate "$id") || continue
        tc_ports+=("$id")
        tc_limits+=("$tc_limit")
    done < <(monitor_ids)

    if ! tc_root_qdisc_is_replaceable "$qdisc_state" &&
       ! tc qdisc del dev "$interface" root 2>/dev/null; then
        finish_tc_update
        echo "无法删除当前冲突 root qdisc，Dog/NTC 规则未重建。" >&2
        return 1
    fi
    rm -f "$(get_tc_root_owner_file)"

    local rebuild_ok=true
    local tc_index
    if [ ${#tc_ports[@]} -gt 0 ]; then
        for tc_index in "${!tc_ports[@]}"; do
            if ! tc_apply_monitor_locked "${tc_ports[$tc_index]}" "${tc_limits[$tc_index]}"; then
                rebuild_ok=false
                break
            fi
        done
    elif [ "$ntc_status" -eq 0 ]; then
        ensure_owned_tc_hierarchy_locked "$interface" || rebuild_ok=false
    fi

    if [ "$rebuild_ok" = "true" ]; then
        local verify_status=0
        dog_tc_runtime_complete_all "$interface" || verify_status=$?
        if [ ${#tc_ports[@]} -gt 0 ] || [ "$ntc_status" -eq 0 ]; then
            [ "$verify_status" -eq 0 ] || rebuild_ok=false
        else
            [ "$verify_status" -eq 2 ] || rebuild_ok=false
        fi
    fi
    finish_tc_update

    if [ "$rebuild_ok" != "true" ]; then
        echo "冲突 qdisc 已清除，但 Dog/NTC TC 规则未能完整重建；请运行 dog --self-check。" >&2
        return 1
    fi
    if [ ${#tc_ports[@]} -eq 0 ] && [ "$ntc_status" -ne 0 ]; then
        echo "外部 TC 冲突已清除；当前没有需要创建的 Dog 端口限速规则。"
    else
        echo "Dog/NTC 统一 HTB 已按现有配置重建。"
    fi
}

# ── 按监控项的带宽限制 ────────────────────────────────────────────
# 出向：nft 的 ptd_<id>_mark 链给命中端口的包打 mark（只占高 20 位，保留低 12 位），
#       物理网卡上一条 fw 过滤器按 mark 把包归入该项的 HTB 子类。端口增删只改 nft 映射，TC 不动。
# 入向：ingress 先于 nft，拿不到 mark；ifb0 上按成员端口用 flower 精确匹配（每成员 8 条：
#       IPv4/IPv6 × TCP/UDP × 源/目的），端口增删时只重建该项的入向过滤器。
# class minor = 0x4000 + 监控项编号，mark = 0x50000000 | (minor << 12)，均为确定值，无需哈希。

tc_minor_for() {
    local n="${1#m}"
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le 49151 ] || return 1
    echo $((0x4000 + n))
}

tc_class_for() {
    local minor
    minor=$(tc_minor_for "$1") || return 1
    printf '1:%x\n' "$minor"
}

tc_mark_for() {
    local minor
    minor=$(tc_minor_for "$1") || return 1
    echo $(( TC_MARK_BASE | (minor << 12) ))
}

# 监控项的 tc 速率（如 100mbit）；未启用限速返回 1。
monitor_tc_rate() {
    local id="$1" rate
    [ "$(mget "$id" .bandwidth_limit.enabled false)" = "true" ] || return 1
    rate=$(mget "$id" .bandwidth_limit.rate unlimited)
    [ "$rate" != "unlimited" ] || return 1
    echo "$rate"
}

# 已安装的 TrafficCop Lite 是否理解 Dog 2.0 的类清单（tc-interop.json）。
# 未安装 NTC 视为兼容；旧版 NTC 会按 1.5.x 的 .ports 反推 Dog 的类，必须先升级。
tc_ntc_compatible() {
    local monitor="$TRAFFICCOP_MONITOR_SCRIPT"
    [ -e "$monitor" ] || return 0
    grep -qF "$TC_CLASS_MANIFEST_SCHEMA" "$monitor" 2>/dev/null
}

tc_require_ntc_compatible() {
    tc_ntc_compatible && return 0
    dog_error "检测到旧版 TrafficCop Lite：它无法识别 Dog 2.0 的限速类，同时运行会互相误判。请先把 TrafficCop Lite 升级到 1.2.0 或更高版本，再设置带宽限制。"
    return 1
}

# 写入供 NTC 读取的类清单（原子替换，root 0644）。
# $1（可选）：要排除的监控项 ID——删除/合并时在持锁移除 TC 对象后、改配置前调用。
tc_write_interop() {
    local exclude="${1:-}" iface id rate classes="[]"
    iface=$(get_default_interface 2>/dev/null || echo "")
    while IFS= read -r id; do
        [ -n "$id" ] && [ "$id" != "$exclude" ] || continue
        rate=$(monitor_tc_rate "$id") || continue
        classes=$(jq -c --arg id "$id" --arg c "$(tc_class_for "$id")" --arg r "$rate" \
            --argjson m "$(tc_mark_for "$id")" --argjson n "$(jq 'length' <<< "$(jq -c --arg id "$id" '.monitors[$id].ports' "$CONFIG_FILE")")" \
            '. + [{id: $id, class_id: $c, rate: $r, mark: $m, mark_mask: 4294963200,
                   egress: "fw", ingress: "flower", ingress_filters: ($n * 8)}]' <<< "$classes")
    done < <(monitor_ids)
    jq -n --arg s "$TC_CLASS_MANIFEST_SCHEMA" --arg v "$SCRIPT_VERSION" --arg i "$iface" \
          --arg at "$(date -u +%FT%TZ)" --argjson c "$classes" \
        '{schema: $s, dog_version: $v, interface: $i, updated_at: $at, classes: $c}' |
        atomic_write "$TC_INTEROP_FILE" 644
}

tc_class_args() {
    local rate="$1" kbps burst
    kbps=$(parse_tc_rate_to_kbps "$rate")
    burst=$(format_tc_burst "$(calculate_tc_burst "$kbps")")
    printf 'rate %s ceil %s burst %s' "$TC_PORT_CLASS_RATE" "$rate" "$burst"
}

# 删除 ifb0 上指向该类的全部 flower 过滤器（不依赖成员数，端口变化后也能清干净）。
tc_remove_ingress_filters_locked() {
    local id="$1" class json
    class=$(tc_class_for "$id") || return 1
    ip link show "$TC_IFB_DEVICE" >/dev/null 2>&1 || return 0
    json=$(tc -j filter show dev "$TC_IFB_DEVICE" parent 1:0 2>/dev/null) || return 0
    jq -r --arg c "$class" '.[] | select(.options.handle? != null and (.options.classid? // .options.flowid? // "") == $c) |
        "\(.protocol) \(.pref) \(.options.handle)"' <<< "$json" 2>/dev/null |
    while read -r proto pref handle; do
        tc filter del dev "$TC_IFB_DEVICE" parent 1:0 protocol "$proto" pref "$pref" handle "$handle" flower 2>/dev/null || true
    done
}

tc_apply_ingress_locked() {
    local id="$1" rate="$2" iface="$3" class minor ports index=0 port offset pref family proto key handle
    class=$(tc_class_for "$id"); minor=$(tc_minor_for "$id")
    ensure_ifb_hierarchy_locked "$iface" || return 1
    ensure_ingress_redirect_locked "$iface" || return 1
    tc_remove_ingress_filters_locked "$id"
    # shellcheck disable=SC2046
    tc class replace dev "$TC_IFB_DEVICE" parent 1:1 classid "$class" htb $(tc_class_args "$rate") || return 1
    mapfile -t ports < <(monitor_ports "$id")
    for port in "${ports[@]}"; do
        index=$((index + 1))
        handle=$(printf '0x%x' $(( (minor << 16) | index )))
        for offset in 0 1 2 3 4 5 6 7; do
            pref=$((100 + offset))
            family=ip; [ "$offset" -lt 4 ] || family=ipv6
            proto=tcp; [ $((offset % 4)) -lt 2 ] || proto=udp
            key=src_port; [ $((offset % 2)) -eq 0 ] || key=dst_port
            tc filter add dev "$TC_IFB_DEVICE" protocol "$family" parent 1:0 pref "$pref" \
                handle "$handle" flower ip_proto "$proto" "$key" "$port" classid "$class" || {
                tc_remove_ingress_filters_locked "$id"
                return 1
            }
        done
    done
}

tc_egress_filter_handle() {
    printf '0x%x/0x%x' "$(tc_mark_for "$1")" "$TC_MARK_MASK"
}

# 施加/更新一个监控项的限速（调用方持有 TC 锁与 Dog 锁）。
tc_apply_monitor_locked() {
    local id="$1" rate="$2" iface class mark
    iface=$(get_default_interface) || return 1
    ensure_owned_tc_hierarchy_locked "$iface" || return 1
    class=$(tc_class_for "$id") || return 1
    mark=$(tc_mark_for "$id")
    # shellcheck disable=SC2046
    tc class replace dev "$iface" parent 1:1 classid "$class" htb $(tc_class_args "$rate") || {
        log_notification "监控项 $id 无法创建 TC 分类 $class"; return 1; }
    tc filter del dev "$iface" parent 1:0 protocol all prio 1 handle "$(tc_egress_filter_handle "$id")" fw 2>/dev/null || true
    tc filter add dev "$iface" parent 1:0 protocol all prio 1 handle "$(tc_egress_filter_handle "$id")" fw flowid "$class" || {
        log_notification "监控项 $id 无法创建出向 fw 过滤器"; return 1; }
    config_update '.monitors[$id].bandwidth_limit.class_id = $c | .monitors[$id].bandwidth_limit.mark_id = $m' \
        --arg id "$id" --arg c "$class" --argjson m "$mark" || return 1
    nft_sync_monitor "$id" || return 1
    tc_apply_ingress_locked "$id" "$rate" "$iface" || { log_notification "监控项 $id 入向限速创建失败"; return 1; }
    tc_monitor_complete "$id" "$iface"
}

# 撤销一个监控项的 TC 对象（不改配置开关；调用方持有 TC 锁）。
tc_remove_monitor_locked() {
    local id="$1" iface class
    iface=$(get_default_interface 2>/dev/null) || return 0
    class=$(tc_class_for "$id") || return 1
    tc_remove_ingress_filters_locked "$id"
    tc class del dev "$TC_IFB_DEVICE" classid "$class" 2>/dev/null || true
    tc filter del dev "$iface" parent 1:0 protocol all prio 1 handle "$(tc_egress_filter_handle "$id")" fw 2>/dev/null || true
    tc class del dev "$iface" classid "$class" 2>/dev/null || true
    cleanup_owned_tc_root_if_unused_locked "$iface" || true
    ! tc class show dev "$iface" 2>/dev/null | awk -v c="$class" '$3 == c {f=1} END {exit !f}'
}

# 删除 2.0 号段（1:4001-1:ffff）里没有对应限速监控项的孤儿类及其过滤器（调用方持有 TC 锁）。
# 孤儿类会让 NTC 判定“存在无法证明归属的 Dog 类”而拒绝操作，必须由 Dog 自己清掉。
tc_remove_orphan_classes_locked() {
    local iface="$1" dev class minor id removed=0
    for dev in "$iface" "$TC_IFB_DEVICE"; do
        ip link show "$dev" >/dev/null 2>&1 || continue
        while read -r class; do
            [[ "$class" =~ ^1:([0-9a-f]+)$ ]] || continue
            minor=$((16#${BASH_REMATCH[1]}))
            [ "$minor" -ge $((0x4001)) ] && [ "$minor" -le $((0xffff)) ] || continue
            id="m$((minor - 0x4000))"
            monitor_exists "$id" && monitor_tc_rate "$id" >/dev/null && continue
            if [ "$dev" = "$TC_IFB_DEVICE" ]; then
                tc_remove_ingress_filters_locked "$id"
            else
                tc filter del dev "$dev" parent 1:0 protocol all prio 1 handle "$(tc_egress_filter_handle "$id")" fw 2>/dev/null || true
            fi
            tc class del dev "$dev" classid "$class" 2>/dev/null && removed=$((removed + 1))
        done < <(tc class show dev "$dev" 2>/dev/null | awk '$1 == "class" && $2 == "htb" && $5 == "1:1" { print $3 }')
    done
    [ "$removed" -eq 0 ] || log_notification "已清理 $removed 个无对应监控项的 TC 分类"
    return 0
}

# 一个监控项的 TC 运行状态是否完整。
tc_monitor_complete() {
    local id="$1" iface="${2:-}" rate class handle want have
    rate=$(monitor_tc_rate "$id") || return 0
    [ -n "$iface" ] || iface=$(get_default_interface 2>/dev/null) || return 1
    class=$(tc_class_for "$id")
    tc_class_rate_matches "$iface" "$class" "$TC_PORT_CLASS_RATE" "$rate" || return 1
    tc_class_rate_matches "$TC_IFB_DEVICE" "$class" "$TC_PORT_CLASS_RATE" "$rate" || return 1
    handle=$(printf '0x%x' "$(tc_mark_for "$id")")
    grep -Eq "handle ${handle}/0xfffff000 classid ${class}( |$)" <<< "$(tc filter show dev "$iface" parent 1:0 2>/dev/null)" || return 1
    want=$(( $(monitor_ports "$id" | wc -l) * 8 ))
    have=$(tc -j filter show dev "$TC_IFB_DEVICE" parent 1:0 2>/dev/null |
        jq --arg c "$class" '[.[] | select(.options.handle? != null and (.options.classid? // .options.flowid? // "") == $c)] | length' 2>/dev/null || echo 0)
    [ "$have" -eq "$want" ]
}

# 0=全部完整，1=有冲突或缺失，2=Dog/NTC 都没有 TC 需求。
dog_tc_runtime_complete_all() {
    local interface="$1" expected=false ntc_rate="" ntc_status=0 id
    ntc_rate=$(trafficcop_unified_state_rate "$interface" 2>/dev/null) || ntc_status=$?
    case "$ntc_status" in
        0)
            expected=true
            tc_root_is_managed "$interface" || return 1
            tc_class_rate_matches "$interface" "1:1" "$ntc_rate" "$ntc_rate" || return 1
            tc_class_rate_matches "$interface" "1:30" "$TC_DEFAULT_CLASS_RATE" "$ntc_rate" || return 1
            ;;
        1|4|5) ;;
        *) [ -e "$TRAFFICCOP_TC_STATE_FILE" ] && return 1 ;;
    esac
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        monitor_tc_rate "$id" >/dev/null || continue
        expected=true
        tc_monitor_complete "$id" "$interface" || return 1
    done < <(monitor_ids)
    [ "$expected" = "true" ] && return 0
    return 2
}

# 端口变化后刷新入向过滤器（出向随 nft 映射自动生效）。
tc_refresh_monitor_ports() {
    local id="$1" rate iface rc=0
    rate=$(monitor_tc_rate "$id") || return 0
    iface=$(get_default_interface) || return 1
    begin_tc_update || return 1
    tc_apply_ingress_locked "$id" "$rate" "$iface" || rc=1
    finish_tc_update
    return "$rc"
}

# 设置或取消限速：rate 为 tc 速率（100mbit）或 0。
tc_set_monitor_limit() {
    local id="$1" rate="$2" rc=0 prev_enabled prev_rate
    if [ "$rate" != "0" ]; then
        tc_require_ntc_compatible || return 1
    fi
    dog_lock || return 75
    prev_enabled=$(mget "$id" .bandwidth_limit.enabled false)
    prev_rate=$(mget "$id" .bandwidth_limit.rate unlimited)
    begin_tc_update || { dog_unlock; return 1; }
    if [ "$rate" = "0" ]; then
        config_update '.monitors[$id].bandwidth_limit = {enabled: false, rate: "unlimited"}' --arg id "$id" || rc=1
        [ "$rc" -eq 0 ] && { tc_remove_monitor_locked "$id" || rc=1; }
        [ "$rc" -eq 0 ] && { nft_sync_monitor "$id" || rc=1; }
        dog_log_event tc_clear "$rc" "id=$id"
    else
        config_update '.monitors[$id].bandwidth_limit.enabled = true | .monitors[$id].bandwidth_limit.rate = $r' \
            --arg id "$id" --arg r "$rate" || rc=1
        if [ "$rc" -eq 0 ] && ! tc_apply_monitor_locked "$id" "$rate"; then
            rc=1
            # 回滚到原设置，避免配置声称已限速而内核没有对应对象。
            tc_remove_monitor_locked "$id" >/dev/null 2>&1 || true
            config_update '.monitors[$id].bandwidth_limit.enabled = ($e == "true") | .monitors[$id].bandwidth_limit.rate = $r' \
                --arg id "$id" --arg e "$prev_enabled" --arg r "$prev_rate" >/dev/null 2>&1 || true
            nft_sync_monitor "$id" >/dev/null 2>&1 || true
            if [ "$prev_enabled" = "true" ] && [ "$prev_rate" != "unlimited" ]; then
                tc_apply_monitor_locked "$id" "$prev_rate" >/dev/null 2>&1 || true
            fi
        fi
        dog_log_event tc_apply "$rc" "id=$id" "rate=$rate"
    fi
    # 清单在释放共享 TC 锁之前写入：NTC 持锁读取时，内核对象与清单一致。
    tc_write_interop || true
    finish_tc_update
    dog_unlock
    return "$rc"
}

# 按配置恢复全部限速（缺失或不完整的才重建）。
tc_restore_all() {
    local id rate iface rc=0 any=false
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        monitor_tc_rate "$id" >/dev/null && { any=true; break; }
    done < <(monitor_ids)
    iface=$(get_default_interface 2>/dev/null) || iface=""
    if [ "$any" != "true" ]; then
        if [ -n "$iface" ] && begin_tc_update; then
            tc_remove_orphan_classes_locked "$iface"
            tc_write_interop || true
            finish_tc_update
        else
            tc_write_interop || true
        fi
        return 0
    fi
    tc_ntc_compatible || { tc_require_ntc_compatible; return 1; }
    [ -n "$iface" ] || return 1
    begin_tc_update || return 1
    tc_remove_orphan_classes_locked "$iface"
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        rate=$(monitor_tc_rate "$id") || continue
        tc_monitor_complete "$id" "$iface" && continue
        tc_apply_monitor_locked "$id" "$rate" || rc=1
    done < <(monitor_ids)
    tc_write_interop || true
    finish_tc_update
    return "$rc"
}

validate_ip_guard_script_file() {
    local candidate="$1"
    [ -s "$candidate" ] &&
        grep -Fq '# PORT_TRAFFIC_DOG_IP_GUARD' "$candidate" 2>/dev/null &&
        bash -n "$candidate" >/dev/null 2>&1
}

install_ip_guard_script_file() {
    local source_file="$1"
    local temp_file
    mkdir -p "$CONFIG_DIR" || return 1
    temp_file=$(mktemp "$CONFIG_DIR/.port-ip-guard.sh.XXXXXX") || return 1
    if ! install -m 755 "$source_file" "$temp_file" ||
       ! mv -f "$temp_file" "$IP_GUARD_SCRIPT_PATH"; then
        rm -f "$temp_file"
        return 1
    fi
}

get_ip_guard_service_state() {
    if [ ! -e "$IP_GUARD_SERVICE_FILE" ]; then
        echo "absent"
        return 0
    fi
    command -v "$IP_GUARD_SYSTEMCTL" >/dev/null 2>&1 || return 1

    local active_state
    active_state=$("$IP_GUARD_SYSTEMCTL" show "$IP_GUARD_SERVICE" \
        --property=ActiveState --value 2>/dev/null) || return 1
    case "$active_state" in
        active|activating|reloading|deactivating) echo "active" ;;
        inactive|failed) echo "inactive" ;;
        *) return 1 ;;
    esac
}

restart_ip_guard_after_update() {
    validate_ip_guard_script_file "$IP_GUARD_SCRIPT_PATH" || return 1
    command -v "$IP_GUARD_SYSTEMCTL" >/dev/null 2>&1 || return 1
    "$IP_GUARD_SYSTEMCTL" daemon-reload >/dev/null 2>&1 || return 1
    "$IP_GUARD_SYSTEMCTL" restart "$IP_GUARD_SERVICE" >/dev/null 2>&1 || return 1
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if "$IP_GUARD_SYSTEMCTL" is-active --quiet "$IP_GUARD_SERVICE" >/dev/null 2>&1 &&
           bash "$IP_GUARD_SCRIPT_PATH" --self-check >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

ensure_ip_guard_script() {
    if validate_ip_guard_script_file "$IP_GUARD_SCRIPT_PATH"; then
        chmod 755 "$IP_GUARD_SCRIPT_PATH" 2>/dev/null || true
        return 0
    fi

    local script_dir
    local bundled_script
    script_dir=$(dirname "$SCRIPT_PATH")
    bundled_script="$script_dir/port-ip-guard.sh"
    if validate_ip_guard_script_file "$bundled_script"; then
        install_ip_guard_script_file "$bundled_script"
        return $?
    fi

    local tmp rc=0
    tmp=$(mktemp -d) || return 1
    if download_url "$(release_asset_url SHA256SUMS)" "$tmp/SHA256SUMS" &&
       release_download_verified port-ip-guard.sh "$tmp/port-ip-guard.sh" "$tmp/SHA256SUMS" &&
       validate_ip_guard_script_file "$tmp/port-ip-guard.sh"; then
        install_ip_guard_script_file "$tmp/port-ip-guard.sh" || rc=1
    else
        rc=1
    fi
    rm -rf "$tmp"
    return "$rc"
}

manage_ip_guard() {
    menu_clear
    echo -e "${BLUE}=== 在线 IP / 并发连接限制（测试中） ===${NC}"
    echo -e "${YELLOW}独立实验组件，按本机 TCP 服务端口限制在线 IP 数和并发连接数。${NC}"
    echo "IPv4/IPv6 合计，两项可分别设置，0 表示不限；不处理内核 FORWARD 流量。"
    echo "NAT/代理后可能共用一个来源 IP；同 IP 的多条连接仍分别计入连接数。"
    echo "规则采用故障解封设计，但仍不建议直接限制当前 SSH 端口。"
    echo
    if ! dependency_install_missing false all; then
        echo '依赖未就绪；可在主菜单“依赖管理”中安装。未启用新的防火墙限制。' >&2
        read -r -p '按回车返回主菜单...' || return 0
        return 0
    fi
    if ! ensure_ip_guard_script; then
        echo -e "${RED}独立组件下载或校验失败，未修改防火墙。${NC}"
    elif ! bash "$IP_GUARD_SCRIPT_PATH"; then
        echo -e "${RED}在线 IP / 并发连接限制组件执行失败。${NC}"
    fi
    echo
    pause
}

# ── 状态报告与通知（Telegram / 企业微信，已内置，不再下载外部模块） ──
# 关键约束：读数失败时绝不发送“空报告”。要么发送完整报告，要么发送带原因的告警并返回非零。

readonly NOTIFY_RETRIES=2
readonly NOTIFY_CONNECT_TIMEOUT=10
readonly NOTIFY_MAX_TIME=30

monitor_status_tags() {
    local id="$1" tags="" remark mode limit label exp rate
    remark=$(mget "$id" .remark "")
    [ -n "$remark" ] && tags+="[备注:${remark}]"
    mode=$(mget "$id" .billing_mode double)
    limit=$(mget "$id" .quota.monthly_limit unlimited)
    [ "$(mget "$id" .quota.enabled false)" = "true" ] || limit=unlimited
    if [ "$limit" != "unlimited" ]; then
        if [ "$mode" = "single" ]; then tags+="[单向${limit}]"; else tags+="[双向${limit}]"; fi
    else
        if [ "$mode" = "single" ]; then tags+="[单向计费]"; else tags+="[双向计费]"; fi
    fi
    label=$(monitor_reset_label "$id" 2>/dev/null) && tags+="[${label}]"
    exp=$(monitor_expiry_label "$id" 2>/dev/null) && tags+="[${exp}]"
    rate=$(monitor_tc_rate "$id" 2>/dev/null) && tags+="[限速:${rate}]"
    printf '%s' "$tags"
}

build_usage_progress_bar() {
    local percent="${1:-0}" width=20 filled i bar=""
    [ "$percent" -gt 100 ] && percent=100
    filled=$((percent * width / 100))
    for ((i = 0; i < width; i++)); do
        if [ "$i" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
    done
    printf '%s' "$bar"
}

# 生成状态报告正文。读数失败时输出告警正文并返回 2。
build_status_report() {
    local server="${1:-$(hostname)}" now values total=0 count=0 body="" id idx=0
    local in_b out_b mult billed_in billed_out billed ports limit lbytes pct
    now=$(beijing_date '+%Y-%m-%d %H:%M:%S')
    count=$(monitor_ids | grep -c . || true)
    if ! nft_available; then
        printf '⚠️ 服务器: %s | ⏰ %s\n流量读取失败：找不到 nft 命令（PATH=%s）\n请登录服务器运行 dog --self-check\n' "$server" "$now" "$PATH"
        return 2
    fi
    if ! nft_table_exists; then
        printf '⚠️ 服务器: %s | ⏰ %s\n流量读取失败：nftables 表 %s 不存在（规则可能被清空或重启后未恢复）\n请运行 dog --repair\n' "$server" "$now" "$NFT_TABLE"
        return 2
    fi
    values=$(nft_read_values)
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        if ! jq -e --arg id "$id" 'has($id)' <<< "$values" >/dev/null; then
            printf '⚠️ 服务器: %s | ⏰ %s\n流量读取失败：监控项 %s 的计数器缺失\n请运行 dog --repair\n' "$server" "$now" "$id"
            return 2
        fi
        idx=$((idx + 1))
        read -r in_b out_b < <(jq -r --arg id "$id" '.[$id] | "\(.in) \(.out)"' <<< "$values")
        mult=$(monitor_billing_multiplier "$id")
        billed_in=$((in_b * mult)); billed_out=$((out_b * mult)); billed=$((billed_in + billed_out))
        total=$((total + billed))
        ports=$(monitor_ports_csv "$id")
        [ -n "$body" ] && body+=$'\n\n'
        body+="${idx}. [${id}]$(monitor_status_tags "$id") | 端口:${ports}"$'\n'
        body+="总流量:$(format_bytes "$billed") | 入站(下载):$(format_bytes "$billed_in") | 出站(上传):$(format_bytes "$billed_out")"
        limit=$(mget "$id" .quota.monthly_limit unlimited)
        if [ "$(mget "$id" .quota.enabled false)" = "true" ] && [ "$limit" != "unlimited" ] &&
           lbytes=$(parse_size_to_bytes "$limit") && [ "$lbytes" -gt 0 ]; then
            pct=$((billed * 100 / lbytes))
            body+=$'\n'"$(format_bytes "$billed")/${limit} | ${pct}%$([ "$pct" -ge 100 ] && echo ' (超限)') | $(monitor_cycle_range "$id")"
            body+=$'\n'"[$(build_usage_progress_bar "$pct")]"
        fi
    done < <(monitor_ids)
    printf '🔗 服务器: %s | ⏰ %s\n' "$server" "$now"
    printf '────────────────────────────────────────\n'
    printf '状态: 监控中 | 监控项: %s个 | 周期总流量: %s\n' "$count" "$(format_bytes "$total")"
    printf '────────────────────────────────────────\n'
    printf '%s\n' "$body"
}

# 按行截断到不超过 max_bytes 字节，不会切断多字节字符。
truncate_lines_bytes() {
    local max="$1"
    LC_ALL=C awk -v max="$max" 'BEGIN { n = 0 }
        { len = length($0) + 1 }
        n + len > max { print "[消息过长，已截断]"; exit }
        { print; n += len }'
}

# ── Telegram ──

telegram_api_base() {
    local route base
    route=$(cfg '.notifications.telegram.api_route // "official"')
    if [ "$route" != "custom" ]; then echo "https://api.telegram.org"; return 0; fi
    base=$(cfg '.notifications.telegram.custom_api_base // ""' | tr -d ' ')
    base="${base%/}"
    [[ "$base" =~ ^https:// ]] || [[ "$base" =~ ^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/|$) ]] || return 1
    echo "$base"
}

telegram_send() {
    local text="$1" token chat base url resp rc attempt=0 masked
    token=$(cfg '.notifications.telegram.bot_token // ""')
    chat=$(cfg '.notifications.telegram.chat_id // ""')
    if [ -z "$token" ] || [ -z "$chat" ]; then log_notification "Telegram 配置不完整"; return 1; fi
    base=$(telegram_api_base) || { log_notification "Telegram 自定义线路无效（必须是 https://，http 仅限本机回环）"; return 1; }
    if [[ "$base" =~ /bot$ ]]; then url="${base}${token}/sendMessage"; else url="${base}/bot${token}/sendMessage"; fi
    masked="${url//$token/${token:0:6}***}"
    text=$(printf '%s\n' "$text" | truncate_lines_bytes 3900)
    while [ "$attempt" -le "$NOTIFY_RETRIES" ]; do
        rc=0
        # URL（含 token）经 -K - 从标准输入传给 curl，不出现在进程参数里。
        resp=$(printf 'url = "%s"\n' "$url" | curl -sS -K - --connect-timeout "$NOTIFY_CONNECT_TIMEOUT" \
            --max-time "$NOTIFY_MAX_TIME" --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}" 2>&1) || rc=$?
        if [ "$rc" -eq 0 ] && jq -e '.ok == true' <<< "$resp" >/dev/null 2>&1; then
            log_notification "Telegram 发送成功（$masked）"
            return 0
        fi
        local migrated
        migrated=$(jq -r '.parameters.migrate_to_chat_id // empty' <<< "$resp" 2>/dev/null || true)
        if [ -n "$migrated" ] && [ "$migrated" != "$chat" ]; then
            chat="$migrated"
            config_update '.notifications.telegram.chat_id = $c' --arg c "$migrated" || true
            log_notification "Telegram 群已升级为超级群，chat_id 已更新为 $migrated"
            continue
        fi
        log_notification "Telegram 发送失败（curl=$rc，$masked）：$(tr '\n' ' ' <<< "$resp" | cut -c1-200)"
        attempt=$((attempt + 1))
        [ "$attempt" -le "$NOTIFY_RETRIES" ] && sleep 2
    done
    return 1
}

# ── 企业微信 ──

wecom_send() {
    local text="$1" hook payload resp rc attempt=0
    hook=$(cfg '.notifications.wecom.webhook_url // ""')
    [ -n "$hook" ] || { log_notification "企业微信 Webhook 未配置"; return 1; }
    [[ "$hook" =~ ^https:// ]] || { log_notification "企业微信 Webhook 必须使用 https://"; return 1; }
    text=$(printf '%s\n' "$text" | truncate_lines_bytes 2000)
    payload=$(jq -cn --arg c "$text" '{msgtype: "text", text: {content: $c}}')
    while [ "$attempt" -le "$NOTIFY_RETRIES" ]; do
        rc=0
        resp=$(printf 'url = "%s"\n' "$hook" | curl -sS -K - --connect-timeout "$NOTIFY_CONNECT_TIMEOUT" \
            --max-time "$NOTIFY_MAX_TIME" -H 'Content-Type: application/json' -d "$payload" 2>&1) || rc=$?
        if [ "$rc" -eq 0 ] && jq -e '.errcode == 0' <<< "$resp" >/dev/null 2>&1; then
            log_notification "企业微信发送成功"
            return 0
        fi
        log_notification "企业微信发送失败（curl=$rc）：$(tr '\n' ' ' <<< "$resp" | cut -c1-200)"
        attempt=$((attempt + 1))
        [ "$attempt" -le "$NOTIFY_RETRIES" ] && sleep 2
    done
    return 1
}

channel_enabled() {
    local c="$1"
    [ "$(cfg ".notifications.${c}.enabled // false")" = "true" ]
}

channel_status_enabled() {
    local c="$1"
    channel_enabled "$c" && [ "$(cfg ".notifications.${c}.status_notifications.enabled // false")" = "true" ]
}

channel_server_name() {
    local n
    n=$(cfg ".notifications.${1}.server_name // \"\"")
    [ -n "$n" ] || n=$(hostname)
    echo "$n"
}

# 发送状态报告到指定通道（telegram|wecom）。返回码：0 成功，1 发送失败，2 已发送读数告警。
send_status_report() {
    local channel="$1" report rc=0 send_rc=0
    has_monitors || return 0
    report=$(build_status_report "$(channel_server_name "$channel")") || rc=$?
    case "$channel" in
        telegram) telegram_send "$report" || send_rc=1 ;;
        wecom) wecom_send "$report" || send_rc=1 ;;
        *) return 1 ;;
    esac
    if [ "$rc" -ne 0 ]; then
        log_notification "$channel 状态报告读数失败，已发送告警：$(head -n 2 <<< "$report" | tail -n 1)"
        return 2
    fi
    return "$send_rc"
}

notification_interval_cron_expression() {
    case "$1" in
        1m) echo "* * * * *" ;;
        15m) echo "*/15 * * * *" ;;
        30m) echo "*/30 * * * *" ;;
        1h) echo "0 * * * *" ;;
        2h) echo "0 */2 * * *" ;;
        6h) echo "0 */6 * * *" ;;
        12h) echo "0 */12 * * *" ;;
        24h) echo "0 0 * * *" ;;
        *) return 1 ;;
    esac
}

select_notification_interval() {
    local choice
    {
        echo "推送周期：1) 1分钟  2) 15分钟  3) 30分钟  4) 1小时  5) 2小时  6) 6小时  7) 12小时  8) 24小时"
    } >&2
    read -r -p "请选择 [1-8，默认 4]: " choice
    case "${choice:-4}" in
        1) echo 1m ;; 2) echo 15m ;; 3) echo 30m ;; 4) echo 1h ;;
        5) echo 2h ;; 6) echo 6h ;; 7) echo 12h ;; 8) echo 24h ;;
        *) return 1 ;;
    esac
}

manage_notification_channel() {
    local c="$1" title choice v interval
    [ "$c" = telegram ] && title="Telegram" || title="企业微信"
    while true; do
        echo
        echo -e "${BLUE}=== ${title} 通知 ===${NC}"
        echo "状态：通道 $(channel_enabled "$c" && echo 开启 || echo 关闭) | 定时报告 $(channel_status_enabled "$c" && echo "开启（$(cfg ".notifications.${c}.status_notifications.interval // \"1h\"")）" || echo 关闭)"
        if [ "$c" = telegram ]; then
            echo "1. 设置 Bot Token 与 Chat ID"
            echo "5. 切换 API 线路（当前：$(cfg '.notifications.telegram.api_route // "official"')）"
        else
            echo "1. 设置 Webhook 地址"
        fi
        echo "2. 设置服务器名称（当前：$(channel_server_name "$c")）"
        echo "3. 开关定时报告并设置周期"
        echo "4. 立即发送一次测试报告"
        echo "6. 关闭此通道"
        echo "0. 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1)
                if [ "$c" = telegram ]; then
                    read -r -p "Bot Token: " v
                    [ -n "$v" ] || continue
                    local chat
                    read -r -p "Chat ID: " chat
                    config_update '.notifications.telegram.bot_token = $t | .notifications.telegram.chat_id = $c | .notifications.telegram.enabled = true' \
                        --arg t "$v" --arg c "$chat" && echo -e "${GREEN}已保存${NC}"
                else
                    read -r -p "Webhook 地址（https://qyapi.weixin.qq.com/...）: " v
                    [[ "$v" =~ ^https:// ]] || { echo -e "${RED}必须是 https:// 地址${NC}"; continue; }
                    config_update '.notifications.wecom.webhook_url = $u | .notifications.wecom.enabled = true' --arg u "$v" &&
                        echo -e "${GREEN}已保存${NC}"
                fi ;;
            2)
                read -r -p "服务器名称: " v
                config_update ".notifications.${c}.server_name = \$n" --arg n "$v" ;;
            3)
                if channel_status_enabled "$c" && confirm "定时报告已开启，是否关闭"; then
                    config_update ".notifications.${c}.status_notifications.enabled = false"
                else
                    interval=$(select_notification_interval) || { echo -e "${RED}无效选择${NC}"; continue; }
                    config_update ".notifications.${c}.status_notifications = {enabled: true, interval: \$i}" --arg i "$interval"
                fi
                cron_sync || true ;;
            4)
                local rc=0
                send_status_report "$c" || rc=$?
                case "$rc" in
                    0) echo -e "${GREEN}发送成功${NC}" ;;
                    2) echo -e "${YELLOW}读数失败，已发送告警，请运行 dog --self-check${NC}" ;;
                    *) echo -e "${RED}发送失败，详见 $NOTIFY_LOG_FILE${NC}" ;;
                esac ;;
            5)
                [ "$c" = telegram ] || continue
                echo "1) 官方 api.telegram.org  2) 自定义反代地址"
                read -r -p "请选择: " v
                if [ "$v" = 2 ]; then
                    local base
                    read -r -p "API 基础地址（https://example.com）: " base
                    base="${base%/}"
                    [[ "$base" =~ ^https:// ]] || [[ "$base" =~ ^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/|$) ]] ||
                        { echo -e "${RED}远程地址必须使用 https://${NC}"; continue; }
                    config_update '.notifications.telegram.api_route = "custom" | .notifications.telegram.custom_api_base = $b' --arg b "$base"
                else
                    config_update '.notifications.telegram.api_route = "official"'
                fi ;;
            6)
                config_update ".notifications.${c}.enabled = false" && cron_sync || true ;;
            0|"") return 0 ;;
        esac
    done
}

manage_notifications() {
    local choice
    while true; do
        echo
        echo -e "${BLUE}=== 通知管理 ===${NC}"
        echo "1. Telegram"
        echo "2. 企业微信"
        echo "3. 查看通知日志"
        echo "0. 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1) manage_notification_channel telegram ;;
            2) manage_notification_channel wecom ;;
            3) tail -n 40 "$NOTIFY_LOG_FILE" 2>/dev/null || echo "暂无日志"; pause ;;
            0|"") return 0 ;;
        esac
    done
}

# ── 定时任务 ──────────────────────────────────────────────────────
# cron_sync 是唯一写入 Dog 定时任务的入口：先移除所有 Dog 行（含 1.5.x 旧格式），
# 再按当前配置生成。不碰其他任务，也不增删 PATH= 行（脚本自身已固定 PATH）。
#   * * * * *  --tick                每分钟：规则自检修复、到期封锁、周期重置、日统计、整机流量
#   @reboot    --boot                开机恢复 nft 计数与配额
#   <周期>     --send-status <通道>  状态报告（通道与定时报告均开启时）

readonly DOG_CRON_TAG="# port-traffic-dog"

read_root_crontab() {
    local out rc=0
    out=$(crontab -l 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        grep -qi "no crontab" <<< "$out" && return 0
        echo "读取 root crontab 失败：$out" >&2
        return 1
    fi
    printf '%s\n' "$out"
}

# 过滤掉 Dog 自己的行（新旧格式）。
filter_dog_cron_lines() {
    awk '
        /# port-traffic-dog/ { next }
        /端口流量狗/ { next }
        /port-traffic-dog\.sh[[:space:]]+--/ { next }
        /\/usr\/local\/bin\/dog[[:space:]]+--/ { next }
        { print }
    '
}

desired_dog_cron_lines() {
    local exe c expr
    has_monitors || return 0
    exe=$(get_script_exec_path)
    printf '* * * * * %s --tick >/dev/null 2>&1  %s tick\n' "$exe" "$DOG_CRON_TAG"
    printf '@reboot %s --boot >/dev/null 2>&1  %s boot\n' "$exe" "$DOG_CRON_TAG"
    for c in telegram wecom; do
        channel_status_enabled "$c" || continue
        expr=$(notification_interval_cron_expression "$(cfg ".notifications.${c}.status_notifications.interval // \"1h\"")") || continue
        printf '%s %s --send-status %s >/dev/null 2>&1  %s %s\n' "$expr" "$exe" "$c" "$DOG_CRON_TAG" "$c"
    done
}

cron_sync() {
    command -v crontab >/dev/null 2>&1 || { dog_error "未找到 crontab 命令，定时任务无法配置"; return 1; }
    local current desired next rc=0
    dog_lock || return 75
    if ! current=$(read_root_crontab); then
        dog_unlock; return 1
    fi
    desired=$(desired_dog_cron_lines)
    next=$(printf '%s\n' "$current" | filter_dog_cron_lines)
    if [ -n "$desired" ]; then
        if [ -n "$next" ]; then next=$(printf '%s\n%s' "$next" "$desired"); else next="$desired"; fi
    fi
    if [ "$next" != "$current" ]; then
        printf '%s\n' "$next" | crontab - || rc=1
    fi
    dog_unlock
    [ -n "$desired" ] && { ensure_cron_service_running || dog_error "cron 服务未运行，定时任务不会执行"; }
    return "$rc"
}

cron_remove_all() {
    command -v crontab >/dev/null 2>&1 || return 0
    local current
    current=$(read_root_crontab) || return 1
    printf '%s\n' "$current" | filter_dog_cron_lines | crontab -
}

# 自检：Dog 定时任务是否与期望一致。
cron_in_sync() {
    local current desired actual
    current=$(read_root_crontab 2>/dev/null) || return 1
    desired=$(desired_dog_cron_lines)
    actual=$(printf '%s\n' "$current" | grep -F "$DOG_CRON_TAG" || true)
    [ "$actual" = "$desired" ]
}

# 每分钟任务。任何一步失败都写入日志，不影响其他步骤。
cron_tick() {
    local failed=0 step
    config_exists || return 0
    validate_config_file "$CONFIG_FILE" 2>/dev/null || { log_notification "定时任务跳过：配置文件校验失败"; return 1; }
    has_monitors || { collect_machine_traffic >/dev/null 2>&1 || true; return 0; }
    # 交互操作持锁时最多等 40 秒，避免与菜单修改冲突；仍拿不到则跳过本轮。
    dog_lock 40 || { log_notification "定时任务跳过：另一个 Dog 进程持有锁"; return 0; }
    for step in runtime_ensure_nft check_expirations check_due_resets stats_snapshot; do
        if ! "$step" quiet >/dev/null 2>&1; then
            failed=1
            dog_log_event cron_task 1 "step=${step//_/-}"
        fi
    done
    dog_unlock
    collect_machine_traffic >/dev/null 2>&1 || true
    return "$failed"
}

cron_service_is_running() {
    if command -v systemctl >/dev/null 2>&1 &&
       (systemctl is-active --quiet cron 2>/dev/null ||
        systemctl is-active --quiet crond 2>/dev/null); then
        return 0
    fi
    command -v pgrep >/dev/null 2>&1 &&
        (pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1)
}

ensure_cron_service_running() {
    # Debian/Ubuntu
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable cron >/dev/null 2>&1 || systemctl enable crond >/dev/null 2>&1 || true
        systemctl start cron >/dev/null 2>&1 || systemctl start crond >/dev/null 2>&1 || true
        if systemctl is-active --quiet cron 2>/dev/null ||
           systemctl is-active --quiet crond 2>/dev/null; then
            return 0
        fi
    fi

    if command -v service >/dev/null 2>&1; then
        service cron start >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
    fi

    # Alpine/OpenRC
    if command -v rc-update >/dev/null 2>&1; then
        rc-update add crond default >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service crond start >/dev/null 2>&1 || true
        rc-service crond status >/dev/null 2>&1 && return 0
    fi
    if command -v crond >/dev/null 2>&1 && ! pgrep -x crond >/dev/null 2>&1; then
        crond -b >/dev/null 2>&1 || true
    fi
    # Debian 的 cron 在没有 systemd/service 入口的隔离或容器环境中仍可直接后台启动。
    if command -v cron >/dev/null 2>&1 && ! pgrep -x cron >/dev/null 2>&1; then
        cron >/dev/null 2>&1 || true
    fi

    cron_service_is_running
}

list_machine_interfaces() {
    # 只取有 device 链接的真物理网卡。隧道（warp、wg*）、网桥（docker0、br-*）、
    # veth、lo、ifb 都没有这个链接——用黑名单会漏掉非标准命名的隧道接口，
    # 导致同一条流量在物理网卡和隧道上被重复计数。
    local path iface
    for path in /sys/class/net/*; do
        [ -e "$path/device" ] || continue
        iface=${path##*/}
        printf '%s\n' "$iface"
    done
}

collect_machine_traffic() {
    local interfaces=()
    mapfile -t interfaces < <(list_machine_interfaces)
    [ "${#interfaces[@]}" -gt 0 ] || return 0

    mkdir -p "$CONFIG_DIR" 2>/dev/null || return 1
    exec 6>"$CONFIG_DIR/.machine_traffic.lock" 2>/dev/null || return 1
    if ! flock -n 6 2>/dev/null; then
        exec 6>&-
        return 0
    fi

    local current_boot_id
    current_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
    local now
    now=$(date +%s)

    local data="{}"
    local first_run=false
    if [ -f "$MACHINE_TRAFFIC_FILE" ]; then
        data=$(cat "$MACHINE_TRAFFIC_FILE" 2>/dev/null || echo "{}")
    else
        first_run=true
    fi

    local last_boot_id
    last_boot_id=$(printf '%s' "$data" | jq -r '.lifetime_raw.boot_id // ""' 2>/dev/null || echo "")
    local new_data="$data"
    local iface line rx tx last_rx last_tx delta_rx delta_tx

    for iface in "${interfaces[@]}"; do
        line=$(awk -v dev="${iface}:" '$1 == dev {print $2" "$10; exit}' /proc/net/dev 2>/dev/null)
        [ -n "$line" ] || continue
        rx=${line%% *}
        tx=${line##* }
        [[ "$rx" =~ ^[0-9]+$ ]] || continue
        [[ "$tx" =~ ^[0-9]+$ ]] || continue

        last_rx=$(printf '%s' "$new_data" | jq -r --arg i "$iface" '.lifetime_raw.ifaces[$i].rx_bytes // 0' 2>/dev/null || echo 0)
        last_tx=$(printf '%s' "$new_data" | jq -r --arg i "$iface" '.lifetime_raw.ifaces[$i].tx_bytes // 0' 2>/dev/null || echo 0)
        [[ "$last_rx" =~ ^[0-9]+$ ]] || last_rx=0
        [[ "$last_tx" =~ ^[0-9]+$ ]] || last_tx=0

        if [ "$first_run" = "true" ]; then
            # 首次采集只记基准：安装之前的历史流量不计入
            delta_rx=0
            delta_tx=0
        elif [ -n "$last_boot_id" ] && [ "$last_boot_id" != "$current_boot_id" ]; then
            # 宿主机重启：开机至今的计数全部计入累计
            delta_rx=$rx
            delta_tx=$tx
        elif [ "$rx" -lt "$last_rx" ] || [ "$tx" -lt "$last_tx" ]; then
            # 未重启但计数回退（网卡重建等）：按当前值重新校准基准
            delta_rx=$rx
            delta_tx=$tx
        else
            delta_rx=$((rx - last_rx))
            delta_tx=$((tx - last_tx))
        fi

        new_data=$(printf '%s' "$new_data" | jq -c --arg i "$iface" \
            --argjson lrx "$rx" --argjson ltx "$tx" \
            --argjson drx "$delta_rx" --argjson dtx "$delta_tx" '
            .lifetime_raw.ifaces[$i] = {"rx_bytes": $lrx, "tx_bytes": $ltx} |
            .monthly.ifaces[$i] = ((.monthly.ifaces[$i] // {"rx_bytes": 0, "tx_bytes": 0}) |
                .rx_bytes += $drx | .tx_bytes += $dtx)' 2>/dev/null) || new_data="$data"
    done

    new_data=$(printf '%s' "$new_data" | jq -c --arg boot "$current_boot_id" --argjson now "$now" '
        .lifetime_raw.boot_id = $boot |
        .lifetime_raw.updated_at = $now |
        .monthly.reset_at = (.monthly.reset_at // $now)' 2>/dev/null) || new_data=""

    if [ -n "$new_data" ]; then
        local tmp_file="${MACHINE_TRAFFIC_FILE}.tmp.$$"
        if printf '%s\n' "$new_data" > "$tmp_file" 2>/dev/null; then
            chmod 600 "$tmp_file" 2>/dev/null || true
            mv -f "$tmp_file" "$MACHINE_TRAFFIC_FILE" 2>/dev/null || rm -f "$tmp_file"
        else
            rm -f "$tmp_file"
        fi
    fi

    flock -u 6 2>/dev/null || true
    exec 6>&-
    return 0
}

machine_traffic_summary() {
    [ -f "$MACHINE_TRAFFIC_FILE" ] || return 0
    local rx tx
    rx=$(jq -r '[.monthly.ifaces[]?.rx_bytes] | add // 0' "$MACHINE_TRAFFIC_FILE" 2>/dev/null || echo 0)
    tx=$(jq -r '[.monthly.ifaces[]?.tx_bytes] | add // 0' "$MACHINE_TRAFFIC_FILE" 2>/dev/null || echo 0)
    [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
    [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
    printf '入 %s / 出 %s' "$(format_bytes "$rx")" "$(format_bytes "$tx")"
}

# ── 安装、更新、卸载 ──────────────────────────────────────────────
# 更新只接受 GitHub Release 资产，并用同一 Release 的 SHA256SUMS 校验；镜像只用于加速，
# 不论从哪个源下载都必须通过哈希校验。

readonly SHORTCUT_MARKER="# port-traffic-dog shortcut"

release_asset_url() {
    printf 'https://github.com/%s/releases/latest/download/%s\n' "$DOG_REPO" "$1"
}

# 下载到文件：先直连，失败再走镜像（PORT_TRAFFIC_DOG_MIRROR，默认 gh-proxy）。
download_url() {
    local url="$1" out="$2" mirror="${PORT_TRAFFIC_DOG_MIRROR:-https://v6.gh-proxy.org}" src
    for src in "$url" "${mirror%/}/$url"; do
        if curl -fsSL --connect-timeout "$SHORT_CONNECT_TIMEOUT" --max-time 120 "$src" -o "$out" 2>/dev/null && [ -s "$out" ]; then
            return 0
        fi
    done
    return 1
}

# 下载 Release 资产并校验；$3 为已下载的 SHA256SUMS 文件。
release_download_verified() {
    local name="$1" out="$2" sums="$3" want got
    download_url "$(release_asset_url "$name")" "$out" || { dog_error "下载 $name 失败"; return 1; }
    want=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$sums")
    [ -n "$want" ] || { dog_error "SHA256SUMS 中没有 $name"; return 1; }
    got=$(sha256sum "$out" | awk '{print $1}')
    [ "$want" = "$got" ] || { dog_error "$name 校验失败（期望 $want，实际 $got），已拒绝安装"; return 1; }
}

get_script_version_from_file() {
    awk -F'"' '/^readonly SCRIPT_VERSION="[0-9]+(\.[0-9]+)+"/ { print $2; exit }' "$1" 2>/dev/null
}

# $1 < $2 时返回 0。
version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# 归属判断：2.0 标记、指向安装路径的软链接，或 1.4/1.5 生成的单行包装脚本（exec bash <安装路径>）。
shortcut_is_ours() {
    [ ! -e "$SHORTCUT_PATH" ] && return 0
    grep -qF "$SHORTCUT_MARKER" "$SHORTCUT_PATH" 2>/dev/null && return 0
    [ "$(readlink -f "$SHORTCUT_PATH" 2>/dev/null)" = "$INSTALLED_SCRIPT_PATH" ] && return 0
    [ -f "$SHORTCUT_PATH" ] && [ ! -L "$SHORTCUT_PATH" ] && [ "$(stat -c %s "$SHORTCUT_PATH" 2>/dev/null || echo 9999)" -lt 512 ] &&
        [ "$(grep -Evc '^[[:space:]]*(#.*)?$' "$SHORTCUT_PATH" 2>/dev/null)" = 1 ] &&
        grep -Eq "^exec bash \"?${INSTALLED_SCRIPT_PATH//./\\.}\"? \"\\\$@\"\$" "$SHORTCUT_PATH" 2>/dev/null
}

create_shortcut() {
    if ! shortcut_is_ours; then
        echo -e "${YELLOW}$SHORTCUT_PATH 已被其他程序占用，未创建快捷命令；请使用 $INSTALLED_SCRIPT_PATH${NC}" >&2
        return 0
    fi
    printf '#!/bin/sh\n%s\nexec %s "$@"\n' "$SHORTCUT_MARKER" "$INSTALLED_SCRIPT_PATH" | atomic_write "$SHORTCUT_PATH" 755
}

# 把当前运行的脚本安装到固定位置（首次运行下载的脚本时自动调用）。
install_self() {
    if [ "$SCRIPT_PATH" != "$INSTALLED_SCRIPT_PATH" ]; then
        bash -n "$SCRIPT_PATH" || { dog_error "脚本语法检查失败，未安装"; return 1; }
        cat "$SCRIPT_PATH" | atomic_write "$INSTALLED_SCRIPT_PATH" 755 || return 1
    fi
    create_shortcut || true
    ensure_config || return 1
    if [ -f "$SCRIPT_PATH" ] && [ -f "$(dirname "$SCRIPT_PATH")/port-ip-guard.sh" ] && [ ! -f "$IP_GUARD_SCRIPT_PATH" ]; then
        install_ip_guard_script_file "$(dirname "$SCRIPT_PATH")/port-ip-guard.sh" >/dev/null 2>&1 || true
    fi
    dog_log_event install 0
}

# 更新后由新版本执行的维护：迁移、恢复规则、刷新定时任务。
post_update() {
    local rc=0
    ensure_config || return 1
    if legacy_needs_migration; then
        migrate_from_legacy || return 1
    fi
    validate_config_file "$CONFIG_FILE" || return 1
    restore_runtime || rc=1
    cron_sync || rc=1
    tc_write_interop || true
    return "$rc"
}

update_dog() {
    local force="${1:-}" tmp sums new cur ver backup guard_installed=false rc=0
    tmp=$(mktemp -d) || return 1
    sums="$tmp/SHA256SUMS"; new="$tmp/port-traffic-dog.sh"
    echo "正在从 GitHub Release 获取最新版本（$DOG_REPO）..."
    if ! download_url "$(release_asset_url SHA256SUMS)" "$sums"; then
        rm -rf "$tmp"; dog_error "无法下载 SHA256SUMS（仓库尚无 Release 或网络不可达）"; return 1
    fi
    release_download_verified port-traffic-dog.sh "$new" "$sums" || { rm -rf "$tmp"; return 1; }
    bash -n "$new" || { rm -rf "$tmp"; dog_error "新脚本语法检查失败"; return 1; }
    ver=$(get_script_version_from_file "$new")
    cur="$SCRIPT_VERSION"
    echo "当前版本 $cur，最新版本 ${ver:-未知}"
    if [ -z "$ver" ]; then rm -rf "$tmp"; dog_error "无法识别新脚本版本"; return 1; fi
    if [ "$ver" = "$cur" ] && [ "$force" != "--force" ]; then rm -rf "$tmp"; echo "已是最新版本"; return 0; fi
    if version_lt "$ver" "$cur" && [ "$force" != "--force" ]; then
        rm -rf "$tmp"; dog_error "Release 版本 $ver 低于当前 $cur，已拒绝降级（如确需降级请加 --force）"; return 1
    fi
    [ -f "$IP_GUARD_SCRIPT_PATH" ] && guard_installed=true
    # 只在服务原本运行时才重启（与 1.5.x 一致）；状态无法确认时不动任何文件。
    local guard_state=absent
    if ! guard_state=$(get_ip_guard_service_state); then
        rm -rf "$tmp"; dog_error "无法确认 IP Guard 服务状态，已停止更新"; return 1
    fi
    if [ "$guard_installed" = "true" ]; then
        release_download_verified port-ip-guard.sh "$tmp/port-ip-guard.sh" "$sums" || { rm -rf "$tmp"; return 1; }
    fi
    backup="$BACKUP_DIR/update-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup" && chmod 700 "$backup"
    cp -p "$INSTALLED_SCRIPT_PATH" "$backup/" 2>/dev/null || true
    cp -p "$CONFIG_FILE" "$TRAFFIC_DATA_FILE" "$TRAFFIC_STATS_FILE" "$backup/" 2>/dev/null || true
    cp -p "$IP_GUARD_SCRIPT_PATH" "$backup/" 2>/dev/null || true
    crontab -l > "$backup/crontab.txt" 2>/dev/null || true
    atomic_write "$INSTALLED_SCRIPT_PATH" 755 < "$new" || { rm -rf "$tmp"; return 1; }
    if [ "$guard_installed" = "true" ]; then
        if ! install_ip_guard_script_file "$tmp/port-ip-guard.sh"; then
            rc=1
        elif [ "$guard_state" = active ] && ! restart_ip_guard_after_update; then
            rc=1; dog_error "IP Guard 服务重启或自检失败，请执行 systemctl status $IP_GUARD_SERVICE 检查"
        fi
    fi
    create_shortcut || true
    if ! "$INSTALLED_SCRIPT_PATH" --post-update; then
        echo -e "${RED}新版本维护失败，正在恢复更新前的文件...${NC}" >&2
        cp -p "$backup/port-traffic-dog.sh" "$INSTALLED_SCRIPT_PATH" 2>/dev/null || true
        for f in config.json traffic_data.json traffic_stats.json; do
            [ -f "$backup/$f" ] && cp -p "$backup/$f" "$CONFIG_DIR/$f"
        done
        [ -f "$backup/port-ip-guard.sh" ] && cp -p "$backup/port-ip-guard.sh" "$IP_GUARD_SCRIPT_PATH"
        [ -f "$backup/crontab.txt" ] && crontab "$backup/crontab.txt" 2>/dev/null || true
        rm -rf "$tmp"
        dog_log_event install_rollback 0
        dog_error "已恢复到 $cur（备份 $backup）"
        return 1
    fi
    rm -rf "$tmp"
    dog_log_event install "$rc"
    echo -e "${GREEN}已更新到 $ver（更新前备份：$backup）${NC}"
    return "$rc"
}

uninstall_dog() {
    local keep_config="${1:-}" iface id rc=0
    echo -e "${YELLOW}将删除全部端口监控规则、限速、定时任务和 Dog 程序文件。${NC}"
    if [ "$keep_config" = "--keep-config" ]; then
        echo "配置与统计将保留在 $CONFIG_DIR"
    else
        echo "配置与统计也会删除（可加 --keep-config 保留）"
    fi
    confirm "确认卸载" || { echo "已取消"; return 0; }
    dog_lock || return 75
    cron_remove_all || rc=1
    if config_exists && [ "$(config_schema)" = "2" ]; then
        begin_tc_update && {
            while IFS= read -r id; do
                [ -n "$id" ] || continue
                monitor_tc_rate "$id" >/dev/null && { tc_remove_monitor_locked "$id" || rc=1; }
            done < <(monitor_ids)
            iface=$(get_default_interface 2>/dev/null) && cleanup_owned_tc_root_if_unused_locked "$iface"
            finish_tc_update
        }
    fi
    if nft_table_exists; then nft delete table "$NFT_FAMILY" "$NFT_TABLE" || rc=1; fi
    if [ -f "$IP_GUARD_SCRIPT_PATH" ]; then
        bash "$IP_GUARD_SCRIPT_PATH" --uninstall --yes || rc=1
    fi
    rm -f "$TC_INTEROP_FILE"
    dog_unlock
    if [ "$keep_config" != "--keep-config" ]; then
        rm -rf "$CONFIG_DIR" || rc=1
    fi
    shortcut_is_ours && rm -f "$SHORTCUT_PATH"
    rm -f "$INSTALLED_SCRIPT_PATH" || rc=1
    cleanup_tc_recovery_files_if_unused || true
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}卸载完成。依赖软件包未删除，如需移除可运行：bash port-traffic-dog.sh --dependencies remove${NC}"
    else
        echo -e "${YELLOW}卸载完成，但有部分清理步骤失败，请检查 nft list ruleset 与 tc qdisc show${NC}"
    fi
    return "$rc"
}

# ── 配置导出 / 导入 ───────────────────────────────────────────────
# 配置包是 tar.gz，根目录 port-traffic-dog-config/。导入只读取白名单中的 JSON 数据文件，
# 不会导入任何可执行内容（1.5.x 会把包内的通知脚本复制进来并由 root cron 执行）。

readonly CONFIG_IO_FILES="config.json traffic_data.json traffic_stats.json reset_history.json"

export_config() {
    local out_dir="${1:-/root}" ts tmp pkg archive f
    ts=$(date +%Y%m%d-%H%M%S)
    archive="$out_dir/port-traffic-dog-config-$ts.tar.gz"
    dog_lock || return 75
    if has_monitors && ! stats_snapshot; then
        echo -e "${YELLOW}警告：刷新内核计数失败，导出的流量为最近一次灾备值${NC}" >&2
    fi
    tmp=$(mktemp -d); pkg="$tmp/port-traffic-dog-config"
    mkdir -p "$pkg"
    for f in $CONFIG_IO_FILES; do
        [ -f "$CONFIG_DIR/$f" ] && cp -p "$CONFIG_DIR/$f" "$pkg/"
    done
    dog_unlock
    printf 'version=%s\nexported_at=%s\nhost=%s\nmonitors=%s\n' "$SCRIPT_VERSION" "$(date -u +%FT%TZ)" \
        "$(hostname)" "$(jq -r '[.monitors | keys[]] | join(" ")' "$CONFIG_FILE" 2>/dev/null)" > "$pkg/package_info.txt"
    ( umask 077; tar -czf "$archive" -C "$tmp" port-traffic-dog-config ) || { rm -rf "$tmp"; dog_error "打包失败"; return 1; }
    rm -rf "$tmp"
    chmod 600 "$archive"
    dog_log_event export_config 0
    echo -e "${GREEN}已导出：$archive（包含 Telegram/企业微信凭据，请妥善保管）${NC}"
}

import_config() {
    local archive="$1" tmp src backup f schema rc=0
    [ -f "$archive" ] || { dog_error "文件不存在：$archive"; return 1; }
    tmp=$(mktemp -d)
    # 只提取白名单文件；拒绝绝对路径、.. 与非普通文件。
    if tar -tvzf "$archive" 2>/dev/null | awk 'substr($1,1,1) !~ /^[-d]$/ {bad=1} END {exit !bad}'; then
        rm -rf "$tmp"; dog_error "配置包含有链接或设备文件，已拒绝"; return 1
    fi
    local listing
    # 先完整取出清单再匹配：管道里 grep -q 提前退出会让 tar 收到 SIGPIPE，pipefail 下整个判断变假，
    # 不安全路径反而被放行。
    listing=$(tar -tzf "$archive" 2>/dev/null) || { rm -rf "$tmp"; dog_error "无法读取归档：$archive"; return 1; }
    if grep -Eq '(^/|(^|/)\.\.(/|$))' <<< "$listing"; then
        rm -rf "$tmp"; dog_error "配置包含有不安全路径，已拒绝"; return 1
    fi
    for f in $CONFIG_IO_FILES; do
        tar -xzf "$archive" -C "$tmp" "port-traffic-dog-config/$f" 2>/dev/null || true
    done
    src="$tmp/port-traffic-dog-config"
    [ -s "$src/config.json" ] || { rm -rf "$tmp"; dog_error "配置包中没有 config.json"; return 1; }
    schema=$(jq -r '.schema // (if has("ports") then 1 else 0 end)' "$src/config.json" 2>/dev/null || echo 0)
    case "$schema" in
        2) validate_config_file "$src/config.json" || { rm -rf "$tmp"; dog_error "配置无效，未导入"; return 1; } ;;
        1) echo -e "${YELLOW}这是 1.5.x 导出的配置包，将按旧格式迁移（流量取包内灾备值）${NC}" ;;
        *) rm -rf "$tmp"; dog_error "无法识别的配置格式"; return 1 ;;
    esac
    if [ "$schema" = "1" ] && jq -e '[.ports[] | select((.bandwidth_limit.enabled // false))] | length > 0' "$src/config.json" >/dev/null; then
        tc_require_ntc_compatible || { rm -rf "$tmp"; return 1; }
    fi
    if has_monitors; then
        echo -e "${YELLOW}导入会替换当前全部 $(monitor_ids | grep -c .) 个监控项及其统计。${NC}"
    fi
    confirm "确认导入" || { rm -rf "$tmp"; return 0; }

    dog_lock || { rm -rf "$tmp"; return 75; }
    backup="$BACKUP_DIR/import-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup" && chmod 700 "$backup"
    has_monitors && stats_snapshot >/dev/null 2>&1 || true
    for f in $CONFIG_IO_FILES; do [ -f "$CONFIG_DIR/$f" ] && cp -p "$CONFIG_DIR/$f" "$backup/"; done
    teardown_runtime
    for f in $CONFIG_IO_FILES; do
        rm -f "$CONFIG_DIR/$f"
        [ -f "$src/$f" ] && install -m 600 "$src/$f" "$CONFIG_DIR/$f"
    done
    rm -rf "$tmp"
    if [ "$schema" = "1" ]; then
        migrate_from_legacy || rc=1
    else
        nft_rebuild_all || rc=1
        [ "$rc" -eq 0 ] && { stats_rebaseline_all || true; tc_restore_all || rc=1; }
    fi
    if [ "$rc" -ne 0 ]; then
        echo -e "${RED}导入失败，正在恢复原配置...${NC}" >&2
        teardown_runtime
        for f in $CONFIG_IO_FILES; do
            rm -f "$CONFIG_DIR/$f"
            [ -f "$backup/$f" ] && cp -p "$backup/$f" "$CONFIG_DIR/$f"
        done
        config_exists || ensure_config
        nft_rebuild_all || true
        tc_restore_all || true
    fi
    dog_unlock
    cron_sync || true
    dog_log_event import_config "$rc"
    [ "$rc" -eq 0 ] && echo -e "${GREEN}导入完成（原配置备份：$backup）${NC}"
    return "$rc"
}

# 拆除当前全部运行状态（TC 限速与 nft 表），不改配置文件。调用方持有 Dog 锁。
teardown_runtime() {
    local id iface
    if config_exists && [ "$(config_schema)" = "2" ]; then
        if begin_tc_update; then
            while IFS= read -r id; do
                [ -n "$id" ] || continue
                monitor_tc_rate "$id" >/dev/null && tc_remove_monitor_locked "$id" >/dev/null 2>&1
            done < <(monitor_ids)
            iface=$(get_default_interface 2>/dev/null) && cleanup_owned_tc_root_if_unused_locked "$iface" >/dev/null 2>&1
            finish_tc_update
        fi
    fi
    nft_table_exists && nft delete table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null || true
}

# ── 交互菜单 ──────────────────────────────────────────────────────
# 所有子菜单都是循环，返回即回到上一级（1.5.x 的菜单互相递归调用，层数越用越深）。

menu_text_width() {
    local text="$1" index character code width=0 LC_CTYPE=C.UTF-8
    for ((index=0; index<${#text}; index++)); do
        character="${text:index:1}"
        printf -v code '%d' "'$character"
        if (( code >= 0x300 && code <= 0x36f )); then continue; fi
        if (( code >= 0x1100 && (code <= 0x115f || code >= 0x2e80) )); then
            width=$((width+2))
        else width=$((width+1)); fi
    done
    printf '%s' "$width"
}

menu_columns() {
    local columns="${COLUMNS:-80}" size
    if [ -t 1 ]; then
        size=$(stty size 2>/dev/null) || size=''
        [ -z "$size" ] || columns="${size##* }"
    fi
    [[ "$columns" =~ ^[0-9]+$ ]] && [ "$columns" -ge 20 ] && [ "$columns" -le 500 ] || columns=80
    printf '%s' "$columns"
}

menu_item() {
    local number="$1" text="$2" columns="${3:-80}" index character width=4 amount
    local LC_CTYPE=C.UTF-8
    printf '%b%2s.%b ' "$BLUE" "$number" "$NC"
    for ((index=0; index<${#text}; index++)); do
        character="${text:index:1}"
        amount=$(menu_text_width "$character")
        if [ "$((width+amount))" -gt "$columns" ]; then printf '\n    '; width=4; fi
        printf '%s' "$character"
        width=$((width+amount))
    done
    printf '\n'
}

readonly -a MAIN_MENU_LABELS=(
    '添加监控项' '修改端口（加/减/替换/拆分/合并）'
    '删除监控项' '配额与自动重置'
    '带宽限制' '服务到期'
    '计费模式与备注' '立即重置流量'
    '通知管理' '系统自检/修复'
    'TC 冲突处理/自动恢复' '在线 IP / 并发限制（测试中）'
    '依赖检测/安装/卸载' '配置导出/导入'
    '查看日志' '更新脚本'
    '卸载'
)

show_main_menu_options() {
    local columns index left right width n="${#MAIN_MENU_LABELS[@]}" lw=0 rw=0
    columns=$(menu_columns)
    # 左列宽度取最长左侧标签，保证右列对齐；两列放不下时改为单列。
    for ((index = 0; index < n; index++)); do
        width=$(menu_text_width "${MAIN_MENU_LABELS[index]}")
        if ((index % 2 == 0)); then ((width > lw)) && lw=$width; else ((width > rw)) && rw=$width; fi
    done
    if [ $((4 + lw + 2 + 4 + rw)) -le "$columns" ]; then
        for ((index = 0; index < n; index += 2)); do
            left="${MAIN_MENU_LABELS[index]}"
            if [ $((index + 1)) -lt "$n" ]; then
                right="${MAIN_MENU_LABELS[index + 1]}"
                width=$(menu_text_width "$left")
                printf '%b%2d.%b %s%*s%b%2d.%b %s\n' "$BLUE" "$((index + 1))" "$NC" "$left" "$((lw - width + 2))" '' \
                    "$BLUE" "$((index + 2))" "$NC" "$right"
            else
                menu_item "$((index + 1))" "$left" "$columns"
            fi
        done
    else
        for ((index = 0; index < n; index++)); do menu_item "$((index + 1))" "${MAIN_MENU_LABELS[index]}" "$columns"; done
    fi
    menu_item 0 退出 "$columns"
}

# 监控项汇总表（只读一次 nft）。
show_monitor_table() {
    local values id idx=0 in_b out_b mult billed limit pct usage ports n
    if ! has_monitors; then
        echo "  （暂无监控项）"
        return 1
    fi
    values=$(nft_read_values 2>/dev/null || echo '{}')
    printf '  %-3s %-5s %-34s %-12s %s\n' '#' 'ID' '端口 / 备注' '周期流量' '配额 / 状态'
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        idx=$((idx + 1))
        read -r in_b out_b < <(jq -r --arg id "$id" '.[$id] // {} | "\(.in // 0) \(.out // 0)"' <<< "$values")
        mult=$(monitor_billing_multiplier "$id")
        billed=$(( (in_b + out_b) * mult ))
        ports=$(monitor_label "$id")
        n=$(monitor_ports "$id" | wc -l)
        [ "$n" -gt 1 ] && ports="$ports [${n}项]"
        usage="不限额"
        limit=$(mget "$id" .quota.monthly_limit unlimited)
        if [ "$(mget "$id" .quota.enabled false)" = "true" ] && [ "$limit" != "unlimited" ]; then
            pct=$(( billed * 100 / $(parse_size_to_bytes "$limit") ))
            usage="${limit} ${pct}%"
        fi
        monitor_is_expired "$id" && usage+=" 已到期"
        monitor_tc_rate "$id" >/dev/null && usage+=" 限速$(monitor_tc_rate "$id")"
        jq -e --arg id "$id" 'has($id)' <<< "$values" >/dev/null || usage+=" ⚠计数缺失"
        printf '  %-3s %-5s %-34s %-12s %s\n' "$idx" "$id" "$ports" "$(format_bytes "$billed")" "$usage"
    done < <(monitor_ids)
}

# 交互选择监控项：接受序号、ID（m3）或成员端口（8031）。输出 ID。
select_monitor() {
    local prompt="${1:-请选择监控项}" input ids id
    mapfile -t ids < <(monitor_ids)
    [ "${#ids[@]}" -gt 0 ] || { echo -e "${YELLOW}暂无监控项${NC}" >&2; return 1; }
    show_monitor_table >&2 || true
    read -r -p "$prompt（序号 / ID / 端口，回车取消）: " input
    [ -n "$input" ] || return 1
    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "${#ids[@]}" ] && [ "$input" -le 999 ]; then
        echo "${ids[$((input - 1))]}"
        return 0
    fi
    if id=$(resolve_monitor "$input"); then echo "$id"; return 0; fi
    echo -e "${RED}找不到监控项：$input${NC}" >&2
    return 1
}

menu_add_monitor() {
    local input units unit remark id
    echo -e "${BLUE}=== 添加监控项 ===${NC}"
    show_listening_ports
    echo
    echo -e "格式：${GREEN},${NC} 组合多个端口为一个监控项（共享统计/配额/限速），${GREEN};${NC} 分隔多个独立监控项，${GREEN}-${NC} 表示端口段"
    echo -e "例：${GREEN}80,443${NC} 一个监控项；${GREEN}80,443;8080-8090${NC} 两个监控项"
    read -r -p "端口: " input
    [ -n "$input" ] || return 0
    parse_monitor_units "$input" units || { pause; return 1; }
    read -r -p "备注（可留空）: " remark
    for unit in "${units[@]}"; do
        if id=$(monitor_add "$unit" "$remark"); then
            echo -e "${GREEN}已添加 $id：$unit${NC}"
        else
            echo -e "${RED}添加 $unit 失败${NC}"
        fi
    done
    cron_sync || true
    if [ "${#units[@]}" -eq 1 ] && [ -n "${id:-}" ] && confirm "现在设置配额与自动重置"; then
        menu_quota_for "$id"
    fi
}

menu_edit_ports() {
    local id choice input target remark copy
    id=$(select_monitor "要修改的监控项") || return 0
    while monitor_exists "$id"; do
        echo
        echo -e "${BLUE}=== 修改端口：$id $(monitor_label "$id") ===${NC}"
        echo "当前成员：$(monitor_ports_csv "$id")"
        echo "1. 添加端口/端口段（流量继续累计）"
        echo "2. 删除端口（已统计流量保留在本项）"
        echo "3. 整组替换端口"
        echo "4. 拆出部分端口为新监控项（新项从 0 开始计）"
        echo "5. 把本项合并到另一个监控项（流量相加）"
        echo "0. 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1) read -r -p "要添加的端口（逗号分隔）: " input
               [ -n "$input" ] && input=$(parse_port_list "$input" | paste -sd,) && monitor_edit_ports "$id" "$input" "" "" &&
                   echo -e "${GREEN}已更新：$(monitor_ports_csv "$id")${NC}" ;;
            2) read -r -p "要删除的成员（逗号分隔，端口段按原样写）: " input
               [ -n "$input" ] && input=$(parse_port_list "$input" | paste -sd,) && monitor_edit_ports "$id" "" "$input" "" &&
                   echo -e "${GREEN}已更新：$(monitor_ports_csv "$id")${NC}" ;;
            3) read -r -p "新的完整端口列表: " input
               [ -n "$input" ] && input=$(parse_port_list "$input" | paste -sd,) && monitor_edit_ports "$id" "" "" "$input" &&
                   echo -e "${GREEN}已更新：$(monitor_ports_csv "$id")${NC}" ;;
            4) read -r -p "要拆出的成员（逗号分隔）: " input
               [ -n "$input" ] || continue
               input=$(parse_port_list "$input" | paste -sd,) || continue
               read -r -p "新监控项备注（可留空）: " remark
               copy=""; confirm "新项是否复制本项的配额、重置策略和到期日" && copy=copy
               if target=$(monitor_split "$id" "$input" "$remark" "$copy"); then
                   echo -e "${GREEN}已拆出新监控项 $target${NC}"
               fi ;;
            5) target=$(select_monitor "合并到哪个监控项") || continue
               [ "$target" != "$id" ] || { echo -e "${RED}不能合并到自身${NC}"; continue; }
               echo "将把 $id 的端口与流量并入 $target，$id 的配额/限速/到期设置作废，以 $target 为准。"
               confirm "确认合并" || continue
               if monitor_merge "$id" "$target"; then
                   echo -e "${GREEN}已合并到 $target${NC}"
                   return 0
               fi ;;
            0|"") return 0 ;;
        esac
    done
}

menu_remove_monitor() {
    local id
    id=$(select_monitor "要删除的监控项") || return 0
    confirm "确认删除 $id（$(monitor_label "$id")）及其统计、配额、限速与到期设置" || return 0
    monitor_remove "$id" && echo -e "${GREEN}已删除 $id${NC}"
    cron_sync || true
}

menu_quota_for() {
    local id="$1" limit policy
    echo "当前配额：$(mget "$id" .quota.monthly_limit unlimited)（$(mget "$id" .billing_mode double) 计费）"
    read -r -p "流量配额（如 500GB、1.5TB；0 取消；回车不变）: " limit
    if [ -n "$limit" ]; then
        monitor_set_quota "$id" "$limit" && echo -e "${GREEN}配额已更新${NC}"
    fi
    if confirm "设置自动重置策略（当前：$(monitor_reset_label "$id" 2>/dev/null || echo 不自动重置)）"; then
        policy=$(prompt_reset_policy "$(mget "$id" .reset_policy.day 1)") || return 0
        monitor_set_reset_policy "$id" "$policy" && echo -e "${GREEN}重置策略已更新：$(monitor_reset_label "$id" 2>/dev/null || echo 不自动重置)${NC}"
    fi
}

menu_quota_reset() {
    local id
    id=$(select_monitor "设置配额/重置的监控项") || return 0
    menu_quota_for "$id"
}

menu_bandwidth() {
    local id input rate
    id=$(select_monitor "设置带宽限制的监控项") || return 0
    echo "当前：$(monitor_tc_rate "$id" 2>/dev/null || echo 不限速)（上下行分别限制，同项端口共享）"
    read -r -p "带宽（如 100Mbps、1Gbps；0 取消）: " input
    [ -n "$input" ] || return 0
    validate_bandwidth "$input" || { echo -e "${RED}格式无效${NC}"; return 1; }
    if [ "$input" = "0" ]; then rate=0; else rate=$(convert_bandwidth_to_tc "$input"); fi
    if [ "$rate" != "0" ] && [ "$(tc_auto_recovery_state 2>/dev/null || echo disabled)" != "enabled" ]; then
        show_tc_auto_recovery_notice 2>/dev/null || true
    fi
    tc_set_monitor_limit "$id" "$rate" && echo -e "${GREEN}带宽限制已更新${NC}"
}

menu_expiry() {
    local id input
    id=$(select_monitor "设置服务到期的监控项") || return 0
    echo "当前：$(monitor_expiry_label "$id" 2>/dev/null || echo 未设置)"
    read -r -p "到期日 YYYY-MM-DD（输入 0 取消到期）: " input
    [ -n "$input" ] || return 0
    [ "$input" = "0" ] && input=""
    monitor_set_expiry "$id" "$input" && echo -e "${GREEN}到期设置已更新${NC}"
}

menu_billing_remark() {
    local id choice input
    id=$(select_monitor "要修改的监控项") || return 0
    echo "1. 计费模式（当前：$(mget "$id" .billing_mode double)）"
    echo "2. 备注（当前：$(mget "$id" .remark "")）"
    read -r -p "请选择: " choice
    case "$choice" in
        1) echo "double：入站+出站，各按 2 倍计（与上游一致）；single：入站+出站按 1 倍计"
           read -r -p "模式 [double/single]: " input
           [ -n "$input" ] && monitor_set_billing "$id" "$input" && echo -e "${GREEN}已切换${NC}" ;;
        2) read -r -p "新备注（最长 64 字符，留空清除）: " input
           monitor_set_remark "$id" "$input" && echo -e "${GREEN}已更新${NC}" ;;
    esac
}

menu_reset_now() {
    local id
    id=$(select_monitor "要立即清零流量的监控项") || return 0
    confirm "确认清零 $id 的本周期流量与已用配额（自动重置日程不变）" || return 0
    reset_monitor "$id" manual && echo -e "${GREEN}已清零${NC}"
}

menu_config_io() {
    local choice file
    echo "1. 导出配置与统计"
    echo "2. 导入配置包"
    read -r -p "请选择: " choice
    case "$choice" in
        1) export_config ;;
        2) read -r -p "配置包路径: " file; [ -n "$file" ] && import_config "$file" ;;
    esac
}

show_dashboard() {
    local total=0 values id machine
    echo -e "${BLUE}=== ${SCRIPT_NAME} v${SCRIPT_VERSION} ===${NC}"
    if has_monitors; then
        values=$(nft_read_values 2>/dev/null || echo '{}')
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            total=$(( total + $(jq -r --arg id "$id" '.[$id] // {} | ((.in // 0) + (.out // 0))' <<< "$values") * $(monitor_billing_multiplier "$id") ))
        done < <(monitor_ids)
        echo -e "${GREEN}状态: 监控中${NC} | 监控项 $(monitor_ids | grep -c .) 个 | 周期总流量 $(format_bytes "$total")"
    else
        echo -e "${YELLOW}状态: 未添加监控项${NC}"
    fi
    machine=$(machine_traffic_summary 2>/dev/null || true)
    [ -n "$machine" ] && echo "$machine"
    show_monitor_table >/dev/null 2>&1 && show_monitor_table
    if ! nft_runtime_drift >/dev/null 2>&1 && has_monitors; then
        echo -e "${YELLOW}⚠ nftables 规则与配置不一致，建议执行 10. 系统自检/修复${NC}"
    fi
    if has_monitors && ! cron_in_sync 2>/dev/null; then
        echo -e "${YELLOW}⚠ 定时任务与配置不一致，建议执行 10. 系统自检/修复${NC}"
    fi
}

show_main_menu() {
    local choice
    while true; do
        menu_clear
        show_dashboard
        echo
        show_main_menu_options
        read -r -p "请选择操作: " choice || exit 0
        case "$choice" in
            1) menu_add_monitor ;;
            2) menu_edit_ports ;;
            3) menu_remove_monitor ;;
            4) menu_quota_reset ;;
            5) menu_bandwidth ;;
            6) menu_expiry ;;
            7) menu_billing_remark ;;
            8) menu_reset_now ;;
            9) manage_notifications; continue ;;
            10) system_check_and_repair ;;
            11) manage_tc_recovery ;;
            12) manage_ip_guard; continue ;;
            13) dependency_menu ;;
            14) menu_config_io ;;
            15) show_operation_logs ;;
            16) update_dog ;;
            17) uninstall_dog && exit 0 ;;
            0) exit 0 ;;
            *) continue ;;
        esac
        pause
    done
}

# ── 自检与修复 ────────────────────────────────────────────────────

SC_ERRORS=0
SC_WARNINGS=0
sc_ok() { echo -e "  ${GREEN}✓${NC} $*"; }
sc_warn() { echo -e "  ${YELLOW}!${NC} $*"; SC_WARNINGS=$((SC_WARNINGS + 1)); }
sc_err() { echo -e "  ${RED}✗${NC} $*"; SC_ERRORS=$((SC_ERRORS + 1)); }

nft_version_ok() {
    local v
    v=$(nft --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
    [ -n "$v" ] && ! version_lt "$v" "0.9.2"
}

# 只读自检；有错误返回 1。
self_check() {
    local exe cmd rt drift id age saved c
    SC_ERRORS=0; SC_WARNINGS=0
    echo -e "${BLUE}=== Dog 自检（v${SCRIPT_VERSION}） ===${NC}"

    echo "[运行环境]"
    for cmd in nft jq tc ip crontab curl flock awk ss sha256sum; do
        if command -v "$cmd" >/dev/null 2>&1; then :; else sc_err "缺少命令：$cmd"; fi
    done
    if nft_version_ok; then sc_ok "nftables $(nft --version 2>/dev/null | awk '{print $2}')（需要 ≥ 0.9.2）"; else sc_err "nftables 版本过低或不可用（需要 ≥ 0.9.2）"; fi
    exe=$(get_script_exec_path)
    # 用 cron 的最小环境运行一次，确认脚本自身能找到 nft（1.5.x 的空推送就是在这里失败）。
    if env -i HOME=/root PATH=/usr/bin:/bin "$exe" --cron-env-probe >/dev/null 2>&1; then
        sc_ok "cron 最小环境（PATH=/usr/bin:/bin）下可找到 nft 与 jq"
    else
        sc_err "cron 最小环境下脚本无法运行或找不到 nft：$exe"
    fi
    if cron_service_is_running; then sc_ok "cron 服务运行中"; else sc_err "cron 服务未运行，定时统计/重置/推送不会执行"; fi

    echo "[配置]"
    if ! config_exists; then
        sc_warn "尚未创建配置"
    elif [ "$(config_schema)" = "1" ]; then
        sc_err "仍是 1.5.x 配置，请运行 dog --repair 完成迁移"
    else
        # 校验错误直接收进变量：不在 /tmp 用可预测文件名（root 写入可被符号链接劫持）。
        local verr
        if verr=$(validate_config_file "$CONFIG_FILE" 2>&1 >/dev/null); then
            sc_ok "配置有效：$(monitor_ids | grep -c .) 个监控项"
        else
            while IFS= read -r c; do [ -n "$c" ] && sc_err "$c"; done <<< "$verr"
        fi
    fi
    [ "$(config_schema)" = "2" ] || { echo; echo "错误 $SC_ERRORS，警告 $SC_WARNINGS"; [ "$SC_ERRORS" -eq 0 ]; return; }

    echo "[nftables 计数与配额]"
    if has_monitors; then
        rt=$(nft_runtime_json 2>/dev/null || echo null)
        if [ "$rt" = "null" ]; then
            sc_err "表 $NFT_FAMILY $NFT_TABLE 不存在"
        elif drift=$(nft_runtime_drift "$rt"); then
            sc_ok "规则、计数器、配额、到期封锁与配置一致"
        else
            while IFS= read -r c; do sc_err "$c"; done <<< "$drift"
        fi
    else
        sc_ok "无监控项"
    fi

    echo "[带宽限制]"
    local any_tc=false
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        monitor_tc_rate "$id" >/dev/null || continue
        any_tc=true
        if tc_monitor_complete "$id"; then sc_ok "$id 限速 $(monitor_tc_rate "$id") 完整"; else sc_err "$id 限速对象缺失或不一致"; fi
    done < <(monitor_ids)
    [ "$any_tc" = "true" ] || sc_ok "未设置限速"
    if [ -e /etc/trafficcop-lite/trafficcop-lite-monitor.sh ]; then
        if tc_ntc_compatible; then sc_ok "TrafficCop Lite 已安装且支持 Dog 2.0 类清单"
        elif [ "$any_tc" = "true" ]; then sc_err "TrafficCop Lite 版本过旧（不识别 $TC_CLASS_MANIFEST_SCHEMA），请升级到 1.2.0+"
        else sc_warn "TrafficCop Lite 版本过旧；设置限速前需先升级"; fi
    fi
    if [ "$any_tc" = "true" ] && [ ! -s "$TC_INTEROP_FILE" ]; then sc_err "缺少类清单 $TC_INTEROP_FILE"; fi

    echo "[定时任务与数据]"
    if cron_in_sync; then sc_ok "Dog 定时任务与配置一致"; else sc_err "Dog 定时任务缺失或与配置不一致"; fi
    if has_monitors; then
        saved=$(jq -r '.saved_at // empty' "$TRAFFIC_DATA_FILE" 2>/dev/null || true)
        if [ -n "$saved" ]; then
            age=$(( $(date +%s) - $(date -d "$saved" +%s 2>/dev/null || echo 0) ))
            if [ "$age" -le 300 ]; then sc_ok "流量灾备 ${age}s 前更新"; else sc_warn "流量灾备已 $((age / 60)) 分钟未更新（定时任务可能未执行）"; fi
        else
            sc_warn "尚无流量灾备文件"
        fi
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            monitor_has_auto_reset "$id" || continue
            monitor_next_reset "$id" >/dev/null 2>&1 || sc_err "$id 无法计算下次重置日期"
        done < <(monitor_ids)
    fi

    echo "[通知]"
    for c in telegram wecom; do
        channel_enabled "$c" || continue
        if [ "$c" = telegram ]; then
            [ -n "$(cfg '.notifications.telegram.bot_token // ""')" ] && [ -n "$(cfg '.notifications.telegram.chat_id // ""')" ] &&
                sc_ok "Telegram 已配置（推送 $(channel_status_enabled telegram && cfg '.notifications.telegram.status_notifications.interval' || echo 关闭)）" ||
                sc_err "Telegram 已开启但 Token/Chat ID 不完整"
            telegram_api_base >/dev/null || sc_err "Telegram 自定义线路无效"
        else
            [ -n "$(cfg '.notifications.wecom.webhook_url // ""')" ] && sc_ok "企业微信已配置" || sc_err "企业微信已开启但未设置 Webhook"
        fi
    done

    echo
    if [ "$SC_ERRORS" -eq 0 ]; then
        echo -e "${GREEN}自检通过${NC}（警告 $SC_WARNINGS）"
    else
        echo -e "${RED}发现 $SC_ERRORS 个错误${NC}（警告 $SC_WARNINGS），可运行 dog --repair 自动修复"
    fi
    [ "$SC_ERRORS" -eq 0 ]
}

# 修复：补依赖、迁移、重建规则与限速、刷新定时任务，然后自检。
system_check_and_repair() {
    echo -e "${BLUE}=== 系统修复 ===${NC}"
    # 只检测一次；缺失时交给 dependency_install_missing（--yes 时自动装，否则询问）。
    # check_dependencies 自带无确认安装，不能与之串用（会绕过确认并重复执行 apt）。
    dependency_report core >/dev/null 2>&1 || dependency_install_missing "$DOG_NONINTERACTIVE" core || true
    ensure_config || return 1
    if legacy_needs_migration; then migrate_from_legacy || return 1; fi
    validate_config_file "$CONFIG_FILE" || { dog_error "配置无效，请先修正 $CONFIG_FILE"; return 1; }
    create_shortcut || true
    if [ "$SCRIPT_PATH" != "$INSTALLED_SCRIPT_PATH" ] && [ ! -f "$INSTALLED_SCRIPT_PATH" ]; then install_self || true; fi
    dog_lock || return 75
    echo "· 修复 nftables 规则"; runtime_ensure_nft || true
    echo "· 同步到期封锁"; check_expirations || true
    echo "· 刷新统计与灾备"; stats_snapshot || true
    dog_unlock
    echo "· 恢复带宽限制"; tc_restore_all || true
    echo "· 刷新定时任务"; cron_sync || true
    echo
    self_check
}

# ── 命令行入口 ────────────────────────────────────────────────────

show_usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

用法：dog                         打开交互菜单
      dog list [--json]           列出监控项
      dog status                  打印状态报告（与推送内容相同）
      dog add <端口> [--remark R]  添加监控项；"80,443" 为一项，"80;443" 为两项，"8000-8010" 为端口段
      dog edit <ID|端口> [选项]    修改监控项：
          --add P,P   --del P,P   --set P,P        增加 / 删除 / 整组替换端口（流量连续）
          --remark R  --quota 500GB|0  --billing double|single
          --limit 100Mbps|0  --expiry YYYY-MM-DD|0
          --reset monthly:1 | days:30[@YYYY-MM-DD] | months:3[@YYYY-MM-DD][:15] | yearly:1-1 | once:YYYY-MM-DD | none
      dog split <ID> <端口> [--remark R] [--copy]   拆出为新监控项（--copy 复制配额/重置/到期）
      dog merge <源ID> <目标ID>                     合并（流量相加，保留目标设置）
      dog remove <ID|端口>        删除监控项
      dog reset <ID|端口>         立即清零本周期流量
      --yes                       非交互确认

维护：--self-check  --repair  --restore-runtime  --tc-status  --recover-tc --manual|--auto
      --update [--force]  --uninstall [--keep-config]  --export [目录]  --import <文件>
      --dependencies check|install|owned|remove [--all] [--yes]  --logs  --version
EOF
}

# "monthly:1" 等简写 → 重置策略 JSON
parse_reset_spec() {
    local s="$1" today
    today=$(get_current_date)
    case "$s" in
        none) echo '{"type":"none"}' ;;
        monthly:*) validate_day_1_31 "${s#*:}" && jq -cn --argjson d "${s#*:}" '{type:"monthly",day:$d}' ;;
        days:*)
            local rest="${s#days:}" n a
            n="${rest%%@*}"; a="$today"; [[ "$rest" == *@* ]] && a="${rest#*@}"
            [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && is_valid_date "$a" &&
                jq -cn --argjson e "$n" --arg a "$a" '{type:"interval_days",every:$e,anchor_date:$a}' ;;
        months:*)
            local rest="${s#months:}" n a d
            n="${rest%%[@:]*}"; a="$today"; d=""
            if [[ "$rest" == *@* ]]; then a="${rest#*@}"; a="${a%%:*}"; fi
            [[ "$rest" =~ :([0-9]+)$ ]] && d="${BASH_REMATCH[1]}"
            [ -n "$d" ] || d=$((10#${a:8:2}))
            [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && is_valid_date "$a" && validate_day_1_31 "$d" &&
                jq -cn --argjson e "$n" --arg a "$a" --argjson d "$d" '{type:"interval_months",every:$e,anchor_date:$a,day:$d}' ;;
        yearly:*-*)
            local m="${s#yearly:}"; local d="${m#*-}"; m="${m%-*}"
            validate_month_1_12 "$m" && validate_day_1_31 "$d" && jq -cn --argjson m "$m" --argjson d "$d" '{type:"yearly",month:$m,day:$d}' ;;
        once:*) is_valid_date "${s#once:}" && jq -cn --arg d "${s#once:}" '{type:"fixed_date",date:$d}' ;;
        *) return 1 ;;
    esac
}

cli_list() {
    if [ "${1:-}" = "--json" ]; then
        jq -n --argjson c "$(jq '.monitors' "$CONFIG_FILE")" --argjson v "$(nft_read_values)" '
            $c | to_entries | map(.value + {id: .key, counters: ($v[.key] // null)})'
    else
        show_monitor_table || true
    fi
}

cli_edit() {
    local ref="$1" id add="" del="" set="" rc=0
    shift
    id=$(resolve_monitor "$ref") || { dog_error "找不到监控项：$ref"; return 1; }
    local -a ops=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --add|--del|--set) [ -n "${2:-}" ] || { show_usage; return 2; }
                local v; v=$(parse_port_list "$2" | paste -sd,) || return 1
                case "$1" in --add) add="$v" ;; --del) del="$v" ;; --set) set="$v" ;; esac; shift 2 ;;
            --remark|--quota|--billing|--limit|--expiry|--reset)
                [ "$#" -ge 2 ] || { show_usage; return 2; }
                ops+=("$1" "$2"); shift 2 ;;
            *) dog_error "未知选项：$1"; return 2 ;;
        esac
    done
    if [ -n "$add$del$set" ]; then
        monitor_edit_ports "$id" "$add" "$del" "$set" || rc=1
    fi
    local i
    for ((i = 0; i < ${#ops[@]}; i += 2)); do
        local opt="${ops[i]}" val="${ops[i+1]}"
        case "$opt" in
            --remark) monitor_set_remark "$id" "$val" || rc=1 ;;
            --quota) monitor_set_quota "$id" "$val" || rc=1 ;;
            --billing) monitor_set_billing "$id" "$val" || rc=1 ;;
            --expiry) [ "$val" = "0" ] && val=""; monitor_set_expiry "$id" "$val" || rc=1 ;;
            --limit)
                if [ "$val" = "0" ]; then tc_set_monitor_limit "$id" 0 || rc=1
                elif validate_bandwidth "$val"; then tc_set_monitor_limit "$id" "$(convert_bandwidth_to_tc "$val")" || rc=1
                else dog_error "带宽格式无效：$val"; rc=1; fi ;;
            --reset)
                local p; p=$(parse_reset_spec "$val") || { dog_error "重置策略格式无效：$val"; rc=1; continue; }
                monitor_set_reset_policy "$id" "$p" || rc=1 ;;
        esac
    done
    [ "$rc" -eq 0 ] && echo "$id: $(monitor_ports_csv "$id")"
    return "$rc"
}

main() {
    local args=() a
    for a in "$@"; do
        if [ "$a" = "--yes" ] || [ "$a" = "-y" ]; then DOG_NONINTERACTIVE=true; else args+=("$a"); fi
    done
    set -- "${args[@]+"${args[@]}"}"

    case "${1:-}" in
        --version|-v) echo "$SCRIPT_NAME v$SCRIPT_VERSION"; return 0 ;;
        --help|-h|help) show_usage; return 0 ;;
        --cron-env-probe) command -v nft >/dev/null && command -v jq >/dev/null; return ;;
        --validate-config) [ -n "${2:-}" ] || return 2; validate_config_file "$2"; return ;;
    esac
    check_root

    case "${1:-}" in
        --dependencies) shift; dependency_cli "$@"; return ;;
        --uninstall) uninstall_dog "${2:-}"; return ;;
        --logs) show_operation_logs; return ;;   # 只读，不创建配置目录
    esac

    if ! command -v jq >/dev/null 2>&1 || ! command -v nft >/dev/null 2>&1; then
        if is_interactive; then
            dependency_install_missing false core || { dog_error "缺少 jq/nft，无法继续"; return 1; }
        else
            dog_error "缺少 jq 或 nft，无法继续（PATH=$PATH）"; return 1
        fi
    fi
    ensure_config || return 1
    if legacy_needs_migration; then
        migrate_from_legacy || return 1
    fi

    local cmd="${1:-}"
    [ "$#" -gt 0 ] && shift
    case "$cmd" in
        "")
            [ -f "$INSTALLED_SCRIPT_PATH" ] && [ -x "$SHORTCUT_PATH" ] || install_self || true
            validate_config_file "$CONFIG_FILE" || { dog_error "配置无效，请修正 $CONFIG_FILE 或运行 dog --repair"; return 1; }
            show_main_menu ;;
        list) cli_list "$@" ;;
        status) build_status_report "$(hostname)" ;;
        add)
            [ -n "${1:-}" ] || { show_usage; return 2; }
            local input="$1" remark="" units u rc=0
            [ "${2:-}" = "--remark" ] && remark="${3:-}"
            parse_monitor_units "$input" units || return 1
            for u in "${units[@]}"; do monitor_add "$u" "$remark" || rc=1; done
            cron_sync || true
            return "$rc" ;;
        edit) [ -n "${1:-}" ] || { show_usage; return 2; }; cli_edit "$@" ;;
        split)
            [ -n "${2:-}" ] || { show_usage; return 2; }
            local sid sp sr="" sc=""
            sid=$(resolve_monitor "$1") || { dog_error "找不到监控项：$1"; return 1; }
            sp=$(parse_port_list "$2" | paste -sd,) || return 1
            shift 2
            while [ "$#" -gt 0 ]; do
                case "$1" in --remark) sr="${2:-}"; shift 2 ;; --copy) sc=copy; shift ;; *) return 2 ;; esac
            done
            monitor_split "$sid" "$sp" "$sr" "$sc" ;;
        merge)
            [ -n "${2:-}" ] || { show_usage; return 2; }
            local ms md
            ms=$(resolve_monitor "$1") && md=$(resolve_monitor "$2") || { dog_error "找不到监控项"; return 1; }
            monitor_merge "$ms" "$md" ;;
        remove|rm)
            local rid; rid=$(resolve_monitor "${1:-}") || { dog_error "找不到监控项：${1:-}"; return 1; }
            confirm "确认删除 $rid（$(monitor_label "$rid")）" || return 1
            monitor_remove "$rid" && cron_sync ;;
        reset)
            local zid; zid=$(resolve_monitor "${1:-}") || { dog_error "找不到监控项：${1:-}"; return 1; }
            confirm "确认清零 $zid 本周期流量" || return 1
            reset_monitor "$zid" manual ;;

        # 定时任务入口
        --tick) cron_tick ;;
        --boot|--restore-nft-runtime) restore_runtime_nft_only ;;
        --send-status) send_status_report "${1:-telegram}" ;;
        --send-telegram-status) send_status_report telegram ;;
        --send-wecom-status) send_status_report wecom ;;
        # 1.5.x 旧定时任务兼容（cron 刷新前仍可能被调用）
        --snapshot-traffic|--check-scheduled-resets|--check-port-expirations|--collect-machine-traffic)
            cron_tick ;;

        --self-check) self_check ;;
        --repair|--repair-traffic-rules|--refresh-all-cron) system_check_and_repair ;;
        --refresh-notification-cron|--refresh-port-reset-cron) cron_sync ;;
        --sync-notification-modules) echo "2.0 起通知功能已内置，无需同步模块" ;;
        --restore-runtime) restore_runtime ;;
        --tc-status) dog_tc_status ;;
        --recover-tc) recover_tc_runtime "${1:---manual}" ;;
        --install) install_self && cron_sync ;;
        # --finalize-update：1.5.x 的 --update 装好新脚本后调用的入口，失败时由旧版负责回滚。
        --post-update|--finalize-update) post_update ;;
        --update) update_dog "${1:-}" ;;
        --export) export_config "${1:-/root}" ;;
        --import) [ -n "${1:-}" ] || return 2; import_config "$1" ;;
        *) show_usage; return 2 ;;
    esac
}

main "$@"
