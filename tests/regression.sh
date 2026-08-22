#!/bin/bash

set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCRIPT_FILE="$PROJECT_DIR/port-traffic-dog.sh"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap 'echo "regression failed at line $LINENO" >&2' ERR

# Load function definitions without running main, and redirect all state to a temp directory.
source <(sed \
    -e "s#^readonly CONFIG_DIR=.*#readonly CONFIG_DIR=\"$TEST_DIR/config\"#" \
    -e "s#^readonly CRON_LOCK_DIR=.*#readonly CRON_LOCK_DIR=\"$TEST_DIR/cron.lock\"#" \
    -e "s#^readonly TC_SHARED_LOCK_FILE=.*#readonly TC_SHARED_LOCK_FILE=\"$TEST_DIR/traffic-tools-tc.lock\"#" \
    -e "s#^readonly TRAFFICCOP_TC_STATE_FILE=.*#readonly TRAFFICCOP_TC_STATE_FILE=\"$TEST_DIR/trafficcop-tc.state\"#" \
    -e '$d' \
    "$SCRIPT_FILE")

mkdir -p "$CONFIG_DIR/logs"
flock() { :; }

write_base_config() {
    jq -n '{
        global: {
            billing_mode: "double",
            traffic_accounting_model: "upstream-weighted-v2",
            tc_runtime_model: "unified-htb-v3"
        },
        ports: {},
        nftables: {table_name: "port_traffic_monitor", family: "inet"},
        notifications: {
            telegram: {enabled: true, status_notifications: {enabled: true, interval: "1m"}},
            wecom: {enabled: true, status_notifications: {enabled: true, interval: "1m"}}
        }
    }' > "$CONFIG_FILE"
}

write_base_config
validate_config_file "$CONFIG_FILE"
cp "$CONFIG_FILE" "$TEST_DIR/config.valid.json"

# 新安装必须默认走 Telegram 官方线路，且不预填自定义 API 地址。
rm -f "$CONFIG_FILE"
(
    init_nftables() { :; }
    setup_exit_hooks() { :; }
    restore_monitoring_if_needed() { :; }
    ensure_traffic_accounting_model() { :; }
    ensure_tc_runtime_model() { :; }
    init_config
    jq -e '
        .notifications.telegram.api_route == "official" and
        .notifications.telegram.custom_api_base == ""
    ' "$CONFIG_FILE" >/dev/null
)
write_base_config

jq '.ports = {"3265": {}, "3000-4000": {}}' "$CONFIG_FILE" > "$TEST_DIR/config.overlap.json"
! validate_config_file "$TEST_DIR/config.overlap.json" >/dev/null 2>&1
jq '.ports = {"70000": {}}' "$CONFIG_FILE" > "$TEST_DIR/config.bad-port.json"
! validate_config_file "$TEST_DIR/config.bad-port.json" >/dev/null 2>&1

mkdir "$TRAFFIC_STATS_LOCK_DIR"
printf '99999999 0\n' > "$TRAFFIC_STATS_LOCK_DIR/owner"
acquire_traffic_stats_lock
release_traffic_stats_lock

readonly REUSED_PID_LOCK_DIR="$CONFIG_DIR/reused-pid.lock"
mkdir "$REUSED_PID_LOCK_DIR"
printf '%s 0\n' "${BASHPID:-$$}" > "$REUSED_PID_LOCK_DIR/owner"
acquire_directory_lock "$REUSED_PID_LOCK_DIR"
[ "$(wc -w < "$REUSED_PID_LOCK_DIR/owner")" -eq 4 ]
release_directory_lock "$REUSED_PID_LOCK_DIR"

readonly LIVE_LOCK_DIR="$CONFIG_DIR/live.lock"
mkdir "$LIVE_LOCK_DIR"
printf '%s 0\n' "${BASHPID:-$$}" > "$LIVE_LOCK_DIR/owner"
(release_directory_lock "$LIVE_LOCK_DIR")
[ -d "$LIVE_LOCK_DIR" ]
release_directory_lock "$LIVE_LOCK_DIR"
[ ! -d "$LIVE_LOCK_DIR" ]

(
    save_traffic_data_locked() { [ -d "$TRAFFIC_STATS_LOCK_DIR" ]; }
    save_traffic_data
)
[ ! -d "$TRAFFIC_STATS_LOCK_DIR" ]

acquire_traffic_stats_lock
original_save_traffic_data_locked=$(declare -f save_traffic_data_locked)
save_traffic_data_locked() { [ -d "$TRAFFIC_STATS_LOCK_DIR" ]; }
save_traffic_data
eval "$original_save_traffic_data_locked"
[ -d "$TRAFFIC_STATS_LOCK_DIR" ]
release_traffic_stats_lock
[ ! -d "$TRAFFIC_STATS_LOCK_DIR" ]

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
[ "$(add_days_to_date 2024-03-01 -1)" = "2024-02-29" ]
[ "$(calculate_interval_days_next_date 2000-01-01 1 2026-07-26)" = "2026-07-26" ]
[ "$(calculate_interval_days_next_date 2026-07-01 10 2026-07-26)" = "2026-07-31" ]
! is_valid_date "0000-01-01"
[ "$(add_months_to_date 2025-01-31 1 31)" = "2025-02-28" ]
[ "$(add_months_to_date 2024-01-31 1 31)" = "2024-02-29" ]
[ "$(calculate_monthly_next_date 31 2025-02-01)" = "2025-02-28" ]
[ "$(calculate_interval_months_next_date 2025-01-31 1 31 2025-03-01)" = "2025-03-31" ]
[ "$(calculate_yearly_next_date 2 29 2025-01-01)" = "2025-02-28" ]
[ "$(get_port_spec_bounds 3265)" = "3265 3265" ]
[ "$(get_port_spec_bounds 3000-4000)" = "3000 4000" ]
port_specs_overlap 3265 3000-4000
port_specs_overlap 3000-4000 3500-4500
! port_specs_overlap 3265 4000-5000
[ "$(get_expected_counter_rule_count double)" -eq 8 ]
[ "$(get_expected_counter_rule_count single)" -eq 4 ]
[ "$(get_expected_quota_rule_count double)" -eq 16 ]
[ "$(get_expected_quota_rule_count single)" -eq 8 ]
[ "$(scale_counter_for_rule_multiplier 100 1 2)" -eq 200 ]
[ "$(scale_counter_for_rule_multiplier 200 2 1)" -eq 100 ]
[ "$(get_counter_rule_multiplier_from_count 7 2)" -eq 2 ]
[ "$(calculate_total_traffic 100 200 double)" -eq 300 ]
[ "$(calculate_total_traffic 100 200 single)" -eq 300 ]
printf '%s\n' '#!/bin/bash' 'readonly SCRIPT_VERSION="1.5.11"' > "$TEST_DIR/version-script.sh"
[ "$(get_script_version_from_file "$TEST_DIR/version-script.sh")" = "1.5.11" ]
script_version_is_older 1.5.10 1.5.11
script_version_is_older 1.4 1.5.0
! script_version_is_older 1.5.11 1.5.11
! script_version_is_older 1.6.0 1.5.11
version_status=0
script_version_is_older 1.5.x 1.5.11 || version_status=$?
[ "$version_status" -eq 2 ]

readonly FINALIZE_UPDATE_TRACE="$TEST_DIR/finalize-update.trace"
(
    check_dependencies() { printf 'dependencies\n' >> "$FINALIZE_UPDATE_TRACE"; }
    init_config() { printf 'init\n' >> "$FINALIZE_UPDATE_TRACE"; }
    refresh_all_cron_from_config() { printf 'cron\n' >> "$FINALIZE_UPDATE_TRACE"; }
    restore_runtime_state() { printf 'runtime\n' >> "$FINALIZE_UPDATE_TRACE"; }
    finalize_script_update >/dev/null
)
[ "$(paste -sd, "$FINALIZE_UPDATE_TRACE")" = "dependencies,init,cron,runtime" ]
(
    check_dependencies() { :; }
    init_config() { :; }
    refresh_all_cron_from_config() { return 1; }
    restore_runtime_state() { touch "$TEST_DIR/finalize-restore-should-not-run"; }
    ! finalize_script_update >/dev/null
)
[ ! -e "$TEST_DIR/finalize-restore-should-not-run" ]
[ "$(declare -f install_update_script | grep -c 'download_with_sources')" -eq 1 ]
declare -f install_update_script | grep -q -- '--finalize-update'

