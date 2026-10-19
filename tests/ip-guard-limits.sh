#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export PTD_IP_GUARD_CONFIG_DIR="$TEST_DIR"
export PTD_IP_GUARD_CONFIG_FILE="$TEST_DIR/config.json"
passed=0
failed=0
check() {
    if "$@"; then passed=$((passed+1)); printf 'PASS %s\n' "$*";
    else failed=$((failed+1)); printf 'FAIL %s\n' "$*"; fi
}
valid() { printf '%s\n' "$1" > "$TEST_DIR/config.json"; bash "$ROOT/port-ip-guard.sh" --validate-config "$TEST_DIR/config.json"; }
invalid() { ! valid "$1" >/dev/null 2>&1; }
check valid '{"schema":"port-traffic-dog-ip-guard-v1","ports":{"43871":{"max_ips":2,"idle_timeout":2}}}'
check valid '{"schema":"port-traffic-dog-ip-guard-v1","ports":{"43871":{"max_ips":0,"max_connections":2,"idle_timeout":0}}}'
check valid '{"schema":"port-traffic-dog-ip-guard-v1","ports":{"43871":{"max_ips":2,"max_connections":0}}}'
check valid '{"schema":"port-traffic-dog-ip-guard-v1","ports":{"43871":{"max_ips":0,"max_connections":0}}}'
check invalid '{"schema":"port-traffic-dog-ip-guard-v1","ports":{"43871":{"max_ips":2,"max_connections":-1}}}'
check invalid '{"schema":"port-traffic-dog-ip-guard-v1","ports":{"43871":{"max_ips":2,"max_connections":1.5}}}'
check invalid '{"schema":"port-traffic-dog-ip-guard-v1","ports":{"43871":{"max_ips":true,"max_connections":2}}}'
first_syn_rule() {
    printf '%s\n' '{"schema":"port-traffic-dog-ip-guard-v1","ports":{"43871":{"max_ips":2}}}' > "$TEST_DIR/config.json"
    bash "$ROOT/port-ip-guard.sh" --render-rules > "$TEST_DIR/rules"
    grep -Eq 'tcp dport 43871 .*queue num [0-9]+ bypass' "$TEST_DIR/rules" &&
        ! grep -Eq 'tcp dport 43871 drop' "$TEST_DIR/rules"
}
check first_syn_rule
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
