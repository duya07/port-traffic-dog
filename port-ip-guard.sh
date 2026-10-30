#!/bin/bash

set -euo pipefail
umask 077

# PORT_TRAFFIC_DOG_IP_GUARD
# 独立实验组件：按本机 TCP 服务端口限制同时在线 IP 数和并发连接数。

CONFIG_DIR="${PTD_IP_GUARD_CONFIG_DIR:-/etc/port-traffic-dog}"
CONFIG_FILE="${PTD_IP_GUARD_CONFIG_FILE:-$CONFIG_DIR/ip-guard.json}"
LOCK_FILE="${PTD_IP_GUARD_LOCK_FILE:-/run/lock/port-traffic-dog-ip-guard.lock}"
TABLE_NAME="${PTD_IP_GUARD_TABLE_NAME:-port_traffic_dog_ip_guard}"
readonly TABLE_OWNER_MARKER="port-traffic-dog-ip-guard:v1"
SERVICE_NAME="${PTD_IP_GUARD_SERVICE_NAME:-port-traffic-dog-ip-guard.service}"
SERVICE_FILE="${PTD_IP_GUARD_SERVICE_FILE:-/etc/systemd/system/$SERVICE_NAME}"
readonly SERVICE_OWNER_MARKER="# PORT_TRAFFIC_DOG_IP_GUARD_SERVICE:v1"
INSTALLED_SCRIPT="${PTD_IP_GUARD_SCRIPT_PATH:-$CONFIG_DIR/port-ip-guard.sh}"
SYSTEMCTL="${PTD_IP_GUARD_SYSTEMCTL:-systemctl}"
RECONCILE_SECONDS="${PTD_IP_GUARD_RECONCILE_SECONDS:-2}"
QUEUE_NUMBER="${PTD_IP_GUARD_QUEUE_NUMBER:-47683}"
DAEMON_STATE_FILE="$CONFIG_DIR/ip-guard-state.json"
readonly MAX_LIMIT=65535
# 一个来源 IP 没有任何活跃流之后，还保留多久名额（秒）。
# 太小会让刚切走的 IP 立刻被顶掉，太大则断连的 IP 长期占位；300 秒是折中值。
readonly DEFAULT_IDLE_TIMEOUT=300

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

declare -A POLICY_LIMIT=()
declare -A POLICY_IDLE=()
declare -A POLICY_CONNECTIONS=()
TABLE_STATE="error"
DAEMON_LISTENER_PID=""
DAEMON_EVENT_FIFO=""
DAEMON_STOP_REQUESTED=false

usage() {
    cat >&2 <<EOF
用法:
  $0
  $0 --run [--confirm-restrict-ssh RESTRICT_SSH]
  $0 --apply|--apply-if-configured [--confirm-restrict-ssh RESTRICT_SSH]
  $0 --self-check
  $0 --validate-config <配置文件>
  $0 --render-rules
  $0 --fail-open
  $0 --uninstall [--yes]
EOF
}

