begin_tc_update() {
    if [ "$TC_SHARED_LOCK_DEPTH" -gt 0 ]; then
        TC_SHARED_LOCK_DEPTH=$((TC_SHARED_LOCK_DEPTH + 1))
        return 0
    fi

    mkdir -p "$(dirname "$TC_SHARED_LOCK_FILE")" || return 1
    exec 9>"$TC_SHARED_LOCK_FILE" || return 1
    if ! flock -w 15 9; then
        exec 9>&-
        return 1
    fi
    TC_SHARED_LOCK_DEPTH=1
    TC_UPDATE_MIGRATED_LEGACY_TBF=false
    TC_UPDATE_LEGACY_TBF_RATE=""
}

finish_tc_update() {
    [ "$TC_SHARED_LOCK_DEPTH" -gt 0 ] || return 0
    TC_SHARED_LOCK_DEPTH=$((TC_SHARED_LOCK_DEPTH - 1))
    if [ "$TC_SHARED_LOCK_DEPTH" -eq 0 ]; then
        TC_UPDATE_MIGRATED_LEGACY_TBF=false
        TC_UPDATE_LEGACY_TBF_RATE=""
        flock -u 9 2>/dev/null || true
        exec 9>&-
    fi
}

# 端口段与端口组走同一条 TC 限速路径：nft 侧按端口打 meta mark，tc 侧用一条 fw
# 过滤器按 mark 归入同一个 class。单端口则走 u32/flower 精确匹配。
# 组内成员既可以是单端口也可以是端口段，靠 port_selectors 逐条展开。

# burst速率突发计算
# 注意：不要照搬上游的 10ms/64KB 公式。burst 是相对 class **rate** 的桶，而本项目
# 端口类的 rate 固定为 TC_PORT_CLASS_RATE(1kbit)、只有 ceil 承载限速值，内核会按 rate
# 归一化 burst（实测：rate 1kbit 下传 6250000 显示 6Kb、传 64k 显示 31176b；rate 500Mbit
# 下传 6250000 则原样显示）。上游用 rate=ceil=限速值 的结构，其公式在这里不适用，照搬
# 反而会让高速率下的实际突发从 6Kb 变成 31176b，比原来更宽松。
calculate_tc_burst() {
    local base_rate=$1
    local rate_bytes_per_sec=$((base_rate * 1000 / 8))
    local burst_by_formula=$((rate_bytes_per_sec / 20))  # 50ms缓冲
    local min_burst=$((2 * 1500))                        # 2个MTU最小值

    if [ $burst_by_formula -gt $min_burst ]; then
        echo $burst_by_formula
    else
        echo $min_burst
    fi
}

format_tc_burst() {
    local burst_bytes=$1
    if [ $burst_bytes -lt 1024 ]; then
        echo "${burst_bytes}"
    elif [ $burst_bytes -lt 1048576 ]; then
        echo "$((burst_bytes / 1024))k"
    else
        echo "$((burst_bytes / 1048576))m"
    fi
}

parse_tc_rate_to_kbps() {
    local total_limit="$1"
    case "$total_limit" in
        *gbit) echo $(( ${total_limit%gbit} * 1000000 )) ;;
        *mbit) echo $(( ${total_limit%mbit} * 1000 )) ;;
        *) echo "${total_limit%kbit}" ;;
    esac
}

# 将用户输入的带宽值(Kbps/Mbps/Gbps)转换为TC格式(kbit/mbit/gbit)

# Dog 与 NTC 共用同一个恢复入口和同一个 systemd oneshot，避免两边各自抢 root。
tc_recovery_systemd_available() {
    command -v "$TC_RECOVERY_SYSTEMCTL" >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

tc_recovery_unit_is_owned() {
    [ -f "$TC_RECOVERY_UNIT_FILE" ] &&
        grep -Fqx '# traffic-tools-tc-recovery-v1' "$TC_RECOVERY_UNIT_FILE" 2>/dev/null
}

tc_recovery_runner_is_owned() {
    [ -f "$TC_RECOVERY_RUNNER" ] &&
        grep -Fqx '# traffic-tools-tc-recovery-v1' "$TC_RECOVERY_RUNNER" 2>/dev/null
}

install_tc_recovery_service_files() {
    local runner_dir unit_dir runner_tmp unit_tmp
    runner_dir=$(dirname "$TC_RECOVERY_RUNNER")
    unit_dir=$(dirname "$TC_RECOVERY_UNIT_FILE")
    runner_tmp="${TC_RECOVERY_RUNNER}.tmp.$$"
    unit_tmp="${TC_RECOVERY_UNIT_FILE}.tmp.$$"

    if [ -e "$TC_RECOVERY_RUNNER" ] && ! tc_recovery_runner_is_owned; then
        echo "共享 TC 恢复入口已被其他文件占用: $TC_RECOVERY_RUNNER" >&2
        return 1
    fi
    if [ -e "$TC_RECOVERY_UNIT_FILE" ] && ! tc_recovery_unit_is_owned; then
        echo "共享 TC 恢复服务名已被其他 unit 占用: $TC_RECOVERY_UNIT_FILE" >&2
        return 1
    fi
    mkdir -p "$runner_dir" || return 1
    if ! cat > "$runner_tmp" <<'EOF'
#!/bin/bash
# traffic-tools-tc-recovery-v1
set -euo pipefail

mode="${1:---auto}"
case "$mode" in
    --auto|--manual) ;;
    *) echo "usage: $0 [--auto|--manual]" >&2; exit 2 ;;
esac

dog_script=/usr/local/bin/port-traffic-dog.sh
dog_config=/etc/port-traffic-dog/config.json
ntc_monitor=/etc/trafficcop-lite/trafficcop-lite-monitor.sh
ntc_config=/etc/trafficcop-lite/traffic_monitor_config.txt
handled=false
result=0

# 入口在而配置不可读属于异常：必须报出来，不能静默跳过恢复。
# 此模板由 dog 与 ntc 共用，两边必须逐字一致，否则后运行的一方会覆盖先运行的一方。
if [ -r "$dog_script" ]; then
    if [ -r "$dog_config" ]; then
        bash "$dog_script" --recover-tc "$mode" || result=1
    else
        echo "port-traffic-dog 已安装但配置不可读，跳过 TC 恢复: $dog_config" >&2
        result=1
    fi
    handled=true
