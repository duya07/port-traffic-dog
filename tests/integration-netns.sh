#!/bin/bash

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "integration test requires root" >&2
    exit 1
fi

if [ "${PORT_TRAFFIC_DOG_NETNS_TEST:-0}" != "1" ]; then
    exec unshare -n env PORT_TRAFFIC_DOG_NETNS_TEST=1 bash "$0"
fi

readonly TEST_DIR="$(mktemp -d)"
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCRIPT_FILE="$PROJECT_DIR/port-traffic-dog.sh"

cleanup() {
    jobs -pr | xargs -r kill 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap '
    echo "integration failed at line $LINENO" >&2
    if [ -f "${CONFIG_DIR:-}/logs/notification.log" ]; then
        tail -n 10 "${CONFIG_DIR}/logs/notification.log" >&2
    fi
    if ip link show eth0 >/dev/null 2>&1; then
        tc qdisc show dev eth0 >&2 || true
        tc class show dev eth0 >&2 || true
        tc filter show dev eth0 parent 1:0 >&2 || true
    fi
' ERR

source <(sed \
    -e "s#^readonly CONFIG_DIR=.*#readonly CONFIG_DIR=\"$TEST_DIR/config\"#" \
    -e "s#^readonly TC_SHARED_LOCK_FILE=.*#readonly TC_SHARED_LOCK_FILE=\"$TEST_DIR/traffic-tools-tc.lock\"#" \
    -e "s#^readonly TRAFFICCOP_TC_STATE_FILE=.*#readonly TRAFFICCOP_TC_STATE_FILE=\"$TEST_DIR/trafficcop-tc.state\"#" \
    -e '$d' \
    "$SCRIPT_FILE")

mkdir -p "$CONFIG_DIR/logs"
jq -n '{
    global: {billing_mode: "double", data_retention_days: 30},
    ports: {
        "3265": {
            enabled: true,
            billing_mode: "double",
            quota: {enabled: true, monthly_limit: "1GB"},
            bandwidth_limit: {enabled: true, rate: "10mbit"}
        }
    },
    nftables: {table_name: "port_traffic_monitor", family: "inet"},
    notifications: {
        telegram: {enabled: false, status_notifications: {enabled: false}},
        wecom: {enabled: false, status_notifications: {enabled: false}}
    }
}' > "$CONFIG_FILE"

ip link set lo up
init_nftables
add_nftables_rules 3265
apply_nftables_quota 3265 1GB
[ "$(get_nftables_quota_limit_bytes 3265)" -eq 1073741824 ]

# Correct rule counts must not hide a quota object with the wrong runtime limit.
apply_nftables_quota 3265 2GB
[ "$(count_quota_rules 3265)" -eq 16 ]
[ "$(get_nftables_quota_limit_bytes 3265)" -eq 2147483648 ]
repair_port_quota_rules 3265
[ "$LAST_REPAIR_CHANGED" = "true" ]
[ "$(get_nftables_quota_limit_bytes 3265)" -eq 1073741824 ]

# Runtime reconciliation must remove only dog-owned objects that are absent from config.
nft add counter inet port_traffic_monitor port_33366_in
nft add counter inet port_traffic_monitor port_33366_out
nft add quota inet port_traffic_monitor port_33366_quota \
    '{ over 1073741824 bytes used 0 bytes }'
nft insert rule inet port_traffic_monitor input tcp dport 33366 counter name port_33366_in
nft insert rule inet port_traffic_monitor output tcp sport 33366 counter name port_33366_out
nft insert rule inet port_traffic_monitor input tcp dport 33366 quota name port_33366_quota drop
[ "$(list_orphaned_runtime_objects | wc -l)" -eq 3 ]
reconcile_orphaned_runtime_objects
! nft list counter inet port_traffic_monitor port_33366_in >/dev/null 2>&1
! nft list counter inet port_traffic_monitor port_33366_out >/dev/null 2>&1
! nft list quota inet port_traffic_monitor port_33366_quota >/dev/null 2>&1
nft list counter inet port_traffic_monitor port_3265_in >/dev/null
nft list quota inet port_traffic_monitor port_3265_quota >/dev/null

python3 -c '
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 3265))
s.listen(1)
for _ in range(2):
    c, _ = s.accept()
    while c.recv(65536):
        pass
    c.close()
' &
server_pid=$!
sleep 0.2
python3 -c '
import socket
s = socket.create_connection(("127.0.0.1", 3265))
chunk = b"x" * 65536
for _ in range(160):
    s.sendall(chunk)
s.close()
'

