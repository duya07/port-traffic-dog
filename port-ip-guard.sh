#!/bin/bash

set -euo pipefail
umask 077

# PORT_TRAFFIC_DOG_IP_GUARD
# 独立实验组件：按 TCP conntrack 活跃项限制单端口的来源 IP 总数。

CONFIG_DIR="${PTD_IP_GUARD_CONFIG_DIR:-/etc/port-traffic-dog}"
CONFIG_FILE="${PTD_IP_GUARD_CONFIG_FILE:-$CONFIG_DIR/ip-guard.json}"
LOCK_FILE="${PTD_IP_GUARD_LOCK_FILE:-/run/lock/port-traffic-dog-ip-guard.lock}"
TABLE_NAME="${PTD_IP_GUARD_TABLE_NAME:-port_traffic_dog_ip_guard}"
readonly TABLE_OWNER_MARKER="port-traffic-dog-ip-guard:v1"
SERVICE_NAME="${PTD_IP_GUARD_SERVICE_NAME:-port-traffic-dog-ip-guard.service}"
SERVICE_FILE="${PTD_IP_GUARD_SERVICE_FILE:-/etc/systemd/system/$SERVICE_NAME}"
INSTALLED_SCRIPT="${PTD_IP_GUARD_SCRIPT_PATH:-$CONFIG_DIR/port-ip-guard.sh}"
SYSTEMCTL="${PTD_IP_GUARD_SYSTEMCTL:-systemctl}"
RECONCILE_SECONDS="${PTD_IP_GUARD_RECONCILE_SECONDS:-60}"
readonly MAX_LIMIT=1024

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

declare -A POLICY_LIMIT=()
declare -A FLOW_SOURCE=()
declare -A ACTIVE_COUNT=()
declare -A ADMITTED=()
declare -A FIRST_SEEN=()
declare -A ADMISSION_CHANGED_PORTS=()
declare -A LOCAL_ADDRESSES=()
SEQUENCE=0
ADMISSION_CHANGED=false
PARSED_EVENT=""
PARSED_SOURCE=""
PARSED_DESTINATION=""
PARSED_SPORT=""
PARSED_DPORT=""
PARSED_REPLY_SOURCE=""
PARSED_REPLY_DESTINATION=""
PARSED_REPLY_SPORT=""
PARSED_REPLY_DPORT=""
TABLE_STATE="error"
DAEMON_LISTENER_PID=""
DAEMON_EVENT_FIFO=""

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
    [[ "$RECONCILE_SECONDS" =~ ^[0-9]+$ ]] &&
        [ "$RECONCILE_SECONDS" -ge 1 ] && [ "$RECONCILE_SECONDS" -le 86400 ] || {
        echo "PTD_IP_GUARD_RECONCILE_SECONDS 必须是 1-86400 的整数。" >&2
        return 1
    }
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
    for command_name in nft jq conntrack flock ip; do
        command_exists "$command_name" || missing+=("$command_name")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "缺少依赖: ${missing[*]}（Debian/Ubuntu 可安装 nftables jq conntrack iproute2）" >&2
        return 1
    fi
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
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "$MAX_LIMIT" ]
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
            ((.value | keys) == ["max_ips"]) and
            (.value.max_ips | type == "number") and
            (.value.max_ips >= 1) and (.value.max_ips <= $max) and
            ((.value.max_ips | floor) == .value.max_ips)
        ] | all)
    ' "$config_path" >/dev/null || {
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
    local port limit policy_data
    validate_config || return 1
    policy_data=$(jq -r '.ports | to_entries[] | "\(.key) \(.value.max_ips)"' "$CONFIG_FILE") || return 1
    while read -r port limit; do
        [ -n "$port" ] || continue
        validate_port "$port" && validate_limit "$limit" || return 1
        POLICY_LIMIT["$port"]="$limit"
    done <<< "$policy_data"
}

set_name_v4() {
    echo "p${1}_v4"
}

