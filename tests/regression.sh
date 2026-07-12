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
[ "$(get_expected_counter_rule_count double)" -eq 8 ]
[ "$(get_expected_counter_rule_count single)" -eq 4 ]
[ "$(get_expected_quota_rule_count double)" -eq 16 ]
[ "$(get_expected_quota_rule_count single)" -eq 8 ]
[ "$(scale_counter_for_rule_multiplier 100 1 2)" -eq 200 ]
[ "$(scale_counter_for_rule_multiplier 200 2 1)" -eq 100 ]
[ "$(get_counter_rule_multiplier_from_count 7 2)" -eq 2 ]
[ "$(calculate_total_traffic 100 200 double)" -eq 300 ]
[ "$(calculate_total_traffic 100 200 single)" -eq 300 ]

today=$(get_current_date)
jq -n --arg port "3265" --arg date "$today" '
    {last_snapshot: {}, state: {}, daily: {($port): {($date): {input: 100, output: 200}}}}
' > "$TRAFFIC_STATS_FILE"
scale_current_day_traffic_stats 3265 1 2 1 2
jq -e --arg port "3265" --arg date "$today" \
    '.daily[$port][$date].input == 200 and .daily[$port][$date].output == 400' \
    "$TRAFFIC_STATS_FILE" >/dev/null
rm -f "$TRAFFIC_STATS_FILE"

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

(
    test_input=100
    test_output=200
    test_quota=300
    quota_exists=true
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
        elif [ "$action" = "reset" ] && [ "$object_type" = "counter" ]; then
            if [[ "$object_name" == *_in ]]; then test_input=0; else test_output=0; fi
        elif [ "$action" = "reset" ] && [ "$object_type" = "quota" ]; then
            test_quota=0
        fi
    }

    reset_port_nftables_counters 3265
    [ "$test_input" -eq 0 ]
    [ "$test_output" -eq 0 ]
    [ "$test_quota" -eq 0 ]

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
    get_nftables_counter_data() { echo "100 200"; }
    remove_nftables_quota() { :; }
    remove_nftables_rules() { :; }
    restore_counter_value() { printf '%s %s\n' "$2" "$3" > "$DOUBLE_REPAIR_CAPTURE"; }
    add_nftables_rules() { :; }
    scale_current_day_traffic_stats() { :; }
    update_traffic_snapshot_baseline() { :; }
    apply_nftables_quota() { :; }
    log_notification() { :; }
    repair_port_traffic_rules 8123
)
[ "$(cat "$DOUBLE_REPAIR_CAPTURE")" = "200 400" ]

readonly SINGLE_REPAIR_CAPTURE="$TEST_DIR/single-repair.capture"
update_config_file '.ports["3265"].billing_mode = "single"'
(
    count_counter_rules() {
        if [ "$2" = "in" ]; then echo 0; else echo 4; fi
    }
    get_nftables_counter_data() { echo "0 300"; }
    remove_nftables_quota() { :; }
    remove_nftables_rules() { :; }
    restore_counter_value() { printf '%s %s\n' "$2" "$3" > "$SINGLE_REPAIR_CAPTURE"; }
    add_nftables_rules() { :; }
    scale_current_day_traffic_stats() { :; }
    update_traffic_snapshot_baseline() { :; }
    apply_nftables_quota() { :; }
    log_notification() { :; }
    repair_port_traffic_rules 3265
)
[ "$(cat "$SINGLE_REPAIR_CAPTURE")" = "0 300" ]
update_config_file '.ports["3265"].billing_mode = "double"'

readonly NFT_COMMAND_LOG="$TEST_DIR/nft-commands.log"
nft() {
    printf '%s\n' "$*" >> "$NFT_COMMAND_LOG"
    if [ "${1:-}" = "list" ] && [ "${2:-}" = "counter" ]; then
        echo "counter test { packets 1 bytes 100 }"
    fi
    return 0
}