fi
if [ -r "$ntc_monitor" ]; then
    if [ -r "$ntc_config" ]; then
        bash "$ntc_monitor" --tc-recover-owned "$mode" || result=1
    else
        echo "trafficcop-lite 已安装但配置不可读，跳过 TC 恢复: $ntc_config" >&2
        result=1
    fi
    handled=true
fi

$handled || exit 0
exit "$result"
EOF
    then
        rm -f "$runner_tmp"
        return 1
    fi
    chmod 755 "$runner_tmp" || { rm -f "$runner_tmp"; return 1; }
    if ! cmp -s "$runner_tmp" "$TC_RECOVERY_RUNNER"; then
        mv -f "$runner_tmp" "$TC_RECOVERY_RUNNER" || { rm -f "$runner_tmp"; return 1; }
    else
        rm -f "$runner_tmp"
    fi

    tc_recovery_systemd_available || return 0
    mkdir -p "$unit_dir" || return 1
    if ! cat > "$unit_tmp" <<EOF
# traffic-tools-tc-recovery-v1
[Unit]
Description=Recover Dog and TrafficCop Lite unified HTB
Wants=network-online.target
After=network-online.target vnstat.service

[Service]
Type=oneshot
ExecStart=$TC_RECOVERY_RUNNER --auto

[Install]
WantedBy=multi-user.target
EOF
    then
        rm -f "$unit_tmp"
        return 1
    fi
    chmod 644 "$unit_tmp" || { rm -f "$unit_tmp"; return 1; }
    if ! cmp -s "$unit_tmp" "$TC_RECOVERY_UNIT_FILE"; then
        mv -f "$unit_tmp" "$TC_RECOVERY_UNIT_FILE" || { rm -f "$unit_tmp"; return 1; }
    else
        rm -f "$unit_tmp"
    fi
    "$TC_RECOVERY_SYSTEMCTL" daemon-reload >/dev/null 2>&1
}

tc_auto_recovery_state() {
    if ! tc_recovery_systemd_available; then
        echo "不可用（当前系统未运行 systemd）"
    elif [ -e "$TC_RECOVERY_UNIT_FILE" ] && ! tc_recovery_unit_is_owned; then
        echo "冲突（同名 unit 不属于 Dog/NTC）"
    elif [ -e "$TC_RECOVERY_RUNNER" ] && ! tc_recovery_runner_is_owned; then
        echo "冲突（恢复入口不属于 Dog/NTC）"
    elif [ -e "$TC_RECOVERY_UNIT_FILE" ] && [ ! -e "$TC_RECOVERY_RUNNER" ]; then
        echo "损坏（恢复入口缺失）"
    elif [ ! -e "$TC_RECOVERY_UNIT_FILE" ]; then
        echo "未启用"
    elif "$TC_RECOVERY_SYSTEMCTL" is-enabled --quiet "$TC_RECOVERY_SERVICE" 2>/dev/null; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

enable_tc_auto_recovery() {
    tc_recovery_systemd_available || {
        echo -e "${RED}当前系统未运行 systemd，无法启用开机自动恢复。${NC}"
        return 1
    }
    install_tc_recovery_service_files || return 1
    "$TC_RECOVERY_SYSTEMCTL" enable "$TC_RECOVERY_SERVICE" >/dev/null
}

disable_tc_auto_recovery() {
    tc_recovery_systemd_available || return 0
    [ ! -e "$TC_RECOVERY_UNIT_FILE" ] && return 0
    if ! tc_recovery_unit_is_owned; then
        echo "同名恢复 unit 不属于 Dog/NTC，拒绝停用: $TC_RECOVERY_UNIT_FILE" >&2
        return 1
    fi
    "$TC_RECOVERY_SYSTEMCTL" disable "$TC_RECOVERY_SERVICE" >/dev/null 2>&1
}

cleanup_tc_recovery_files_if_unused() {
    if { [ -r /usr/local/bin/port-traffic-dog.sh ] && [ -r /etc/port-traffic-dog/config.json ]; } ||
       { [ -r /etc/trafficcop-lite/trafficcop-lite-monitor.sh ] && [ -r /etc/trafficcop-lite/traffic_monitor_config.txt ]; }; then
        return 0
    fi
    if [ -e "$TC_RECOVERY_UNIT_FILE" ]; then
        if ! tc_recovery_unit_is_owned; then
            echo "同名恢复 unit 不属于 Dog/NTC，已保留且未调用 systemctl: $TC_RECOVERY_UNIT_FILE" >&2
            return 1
        fi
        if tc_recovery_systemd_available; then
            "$TC_RECOVERY_SYSTEMCTL" disable --now "$TC_RECOVERY_SERVICE" >/dev/null 2>&1 || return 1
        fi
        rm -f "$TC_RECOVERY_UNIT_FILE" || return 1
    fi
    if tc_recovery_runner_is_owned; then
        rm -f "$TC_RECOVERY_RUNNER" || return 1
    fi
    if tc_recovery_systemd_available; then
        "$TC_RECOVERY_SYSTEMCTL" daemon-reload >/dev/null 2>&1 || return 1
    fi
}

dog_tc_status_label() {
    local status_output=""
    status_output=$(dog_tc_status 2>/dev/null || true)
    case "$status_output" in
        TC_STATUS=OK*) echo "正常" ;;
        TC_STATUS=IDLE*) echo "空闲" ;;
        *REASON=external-root-qdisc*) echo "冲突（外部/未知 TC）" ;;
        TC_STATUS=CONFLICT*) echo "异常（自身规则已失效）" ;;
        *) echo "无法检测" ;;
    esac
}

dog_tc_status_kind() {
    case "${1:-}" in
        TC_STATUS=OK*) echo "ok" ;;
        TC_STATUS=IDLE*) echo "idle" ;;
        TC_STATUS=CONFLICT*) echo "conflict" ;;
        *) echo "error" ;;
    esac
}

show_tc_takeover_warning() {
    echo -e "${RED}检测到当前 TC 配置可能已被其他程序修改。${NC}"
    echo "继续操作将删除当前冲突的 TC/qdisc 配置，"
    echo "并只重新建立 Dog/NTC 体系自身管理的规则。"
    echo "其他程序创建的 TC 配置不会被保留。"
    echo
    echo -e "${YELLOW}如果其他 TC 管理脚本或服务仍然存在，其之后再次启动或重启时，"
    echo -e "仍可能覆盖 Dog/NTC。建议卸载、关闭或禁用这些冲突程序。${NC}"
}

