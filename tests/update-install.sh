#!/bin/bash

set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCRIPT_FILE="$PROJECT_DIR/port-traffic-dog.sh"
readonly TEST_CONFIG_DIR="$TEST_DIR/config"
readonly TEST_INSTALL_PATH="$TEST_DIR/bin/port-traffic-dog.sh"
readonly PAYLOAD_ROOT="$TEST_DIR/payload"
readonly DOWNLOAD_COUNT_FILE="$TEST_DIR/download-count"
export PTD_UPDATE_TEST_MARKER="$TEST_DIR/finalized"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap 'echo "update install test failed at line $LINENO" >&2' ERR

mkdir -p "$TEST_CONFIG_DIR/logs" "$(dirname "$TEST_INSTALL_PATH")"
jq -n '{
    global: {billing_mode: "double"},
    ports: {},
    nftables: {table_name: "ptd_update_test", family: "inet"},
    notifications: {}
}' > "$TEST_CONFIG_DIR/config.json"

source <(sed \
    -e 's/^readonly SCRIPT_VERSION=.*/readonly SCRIPT_VERSION="1.5.9"/' \
    -e "s#^readonly INSTALLED_SCRIPT_PATH=.*#readonly INSTALLED_SCRIPT_PATH=\"$TEST_INSTALL_PATH\"#" \
    -e "s#^readonly CONFIG_DIR=.*#readonly CONFIG_DIR=\"$TEST_CONFIG_DIR\"#" \
    -e "s#^readonly SHORTCUT_COMMAND=.*#readonly SHORTCUT_COMMAND=\"ptd-update-test-$BASHPID\"#" \
    -e '$d' \
    "$SCRIPT_FILE")

create_payload() {
    local version="$1"
    rm -rf "$PAYLOAD_ROOT"
    mkdir -p "$PAYLOAD_ROOT"
    cat > "$PAYLOAD_ROOT/port-traffic-dog.sh" <<EOF
#!/bin/bash
set -euo pipefail
readonly SCRIPT_VERSION="$version"
readonly SCRIPT_NAME="端口流量狗"
case "\${1:-}" in
    --validate-config) jq empty "\$2" ;;
    --finalize-update) printf 'finalized\n' > "\$PTD_UPDATE_TEST_MARKER" ;;
    --version) echo "端口流量狗 v\$SCRIPT_VERSION" ;;
    --restore-runtime) exit 0 ;;
    *) exit 1 ;;
esac
EOF
    printf '%s\n' '#!/bin/bash' 'telegram_fixture() { :; }' > "$PAYLOAD_ROOT/telegram.sh"
    printf '%s\n' '#!/bin/bash' 'wecom_fixture() { :; }' > "$PAYLOAD_ROOT/wecom.sh"
}

printf '%s\n' '#!/bin/bash' 'exit 0' > "$TEST_INSTALL_PATH"
chmod 755 "$TEST_INSTALL_PATH"

check_dependencies() { :; }
init_config() { :; }
record_traffic_snapshot() { :; }
has_active_ports() { return 1; }
save_traffic_data() { :; }
read_current_crontab() { printf '%s\n' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'; }
create_shortcut_command() { :; }
download_with_sources() {
    local output_file="$2"
    local count=0
    [ -f "$DOWNLOAD_COUNT_FILE" ] && count=$(cat "$DOWNLOAD_COUNT_FILE")
    printf '%s\n' "$((count + 1))" > "$DOWNLOAD_COUNT_FILE"
    printf 'fixture archive\n' > "$output_file"
}
unzip() {
    cp -a "$PAYLOAD_ROOT" "$PWD/port-traffic-dog-main"
}

create_payload 1.5.10
: > "$DOWNLOAD_COUNT_FILE"
install_update_script false > "$TEST_DIR/update.out"
[ "$(cat "$DOWNLOAD_COUNT_FILE")" -eq 1 ]
[ -f "$PTD_UPDATE_TEST_MARKER" ]
[ "$(bash "$TEST_INSTALL_PATH" --version)" = "端口流量狗 v1.5.10" ]
cmp -s "$PAYLOAD_ROOT/telegram.sh" "$TEST_CONFIG_DIR/notifications/telegram.sh"
cmp -s "$PAYLOAD_ROOT/wecom.sh" "$TEST_CONFIG_DIR/notifications/wecom.sh"
grep -Fq '版本: v1.5.9 -> v1.5.10' "$TEST_DIR/update.out"

create_payload 1.5.8
: > "$DOWNLOAD_COUNT_FILE"
if install_update_script false > "$TEST_DIR/downgrade.out"; then
    echo "downgrade was not rejected" >&2
    exit 1
fi
[ "$(cat "$DOWNLOAD_COUNT_FILE")" -eq 1 ]
[ "$(bash "$TEST_INSTALL_PATH" --version)" = "端口流量狗 v1.5.10" ]
grep -Fq '已拒绝降级' "$TEST_DIR/downgrade.out"

echo "update install integration test passed"