: > "$NFT_COMMAND_LOG"
update_config_file '.ports["3265"].billing_mode = "double"'
add_nftables_rules 3265
[ "$(grep -c 'add rule .*counter name port_3265_in$' "$NFT_COMMAND_LOG")" -eq 8 ]
[ "$(grep -c 'add rule .*counter name port_3265_out$' "$NFT_COMMAND_LOG")" -eq 8 ]
[ "$(grep -Ec 'add rule .* input (tcp|udp) dport 3265 counter name port_3265_in$' "$NFT_COMMAND_LOG")" -eq 4 ]
[ "$(grep -Ec 'add rule .* forward (tcp|udp) dport 3265 counter name port_3265_in$' "$NFT_COMMAND_LOG")" -eq 4 ]
[ "$(grep -Ec 'add rule .* output (tcp|udp) sport 3265 counter name port_3265_out$' "$NFT_COMMAND_LOG")" -eq 4 ]
[ "$(grep -Ec 'add rule .* forward (tcp|udp) sport 3265 counter name port_3265_out$' "$NFT_COMMAND_LOG")" -eq 4 ]

: > "$NFT_COMMAND_LOG"
apply_nftables_quota 3265 100GB
[ "$(grep -c 'insert rule .*quota name port_3265_quota drop$' "$NFT_COMMAND_LOG")" -eq 16 ]

: > "$NFT_COMMAND_LOG"
update_config_file '.ports["3265"].billing_mode = "single"'
add_nftables_rules 3265
[ "$(grep -c 'add rule .*counter name port_3265_in$' "$NFT_COMMAND_LOG")" -eq 4 ]
[ "$(grep -c 'add rule .*counter name port_3265_out$' "$NFT_COMMAND_LOG")" -eq 4 ]
[ "$(grep -Ec 'add rule .* input (tcp|udp) dport 3265 counter name port_3265_in$' "$NFT_COMMAND_LOG")" -eq 2 ]
[ "$(grep -Ec 'add rule .* forward (tcp|udp) dport 3265 counter name port_3265_in$' "$NFT_COMMAND_LOG")" -eq 2 ]
[ "$(grep -Ec 'add rule .* output (tcp|udp) sport 3265 counter name port_3265_out$' "$NFT_COMMAND_LOG")" -eq 2 ]
[ "$(grep -Ec 'add rule .* forward (tcp|udp) sport 3265 counter name port_3265_out$' "$NFT_COMMAND_LOG")" -eq 2 ]

: > "$NFT_COMMAND_LOG"
apply_nftables_quota 3265 100GB
[ "$(grep -c 'insert rule .*quota name port_3265_quota drop$' "$NFT_COMMAND_LOG")" -eq 8 ]
update_config_file '.ports["3265"].billing_mode = "double"'
unset -f nft

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

printf '%s\n' \
    '55 23 * * * /usr/local/bin/port-traffic-dog.sh --send-snapshot >/dev/null 2>&1  # 端口流量狗快照通知' \
    '0 0 * * * /usr/local/bin/port-traffic-dog.sh --create-snapshot daily >/dev/null 2>&1  # 每日0点创建日快照' \
    '0 0 * * 1 /usr/local/bin/port-traffic-dog.sh --create-snapshot weekly >/dev/null 2>&1' \
    '0 0 1 * * /usr/local/bin/port-traffic-dog.sh --create-snapshot monthly >/dev/null 2>&1' \
    '0 1 * * * /bin/bash -c "find /etc/port-traffic-dog/data/snapshots -type f -delete"' \
    '5 0 1 * * /usr/local/bin/port-traffic-dog.sh --reset-port 8123 >/dev/null 2>&1' \
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

refresh_port_auto_reset_cron_from_config
! grep -q -- '--reset-port' "$CRON_FILE"
! grep -q -- '--check-reset-port' "$CRON_FILE"
[ "$(grep -c -- '--check-scheduled-resets' "$CRON_FILE")" -eq 1 ]
grep -q -- '/usr/local/bin/unrelated-job' "$CRON_FILE"