show_tc_auto_recovery_notice() {
    echo "启用后，恢复服务会在开机网络就绪时检查 Dog/NTC TC 规则。"
    echo "规则正常或当前没有需要恢复的规则时，不会修改 TC。"
    echo "自动恢复只会在 root qdisc 为空闲/默认状态时恢复已有 Dog/NTC 规则。"
    echo "检测到外部或未知 TC 时不会自动删除；必须由用户确认后手动重建。"
}

confirm_enable_tc_auto_recovery() {
    local confirm=""

    show_tc_auto_recovery_notice
    echo
    read -r -p "确认启用请输入 ENABLE: " confirm
    if [ "$confirm" != "ENABLE" ]; then
        echo "未启用。"
        return 0
    fi
    if enable_tc_auto_recovery; then
        echo -e "${GREEN}开机自动恢复已启用。${NC}"
    else
        echo -e "${RED}开机自动恢复启用失败。${NC}"
        return 1
    fi
}

run_shared_tc_recovery() {
    local mode="${1:---manual}"
    install_tc_recovery_service_files || return 1
    bash "$TC_RECOVERY_RUNNER" "$mode"
}

manage_tc_recovery() {
    local tc_choice=""
    local confirm=""
    local status_output=""
    local status_kind=""

    menu_clear
    ui_title "TC 冲突处理 / 自动恢复"
    ui_kv "TC 状态" "$(dog_tc_status_label)"
    ui_kv "自动恢复" "$(tc_auto_recovery_state)"
    ui_kv "恢复方式" "单一 systemd oneshot；启用后在网络就绪时执行一次"
    echo
    ui_option 1 "检测并按需重建 Dog/NTC 规则"
    ui_option 2 "检测并按需重建，同时启用开机自动恢复"
    ui_option 3 "启用开机自动恢复"
    ui_option 4 "关闭开机自动恢复"
    ui_option 0 "返回主菜单"
    ui_prompt 4 tc_choice || return 0
    case "$tc_choice" in
        1|2)
            status_output=$(dog_tc_status 2>/dev/null || true)
            status_kind=$(dog_tc_status_kind "$status_output")
            case "$status_kind" in
                ok)
                    echo -e "${GREEN}当前 TC 状态正常，无需强制重建。${NC}"
                    if [ "$tc_choice" = "2" ]; then
                        echo
                        confirm_enable_tc_auto_recovery || true
                    fi
                    ;;
                idle)
                    echo -e "${YELLOW}当前没有需要恢复的 Dog/NTC TC 规则。${NC}"
                    if [ "$tc_choice" = "2" ]; then
                        echo
                        confirm_enable_tc_auto_recovery || true
                    fi
                    ;;
                conflict)
                    show_tc_takeover_warning
                    echo
                    read -r -p "确认继续请输入 REBUILD: " confirm
                    if [ "$confirm" = "REBUILD" ] && run_shared_tc_recovery --manual; then
                        echo -e "${GREEN}TC 检测/重建完成。${NC}"
                        if [ "$tc_choice" = "2" ]; then
                            if enable_tc_auto_recovery; then
                                echo -e "${GREEN}开机自动恢复已启用。${NC}"
                            else
                                echo -e "${RED}TC 已重建，但开机自动恢复启用失败。${NC}"
                            fi
                        fi
                    elif [ "$confirm" != "REBUILD" ]; then
                        echo "已取消。"
                    else
                        echo -e "${RED}TC 重建失败，请运行 dog --self-check 查看详情。${NC}"
                    fi
                    ;;
                *)
                    echo -e "${RED}无法确认当前 TC 状态，未修改 qdisc。请先运行 dog --self-check。${NC}"
                    ;;
            esac
            ;;
        3)
            confirm_enable_tc_auto_recovery || true
            ;;
        4)
            if disable_tc_auto_recovery; then
                echo -e "${GREEN}开机自动恢复已关闭。${NC}"
            else
                echo -e "${RED}开机自动恢复关闭失败；现有启用状态未被确认改变。${NC}"
            fi
            ;;
        0|"") return 0 ;;
        *) echo -e "${RED}无效选择。${NC}" ;;
    esac
}

get_tc_root_owner_file() {
    echo "$CONFIG_DIR/tc-root-qdisc.owner"
}

mark_tc_root_owned() {
    local interface="$1"
    local machine_id=""
    [ -r /etc/machine-id ] && machine_id=$(tr -d '\r\n' < /etc/machine-id)
    local owner_file
    owner_file=$(get_tc_root_owner_file)
    # 归属标记写不进去就必须报出来：调用方靠它区分“自己的 HTB”和“别人的 HTB”。
    printf '%s|%s\n' "$interface" "$machine_id" > "$owner_file" || return 1
    chmod 600 "$owner_file" 2>/dev/null || true
}

tc_root_owner_marker_matches() {
    local interface="$1"
    local owner_file
    owner_file=$(get_tc_root_owner_file)
    [ -f "$owner_file" ] || return 1
    local recorded_interface recorded_machine_id machine_id=""
    IFS='|' read -r recorded_interface recorded_machine_id < "$owner_file" || return 1
    [ -r /etc/machine-id ] && machine_id=$(tr -d '\r\n' < /etc/machine-id)
    [ "$recorded_interface" = "$interface" ] && [ "$recorded_machine_id" = "$machine_id" ]
}

