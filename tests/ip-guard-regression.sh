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

assert_fails() {
    if "$@"; then
        echo "expected command to fail but it succeeded: $*" >&2
        return 1
    fi
}

export PTD_IP_GUARD_CONFIG_DIR="$TEST_DIR/config"
export PTD_IP_GUARD_CONFIG_FILE="$TEST_DIR/config/ip-guard.json"
export PTD_IP_GUARD_LOCK_FILE="$TEST_DIR/ip-guard.lock"
export PTD_IP_GUARD_SERVICE_FILE="$TEST_DIR/port-traffic-dog-ip-guard.service"
export PTD_IP_GUARD_SCRIPT_PATH="$TEST_DIR/config/port-ip-guard.sh"
export PTD_IP_GUARD_SYSTEMCTL="mock_systemctl"

source "$SCRIPT_FILE"

# 后续不少用例会用同名函数覆盖 load_policies 做故障注入，而这些覆盖不在子 shell 里，
# 会一直泄漏到文件末尾。需要真实行为的用例用下面这份原定义恢复。
readonly ORIGINAL_LOAD_POLICIES_DEFINITION="$(declare -f load_policies)"

# 当前实验功能只保护本机 INPUT；不得对无法可靠识别来源的 FORWARD/DNAT 流量下发 drop。
(
    POLICY_LIMIT=([3265]=2)
    ADMITTED=()
    render_ruleset false > "$TEST_DIR/rendered-rules.nft"
)
grep -Fq 'hook input' "$TEST_DIR/rendered-rules.nft"
assert_fails grep -Fq 'guard_forward' "$TEST_DIR/rendered-rules.nft"
assert_fails grep -Fq 'hook forward' "$TEST_DIR/rendered-rules.nft"

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


MOCK_LOAD_STATE="loaded"
MOCK_ACTIVE_STATE="active"
MOCK_ENABLED_STATE="enabled"
MOCK_ACTIVE_AFTER_DISABLE="inactive"
MOCK_ACTIVE_AFTER_STOP="inactive"
MOCK_ENABLED_AFTER_DISABLE="disabled"
MOCK_DISABLE_RC=0
MOCK_STOP_RC=0
MOCK_DAEMON_RELOAD_RC=0
MOCK_RESTART_RC=0

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
        enable) return 0 ;;
        restart)
            MOCK_LOAD_STATE="loaded"
            MOCK_ACTIVE_STATE="active"
            return "$MOCK_RESTART_RC"
            ;;
        is-active) [ "$MOCK_ACTIVE_STATE" = "active" ] ;;
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
    MOCK_RESTART_RC=0
    : > "$SYSTEMCTL_TRACE"
    mkdir -p "$(dirname "$SERVICE_FILE")"
    printf '%s\n' \
        "$SERVICE_OWNER_MARKER" \
        'Description=Port Traffic Dog active source IP guard (experimental)' \
        'Type=simple' \
        "ExecStart=$INSTALLED_SCRIPT --run" \
        "ExecStopPost=-$INSTALLED_SCRIPT --fail-open" \
        'Restart=always' > "$SERVICE_FILE"
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
assert_fails stop_service_strict >/dev/null 2>&1

# 已停止但仍 enabled，或变成无法明确禁用的 static，也不能继续清理。
reset_systemctl_mock
MOCK_ENABLED_AFTER_DISABLE="enabled"
assert_fails stop_service_strict >/dev/null 2>&1
reset_systemctl_mock
MOCK_ENABLED_AFTER_DISABLE="static"
assert_fails stop_service_strict >/dev/null 2>&1

# systemd 报 not-found 时，只有服务文件也确实不存在才可视为已清理。
reset_systemctl_mock
MOCK_LOAD_STATE="not-found"
assert_fails stop_service_strict >/dev/null 2>&1
rm -f "$SERVICE_FILE"
stop_service_strict

# 陌生同名单元不得被停止或被安装流程覆盖。
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/foreign-service' > "$SERVICE_FILE"
: > "$SYSTEMCTL_TRACE"
assert_fails stop_service_strict >/dev/null 2>&1
[ ! -s "$SYSTEMCTL_TRACE" ]
(
    install_script_safely() { touch "$TEST_DIR/foreign-install-touched"; }
    assert_fails install_service >/dev/null 2>&1
)
[ ! -e "$TEST_DIR/foreign-install-touched" ]

# 安装只有在服务 active 且已安装脚本自检通过后才算成功。
(
    reset_systemctl_mock
    rm -f "$SERVICE_FILE"
    MOCK_LOAD_STATE="not-found"
    install_script_safely() {
        mkdir -p "$(dirname "$INSTALLED_SCRIPT")"
        printf '%s\n' '#!/bin/bash' '[ "${1:-}" = "--self-check" ]' > "$INSTALLED_SCRIPT"
        chmod 755 "$INSTALLED_SCRIPT"
    }
    install_service
    grep -Fxq "$SERVICE_OWNER_MARKER" "$SERVICE_FILE"
)
(
    reset_systemctl_mock
    rm -f "$SERVICE_FILE"
    MOCK_LOAD_STATE="not-found"
    sleep() { :; }
    install_script_safely() {
        mkdir -p "$(dirname "$INSTALLED_SCRIPT")"
        printf '%s\n' '#!/bin/bash' 'exit 1' > "$INSTALLED_SCRIPT"
        chmod 755 "$INSTALLED_SCRIPT"
    }
    assert_fails install_service >/dev/null 2>&1
)
reset_systemctl_mock