read -r before_input before_output < <(get_nftables_counter_data 3265)
payload_bytes=$((160 * 65536))
[ "$before_input" -ge $((payload_bytes * 2)) ]
[ "$before_input" -lt $((payload_bytes * 3)) ]
[ "$before_output" -gt 0 ]
reset_port_nftables_counters 3265

read -r input_bytes output_bytes < <(get_nftables_counter_data 3265)
[ "$input_bytes" -eq 0 ]
[ "$output_bytes" -eq 0 ]
quota_used=$(nft -j list quota inet port_traffic_monitor port_3265_quota |
    jq -r '.nftables[] | select(.quota != null) | .quota.used // 0')
[ "$quota_used" -eq 0 ]
! counter_direction_has_preceding_terminal_rule 3265 in
! counter_direction_has_preceding_terminal_rule 3265 out

python3 -c '
import socket
s = socket.create_connection(("127.0.0.1", 3265))
chunk = b"y" * 65536
for _ in range(160):
    s.sendall(chunk)
s.close()
'
wait "$server_pid"

read -r input_bytes output_bytes < <(get_nftables_counter_data 3265)
[ "$input_bytes" -gt 0 ]
[ "$output_bytes" -gt 0 ]
nft list quota inet port_traffic_monitor port_3265_quota >/dev/null

# A superset range verdict before dog rules must be detected and repaired.
nft insert rule inet port_traffic_monitor input tcp dport 3000-4000 accept
apply_nftables_quota 3265 1GB
counter_direction_has_preceding_terminal_rule 3265 in
! counter_direction_has_preceding_terminal_rule 3265 out

python3 -c '
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 3265))
s.listen(1)
c, _ = s.accept()
while c.recv(65536):
    pass
c.close()
s.close()
' &
order_server_pid=$!
sleep 0.2
python3 -c '
import socket
s = socket.create_connection(("127.0.0.1", 3265))
chunk = b"z" * 65536
for _ in range(32):
    s.sendall(chunk)
s.close()
'
wait "$order_server_pid"

read -r order_input_before order_output_before < <(get_nftables_counter_data 3265)
order_quota_before=$(get_nftables_quota_used 3265)
[ "$order_quota_before" -gt $((order_input_before + order_output_before)) ]
repair_port_traffic_rules 3265
read -r order_input_after order_output_after < <(get_nftables_counter_data 3265)
order_quota_after=$(get_nftables_quota_used 3265)
[ "$order_input_after" -gt "$order_input_before" ]
[ $((order_input_after + order_output_after)) -eq "$order_quota_after" ]
! counter_direction_has_preceding_terminal_rule 3265 in
! counter_direction_has_preceding_terminal_rule 3265 out
port_counter_quota_usage_consistent 3265

# If only one direction loses a counter rule, recover the quota/counter gap before rebuilding.
missing_rule_handle=$(nft -j -a list chain inet port_traffic_monitor input |
    jq -r --arg counter "port_3265_in" '
        def counter_name:
            .counter? |
            if type == "string" then .
            elif type == "object" then (.name // empty)
            else empty end;
        [
            .nftables[] | .rule? |
            select(any(.expr[]?; counter_name == $counter)) |
            select(any(.expr[]?;
                .match?.left.payload.protocol? == "tcp" and
                .match?.left.payload.field? == "dport")) |
            .handle
        ][0] // empty
    ')
[ -n "$missing_rule_handle" ]
nft delete rule inet port_traffic_monitor input handle "$missing_rule_handle"
[ "$(count_counter_rules 3265 in)" -eq 7 ]

python3 -c '
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 3265))
s.listen(1)
c, _ = s.accept()
while c.recv(65536):
    pass
c.close()
s.close()
' &
missing_rule_server_pid=$!
sleep 0.2
python3 -c '
import socket
s = socket.create_connection(("127.0.0.1", 3265))
chunk = b"m" * 65536
for _ in range(32):
    s.sendall(chunk)
s.close()
'
wait "$missing_rule_server_pid"

read -r missing_input_before missing_output_before < <(get_nftables_counter_data 3265)
missing_quota_before=$(get_nftables_quota_used 3265)
[ "$missing_quota_before" -gt $((missing_input_before + missing_output_before + 1024 * 1024)) ]
repair_port_traffic_rules 3265
read -r missing_input_after missing_output_after < <(get_nftables_counter_data 3265)
missing_quota_after=$(get_nftables_quota_used 3265)
[ "$missing_input_after" -gt "$missing_input_before" ]
[ $((missing_input_after + missing_output_after)) -eq "$missing_quota_after" ]
[ "$(count_counter_rules 3265 in)" -eq 8 ]