tc_state_file_is_secure() {
    local state_file="$1"
    local owner_uid
    local mode

    [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
    owner_uid=$(stat -c '%u' "$state_file" 2>/dev/null) || return 1
    [ "$owner_uid" = "$(id -u)" ] || return 1
    mode=$(stat -c '%a' "$state_file" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ $((8#$mode & 8#022)) -eq 0 ]
}

tc_state_unique_value() {
    local state_file="$1"
    local key="$2"
    local count
    count=$(grep -Ec "^${key}=" "$state_file" 2>/dev/null || true)
    [ "$count" -eq 1 ] || return 1
    grep "^${key}=" "$state_file" | cut -d'=' -f2-
}

tc_state_optional_unique_value() {
    local state_file="$1"
    local key="$2"
    local count
    count=$(grep -Ec "^${key}=" "$state_file" 2>/dev/null || true)
    [ "$count" -le 1 ] || return 1
    if [ "$count" -eq 1 ]; then
        grep "^${key}=" "$state_file" | cut -d'=' -f2-
    fi
    return 0
}

# 仅在 NTC 状态存在时读取其启用状态；配置缺失视为旧版/独立状态，异常配置则拒绝使用状态。
# 返回值：0=已禁用；1=未禁用或配置不存在；2=配置无法安全解释。
trafficcop_config_is_disabled() {
    local disabled

    [ -e "$TRAFFICCOP_CONFIG_FILE" ] || return 1
    tc_state_file_is_secure "$TRAFFICCOP_CONFIG_FILE" || return 2
    disabled=$(tc_state_optional_unique_value "$TRAFFICCOP_CONFIG_FILE" "DISABLED") || return 2
    case "$disabled" in
        true) return 0 ;;
        ""|false) return 1 ;;
        *) return 2 ;;
    esac
}

# 返回值：0=当前接口存在有效统一限速；1=无状态；2=状态无效；3=旧版状态；
# 4=其他接口；5=NTC 已明确禁用，残留状态不再授权恢复整机上限。
trafficcop_unified_state_rate() {
    local interface="$1"
    local schema
    local provider
    local state_interface
    local speed

    [ -e "$TRAFFICCOP_TC_STATE_FILE" ] || return 1
    local disabled_status=0
    trafficcop_config_is_disabled || disabled_status=$?
    case "$disabled_status" in
        0) return 5 ;;
        1) ;;
        *) return 2 ;;
    esac
    tc_state_file_is_secure "$TRAFFICCOP_TC_STATE_FILE" || return 2
    if ! schema=$(tc_state_unique_value "$TRAFFICCOP_TC_STATE_FILE" "SCHEMA" 2>/dev/null); then
        if ! grep -q '^SCHEMA=' "$TRAFFICCOP_TC_STATE_FILE" 2>/dev/null; then
            return 3
        fi
        return 2
    fi
    [ "$schema" = "$TC_INTEROP_SCHEMA" ] || return 2
    provider=$(tc_state_unique_value "$TRAFFICCOP_TC_STATE_FILE" "PROVIDER") || return 2
    [ "$provider" = "trafficcop-lite" ] || return 2
    state_interface=$(tc_state_unique_value "$TRAFFICCOP_TC_STATE_FILE" "INTERFACE") || return 2
    [[ "$state_interface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 2
    speed=$(tc_state_unique_value "$TRAFFICCOP_TC_STATE_FILE" "LIMIT_SPEED") || return 2
    [[ "$speed" =~ ^[1-9][0-9]*$ ]] || return 2
    [ "$state_interface" = "$interface" ] || return 4
    printf '%skbit\n' "$speed"
}

trafficcop_legacy_state_rate() {
    local interface="$1"
    local provider
    local state_interface
    local speed

    [ -e "$TRAFFICCOP_TC_STATE_FILE" ] || return 1
    tc_state_file_is_secure "$TRAFFICCOP_TC_STATE_FILE" || return 1
    ! grep -q '^SCHEMA=' "$TRAFFICCOP_TC_STATE_FILE" 2>/dev/null || return 1
    provider=$(tc_state_optional_unique_value "$TRAFFICCOP_TC_STATE_FILE" "PROVIDER") || return 1
    [ -z "$provider" ] || [ "$provider" = "trafficcop-lite" ] || return 1
    state_interface=$(tc_state_unique_value "$TRAFFICCOP_TC_STATE_FILE" "INTERFACE") || return 1
    [ "$state_interface" = "$interface" ] || return 1
    speed=$(tc_state_unique_value "$TRAFFICCOP_TC_STATE_FILE" "LIMIT_SPEED") || return 1
    [[ "$speed" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%skbit\n' "$speed"
}

tc_rate_from_qdisc_line() {
    local qdisc_line="$1"
    printf '%s\n' "$qdisc_line" |
        awk '{for (i=1; i<=NF; i++) if ($i == "rate") {print $(i+1); exit}}'
}

trafficcop_legacy_tbf_rate() {
    local interface="$1"
    local qdisc_line="$2"
    local expected_rate
    local recorded_qdisc
    local actual_rate
    local expected_bps
    local actual_bps

    grep -Eq '^qdisc tbf .* root([[:space:]]|$)' <<< "$qdisc_line" || return 1
    expected_rate=$(trafficcop_legacy_state_rate "$interface") || return 1
    recorded_qdisc=$(tc_state_optional_unique_value "$TRAFFICCOP_TC_STATE_FILE" "QDISC_LINE") || return 1
    if [ -n "$recorded_qdisc" ]; then
        [ "$recorded_qdisc" = "$qdisc_line" ] || return 1
    fi
    actual_rate=$(tc_rate_from_qdisc_line "$qdisc_line")
    expected_bps=$(normalize_tc_rate_to_bps "$expected_rate") || return 1
    actual_bps=$(normalize_tc_rate_to_bps "$actual_rate") || return 1
    [ "$actual_bps" -eq "$expected_bps" ] || return 1
    printf '%s\n' "$expected_rate"
}

tc_root_qdisc_line() {
    local qdisc_state
    qdisc_state=$(tc qdisc show dev "$1" root 2>/dev/null) || return 1
    awk 'NR == 1 { print }' <<< "$qdisc_state"
}

tc_root_matches_unified_contract() {
    local interface="$1"
    local qdisc_line
    local class_state
    qdisc_line=$(tc_root_qdisc_line "$interface") || return 1
    grep -Eq '^qdisc htb 1: root([[:space:]]|$)' <<< "$qdisc_line" || return 1
    grep -Eq ' default (0x)?30([[:space:]]|$)' <<< "$qdisc_line" || return 1
    class_state=$(tc class show dev "$interface" 2>/dev/null) || return 1
    grep -Eq '^class htb 1:1 root([[:space:]]|$)' <<< "$class_state" || return 1
    grep -Eq '^class htb 1:30 parent 1:1([[:space:]]|$)' <<< "$class_state"
}

tc_root_is_owned() {
    local interface="$1"
    tc_root_owner_marker_matches "$interface" || return 1
    tc_root_matches_unified_contract "$interface"
}

tc_root_is_managed() {
    local interface="$1"
    tc_root_matches_unified_contract "$interface" || return 1
    if tc_root_owner_marker_matches "$interface"; then
        return 0
    fi
    trafficcop_unified_state_rate "$interface" >/dev/null 2>&1
}

tc_root_qdisc_is_replaceable() {
    local qdisc_state="$1"
    local qdisc_type
    qdisc_type=$(printf '%s\n' "$qdisc_state" | awk 'NR == 1 {print $2}')
    case "$qdisc_type" in
        noqueue|fq_codel|pfifo_fast|mq|fq) return 0 ;;
        "")
            # 解析不出类型只可能是 tc 查询异常。当成“可替换”会删掉别人的 root qdisc。
            echo "无法识别 root qdisc 类型（tc 查询异常），按不可替换处理" >&2
            return 1
            ;;
        *) return 1 ;;
    esac
}

