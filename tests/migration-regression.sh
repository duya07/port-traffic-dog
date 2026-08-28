#!/bin/bash

set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MIGRATION_SCRIPT="$PROJECT_DIR/migrate-to-custom.sh"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap 'echo "migration regression failed at line $LINENO" >&2' ERR

create_mocks() {
    local case_dir="$1"
    mkdir -p "$case_dir/mockbin"

    cat > "$case_dir/mockbin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
url=""
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[ -n "$url" ] && [ -n "$out" ]
cp "$PTD_MIGRATION_PAYLOAD_DIR/${url##*/}" "$out"
EOF

    cat > "$case_dir/mockbin/crontab" <<'EOF'
#!/bin/bash
set -euo pipefail
case "${1:-}" in
    -l)
        [ -f "$PTD_MIGRATION_CRONTAB_FILE" ] || exit 1
        cat "$PTD_MIGRATION_CRONTAB_FILE"
        ;;
    -r)
        rm -f "$PTD_MIGRATION_CRONTAB_FILE"
        ;;
    "") exit 1 ;;
    *) cp "$1" "$PTD_MIGRATION_CRONTAB_FILE" ;;
esac
EOF

    cat > "$case_dir/mockbin/systemctl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$PTD_MIGRATION_SYSTEMCTL_LOG"
printf 'systemctl %s\n' "$*" >> "$PTD_MIGRATION_OPERATIONS_LOG"
case "${1:-}" in
    show) cat "$PTD_MIGRATION_SERVICE_STATE_FILE" ;;
    is-active) [ "$(cat "$PTD_MIGRATION_SERVICE_STATE_FILE")" = "active" ] ;;
    stop) printf '%s\n' inactive > "$PTD_MIGRATION_SERVICE_STATE_FILE" ;;
    start|restart) printf '%s\n' active > "$PTD_MIGRATION_SERVICE_STATE_FILE" ;;
    daemon-reload) exit 0 ;;
    *) exit 1 ;;
esac
EOF

    cat > "$case_dir/mockbin/nft" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'nft %s\n' "$*" >> "$PTD_MIGRATION_OPERATIONS_LOG"
if [ "${1:-}" = "list" ]; then
    printf '%s\n' 'table inet port_traffic_monitor {}'
fi
exit 0
EOF

    cat > "$case_dir/mockbin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

    chmod 755 "$case_dir/mockbin/"*
}

write_payloads() {
    local case_dir="$1"
    mkdir -p "$case_dir/payload"

    cat > "$case_dir/payload/port-traffic-dog.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
readonly SCRIPT_VERSION="test"
setup_traffic_snapshot_cron() { :; }
case "${1:-}" in
    --validate-config) jq empty "$2" ;;
    --refresh-all-cron)
        grep -v -- '--restore-runtime\|--restore-nft-runtime' "$PTD_MIGRATION_CRONTAB_FILE" \
            > "$PTD_MIGRATION_CRONTAB_FILE.tmp" || true
        printf '%s\n' \
            '@reboot /usr/local/bin/port-traffic-dog.sh --restore-nft-runtime >/dev/null 2>&1  # port-traffic-dog runtime restore' \
            >> "$PTD_MIGRATION_CRONTAB_FILE.tmp"
        mv "$PTD_MIGRATION_CRONTAB_FILE.tmp" "$PTD_MIGRATION_CRONTAB_FILE"
        ;;
    --repair-traffic-rules) exit 0 ;;
    --restore-runtime) [ "${PTD_MIGRATION_FAIL_RESTORE:-false}" != "true" ] ;;
    --self-check) exit 0 ;;
    --version) echo "端口流量狗 test" ;;
    *) exit 1 ;;
esac
EOF

    cat > "$case_dir/payload/telegram.sh" <<'EOF'
#!/bin/bash
telegram_send_status_notification() { :; }
EOF

    cat > "$case_dir/payload/wecom.sh" <<'EOF'
#!/bin/bash
wecom_send_status_notification() { :; }
EOF

    cat > "$case_dir/payload/port-ip-guard.sh" <<'EOF'
#!/bin/bash
# PORT_TRAFFIC_DOG_IP_GUARD
set -euo pipefail
case "${1:-}" in
    --validate-config)
        jq -e 'type == "object" and .schema == "port-traffic-dog-ip-guard-v1" and (.ports | type == "object")' "$2" >/dev/null
        ;;
    --self-check) [ "${PTD_MIGRATION_FAIL_GUARD_SELF_CHECK:-false}" != "true" ] ;;
    *) exit 1 ;;
esac
EOF
    chmod 755 "$case_dir/payload/"*.sh
}