# 配置提交失败时，运行时状态必须回滚，删除流程也不能触碰原端口。
cp "$CONFIG_FILE" "$TEST_DIR/config.before-transaction-tests.json"
update_config_file '
    .ports = {
        "3265": {
            enabled: true,
            billing_mode: "double",
            quota: {enabled: true, monthly_limit: "1GB"},
            bandwidth_limit: {enabled: true, rate: "10Mbps"}
        }
    }
'
readonly TC_ROLLBACK_CAPTURE="$TEST_DIR/tc-rollback.capture"
(
    show_port_list() { return 0; }
    replace_tc_limit() { printf 'replace:%s\n' "$2" >> "$TC_ROLLBACK_CAPTURE"; }
    update_config_file() { return 1; }
    manage_traffic_limits() { :; }
    sleep() { :; }
    set_port_bandwidth_limit <<< $'1\n20Mbps'
)
[ "$(paste -sd, "$TC_ROLLBACK_CAPTURE")" = "replace:20mbit,replace:10mbit" ]
jq -e '.ports["3265"].bandwidth_limit == {enabled:true, rate:"10Mbps"}' "$CONFIG_FILE" >/dev/null

readonly QUOTA_ROLLBACK_CAPTURE="$TEST_DIR/quota-rollback.capture"
(
    show_port_list() { return 0; }
    apply_nftables_quota() { printf 'apply:%s\n' "$2" >> "$QUOTA_ROLLBACK_CAPTURE"; }
    update_config_file() { return 1; }
    manage_traffic_limits() { :; }
    sleep() { :; }
    set_port_quota_limit <<< $'1\n2GB\nn'
)
[ "$(paste -sd, "$QUOTA_ROLLBACK_CAPTURE")" = "apply:2GB,apply:1GB" ]
jq -e '.ports["3265"].quota == {enabled:true, monthly_limit:"1GB"}' "$CONFIG_FILE" >/dev/null

readonly DELETE_FAILURE_CAPTURE="$TEST_DIR/delete-failure.capture"
(
    show_port_list() { return 0; }
    save_traffic_data() { return 0; }
    update_config_file() { return 1; }
    remove_nftables_rules() { touch "$DELETE_FAILURE_CAPTURE"; }
    remove_nftables_quota() { touch "$DELETE_FAILURE_CAPTURE"; }
    remove_tc_limit() { touch "$DELETE_FAILURE_CAPTURE"; }
    clear_port_conntrack_state() { touch "$DELETE_FAILURE_CAPTURE"; }
    reconcile_orphaned_runtime_objects() { touch "$DELETE_FAILURE_CAPTURE"; }
    refresh_notification_cron_from_config() { :; }
    setup_traffic_snapshot_cron() { :; }
    manage_port_monitoring() { :; }
    sleep() { :; }
    remove_port_monitoring <<< $'1\ny'
)
[ ! -e "$DELETE_FAILURE_CAPTURE" ]
jq -e '.ports["3265"] != null' "$CONFIG_FILE" >/dev/null
cp "$TEST_DIR/config.before-transaction-tests.json" "$CONFIG_FILE"

printf '%s\n' 'not-json' > "$TRAFFIC_STATS_FILE"
! ensure_traffic_stats_file
[ ! -f "$TRAFFIC_STATS_FILE" ]
compgen -G "${TRAFFIC_STATS_FILE}.corrupt.*" >/dev/null
ensure_traffic_stats_file
jq -e '.last_snapshot == {} and .daily == {}' "$TRAFFIC_STATS_FILE" >/dev/null
rm -f "$TRAFFIC_STATS_FILE" "${TRAFFIC_STATS_FILE}.corrupt."*

today=$(get_current_date)
jq -n --arg port "3265" --arg date "$today" '
    {last_snapshot: {}, state: {}, daily: {($port): {($date): {input: 100, output: 200}}}}
' > "$TRAFFIC_STATS_FILE"
scale_current_day_traffic_stats 3265 1 2 1 2
jq -e --arg port "3265" --arg date "$today" \
    '.daily[$port][$date].input == 200 and .daily[$port][$date].output == 400' \
    "$TRAFFIC_STATS_FILE" >/dev/null
rm -f "$TRAFFIC_STATS_FILE"

cp "$CONFIG_FILE" "$TEST_DIR/config.before-snapshot.json"
update_config_file '
    .global.data_retention_days = 30 |
    .ports = {"3265": {enabled:true,billing_mode:"single",quota:{enabled:false,monthly_limit:"unlimited"}}}
'
jq -n '{last_snapshot:{},state:{},daily:{"3265":{"2025-01-01":{input:1,output:1}}}}' > "$TRAFFIC_STATS_FILE"
(
    current_input=100
    current_output=200
    port_counter_objects_exist() { return 0; }
    get_nftables_counter_data() { echo "$current_input $current_output"; }
    get_current_date() { echo "2026-07-11"; }
    get_beijing_time() { echo "2026-07-11T12:00:00+08:00"; }
    record_traffic_snapshot
    current_input=150
    current_output=260
    record_traffic_snapshot
    record_traffic_snapshot
)
jq -e '
    .daily["3265"]["2026-07-11"].input == 50 and
    .daily["3265"]["2026-07-11"].output == 60 and
    .daily["3265"]["2025-01-01"] == null
' "$TRAFFIC_STATS_FILE" >/dev/null
jq -e '
    ."3265".input == 150 and
    ."3265".output == 260 and
    ._meta.traffic_accounting_model == "upstream-weighted-v2" and
    ._meta.port_multipliers["3265"] == {input:1, output:1}
' "$TRAFFIC_DATA_FILE" >/dev/null
(
    get_nftables_counter_data() { echo "7 11"; }
    get_current_date() { echo "2026-07-11"; }
    get_beijing_time() { echo "2026-07-11T12:01:00+08:00"; }
    update_traffic_snapshot_baseline 3265
)
jq -e '
    ."3265".input == 7 and
    ."3265".output == 11 and
    ._meta.port_multipliers["3265"] == {input:1, output:1}
' "$TRAFFIC_DATA_FILE" >/dev/null

jq -n '{
    last_snapshot: {"3265": {input:100,output:200,date:"2026-07-10",time:"2026-07-10T23:58:00+08:00"}},
    state: {"3265": {date:"2026-07-10",time:"2026-07-10T23:58:00+08:00",input_base:50,output_base:100,input_offset:50,output_offset:100,last_input:100,last_output:200}},
    daily: {"3265": {"2026-07-10": {input:50,output:100}}}
}' > "$TRAFFIC_STATS_FILE"
(
    port_counter_objects_exist() { return 0; }
    get_nftables_counter_data() { echo "130 250"; }
    get_current_date() { echo "2026-07-11"; }
    get_beijing_time() { echo "2026-07-11T00:01:00+08:00"; }
    record_traffic_snapshot
)
jq -e '
    .daily["3265"]["2026-07-10"] == {input:50,output:100} and
    .daily["3265"]["2026-07-11"].input == 30 and
    .daily["3265"]["2026-07-11"].output == 50
' "$TRAFFIC_STATS_FILE" >/dev/null
cp "$TEST_DIR/config.before-snapshot.json" "$CONFIG_FILE"
rm -f "$TRAFFIC_STATS_FILE" "$TRAFFIC_DATA_FILE"

update_config_file '.concurrency.first = 1' &
first_pid=$!
update_config_file '.concurrency.second = 2' &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
jq -e '.concurrency == {first: 1, second: 2}' "$CONFIG_FILE" >/dev/null