update_config_file '.ports = {}'
setup_traffic_snapshot_cron
! grep -q -- '--snapshot-traffic' "$CRON_FILE"
! grep -Eq -- '--(send-snapshot|create-snapshot)|/etc/port-traffic-dog/data/snapshots' "$CRON_FILE"
grep -q -- '--check-scheduled-resets' "$CRON_FILE"
grep -q -- '--send-telegram-status' "$CRON_FILE"
grep -q -- '/usr/local/bin/unrelated-job' "$CRON_FILE"
setup_telegram_notification_cron
! grep -q -- '--send-telegram-status' "$CRON_FILE"

update_config_file '.ports["2000"] = {enabled: true}'
setup_telegram_notification_cron
grep -q -- '--send-telegram-status' "$CRON_FILE"
setup_traffic_snapshot_cron
setup_traffic_snapshot_cron
[ "$(grep -c -- '--snapshot-traffic' "$CRON_FILE")" -eq 1 ]
grep -q -- '--check-scheduled-resets' "$CRON_FILE"
grep -q -- '/usr/local/bin/unrelated-job' "$CRON_FILE"

update_config_file '.ports = {}'
setup_telegram_notification_cron
! grep -q -- '--send-telegram-status' "$CRON_FILE"
setup_traffic_snapshot_cron
! grep -q -- '--snapshot-traffic' "$CRON_FILE"
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
    '* * * * * /usr/local/bin/port-traffic-dog.sh --snapshot-traffic >/dev/null 2>&1  # port-traffic-dog traffic snapshot' \
    '* * * * * /usr/local/bin/port-traffic-dog.sh --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知' \
    '* * * * * /usr/local/bin/port-traffic-dog.sh --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知' \
    > "$CRON_FILE"
nft() { :; }
tc() { :; }
ss() { :; }
bc() { :; }
cron() { :; }
count_counter_rules() { echo 8; }
count_quota_rules() { echo 0; }
self_check >/dev/null
sed -i '/--snapshot-traffic/d' "$CRON_FILE"
! self_check >/dev/null

# 普通启动只能执行轻量初始化，不能重复改 cron、同步模块或修复规则。
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
download_notification_modules() { trace_startup_call download_notification_modules; }
refresh_port_auto_reset_cron_from_config() { trace_startup_call refresh_port_auto_reset_cron_from_config; }
refresh_notification_cron_from_config() { trace_startup_call refresh_notification_cron_from_config; }
setup_traffic_snapshot_cron() { trace_startup_call setup_traffic_snapshot_cron; }
repair_duplicate_traffic_rules() {
    trace_startup_call repair_duplicate_traffic_rules
    echo 0
}
record_traffic_snapshot() { trace_startup_call record_traffic_snapshot; }
self_check() { trace_startup_call self_check; }
show_main_menu() { trace_startup_call show_main_menu; }
clear() { :; }
read() { :; }

: > "$STARTUP_TRACE_FILE"
main
[ "$(cat "$STARTUP_TRACE_FILE")" = $'check_root\ncheck_dependencies\ninit_config\nensure_installation_files\nshow_main_menu' ]

: > "$STARTUP_TRACE_FILE"
(main --version >/dev/null)
[ "$(cat "$STARTUP_TRACE_FILE")" = "check_root" ]

grep -q -- '--refresh-port-reset-cron' "$PROJECT_DIR/migrate-to-custom.sh"

: > "$STARTUP_TRACE_FILE"
system_check_and_repair >/dev/null
for expected_call in \
    check_dependencies init_config setup_script_permissions setup_cron_environment \
    create_shortcut_command download_notification_modules \
    refresh_port_auto_reset_cron_from_config refresh_notification_cron_from_config \
    setup_traffic_snapshot_cron repair_duplicate_traffic_rules \
    record_traffic_snapshot self_check show_main_menu; do
    [ "$(grep -c -x "$expected_call" "$STARTUP_TRACE_FILE")" -eq 1 ]
done

echo "regression tests passed"