render_migration_script() {
    local case_dir="$1"
    sed \
        -e "s#^INSTALLED_SCRIPT_PATH=.*#INSTALLED_SCRIPT_PATH=\"$case_dir/bin/port-traffic-dog.sh\"#" \
        -e "s#^DOG_PATH=.*#DOG_PATH=\"$case_dir/bin/dog\"#" \
        -e "s#^CONFIG_DIR=.*#CONFIG_DIR=\"$case_dir/config\"#" \
        -e "s#^IP_GUARD_SERVICE_FILE=.*#IP_GUARD_SERVICE_FILE=\"$case_dir/systemd/port-traffic-dog-ip-guard.service\"#" \
        -e "s#^BACKUP_DIR=.*#BACKUP_DIR=\"$case_dir/backups/\${timestamp}\"#" \
        "$MIGRATION_SCRIPT" > "$case_dir/migrate.sh"
    chmod 755 "$case_dir/migrate.sh"
}

prepare_case() {
    local name="$1"
    local with_existing="${2:-true}"
    local case_dir="$TEST_DIR/$name"
    mkdir -p "$case_dir/bin" "$case_dir/systemd"
    create_mocks "$case_dir"
    write_payloads "$case_dir"
    render_migration_script "$case_dir"
    : > "$case_dir/systemctl.log"
    : > "$case_dir/operations.log"
    printf '%s\n' inactive > "$case_dir/service.state"
    printf '%s\n' \
        '@reboot /usr/local/bin/port-traffic-dog.sh --restore-runtime >/dev/null 2>&1  # port-traffic-dog runtime restore' \
        '5 4 * * * /usr/local/bin/unrelated-job' > "$case_dir/crontab"

    if [ "$with_existing" = "true" ]; then
        mkdir -p "$case_dir/config/notifications"
        jq -n '{ports:{"3265":{enabled:true}},nftables:{family:"inet",table_name:"port_traffic_monitor"}}' \
            > "$case_dir/config/config.json"
        jq -n '{schema:"port-traffic-dog-ip-guard-v1",ports:{"3265":{max_ips:2}}}' \
            > "$case_dir/config/ip-guard.json"
        printf '%s\n' '#!/bin/bash' '# old ip guard' 'exit 0' > "$case_dir/config/port-ip-guard.sh"
        chmod 700 "$case_dir/config/port-ip-guard.sh"
        printf '%s\n' '#!/bin/bash' '# old main' 'exit 0' > "$case_dir/bin/port-traffic-dog.sh"
        printf '%s\n' '#!/bin/bash' '# old shortcut' 'exit 0' > "$case_dir/bin/dog"
        chmod 700 "$case_dir/bin/port-traffic-dog.sh" "$case_dir/bin/dog"
        printf '%s\n' \
            "ExecStart=$case_dir/config/port-ip-guard.sh --run" \
            "ExecStopPost=-$case_dir/config/port-ip-guard.sh --fail-open" \
            > "$case_dir/systemd/port-traffic-dog-ip-guard.service"
    fi

    printf '%s\n' "$case_dir"
}

run_migration() {
    local case_dir="$1"
    shift
    env \
        PATH="$case_dir/mockbin:$PATH" \
        PTD_MIGRATION_PAYLOAD_DIR="$case_dir/payload" \
        PTD_MIGRATION_CRONTAB_FILE="$case_dir/crontab" \
        PTD_MIGRATION_SYSTEMCTL_LOG="$case_dir/systemctl.log" \
        PTD_MIGRATION_SERVICE_STATE_FILE="$case_dir/service.state" \
        PTD_MIGRATION_OPERATIONS_LOG="$case_dir/operations.log" \
        PORT_TRAFFIC_DOG_CRON_LOCK_DIR="$case_dir/root-crontab.lock" \
        PORT_TRAFFIC_DOG_IP_GUARD_SYSTEMCTL=systemctl \
        "$@" \
        bash "$case_dir/migrate.sh"
}

# 活锁属于另一个仍存活的进程时必须拒绝迁移，且不能删除对方的锁。
lock_case=$(prepare_case live-lock false)
mkdir "$lock_case/root-crontab.lock"
boot_id=$(tr -d '\r\n' < /proc/sys/kernel/random/boot_id)
parent_start=$(awk '{print $22}' "/proc/$$/stat")
printf '%s %s %s %s\n' "$$" "$(date +%s)" "$boot_id" "$parent_start" \
    > "$lock_case/root-crontab.lock/owner"
cp "$lock_case/root-crontab.lock/owner" "$lock_case/live-owner.before"
if run_migration "$lock_case" \
    > "$lock_case/output" 2>&1; then
    echo "live cron lock unexpectedly accepted" >&2
    exit 1
fi
cmp -s "$lock_case/live-owner.before" "$lock_case/root-crontab.lock/owner"
[ ! -e "$lock_case/bin/port-traffic-dog.sh" ]

# 成功迁移要安装并复核 IP Guard；原服务 active 时必须重启并自检。
success_case=$(prepare_case success true)
printf '%s\n' active > "$success_case/service.state"
run_migration "$success_case" \
    > "$success_case/output" 2>&1