update_config_file '
    .global = {
        billing_mode: "single",
        data_retention_days: 30,
        collection_interval: 60,
        interface: "auto"
    } |
    .ports = {
        "3265": {
            enabled: true,
            quota: {enabled: true, monthly_limit: "100GB", reset_day: 2}
        },
        "8123": {
            enabled: true,
            billing_mode: "double",
            quota: {enabled: true, monthly_limit: "250GB", reset_day: 1}
        }
    } |
    .notifications.telegram.status_notifications.last_sent = null
'
[ "$(get_reset_policy_type 3265)" = "monthly" ]
ensure_port_next_reset_date 3265 >/dev/null
ensure_port_next_reset_date 8123 >/dev/null
(
    get_nftables_counter_data() { echo "100000000 200000000"; }
    get_nftables_quota_used() { echo 300000000; }
    port_counter_quota_usage_consistent 3265
    get_nftables_quota_used() { echo 10000000; }
    ! port_counter_quota_usage_consistent 3265
)
jq -e '
    .ports["3265"].quota.reset_day == 2 and
    .ports["3265"].quota.reset_policy.type == "monthly" and
    .ports["8123"].quota.reset_day == 1 and
    .ports["8123"].quota.reset_policy.type == "monthly" and
    .global.data_retention_days == 30 and
    .global.collection_interval == 60 and
    .global.interface == "auto" and
    .notifications.telegram.status_notifications.last_sent == null
' \
    "$CONFIG_FILE" >/dev/null

update_config_file '.ports["9999"] = {
    enabled: true,
    billing_mode: "single",
    quota: {
        enabled: true,
        monthly_limit: "10GB",
        reset_day: 31,
        reset_policy: {type: "monthly", day: 31}
    }
}'
(
    get_beijing_month_year() { echo "28 2 2025"; }
    [ "$(get_port_cycle_start_date 9999)" = "2025-02-28" ]
    [ "$(get_port_cycle_range 9999)" = "2025/2/28-2025/3/30" ]
)
update_config_file 'del(.ports["9999"])'

update_config_file '.ports["3265"].quota.reset_policy = {
    type: "monthly",
    day: 2,
    next_reset_date: "2026-07-12"
}'
(
    get_current_date() { echo "2026-07-12"; }
    perform_auto_reset_port() { return 1; }
    ! check_reset_port_due 3265
)
jq -e '.ports["3265"].quota.reset_policy.next_reset_date == "2026-07-12"' "$CONFIG_FILE" >/dev/null
(
    get_current_date() { echo "2026-07-12"; }
    perform_auto_reset_port() { return 0; }
    check_reset_port_due 3265
)
jq -e '
    .ports["3265"].quota.reset_policy.last_reset_date == "2026-07-12" and
    .ports["3265"].quota.reset_policy.next_reset_date == "2026-08-02"
' "$CONFIG_FILE" >/dev/null

update_config_file '.ports["3265"].quota.reset_policy.next_reset_date = "2026-08-02"'
record_reset_history 3265 123 "2026-08-02"
(
    get_current_date() { echo "2026-08-02"; }
    perform_auto_reset_port() { echo called > "$TEST_DIR/repeated-reset"; return 0; }
    check_reset_port_due 3265
)
[ ! -f "$TEST_DIR/repeated-reset" ]
jq -e '.ports["3265"].quota.reset_policy.last_reset_date == "2026-08-02"' "$CONFIG_FILE" >/dev/null

(
    test_input=100
    test_output=200
    test_quota=300
    quota_exists=true
    baseline_updated=false
    nft() {
        local action="${1:-}"
        local object_type="${2:-}"
        local object_name="${5:-}"
        if [ "$action" = "list" ] && [ "$object_type" = "counter" ]; then
            if [[ "$object_name" == *_in ]]; then
                echo "counter $object_name { packets 1 bytes $test_input }"
            else
                echo "counter $object_name { packets 1 bytes $test_output }"
            fi
        elif [ "$action" = "list" ] && [ "$object_type" = "quota" ]; then
            [ "$quota_exists" = "true" ] || return 1
            echo "quota $object_name { over 1000 bytes used $test_quota bytes }"
        fi
    }
    rebuild_port_counter_objects() {
        [ "$1" = "3265" ]
        [ "$2" -eq 0 ]
        [ "$3" -eq 0 ]
        [ "$4" = "true" ]
        # 模拟事务提交后立即产生的新流量；这不能被误判成重置失败。
        test_input=7
        test_output=11
        test_quota=13
    }
    update_traffic_snapshot_baseline_locked() {
        [ "$1" = "3265" ]
        baseline_updated=true
    }

    reset_port_nftables_counters 3265
    [ "$test_input" -eq 7 ]
    [ "$test_output" -eq 11 ]
    [ "$test_quota" -eq 13 ]
    [ "$baseline_updated" = "true" ]

    test_input=100
    test_output=200
    quota_exists=false
    ! reset_port_nftables_counters 3265
    [ "$test_input" -eq 100 ]
    [ "$test_output" -eq 200 ]
)

readonly RESET_LOCK_CAPTURE="$TEST_DIR/reset-lock.capture"
(
    acquire_reset_lock() { return 1; }
    perform_auto_reset_port() { touch "$RESET_LOCK_CAPTURE"; }
    ! auto_reset_port 3265
)
[ ! -e "$RESET_LOCK_CAPTURE" ]

readonly DOUBLE_REPAIR_CAPTURE="$TEST_DIR/double-repair.capture"
(
    count_counter_rules() { echo 4; }
    record_traffic_snapshot() { :; }
    get_port_runtime_usage_snapshot() { echo "100 200 300"; }
    rebuild_port_counter_objects() { [ "$4" = "rebuild" ]; printf '%s %s\n' "$2" "$3" > "$DOUBLE_REPAIR_CAPTURE"; }
    scale_current_day_traffic_stats() { :; }
    update_traffic_snapshot_baseline() { :; }
    log_notification() { :; }
    repair_port_traffic_rules 8123
)
[ "$(cat "$DOUBLE_REPAIR_CAPTURE")" = "100 200" ]

readonly DOUBLE_MIGRATION_CAPTURE="$TEST_DIR/double-migration.capture"
(
    count_counter_rules() { echo 4; }
    record_traffic_snapshot() { :; }
    get_port_runtime_usage_snapshot() { echo "100 200 300"; }
    rebuild_port_counter_objects() { [ "$4" = "rebuild" ]; printf '%s %s\n' "$2" "$3" > "$DOUBLE_MIGRATION_CAPTURE"; }
    scale_current_day_traffic_stats() { :; }
    update_traffic_snapshot_baseline() { :; }
    log_notification() { :; }
    repair_port_traffic_rules 8123 true true
)
[ "$(cat "$DOUBLE_MIGRATION_CAPTURE")" = "200 400" ]

readonly DOUBLE_BACKUP_MIGRATION_CAPTURE="$TEST_DIR/double-backup-migration.capture"
jq -n '{
    "8123": {input:100, output:200},
    _meta: {
        schema_version: 2,
        traffic_accounting_model: "legacy-single-group",
        port_multipliers: {"8123": {input:1, output:1}}
    }
}' > "$TRAFFIC_DATA_FILE"
(
    count_counter_rules() { echo 0; }
    record_traffic_snapshot() { :; }
    get_port_runtime_usage_snapshot() { echo "100 200 300"; }
    rebuild_port_counter_objects() { [ "$4" = "rebuild" ]; printf '%s %s\n' "$2" "$3" > "$DOUBLE_BACKUP_MIGRATION_CAPTURE"; }
    scale_current_day_traffic_stats() { :; }
    update_traffic_snapshot_baseline() { :; }
    log_notification() { :; }
    repair_port_traffic_rules 8123 true true
)
[ "$(cat "$DOUBLE_BACKUP_MIGRATION_CAPTURE")" = "200 400" ]

