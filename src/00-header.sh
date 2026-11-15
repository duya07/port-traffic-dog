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
