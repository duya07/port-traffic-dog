#!/bin/bash
# Focused regressions: real TC/nft in a private network namespace, no services.
set -uo pipefail
if [ "${PTD_COMPAT_NETNS:-0}" != 1 ]; then exec unshare -n env PTD_COMPAT_NETNS=1 bash "$0"; fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export TRAFFIC_TOOLS_TC_LOCK_FILE="$work/tc.lock"
export TRAFFICCOP_TC_STATE_FILE="$work/ntc/tc_limit_state"
export TRAFFICCOP_CONFIG_FILE="$work/ntc/traffic_monitor_config.txt"
export DOG_CONFIG_DIR="$work/dog"
mkdir -p "$work/dog/logs" "$work/ntc"
source <(sed -e "s#^readonly CONFIG_DIR=.*#readonly CONFIG_DIR=\"$work/dog\"#" -e '$d' "$ROOT/dog/port-traffic-dog.sh")
get_default_interface() { printf 'eth0\n'; }
ip link set lo up
ip link add eth0 type veth peer name peer0
ip link set eth0 up
ip link set peer0 up
for name in trafficcop-lite.sh trafficcop-lite-monitor.sh; do
 sed -e "s#^WORK_DIR=.*#WORK_DIR=\"$work/ntc\"#" -e "s#^DOG_CONFIG_FILE=.*#DOG_CONFIG_FILE=\"$CONFIG_FILE\"#" -e "s#^DOG_TC_OWNER_FILE=.*#DOG_TC_OWNER_FILE=\"$work/dog/tc-root-qdisc.owner\"#" "$ROOT/ntc/$name" > "$work/ntc/$name"
done
printf 'DISABLED=false\n' > "$TRAFFICCOP_CONFIG_FILE"
ntc_action() {
 bash -c 'set -uo pipefail; source <(sed "/^# 执行主函数/,\$d" "$1"); MAIN_INTERFACE=eth0; TRAFFIC_PERIOD=monthly; PERIOD_START_DAY=1; if [ "$2" = apply ]; then apply_tc_limit "$3"; else clear_owned_tc_rules compat; fi' _ "$work/ntc/trafficcop-lite-monitor.sh" "$@"
}
reset_tree() {
 tc qdisc del dev eth0 root 2>/dev/null || true
 tc qdisc del dev eth0 ingress 2>/dev/null || true
 ip link del ifb0 2>/dev/null || true
 nft delete table inet port_traffic_monitor 2>/dev/null || true
 rm -f "$work/ntc/tc_limit_state" "$work/dog/tc-root-qdisc.owner"
jq -n '{global:{billing_mode:"single"},ports:{"3265":{enabled:true,billing_mode:"single",quota:{enabled:false,monthly_limit:"unlimited"},bandwidth_limit:{enabled:true,rate:"2mbit"}},"8080,8081":{enabled:true,billing_mode:"single",quota:{enabled:false,monthly_limit:"unlimited"},bandwidth_limit:{enabled:true,rate:"2mbit"}}},nftables:{table_name:"port_traffic_monitor",family:"inet"},notifications:{telegram:{enabled:false},wecom:{enabled:false}}}' > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
 init_nftables
}
pass=0;fail=0
check() { if "$@"; then echo "PASS $*";pass=$((pass+1));else echo "FAIL $*";fail=$((fail+1));fi; }
overlap_rejected() {
 jq '.ports={"8080,8080-8081":{enabled:true}}' "$CONFIG_FILE" > "$work/overlap.json"
 ! bash "$ROOT/dog/port-traffic-dog.sh" --validate-config "$work/overlap.json" >/dev/null 2>&1
}
group_cleanup() {
 reset_tree || return 1
 add_nftables_rules 3265 && add_nftables_rules 8080,8081 || return 1
 apply_tc_limit 3265 2mbit && apply_tc_limit 8080,8081 2mbit || return 1
 local id;id=$(jq -r '.ports["8080,8081"].bandwidth_limit.class_id' "$CONFIG_FILE")
 remove_tc_limit 8080,8081 || return 1
 ! tc class show dev ifb0 | grep -Fq "class htb $id "
}
ntc_updates_ingress() {
 reset_tree && apply_tc_limit 3265 2mbit && ntc_action apply 1000 >/dev/null || return 1
 tc_class_rate_matches ifb0 1:1 1mbit
}
ntc_clears_ingress() {
 reset_tree && ntc_action apply 1000 >/dev/null && apply_tc_limit 3265 2mbit || return 1
 ntc_action clear >/dev/null || return 1
 tc_class_rate_matches ifb0 1:1 100gbit && tc_class_rate_matches ifb0 1:30 1kbit 100gbit
}
drift_detected() {
 reset_tree && apply_tc_limit 3265 2mbit || return 1
 tc class replace dev ifb0 parent 1: classid 1:1 htb rate 777kbit ceil 777kbit || return 1
 ! tc_limit_runtime_complete 3265
}
readonly_check() {
 reset_tree && ntc_action apply 1000 >/dev/null || return 1
 chmod 666 "$TRAFFICCOP_TC_STATE_FILE"
 bash "$work/ntc/trafficcop-lite.sh" --self-check eth0 >/dev/null 2>&1 || true
 [ "$(stat -c %a "$TRAFFICCOP_TC_STATE_FILE")" = 666 ]
}
reset_tree || exit 2
check overlap_rejected
check group_cleanup
check ntc_updates_ingress
check ntc_clears_ingress
check drift_detected
check readonly_check
printf 'compat regression: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