jq -n '{"8123": {input:100, output:200}}' > "$TRAFFIC_DATA_FILE"
readonly UNKNOWN_MIGRATION_CAPTURE="$TEST_DIR/unknown-migration.capture"
(
    count_counter_rules() { echo 0; }
    record_traffic_snapshot() { :; }
    get_port_runtime_usage_snapshot() { echo "100 200 300"; }
    rebuild_port_counter_objects() { touch "$UNKNOWN_MIGRATION_CAPTURE"; }
    log_notification() { :; }
    ! repair_port_traffic_rules 8123 true true
)
[ ! -e "$UNKNOWN_MIGRATION_CAPTURE" ]
rm -f "$TRAFFIC_DATA_FILE"

readonly SINGLE_REPAIR_CAPTURE="$TEST_DIR/single-repair.capture"
update_config_file '.ports["3265"].billing_mode = "single"'
(
    count_counter_rules() {
        if [ "$2" = "in" ]; then echo 0; else echo 4; fi
    }
    record_traffic_snapshot() { :; }
    get_port_runtime_usage_snapshot() { echo "0 300 300"; }
    rebuild_port_counter_objects() { [ "$4" = "rebuild" ]; printf '%s %s\n' "$2" "$3" > "$SINGLE_REPAIR_CAPTURE"; }
    scale_current_day_traffic_stats() { :; }
    update_traffic_snapshot_baseline() { :; }
    log_notification() { :; }
    repair_port_traffic_rules 3265
)
[ "$(cat "$SINGLE_REPAIR_CAPTURE")" = "0 300" ]
update_config_file '.ports["3265"].billing_mode = "double"'

# 外来终止规则位于命名 counter 之前时必须被识别；明确不相交的规则不应误报。
(
    order_state=invalid_exact
    nft() {
        local chain="${@: -1}"
        if [ "$chain" != "input" ]; then
            printf '%s\n' '{"nftables":[{"chain":{"name":"test"}}]}'
            return 0
        fi
        case "$order_state" in
            invalid_exact)
                printf '%s\n' '{"nftables":[
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"quota":"port_3265_quota"},{"drop":null}]}},
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"accept":null}]}},
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"counter":"port_3265_in"}]}}
                ]}' ;;
            invalid_range)
                printf '%s\n' '{"nftables":[
                    {"rule":{"chain":"input","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":{"range":[3000,4000]}}},{"accept":null}]}},
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"counter":"port_3265_in"}]}}
                ]}' ;;
            invalid_set)
                printf '%s\n' '{"nftables":[
                    {"rule":{"chain":"input","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":{"set":[80,3265]}}},{"drop":null}]}},
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"counter":"port_3265_in"}]}}
                ]}' ;;
            invalid_broad)
                printf '%s\n' '{"nftables":[
                    {"rule":{"chain":"input","expr":[{"match":{"op":"in","left":{"ct":{"key":"state"}},"right":"established"}},{"accept":null}]}},
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"counter":"port_3265_in"}]}}
                ]}' ;;
            invalid_jump)
                printf '%s\n' '{"nftables":[
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"jump":{"target":"child"}}]}},
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"counter":"port_3265_in"}]}}
                ]}' ;;
            invalid_vmap)
                printf '%s\n' '{"nftables":[
                    {"rule":{"chain":"input","expr":[{"vmap":{"key":{"payload":{"protocol":"tcp","field":"dport"}},"data":{"set":[[80,{"drop":null}],[3265,{"accept":null}]]}}}]}},
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"counter":"port_3265_in"}]}}
                ]}' ;;
            disjoint_port)
                printf '%s\n' '{"nftables":[
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":{"range":[4000,5000]}}},{"accept":null}]}},
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"counter":"port_3265_in"}]}}
                ]}' ;;
            disjoint_protocol)
                printf '%s\n' '{"nftables":[
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"meta":{"key":"l4proto"}},"right":"icmp"}},{"accept":null}]}},
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"counter":"port_3265_in"}]}}
                ]}' ;;
            valid)
                printf '%s\n' '{"nftables":[
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"counter":"port_3265_in"}]}},
                    {"rule":{"chain":"input","expr":[{"match":{"left":{"payload":{"protocol":"tcp","field":"dport"}},"right":3265}},{"accept":null}]}}
                ]}' ;;
        esac
    }
    for order_state in invalid_exact invalid_range invalid_set invalid_broad invalid_jump invalid_vmap; do
        counter_direction_has_preceding_terminal_rule 3265 in
    done
    for order_state in valid disjoint_port disjoint_protocol; do
        ! counter_direction_has_preceding_terminal_rule 3265 in
    done
    ! counter_direction_has_preceding_terminal_rule 3265 out
)

readonly ORDER_REPAIR_CAPTURE="$TEST_DIR/order-repair.capture"
readonly ORDER_BASELINE_CAPTURE="$TEST_DIR/order-baseline.capture"
(
    count_counter_rules() { echo 8; }
    get_invalid_counter_order_directions() { echo in; }
    record_traffic_snapshot() { :; }
    get_port_runtime_usage_snapshot() { echo "100 200 350"; }
    rebuild_port_counter_objects() { [ "$4" = "rebuild" ]; printf '%s %s\n' "$2" "$3" > "$ORDER_REPAIR_CAPTURE"; }
    scale_current_day_traffic_stats() { :; }
    update_traffic_snapshot_baseline() { printf '%s %s %s %s\n' "$@" > "$ORDER_BASELINE_CAPTURE"; }
    log_notification() { :; }
    repair_port_traffic_rules 8123
)
[ "$(cat "$ORDER_REPAIR_CAPTURE")" = "150 200" ]
[ "$(cat "$ORDER_BASELINE_CAPTURE")" = "8123 preserve_today 50 0" ]

readonly MISSING_RULE_REPAIR_CAPTURE="$TEST_DIR/missing-rule-repair.capture"
(
    count_counter_rules() {
        if [ "$2" = "in" ]; then echo 7; else echo 8; fi
    }
    record_traffic_snapshot() { :; }
    get_port_runtime_usage_snapshot() { echo "100 200 350"; }
    rebuild_port_counter_objects() { [ "$4" = "rebuild" ]; printf '%s %s\n' "$2" "$3" > "$MISSING_RULE_REPAIR_CAPTURE"; }
    scale_current_day_traffic_stats() { :; }
    update_traffic_snapshot_baseline() { :; }
    log_notification() { :; }
    repair_port_traffic_rules 8123
)
[ "$(cat "$MISSING_RULE_REPAIR_CAPTURE")" = "150 200" ]

readonly AMBIGUOUS_GAP_REPAIR_CAPTURE="$TEST_DIR/ambiguous-gap-repair.capture"
(
    count_counter_rules() { echo 7; }
    record_traffic_snapshot() { :; }
    get_port_runtime_usage_snapshot() { echo "100 200 2097452"; }
    rebuild_port_counter_objects() { touch "$AMBIGUOUS_GAP_REPAIR_CAPTURE"; }
    log_notification() { :; }
    ! repair_port_traffic_rules 8123
)
[ ! -e "$AMBIGUOUS_GAP_REPAIR_CAPTURE" ]

readonly NFT_COMMAND_LOG="$TEST_DIR/nft-commands.log"
nft() {
    printf '%s\n' "$*" >> "$NFT_COMMAND_LOG"
    if [ "${1:-}" = "-j" ]; then
        local mode
        local expected
        mode=$(jq -r '.ports["3265"].billing_mode' "$CONFIG_FILE")
        expected=$(get_expected_quota_rule_count "$mode")
        jq -n --argjson expected "$expected" '{
            nftables:
                ([range(0; $expected) |
                    {rule:{chain:"input",handle:(. + 1),expr:[{quota:"port_3265_quota"}]}}] +
                 [{quota:{name:"port_3265_quota",bytes:107374182400}}])
        }'
    elif [ "${1:-}" = "-f" ]; then
        cat "$2" >> "$NFT_COMMAND_LOG"
    elif [ "${1:-}" = "list" ] && [ "${2:-}" = "counter" ]; then
        echo "counter test { packets 1 bytes 100 }"
    elif [ "${1:-}" = "list" ] && [ "${2:-}" = "quota" ]; then
        echo "quota test { over 1 bytes used 0 bytes }"
    fi
    return 0
}
count_quota_rules() {
    [ "$1" = "3265" ] || { echo 0; return; }
    local mode
    mode=$(jq -r '.ports["3265"].billing_mode' "$CONFIG_FILE")
    get_expected_quota_rule_count "$mode"
}
count_counter_rules() {
    local port="$1"
    local direction="$2"
    local prefix
    prefix=$(get_port_counter_prefix "$port")
    grep -c "counter name \"${prefix}_${direction}\"$" "$NFT_COMMAND_LOG" 2>/dev/null || true
}
original_nftables_quota_is_absent=$(declare -f nftables_quota_is_absent)
nftables_quota_is_absent() { return 0; }

