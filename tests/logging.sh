#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export PORT_TRAFFIC_DOG_LOG_FILE="$WORK/logs/traffic.log"
export PORT_TRAFFIC_DOG_CONFIG_LOCK_DIR="$WORK/config.lock"
# The product's final main call must never execute in this function-only test.
# Function-only source generated from the trusted product script.
# shellcheck disable=SC1090
source <(sed -e "s#^readonly CONFIG_DIR=.*#readonly CONFIG_DIR=\"$WORK/config\"#" -e '$d' "$ROOT/port-traffic-dog.sh")

dog_log_event tc_apply 0 port=443 rate=2mbit
[ "$(stat -c %a "$LOG_FILE")" = 600 ]
[ "$(stat -c %a "$(dirname "$LOG_FILE")")" = 700 ]
grep -Eq 'event=tc_apply result=0 port=443 rate=2mbit$' "$LOG_FILE"
grep -q '应用端口带宽限制：成功' "$LOG_FILE"
dog_log_event $'bad\nevent' 0 'token=NEVER_STORE_THIS' >/dev/null 2>&1
if grep -Eq 'bad|NEVER_STORE_THIS|token=' "$LOG_FILE"; then exit 1; fi

mkdir -p "$CONFIG_DIR"
printf '%s\n' '{"ports":{}}' > "$CONFIG_FILE"
update_config_file '.ports["443"] = {enabled:true} | .token = "DO_NOT_STORE_THIS"'
grep -q 'event=config_update result=0' "$LOG_FILE"
if grep -q DO_NOT_STORE_THIS "$LOG_FILE"; then exit 1; fi
before_lines=$(wc -l < "$LOG_FILE")
update_config_file '.'
[ "$(wc -l < "$LOG_FILE")" = "$before_lines" ]
before_hash=$(sha256sum "$CONFIG_FILE")
if update_config_file 'invalid[' >/dev/null 2>&1; then exit 1; fi
[ "$(sha256sum "$CONFIG_FILE")" = "$before_hash" ]
grep -q 'event=config_update result=1' "$LOG_FILE"

python3 - "$LOG_FILE" <<'PY'
import sys
with open(sys.argv[1], 'ab') as output:
    output.write(b'x' * 1048576)
PY
dog_log_event rotation 0
[ -s "$LOG_FILE.1" ]
[ "$(stat -c %s "$LOG_FILE")" -lt 4096 ]
(
    # Called by dog_log_event loaded from the product script.
    # shellcheck disable=SC2317
    dog_write_event() { return 1; }
    dog_log_event io_failure 1 2> "$WORK/io.err"
)
grep -q '日志' "$WORK/io.err"

# Actual TC wrappers preserve failure codes and record results, with no real TC.
begin_tc_update() { :; }
finish_tc_update() { :; }
get_default_interface() { echo test0; }
rollback_legacy_trafficcop_tbf() { :; }
# Called by the actual apply_tc_limit wrapper loaded above.
# shellcheck disable=SC2317
apply_tc_limit_locked() { return 7; }
if apply_tc_limit 443 2mbit; then exit 1; else [ "$?" = 7 ]; fi
grep -q 'event=tc_apply result=7 port=443' "$LOG_FILE"
apply_tc_limit_locked() { return 0; }
apply_tc_limit 443 2mbit
grep -q 'event=tc_apply result=0 port=443' "$LOG_FILE"

readonly_absent="$WORK/absent/logs/traffic.log"
PORT_TRAFFIC_DOG_LOG_FILE="$readonly_absent" bash "$ROOT/port-traffic-dog.sh" --logs > "$WORK/view.out"
[ ! -e "$WORK/absent" ]
echo 'Dog operation logging tests passed'