desired_tc_parent_rate() {
    local interface="$1"
    local rate
    local result=0
    rate=$(trafficcop_unified_state_rate "$interface" 2>/dev/null) || result=$?
    case "$result" in
        0) printf '%s\n' "$rate" ;;
        1|4|5) printf '%s\n' "$TC_PARENT_RATE" ;;
        3)
            if tc_root_owner_marker_matches "$interface" &&
               tc_root_matches_unified_contract "$interface"; then
                trafficcop_legacy_state_rate "$interface"
            else
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

tc_class_rate_and_ceil() {
    local interface="$1"
    local class_id="$2"
    local class_state
    class_state=$(tc class show dev "$interface" 2>/dev/null) || return 1
    awk -v class_id="$class_id" '
            $1 == "class" && $2 == "htb" && $3 == class_id {
                rate=""; ceil=""
                for (i=1; i<=NF; i++) {
                    if ($i == "rate") rate=$(i+1)
                    if ($i == "ceil") ceil=$(i+1)
                }
                if (ceil == "") ceil=rate
                if (rate != "") print rate, ceil
                exit
            }' <<< "$class_state"
}

rollback_legacy_trafficcop_tbf() {
    local interface="$1"
    [ "$TC_UPDATE_MIGRATED_LEGACY_TBF" = "true" ] || return 0
    [ -n "$TC_UPDATE_LEGACY_TBF_RATE" ] || return 1
    if tc qdisc replace dev "$interface" root tbf rate "$TC_UPDATE_LEGACY_TBF_RATE" \
        burst 32kbit latency 400ms 2>/dev/null; then
        rm -f "$(get_tc_root_owner_file)"
        TC_UPDATE_MIGRATED_LEGACY_TBF=false
        TC_UPDATE_LEGACY_TBF_RATE=""
        return 0
    fi
    log_notification "统一HTB迁移失败且无法恢复TrafficCop旧TBF: $interface"
    return 1
}

ensure_owned_tc_hierarchy_locked() {
    local interface="$1"
    local parent_rate=""
    local qdisc_state
    local qdisc_line
    local previous_parent_rate=""
    local previous_parent_ceil=""

    ENSURE_TC_ROOT_CREATED=false
    ENSURE_TC_ROOT_MIGRATED=false
    [ -n "$interface" ] || return 1
    if ! qdisc_state=$(tc qdisc show dev "$interface" 2>/dev/null); then
        log_notification "无法读取网卡TC根队列，已拒绝修改统一HTB: $interface"
        return 1
    fi
    qdisc_line=$(printf '%s\n' "$qdisc_state" | head -n 1)

    if grep -Eq '^qdisc tbf .* root([[:space:]]|$)' <<< "$qdisc_line"; then
        parent_rate=$(trafficcop_legacy_tbf_rate "$interface" "$qdisc_line" 2>/dev/null) || {
            log_notification "检测到无法确认归属的TBF根队列，已拒绝迁移: $interface"
            return 1
        }
        if ! tc qdisc replace dev "$interface" root handle 1: htb default 30 2>/dev/null; then
            log_notification "无法把TrafficCop旧TBF迁移为统一HTB: $interface"
            return 1
        fi
        ENSURE_TC_ROOT_MIGRATED=true
        TC_UPDATE_MIGRATED_LEGACY_TBF=true
        TC_UPDATE_LEGACY_TBF_RATE="$parent_rate"
    else
        parent_rate=$(desired_tc_parent_rate "$interface" 2>/dev/null) || {
            log_notification "TrafficCop TC状态无效，已拒绝修改统一HTB: $interface"
            return 1
        }
    fi
    normalize_tc_rate_to_bps "$parent_rate" >/dev/null 2>&1 || return 1

    if grep -Eq '^qdisc htb 1:' <<< "$qdisc_state"; then
        if ! tc_root_is_managed "$interface"; then
            tc_root_owner_marker_matches "$interface" && rm -f "$(get_tc_root_owner_file)"
            log_notification "检测到不属于Dog/TrafficCop统一协议的HTB根队列，已拒绝接管: $interface"
            return 1
        fi
        if ! read -r previous_parent_rate previous_parent_ceil < <(
            tc_class_rate_and_ceil "$interface" "1:1"
        ); then
            log_notification "无法读取统一HTB父类，已拒绝修改: $interface"
            return 1
        fi
    elif [ "$ENSURE_TC_ROOT_MIGRATED" != "true" ]; then
        if ! tc_root_qdisc_is_replaceable "$qdisc_state"; then
            log_notification "检测到不可安全替换的根qdisc，已拒绝创建统一HTB: $interface"
            return 1
        fi
        if ! tc qdisc replace dev "$interface" root handle 1: htb default 30 2>/dev/null; then
            log_notification "无法创建统一HTB根队列: $interface"
            return 1
        fi
        ENSURE_TC_ROOT_CREATED=true
    fi

    if ! tc class replace dev "$interface" parent 1: classid 1:1 htb \
        rate "$parent_rate" ceil "$parent_rate" 2>/dev/null; then
        if [ "$ENSURE_TC_ROOT_MIGRATED" = "true" ]; then
            rollback_legacy_trafficcop_tbf "$interface" >/dev/null 2>&1 || true
        elif [ "$ENSURE_TC_ROOT_CREATED" = "true" ]; then
            tc qdisc del dev "$interface" root handle 1: 2>/dev/null || true
            rm -f "$(get_tc_root_owner_file)"
        fi
        log_notification "无法创建或更新统一HTB父类: $interface"
        return 1
    fi
    if ! tc class replace dev "$interface" parent 1:1 classid 1:30 htb \
        rate "$TC_DEFAULT_CLASS_RATE" ceil "$parent_rate" 2>/dev/null; then
        if [ "$ENSURE_TC_ROOT_MIGRATED" = "true" ]; then
            rollback_legacy_trafficcop_tbf "$interface" >/dev/null 2>&1 || true
        elif [ "$ENSURE_TC_ROOT_CREATED" = "true" ]; then
            tc qdisc del dev "$interface" root handle 1: 2>/dev/null || true
            rm -f "$(get_tc_root_owner_file)"
        elif [ -n "$previous_parent_rate" ]; then
            tc class replace dev "$interface" parent 1: classid 1:1 htb \
                rate "$previous_parent_rate" ceil "$previous_parent_ceil" 2>/dev/null || true
        fi
        log_notification "无法创建统一HTB默认子类: $interface"
        return 1
    fi
    if ! tc_root_owner_marker_matches "$interface" && ! mark_tc_root_owned "$interface"; then
        if [ "$ENSURE_TC_ROOT_MIGRATED" = "true" ]; then
            rollback_legacy_trafficcop_tbf "$interface" >/dev/null 2>&1 || true
        elif [ "$ENSURE_TC_ROOT_CREATED" = "true" ]; then
            tc qdisc del dev "$interface" root handle 1: 2>/dev/null || true
        fi
        log_notification "无法记录统一HTB根队列归属，已撤销队列: $interface"
        return 1
    fi
}

