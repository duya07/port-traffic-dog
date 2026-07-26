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
trap 'echo "integration failed at line $LINENO" >&2' ERR

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
c, _ = s.accept()
while c.recv(65536):
    pass
' &
server_pid=$!
sleep 0.2
python3 -c '
import socket, time
for _ in range(50):
    try:
        s = socket.create_connection(("127.0.0.1", 3265))
        break
    except ConnectionRefusedError:
        time.sleep(0.02)
else:
    raise RuntimeError("test listener did not start")
chunk = b"x" * 65536
for _ in range(3000):
    s.sendall(chunk)
    time.sleep(0.001)
s.close()
' &
client_pid=$!

sleep 0.3
reset_port_nftables_counters 3265
wait "$client_pid"
wait "$server_pid"

read -r input_bytes output_bytes < <(get_nftables_counter_data 3265)
[ "$input_bytes" -gt 0 ]
[ "$output_bytes" -gt 0 ]
nft list quota inet port_traffic_monitor port_3265_quota >/dev/null

ip link add eth0 type veth peer name peer0
ip link set eth0 up
ip link set peer0 up
get_default_interface() {
    echo eth0
}

apply_tc_limit 3265 10mbit
tc qdisc show dev eth0 | grep -q '^qdisc htb 1:'
[ -f "$(get_tc_root_owner_file)" ]
remove_tc_limit 3265
! tc qdisc show dev eth0 | grep -q '^qdisc htb 1:'
[ ! -f "$(get_tc_root_owner_file)" ]

echo "network namespace integration tests passed"