cmp -s "$success_case/payload/port-ip-guard.sh" "$success_case/config/port-ip-guard.sh"
[ "$(stat -c '%a' "$success_case/config/port-ip-guard.sh")" = "755" ]
grep -Fxq 'restart port-traffic-dog-ip-guard.service' "$success_case/systemctl.log"
grep -Fxq 'is-active --quiet port-traffic-dog-ip-guard.service' "$success_case/systemctl.log"
grep -Fq -- '--restore-nft-runtime' "$success_case/crontab"
! grep -Fq -- '--restore-runtime' "$success_case/crontab"
grep -Fq '迁移完成。' "$success_case/output"

# 覆盖后的维护命令失败时，旧 helper、权限、主脚本和快捷命令都要恢复。
rollback_case=$(prepare_case rollback true)
cp -a "$rollback_case/config/port-ip-guard.sh" "$rollback_case/old-helper"
cp -a "$rollback_case/bin/port-traffic-dog.sh" "$rollback_case/old-main"
cp -a "$rollback_case/bin/dog" "$rollback_case/old-dog"
printf '%s\n' active > "$rollback_case/service.state"
if run_migration "$rollback_case" PTD_MIGRATION_FAIL_RESTORE=true \
    > "$rollback_case/output" 2>&1; then
    echo "failed migration unexpectedly succeeded" >&2
    exit 1
fi
cmp -s "$rollback_case/old-helper" "$rollback_case/config/port-ip-guard.sh"
cmp -s "$rollback_case/old-main" "$rollback_case/bin/port-traffic-dog.sh"
cmp -s "$rollback_case/old-dog" "$rollback_case/bin/dog"
[ "$(stat -c '%a' "$rollback_case/config/port-ip-guard.sh")" = "700" ]
grep -Fxq 'stop port-traffic-dog-ip-guard.service' "$rollback_case/systemctl.log"
grep -Fxq 'start port-traffic-dog-ip-guard.service' "$rollback_case/systemctl.log"
grep -Fq '迁移失败，正在恢复迁移前状态' "$rollback_case/output"

# 首次安装失败时不得遗留主脚本、快捷命令或 IP Guard 配置目录。
first_case=$(prepare_case first-install false)
if run_migration "$first_case" PTD_MIGRATION_FAIL_RESTORE=true \
    > "$first_case/output" 2>&1; then
    echo "failed first migration unexpectedly succeeded" >&2
    exit 1
fi
[ ! -e "$first_case/config" ]
[ ! -e "$first_case/bin/port-traffic-dog.sh" ]
[ ! -e "$first_case/bin/dog" ]

# 新 helper 已重启但自检失败时，必须先停新服务、恢复旧 nft，再启动旧服务。
self_check_case=$(prepare_case guard-self-check true)
printf '%s\n' active > "$self_check_case/service.state"
if run_migration "$self_check_case" PTD_MIGRATION_FAIL_GUARD_SELF_CHECK=true \
    > "$self_check_case/output" 2>&1; then
    echo "guard self-check failure unexpectedly succeeded" >&2
    exit 1
fi
mapfile -t service_ops < <(grep -E '^(restart|stop|start) port-traffic-dog-ip-guard.service$' \
    "$self_check_case/systemctl.log")
[ "${service_ops[0]}" = 'restart port-traffic-dog-ip-guard.service' ]
[ "${service_ops[1]}" = 'stop port-traffic-dog-ip-guard.service' ]
[ "${service_ops[2]}" = 'start port-traffic-dog-ip-guard.service' ]
[ "$(cat "$self_check_case/service.state")" = active ]
stop_line=$(grep -n -m1 '^systemctl stop port-traffic-dog-ip-guard.service$' \
    "$self_check_case/operations.log" | cut -d: -f1)
nft_restore_line=$(grep -n -m1 '^nft -f .*nftables-table\.bak$' \
    "$self_check_case/operations.log" | cut -d: -f1)
start_line=$(grep -n -m1 '^systemctl start port-traffic-dog-ip-guard.service$' \
    "$self_check_case/operations.log" | cut -d: -f1)
[ "$stop_line" -lt "$nft_restore_line" ]
[ "$nft_restore_line" -lt "$start_line" ]

# 仅有 marker 的空壳候选必须在覆盖前被拒绝。
broken_case=$(prepare_case broken-candidate true)
printf '%s\n' active > "$broken_case/service.state"
printf '%s\n' '#!/bin/bash' '# PORT_TRAFFIC_DOG_IP_GUARD' 'exit 0' \
    > "$broken_case/payload/port-ip-guard.sh"
cp "$broken_case/config/port-ip-guard.sh" "$broken_case/helper.before"
if run_migration "$broken_case" > "$broken_case/output" 2>&1; then
    echo "broken guard candidate unexpectedly accepted" >&2
    exit 1
fi
cmp -s "$broken_case/helper.before" "$broken_case/config/port-ip-guard.sh"
grep -Fq 'IP Guard 组件配置校验接口不完整' "$broken_case/output"

echo "migration regression tests passed"
