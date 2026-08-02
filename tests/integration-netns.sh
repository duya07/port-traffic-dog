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
[ "$before_input" -gt 0 ]
[ "$before_output" -gt 0 ]
reset_port_nftables_counters 3265

read -r input_bytes output_bytes < <(get_nftables_counter_data 3265)
[ "$input_bytes" -eq 0 ]
[ "$output_bytes" -eq 0 ]
quota_used=$(nft -j list quota inet port_traffic_monitor port_3265_quota |
    jq -r '.nftables[] | select(.quota != null) | .quota.used // 0')
[ "$quota_used" -eq 0 ]

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
remove_tc_limit 3265
wait_for_tc_state qdisc "qdisc htb 1:" absent
[ ! -f "$(get_tc_root_owner_file)" ]

echo "network namespace integration tests passed"