ensure_owned_tc_hierarchy() {
    local result=0 interface="${1:-$(get_default_interface)}"
    begin_tc_update || return 1
    ensure_owned_tc_hierarchy_locked "$interface" || result=$?
    if [ "$result" -eq 0 ] && ip link show "$TC_IFB_DEVICE" >/dev/null 2>&1; then
        ensure_ifb_hierarchy_locked "$interface" || result=$?
    fi
    finish_tc_update
    return "$result"
}

# 拆掉入向链路：ifb0 上已无端口类、且 TrafficCop 未声明整机限速时才清理。
# 判据与物理网卡保持一致，避免误删 TrafficCop 正在使用的入向层级。
cleanup_ingress_shaping_if_unused_locked() {
    local interface="$1"
    local dev="$TC_IFB_DEVICE"

    [ -n "$interface" ] || return 0
    ip link show "$dev" >/dev/null 2>&1 || return 0

    # ifb0 的合法性从属物理网卡：物理网卡已不属于本脚本时不碰 ifb0
    tc_root_owner_marker_matches "$interface" || return 0

    # 物理网卡的统一 HTB 已经不在了（卸载流程会先删它），说明整条层级正在拆除，
    # 此时 ifb0 上的端口类只是残留，应当一并清掉；否则仍按"有消费者就不动"处理。
    if grep -q '^qdisc htb 1:' <<< "$(tc qdisc show dev "$interface" 2>/dev/null)"; then
        # 1:1 与 1:30 是统一层级的基础分类；其他分类表示端口入向限速仍在使用。
        local class_output
        class_output=$(tc class show dev "$dev" 2>/dev/null) || return 1
        if printf '%s\n' "$class_output" |
           awk '$1 == "class" && $2 == "htb" && $3 != "1:1" && $3 != "1:30" { found=1 } END { exit found ? 0 : 1 }'; then
            return 0
        fi

        local ntc_status=0
        trafficcop_unified_state_rate "$interface" >/dev/null 2>&1 || ntc_status=$?
        if [ "$ntc_status" -eq 0 ]; then
            return 0
        fi
        if [ -e "$TRAFFICCOP_TC_STATE_FILE" ] &&
           [ "$ntc_status" -ne 1 ] && [ "$ntc_status" -ne 4 ] && [ "$ntc_status" -ne 5 ]; then
            # NTC 状态存在但无法安全解释时宁可保留，也不删除它可能正在用的入向层级。
            return 1
        fi
    else
        # 物理网卡的根队列不是本脚本的统一 HTB。这里必须区分两种截然不同的情况：
        #   a) 根队列处于缺省/可替换状态（或已被卸载流程删除，show 不出内容）→ 属残留，清掉 ifb0；
        #   b) 被外部 qdisc 占用（tbf、别的 handle 的 htb 等）→ 说明 eth0 的 ingress 仍归我们，
        #      此时删 ifb0 会连带废掉自己的入向限速，必须原样保留。
        local root_qdisc_state
        root_qdisc_state=$(tc qdisc show dev "$interface" 2>/dev/null) || return 1
        if [ -n "$root_qdisc_state" ] && ! tc_root_qdisc_is_replaceable "$root_qdisc_state"; then
            return 0
        fi
    fi

    tc qdisc del dev "$dev" root 2>/dev/null || true
    tc qdisc del dev "$interface" ingress 2>/dev/null || true
    ip link set "$dev" down 2>/dev/null || true
    ip link del "$dev" 2>/dev/null || true
    return 0
}

cleanup_owned_tc_root_if_unused_locked() {
    local interface="${1:-$(get_default_interface)}"
    [ -n "$interface" ] && tc_root_is_owned "$interface" || return 0

    # 1:1 与 1:30 是统一层级的基础分类；其他分类或过滤器表示端口限速仍在使用。
    local class_output
    local filter_output
    class_output=$(tc class show dev "$interface" 2>/dev/null) || return 1
    if printf '%s\n' "$class_output" |
       awk '$1 == "class" && $2 == "htb" && $3 != "1:1" && $3 != "1:30" { found=1 } END { exit found ? 0 : 1 }'; then
        return 0
    fi
    filter_output=$(tc filter show dev "$interface" parent 1:0 2>/dev/null) || return 1
    if [ -n "$filter_output" ]; then
        return 0
    fi

    local ntc_status=0
    trafficcop_unified_state_rate "$interface" >/dev/null 2>&1 || ntc_status=$?
    if [ "$ntc_status" -eq 0 ]; then
        rm -f "$(get_tc_root_owner_file)"
        return 0
    fi
    if [ -e "$TRAFFICCOP_TC_STATE_FILE" ] &&
       [ "$ntc_status" -ne 1 ] && [ "$ntc_status" -ne 4 ] && [ "$ntc_status" -ne 5 ]; then
        # NTC 状态存在但无法安全解释时宁可保留基础层级，也不删除其全局限速。
        return 1
    fi

    if ! tc qdisc del dev "$interface" root handle 1: 2>/dev/null; then
        return 1
    fi
    # 顺序要紧：先清 ifb0（它要读归属标记），再删归属文件。
    cleanup_ingress_shaping_if_unused_locked "$interface" >/dev/null 2>&1 || true
    rm -f "$(get_tc_root_owner_file)"
}

cleanup_owned_tc_root_if_unused() {
    local result=0
    begin_tc_update || return 1
    cleanup_owned_tc_root_if_unused_locked "$@" || result=$?
    finish_tc_update
    return "$result"
}

ensure_ifb_device_locked() {
    if ! ip link show "$TC_IFB_DEVICE" >/dev/null 2>&1; then
        modprobe ifb numifbs=0 2>/dev/null || true
        ip link add "$TC_IFB_DEVICE" type ifb 2>/dev/null || true
    fi
    ip link set "$TC_IFB_DEVICE" up 2>/dev/null || true
    # ifb 是 NOARP 虚拟设备，operstate 恒为 UNKNOWN，只能判 UP flag
    grep -q "<.*UP.*>" <<< "$(ip link show "$TC_IFB_DEVICE" 2>/dev/null)"
}