# Failed nft transactions must leave the previously working state intact.
atomic_input_before="$missing_input_after"
atomic_output_before="$missing_output_after"
atomic_quota_before=$(nft -j -a list quota inet port_traffic_monitor port_3265_quota)
atomic_in_rules_before=$(count_counter_rules 3265 in)
atomic_out_rules_before=$(count_counter_rules 3265 out)
atomic_quota_rules_before=$(count_quota_rules 3265)
(
    nft() {
        if [ "${1:-}" = "-f" ]; then
            return 1
        fi
        command nft "$@"
    }
    ! repair_port_traffic_rules 3265 true
    ! apply_nftables_quota 3265 2GB
    ! add_nftables_rules 3265
)
read -r atomic_input_after atomic_output_after < <(get_nftables_counter_data 3265)
[ "$atomic_input_after" -eq "$atomic_input_before" ]
[ "$atomic_output_after" -eq "$atomic_output_before" ]
[ "$(count_counter_rules 3265 in)" -eq "$atomic_in_rules_before" ]
[ "$(count_counter_rules 3265 out)" -eq "$atomic_out_rules_before" ]
[ "$(count_quota_rules 3265)" -eq "$atomic_quota_rules_before" ]
[ "$(nft -j -a list quota inet port_traffic_monitor port_3265_quota)" = "$atomic_quota_before" ]

# 当前计费模型下即使规则只剩一组，运行时修复也必须保留已有 counter，不能再次乘 2。
update_config_file '.ports["3265"].billing_mode = "single"'
add_nftables_rules 3265
[ "$(count_counter_rules 3265 in)" -eq 4 ]
update_config_file \
    '.ports["3265"].billing_mode = "double" | .global.traffic_accounting_model = $model' \
    --arg model "$TRAFFIC_ACCOUNTING_MODEL"
read -r repair_input_before repair_output_before < <(get_nftables_counter_data 3265)
repair_port_traffic_rules 3265
read -r repair_input_after repair_output_after < <(get_nftables_counter_data 3265)
[ "$repair_input_after" -eq "$repair_input_before" ]
[ "$repair_output_after" -eq "$repair_output_before" ]
[ "$(count_counter_rules 3265 in)" -eq 8 ]
[ "$(count_counter_rules 3265 out)" -eq 8 ]

ip link add eth0 type veth peer name peer0
ip link set eth0 up
ip link set peer0 up
get_default_interface() {
    echo eth0
}

write_ntc_unified_state() {
    local speed="$1"
    {
        printf 'SCHEMA=%s\n' "$TC_INTEROP_SCHEMA"
        printf 'PROVIDER=trafficcop-lite\n'
        printf 'INTERFACE=eth0\n'
        printf 'LIMIT_SPEED=%s\n' "$speed"
    } > "$TRAFFICCOP_TC_STATE_FILE"
    chmod 600 "$TRAFFICCOP_TC_STATE_FILE"
}

