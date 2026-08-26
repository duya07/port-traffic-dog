#!/bin/bash

set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCRIPT_FILE="$PROJECT_DIR/port-ip-guard.sh"
readonly SYSTEMCTL_TRACE="$TEST_DIR/systemctl.trace"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap 'echo "ip guard regression failed at line $LINENO" >&2' ERR

export PTD_IP_GUARD_CONFIG_DIR="$TEST_DIR/config"
export PTD_IP_GUARD_CONFIG_FILE="$TEST_DIR/config/ip-guard.json"
export PTD_IP_GUARD_LOCK_FILE="$TEST_DIR/ip-guard.lock"
export PTD_IP_GUARD_SERVICE_FILE="$TEST_DIR/port-traffic-dog-ip-guard.service"
export PTD_IP_GUARD_SCRIPT_PATH="$TEST_DIR/config/port-ip-guard.sh"
export PTD_IP_GUARD_SYSTEMCTL="mock_systemctl"

source "$SCRIPT_FILE"
# nftables 1.0.x 的 JSON 可能省略表 comment；只接受表顶层精确所有权标记。
OWNER_TABLES_JSON="$TEST_DIR/owner-tables.json"
OWNER_TABLE_JSON="$TEST_DIR/owner-table.json"
jq -n --arg name "$TABLE_NAME" '{nftables:[{table:{family:"inet",name:$name}}]}' > "$OWNER_TABLES_JSON"
cp "$OWNER_TABLES_JSON" "$OWNER_TABLE_JSON"

(
    nft() {
        case "$*" in
            "-j list tables") cat "$OWNER_TABLES_JSON" ;;
            "-j list table inet $TABLE_NAME") cat "$OWNER_TABLE_JSON" ;;
            "list table inet $TABLE_NAME")
                printf 'table inet %s {\n\tcomment "%s"\n}\n' "$TABLE_NAME" "$TABLE_OWNER_MARKER"
                ;;
            *) return 1 ;;
        esac
    }
    inspect_table_state
    [ "$TABLE_STATE" = "owned" ]
)

(
    nft() {
        case "$*" in
            "-j list tables") cat "$OWNER_TABLES_JSON" ;;
            "-j list table inet $TABLE_NAME") cat "$OWNER_TABLE_JSON" ;;
            "list table inet $TABLE_NAME")
                printf 'table inet %s {\n\tchain fake {\n\t\tcomment "%s"\n\t}\n}\n' "$TABLE_NAME" "$TABLE_OWNER_MARKER"
                ;;
            *) return 1 ;;
        esac
    }
    inspect_table_state 2>/dev/null
    [ "$TABLE_STATE" = "foreign" ]
)


# conntrack 事件按来源 IP 去重；较早来源释放后，下一个等待来源自动准入。
(
    POLICY_LIMIT=([3265]=2)
    FLOW_SOURCE=()
    ACTIVE_COUNT=()
    ADMITTED=()
    FIRST_SEEN=()
    SEQUENCE=0
    sync_admitted_sets() { :; }
    process_conntrack_event '[NEW] tcp 6 120 SYN_SENT src=198.51.100.1 dst=192.0.2.10 sport=40001 dport=3265'
    process_conntrack_event '[NEW] tcp 6 120 SYN_SENT src=198.51.100.2 dst=192.0.2.10 sport=40002 dport=3265'
    process_conntrack_event '[NEW] tcp 6 120 SYN_SENT src=198.51.100.1 dst=192.0.2.10 sport=41001 dport=3265'
    process_conntrack_event '[NEW] tcp 6 120 SYN_SENT src=198.51.100.3 dst=192.0.2.10 sport=40003 dport=3265'
    [ -n "${ADMITTED[3265|198.51.100.1]:-}" ]
    [ -n "${ADMITTED[3265|198.51.100.2]:-}" ]
    [ -z "${ADMITTED[3265|198.51.100.3]:-}" ]
    [ "${ACTIVE_COUNT[3265|198.51.100.1]}" -eq 2 ]
    process_conntrack_event '[DESTROY] tcp 6 0 src=198.51.100.1 dst=192.0.2.10 sport=40001 dport=3265'
    [ "${ACTIVE_COUNT[3265|198.51.100.1]}" -eq 1 ]
    [ -n "${ADMITTED[3265|198.51.100.1]:-}" ]
    process_conntrack_event '[DESTROY] tcp 6 0 src=198.51.100.1 dst=192.0.2.10 sport=41001 dport=3265'
    [ -z "${ADMITTED[3265|198.51.100.1]:-}" ]
    [ -n "${ADMITTED[3265|198.51.100.2]:-}" ]
    [ -n "${ADMITTED[3265|198.51.100.3]:-}" ]
)
MOCK_LOAD_STATE="loaded"
MOCK_ACTIVE_STATE="active"
MOCK_ENABLED_STATE="enabled"
MOCK_ACTIVE_AFTER_DISABLE="inactive"
MOCK_ACTIVE_AFTER_STOP="inactive"
MOCK_ENABLED_AFTER_DISABLE="disabled"
MOCK_DISABLE_RC=0
MOCK_STOP_RC=0
MOCK_DAEMON_RELOAD_RC=0