ensure_ifb_hierarchy_locked() {
    local interface="$1"
    local dev="$TC_IFB_DEVICE"
    local qdisc_state
    local parent_rate

    tc_root_owner_marker_matches "$interface" || return 1

    ensure_ifb_device_locked || {
        log_notification "ifb0 创建失败，端口入向限速未生效"
        return 1
    }

    if ! qdisc_state=$(tc qdisc show dev "$dev" 2>/dev/null); then
        log_notification "无法读取 ifb0 根队列，已拒绝创建入向统一HTB"
        return 1
    fi
    if ! grep -Eq '^qdisc htb 1:' <<< "$qdisc_state"; then
        if ! tc_root_qdisc_is_replaceable "$qdisc_state"; then
            log_notification "ifb0 上存在不可安全替换的根队列，已拒绝接管"
            return 1
        fi
        tc qdisc replace dev "$dev" root handle 1: htb default 30 2>/dev/null || {
            log_notification "无法在 ifb0 上创建统一HTB根队列"
            return 1
        }
    fi

    parent_rate=$(desired_tc_parent_rate "$interface" 2>/dev/null) || {
        log_notification "TrafficCop TC状态无效，已拒绝修改 ifb0 统一HTB"
        return 1
    }
    tc class replace dev "$dev" parent 1: classid 1:1 htb \
        rate "$parent_rate" ceil "$parent_rate" 2>/dev/null || return 1
    tc class replace dev "$dev" parent 1:1 classid 1:30 htb \
        rate "$TC_DEFAULT_CLASS_RATE" ceil "$parent_rate" 2>/dev/null || return 1
}

ingress_redirect_runtime_complete() {
    local state
    state=$(tc -j filter show dev "$1" parent "$TC_IFB_INGRESS_HANDLE" 2>/dev/null) || return 1
    jq -e --arg dev "$TC_IFB_DEVICE" '
        def redirects($proto): [.[] | select(.protocol == $proto) |
            .options.actions[]? | select(.kind == "mirred" and
            .mirred_action == "redirect" and .direction == "egress" and .to_dev == $dev)] | length;
        redirects("ip") == 1 and redirects("ipv6") == 1
    ' <<< "$state" >/dev/null
}

ensure_ingress_redirect_locked() {
    local interface="$1" state proto count
    state=$(tc qdisc show dev "$interface" 2>/dev/null) || return 1
    if ! grep -q '^qdisc ingress' <<< "$state"; then
        tc qdisc add dev "$interface" handle "$TC_IFB_INGRESS_HANDLE" ingress 2>/dev/null || return 1
    fi
    state=$(tc -j filter show dev "$interface" parent "$TC_IFB_INGRESS_HANDLE" 2>/dev/null) || return 1
    for proto in ip ipv6; do
        count=$(jq --arg proto "$proto" --arg dev "$TC_IFB_DEVICE" '
            [.[] | select(.protocol == $proto) | .options.actions[]? |
             select(.kind == "mirred" and .mirred_action == "redirect" and
                    .direction == "egress" and .to_dev == $dev)] | length
        ' <<< "$state") || return 1
        [ "$count" -le 1 ] || return 1
        if [ "$count" -eq 0 ]; then
            tc filter add dev "$interface" parent "$TC_IFB_INGRESS_HANDLE" protocol "$proto" u32 \
                match u32 0 0 action mirred egress redirect dev "$TC_IFB_DEVICE" 2>/dev/null || return 1
        fi
    done
}

# 删除TC带宽限制

normalize_tc_rate_to_bps() {
    local rate
    rate=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    [[ "$rate" =~ ^([0-9]+)(bit|kbit|mbit|gbit)$ ]] || return 1
    local value="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in
        bit) echo "$value" ;;
        kbit) echo $((value * 1000)) ;;
        mbit) echo $((value * 1000000)) ;;
        gbit) echo $((value * 1000000000)) ;;
    esac
}

tc_class_rate_matches() {
    local interface="$1"
    local class_id="$2"
    local expected_rate="$3"
    local expected_ceil="${4:-$expected_rate}"
    local class_line
    local class_state
    class_state=$(tc class show dev "$interface" 2>/dev/null) || return 1
    class_line=$(awk -v class_id="$class_id" \
        '$1 == "class" && $2 == "htb" && $3 == class_id {print; exit}' <<< "$class_state")
    [ -n "$class_line" ] || return 1

    local actual_rate
    local actual_ceil
    actual_rate=$(printf '%s\n' "$class_line" |
        awk '{for (i=1; i<=NF; i++) if ($i == "rate") {print $(i+1); exit}}')
    actual_ceil=$(printf '%s\n' "$class_line" |
        awk '{for (i=1; i<=NF; i++) if ($i == "ceil") {print $(i+1); exit}}')
    [ -n "$actual_ceil" ] || actual_ceil="$actual_rate"

    local expected_bps
    local expected_ceil_bps
    local actual_rate_bps
    local actual_ceil_bps
    expected_bps=$(normalize_tc_rate_to_bps "$expected_rate") || return 1
    expected_ceil_bps=$(normalize_tc_rate_to_bps "$expected_ceil") || return 1
    actual_rate_bps=$(normalize_tc_rate_to_bps "$actual_rate") || return 1
    actual_ceil_bps=$(normalize_tc_rate_to_bps "$actual_ceil") || return 1
    [ "$actual_rate_bps" -eq "$expected_bps" ] && [ "$actual_ceil_bps" -eq "$expected_ceil_bps" ]
}

# 入向整形链路是否完整：ifb0 存在、ingress 重定向在位、端口类与过滤器齐全。
# class_id 与 expected_rate 与出向同源，保证两侧限速一致。

# 返回值：0=存在且完整；1=存在但失效/状态不可解释；2=当前不需要 TC。

