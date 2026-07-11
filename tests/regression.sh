#!/bin/bash

set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCRIPT_FILE="$PROJECT_DIR/port-traffic-dog.sh"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Load function definitions without running main, and redirect all state to a temp directory.
source <(sed \
    -e "s#^readonly CONFIG_DIR=.*#readonly CONFIG_DIR=\"$TEST_DIR/config\"#" \
    -e '$d' \
    "$SCRIPT_FILE")

mkdir -p "$CONFIG_DIR/logs"

write_base_config() {
    jq -n '{
        global: {billing_mode: "double"},
        ports: {},
        nftables: {table_name: "port_traffic_monitor", family: "inet"},
        notifications: {
            telegram: {enabled: true, status_notifications: {enabled: true, interval: "1m"}},
            wecom: {enabled: true, status_notifications: {enabled: true, interval: "1m"}}
        }
    }' > "$CONFIG_FILE"
}

write_base_config

mkdir "$TRAFFIC_STATS_LOCK_DIR"
printf '99999999 0\n' > "$TRAFFIC_STATS_LOCK_DIR/owner"
acquire_traffic_stats_lock
release_traffic_stats_lock

should_carry_cross_day_snapshot_delta \
    "2026-07-10" "2026-07-10T23:59:10+08:00" \
    "2026-07-11" "2026-07-11T00:00:05+08:00"
! should_carry_cross_day_snapshot_delta \
    "2026-07-10" "2026-07-10T23:50:10+08:00" \
    "2026-07-11" "2026-07-11T00:00:05+08:00"
! should_carry_cross_day_snapshot_delta \
    "2026-07-10" "2026-07-10T23:59:10+08:00" \
    "2026-07-11" "2026-07-11T00:01:05+08:00"

[ "$(add_days_to_date 2024-02-28 1)" = "2024-02-29" ]
[ "$(add_days_to_date 2024-02-29 1)" = "2024-03-01" ]
[ "$(add_months_to_date 2025-01-31 1 31)" = "2025-02-28" ]
[ "$(add_months_to_date 2024-01-31 1 31)" = "2024-02-29" ]
[ "$(calculate_monthly_next_date 31 2025-02-01)" = "2025-02-28" ]
[ "$(calculate_interval_months_next_date 2025-01-31 1 31 2025-03-01)" = "2025-03-31" ]
[ "$(calculate_yearly_next_date 2 29 2025-01-01)" = "2025-02-28" ]

update_config_file '.concurrency.first = 1' &
first_pid=$!
update_config_file '.concurrency.second = 2' &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
jq -e '.concurrency == {first: 1, second: 2}' "$CONFIG_FILE" >/dev/null

update_config_file '
    .ports = {
        "3265": {
            enabled: true,
            quota: {enabled: true, monthly_limit: "100GB", reset_day: 2}
        }
    }
'
[ "$(get_reset_policy_type 3265)" = "monthly" ]
ensure_port_next_reset_date 3265 >/dev/null
jq -e '.ports["3265"].quota.reset_day == 2 and .ports["3265"].quota.reset_policy.type == "monthly"' \
    "$CONFIG_FILE" >/dev/null

readonly CRON_FILE="$TEST_DIR/crontab"
crontab() {
    if [ "${1:-}" = "-l" ]; then
        [ -f "$CRON_FILE" ] && cat "$CRON_FILE"
        return 0
    fi
    cp "$1" "$CRON_FILE"
}
get_script_exec_path() {
    echo "/usr/local/bin/port-traffic-dog.sh"
}
ensure_cron_service_running() {
    :
}

update_config_file '.ports = {}'
setup_telegram_notification_cron
! grep -q -- '--send-telegram-status' "$CRON_FILE"
setup_traffic_snapshot_cron
! grep -q -- '--snapshot-traffic' "$CRON_FILE"

update_config_file '.ports["2000"] = {enabled: true}'
setup_telegram_notification_cron
grep -q -- '--send-telegram-status' "$CRON_FILE"
setup_traffic_snapshot_cron
grep -q -- '--snapshot-traffic' "$CRON_FILE"

update_config_file '.ports = {}'
setup_telegram_notification_cron
! grep -q -- '--send-telegram-status' "$CRON_FILE"
setup_traffic_snapshot_cron
! grep -q -- '--snapshot-traffic' "$CRON_FILE"

update_config_file '.ports = {"2000": {enabled: true}}'
jq -n '{
    "1000": {input: 10, output: 20},
    "2000": {input: 30, output: 40}
}' > "$TRAFFIC_DATA_FILE"
restored_ports=()
restore_counter_value() {
    restored_ports+=("$1")
}
restore_traffic_data_from_backup
[ "${#restored_ports[@]}" -eq 1 ]
[ "${restored_ports[0]}" = "2000" ]

jq -n '{
    last_snapshot: {"2000": {}, "3000": {}},
    state: {"2000": {}, "3000": {}},
    daily: {"2000": {}, "3000": {}}
}' > "$TRAFFIC_STATS_FILE"
jq -n '{"2000": {input: 1}, "3000": {input: 2}}' > "$TRAFFIC_DATA_FILE"
remove_port_traffic_state 2000
jq -e '(.last_snapshot["2000"] == null) and (.state["2000"] == null) and
       (.daily["2000"] == null) and (.daily["3000"] != null)' "$TRAFFIC_STATS_FILE" >/dev/null
jq -e 'has("2000") | not' "$TRAFFIC_DATA_FILE" >/dev/null
jq -e 'has("3000")' "$TRAFFIC_DATA_FILE" >/dev/null

update_config_file '
    .ports = {
        "2000": {
            enabled: true,
            billing_mode: "double",
            quota: {enabled: true, monthly_limit: "invalid"}
        }
    }
'
quota_removed=false
remove_nftables_quota() {
    quota_removed=true
}
log_notification() {
    :
}
apply_nftables_quota 2000 "invalid"
[ "$quota_removed" = "false" ]

update_config_file '
    .ports = {
        "65535": {enabled: true, bandwidth_limit: {enabled: true, rate: "1Mbps"}}
    }
'
class_id=$(generate_tc_class_id 65535)
class_minor=$(tc_class_id_minor "$class_id")
[ "$class_minor" -ge 2 ]
[ "$class_minor" -le 65535 ]
jq -e --arg class_id "$class_id" '.ports["65535"].bandwidth_limit.class_id == $class_id' \
    "$CONFIG_FILE" >/dev/null

(
    unset -f update_config_file
    source "$PROJECT_DIR/telegram.sh"
    telegram_update_config_file '.compat.telegram = true'
)
(
    unset -f update_config_file
    source "$PROJECT_DIR/wecom.sh"
    wecom_update_config_file '.compat.wecom = true'
)
jq -e '.compat == {telegram: true, wecom: true}' "$CONFIG_FILE" >/dev/null

echo "regression tests passed"
