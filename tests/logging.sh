#!/bin/bash
# Dog 2.0 操作日志：权限、字段白名单、敏感值不落盘、轮转、写失败不改变业务返回码、--logs 只读。
# 只 source 函数，状态全部在临时目录；不调用 nft/tc/crontab。
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export PORT_TRAFFIC_DOG_CONFIG_DIR="$WORK/config"
export PORT_TRAFFIC_DOG_LOCK_FILE="$WORK/dog.lock"
export PORT_TRAFFIC_DOG_LOG_FILE="$WORK/logs/traffic.log"
export NO_COLOR=1
# shellcheck disable=SC1090
source <(sed '$d' "$ROOT/port-traffic-dog.sh")

dog_log_event tc_apply 0 id=m3 port=443 rate=2mbit
[ "$(stat -c %a "$LOG_FILE")" = 600 ]
[ "$(stat -c %a "$(dirname "$LOG_FILE")")" = 700 ]
grep -Eq 'event=tc_apply result=0$' "$LOG_FILE"
grep -q ' id=m3 port=443 rate=2mbit ' "$LOG_FILE"
grep -q '应用带宽限制：成功' "$LOG_FILE"
# 非法事件名与非白名单字段一律丢弃。
dog_log_event $'bad\nevent' 0 'token=NEVER_STORE_THIS' >/dev/null 2>&1
dog_log_event tc_apply 0 'token=NEVER_STORE_THIS' 'id=../../x' >/dev/null 2>&1
if grep -Eq 'bad|NEVER_STORE_THIS|token=|\.\./' "$LOG_FILE"; then exit 1; fi

# config_update：成功记 0；内容不变不写不记；无效配置记 1 且文件不变；值不进日志。
mkdir -p "$CONFIG_DIR"
default_config_json > "$CONFIG_FILE"
config_update '.global.data_retention_days = 123 | .notifications.telegram.bot_token = "DO_NOT_STORE_THIS"'
grep -q 'event=config_update result=0' "$LOG_FILE"
if grep -q DO_NOT_STORE_THIS "$LOG_FILE"; then exit 1; fi
before_lines=$(wc -l < "$LOG_FILE")
before_hash=$(sha256sum "$CONFIG_FILE")
config_update '.'
[ "$(wc -l < "$LOG_FILE")" = "$before_lines" ]
[ "$(sha256sum "$CONFIG_FILE")" = "$before_hash" ]
if config_update '.schema = 7' >/dev/null 2>&1; then exit 1; fi
[ "$(sha256sum "$CONFIG_FILE")" = "$before_hash" ]
grep -q 'event=config_update result=1' "$LOG_FILE"
if config_update 'invalid[' >/dev/null 2>&1; then exit 1; fi
[ "$(sha256sum "$CONFIG_FILE")" = "$before_hash" ]

# 轮转：超过 1 MiB 时滚动到 .1。
python3 - "$LOG_FILE" <<'PY'
import sys
with open(sys.argv[1], 'ab') as output:
    output.write(b'x' * 1048576)
PY
dog_log_event install 0
[ -s "$LOG_FILE.1" ]
[ "$(stat -c %s "$LOG_FILE")" -lt 4096 ]

# 日志写失败只告警，不改变返回码。
(
    # shellcheck disable=SC2317
    dog_write_event() { return 1; }
    dog_log_event io_failure 1 2> "$WORK/io.err"
)
grep -q '日志' "$WORK/io.err"

# --logs 只读：不创建配置目录与日志目录。
absent="$WORK/absent"
PORT_TRAFFIC_DOG_CONFIG_DIR="$absent" PORT_TRAFFIC_DOG_LOG_FILE="$absent/logs/traffic.log" \
    bash "$ROOT/port-traffic-dog.sh" --logs > "$WORK/view.out"
[ ! -e "$absent" ]
grep -q '暂无日志' "$WORK/view.out"
echo 'Dog operation logging tests passed'