dog_tc_status() {
    local interface
    interface=$(get_default_interface 2>/dev/null || true)
    if [ -z "$interface" ]; then
        echo "TC_STATUS=ERROR REASON=interface-unresolved"
        return 1
    fi
    if ! begin_tc_update; then
        echo "TC_STATUS=ERROR INTERFACE=$interface REASON=lock-timeout"
        return 1
    fi

    local runtime_status=0
    local qdisc_state
    local class_state
    if ! qdisc_state=$(tc qdisc show dev "$interface" 2>/dev/null) ||
       ! class_state=$(tc class show dev "$interface" 2>/dev/null) ||
       ! tc filter show dev "$interface" parent 1:0 >/dev/null 2>&1; then
        finish_tc_update
        echo "TC_STATUS=ERROR INTERFACE=$interface REASON=status-read-failed"
        return 1
    fi
    dog_tc_runtime_complete_all "$interface" || runtime_status=$?

    local result=0
    case "$runtime_status" in
        0)
            echo "TC_STATUS=OK INTERFACE=$interface MODEL=$TC_INTEROP_SCHEMA"
            ;;
        1)
            echo "TC_STATUS=CONFLICT INTERFACE=$interface REASON=managed-rules-invalid"
            result=1
            ;;
        2)
            if tc_root_qdisc_is_replaceable "$qdisc_state"; then
                echo "TC_STATUS=IDLE INTERFACE=$interface"
            elif tc_root_is_managed "$interface"; then
                echo "TC_STATUS=CONFLICT INTERFACE=$interface REASON=orphaned-managed-root"
                result=1
            else
                echo "TC_STATUS=CONFLICT INTERFACE=$interface REASON=external-root-qdisc"
                result=1
            fi
            ;;
        *)
            echo "TC_STATUS=ERROR INTERFACE=$interface REASON=status-unavailable"
            result=1
            ;;
    esac
    finish_tc_update
    return "$result"
}

# 仅供用户确认后的共享恢复入口调用。--auto 只恢复已有 Dog/NTC TC 状态；
# --manual 还允许清除首次安装时发现的外部 root，之后由用户重新配置限速。
recover_tc_runtime() {
    local mode="${1:---manual}"
    case "$mode" in
        --auto|--manual) ;;
        *)
            echo "不支持的 TC 恢复模式: $mode" >&2
            return 2
            ;;
    esac

    validate_config_file "$CONFIG_FILE" 2>/dev/null || {
        echo "Dog 配置无效，拒绝修改 TC。" >&2
        return 1
    }
    local interface
    interface=$(get_default_interface 2>/dev/null || true)
    [ -n "$interface" ] || {
        echo "无法确定默认网卡，未修改 TC。" >&2
        return 1
    }
    if ! begin_tc_update; then
        echo "无法取得共享 TC 锁，未修改 qdisc。" >&2
        return 1
    fi

    local qdisc_state
    local class_state
    if ! qdisc_state=$(tc qdisc show dev "$interface" 2>/dev/null) ||
       ! class_state=$(tc class show dev "$interface" 2>/dev/null) ||
       ! tc filter show dev "$interface" parent 1:0 >/dev/null 2>&1; then
        finish_tc_update
        echo "无法读取完整 TC 状态，未修改 qdisc。" >&2
        return 1
    fi

    local runtime_status=0
    dog_tc_runtime_complete_all "$interface" || runtime_status=$?
    if [ "$runtime_status" -eq 0 ]; then
        finish_tc_update
        echo "Dog/NTC TC 规则完整，无需重建。"
        return 0
    fi

    local ntc_status=0
    trafficcop_unified_state_rate "$interface" >/dev/null 2>&1 || ntc_status=$?
    if [ -e "$TRAFFICCOP_TC_STATE_FILE" ] &&
       [ "$ntc_status" -ne 0 ] && [ "$ntc_status" -ne 1 ] &&
       [ "$ntc_status" -ne 4 ] && [ "$ntc_status" -ne 5 ]; then
        finish_tc_update
        echo "TrafficCop TC 状态文件无法安全解释，拒绝自动删除 qdisc。" >&2
        return 1
    fi
    if [ "$mode" = "--auto" ] && [ "$runtime_status" -eq 2 ]; then
        finish_tc_update
        echo "当前没有需要自动恢复的 Dog/NTC TC 规则。"
        return 0
    fi

    if [ "$mode" = "--auto" ] && ! tc_root_qdisc_is_replaceable "$qdisc_state"; then
        finish_tc_update
        echo "自动恢复检测到外部或未知 root qdisc，拒绝接管；请由用户确认后执行手动重建。" >&2
        return 1
    fi
    if [ "$runtime_status" -eq 2 ] && tc_root_qdisc_is_replaceable "$qdisc_state"; then
        finish_tc_update
        echo "当前 TC 为空闲状态，无需处理。"
        return 0
    fi

    local tc_ports=()
    local tc_limits=()
    local id tc_limit
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        tc_limit=$(monitor_tc_rate "$id") || continue
        tc_ports+=("$id")
        tc_limits+=("$tc_limit")
    done < <(monitor_ids)

    if ! tc_root_qdisc_is_replaceable "$qdisc_state" &&
       ! tc qdisc del dev "$interface" root 2>/dev/null; then
        finish_tc_update
        echo "无法删除当前冲突 root qdisc，Dog/NTC 规则未重建。" >&2
        return 1
    fi
    rm -f "$(get_tc_root_owner_file)"

    local rebuild_ok=true
    local tc_index
    if [ ${#tc_ports[@]} -gt 0 ]; then
        for tc_index in "${!tc_ports[@]}"; do
            if ! tc_apply_monitor_locked "${tc_ports[$tc_index]}" "${tc_limits[$tc_index]}"; then
                rebuild_ok=false
                break
            fi
        done
    elif [ "$ntc_status" -eq 0 ]; then
        ensure_owned_tc_hierarchy_locked "$interface" || rebuild_ok=false
    fi

    if [ "$rebuild_ok" = "true" ]; then
        local verify_status=0
        dog_tc_runtime_complete_all "$interface" || verify_status=$?
        if [ ${#tc_ports[@]} -gt 0 ] || [ "$ntc_status" -eq 0 ]; then
            [ "$verify_status" -eq 0 ] || rebuild_ok=false
        else
            [ "$verify_status" -eq 2 ] || rebuild_ok=false
        fi
    fi
    finish_tc_update

    if [ "$rebuild_ok" != "true" ]; then
        echo "冲突 qdisc 已清除，但 Dog/NTC TC 规则未能完整重建；请运行 dog --self-check。" >&2
        return 1
    fi
    if [ ${#tc_ports[@]} -eq 0 ] && [ "$ntc_status" -ne 0 ]; then
        echo "外部 TC 冲突已清除；当前没有需要创建的 Dog 端口限速规则。"
    else
        echo "Dog/NTC 统一 HTB 已按现有配置重建。"
    fi
}