: > "$NFT_COMMAND_LOG"
update_config_file '.ports["3265"].billing_mode = "double"'
add_nftables_rules 3265
[ "$(grep -c 'insert rule .*counter name "port_3265_in"$' "$NFT_COMMAND_LOG")" -eq 8 ]
[ "$(grep -c 'insert rule .*counter name "port_3265_out"$' "$NFT_COMMAND_LOG")" -eq 8 ]
[ "$(grep -Ec 'insert rule .* input (tcp|udp) dport 3265 counter name "port_3265_in"$' "$NFT_COMMAND_LOG")" -eq 4 ]
[ "$(grep -Ec 'insert rule .* forward (tcp|udp) dport 3265 counter name "port_3265_in"$' "$NFT_COMMAND_LOG")" -eq 4 ]
[ "$(grep -Ec 'insert rule .* output (tcp|udp) sport 3265 counter name "port_3265_out"$' "$NFT_COMMAND_LOG")" -eq 4 ]
[ "$(grep -Ec 'insert rule .* forward (tcp|udp) sport 3265 counter name "port_3265_out"$' "$NFT_COMMAND_LOG")" -eq 4 ]

: > "$NFT_COMMAND_LOG"
apply_nftables_quota 3265 100GB
[ "$(grep -c 'insert rule .*quota name "port_3265_quota" drop$' "$NFT_COMMAND_LOG")" -eq 16 ]

: > "$NFT_COMMAND_LOG"
update_config_file '.ports["3265"].billing_mode = "single"'
add_nftables_rules 3265
[ "$(grep -c 'insert rule .*counter name "port_3265_in"$' "$NFT_COMMAND_LOG")" -eq 4 ]
[ "$(grep -c 'insert rule .*counter name "port_3265_out"$' "$NFT_COMMAND_LOG")" -eq 4 ]
[ "$(grep -Ec 'insert rule .* input (tcp|udp) dport 3265 counter name "port_3265_in"$' "$NFT_COMMAND_LOG")" -eq 2 ]
[ "$(grep -Ec 'insert rule .* forward (tcp|udp) dport 3265 counter name "port_3265_in"$' "$NFT_COMMAND_LOG")" -eq 2 ]
[ "$(grep -Ec 'insert rule .* output (tcp|udp) sport 3265 counter name "port_3265_out"$' "$NFT_COMMAND_LOG")" -eq 2 ]
[ "$(grep -Ec 'insert rule .* forward (tcp|udp) sport 3265 counter name "port_3265_out"$' "$NFT_COMMAND_LOG")" -eq 2 ]

: > "$NFT_COMMAND_LOG"
apply_nftables_quota 3265 100GB
[ "$(grep -c 'insert rule .*quota name "port_3265_quota" drop$' "$NFT_COMMAND_LOG")" -eq 8 ]
(
    count_quota_rules() { echo 0; }
    nft() {
        if [ "${1:-}" = "list" ] && [ "${2:-}" = "counter" ]; then
            echo "counter test { packets 1 bytes 100 }"
            return 0
        fi
        if [ "${1:-}" = "list" ] && [ "${2:-}" = "quota" ]; then
            return 1
        fi
        return 0
    }
    ! apply_nftables_quota 3265 100GB
)
update_config_file '.ports["3265"].billing_mode = "double"'
update_config_file '.ports["3000-4000"] = {enabled:true,billing_mode:"single",quota:{enabled:false,monthly_limit:"unlimited"}}'
: > "$NFT_COMMAND_LOG"
add_nftables_rules 3000-4000
! grep -q 'meta mark set.*counter name' "$NFT_COMMAND_LOG"
[ "$(grep -c 'counter name "port_3000_4000_in"$' "$NFT_COMMAND_LOG")" -eq 4 ]
update_config_file 'del(.ports["3000-4000"])'

[ "$(generate_port_range_mark 1-2)" = "$(generate_port_range_mark 721-898)" ]
update_config_file '.ports["1-2"]={bandwidth_limit:{}} | .ports["721-898"]={bandwidth_limit:{}}'
mark_one=$(get_or_create_port_range_mark 1-2 1:2)
mark_two=$(get_or_create_port_range_mark 721-898 1:3)
[ "$mark_one" != "$mark_two" ]
[ $((mark_one & TC_MARK_PRESERVE_MASK)) -eq 0 ]
[ $((mark_two & TC_MARK_PRESERVE_MASK)) -eq 0 ]
update_config_file 'del(.ports["1-2"], .ports["721-898"])'

unset -f count_quota_rules
unset -f nftables_quota_is_absent
eval "$original_nftables_quota_is_absent"
unset -f nft

readonly ORPHAN_BATCH_CAPTURE="$TEST_DIR/orphan-cleanup.batch"
(
    orphan_state="stale"
    nft() {
        if [ "${1:-}" = "-j" ]; then
            if [ "$orphan_state" = "stale" ]; then
                printf '%s\n' '{"nftables":[
                    {"counter":{"name":"port_3265_in"}},
                    {"counter":{"name":"port_3265_out"}},
                    {"quota":{"name":"port_3265_quota"}},
                    {"counter":{"name":"port_33366_in"}},
                    {"counter":{"name":"port_33366_out"}},
                    {"quota":{"name":"port_33366_quota"}},
                    {"rule":{"chain":"input","handle":3,"expr":[{"counter":"port_33366_in"}]}},
                    {"rule":{"chain":"output","handle":4,"expr":[{"counter":"port_33366_out"}]}},
                    {"rule":{"chain":"input","handle":5,"expr":[{"quota":"port_33366_quota"},{"drop":null}]}}
                ]}'
            else
                printf '%s\n' '{"nftables":[
                    {"counter":{"name":"port_3265_in"}},
                    {"counter":{"name":"port_3265_out"}},
                    {"quota":{"name":"port_3265_quota"}}
                ]}'
            fi
            return 0
        fi
        if [ "${1:-}" = "-f" ]; then
            cp "$2" "$ORPHAN_BATCH_CAPTURE"
            orphan_state="clean"
            return 0
        fi
        return 0
    }
    orphaned=$(list_orphaned_runtime_objects)
    [ "$(printf '%s\n' "$orphaned" | wc -l)" -eq 3 ]
    printf '%s\n' "$orphaned" | grep -q '^counter port_33366_in$'
    printf '%s\n' "$orphaned" | grep -q '^counter port_33366_out$'
    printf '%s\n' "$orphaned" | grep -q '^quota port_33366_quota$'
    reconcile_orphaned_runtime_objects
    grep -q '^delete rule inet port_traffic_monitor input handle 3$' "$ORPHAN_BATCH_CAPTURE"
    grep -q '^delete counter inet port_traffic_monitor port_33366_in$' "$ORPHAN_BATCH_CAPTURE"
    grep -q '^delete quota inet port_traffic_monitor port_33366_quota$' "$ORPHAN_BATCH_CAPTURE"
    ! grep -q 'delete .*port_3265_' "$ORPHAN_BATCH_CAPTURE"
    [ -z "$(list_orphaned_runtime_objects)" ]
)