check_bash_version() {
    if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
        echo "此功能需要 Bash 4.0 或更高版本。" >&2
        return 1
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 权限运行此脚本。" >&2
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_absolute_path() {
    local path="${1:-}"
    [ -n "$path" ] && [[ "$path" == /* ]] && [[ "$path" != *[$'\r\n\t ']* ]]
}

validate_runtime_settings() {
    [[ "$TABLE_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]{0,63}$ ]] || {
        echo "无效的 nftables 表名: $TABLE_NAME" >&2
        return 1
    }
    [[ "$SERVICE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*\.service$ ]] || {
        echo "无效的 systemd 服务名: $SERVICE_NAME" >&2
        return 1
    }
    [[ "$SYSTEMCTL" =~ ^([A-Za-z0-9_.+-]+|/[A-Za-z0-9_./+-]+)$ ]] || {
        echo "无效的 systemctl 命令路径。" >&2
        return 1
    }
    if ! [[ "$RECONCILE_SECONDS" =~ ^[0-9]+$ ]] ||
       [ "$RECONCILE_SECONDS" -lt 1 ] || [ "$RECONCILE_SECONDS" -gt 86400 ]; then
        echo "PTD_IP_GUARD_RECONCILE_SECONDS 必须是 1-86400 的整数。" >&2
        return 1
    fi
    if ! [[ "$QUEUE_NUMBER" =~ ^[0-9]+$ ]] || [ "$QUEUE_NUMBER" -gt 65535 ]; then
        echo "PTD_IP_GUARD_QUEUE_NUMBER 必须是 0-65535 的整数。" >&2
        return 1
    fi
    local path
    for path in "$CONFIG_DIR" "$CONFIG_FILE" "$LOCK_FILE" "$SERVICE_FILE" "$INSTALLED_SCRIPT"; do
        validate_absolute_path "$path" || {
            echo "路径必须是无空白字符的绝对路径: $path" >&2
            return 1
        }
    done
    [[ "$INSTALLED_SCRIPT" =~ ^/[A-Za-z0-9_./@+-]+$ ]] || {
        echo "安装脚本路径含有 systemd ExecStart 不接受的字符。" >&2
        return 1
    }
}

check_dependencies() {
    local missing=()
    local command_name
    for command_name in nft jq conntrack flock ip ss python3; do
        command_exists "$command_name" || missing+=("$command_name")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "缺少依赖: ${missing[*]}（Debian/Ubuntu 可安装 nftables jq conntrack iproute2 python3 libnetfilter-queue1）" >&2
        return 1
    fi
    python3 -c 'import ctypes; ctypes.CDLL("libnetfilter_queue.so.1")' 2>/dev/null || {
        echo "缺少 libnetfilter_queue.so.1（Debian/Ubuntu: apt install libnetfilter-queue1）。" >&2
        return 1
    }
}

check_validation_dependency() {
    command_exists jq || {
        echo "缺少依赖: jq" >&2
        return 1
    }
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_limit() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 0 ] && [ "$1" -le "$MAX_LIMIT" ]
}

validate_address_token() {
    local address="${1:-}"
    if [[ "$address" == *:* ]]; then
        [[ "$address" =~ ^[0-9A-Fa-f:.]+$ ]]
    else
        [[ "$address" =~ ^[0-9.]+$ ]]
    fi
}

init_config() {
    local temp_file
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR" 2>/dev/null || true
    if [ ! -f "$CONFIG_FILE" ]; then
        temp_file=$(mktemp "$CONFIG_DIR/.ip-guard.json.XXXXXX") || return 1
        if ! printf '%s\n' '{"schema":"port-traffic-dog-ip-guard-v1","ports":{}}' > "$temp_file"; then
            rm -f "$temp_file"
            return 1
        fi
        if ! chmod 600 "$temp_file" || ! mv -f "$temp_file" "$CONFIG_FILE"; then
            rm -f "$temp_file"
            return 1
        fi
    fi
    validate_config
}

validate_config_file() {
    local config_path="$1"
    [ -f "$config_path" ] || {
        echo "配置文件不存在或不是普通文件: $config_path" >&2
        return 1
    }
    jq -e --argjson max "$MAX_LIMIT" '
        type == "object" and
        ((keys | sort) == ["ports", "schema"]) and
        (.schema == "port-traffic-dog-ip-guard-v1") and
        (.ports | type == "object") and
        ([.ports | to_entries[] |
            (.key | test("^[0-9]+$") and (tonumber >= 1) and (tonumber <= 65535) and ((tonumber | tostring) == .)) and
            (.value | type == "object") and
            (((.value | keys) - ["max_ips", "max_connections", "idle_timeout"]) == []) and
            (.value.max_ips | type == "number") and
            (.value.max_ips >= 0) and (.value.max_ips <= $max) and
            ((.value.max_ips | floor) == .value.max_ips) and
            (.value | (has("max_connections") | not) or (.max_connections | type == "number")) and
            (.value | (has("idle_timeout") | not) or (.idle_timeout | type == "number")) and
            ((.value.max_connections // 0) | type == "number") and
            ((.value.max_connections // 0) >= 0) and ((.value.max_connections // 0) <= $max) and
            (((.value.max_connections // 0) | floor) == (.value.max_connections // 0)) and
            ((.value.idle_timeout // $idle) | type == "number") and
            ((.value.idle_timeout // $idle) >= 0) and
            ((.value.idle_timeout // $idle) <= 86400) and
            (((.value.idle_timeout // $idle) | floor) == (.value.idle_timeout // $idle))
        ] | all)
    ' --argjson idle "$DEFAULT_IDLE_TIMEOUT" "$config_path" >/dev/null || {
        echo "IP 上限配置格式或取值无效: $config_path" >&2
        return 1
    }
}

validate_config() {
    validate_config_file "$CONFIG_FILE"
}

update_config() {
    local filter="$1"
    shift
    local temp_file
    temp_file=$(mktemp "$CONFIG_DIR/.ip-guard.json.XXXXXX") || return 1
    if jq "$@" "$filter" "$CONFIG_FILE" > "$temp_file" && validate_config_file "$temp_file"; then
        if ! chmod 600 "$temp_file" || ! mv -f "$temp_file" "$CONFIG_FILE"; then
            rm -f "$temp_file"
            return 1
        fi
    else
        rm -f "$temp_file"
        return 1
    fi
}

update_config_and_apply() {
    local filter="$1"
    local ssh_confirmation="$2"
    shift 2
    local backup_file

    backup_file=$(mktemp "$CONFIG_DIR/.ip-guard.rollback.XXXXXX") || return 1
    if ! cp -p "$CONFIG_FILE" "$backup_file"; then
        rm -f "$backup_file"
        return 1
    fi
    if ! update_config "$filter" "$@"; then
        rm -f "$backup_file"
        return 1
    fi
    if apply_if_configured "$ssh_confirmation"; then
        rm -f "$backup_file"
        return 0
    fi

    echo "新配置应用失败，正在恢复原配置与原规则。" >&2
    if ! mv -f "$backup_file" "$CONFIG_FILE"; then
        echo "原配置文件无法恢复，备份保留在 $backup_file。" >&2
        return 1
    fi
    if ! apply_if_configured "$ssh_confirmation"; then
        echo "原配置恢复不完整，正在尝试停止服务并解除本组件规则。" >&2
        if stop_service_strict; then
            fail_open_firewall >/dev/null 2>&1 || true
        fi
        return 1
    fi
    return 1
}

load_policies() {
    POLICY_LIMIT=()
    POLICY_IDLE=()
    POLICY_CONNECTIONS=()
    local port limit idle connections policy_data
    validate_config || return 1
    policy_data=$(jq -r --argjson idle "$DEFAULT_IDLE_TIMEOUT" \
        '.ports | to_entries[] | "\(.key) \(.value.max_ips) \(.value.idle_timeout // $idle) \(.value.max_connections // 0)"' \
        "$CONFIG_FILE") || return 1
    while read -r port limit idle connections; do
        [ -n "$port" ] || continue
        validate_port "$port" && validate_limit "$limit" && validate_limit "$connections" || return 1
        # 两项均为 0 的端口不进入队列，也不触发 SSH 限制确认。
        [ "$limit" -ne 0 ] || [ "$connections" -ne 0 ] || continue
        POLICY_LIMIT["$port"]="$limit"
        POLICY_CONNECTIONS["$port"]="$connections"
        # Exposed to shell policy/configuration regression checks; worker reads JSON.
        # shellcheck disable=SC2034
        POLICY_IDLE["$port"]="${idle:-$DEFAULT_IDLE_TIMEOUT}"
    done <<< "$policy_data"
}

inspect_table_state() {
    TABLE_STATE="error"
    local tables_json table_json table_text table_count
    if ! tables_json=$(nft -j list tables 2>/dev/null); then
        echo "无法读取 nftables 表清单；为避免误删，拒绝修改。" >&2
        return 1
    fi
    if ! table_count=$(jq -r --arg name "$TABLE_NAME" '
        [.nftables[] | .table? | select(.family == "inet" and .name == $name)] | length
    ' <<< "$tables_json" 2>/dev/null); then
        echo "无法解析 nftables 表清单；为避免误删，拒绝修改。" >&2
        return 1
    fi
    case "$table_count" in
        0)
            TABLE_STATE="absent"
            return 0
            ;;
        1) ;;
        *)
            echo "nftables 返回了异常的同名表数量；为避免误删，拒绝修改。" >&2
            return 1
            ;;
    esac
    if ! table_json=$(nft -j list table inet "$TABLE_NAME" 2>/dev/null); then
        echo "同名 nftables 表存在但无法读取；为避免误删，拒绝修改。" >&2
        return 1
    fi
    if jq -e --arg name "$TABLE_NAME" --arg marker "$TABLE_OWNER_MARKER" '
        [.nftables[] | .table? |
            select(.family == "inet" and .name == $name and .comment == $marker)] |
        length == 1
    ' <<< "$table_json" >/dev/null 2>&1; then
        TABLE_STATE="owned"
        return 0
    fi

    # nftables 1.0.x 接受表 comment，但其 JSON 输出可能省略该字段。
    # 兼容回退只接受表定义顶部的第一项精确等于所有权标记，链/规则注释不能冒充。
    if ! table_text=$(nft list table inet "$TABLE_NAME" 2>/dev/null); then
        echo "同名 nftables 表存在但无法读取文本定义；为避免误删，拒绝修改。" >&2
        return 1
    fi
    if awk -v marker="$TABLE_OWNER_MARKER" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (!inside_table) {
                if (line ~ /^table[[:space:]].*\{[[:space:]]*$/) inside_table = 1
                next
            }
            if (line == "") next
            if (line == "comment \"" marker "\"" ||
                line == "comment \"" marker "\";") found = 1
            exit
        }
        END { exit(found ? 0 : 1) }
    ' <<< "$table_text"; then
        TABLE_STATE="owned"
        return 0
    fi

    TABLE_STATE="foreign"
    echo "检测到同名 nftables 表 inet $TABLE_NAME，但缺少本脚本所有权标记；拒绝修改。" >&2
    return 0
}

require_owned_table() {
    inspect_table_state || return 1
    if [ "$TABLE_STATE" != "owned" ]; then
        if [ "$TABLE_STATE" = "absent" ]; then
            echo "IP 上限 nftables 表不存在，拒绝执行增量更新。" >&2
        fi
        return 1
    fi
}

apply_nft_batch() {
    local batch_file="$1"
    [ -s "$batch_file" ] || return 0
    if ! nft -c -f "$batch_file"; then
        echo "nftables 批次预检失败，未修改现有规则。" >&2
        return 1
    fi
    if ! nft -f "$batch_file"; then
        echo "nftables 原子提交失败。" >&2
        return 1
    fi
}

remove_owned_table() {
    inspect_table_state || return 1
    case "$TABLE_STATE" in
        absent) return 0 ;;
        owned) ;;
        foreign) return 1 ;;
        *) return 1 ;;
    esac

    local batch_file
    batch_file=$(mktemp /tmp/port-traffic-dog-ip-guard-remove.XXXXXX) || return 1
    printf 'delete table inet %s\n' "$TABLE_NAME" > "$batch_file"
    if ! apply_nft_batch "$batch_file"; then
        rm -f "$batch_file"
        return 1
    fi
    rm -f "$batch_file"
}

render_ruleset() {
    local replace_existing="${1:-false}"
    local port

    if [ "$replace_existing" = "true" ]; then
        printf 'delete table inet %s\n' "$TABLE_NAME"
    fi
    # create 会在同名表于检查后被其他程序建立时失败，不会接管未知表。
    printf 'create table inet %s { comment "%s"; }\n' "$TABLE_NAME" "$TABLE_OWNER_MARKER"
    printf 'add chain inet %s guard_input { type filter hook input priority -20; policy accept; }\n' "$TABLE_NAME"
    # 引用 ct 以启用新网络命名空间中的跟踪；不改变其他防火墙链的裁决。
    printf 'add rule inet %s guard_input ct state established,related accept comment "ptd_ip_guard_existing"\n' "$TABLE_NAME"

    for port in $(printf '%s\n' "${!POLICY_LIMIT[@]}" | sort -n); do
        # 只处理初始 SYN；已建立连接的数据包不经过用户态。
        # bypass 与 NFQA_CFG_F_FAIL_OPEN 共同保证消费者离线/队列满时放行。
        printf 'add rule inet %s guard_input tcp dport %s tcp flags & (syn | ack | rst | fin) == syn queue num %s bypass comment "ptd_ip_guard_%s_syn_queue"\n' \
            "$TABLE_NAME" "$port" "$QUEUE_NUMBER" "$port"
    done
}

rebuild_firewall() {
    local rules_file
    local replace_existing=false
    inspect_table_state || return 1
    case "$TABLE_STATE" in
        owned) replace_existing=true ;;
        absent) ;;
        foreign) return 1 ;;
        *) return 1 ;;
    esac
    rules_file=$(mktemp "$CONFIG_DIR/.ip-guard-rules.XXXXXX") || return 1
    if ! render_ruleset "$replace_existing" > "$rules_file"; then
        rm -f "$rules_file"
        return 1
    fi
    if ! apply_nft_batch "$rules_file"; then
        rm -f "$rules_file"
        return 1
    fi
    rm -f "$rules_file"
}

current_ssh_server_port() {
    local client_address client_port server_address server_port extra
    [ -n "${SSH_CONNECTION:-}" ] || return 1
    read -r client_address client_port server_address server_port extra <<< "$SSH_CONNECTION"
    [ -n "$client_address" ] && validate_port "$client_port" &&
        [ -n "$server_address" ] && validate_port "$server_port" &&
        [ -z "${extra:-}" ] || return 1
    printf '%s\n' "$server_port"
}

warn_current_ssh_restriction() {
    local ssh_port="$1"
    echo -e "${RED}警告：端口 $ssh_port 是当前 SSH 会话的服务端口。${NC}" >&2
    echo -e "${YELLOW}限制该端口可能拒绝新的管理来源；当前连接也可能因重连而失去访问。${NC}" >&2
}

require_current_ssh_confirmation() {
    local confirmation="${1:-}"
    local ssh_port
    ssh_port=$(current_ssh_server_port) || return 0
    [ -n "${POLICY_LIMIT[$ssh_port]:-}" ] || return 0
    warn_current_ssh_restriction "$ssh_port"
    if [ "$confirmation" != "RESTRICT_SSH" ]; then
        echo "拒绝应用。命令行需追加: --confirm-restrict-ssh RESTRICT_SSH" >&2
        return 1
    fi
}

SSH_CONFIRMATION_TOKEN=""
interactive_confirm_current_ssh() {
    local candidate_port="${1:-}"
    local removing_port="${2:-}"
    local ssh_port first_confirm final_confirm
    SSH_CONFIRMATION_TOKEN=""
    ssh_port=$(current_ssh_server_port) || return 0

    if [ "$removing_port" = "$ssh_port" ]; then
        return 0
    fi
    if [ "$candidate_port" != "$ssh_port" ] && [ -z "${POLICY_LIMIT[$ssh_port]:-}" ]; then
        return 0
    fi

    warn_current_ssh_restriction "$ssh_port"
    read -r -p "仍要继续限制当前 SSH 端口? [y/N]: " first_confirm
    [[ "$first_confirm" =~ ^[Yy]$ ]] || return 1
    read -r -p "二次确认，请完整输入 RESTRICT_SSH: " final_confirm
    [ "$final_confirm" = "RESTRICT_SSH" ] || {
        echo "二次确认不匹配，已取消。" >&2
        return 1
    }
    SSH_CONFIRMATION_TOKEN="RESTRICT_SSH"
}

guard_log_event() {
    if command_exists python3 && [ -d "$CONFIG_DIR" ]; then
        (run_admission_worker --log "$1" "${2:-0}") || echo "IP Guard 生命周期日志写入失败。" >&2
    fi
    return 0
}

show_guard_logs() {
    local path="$CONFIG_DIR/logs/ip-guard.log"
    if [ -f "$path" ] && [ ! -L "$path" ]; then
        tail -n 50 -- "$path" | jq -r '"\(.time) \(.message // .event)"'
    else
        echo "暂无 IP Guard 日志"
    fi
}

fail_open_firewall() {
    if ! command_exists nft || ! command_exists jq; then
        echo "无法执行 fail-open：缺少 nft 或 jq，未能安全确认表所有权。" >&2
        return 1
    fi
    if remove_owned_table; then
        guard_log_event fail_open 0
        echo "IP 上限 nftables 规则已处于 fail-open 状态。"
        return 0
    fi
    echo "fail-open 拒绝删除未知或不可验证的同名 nftables 表。" >&2
    return 1
}

request_daemon_stop() {
    DAEMON_STOP_REQUESTED=true
}
cleanup_daemon() {
    local daemon_status=$?
    trap - EXIT INT TERM
    guard_log_event daemon_exit "$daemon_status"
    if [ -n "$DAEMON_LISTENER_PID" ]; then
        kill "$DAEMON_LISTENER_PID" >/dev/null 2>&1 || true
        wait "$DAEMON_LISTENER_PID" 2>/dev/null || true
    fi
    if [ -n "$DAEMON_EVENT_FIFO" ]; then
        exec 8>&- 2>/dev/null || true
        rm -f "$DAEMON_EVENT_FIFO"
    fi
    rm -f -- "$DAEMON_STATE_FILE"
    fail_open_firewall || true
}

# 随本脚本分发，沿用原安装/更新/回滚事务。
run_admission_worker() {
    exec python3 - "$CONFIG_FILE" "$QUEUE_NUMBER" "$DAEMON_STATE_FILE" "$RECONCILE_SECONDS" "$CONFIG_DIR/logs/ip-guard.log" "$@" <<'PTD_IP_GUARD_PY'
import ctypes
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time


class Audit:
    """Bounded private JSONL events; raw client addresses never enter the log."""
    def __init__(self, path):
        self.path = path
        self.salt = os.urandom(16)
        self.buckets = {}
        self.warned = False

    def emit(self, event, **fields):
        if not re.fullmatch('[a-z][a-z0-9_]{0,63}', event):
            return
        entry = {'time': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'event': event}
        for name, value in fields.items():
            if name == 'source':
                entry['source_id'] = hashlib.blake2s(str(value).encode(), key=self.salt, digest_size=8).hexdigest()
            elif name in ('port', 'count', 'queue', 'connections', 'online_ips', 'result', 'ports') and isinstance(value, int):
                entry[name] = value
            elif name in ('reason', 'original') and isinstance(value, str) and re.fullmatch('[A-Za-z0-9_]{1,64}', value):
                entry[name] = value
        descriptions = {
            'startup': '在线 IP / 并发连接守护已启动',
            'startup_requested': '正在准备准入队列和连接快照',
            'shutdown': '准入引擎已停止', 'daemon_exit': '守护进程已退出',
            'fail_open': '已解除本组件限制，恢复放行',
            'lock_busy': '启动失败：另一个守护进程仍在运行',
            'admit': '已准入新的 TCP 连接', 'release': '已释放关闭连接的名额',
            'reject': '已拒绝新的 TCP 连接', 'suppressed': '相同事件的重复记录已汇总',
        }
        message = descriptions.get(event, '操作记录')
        if 'port' in entry:
            message = '端口 %d：%s' % (entry['port'], message)
        if entry.get('reason') == 'ip_limit':
            message += '，同时在线 IP 数达到上限'
        elif entry.get('reason') == 'connection_limit':
            message += '，并发连接数达到上限'
        if 'count' in entry:
            message += '，数量 %d' % entry['count']
        if 'source_id' in entry:
            message += '，匿名来源标识 ' + entry['source_id']
        if 'result' in entry:
            message += '（成功）' if entry['result'] == 0 else '（异常，返回码 %d）' % entry['result']
        entry['message'] = message
        try:
            directory = os.path.dirname(self.path)
            if os.path.islink(directory) or os.path.islink(self.path) or os.path.islink(self.path + '.lock'):
                raise OSError('log path is a symlink')
            os.makedirs(directory, mode=0o700, exist_ok=True)
            os.chmod(directory, 0o700)
            with open(self.path + '.lock', 'a') as lock:
                os.fchmod(lock.fileno(), 0o600)
                deadline = time.monotonic() + 0.2
                while True:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            raise OSError('log lock timeout')
                        time.sleep(0.01)
                for index in (1, 2, 3):
                    if os.path.islink(self.path + '.' + str(index)):
                        raise OSError('rotated log is a symlink')
                if os.path.exists(self.path) and os.path.getsize(self.path) >= 1048576:
                    if os.path.exists(self.path + '.3'):
                        os.unlink(self.path + '.3')
                    for index in (2, 1):
                        if os.path.exists(self.path + '.' + str(index)):
                            os.replace(self.path + '.' + str(index), self.path + '.' + str(index + 1))
                    os.replace(self.path, self.path + '.1')
                descriptor = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
                with os.fdopen(descriptor, 'a', encoding='utf-8') as output:
                    os.fchmod(output.fileno(), 0o600)
                    output.write(json.dumps(entry, sort_keys=True, ensure_ascii=False) + '\n')
        except OSError:
            if not self.warned:
                print('IP Guard 日志写入失败；准入状态保持不变。', file=sys.stderr)
                self.warned = True

    def limited(self, event, port, **fields):
        key = (event, port, fields.get('reason', ''))
        now = time.monotonic()
        if key not in self.buckets or now - self.buckets[key][0] >= 10:
            self.flush()
            self.buckets[key] = [now, 0]
            self.emit(event, port=port, **fields)
        else:
            self.buckets[key][1] += 1

    def flush(self, force=False):
        now = time.monotonic()
        for (event, port, reason), bucket in self.buckets.items():
            if bucket[1] and (force or now - bucket[0] >= 10):
                self.emit('suppressed', port=port, original=event, reason=reason or 'none', count=bucket[1])
                bucket[1] = 0


class Admission:
    """Single-consumer admission; retransmitted SYNs share one reservation."""
    def __init__(self, policies, clock=time.monotonic, audit=None):
        self.policies = {int(port): policy for port, policy in policies.items()}
        self.clock = clock
        self.audit = audit
        self.flows = {}
        self.idle = {}

    def active_sources(self, port):
        return {key[1] for key in self.flows if key[0] == port}

    def trim_idle(self):
        for key, until in list(self.idle.items()):
            if until <= self.clock() or key[1] in self.active_sources(key[0]):
                self.idle.pop(key, None)
        for port, policy in self.policies.items():
            cap = policy['max_ips']
            if cap:
                retained = sorted((until, key) for key, until in self.idle.items() if key[0] == port)
                while retained and len(retained) + len(self.active_sources(port)) > cap:
                    self.idle.pop(retained.pop(0)[1], None)

    def reconcile(self, records):
        now = self.clock()
        before = {port: self.active_sources(port) for port in self.policies}
        previous_flows = set(self.flows)
        live, ended = {}, set()
        for key, state in records:
            if key[0] not in self.policies:
                continue
            if state in ('TIME_WAIT', 'CLOSE'):
                ended.add(key)
            else:
                live[key] = (self.flows.get(key, (now, False))[0], True)
        # Verdict precedes confirmation. Reserve pending SYNs for at most 30s;
        # retransmission never extends that deadline.
        for key, (born, confirmed) in self.flows.items():
            if key not in live and key not in ended and not confirmed and now - born < 30:
                live[key] = (born, False)
        self.flows = live
        if self.audit:
            for port in self.policies:
                released = sum(key[0] == port for key in previous_flows - set(live))
                if released:
                    self.audit.emit('release', port=port, count=released)
        for port, sources in before.items():
            idle = self.policies[port].get('idle_timeout', 300)
            for source in sources - self.active_sources(port):
                if idle:
                    self.idle[(port, source)] = now + idle
        self.trim_idle()

    def admit(self, key):
        port, source, _, _ = key
        if port not in self.policies or key in self.flows:
            return True
        policy = self.policies[port]
        cap = policy.get('max_connections', 0)
        if cap and sum(item[0] == port for item in self.flows) >= cap:
            if self.audit:
                self.audit.limited('reject', port, source=source, reason='connection_limit')
            return False
        sources = self.active_sources(port)
        cap = policy['max_ips']
        if cap and source not in sources and len(sources) >= cap:
            if self.audit:
                self.audit.limited('reject', port, source=source, reason='ip_limit')
            return False
        self.flows[key] = (self.clock(), False)
        self.idle.pop((port, source), None)
        # Retain idle addresses as a preference; they cannot displace live users.
        self.trim_idle()
        if self.audit:
            self.audit.limited('admit', port, source=source)
        return True

    def status(self):
        self.trim_idle()
        return {str(port): {
            'online_ips': len(self.active_sources(port)),
            'connections': sum(key[0] == port for key in self.flows),
            'idle_ips': sum(key[0] == port for key in self.idle),
            'max_ips': policy['max_ips'],
            'max_connections': policy.get('max_connections', 0),
        } for port, policy in self.policies.items()}


def syn_key(packet):
    """Parse IPv4/IPv6 input TCP SYNs, including IPv6 extension headers."""
    if not packet:
        return None
    version = packet[0] >> 4
    if version == 4:
        if len(packet) < 20 or packet[9] != 6:
            return None
        offset = (packet[0] & 15) * 4
        if offset < 20 or struct.unpack('!H', packet[6:8])[0] & 0x1fff:
            return None
        source = socket.inet_ntop(socket.AF_INET, packet[12:16])
        destination = socket.inet_ntop(socket.AF_INET, packet[16:20])
    elif version == 6:
        if len(packet) < 40:
            return None
        source = socket.inet_ntop(socket.AF_INET6, packet[8:24])
        destination = socket.inet_ntop(socket.AF_INET6, packet[24:40])
        protocol, offset = packet[6], 40
        for _ in range(16):
            if protocol == 6:
                break
            if offset + 2 > len(packet):
                return None
            if protocol in (0, 43, 60):
                length = (packet[offset + 1] + 1) * 8
            elif protocol == 44:
                if offset + 8 > len(packet) or struct.unpack('!H', packet[offset+2:offset+4])[0] & 0xfff8:
                    return None
                length = 8
            elif protocol == 51:
                length = (packet[offset + 1] + 2) * 4
            else:
                return None
            protocol, offset = packet[offset], offset + length
        else:
            return None
    else:
        return None
    if offset + 20 > len(packet) or packet[offset + 13] & 0x17 != 0x02:
        return None
    sport, dport = struct.unpack('!HH', packet[offset:offset+4])
    return (dport, source, destination, sport)


def conntrack_records(text, local):
    records = []
    for line in text.splitlines():
        state = re.search(r'\btcp\s+\d+\s+\d+\s+([A-Z_]+)', line)
        tuples = re.findall(r'\bsrc=(\S+)\s+dst=(\S+)\s+sport=(\d+)\s+dport=(\d+)', line)
        if not state or len(tuples) != 2:
            continue
        original, reply = tuples
        rsrc, rdst, rsport, rdport = reply
        osrc, odst, osport, odport = original
        rsrc, rdst = str(ipaddress.ip_address(rsrc)), str(ipaddress.ip_address(rdst))
        if rsrc in local:
            key = (int(rsport), rdst, rsrc, int(rdport))
        elif str(ipaddress.ip_address(odst)) in local:
            key = (int(odport), str(ipaddress.ip_address(osrc)), str(ipaddress.ip_address(odst)), int(osport))
        else:
            continue
        records.append((key, state.group(1)))
    return records


def socket_records(text):
    records = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 5 or parts[0] in ('LISTEN', 'UNCONN', 'TIME-WAIT', 'CLOSED', 'CLOSE', 'SYN-SENT'):
            continue
        try:
            local, port = parts[3].rsplit(':', 1)
            peer, sport = parts[4].rsplit(':', 1)
            def address(value):
                parsed = ipaddress.ip_address(value.strip('[]').split('%')[0])
                return str(getattr(parsed, 'ipv4_mapped', None) or parsed)
            records.append(((int(port), address(peer), address(local), int(sport)), parts[0]))
        except (ValueError, IndexError):
            continue
    return records


def snapshot(engine):
    result = subprocess.run(['ip', '-j', 'address', 'show'], check=True, capture_output=True, text=True, timeout=5)
    local = {str(ipaddress.ip_address(info['local'])) for interface in json.loads(result.stdout)
             for info in interface.get('addr_info', []) if 'local' in info}
    records = []
    for family in ('ipv4', 'ipv6'):
        result = subprocess.run(['conntrack', '-L', '-f', family, '-p', 'tcp', '-o', 'extended'],
                                check=True, capture_output=True, text=True, timeout=5)
        records.extend(conntrack_records(result.stdout, local))
    # Existing sockets may predate the first conntrack reference in a fresh netns.
    result = subprocess.run(['ss', '-H', '-n', '-t'], check=True, capture_output=True, text=True, timeout=5)
    records.extend(socket_records(result.stdout))
    engine.reconcile(records)


def write_status(path, engine, queue, config_hash):
    data = {'owner': 'port-traffic-dog-ip-guard:v2', 'pid': os.getpid(),
            'queue': queue, 'updated_at': time.time(), 'config_sha256': config_hash,
            'ports': engine.status()}
    descriptor, temporary = tempfile.mkstemp(prefix='.ip-guard-state.', dir=os.path.dirname(path))
    try:
        with os.fdopen(descriptor, 'w') as output:
            json.dump(data, output, sort_keys=True)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def serve(config_path, queue, status_path, interval, log_path):
    with open(config_path, 'rb') as config_file:
        raw_config = config_file.read()
    config_hash = hashlib.sha256(raw_config).hexdigest()
    audit = Audit(log_path)
    engine = Admission(json.loads(raw_config)['ports'], audit=audit)
    lib = ctypes.CDLL('libnetfilter_queue.so.1', use_errno=True)
    pointer = ctypes.c_void_p
    callback_type = ctypes.CFUNCTYPE(ctypes.c_int, pointer, pointer, pointer, pointer)
    signatures = {
        'nfq_open': (pointer, []),
        'nfq_close': (ctypes.c_int, [pointer]),
        'nfq_create_queue': (pointer, [pointer, ctypes.c_uint16, callback_type, pointer]),
        'nfq_destroy_queue': (ctypes.c_int, [pointer]),
        'nfq_set_mode': (ctypes.c_int, [pointer, ctypes.c_uint8, ctypes.c_uint32]),
        'nfq_set_queue_maxlen': (ctypes.c_int, [pointer, ctypes.c_uint32]),
        'nfq_set_queue_flags': (ctypes.c_int, [pointer, ctypes.c_uint32, ctypes.c_uint32]),
        'nfq_fd': (ctypes.c_int, [pointer]),
        'nfq_handle_packet': (ctypes.c_int, [pointer, ctypes.c_char_p, ctypes.c_int]),
        'nfq_get_msg_packet_hdr': (pointer, [pointer]),
        'nfq_get_payload': (ctypes.c_int, [pointer, ctypes.POINTER(pointer)]),
        'nfq_set_verdict': (ctypes.c_int, [pointer, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, pointer]),
    }
    for name, (result_type, argument_types) in signatures.items():
        function = getattr(lib, name)
        function.restype, function.argtypes = result_type, argument_types
    stopping, failure, first_packet = False, [], True

    def stop(_signal, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    parent = os.getppid()
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0 or os.getppid() != parent:
        raise RuntimeError('cannot attach worker lifecycle to supervisor')

    @callback_type
    def decide(queue_handle, _message, packet_data, _user):
        nonlocal first_packet, stopping
        header = lib.nfq_get_msg_packet_hdr(packet_data)
        if not header:
            failure.append('NFQUEUE packet header absent')
            stopping = True
            return -1
        packet_id = struct.unpack('!I', ctypes.string_at(header, 4))[0]
        verdict = 1
        try:
            if first_packet:
                # Cover existing handshakes between initial snapshot and rule install.
                snapshot(engine)
                first_packet = False
            data = pointer()
            length = lib.nfq_get_payload(packet_data, ctypes.byref(data))
            if length < 0:
                raise RuntimeError('NFQUEUE payload unavailable')
            key = syn_key(ctypes.string_at(data, length))
            if key is not None:
                verdict = 1 if engine.admit(key) else 0
        except Exception as error:
            failure.append(type(error).__name__)
            stopping = True
        if lib.nfq_set_verdict(queue_handle, packet_id, verdict, 0, None) < 0:
            failure.append('NFQUEUE verdict failed')
            stopping = True
        return 0

    handle = lib.nfq_open()
    if not handle:
        raise RuntimeError('cannot open NFQUEUE')
    queue_handle, channel = None, None
    try:
        # Never unbind a family: other queue consumers must remain untouched.
        queue_handle = lib.nfq_create_queue(handle, queue, decide, None)
        if not queue_handle:
            raise RuntimeError('NFQUEUE unavailable or already owned: %d' % queue)
        for result in (lib.nfq_set_mode(queue_handle, 2, 4096),
                       lib.nfq_set_queue_maxlen(queue_handle, 1024),
                       lib.nfq_set_queue_flags(queue_handle, 1, 1)):
            if result < 0:
                raise RuntimeError('cannot configure NFQUEUE fail-open')
        channel = socket.fromfd(lib.nfq_fd(handle), socket.AF_NETLINK, socket.SOCK_RAW)
        channel.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1048576)
        snapshot(engine)
        write_status(status_path, engine, queue, config_hash)
        next_snapshot, next_status = time.monotonic() + interval, time.monotonic() + 1
        audit.emit('startup', queue=queue, ports=len(engine.policies), connections=len(engine.flows))
        while not stopping:
            now = time.monotonic()
            if now >= next_snapshot:
                snapshot(engine)
                next_snapshot = time.monotonic() + interval
            audit.flush()
            if now >= next_status:
                write_status(status_path, engine, queue, config_hash)
                next_status = time.monotonic() + 1
            readable, _, _ = select.select([channel], [], [], min(1, max(0, next_snapshot - time.monotonic())))
            if readable:
                packet = channel.recv(65536)
                if lib.nfq_handle_packet(handle, packet, len(packet)) < 0:
                    raise RuntimeError('NFQUEUE dispatch failed')
        if failure:
            raise RuntimeError(failure[0])
    finally:
        audit.emit('shutdown', result=1 if failure or sys.exc_info()[0] else 0)
        audit.flush(force=True)
        if channel is not None:
            channel.close()
        if queue_handle:
            lib.nfq_destroy_queue(queue_handle)
        lib.nfq_close(handle)


if __name__ == '__main__':
    try:
        if len(sys.argv) > 6 and sys.argv[6] == '--log':
            Audit(sys.argv[5]).emit(sys.argv[7], result=int(sys.argv[8]))
        else:
            serve(sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5])
    except Exception as error:
        print('IP Guard admission stopped: %s' % error, file=sys.stderr)
        sys.exit(1)
PTD_IP_GUARD_PY
}

worker_is_ready() {
    [ -f "$DAEMON_STATE_FILE" ] && kill -0 "$DAEMON_LISTENER_PID" 2>/dev/null &&
        jq -e --argjson pid "$DAEMON_LISTENER_PID" --argjson queue "$QUEUE_NUMBER" \
            '.owner == "port-traffic-dog-ip-guard:v2" and .pid == $pid and .queue == $queue' \
            "$DAEMON_STATE_FILE" >/dev/null 2>&1
}

run_daemon() {
    local ssh_confirmation="${1:-}"
    check_dependencies || return 1
    init_config || return 1
    load_policies || return 1
    require_current_ssh_confirmation "$ssh_confirmation" || return 1
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || {
        echo "另一个 IP Guard 守护进程正在运行。" >&2
        guard_log_event lock_busy 1
        return 1
    }
    DAEMON_STOP_REQUESTED=false
    # 确认所有权后才允许退出清理，陌生同名表必须保留。
    inspect_table_state || return 1
    [ "$TABLE_STATE" != foreign ] || return 1
    guard_log_event startup_requested 0
    trap cleanup_daemon EXIT
    trap request_daemon_stop INT TERM
    [ ${#POLICY_LIMIT[@]} -gt 0 ] || return 0
    rm -f -- "$DAEMON_STATE_FILE"
    run_admission_worker &
    DAEMON_LISTENER_PID=$!
    local attempt
    for attempt in {1..150}; do
        worker_is_ready && break
        kill -0 "$DAEMON_LISTENER_PID" 2>/dev/null || break
        [ "$DAEMON_STOP_REQUESTED" != true ] || return 0
        sleep 0.1
    done
    worker_is_ready || {
        echo "准入队列未就绪，未启用限制。" >&2
        return 1
    }
    rebuild_firewall || {
        echo "无法建立 IP Guard nftables 规则。" >&2
        return 1
    }
    echo "IP Guard 已启动，端口数: ${#POLICY_LIMIT[@]}，队列: $QUEUE_NUMBER"
    while kill -0 "$DAEMON_LISTENER_PID" 2>/dev/null && [ "$DAEMON_STOP_REQUESTED" != true ]; do
        sleep 0.2
    done
    if [ "$DAEMON_STOP_REQUESTED" = true ]; then
        return 0
    fi
    wait "$DAEMON_LISTENER_PID" || true
    echo "IP Guard 准入引擎意外退出，解除限制。" >&2
    return 1
}

install_script_safely() {
    local source_path install_dir temp_script
    source_path=$(readlink -f -- "${BASH_SOURCE[0]}") || {
        echo "无法解析当前脚本路径。" >&2
        return 1
    }
    install_dir=$(dirname "$INSTALLED_SCRIPT")
    mkdir -p "$install_dir" || return 1
    if [ -d "$INSTALLED_SCRIPT" ]; then
        echo "安装目标是目录，拒绝覆盖: $INSTALLED_SCRIPT" >&2
        return 1
    fi

    if [ -e "$INSTALLED_SCRIPT" ] && [ "$source_path" -ef "$INSTALLED_SCRIPT" ]; then
        chmod 755 "$INSTALLED_SCRIPT"
        return 0
    fi

    temp_script=$(mktemp "$install_dir/.port-ip-guard.sh.XXXXXX") || return 1
    if ! install -m 755 "$source_path" "$temp_script"; then
        rm -f "$temp_script"
        return 1
    fi
    if ! mv -f "$temp_script" "$INSTALLED_SCRIPT"; then
        rm -f "$temp_script"
        return 1
    fi
}

service_file_is_owned() {
    [ -f "$SERVICE_FILE" ] && [ ! -L "$SERVICE_FILE" ] || return 1
    grep -Fxq "ExecStart=$INSTALLED_SCRIPT --run" "$SERVICE_FILE" || return 1
    grep -Fxq "ExecStopPost=-$INSTALLED_SCRIPT --fail-open" "$SERVICE_FILE" || return 1
    if grep -Fxq "$SERVICE_OWNER_MARKER" "$SERVICE_FILE"; then
        return 0
    fi

    # 兼容升级前由本组件创建、尚未带所有权标记的旧单元。
    grep -Fxq 'Description=Port Traffic Dog active source IP guard (experimental)' "$SERVICE_FILE" &&
        grep -Fxq 'Type=simple' "$SERVICE_FILE" &&
        grep -Fxq 'Restart=always' "$SERVICE_FILE"
}

install_service() {
    local service_dir temp_service load_state
    command_exists "$SYSTEMCTL" || {
        echo "系统没有 systemd，无法持久运行该测试功能。" >&2
        return 1
    }
    service_dir=$(dirname "$SERVICE_FILE")
    mkdir -p "$service_dir" || return 1
    if [ -d "$SERVICE_FILE" ]; then
        echo "systemd 单元目标是目录，拒绝覆盖: $SERVICE_FILE" >&2
        return 1
    fi
    if [ -e "$SERVICE_FILE" ] && ! service_file_is_owned; then
        echo "同名 systemd 单元不属于本组件，拒绝覆盖: $SERVICE_FILE" >&2
        return 1
    fi
    load_state=$("$SYSTEMCTL" show "$SERVICE_NAME" --property=LoadState --value 2>/dev/null) || {
        echo "无法确认 $SERVICE_NAME 是否已被其他单元占用。" >&2
        return 1
    }
    if [ "$load_state" != "not-found" ] && [ ! -e "$SERVICE_FILE" ]; then
        echo "同名 systemd 单元已从其他位置加载，拒绝覆盖: $SERVICE_NAME" >&2
        return 1
    fi
    install_script_safely || return 1
    temp_service=$(mktemp "$service_dir/.${SERVICE_NAME}.XXXXXX") || return 1
    if cat > "$temp_service" <<EOF
$SERVICE_OWNER_MARKER
[Unit]
Description=Port Traffic Dog active source IP guard (experimental)
After=network-online.target nftables.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$INSTALLED_SCRIPT --run
ExecStopPost=-$INSTALLED_SCRIPT --fail-open
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    then
        :
    else
        rm -f "$temp_service"
        return 1
    fi
    if ! chmod 644 "$temp_service"; then
        rm -f "$temp_service"
        return 1
    fi
    if ! mv -f "$temp_service" "$SERVICE_FILE"; then
        rm -f "$temp_service"
        return 1
    fi
    "$SYSTEMCTL" daemon-reload || return 1
    "$SYSTEMCTL" enable "$SERVICE_NAME" >/dev/null || return 1
    "$SYSTEMCTL" restart "$SERVICE_NAME" || return 1

    local attempt
    # Bounded service readiness retries; the counter is intentionally unused.
    # shellcheck disable=SC2034
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if "$SYSTEMCTL" is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1 &&
           bash "$INSTALLED_SCRIPT" --self-check >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "$SERVICE_NAME 重启后未通过 active/self-check 核验。" >&2
    return 1
}

systemd_runtime_available() { [ -d /run/systemd/system ]; }

guard_absent_without_manager() {
    # systemctl 可随依赖被装入容器；命令存在不表示 systemd 正在运行。
    systemd_runtime_available && return 1
    [ ! -e "$SERVICE_FILE" ] && [ ! -L "$SERVICE_FILE" ] || return 1
    [ ! -e "$DAEMON_STATE_FILE" ] && [ ! -L "$DAEMON_STATE_FILE" ] || return 1
    [ ! -L "$LOCK_FILE" ] || return 1
    if [ -e "$LOCK_FILE" ]; then flock -n "$LOCK_FILE" true || return 1; fi
    return 0
}

stop_service_strict() {
    local load_state active_state enabled_state
    if [ -e "$SERVICE_FILE" ] && ! service_file_is_owned; then
        echo "同名 systemd 单元不属于本组件，拒绝停止或删除: $SERVICE_FILE" >&2
        return 1
    fi
    command_exists "$SYSTEMCTL" || {
        guard_absent_without_manager && return 0
        echo "缺少 systemctl，无法确认守护服务已停止。" >&2
        return 1
    }
    load_state=$("$SYSTEMCTL" show "$SERVICE_NAME" --property=LoadState --value 2>/dev/null) || {
        guard_absent_without_manager && return 0
        echo "无法查询 $SERVICE_NAME 的加载状态。" >&2
        return 1
    }
    if [ "$load_state" = "not-found" ]; then
        [ ! -e "$SERVICE_FILE" ] || return 1
        return 0
    fi
    if ! service_file_is_owned; then
        echo "$SERVICE_NAME 已加载，但无法确认由本组件所有，拒绝停止。" >&2
        return 1
    fi

    # disable --now 先撤销开机入口并请求停止；显式 stop 兼容不支持 --now
    # 或只完成了其中一步的 systemd。命令返回值不能替代最终状态校验。
    "$SYSTEMCTL" disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    "$SYSTEMCTL" stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    enabled_state=$("$SYSTEMCTL" is-enabled "$SERVICE_NAME" 2>/dev/null || true)
    case "$enabled_state" in
        enabled|enabled-runtime|linked|linked-runtime|alias)
            echo "$SERVICE_NAME 仍处于启用状态，拒绝继续清理。" >&2
            return 1
            ;;
        disabled|masked|masked-runtime) ;;
        not-found)
            [ ! -e "$SERVICE_FILE" ] || {
                echo "$SERVICE_NAME 无法由 systemd 识别，但服务文件仍存在。" >&2
                return 1
            }
            ;;
        *)
            echo "无法确认 $SERVICE_NAME 已禁用。" >&2
            return 1
            ;;
    esac

    # 必须在禁用动作之后做最后一次 active 校验，避免 stop 与 disable 之间
    # 被 Restart=always 或其他 systemd 入口重新拉起后仍误报卸载成功。
    active_state=$("$SYSTEMCTL" show "$SERVICE_NAME" --property=ActiveState --value 2>/dev/null) || {
        echo "无法确认 $SERVICE_NAME 已停止。" >&2
        return 1
    }
    case "$active_state" in
        inactive|failed) return 0 ;;
        *)
            echo "$SERVICE_NAME 仍处于 $active_state 状态，拒绝删除 fail-open 组件。" >&2
            return 1
            ;;
    esac
}

apply_if_configured() {
    local ssh_confirmation="${1:-}"
    check_validation_dependency || return 1
    init_config || return 1
    load_policies || return 1
    require_current_ssh_confirmation "$ssh_confirmation" || return 1
    if [ ${#POLICY_LIMIT[@]} -eq 0 ]; then
        if ! command_exists nft || ! command_exists jq; then
            echo "缺少 nft 或 jq，无法安全确认并清理 nftables 表。" >&2
            return 1
        fi
        inspect_table_state || return 1
        [ "$TABLE_STATE" != "foreign" ] || return 1
        stop_service_strict || return 1
        fail_open_firewall
        return $?
    fi
    check_dependencies || return 1
    inspect_table_state || return 1
    [ "$TABLE_STATE" != "foreign" ] || return 1
    install_service
}

runtime_state_valid() {
    local pid digest now
    [ -f "$DAEMON_STATE_FILE" ] || return 1
    pid=$(jq -er '.pid | select(type == "number" and . > 0 and floor == .)' "$DAEMON_STATE_FILE") || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    digest=$(sha256sum "$CONFIG_FILE") || return 1
    digest=${digest%% *}
    now=$(date +%s)
    jq -e --arg digest "$digest" --argjson queue "$QUEUE_NUMBER" --argjson now "$now" \
        --argjson age "$((RECONCILE_SECONDS + 12))" '
        .owner == "port-traffic-dog-ip-guard:v2" and .queue == $queue and
        .config_sha256 == $digest and .updated_at <= ($now + 1) and
        .updated_at >= ($now - $age) and (.ports | type == "object")' \
        "$DAEMON_STATE_FILE" >/dev/null || return 1
    awk -v queue="$QUEUE_NUMBER" -v pid="$pid" \
        '$1 == queue && $2 == pid {found=1} END {exit !found}' \
        /proc/net/netfilter/nfnetlink_queue 2>/dev/null
}

show_status() {
    init_config
    load_policies
    echo -e "${BLUE}=== 在线 IP / 并发连接限制（测试中） ===${NC}"
    echo "口径: 每个本机 TCP 服务端口，IPv4/IPv6 合计；每项 0 表示不限。"
    echo "仅保护本机 INPUT；首个 SYN 直接准入，已有活跃连接保留。"
    echo "连接关闭后按快照回收（默认每 ${RECONCILE_SECONDS} 秒）；空闲 IP 名额可让给新来源。"
    local port ips connections
    local live=false
    if runtime_state_valid; then live=true; fi
    if [ ${#POLICY_LIMIT[@]} -eq 0 ]; then
        echo "当前没有生效的限制。"
    fi
    for port in $(printf '%s\n' "${!POLICY_LIMIT[@]}" | sort -n); do
        ips="未知"; connections="未知"
        if [ "$live" = true ]; then
            ips=$(jq -r --arg port "$port" '.ports[$port].online_ips // "未知"' "$DAEMON_STATE_FILE")
            connections=$(jq -r --arg port "$port" '.ports[$port].connections // "未知"' "$DAEMON_STATE_FILE")
        fi
        echo "端口 $port: 在线 IP $ips / ${POLICY_LIMIT[$port]}；连接 $connections / ${POLICY_CONNECTIONS[$port]}（0=不限）"
    done
    if [ "$live" = true ]; then echo "准入引擎: 运行中"; else echo "准入引擎: 未运行或状态未通过核验"; fi
}

nft_port_contract_valid() {
    local table_json="$1" port="$2"
    printf '%s' "$table_json" | jq -e --argjson port "$port" --argjson queue "$QUEUE_NUMBER" '
        any(.nftables[]; .rule? |
            .chain == "guard_input" and
            .comment == ("ptd_ip_guard_" + ($port | tostring) + "_syn_queue") and
            (.expr | length) == 3 and
            .expr[0].match == {op:"==",left:{payload:{protocol:"tcp",field:"dport"}},right:$port} and
            .expr[1].match.op == "==" and
            .expr[1].match.left["&"][0] == {payload:{protocol:"tcp",field:"flags"}} and
            ((.expr[1].match.left["&"][1] | if type == "object" then .["|"] else . end | sort) == ["ack","fin","rst","syn"]) and
            .expr[1].match.right == "syn" and
            .expr[2].queue.num == $queue and .expr[2].queue.flags == "bypass")
    ' >/dev/null
}

self_check() {
    check_dependencies || return 1
    init_config || return 1
    load_policies || return 1
    if [ ${#POLICY_LIMIT[@]} -eq 0 ]; then
        echo "IP_GUARD_STATUS=IDLE"
        return 0
    fi
    service_file_is_owned || {
        echo "IP_GUARD_STATUS=ERROR REASON=service-unit-unowned"
        return 1
    }
    "$SYSTEMCTL" is-active --quiet "$SERVICE_NAME" 2>/dev/null || {
        echo "IP_GUARD_STATUS=ERROR REASON=service-inactive"
        return 1
    }
    require_owned_table || {
        echo "IP_GUARD_STATUS=ERROR REASON=table-unowned-or-missing"
        return 1
    }
    local table_json port
    table_json=$(nft -j list table inet "$TABLE_NAME" 2>/dev/null) || {
        echo "IP_GUARD_STATUS=ERROR REASON=rules-unreadable"
        return 1
    }
    printf '%s' "$table_json" |
        jq -e --argjson expected_rules "$(( ${#POLICY_LIMIT[@]} + 1 ))" '
            ([.nftables[] | .chain? // empty] | length) == 1 and
            any(.nftables[]; .chain? |
                .name == "guard_input" and .type == "filter" and
                .hook == "input" and .prio == -20 and .policy == "accept") and
            ([.nftables[] | .set? // empty] | length) == 0 and
            any(.nftables[]; .rule? |
                .chain == "guard_input" and .comment == "ptd_ip_guard_existing" and
                .expr == [{match:{op:"in",left:{ct:{key:"state"}},right:["established","related"]}},{accept:null}]) and
            ([.nftables[] | .rule? // empty] | length) == $expected_rules
        ' >/dev/null || {
            echo "IP_GUARD_STATUS=ERROR REASON=rules-incomplete"
            return 1
        }
    for port in "${!POLICY_LIMIT[@]}"; do
        if ! nft_port_contract_valid "$table_json" "$port"; then
            echo "IP_GUARD_STATUS=ERROR REASON=port-contract-invalid PORT=$port"
            return 1
        fi
    done
    runtime_state_valid || {
        echo "IP_GUARD_STATUS=ERROR REASON=queue-or-runtime-invalid"
        return 1
    }
    echo "IP_GUARD_STATUS=OK PORTS=${#POLICY_LIMIT[@]}"
}

uninstall_feature() {
    local assume_yes="${1:-false}"
    if [ "$assume_yes" != "true" ]; then
        local confirm
        read -r -p "确认删除 IP 上限测试功能及其配置? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    fi
    if ! command_exists nft || ! command_exists jq; then
        echo "缺少 nft 或 jq，无法安全确认并卸载 nftables 表。" >&2
        return 1
    fi
    inspect_table_state || return 1
    [ "$TABLE_STATE" != "foreign" ] || return 1
    stop_service_strict || return 1
    remove_owned_table || return 1
    rm -f "$SERVICE_FILE" "$CONFIG_FILE"
    if systemd_runtime_available && ! "$SYSTEMCTL" daemon-reload >/dev/null 2>&1; then
        echo "警告：组件已停止、解封并删除，但 systemd daemon-reload 失败；请稍后手动执行 systemctl daemon-reload。" >&2
    fi
    echo "IP 上限测试功能已卸载。"
}

interactive_menu() {
    while true; do
        clear 2>/dev/null || true
        show_status
        echo
        echo "1. 添加或修改端口上限"
        echo "2. 删除端口上限"
        echo "3. 自检并重建"
        echo "4. 卸载此测试功能"
        echo "5. 查看 IP Guard 日志"
        echo "0. 返回 Dog 主菜单"
        echo
        local choice port limit connections idle
        read -r -p "请选择 [0-5]: " choice || return 0
        case "$choice" in
            1)
                read -r -p "单个 TCP 端口 [1-65535]: " port || return 0
                read -r -p "最多同时在线 IP 数 [0-$MAX_LIMIT，0=不限]: " limit || return 0
                read -r -p "最多并发 TCP 连接数 [0-$MAX_LIMIT，0=不限]: " connections || return 0
                idle=$(jq -r --arg port "$port" --argjson idle "$DEFAULT_IDLE_TIMEOUT" '.ports[$port].idle_timeout // $idle' "$CONFIG_FILE")
                if ! validate_port "$port" || ! validate_limit "$limit" || ! validate_limit "$connections"; then
                    echo -e "${RED}端口或上限无效。${NC}"
                elif ! load_policies || ! interactive_confirm_current_ssh "$port" ""; then
                    echo -e "${YELLOW}操作已取消。${NC}"
                elif update_config_and_apply ".ports[\$port] = {max_ips: \$limit, max_connections: \$connections, idle_timeout: \$idle}" \
                    "$SSH_CONFIRMATION_TOKEN" --arg port "$port" --argjson limit "$limit" \
                    --argjson connections "$connections" --argjson idle "$idle"; then
                    echo -e "${GREEN}端口 $port：在线 IP 上限 $limit，连接上限 $connections（0=不限）。${NC}"
                else
                    echo -e "${RED}配置或服务应用失败。${NC}"
                fi
                ;;
            2)
                read -r -p "要删除限制的 TCP 端口: " port
                if ! validate_port "$port"; then
                    echo -e "${RED}端口无效。${NC}"
                elif ! load_policies || ! interactive_confirm_current_ssh "" "$port"; then
                    echo -e "${YELLOW}操作已取消。${NC}"
                elif update_config_and_apply "del(.ports[\$port])" \
                    "$SSH_CONFIRMATION_TOKEN" --arg port "$port"; then
                    echo -e "${GREEN}端口 $port 的来源 IP 上限已删除。${NC}"
                else
                    echo -e "${RED}删除失败。${NC}"
                fi
                ;;
            3)
                if ! load_policies || ! interactive_confirm_current_ssh "" ""; then
                    echo -e "${YELLOW}操作已取消。${NC}"
                elif apply_if_configured "$SSH_CONFIRMATION_TOKEN" && self_check; then
                    echo -e "${GREEN}自检/重建完成。${NC}"
                else
                    echo -e "${RED}自检/重建失败，请查看 systemctl status $SERVICE_NAME。${NC}"
                fi
                ;;
            4) uninstall_feature ;;
            5) show_guard_logs ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择。${NC}" ;;
        esac
        echo
        read -r -p "按回车继续..."
    done
}

SSH_CLI_CONFIRMATION=""
parse_optional_ssh_confirmation() {
    SSH_CLI_CONFIRMATION=""
    case "$#" in
        0) return 0 ;;
        2)
            [ "$1" = "--confirm-restrict-ssh" ] && [ "$2" = "RESTRICT_SSH" ] || return 1
            SSH_CLI_CONFIRMATION="RESTRICT_SSH"
            ;;
        *) return 1 ;;
    esac
}

main() {
    check_bash_version || return 1
    case "${1:-}" in
        --logs)
            [ $# -eq 1 ] || { usage; return 1; }
            show_guard_logs
            ;;
        --run)
            shift
            parse_optional_ssh_confirmation "$@" || { usage; return 1; }
            require_root
            validate_runtime_settings
            run_daemon "$SSH_CLI_CONFIRMATION"
            ;;
        --apply|--apply-if-configured)
            shift
            parse_optional_ssh_confirmation "$@" || { usage; return 1; }
            require_root
            validate_runtime_settings
            apply_if_configured "$SSH_CLI_CONFIRMATION"
            ;;
        --self-check)
            [ $# -eq 1 ] || { usage; return 1; }
            require_root
            validate_runtime_settings
            self_check
            ;;
        --validate-config)
            [ $# -eq 2 ] || return 1
            check_validation_dependency
            validate_config_file "$2"
            ;;
        --render-rules)
            [ $# -eq 1 ] || { usage; return 1; }
            require_root
            validate_runtime_settings
            check_validation_dependency
            init_config
            load_policies
            render_ruleset false
            ;;
        --fail-open)
            [ $# -eq 1 ] || { usage; return 1; }
            require_root
            validate_runtime_settings
            fail_open_firewall
            ;;
        --uninstall)
            [ $# -le 2 ] || { usage; return 1; }
            [ $# -eq 1 ] || [ "$2" = "--yes" ] || { usage; return 1; }
            require_root
            validate_runtime_settings
            uninstall_feature "$([ $# -eq 2 ] && echo true || echo false)"
            ;;
        "")
            require_root
            validate_runtime_settings
            check_dependencies
            interactive_menu
            ;;
        *) usage; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
