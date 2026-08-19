#!/bin/bash

set -euo pipefail

readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly LEGACY_COMMIT="c8c91c527fc4beb11e48e9c6fde4627f75fc2dd2"
legacy_script="${LEGACY_SCRIPT:-}"

if [ "$(id -u)" -ne 0 ]; then
    echo "upgrade compatibility test requires root" >&2
    exit 1
fi

if [ -n "$legacy_script" ] && [ ! -f "$legacy_script" ]; then
    echo "LEGACY_SCRIPT does not exist: $legacy_script" >&2
    exit 1
fi
if [ -z "$legacy_script" ] &&
   ! git -c safe.directory="$PROJECT_DIR" -C "$PROJECT_DIR" \
        cat-file -e "$LEGACY_COMMIT:port-traffic-dog.sh" 2>/dev/null; then
    echo "v1.5.2 fixture is unavailable; provide LEGACY_SCRIPT or fetch commit $LEGACY_COMMIT" >&2
    exit 1
fi

if [ "${PORT_TRAFFIC_DOG_UPGRADE_TEST:-0}" != "1" ]; then
    exec unshare -n env \
        PORT_TRAFFIC_DOG_UPGRADE_TEST=1 \
        LEGACY_SCRIPT="$legacy_script" \
        bash "$0"
fi

readonly TEST_DIR="$(mktemp -d)"
readonly CURRENT_SCRIPT="$PROJECT_DIR/port-traffic-dog.sh"
readonly TEST_CONFIG_DIR="$TEST_DIR/config"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap 'echo "v1.5.2 upgrade test failed at line $LINENO" >&2' ERR

if [ -z "$legacy_script" ]; then
    legacy_script="$TEST_DIR/port-traffic-dog-v1.5.2.sh"
    git -c safe.directory="$PROJECT_DIR" -C "$PROJECT_DIR" \
        show "$LEGACY_COMMIT:port-traffic-dog.sh" > "$legacy_script"
fi
readonly LEGACY_SCRIPT="$legacy_script"

run_legacy_phase() (
    source <(sed \
        -e "s#^readonly CONFIG_DIR=.*#readonly CONFIG_DIR=\"$TEST_CONFIG_DIR\"#" \
        -e '$d' \
        "$LEGACY_SCRIPT")

    mkdir -p "$CONFIG_DIR/logs"
    jq -n --arg model "$TRAFFIC_ACCOUNTING_MODEL" '{
        global: {billing_mode: "double", traffic_accounting_model: $model},
        ports: {
            "3265": {
                enabled: true,
                billing_mode: "double",
                quota: {enabled: true, monthly_limit: "1GB"},
                bandwidth_limit: {enabled: true, rate: "10Mbps"}
            }
        },
        nftables: {table_name: "ptd_upgrade_152", family: "inet"},
        notifications: {
            telegram: {enabled: false, status_notifications: {enabled: false}},
            wecom: {enabled: false, status_notifications: {enabled: false}}
        }
    }' > "$CONFIG_FILE"

    ip link add ptd152 type veth peer name ptd152peer
    ip link set ptd152 up
    ip link set ptd152peer up
    get_default_interface() { echo ptd152; }

    init_nftables
    restore_counter_value 3265 123456 654321
    add_nftables_rules 3265
    apply_nftables_quota 3265 1GB
    if ! apply_tc_limit 3265 "$(convert_bandwidth_to_tc 10Mbps)"; then
        local legacy_class_id
        local legacy_class_state
        local legacy_filter_state
        legacy_class_id=$(jq -r '.ports["3265"].bandwidth_limit.class_id // empty' "$CONFIG_FILE")
        legacy_class_state=$(tc class show dev ptd152 2>/dev/null || true)
        legacy_filter_state=$(tc filter show dev ptd152 parent 1:0 2>/dev/null || true)
        [ -n "$legacy_class_id" ]
        grep -Fq "class htb $legacy_class_id " <<< "$legacy_class_state"
        [ "$(grep -Fc "flowid $legacy_class_id" <<< "$legacy_filter_state")" -ge 4 ]
    fi
    save_traffic_data

    [ "$(count_counter_rules 3265 in)" -eq 8 ]
    [ "$(count_counter_rules 3265 out)" -eq 8 ]
    [ "$(count_quota_rules 3265)" -eq 16 ]
)

run_current_phase() (
    source <(sed \
        -e "s#^readonly CONFIG_DIR=.*#readonly CONFIG_DIR=\"$TEST_CONFIG_DIR\"#" \
        -e '$d' \
        "$CURRENT_SCRIPT")

    get_default_interface() { echo ptd152; }
    init_config

    local current_data=()
    read -r -a current_data < <(get_nftables_counter_data 3265)
    [ "${current_data[0]}" -eq 123456 ]
    [ "${current_data[1]}" -eq 654321 ]
    [ "$(count_counter_rules 3265 in)" -eq 8 ]
    [ "$(count_counter_rules 3265 out)" -eq 8 ]
    [ "$(count_quota_rules 3265)" -eq 16 ]
    tc_limit_runtime_complete 3265
    [ -f "$(get_tc_root_owner_file)" ]
    [ "$(jq -r '.global.tc_runtime_model // empty' "$CONFIG_FILE")" = "$TC_RUNTIME_MODEL" ]

    save_traffic_data
    jq -e '
        ."3265" == {input:123456, output:654321, backup_time:."3265".backup_time} and
        ._meta.traffic_accounting_model == "upstream-weighted-v2" and
        ._meta.port_multipliers["3265"] == {input:2, output:2}
    ' "$TRAFFIC_DATA_FILE" >/dev/null
)

run_legacy_phase
run_current_phase

echo "v1.5.2 direct upgrade compatibility test passed"