wait_for_tc_state() {
    local object_type="$1"
    local pattern="$2"
    local expected_state="$3"
    local attempt
    local output
    for attempt in {1..100}; do
        output=$(tc "$object_type" show dev eth0 2>/dev/null || true)
        if [[ "$output" == *"$pattern"* ]]; then
            [ "$expected_state" = "present" ] && return 0
        elif [ "$expected_state" = "absent" ]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

apply_tc_limit 3265 10mbit
class_id=$(jq -r '.ports["3265"].bandwidth_limit.class_id' "$CONFIG_FILE")
[ "$(tc filter show dev eth0 protocol ipv6 parent 1:0 | grep -Fc "classid $class_id")" -eq 4 ]
[ -f "$(get_tc_root_owner_file)" ]
tc_class_rate_matches eth0 1:30 "$TC_DEFAULT_CLASS_RATE" "$TC_PARENT_RATE"
tc_class_rate_matches eth0 "$class_id" "$TC_PORT_CLASS_RATE" 10mbit
tc_limit_runtime_complete 3265

# TrafficCop 状态是父类权威来源；Dog 只读状态并原地协调，不调用另一个项目。
write_ntc_unified_state 5000
ensure_owned_tc_hierarchy eth0
tc_limit_runtime_complete 3265
tc_class_rate_matches eth0 1:1 5mbit
tc_class_rate_matches eth0 1:30 "$TC_DEFAULT_CLASS_RATE" 5mbit
tc_class_rate_matches eth0 "$class_id" "$TC_PORT_CLASS_RATE" 10mbit
rm -f "$TRAFFICCOP_TC_STATE_FILE"
ensure_owned_tc_hierarchy eth0
tc_limit_runtime_complete 3265
tc_class_rate_matches eth0 1:1 "$TC_PARENT_RATE"

# Missing IPv4 UDP filters and rate drift must both fail runtime validation.
filter_prio=$((3265 % 1000 + 1))
tc filter del dev eth0 protocol ip parent 1:0 prio "$((filter_prio + 1000))" u32
! tc_limit_runtime_complete 3265
remove_tc_limit 3265
apply_tc_limit 3265 10mbit
tc_limit_runtime_complete 3265
tc class replace dev eth0 parent 1:1 classid "$class_id" htb rate 20mbit ceil 20mbit
! tc_limit_runtime_complete 3265
remove_tc_limit 3265
wait_for_tc_state qdisc "qdisc htb 1:" absent
[ ! -f "$(get_tc_root_owner_file)" ]

# 外部程序在 Dog 之后删树重建同名 HTB 时，残留 owner 文件不得被当作归属证据。
apply_tc_limit 3265 10mbit
tc qdisc del dev eth0 root handle 1:
tc qdisc add dev eth0 root handle 1: htb default 10
tc class add dev eth0 parent 1: classid 1:10 htb rate 87mbit ceil 87mbit
! apply_tc_limit 3265 10mbit
[ ! -f "$(get_tc_root_owner_file)" ]
! tc class show dev eth0 | grep -Eq '^class htb 1:1([[:space:]]|$)'
tc qdisc del dev eth0 root handle 1:

# An unrelated HTB hierarchy must remain untouched.
tc qdisc add dev eth0 root handle 1: htb default 30
tc class add dev eth0 parent 1: classid 1:1 htb rate 1mbit
foreign_before="$(tc qdisc show dev eth0; tc class show dev eth0)"
! apply_tc_limit 3265 10mbit
write_ntc_unified_state 5000
! apply_tc_limit 3265 10mbit
[ "$foreign_before" = "$(tc qdisc show dev eth0; tc class show dev eth0)" ]
rm -f "$TRAFFICCOP_TC_STATE_FILE"
tc class show dev eth0 | grep -Eq '^class htb 1:1 .*rate 1Mbit([[:space:]]|$)'
tc qdisc del dev eth0 root handle 1:

# 严格匹配 TrafficCop 状态的旧 TBF 可迁移；Dog 不改写 NTC 状态文件。
tc qdisc add dev eth0 root tbf rate 5mbit burst 32kbit latency 400ms
legacy_tbf_line="$(tc qdisc show dev eth0 root | head -n 1)"
{
    printf 'INTERFACE=eth0\n'
    printf 'LIMIT_SPEED=5000\n'
    printf 'QDISC_LINE=%s\n' "$legacy_tbf_line"
    printf 'PROVIDER=trafficcop-lite\n'
} > "$TRAFFICCOP_TC_STATE_FILE"
chmod 600 "$TRAFFICCOP_TC_STATE_FILE"
apply_tc_limit 3265 10mbit
tc_root_matches_unified_contract eth0
tc_class_rate_matches eth0 1:1 5mbit
tc_limit_runtime_complete 3265
! grep -q '^SCHEMA=' "$TRAFFICCOP_TC_STATE_FILE"
rm -f "$TRAFFICCOP_TC_STATE_FILE"
remove_tc_limit 3265
wait_for_tc_state qdisc "qdisc htb 1:" absent

# 1:30 永远保留给默认叶；旧端口冲突 ID 必须先迁移到新 ID。
update_config_file '.ports["3265"].bandwidth_limit.class_id = "1:30"'
apply_tc_limit 3265 10mbit
class_id=$(jq -r '.ports["3265"].bandwidth_limit.class_id' "$CONFIG_FILE")
[ "$class_id" != "1:30" ]
tc_class_rate_matches eth0 1:30 "$TC_DEFAULT_CLASS_RATE" "$TC_PARENT_RATE"
tc_limit_runtime_complete 3265
remove_tc_limit 3265

# Port-range marks reserve only high bits and keep the low 12 skb-mark bits.
update_config_file '
    .ports["4000-4010"] = {
        enabled: true,
        billing_mode: "single",
        quota: {enabled: false, monthly_limit: "unlimited"},
        bandwidth_limit: {enabled: true, rate: "5Mbps"}
    }
'
apply_tc_limit 4000-4010 5mbit
tc_limit_runtime_complete 4000-4010
range_mark_id=$(jq -r '.ports["4000-4010"].bandwidth_limit.mark_id' "$CONFIG_FILE")
port_range_mark_rules_complete 4000-4010 "$range_mark_id"
remove_tc_limit 4000-4010
update_config_file 'del(.ports["4000-4010"])'

echo "network namespace integration tests passed"