mock_systemctl() {
    printf '%s\n' "$*" >> "$SYSTEMCTL_TRACE"
    local action="${1:-}"
    shift || true
    case "$action" in
        show)
            case " $* " in
                *" --property=LoadState "*) echo "$MOCK_LOAD_STATE" ;;
                *" --property=ActiveState "*) echo "$MOCK_ACTIVE_STATE" ;;
                *) return 1 ;;
            esac
            ;;
        disable)
            MOCK_ACTIVE_STATE="$MOCK_ACTIVE_AFTER_DISABLE"
            MOCK_ENABLED_STATE="$MOCK_ENABLED_AFTER_DISABLE"
            return "$MOCK_DISABLE_RC"
            ;;
        stop)
            MOCK_ACTIVE_STATE="$MOCK_ACTIVE_AFTER_STOP"
            return "$MOCK_STOP_RC"
            ;;
        is-enabled)
            echo "$MOCK_ENABLED_STATE"
            [ "$MOCK_ENABLED_STATE" = "enabled" ]
            ;;
        daemon-reload) return "$MOCK_DAEMON_RELOAD_RC" ;;
        *) return 1 ;;
    esac
}

reset_systemctl_mock() {
    MOCK_LOAD_STATE="loaded"
    MOCK_ACTIVE_STATE="active"
    MOCK_ENABLED_STATE="enabled"
    MOCK_ACTIVE_AFTER_DISABLE="inactive"
    MOCK_ACTIVE_AFTER_STOP="inactive"
    MOCK_ENABLED_AFTER_DISABLE="disabled"
    MOCK_DISABLE_RC=0
    MOCK_STOP_RC=0
    MOCK_DAEMON_RELOAD_RC=0
    : > "$SYSTEMCTL_TRACE"
    mkdir -p "$(dirname "$SERVICE_FILE")"
    : > "$SERVICE_FILE"
}

# 成功路径必须先请求 disable --now/stop，再以最终 systemd 状态为准。
reset_systemctl_mock
stop_service_strict
grep -Fq "disable --now $SERVICE_NAME" "$SYSTEMCTL_TRACE"
grep -Fq "stop $SERVICE_NAME" "$SYSTEMCTL_TRACE"

# 命令即使返回成功，只要最后仍 active 就必须失败。
reset_systemctl_mock
MOCK_ACTIVE_AFTER_DISABLE="active"
MOCK_ACTIVE_AFTER_STOP="active"
! stop_service_strict >/dev/null 2>&1

# 已停止但仍 enabled，或变成无法明确禁用的 static，也不能继续清理。
reset_systemctl_mock
MOCK_ENABLED_AFTER_DISABLE="enabled"
! stop_service_strict >/dev/null 2>&1
reset_systemctl_mock
MOCK_ENABLED_AFTER_DISABLE="static"
! stop_service_strict >/dev/null 2>&1

# systemd 报 not-found 时，只有服务文件也确实不存在才可视为已清理。
reset_systemctl_mock
MOCK_LOAD_STATE="not-found"
! stop_service_strict >/dev/null 2>&1
rm -f "$SERVICE_FILE"
stop_service_strict

# self-check 必须核对链、集合和每个端口规则的完整语义，不能只按对象数量通过。
SELF_CHECK_FIXTURE="$TEST_DIR/self-check.json"
jq -n '
    def allow($chain; $comment; $protocol; $set_name):
        {rule:{chain:$chain, comment:$comment, expr:[
            {match:{op:"==", left:{payload:{protocol:$protocol,field:"saddr"}}, right:("@" + $set_name)}},
            {match:{op:"==", left:{payload:{protocol:"tcp",field:"dport"}}, right:3265}},
            {accept:null}
        ]}};
    def block($chain):
        {rule:{chain:$chain, comment:"ptd_ip_guard_3265_drop", expr:[
            {match:{op:"==", left:{payload:{protocol:"tcp",field:"dport"}}, right:3265}},
            {drop:null}
        ]}};
    {
        nftables: [
            {metainfo:{version:"1.0.6"}},
            {chain:{name:"guard_input",type:"filter",hook:"input",prio:-20,policy:"accept"}},
            {chain:{name:"guard_forward",type:"filter",hook:"forward",prio:-20,policy:"accept"}},
            {set:{name:"p3265_v4",type:"ipv4_addr"}},
            {set:{name:"p3265_v6",type:"ipv6_addr"}},
            allow("guard_input";"ptd_ip_guard_3265_v4_allow";"ip";"p3265_v4"),
            allow("guard_input";"ptd_ip_guard_3265_v6_allow";"ip6";"p3265_v6"),
            block("guard_input"),
            allow("guard_forward";"ptd_ip_guard_3265_v4_allow";"ip";"p3265_v4"),
            allow("guard_forward";"ptd_ip_guard_3265_v6_allow";"ip6";"p3265_v6"),
            block("guard_forward")
        ]
    }