set_name_v6() {
    echo "p${1}_v6"
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
    local port key address

    if [ "$replace_existing" = "true" ]; then
        printf 'delete table inet %s\n' "$TABLE_NAME"
    fi
    # create 会在同名表于检查后被其他程序建立时失败，不会接管未知表。
    printf 'create table inet %s { comment "%s"; }\n' "$TABLE_NAME" "$TABLE_OWNER_MARKER"
    printf 'add chain inet %s guard_input { type filter hook input priority -20; policy accept; }\n' "$TABLE_NAME"

    for port in $(printf '%s\n' "${!POLICY_LIMIT[@]}" | sort -n); do
        printf 'add set inet %s %s { type ipv4_addr; }\n' "$TABLE_NAME" "$(set_name_v4 "$port")"
        printf 'add set inet %s %s { type ipv6_addr; }\n' "$TABLE_NAME" "$(set_name_v6 "$port")"
        for key in "${!ADMITTED[@]}"; do
            [[ "$key" == "$port|"* ]] || continue
            address=${key#*|}
            validate_address_token "$address" || {
                echo "拒绝把无效来源地址写入 nftables: $address" >&2
                return 1
            }
            if [[ "$address" == *:* ]]; then
                printf 'add element inet %s %s { %s }\n' "$TABLE_NAME" "$(set_name_v6 "$port")" "$address"
            else
                printf 'add element inet %s %s { %s }\n' "$TABLE_NAME" "$(set_name_v4 "$port")" "$address"
            fi
        done
        printf 'add rule inet %s guard_input ip saddr @%s tcp dport %s accept comment "ptd_ip_guard_%s_v4_allow"\n' \
            "$TABLE_NAME" "$(set_name_v4 "$port")" "$port" "$port"
        printf 'add rule inet %s guard_input ip6 saddr @%s tcp dport %s accept comment "ptd_ip_guard_%s_v6_allow"\n' \
            "$TABLE_NAME" "$(set_name_v6 "$port")" "$port" "$port"
        printf 'add rule inet %s guard_input tcp dport %s drop comment "ptd_ip_guard_%s_drop"\n' \
            "$TABLE_NAME" "$port" "$port"
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

sync_admitted_sets() {
    local batch_file
    local port key address
    local ports=()
    local -A selected_ports=()

    if [ "$#" -gt 0 ]; then
        for port in "$@"; do
            validate_port "$port" && [ -n "${POLICY_LIMIT[$port]:-}" ] || {
                echo "拒绝同步未配置的 IP 上限端口: $port" >&2
                return 1
            }
            [ -n "${selected_ports[$port]:-}" ] && continue
            selected_ports["$port"]=1
            ports+=("$port")
        done
    else
        for port in "${!POLICY_LIMIT[@]}"; do
            selected_ports["$port"]=1
            ports+=("$port")
        done
    fi
    [ "${#ports[@]}" -gt 0 ] || return 0

    require_owned_table || return 1
    batch_file=$(mktemp "$CONFIG_DIR/.ip-guard-sets.XXXXXX") || return 1
    for port in "${ports[@]}"; do
        printf 'flush set inet %s %s\n' "$TABLE_NAME" "$(set_name_v4 "$port")" >> "$batch_file"
        printf 'flush set inet %s %s\n' "$TABLE_NAME" "$(set_name_v6 "$port")" >> "$batch_file"
    done
    for key in "${!ADMITTED[@]}"; do
        port=${key%%|*}
        address=${key#*|}
        [ -n "${selected_ports[$port]:-}" ] || continue
        validate_address_token "$address" || {
            echo "拒绝把无效来源地址写入 nftables: $address" >&2
            rm -f "$batch_file"
            return 1
        }
        if [[ "$address" == *:* ]]; then
            printf 'add element inet %s %s { %s }\n' "$TABLE_NAME" "$(set_name_v6 "$port")" "$address" >> "$batch_file"
        else
            printf 'add element inet %s %s { %s }\n' "$TABLE_NAME" "$(set_name_v4 "$port")" "$address" >> "$batch_file"
        fi
    done
    if ! apply_nft_batch "$batch_file"; then
        rm -f "$batch_file"
        return 1
    fi
    rm -f "$batch_file"
}

parse_conntrack_line() {
    local line="$1"
    local token
    local tokens=()
    PARSED_EVENT="SNAPSHOT"
    PARSED_SOURCE=""
    PARSED_DESTINATION=""
    PARSED_SPORT=""
    PARSED_DPORT=""
    PARSED_REPLY_SOURCE=""
    PARSED_REPLY_DESTINATION=""
    PARSED_REPLY_SPORT=""
    PARSED_REPLY_DPORT=""
    read -r -a tokens <<< "$line"
    for token in "${tokens[@]}"; do
        case "$token" in
            '[NEW]') PARSED_EVENT="NEW" ;;
            '[DESTROY]') PARSED_EVENT="DESTROY" ;;
            src=*)
                if [ -z "$PARSED_SOURCE" ]; then
                    PARSED_SOURCE=${token#src=}
                elif [ -z "$PARSED_REPLY_SOURCE" ]; then
                    PARSED_REPLY_SOURCE=${token#src=}
                fi
                ;;
            dst=*)
                if [ -z "$PARSED_DESTINATION" ]; then
                    PARSED_DESTINATION=${token#dst=}
                elif [ -z "$PARSED_REPLY_DESTINATION" ]; then
                    PARSED_REPLY_DESTINATION=${token#dst=}
                fi
                ;;
            sport=*)
                if [ -z "$PARSED_SPORT" ]; then
                    PARSED_SPORT=${token#sport=}
                elif [ -z "$PARSED_REPLY_SPORT" ]; then
                    PARSED_REPLY_SPORT=${token#sport=}
                fi
                ;;
            dport=*)
                if [ -z "$PARSED_DPORT" ]; then
                    PARSED_DPORT=${token#dport=}
                elif [ -z "$PARSED_REPLY_DPORT" ]; then
                    PARSED_REPLY_DPORT=${token#dport=}
                fi
                ;;
        esac
    done
    validate_address_token "$PARSED_SOURCE" && validate_address_token "$PARSED_DESTINATION" &&
        validate_port "$PARSED_SPORT" && validate_port "$PARSED_DPORT" &&
        validate_address_token "$PARSED_REPLY_SOURCE" &&
        validate_address_token "$PARSED_REPLY_DESTINATION" &&
        validate_port "$PARSED_REPLY_SPORT" && validate_port "$PARSED_REPLY_DPORT"
}

load_local_addresses() {
    local address_output index interface_name family address remainder

    LOCAL_ADDRESSES=()
    address_output=$(ip -o address show 2>/dev/null) || return 1
    while read -r index interface_name family address remainder; do
        case "$family" in
            inet|inet6) ;;
            *) continue ;;
        esac
        address=${address%/*}
        validate_address_token "$address" || continue
        LOCAL_ADDRESSES["$address"]=1
    done <<< "$address_output"
    [ "${#LOCAL_ADDRESSES[@]}" -gt 0 ]
}

parsed_inbound_policy_port() {
    local policy_port="$PARSED_REPLY_SPORT"

    [ -n "${POLICY_LIMIT[$policy_port]:-}" ] || return 1
    [ -n "${LOCAL_ADDRESSES[$PARSED_REPLY_SOURCE]:-}" ] || return 1
    printf '%s\n' "$policy_port"
}

flow_key_from_parsed() {
    printf '%s|%s|%s|%s\n' "$PARSED_SOURCE" "$PARSED_DESTINATION" "$PARSED_SPORT" "$PARSED_DPORT"
}

record_flow() {
    local flow_key="$1"
    local active_key="$2"
    [ -z "${FLOW_SOURCE[$flow_key]:-}" ] || return 0
    FLOW_SOURCE["$flow_key"]="$active_key"
    ACTIVE_COUNT["$active_key"]=$(( ${ACTIVE_COUNT[$active_key]:-0} + 1 ))
    if [ -z "${FIRST_SEEN[$active_key]:-}" ]; then
        SEQUENCE=$((SEQUENCE + 1))
        FIRST_SEEN["$active_key"]="$SEQUENCE"
    fi
}

forget_flow() {
    local flow_key="$1"
    local active_key="${FLOW_SOURCE[$flow_key]:-}"
    [ -n "$active_key" ] || return 1
    unset 'FLOW_SOURCE[$flow_key]'
    local count=$(( ${ACTIVE_COUNT[$active_key]:-1} - 1 ))
    if [ "$count" -le 0 ]; then
        unset 'ACTIVE_COUNT[$active_key]' 'ADMITTED[$active_key]' 'FIRST_SEEN[$active_key]'
    else
        ACTIVE_COUNT["$active_key"]="$count"
    fi
}

recalculate_port_admission() {
    local port="$1"
    local max_ips="${POLICY_LIMIT[$port]}"
    local key
    local candidates=()
    local -A previous_admitted=()
    ADMISSION_CHANGED=false
    for key in "${!ADMITTED[@]}"; do
        if [[ "$key" == "$port|"* ]]; then
            previous_admitted["$key"]=1
            unset 'ADMITTED[$key]'
        fi
    done
    mapfile -t candidates < <(
        for key in "${!ACTIVE_COUNT[@]}"; do
            [[ "$key" == "$port|"* ]] || continue
            printf '%012d %s\n' "${FIRST_SEEN[$key]:-999999999999}" "$key"
        done | sort -n -k1,1 -k2,2
    )
    local index=0
    local item
    for item in "${candidates[@]}"; do
        key=${item#* }
        if [ "$index" -lt "$max_ips" ]; then
            ADMITTED["$key"]=1
            [ -n "${previous_admitted[$key]:-}" ] || ADMISSION_CHANGED=true
        fi
        index=$((index + 1))
    done
    for key in "${!previous_admitted[@]}"; do
        [ -n "${ADMITTED[$key]:-}" ] || ADMISSION_CHANGED=true
    done
}

recalculate_all_admission() {
    local port
    ADMISSION_CHANGED_PORTS=()
    for port in "${!POLICY_LIMIT[@]}"; do
        recalculate_port_admission "$port"
        [ "$ADMISSION_CHANGED" = "true" ] && ADMISSION_CHANGED_PORTS["$port"]=1
    done
    return 0
}

sync_changed_admitted_sets() {
    [ "${#ADMISSION_CHANGED_PORTS[@]}" -gt 0 ] || return 0
    local changed_ports=()
    mapfile -t changed_ports < <(printf '%s\n' "${!ADMISSION_CHANGED_PORTS[@]}" | sort -n)
    sync_admitted_sets "${changed_ports[@]}"
}

load_conntrack_snapshot() {
    local snapshot_file
    load_local_addresses || return 1
    snapshot_file=$(mktemp "$CONFIG_DIR/.ip-guard-conntrack.XXXXXX") || return 1
    if ! conntrack -L -p tcp -o extended > "$snapshot_file" 2>/dev/null; then
        rm -f "$snapshot_file"
        return 1
    fi
    FLOW_SOURCE=()
    ACTIVE_COUNT=()
    local line flow_key active_key policy_port
    while IFS= read -r line; do
        parse_conntrack_line "$line" || continue
        policy_port=$(parsed_inbound_policy_port) || continue
        flow_key=$(flow_key_from_parsed)
        active_key="$policy_port|$PARSED_SOURCE"
        record_flow "$flow_key" "$active_key"
    done < "$snapshot_file"
    rm -f "$snapshot_file"
    local key
    for key in "${!FIRST_SEEN[@]}"; do
        [ -n "${ACTIVE_COUNT[$key]:-}" ] || unset 'FIRST_SEEN[$key]' 'ADMITTED[$key]'
    done
    recalculate_all_admission
}

process_conntrack_event() {
    local line="$1"
    parse_conntrack_line "$line" || return 0
    local policy_port
    policy_port=$(parsed_inbound_policy_port) || return 0
    local flow_key
    local active_key="$policy_port|$PARSED_SOURCE"
    flow_key=$(flow_key_from_parsed)
    case "$PARSED_EVENT" in
        NEW)
            record_flow "$flow_key" "$active_key"
            ;;
        DESTROY)
            forget_flow "$flow_key" || return 0
            ;;
        *) return 0 ;;
    esac
    recalculate_port_admission "$policy_port"
    [ "$ADMISSION_CHANGED" = "true" ] || return 0
    sync_admitted_sets "$policy_port"
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

fail_open_firewall() {
    if ! command_exists nft || ! command_exists jq; then
        echo "无法执行 fail-open：缺少 nft 或 jq，未能安全确认表所有权。" >&2
        return 1
    fi
    if remove_owned_table; then
        echo "IP 上限 nftables 规则已处于 fail-open 状态。"
        return 0
    fi
    echo "fail-open 拒绝删除未知或不可验证的同名 nftables 表。" >&2
    return 1
}

cleanup_daemon() {
    trap - EXIT INT TERM
    if [ -n "$DAEMON_LISTENER_PID" ]; then
        kill "$DAEMON_LISTENER_PID" >/dev/null 2>&1 || true
        wait "$DAEMON_LISTENER_PID" 2>/dev/null || true
    fi
    if [ -n "$DAEMON_EVENT_FIFO" ]; then
        exec 8>&- 2>/dev/null || true
        rm -f "$DAEMON_EVENT_FIFO"
    fi
    fail_open_firewall || true
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
        echo "另一个 IP 上限守护进程正在运行。" >&2
        return 1
    }
    trap cleanup_daemon EXIT
    trap 'exit 0' INT TERM

    [ ${#POLICY_LIMIT[@]} -gt 0 ] || return 0

    DAEMON_EVENT_FIFO="$CONFIG_DIR/.ip-guard-events.$$"
    mkfifo "$DAEMON_EVENT_FIFO"
    # 先持有 FIFO 读写端，再启动 conntrack 监听。否则写端会一直等待读端，
    # 全量快照和规则重建期间产生的 NEW/DESTROY 事件会形成监听空窗。
    if ! exec 8<>"$DAEMON_EVENT_FIFO"; then
        echo "无法打开 conntrack 事件通道。" >&2
        return 1
    fi
    conntrack -E -p tcp -e NEW,DESTROY -o timestamp,extended > "$DAEMON_EVENT_FIFO" &
    DAEMON_LISTENER_PID=$!

    load_conntrack_snapshot || {
        echo "无法读取 conntrack 初始快照，未启用 IP 上限。" >&2
        return 1
    }
    rebuild_firewall || {
        echo "无法建立 IP 上限 nftables 规则。" >&2
        return 1
    }
    echo "IP 上限守护已启动，端口数: ${#POLICY_LIMIT[@]}"

    local last_reconcile
    last_reconcile=$(date +%s)
    local line now
    while kill -0 "$DAEMON_LISTENER_PID" 2>/dev/null; do
        if IFS= read -r -t 1 line <&8; then
            process_conntrack_event "$line" || return 1
        fi
        now=$(date +%s)
        if [ $((now - last_reconcile)) -ge "$RECONCILE_SECONDS" ]; then
            if load_conntrack_snapshot; then
                sync_changed_admitted_sets || return 1
            else
                echo "conntrack 全量校准失败，保留当前准入集合。" >&2
            fi
            # 无论成功与否均按配置间隔执行下一次校准，避免故障时每秒扫描全表。
            last_reconcile="$now"
        fi
    done
    wait "$DAEMON_LISTENER_PID" || true
    echo "conntrack 事件监听意外退出。" >&2
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

install_service() {
    local service_dir temp_service
    command_exists "$SYSTEMCTL" || {
        echo "系统没有 systemd，无法持久运行该测试功能。" >&2
        return 1
    }
    install_script_safely || return 1
    service_dir=$(dirname "$SERVICE_FILE")
    mkdir -p "$service_dir" || return 1
    if [ -d "$SERVICE_FILE" ]; then
        echo "systemd 单元目标是目录，拒绝覆盖: $SERVICE_FILE" >&2
        return 1
    fi
    temp_service=$(mktemp "$service_dir/.${SERVICE_NAME}.XXXXXX") || return 1
    if cat > "$temp_service" <<EOF
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
}

stop_service_strict() {
    local load_state active_state enabled_state
    command_exists "$SYSTEMCTL" || {
        [ ! -e "$SERVICE_FILE" ] && return 0
        echo "缺少 systemctl，无法确认守护服务已停止。" >&2
        return 1
    }
    load_state=$("$SYSTEMCTL" show "$SERVICE_NAME" --property=LoadState --value 2>/dev/null) || {
        echo "无法查询 $SERVICE_NAME 的加载状态。" >&2
        return 1
    }
    if [ "$load_state" = "not-found" ]; then
        [ ! -e "$SERVICE_FILE" ] || return 1
        return 0
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

show_status() {
    init_config
    load_policies
    echo -e "${BLUE}=== 同时在线来源 IP 上限（测试中） ===${NC}"
    echo "口径: 本机 TCP 服务的 conntrack 活跃来源 IP；IPv4/IPv6 合并计数。"
    echo "范围: 仅保护本机 INPUT，不处理内核 FORWARD/DNAT 流量。"
    echo "未知来源先丢弃首个 SYN，准入后由 TCP 重传建立连接。"
    echo
    if [ ${#POLICY_LIMIT[@]} -eq 0 ]; then
        echo "尚未配置端口。"
        return
    fi
    inspect_table_state || TABLE_STATE="error"
    case "$TABLE_STATE" in
        owned) ;;
        absent) echo -e "${YELLOW}nftables 状态: 规则表尚未建立。${NC}" ;;
        foreign) echo -e "${RED}nftables 状态: 同名表不属于本脚本，已拒绝接管。${NC}" ;;
        *) echo -e "${RED}nftables 状态: 无法验证。${NC}" ;;
    esac
    local port allowed_v4 allowed_v6
    for port in $(printf '%s\n' "${!POLICY_LIMIT[@]}" | sort -n); do
        allowed_v4=0
        allowed_v6=0
        if [ "$TABLE_STATE" = "owned" ]; then
            allowed_v4=$(nft -j list set inet "$TABLE_NAME" "$(set_name_v4 "$port")" 2>/dev/null |
                jq -r '[.nftables[] | .set?.elem? // empty] | flatten | length' 2>/dev/null || echo 0)
            allowed_v6=$(nft -j list set inet "$TABLE_NAME" "$(set_name_v6 "$port")" 2>/dev/null |
                jq -r '[.nftables[] | .set?.elem? // empty] | flatten | length' 2>/dev/null || echo 0)
        fi
        echo "端口 $port: 上限 ${POLICY_LIMIT[$port]}，当前准入约 $((allowed_v4 + allowed_v6)) 个来源 IP"
    done
    if "$SYSTEMCTL" is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "守护服务: 运行中"
    else
        echo "守护服务: 未运行"
    fi
}

nft_port_contract_valid() {
    local table_json="$1"
    local port="$2"
    local set_v4 set_v6
    set_v4=$(set_name_v4 "$port")
    set_v6=$(set_name_v6 "$port")

    printf '%s' "$table_json" |
        jq -e --argjson port "$port" --arg set_v4 "$set_v4" --arg set_v6 "$set_v6" '
            def has_match($protocol; $field; $right):
                any(.expr[]?;
                    .match? |
                    .op == "==" and
                    .left.payload?.protocol == $protocol and
                    .left.payload?.field == $field and
                    ((.right | tostring) == ($right | tostring)));
            def has_verdict($verdict):
                any(.expr[]?; has($verdict));
            def allow_rule($chain; $comment; $protocol; $set_name):
                any(.nftables[]; .rule? |
                    .chain == $chain and .comment == $comment and
                    (.expr | length) == 3 and
                    has_match($protocol; "saddr"; ("@" + $set_name)) and
                    has_match("tcp"; "dport"; $port) and
                    has_verdict("accept"));
            def drop_rule($chain; $comment):
                any(.nftables[]; .rule? |
                    .chain == $chain and .comment == $comment and
                    (.expr | length) == 2 and
                    has_match("tcp"; "dport"; $port) and
                    has_verdict("drop"));

            any(.nftables[]; .set? | .name == $set_v4 and .type == "ipv4_addr") and
            any(.nftables[]; .set? | .name == $set_v6 and .type == "ipv6_addr") and
            allow_rule("guard_input"; ("ptd_ip_guard_" + ($port | tostring) + "_v4_allow"); "ip"; $set_v4) and
            allow_rule("guard_input"; ("ptd_ip_guard_" + ($port | tostring) + "_v6_allow"); "ip6"; $set_v6) and
            drop_rule("guard_input"; ("ptd_ip_guard_" + ($port | tostring) + "_drop"))
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
        jq -e --argjson expected_rules "$(( ${#POLICY_LIMIT[@]} * 3 ))" \
            --argjson expected_sets "$(( ${#POLICY_LIMIT[@]} * 2 ))" '
            ([.nftables[] | .chain? // empty] | length) == 1 and
            any(.nftables[]; .chain? |
                .name == "guard_input" and .type == "filter" and
                .hook == "input" and .prio == -20 and .policy == "accept") and
            ([.nftables[] | .set? // empty] | length) == $expected_sets and
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
    if ! "$SYSTEMCTL" daemon-reload >/dev/null 2>&1; then
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
        echo "0. 返回 Dog 主菜单"
        echo
        local choice port limit
        read -r -p "请选择 [0-4]: " choice
        case "$choice" in
            1)
                read -r -p "单个 TCP 端口 [1-65535]: " port
                read -r -p "最多同时活跃来源 IP 数 [1-$MAX_LIMIT]: " limit
                if ! validate_port "$port" || ! validate_limit "$limit"; then
                    echo -e "${RED}端口或上限无效。${NC}"
                elif ! load_policies || ! interactive_confirm_current_ssh "$port" ""; then
                    echo -e "${YELLOW}操作已取消。${NC}"
                elif update_config_and_apply ".ports[\$port] = {max_ips: \$limit}" \
                    "$SSH_CONFIRMATION_TOKEN" --arg port "$port" --argjson limit "$limit"; then
                    echo -e "${GREEN}端口 $port 的来源 IP 上限已设置为 $limit。${NC}"
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