readonly CONNTRACK_CAPTURE="$TEST_DIR/conntrack.capture"
(
    conntrack() { printf '%s\n' "$*" >> "$CONNTRACK_CAPTURE"; }
    clear_port_conntrack_state 3000-4000
    [ "$(wc -l < "$CONNTRACK_CAPTURE")" -eq 2 ]
    grep -q -- '-p tcp --dport 3000:4000' "$CONNTRACK_CAPTURE"
    grep -q -- '-p udp --dport 3000:4000' "$CONNTRACK_CAPTURE"
)

readonly CRON_FILE="$TEST_DIR/crontab"
CRON_READ_FAIL=false
crontab() {
    if [ "${1:-}" = "-l" ]; then
        if [ "$CRON_READ_FAIL" = "true" ]; then
            echo "permission denied" >&2
            return 2
        fi
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

printf '%s\n' \
    '55 23 * * * /usr/local/bin/port-traffic-dog.sh --send-snapshot >/dev/null 2>&1  # 端口流量狗快照通知' \
    '0 0 * * * /usr/local/bin/port-traffic-dog.sh --create-snapshot daily >/dev/null 2>&1  # 每日0点创建日快照' \
    '0 0 * * 1 /usr/local/bin/port-traffic-dog.sh --create-snapshot weekly >/dev/null 2>&1' \
    '0 0 1 * * /usr/local/bin/port-traffic-dog.sh --create-snapshot monthly >/dev/null 2>&1' \
    '0 1 * * * /bin/bash -c "find /etc/port-traffic-dog/data/snapshots -type f -delete"' \
    '0 0 */80 * * /usr/local/bin/port-traffic-dog.sh --reset-port 8123 >/dev/null 2>&1' \
    '0 */12 * * * /usr/local/bin/port-traffic-dog.sh --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知' \
    '17 * * * * /usr/local/bin/unrelated-job' \
    > "$CRON_FILE"

setup_port_auto_reset_cron 8123
! grep -q -- '--reset-port 8123' "$CRON_FILE"
! grep -q -- '--check-reset-port' "$CRON_FILE"
[ "$(grep -c -- '--check-scheduled-resets' "$CRON_FILE")" -eq 1 ]
grep -Fq -- '*/5 * * * * /usr/local/bin/port-traffic-dog.sh --check-scheduled-resets' "$CRON_FILE"
grep -q -- '--send-snapshot' "$CRON_FILE"
grep -q -- '--send-telegram-status' "$CRON_FILE"
grep -q -- '/usr/local/bin/unrelated-job' "$CRON_FILE"

migrate_legacy_cron_if_needed
! grep -Eq -- '--(reset-port|check-reset-port|send-snapshot|create-snapshot)|/etc/port-traffic-dog/data/snapshots' "$CRON_FILE"
[ "$(grep -c -- '--check-scheduled-resets' "$CRON_FILE")" -eq 1 ]
[ "$(grep -c -- '--snapshot-traffic' "$CRON_FILE")" -eq 1 ]
[ "$(grep -c -- '--restore-runtime' "$CRON_FILE")" -eq 1 ]
grep -q -- '--send-telegram-status' "$CRON_FILE"
grep -q -- '/usr/local/bin/unrelated-job' "$CRON_FILE"
printf '%s\n' '5 0 * * * /usr/local/bin/port-traffic-dog.sh --check-reset-port 3011 >/dev/null 2>&1  # 端口流量狗自动重置端口3011' >> "$CRON_FILE"
migrate_legacy_cron_if_needed
! grep -q -- '--check-reset-port 3011' "$CRON_FILE"
[ "$(grep -c -- '--check-scheduled-resets' "$CRON_FILE")" -eq 1 ]
cp "$CRON_FILE" "$TEST_DIR/crontab.before-noop"
migrate_legacy_cron_if_needed
cmp -s "$CRON_FILE" "$TEST_DIR/crontab.before-noop"

cp "$CRON_FILE" "$TEST_DIR/crontab.before-read-failure"
CRON_READ_FAIL=true
! setup_telegram_notification_cron
CRON_READ_FAIL=false
cmp -s "$CRON_FILE" "$TEST_DIR/crontab.before-read-failure"

refresh_port_auto_reset_cron_from_config
! grep -q -- '--reset-port' "$CRON_FILE"
! grep -q -- '--check-reset-port' "$CRON_FILE"
[ "$(grep -c -- '--check-scheduled-resets' "$CRON_FILE")" -eq 1 ]
grep -q -- '/usr/local/bin/unrelated-job' "$CRON_FILE"

update_config_file '.ports = {}'
setup_traffic_snapshot_cron
! grep -q -- '--snapshot-traffic' "$CRON_FILE"
[ "$(grep -c -- '--restore-runtime' "$CRON_FILE")" -eq 1 ]
! grep -Eq -- '--(send-snapshot|create-snapshot)|/etc/port-traffic-dog/data/snapshots' "$CRON_FILE"
grep -q -- '--check-scheduled-resets' "$CRON_FILE"
grep -q -- '--send-telegram-status' "$CRON_FILE"
grep -q -- '/usr/local/bin/unrelated-job' "$CRON_FILE"
setup_telegram_notification_cron
! grep -q -- '--send-telegram-status' "$CRON_FILE"

update_config_file '.ports["2000"] = {enabled: true}'
setup_telegram_notification_cron
grep -q -- '--send-telegram-status' "$CRON_FILE"
setup_wecom_notification_cron
grep -q -- '--send-wecom-status' "$CRON_FILE"
update_config_file '
    .notifications.telegram.enabled = false |
    .notifications.wecom.enabled = false
'
setup_telegram_notification_cron
setup_wecom_notification_cron
! grep -q -- '--send-telegram-status' "$CRON_FILE"
! grep -q -- '--send-wecom-status' "$CRON_FILE"
update_config_file '
    .notifications.telegram.enabled = true |
    .notifications.wecom.enabled = true
'
setup_traffic_snapshot_cron
setup_traffic_snapshot_cron
[ "$(grep -c -- '--snapshot-traffic' "$CRON_FILE")" -eq 1 ]
[ "$(grep -c -- '--restore-runtime' "$CRON_FILE")" -eq 1 ]
grep -q -- '--check-scheduled-resets' "$CRON_FILE"
grep -q -- '/usr/local/bin/unrelated-job' "$CRON_FILE"

update_config_file '.ports = {}'
setup_telegram_notification_cron
! grep -q -- '--send-telegram-status' "$CRON_FILE"
setup_traffic_snapshot_cron
! grep -q -- '--snapshot-traffic' "$CRON_FILE"
[ "$(grep -c -- '--restore-runtime' "$CRON_FILE")" -eq 1 ]
refresh_port_auto_reset_cron_from_config
! grep -q -- '--check-scheduled-resets' "$CRON_FILE"

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
[ -f "$TRAFFIC_DATA_FILE" ]

jq -n '{
    last_snapshot: {"2000": {}, "3000": {}},
    state: {"2000": {}, "3000": {}},
    daily: {"2000": {}, "3000": {}}
}' > "$TRAFFIC_STATS_FILE"
jq -n '{
    "2000": {input: 1},
    "3000": {input: 2},
    _meta: {
        schema_version: 2,
        port_multipliers: {"2000": {input:2, output:2}, "3000": {input:1, output:1}}
    }
}' > "$TRAFFIC_DATA_FILE"
remove_port_traffic_state 2000
jq -e '(.last_snapshot["2000"] == null) and (.state["2000"] == null) and
       (.daily["2000"] == null) and (.daily["3000"] != null)' "$TRAFFIC_STATS_FILE" >/dev/null
jq -e 'has("2000") | not' "$TRAFFIC_DATA_FILE" >/dev/null
jq -e 'has("3000")' "$TRAFFIC_DATA_FILE" >/dev/null
jq -e '._meta.port_multipliers["2000"] == null and
       ._meta.port_multipliers["3000"] == {input:1, output:1}' "$TRAFFIC_DATA_FILE" >/dev/null

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
! apply_nftables_quota 2000 "invalid"
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
[ "$(get_tc_ipv6_filter_handle 65535 3)" = "0x3ffff" ]
jq -e --arg class_id "$class_id" '.ports["65535"].bandwidth_limit.class_id == $class_id' \
    "$CONFIG_FILE" >/dev/null