' > "$SELF_CHECK_FIXTURE"
(
    check_dependencies() { :; }
    init_config() { :; }
    load_policies() { POLICY_LIMIT=([3265]=2); }
    mock_systemctl() { [ "${1:-}" = "is-active" ]; }
    require_owned_table() { :; }
    nft() { cat "$SELF_CHECK_FIXTURE"; }
    self_check
) | grep -Fxq 'IP_GUARD_STATUS=OK PORTS=1'

BROKEN_SELF_CHECK_FIXTURE="$TEST_DIR/self-check-broken.json"
jq '(.nftables[] | select(.rule?.chain == "guard_input" and
    .rule?.comment == "ptd_ip_guard_3265_v4_allow") |
    .rule.expr[1].match.right) = 9999' "$SELF_CHECK_FIXTURE" > "$BROKEN_SELF_CHECK_FIXTURE"
(
    check_dependencies() { :; }
    init_config() { :; }
    load_policies() { POLICY_LIMIT=([3265]=2); }
    mock_systemctl() { [ "${1:-}" = "is-active" ]; }
    require_owned_table() { :; }
    nft() { cat "$BROKEN_SELF_CHECK_FIXTURE"; }
    ! self_check >/dev/null 2>&1
)

# 入口级验证：空策略和卸载都不得在残留 active 时继续删除防火墙或文件。
FAIL_OPEN_CAPTURE="$TEST_DIR/fail-open.capture"
REMOVE_CAPTURE="$TEST_DIR/remove.capture"
check_validation_dependency() { :; }
init_config() { mkdir -p "$CONFIG_DIR"; }
load_policies() { POLICY_LIMIT=(); }
require_current_ssh_confirmation() { :; }
inspect_table_state() { TABLE_STATE="owned"; }
fail_open_firewall() { touch "$FAIL_OPEN_CAPTURE"; }
remove_owned_table() { touch "$REMOVE_CAPTURE"; }
nft() { :; }
jq() { :; }

reset_systemctl_mock
MOCK_ACTIVE_AFTER_DISABLE="active"
MOCK_ACTIVE_AFTER_STOP="active"
! apply_if_configured >/dev/null 2>&1
[ ! -e "$FAIL_OPEN_CAPTURE" ]

mkdir -p "$(dirname "$CONFIG_FILE")"
: > "$CONFIG_FILE"
reset_systemctl_mock
MOCK_ACTIVE_AFTER_DISABLE="active"
MOCK_ACTIVE_AFTER_STOP="active"
! uninstall_feature true >/dev/null 2>&1
[ ! -e "$REMOVE_CAPTURE" ]
[ -e "$SERVICE_FILE" ]
[ -e "$CONFIG_FILE" ]

# 确认 inactive + disabled 后，两条入口才允许进入 fail-open 清理。
reset_systemctl_mock
apply_if_configured >/dev/null
[ -e "$FAIL_OPEN_CAPTURE" ]

rm -f "$REMOVE_CAPTURE"
mkdir -p "$(dirname "$CONFIG_FILE")"
: > "$CONFIG_FILE"
reset_systemctl_mock
uninstall_feature true >/dev/null
[ -e "$REMOVE_CAPTURE" ]
[ ! -e "$SERVICE_FILE" ]
[ ! -e "$CONFIG_FILE" ]

# 已完成 stop + fail-open + 文件删除后，daemon-reload 失败只能警告，不能伪装成可回滚失败。
mkdir -p "$(dirname "$CONFIG_FILE")"
: > "$CONFIG_FILE"
reset_systemctl_mock
MOCK_DAEMON_RELOAD_RC=1
uninstall_feature true > "$TEST_DIR/uninstall-reload.out" 2>&1
grep -Fq 'daemon-reload 失败' "$TEST_DIR/uninstall-reload.out"
[ ! -e "$SERVICE_FILE" ]
[ ! -e "$CONFIG_FILE" ]

# 菜单配置与运行规则是一个事务：首次 apply 失败时恢复原配置并重新应用旧策略。
printf '%s\n' '{"schema":"port-traffic-dog-ip-guard-v1","ports":{"3265":{"max_ips":2}}}' > "$CONFIG_FILE"
cp "$CONFIG_FILE" "$TEST_DIR/config.before-transaction"
APPLY_TRANSACTION_COUNT=0
apply_if_configured() {
    APPLY_TRANSACTION_COUNT=$((APPLY_TRANSACTION_COUNT + 1))
    [ "$APPLY_TRANSACTION_COUNT" -ge 2 ]
}
! update_config_and_apply 'del(.ports[$port])' token --arg port 3265 >/dev/null 2>&1
cmp -s "$CONFIG_FILE" "$TEST_DIR/config.before-transaction"
[ "$APPLY_TRANSACTION_COUNT" -eq 2 ]

echo "ip guard regression passed"