# self-check 必须核对链、集合和每个端口规则的完整语义，不能只按对象数量通过。
SELF_CHECK_FIXTURE="$TEST_DIR/self-check.json"
jq -n '
    {nftables: [
        {chain:{name:"guard_input",type:"filter",hook:"input",prio:-20,policy:"accept"}},
        {rule:{chain:"guard_input",comment:"ptd_ip_guard_existing",expr:[
            {match:{op:"in",left:{ct:{key:"state"}},right:["established","related"]}},{accept:null}]}},
        {rule:{chain:"guard_input",comment:"ptd_ip_guard_3265_syn_queue",expr:[
            {match:{op:"==",left:{payload:{protocol:"tcp",field:"dport"}},right:3265}},
            {match:{op:"==",left:{"&":[{payload:{protocol:"tcp",field:"flags"}},["fin","syn","rst","ack"]]},right:"syn"}},
            {queue:{num:47683,flags:"bypass"}}]}}
    ]}
' > "$SELF_CHECK_FIXTURE"
(
    check_dependencies() { :; }
    init_config() { :; }
    load_policies() { POLICY_LIMIT=([3265]=2); }
    service_file_is_owned() { :; }
    mock_systemctl() { [ "${1:-}" = "is-active" ]; }
    require_owned_table() { :; }
    runtime_state_valid() { :; }
    nft() { cat "$SELF_CHECK_FIXTURE"; }
    self_check
) | grep -Fxq 'IP_GUARD_STATUS=OK PORTS=1'

BROKEN_SELF_CHECK_FIXTURE="$TEST_DIR/self-check-broken.json"
jq '(.nftables[] | select(.rule?.chain == "guard_input" and
    .rule?.comment == "ptd_ip_guard_3265_syn_queue") |
    .rule.expr[0].match.right) = 9999' "$SELF_CHECK_FIXTURE" > "$BROKEN_SELF_CHECK_FIXTURE"
(
    check_dependencies() { :; }
    init_config() { :; }
    load_policies() { POLICY_LIMIT=([3265]=2); }
    service_file_is_owned() { :; }
    mock_systemctl() { [ "${1:-}" = "is-active" ]; }
    require_owned_table() { :; }
    runtime_state_valid() { :; }
    nft() { cat "$BROKEN_SELF_CHECK_FIXTURE"; }
    assert_fails self_check >/dev/null 2>&1
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
assert_fails apply_if_configured >/dev/null 2>&1
[ ! -e "$FAIL_OPEN_CAPTURE" ]

mkdir -p "$(dirname "$CONFIG_FILE")"
: > "$CONFIG_FILE"
reset_systemctl_mock
MOCK_ACTIVE_AFTER_DISABLE="active"
MOCK_ACTIVE_AFTER_STOP="active"
assert_fails uninstall_feature true >/dev/null 2>&1
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
assert_fails update_config_and_apply 'del(.ports[$port])' token --arg port 3265 >/dev/null 2>&1
cmp -s "$CONFIG_FILE" "$TEST_DIR/config.before-transaction"
[ "$APPLY_TRANSACTION_COUNT" -eq 2 ]

# 旧 max_ips-only 配置保持 300 秒空闲保留；连接数默认不限。
(
    unset -f jq
    eval "$ORIGINAL_LOAD_POLICIES_DEFINITION"
    printf '%s\n' '{"schema":"port-traffic-dog-ip-guard-v1","ports":{"3265":{"max_ips":2}}}' > "$CONFIG_FILE"
    load_policies
    [ "${POLICY_LIMIT[3265]}" = 2 ]
    [ "${POLICY_IDLE[3265]}" = 300 ]
    [ "${POLICY_CONNECTIONS[3265]}" = 0 ]
    printf '%s\n' '{"schema":"port-traffic-dog-ip-guard-v1","ports":{"3265":{"max_ips":0,"max_connections":3,"idle_timeout":45}}}' > "$CONFIG_FILE"
    load_policies
    [ "${POLICY_LIMIT[3265]}" = 0 ]
    [ "${POLICY_CONNECTIONS[3265]}" = 3 ]
    [ "${POLICY_IDLE[3265]}" = 45 ]
    printf '%s\n' '{"schema":"port-traffic-dog-ip-guard-v1","ports":{"3265":{"max_ips":0,"max_connections":0}}}' > "$CONFIG_FILE"
    load_policies
    [ "${#POLICY_LIMIT[@]}" = 0 ]
)
python3 "$PROJECT_DIR/tests/ip-guard-engine.py"
echo "ip guard regression passed"