# 无有效配置卸载时，必须先取得共享锁再复核归属；锁内出现的 NTC 状态不得被删除。
(
    owner_file=$(get_tc_root_owner_file)
    printf '%s\n' 'eth0|test-machine' > "$owner_file"
    lock_held=false
    ntc_claimed=false
    begin_tc_update() {
        lock_held=true
        ntc_claimed=true
    }
    finish_tc_update() { lock_held=false; }
    tc_root_is_owned() { [ "$lock_held" = "true" ]; }
    trafficcop_unified_state_rate() {
        [ "$lock_held" = "true" ] && [ "$ntc_claimed" = "true" ] || return 1
        printf '%s\n' '5mbit'
    }
    tc() {
        if [ "${1:-}" = "qdisc" ] && [ "${2:-}" = "del" ]; then
            touch "$TEST_DIR/uninstall-qdisc-deleted"
        fi
    }
    log_notification() { :; }

    cleanup_owned_tc_root_without_config
    [ "$lock_held" = "false" ]
    [ ! -e "$owner_file" ]
    [ ! -e "$TEST_DIR/uninstall-qdisc-deleted" ]
)

(
    get_default_interface() { echo eth0; }
    tc_root_is_managed() { return 0; }
    tc_root_owner_marker_matches() { return 0; }
    tc_class_added=false
    tc() {
        if [ "$1" = "qdisc" ] && [ "$2" = "show" ]; then
            echo 'qdisc htb 1: root refcnt 2 default 30'
        elif [ "$1" = "class" ] && [ "$2" = "show" ]; then
            echo 'class htb 1:1 root rate 100Gbit ceil 100Gbit'
            echo 'class htb 1:30 parent 1:1 rate 1Kbit ceil 100Gbit'
            [ "$tc_class_added" = "true" ] && echo "class htb $class_id parent 1:1 rate 1Kbit ceil 1Mbit"
        elif [ "$1" = "class" ] && [ "$2" = "replace" ] &&
             [[ " $* " == *" classid $class_id "* ]]; then
            tc_class_added=true
        fi
        return 0
    }
    apply_tc_limit 65535 1mbit
)
(
    get_default_interface() { echo eth0; }
    tc_root_is_managed() { return 1; }
    adopt_legacy_tc_root_if_safe() { return 1; }
    tc_class_changed=false
    tc() {
        if [ "$1" = "qdisc" ] && [ "$2" = "show" ]; then
            echo 'qdisc htb 1: root refcnt 2 default 30'
        elif [ "$1" = "class" ] && { [ "$2" = "replace" ] || [ "$2" = "del" ]; }; then
            tc_class_changed=true
        fi
        return 0
    }
    ! apply_tc_limit 65535 1mbit
    [ "$tc_class_changed" = "false" ]
)
(
    get_default_interface() { echo eth0; }
    tc() {
        if [ "$1" = "qdisc" ] && [ "$2" = "show" ]; then
            echo 'qdisc fq_codel 0: root refcnt 2'
            return 0
        fi
        if [ "$1" = "qdisc" ] && [ "$2" = "replace" ]; then
            return 1
        fi
        return 0
    }
    ! apply_tc_limit 65535 1mbit
)

(
    unset -f update_config_file
    source "$PROJECT_DIR/telegram.sh"
    telegram_update_config_file '.compat.telegram = true'
    telegram_update_config_file '
        del(.notifications.telegram.api_route) |
        del(.notifications.telegram.custom_api_base)
    '
    [ "$(get_telegram_api_route)" = "official" ]
    [ "$(get_telegram_api_base)" = "https://api.telegram.org" ]

    # 旧版明确保存的自定义线路和地址必须继续按原配置读取。
    telegram_update_config_file '
        .notifications.telegram.api_route = "custom" |
        .notifications.telegram.custom_api_base = "http://example.com"
    '
    [ "$(get_telegram_api_base)" = "https://api.telegram.org" ]
    telegram_update_config_file '.notifications.telegram.custom_api_base = "http://127.0.0.1:8080"'
    [ "$(get_telegram_api_base)" = "http://127.0.0.1:8080" ]
    telegram_update_config_file '.notifications.telegram.custom_api_base = "https://tg.example.com/"'
    [ "$(get_telegram_api_base)" = "https://tg.example.com" ]
    (
        init_nftables() { :; }
        setup_exit_hooks() { :; }
        restore_monitoring_if_needed() { :; }
        ensure_traffic_accounting_model() { :; }
        ensure_tc_runtime_model() { :; }
        init_config
        jq -e '
            .notifications.telegram.api_route == "custom" and
            .notifications.telegram.custom_api_base == "https://tg.example.com/"
        ' "$CONFIG_FILE" >/dev/null
    )
)
readonly TELEGRAM_TEST_CAPTURE="$TEST_DIR/telegram-test.capture"
(
    source "$PROJECT_DIR/telegram.sh"
    telegram_is_enabled() { return 0; }
    format_status_message() { echo test; }
    send_telegram_message() { touch "$TELEGRAM_TEST_CAPTURE"; }
    sleep() { :; }
    telegram_update_config_file '.notifications.telegram.status_notifications.enabled = false'
    telegram_test >/dev/null
)
[ -f "$TELEGRAM_TEST_CAPTURE" ]
(
    unset -f update_config_file
    source "$PROJECT_DIR/wecom.sh"
    wecom_update_config_file '.compat.wecom = true'
)
readonly WECOM_TEST_CAPTURE="$TEST_DIR/wecom-test.capture"
(
    source "$PROJECT_DIR/wecom.sh"
    wecom_is_enabled() { return 0; }
    format_text_status_message() { echo test; }
    send_wecom_message() { touch "$WECOM_TEST_CAPTURE"; }
    sleep() { :; }
    wecom_update_config_file '.notifications.wecom.status_notifications.enabled = false'
    wecom_test >/dev/null
)
[ -f "$WECOM_TEST_CAPTURE" ]
jq -e '.compat == {telegram: true, wecom: true}' "$CONFIG_FILE" >/dev/null

readonly WECOM_PAYLOAD_CAPTURE="$TEST_DIR/wecom-payload.json"
update_config_file '
    .notifications.wecom.enabled = true |
    .notifications.wecom.webhook_url = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test"
'
(
    source "$PROJECT_DIR/wecom.sh"
    curl() {
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-d" ]; then
                printf '%s' "$2" > "$WECOM_PAYLOAD_CAPTURE"
                shift 2
                continue
            fi
            shift
        done
        echo '{"errcode":0}'
    }
    send_wecom_message $'引号" 换行\n反斜线\\ 制表\t结束'
)
jq -e '.msgtype == "text" and .text.content == "引号\" 换行\n反斜线\\ 制表\t结束"' \
    "$WECOM_PAYLOAD_CAPTURE" >/dev/null

# 自检必须核对流量规则和 cron，而不是只检查配置文件格式。
update_config_file '
    .ports = {
        "2000": {
            enabled: true,
            billing_mode: "double",
            quota: {enabled: false, monthly_limit: "unlimited"}
        }
    } |
    .notifications.telegram.enabled = true |
    .notifications.telegram.bot_token = "" |
    .notifications.telegram.status_notifications = {enabled: true, interval: "1m"} |
    .notifications.wecom.status_notifications = {enabled: true, interval: "1m"}
'
mkdir -p "$CONFIG_DIR/notifications"
cp "$PROJECT_DIR/telegram.sh" "$CONFIG_DIR/notifications/telegram.sh"
cp "$PROJECT_DIR/wecom.sh" "$CONFIG_DIR/notifications/wecom.sh"
printf '%s\n' \
    '@reboot sleep 15 && /usr/local/bin/port-traffic-dog.sh --restore-runtime >/dev/null 2>&1  # port-traffic-dog runtime restore' \
    '* * * * * /usr/local/bin/port-traffic-dog.sh --snapshot-traffic >/dev/null 2>&1  # port-traffic-dog traffic snapshot' \
    '* * * * * /usr/local/bin/port-traffic-dog.sh --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知' \
    '* * * * * /usr/local/bin/port-traffic-dog.sh --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知' \
    > "$CRON_FILE"
nft() {
    if [ "${1:-}" = "list" ] && [ "${2:-}" = "quota" ]; then
        return 1
    fi
    return 0
}
tc() { :; }
ss() { :; }
bc() { :; }
cron() { :; }
flock() { :; }
conntrack() { :; }
get_default_interface() { echo eth0; }
count_counter_rules() { echo 8; }
count_quota_rules() { echo 0; }
get_invalid_counter_order_directions() { :; }
list_orphaned_runtime_objects() { :; }
self_check >/dev/null
sed -i 's/^\* \* \* \* \* \(.*--snapshot-traffic.*\)$/0 * * * * \1/' "$CRON_FILE"
! self_check >/dev/null
sed -i 's/^0 \* \* \* \* \(.*--snapshot-traffic.*\)$/* * * * * \1/' "$CRON_FILE"
self_check >/dev/null
sed -i '/--snapshot-traffic/d' "$CRON_FILE"
! self_check >/dev/null

# 普通启动只允许执行轻量初始化，以及检测到旧 cron 时进行一次性迁移。
readonly STARTUP_TRACE_FILE="$TEST_DIR/startup.trace"
trace_startup_call() {
    printf '%s\n' "$1" >> "$STARTUP_TRACE_FILE"
}
check_root() { trace_startup_call check_root; }
check_dependencies() { trace_startup_call check_dependencies; }
init_config() { trace_startup_call init_config; }
ensure_installation_files() { trace_startup_call ensure_installation_files; }
create_shortcut_command() { trace_startup_call create_shortcut_command; }
setup_script_permissions() { trace_startup_call setup_script_permissions; }
setup_cron_environment() { trace_startup_call setup_cron_environment; }
migrate_legacy_cron_if_needed() { trace_startup_call migrate_legacy_cron_if_needed; }
download_notification_modules() { trace_startup_call download_notification_modules; }
refresh_port_auto_reset_cron_from_config() { trace_startup_call refresh_port_auto_reset_cron_from_config; }
refresh_notification_cron_from_config() { trace_startup_call refresh_notification_cron_from_config; }
setup_traffic_snapshot_cron() { trace_startup_call setup_traffic_snapshot_cron; }
refresh_all_cron_from_config() { trace_startup_call refresh_all_cron_from_config; }
repair_duplicate_traffic_rules() {
    trace_startup_call repair_duplicate_traffic_rules
    echo 0
}
restore_runtime_state() { trace_startup_call restore_runtime_state; }
record_traffic_snapshot() { trace_startup_call record_traffic_snapshot; }
self_check() { trace_startup_call self_check; }
show_main_menu() { trace_startup_call show_main_menu; }
clear() { :; }
read() { :; }

: > "$STARTUP_TRACE_FILE"
main
[ "$(cat "$STARTUP_TRACE_FILE")" = $'check_root\ncheck_dependencies\ninit_config\nensure_installation_files\nmigrate_legacy_cron_if_needed\nshow_main_menu' ]

: > "$STARTUP_TRACE_FILE"
(main --version >/dev/null)
[ "$(cat "$STARTUP_TRACE_FILE")" = "check_root" ]

install_update_script() {
    [ "${1:-}" = "false" ]
    return 23
}
install_status=0
(main --install >/dev/null 2>&1) || install_status=$?
[ "$install_status" -eq 23 ]

(
    get_active_ports() { printf '%s\n' 3265 8123; }
    check_reset_port_due() { [ "$1" != "8123" ]; }
    ! check_scheduled_resets
)

cli_status=0
(
    check_root() { :; }
    auto_reset_port() { return 7; }
    main --reset-port 3265
) >/dev/null 2>&1 || cli_status=$?
[ "$cli_status" -eq 7 ]

cli_status=0
(
    check_root() { :; }
    check_scheduled_resets() { return 8; }
    main --check-scheduled-resets
) >/dev/null 2>&1 || cli_status=$?
[ "$cli_status" -eq 8 ]

cli_status=0
(
    check_root() { :; }
    has_active_ports() { return 0; }
    load_telegram_module() { return 1; }
    main --send-telegram-status
) >/dev/null 2>&1 || cli_status=$?
[ "$cli_status" -eq 1 ]

cli_status=0
(
    check_root() { :; }
    has_active_ports() { return 0; }
    send_status_notification() { return 9; }
    main --send-status
) >/dev/null 2>&1 || cli_status=$?
[ "$cli_status" -eq 9 ]

readonly EXPORT_SAVE_CAPTURE="$TEST_DIR/export-save.capture"
(
    has_active_ports() { return 0; }
    record_traffic_snapshot() { return 1; }
    save_traffic_data() { touch "$EXPORT_SAVE_CAPTURE"; }
    manage_configuration() { :; }
    read() { :; }
    ! export_config >/dev/null
)
[ ! -e "$EXPORT_SAVE_CAPTURE" ]
(
    has_active_ports() { return 0; }
    record_traffic_snapshot() { return 0; }
    save_traffic_data() { return 1; }
    manage_configuration() { :; }
    read() { :; }
    ! export_config >/dev/null
)

grep -q -- '--refresh-all-cron' "$PROJECT_DIR/migrate-to-custom.sh"
grep -q -- 'port-traffic-dog-config/reset.lock' "$PROJECT_DIR/migrate-to-custom.sh"
grep -q -- 'port-traffic-dog-config/cron.lock' "$PROJECT_DIR/migrate-to-custom.sh"
grep -Fq 'CRON_LOCK_DIR="${CONFIG_DIR}/cron.lock"' "$PROJECT_DIR/migrate-to-custom.sh"
grep -Fq '"${current_pid}" "$(date +%s)" "${current_boot_id}" "${current_start_time}"' "$PROJECT_DIR/migrate-to-custom.sh"
! grep -Fq '"${CONFIG_DIR}/reset.lock" "${CONFIG_DIR}/cron.lock"' "$PROJECT_DIR/migrate-to-custom.sh"
[ "$(grep -c 'crontab -l' "$SCRIPT_FILE")" -eq 1 ]
grep -q '^umask 077$' "$PROJECT_DIR/migrate-to-custom.sh"
grep -q -- '--validate-config' "$PROJECT_DIR/migrate-to-custom.sh"
grep -Fq -- 'bash "${INSTALLED_SCRIPT_PATH}" --restore-runtime' "$PROJECT_DIR/migrate-to-custom.sh"
grep -Fq -- 'archive_url="${MODULES_ARCHIVE_URL}?cache_bust=$(date +%s)"' "$SCRIPT_FILE"
grep -Fq -- 'bash "$INSTALLED_SCRIPT_PATH" --finalize-update' "$SCRIPT_FILE"
add_port_monitoring_body=$(sed -n '/^add_port_monitoring() {/,/^}/p' "$SCRIPT_FILE")
grep -q 'refresh_port_auto_reset_cron_from_config' <<< "$add_port_monitoring_body"
grep -Fq -- '"conntrack"' "$SCRIPT_FILE"
grep -Fq -- 'conntrack-tools' "$PROJECT_DIR/alpine-port-traffic-dog-preinstall.sh"

: > "$STARTUP_TRACE_FILE"
system_check_and_repair >/dev/null
for expected_call in \
    check_dependencies init_config setup_script_permissions setup_cron_environment \
    create_shortcut_command download_notification_modules \
    refresh_all_cron_from_config repair_duplicate_traffic_rules \
    restore_runtime_state record_traffic_snapshot self_check show_main_menu; do
    [ "$(grep -c -x "$expected_call" "$STARTUP_TRACE_FILE")" -eq 1 ]
done

echo "regression tests passed"
