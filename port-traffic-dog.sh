#!/bin/bash

set -euo pipefail

readonly SCRIPT_VERSION="1.5.13"
readonly SCRIPT_NAME="端口流量狗"
readonly SCRIPT_PATH="$(realpath "$0")"
readonly INSTALLED_SCRIPT_PATH="/usr/local/bin/port-traffic-dog.sh"
readonly CONFIG_DIR="/etc/port-traffic-dog"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly LOG_FILE="$CONFIG_DIR/logs/traffic.log"
readonly TRAFFIC_DATA_FILE="$CONFIG_DIR/traffic_data.json"
readonly TRAFFIC_STATS_FILE="$CONFIG_DIR/traffic_stats.json"
readonly TRAFFIC_STATS_LOCK_DIR="$CONFIG_DIR/traffic_stats.lock"
readonly CONFIG_LOCK_DIR="$CONFIG_DIR/config.lock"
readonly RESET_LOCK_DIR="$CONFIG_DIR/reset.lock"
readonly CRON_LOCK_DIR="$CONFIG_DIR/cron.lock"
readonly TC_SHARED_LOCK_FILE="${TRAFFIC_TOOLS_TC_LOCK_FILE:-/run/lock/traffic-tools-tc.lock}"
readonly TRAFFICCOP_TC_STATE_FILE="${TRAFFICCOP_TC_STATE_FILE:-/etc/trafficcop-lite/tc_limit_state}"
readonly TC_RECOVERY_RUNNER="${TRAFFIC_TOOLS_TC_RECOVERY_RUNNER:-/usr/local/sbin/traffic-tools-tc-recovery.sh}"
readonly TC_RECOVERY_UNIT_FILE="${TRAFFIC_TOOLS_TC_RECOVERY_UNIT_FILE:-/etc/systemd/system/traffic-tools-tc-recovery.service}"
readonly TC_RECOVERY_SERVICE="traffic-tools-tc-recovery.service"
readonly TC_RECOVERY_SYSTEMCTL="${TRAFFIC_TOOLS_SYSTEMCTL:-systemctl}"
readonly TC_INTEROP_SCHEMA="traffic-tools-unified-htb-v1"
readonly TRAFFIC_ACCOUNTING_MODEL="upstream-weighted-v2"
readonly TC_RUNTIME_MODEL="unified-htb-v3"
readonly DEFAULT_TRAFFIC_RETENTION_DAYS=400
readonly TC_PARENT_RATE="100gbit"
readonly TC_DEFAULT_CLASS_RATE="1kbit"
readonly TC_PORT_CLASS_RATE="1kbit"
readonly TC_MARK_MASK=0xfffff000
readonly TC_MARK_PRESERVE_MASK=0x00000fff
readonly LEGACY_LOCK_MAX_AGE=86400

readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'
# 网络超时设置
readonly SHORT_CONNECT_TIMEOUT=5
readonly SHORT_MAX_TIMEOUT=7
readonly SCRIPT_URL="https://raw.githubusercontent.com/duya07/port-traffic-dog/main/port-traffic-dog.sh"
readonly MODULES_ARCHIVE_URL="https://github.com/duya07/port-traffic-dog/archive/refs/heads/main.zip"
readonly SHORTCUT_COMMAND="dog"

get_script_exec_path() {
    if [ -f "$INSTALLED_SCRIPT_PATH" ]; then
        echo "$INSTALLED_SCRIPT_PATH"
    else
        echo "$SCRIPT_PATH"
    fi
}

detect_system() {
    # Ubuntu优先检测：避免Debian系统误判
    if [ -f /etc/lsb-release ] && grep -q "Ubuntu" /etc/lsb-release 2>/dev/null; then
        echo "ubuntu"
        return
    fi

    if [ -f /etc/debian_version ]; then
        echo "debian"
        return
    fi

    echo "unknown"
}

install_missing_tools() {
    local missing_tools=("$@")
    local system_type=$(detect_system)
    local pkg_cmd
    case $system_type in
        "ubuntu") pkg_cmd="apt" ;;
        "debian") pkg_cmd="apt-get" ;;
        *)
            echo -e "${RED}不支持的系统类型: $system_type${NC}"
            echo "支持的系统: Ubuntu, Debian"
            echo "请手动安装: ${missing_tools[*]}"
            exit 1
            ;;
    esac

    echo -e "${YELLOW}检测到缺少工具: ${missing_tools[*]}${NC}"
    echo "正在自动安装..."

    $pkg_cmd update -qq
    for tool in "${missing_tools[@]}"; do
        case $tool in
            "nft") $pkg_cmd install -y nftables ;;
            "tc") $pkg_cmd install -y iproute2 ;;
            "ss") $pkg_cmd install -y iproute2 ;;
            "jq") $pkg_cmd install -y jq ;;
            "awk") $pkg_cmd install -y gawk ;;
            "bc") $pkg_cmd install -y bc ;;
            "curl") $pkg_cmd install -y curl ;;
            "conntrack") $pkg_cmd install -y conntrack ;;
            "flock") $pkg_cmd install -y util-linux ;;
            "cron")
                $pkg_cmd install -y cron
                systemctl enable cron 2>/dev/null || true
                systemctl start cron 2>/dev/null || true
                ;;
            *) $pkg_cmd install -y "$tool" ;;
        esac
    done

    echo -e "${GREEN}依赖工具安装完成${NC}"
}

check_dependencies() {
    local silent_mode=${1:-false}
    local missing_tools=()
    local required_tools=("nft" "tc" "ss" "jq" "awk" "bc" "unzip" "cron" "curl" "conntrack" "flock")

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        install_missing_tools "${missing_tools[@]}"

        local still_missing=()
        for tool in "${missing_tools[@]}"; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                still_missing+=("$tool")
            fi
        done

        if [ ${#still_missing[@]} -gt 0 ]; then
            echo -e "${RED}安装失败，仍缺少工具: ${still_missing[*]}${NC}"
            echo "请手动安装后重试"
            exit 1
        fi
    fi

    if [ "$silent_mode" != "true" ]; then
        echo -e "${GREEN}依赖检查通过${NC}"
    fi

}

setup_script_permissions() {
    if [ -f "$SCRIPT_PATH" ]; then
        chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    fi

    if [ -f "$INSTALLED_SCRIPT_PATH" ]; then
        chmod +x "$INSTALLED_SCRIPT_PATH" 2>/dev/null || true
    fi
}

read_current_crontab() {
    local output
    local result=0
    output=$(crontab -l 2>&1) || result=$?
    if [ "$result" -ne 0 ]; then
        if printf '%s' "$output" | grep -qi "no crontab for"; then
            return 0
        fi
        echo "读取 root crontab 失败: $output" >&2
        return 1
    fi
    printf '%s\n' "$output"
}

begin_cron_update() {
    acquire_directory_lock "$CRON_LOCK_DIR"
}

release_cron_update() {
    release_directory_lock "$CRON_LOCK_DIR"
}

read_root_crontab_locked() {
    local output=""
    local result=0

    begin_cron_update || return 1
    output=$(read_current_crontab) || result=$?
    release_cron_update
    [ "$result" -eq 0 ] || return "$result"
    printf '%s\n' "$output"
}

finish_cron_update() {
    local cron_file="$1"
    local result=0
    crontab "$cron_file" || result=1
    rm -f "$cron_file"
    release_cron_update
    return "$result"
}

setup_cron_environment() {
    # cron环境PATH不完整，需要设置完整路径
    begin_cron_update || return 1
    local current_cron
    if ! current_cron=$(read_current_crontab); then
        release_cron_update
        return 1
    fi
    if ! echo "$current_cron" | grep -q "^PATH=.*sbin"; then
        local temp_cron=$(mktemp)
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" > "$temp_cron"
        printf '%s\n' "$current_cron" | grep -v "^PATH=" >> "$temp_cron" || true
        finish_cron_update "$temp_cron"
        return
    fi
    release_cron_update
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要root权限运行${NC}"
        exit 1
    fi
}

init_config() {
    mkdir -p "$CONFIG_DIR" "$(dirname "$LOG_FILE")"

    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "global": {
    "billing_mode": "double"
  },
  "ports": {},
  "nftables": {
    "table_name": "port_traffic_monitor",
    "family": "inet"
  },
  "notifications": {
    "telegram": {
      "enabled": false,
      "bot_token": "",
      "chat_id": "",
      "server_name": "",
      "api_route": "official",
      "custom_api_base": "",
      "status_notifications": {
        "enabled": false,
        "interval": "1h"
      }
    },
    "email": {
      "enabled": false,
      "status": "coming_soon"
    },
    "wecom": {
      "enabled": false,
      "webhook_url": "",
      "server_name": "",
      "status_notifications": {
        "enabled": false,
        "interval": "1h"
      }
    }
  }
}
EOF
    fi

    if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}错误：配置文件不是有效 JSON: $CONFIG_FILE${NC}"
        return 1
    fi
    if ! validate_config_file "$CONFIG_FILE"; then
        echo -e "${RED}错误：配置文件内容无效，已停止加载${NC}"
        return 1
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true

    init_nftables || return 1
    setup_exit_hooks
    restore_monitoring_if_needed || return 1
    ensure_traffic_accounting_model || return 1
    ensure_tc_runtime_model || return 1
}

init_nftables() {
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    # 使用inet family支持IPv4/IPv6双栈
    nft add table $family $table_name 2>/dev/null || true
    nft add chain $family $table_name input { type filter hook input priority 0\; } 2>/dev/null || true
    nft add chain $family $table_name output { type filter hook output priority 0\; } 2>/dev/null || true
    nft add chain $family $table_name forward { type filter hook forward priority 0\; } 2>/dev/null || true
}

get_network_interfaces() {
    local interfaces=()

    while IFS= read -r interface; do
        if [[ "$interface" != "lo" ]] && [[ "$interface" != "" ]]; then
            interfaces+=("$interface")
        fi
    done < <(ip link show | grep "state UP" | awk -F': ' '{print $2}' | cut -d'@' -f1)

    printf '%s\n' "${interfaces[@]}"
}

get_default_interface() {
    local default_interface
    default_interface=$(ip -o route show default 2>/dev/null |
        awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    if [ -z "$default_interface" ]; then
        default_interface=$(ip -o -6 route show default 2>/dev/null |
            awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    fi

    if [ -n "$default_interface" ]; then
        echo "$default_interface"
        return
    fi

    local interfaces=($(get_network_interfaces))
    if [ ${#interfaces[@]} -gt 0 ]; then
        echo "${interfaces[0]}"
    else
        echo "eth0"
    fi
}

format_bytes() {
    local bytes=$1

    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        bytes=0
    fi

    if [ $bytes -ge 1073741824 ]; then
        local gb=$(echo "scale=2; $bytes / 1073741824" | bc)
        echo "${gb}GB"
    elif [ $bytes -ge 1048576 ]; then
        local mb=$(echo "scale=2; $bytes / 1048576" | bc)
        echo "${mb}MB"
    elif [ $bytes -ge 1024 ]; then
        local kb=$(echo "scale=2; $bytes / 1024" | bc)
        echo "${kb}KB"
    else
        echo "${bytes}B"
    fi
}

get_beijing_time() {
    TZ='Asia/Shanghai' date "$@"
}

update_config() {
    local jq_expression="$1"
    update_config_file "$jq_expression"
}

acquire_directory_lock() {
    local lock_dir="$1"
    mkdir -p "$CONFIG_DIR"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if mkdir "$lock_dir" 2>/dev/null; then
            local current_pid="${BASHPID:-$$}"
            local current_boot_id="-"
            local current_start_time="-"
            [ -r /proc/sys/kernel/random/boot_id ] && \
                current_boot_id=$(tr -d '\r\n' < /proc/sys/kernel/random/boot_id)
            [ -r "/proc/$current_pid/stat" ] && \
                current_start_time=$(awk '{print $22}' "/proc/$current_pid/stat" 2>/dev/null || echo "-")
            if printf '%s %s %s %s\n' \
                "$current_pid" "$(date +%s)" "$current_boot_id" "$current_start_time" > "$lock_dir/owner"; then
                return 0
            fi
            rm -f "$lock_dir/owner" 2>/dev/null || true
            rmdir "$lock_dir" 2>/dev/null || true
            continue
        fi

        local owner_pid=""
        local owner_time=0
        local owner_boot_id=""
        local owner_start_time=""
        local stale_lock=false
        if read -r owner_pid owner_time owner_boot_id owner_start_time 2>/dev/null < "$lock_dir/owner"; then
            local now
            now=$(date +%s)
            if ! [[ "$owner_pid" =~ ^[0-9]+$ ]] || ! [[ "$owner_time" =~ ^[0-9]+$ ]] || \
               ! kill -0 "$owner_pid" 2>/dev/null || [ "$now" -lt "$owner_time" ]; then
                stale_lock=true
            else
                local current_boot_id=""
                local current_start_time=""
                local boot_epoch=""
                [ -r /proc/sys/kernel/random/boot_id ] && \
                    current_boot_id=$(tr -d '\r\n' < /proc/sys/kernel/random/boot_id)
                [ -r "/proc/$owner_pid/stat" ] && \
                    current_start_time=$(awk '{print $22}' "/proc/$owner_pid/stat" 2>/dev/null || true)

                if [ -n "$owner_boot_id" ] && [ "$owner_boot_id" != "-" ] && \
                   [ -n "$current_boot_id" ] && [ "$owner_boot_id" != "$current_boot_id" ]; then
                    stale_lock=true
                elif [ -n "$owner_start_time" ] && [ "$owner_start_time" != "-" ] && \
                     [ -n "$current_start_time" ] && [ "$owner_start_time" != "$current_start_time" ]; then
                    stale_lock=true
                elif [ -z "$owner_boot_id" ] || [ "$owner_boot_id" = "-" ]; then
                    boot_epoch=$(awk '$1 == "btime" {print $2; exit}' /proc/stat 2>/dev/null || true)
                    if [[ "$boot_epoch" =~ ^[0-9]+$ ]] && [ "$owner_time" -lt "$boot_epoch" ]; then
                        stale_lock=true
                    elif [ $((now - owner_time)) -gt "$LEGACY_LOCK_MAX_AGE" ]; then
                        stale_lock=true
                    fi
                fi
            fi
        else
            # 新锁创建后会有极短的 owner 写入窗口，先等待再判断残留锁。
            sleep 1
            if [ ! -s "$lock_dir/owner" ]; then
                stale_lock=true
            fi
        fi
        if [ "$stale_lock" = "true" ]; then
            rm -f "$lock_dir/owner" 2>/dev/null || true
            rmdir "$lock_dir" 2>/dev/null || true
            continue
        fi
        sleep 1
    done
    return 1
}

directory_lock_owned_by_current_process() {
    local lock_dir="$1"
    local owner_pid=""
    local owner_time=""
    local owner_boot_id=""
    local owner_start_time=""
    local current_pid="${BASHPID:-$$}"
    read -r owner_pid owner_time owner_boot_id owner_start_time 2>/dev/null < "$lock_dir/owner" || return 1
    [ "$owner_pid" = "$current_pid" ] || return 1

    if [ -n "$owner_boot_id" ] && [ "$owner_boot_id" != "-" ] && \
       [ -r /proc/sys/kernel/random/boot_id ]; then
        [ "$owner_boot_id" = "$(tr -d '\r\n' < /proc/sys/kernel/random/boot_id)" ] || return 1
    fi
    if [ -n "$owner_start_time" ] && [ "$owner_start_time" != "-" ] && \
       [ -r "/proc/$current_pid/stat" ]; then
        [ "$owner_start_time" = "$(awk '{print $22}' "/proc/$current_pid/stat" 2>/dev/null)" ] || return 1
    fi
}

release_directory_lock() {
    local lock_dir="$1"
    if [ -f "$lock_dir/owner" ] && ! directory_lock_owned_by_current_process "$lock_dir"; then
        return 0
    fi
    rm -f "$lock_dir/owner" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
}

# Dog 与 TrafficCop 会修改同一网卡的 TC 层级。cron 锁仍归各项目所有，
# 但 TC 事务必须共用这一把锁，避免父类和端口子类被并发改成半完成状态。
TC_SHARED_LOCK_DEPTH=0
TC_UPDATE_MIGRATED_LEGACY_TBF=false
TC_UPDATE_LEGACY_TBF_RATE=""

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

acquire_config_lock() {
    acquire_directory_lock "$CONFIG_LOCK_DIR"
}

release_config_lock() {
    release_directory_lock "$CONFIG_LOCK_DIR"
}

acquire_reset_lock() {
    acquire_directory_lock "$RESET_LOCK_DIR"
}

release_reset_lock() {
    release_directory_lock "$RESET_LOCK_DIR"
}

update_config_file() {
    local jq_filter="$1"
    shift

    acquire_config_lock || return 1
    local temp_file
    if ! temp_file=$(mktemp "$CONFIG_DIR/.config.json.tmp.XXXXXX"); then
        release_config_lock
        return 1
    fi
    local result=1
    if jq "$@" "$jq_filter" "$CONFIG_FILE" > "$temp_file"; then
        if mv "$temp_file" "$CONFIG_FILE"; then
            result=0
        else
            rm -f "$temp_file"
        fi
    else
        rm -f "$temp_file"
    fi
    release_config_lock
    return "$result"
}

show_port_list() {
    local active_ports=($(get_active_ports))
    if [ ${#active_ports[@]} -eq 0 ]; then
        echo "暂无监控端口"
        return 1
    fi

    echo "当前监控的端口:"
    for i in "${!active_ports[@]}"; do
        local port=${active_ports[$i]}
        local status_label=$(get_port_status_label "$port")
        echo "$((i+1)). 端口 $port $status_label"
    done
    return 0
}

parse_multi_choice_input() {
    local input="$1"
    local max_choice="$2"
    local -n result_array=$3

    IFS=',' read -ra CHOICES <<< "$input"
    result_array=()

    for choice in "${CHOICES[@]}"; do
        choice=$(echo "$choice" | tr -d ' ')
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$max_choice" ]; then
            result_array+=("$choice")
        else
            echo -e "${RED}无效选择: $choice${NC}"
        fi
    done
}

parse_comma_separated_input() {
    local input="$1"
    local -n result_array=$2

    IFS=',' read -ra result_array <<< "$input"

    for i in "${!result_array[@]}"; do
        result_array[$i]=$(echo "${result_array[$i]}" | tr -d ' ')
    done
}

parse_port_range_input() {
    local input="$1"
    local -n result_array=$2

    IFS=',' read -ra PARTS <<< "$input"
    result_array=()

    for part in "${PARTS[@]}"; do
        part=$(echo "$part" | tr -d ' ')

        if is_port_range "$part"; then
            # 端口段：100-200
            local start_port=$(echo "$part" | cut -d'-' -f1)
            local end_port=$(echo "$part" | cut -d'-' -f2)

            if [ "$start_port" -gt "$end_port" ]; then
                echo -e "${RED}错误：端口段 $part 起始端口大于结束端口${NC}"
                return 1
            fi

            if [ "$start_port" -lt 1 ] || [ "$start_port" -gt 65535 ] || [ "$end_port" -lt 1 ] || [ "$end_port" -gt 65535 ]; then
                echo -e "${RED}错误：端口段 $part 包含无效端口，必须在1-65535范围内${NC}"
                return 1
            fi

            result_array+=("$part")

        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            if [ "$part" -ge 1 ] && [ "$part" -le 65535 ]; then
                result_array+=("$part")
            else
                echo -e "${RED}错误：端口号 $part 无效，必须是1-65535之间的数字${NC}"
                return 1
            fi
        else
            echo -e "${RED}错误：无效的端口格式 $part${NC}"
            return 1
        fi
    done

    return 0
}

expand_single_value_to_array() {
    local -n source_array=$1
    local target_size=$2

    if [ ${#source_array[@]} -eq 1 ]; then
        local single_value="${source_array[0]}"
        source_array=()
        for ((i=0; i<target_size; i++)); do
            source_array+=("$single_value")
        done
    fi
}


get_beijing_month_year() {
    local current_day=$(TZ='Asia/Shanghai' date +%d | sed 's/^0//')
    local current_month=$(TZ='Asia/Shanghai' date +%m | sed 's/^0//')
    local current_year=$(TZ='Asia/Shanghai' date +%Y)
    echo "$current_day $current_month $current_year"
}

get_billing_rule_multiplier() {
    local billing_mode="${1:-single}"
    if [ "$billing_mode" = "double" ]; then
        echo 2
    else
        echo 1
    fi
}

get_counter_rule_multiplier_from_count() {
    local rule_count="${1:-0}"
    local fallback_multiplier="${2:-1}"
    [[ "$fallback_multiplier" =~ ^[0-9]+$ ]] || fallback_multiplier=1
    [ "$fallback_multiplier" -ge 1 ] || fallback_multiplier=1
    if [[ "$rule_count" =~ ^[0-9]+$ ]] && [ "$rule_count" -ge 4 ] && [ $((rule_count % 4)) -eq 0 ]; then
        echo $((rule_count / 4))
    else
        # 部分规则损坏时无法从数量推断历史倍率，保留当前模式倍率可避免修复时再次放大 counter。
        echo "$fallback_multiplier"
    fi
}

scale_counter_for_rule_multiplier() {
    local counter_bytes="${1:-0}"
    local source_multiplier="${2:-1}"
    local target_multiplier="${3:-1}"
    [[ "$counter_bytes" =~ ^[0-9]+$ ]] || counter_bytes=0
    [[ "$source_multiplier" =~ ^[0-9]+$ ]] || source_multiplier=1
    [[ "$target_multiplier" =~ ^[0-9]+$ ]] || target_multiplier=1
    [ "$source_multiplier" -ge 1 ] || source_multiplier=1
    [ "$target_multiplier" -ge 1 ] || target_multiplier=1
    echo $((counter_bytes * target_multiplier / source_multiplier))
}

get_expected_counter_rule_count() {
    local billing_mode="${1:-single}"
    local multiplier
    multiplier=$(get_billing_rule_multiplier "$billing_mode")
    echo $((4 * multiplier))
}

get_expected_quota_rule_count() {
    local billing_mode="${1:-single}"
    local multiplier
    multiplier=$(get_billing_rule_multiplier "$billing_mode")
    echo $((8 * multiplier))
}

get_nftables_counter_data() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local input_bytes=0
    local output_bytes=0

    if is_port_range "$port"; then
        local port_safe=$(echo "$port" | tr '-' '_')
        input_bytes=$(nft list counter $family $table_name "port_${port_safe}_in" 2>/dev/null | \
            grep -o 'bytes [0-9]*' | awk '{print $2}' || true)
        output_bytes=$(nft list counter $family $table_name "port_${port_safe}_out" 2>/dev/null | \
            grep -o 'bytes [0-9]*' | awk '{print $2}' || true)
    else
        input_bytes=$(nft list counter $family $table_name "port_${port}_in" 2>/dev/null | \
            grep -o 'bytes [0-9]*' | awk '{print $2}' || true)
        output_bytes=$(nft list counter $family $table_name "port_${port}_out" 2>/dev/null | \
            grep -o 'bytes [0-9]*' | awk '{print $2}' || true)
    fi

    input_bytes=${input_bytes:-0}
    output_bytes=${output_bytes:-0}
    echo "$input_bytes $output_bytes"
}

get_nftables_quota_used() {
    local port="$1"
    local table_name
    local family
    local quota_name
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    quota_name=$(get_port_quota_name "$port")

    local quota_used
    quota_used=$(nft -j list quota "$family" "$table_name" "$quota_name" 2>/dev/null |
        jq -r '.nftables[] | select(.quota != null) | .quota.used // 0' 2>/dev/null |
        head -n1)
    if [[ "$quota_used" =~ ^[0-9]+$ ]]; then
        echo "$quota_used"
        return 0
    fi

    local quota_output
    quota_output=$(nft list quota "$family" "$table_name" "$quota_name" 2>/dev/null) || return 1
    quota_used=$(printf '%s\n' "$quota_output" |
        sed -n 's/.*used \([0-9][0-9]*\) bytes.*/\1/p' |
        head -n1)
    if [[ "$quota_used" =~ ^[0-9]+$ ]]; then
        echo "$quota_used"
        return 0
    fi
    # 文本输出省略 used 字段时表示尚未产生流量。
    echo 0
}

get_nftables_quota_limit_bytes() {
    local port="$1"
    local table_name
    local family
    local quota_name
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    quota_name=$(get_port_quota_name "$port")

    local quota_bytes
    quota_bytes=$(nft -j list quota "$family" "$table_name" "$quota_name" 2>/dev/null |
        jq -r '.nftables[] | select(.quota != null) | .quota.bytes // empty' 2>/dev/null |
        head -n1)
    [[ "$quota_bytes" =~ ^[0-9]+$ ]] || return 1
    echo "$quota_bytes"
}

nftables_quota_limit_matches() {
    local port="$1"
    local quota_limit="$2"
    local expected_bytes
    local actual_bytes
    expected_bytes=$(parse_size_to_bytes "$quota_limit" 2>/dev/null || echo 0)
    [[ "$expected_bytes" =~ ^[0-9]+$ ]] && [ "$expected_bytes" -gt 0 ] || return 1
    actual_bytes=$(get_nftables_quota_limit_bytes "$port") || return 1
    [ "$actual_bytes" -eq "$expected_bytes" ]
}

get_port_runtime_usage_snapshot() {
    local port="$1"
    local table_name
    local family
    local prefix
    local snapshot
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    prefix=$(get_port_counter_prefix "$port")

    snapshot=$(nft -j list table "$family" "$table_name" 2>/dev/null |
        jq -r \
            --arg input "${prefix}_in" \
            --arg output "${prefix}_out" \
            --arg quota "${prefix}_quota" '
            ([.nftables[] | .counter? |
                select(type == "object" and .name == $input) | .bytes // 0][0] // -1) as $in |
            ([.nftables[] | .counter? |
                select(type == "object" and .name == $output) | .bytes // 0][0] // -1) as $out |
            ([.nftables[] | .quota? |
                select(type == "object" and .name == $quota) | .used // 0][0] // -1) as $used |
            "\($in) \($out) \($used)"
        ') || return 1
    [[ "$snapshot" =~ ^[0-9]+\ [0-9]+\ -?[0-9]+$ ]] || return 1
    echo "$snapshot"
}

port_counter_quota_usage_consistent() {
    local port="$1"
    [ -d "$RESET_LOCK_DIR" ] && return 0
    [ "$(get_quota_enabled "$port")" = "true" ] || return 0
    local quota_limit
    quota_limit=$(get_quota_limit "$port")
    [ "$quota_limit" != "unlimited" ] || return 0

    local first=()
    local second=()
    local quota_used
    read -r -a first < <(get_nftables_counter_data "$port")
    quota_used=$(get_nftables_quota_used "$port") || return 1
    read -r -a second < <(get_nftables_counter_data "$port")
    local first_total=$(( ${first[0]:-0} + ${first[1]:-0} ))
    local second_total=$(( ${second[0]:-0} + ${second[1]:-0} ))
    local lower_total="$first_total"
    local upper_total="$second_total"
    if [ "$lower_total" -gt "$upper_total" ]; then
        lower_total="$second_total"
        upper_total="$first_total"
    fi

    # quota 在两次 counter 读取之间采样；1MiB 仅用于容纳单个大包/GSO 与命令读取抖动。
    local tolerance=$((1024 * 1024))
    [ $((quota_used + tolerance)) -ge "$lower_total" ] || return 1

    local limit_bytes
    limit_bytes=$(parse_size_to_bytes "$quota_limit" 2>/dev/null || echo 0)
    if [[ "$limit_bytes" =~ ^[0-9]+$ ]] && [ "$quota_used" -lt "$limit_bytes" ]; then
        [ "$quota_used" -le $((upper_total + tolerance)) ] || return 1
    fi
}

port_counter_objects_exist() {
    local port="$1"
    local table_name
    local family
    local prefix
    table_name=$(jq -r '.nftables.table_name // "port_traffic_monitor"' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family // "inet"' "$CONFIG_FILE")
    prefix=$(get_port_counter_prefix "$port")
    nft list counter "$family" "$table_name" "${prefix}_in" >/dev/null 2>&1 &&
        nft list counter "$family" "$table_name" "${prefix}_out" >/dev/null 2>&1
}

runtime_counter_objects_complete() {
    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    local port
    for port in "${active_ports[@]}"; do
        port_counter_objects_exist "$port" || return 1
    done
}

write_traffic_backup_metadata() {
    local data_file="$1"
    [ -f "$data_file" ] || return 1

    local current_model
    current_model=$(jq -r '.global.traffic_accounting_model // ""' "$CONFIG_FILE" 2>/dev/null || true)
    [ "$current_model" = "$TRAFFIC_ACCOUNTING_MODEL" ] || return 0

    local metadata_temp
    metadata_temp=$(mktemp "$CONFIG_DIR/.traffic_data.metadata.XXXXXX") || return 1
    if ! jq \
        --arg model "$TRAFFIC_ACCOUNTING_MODEL" \
        --slurpfile config "$CONFIG_FILE" \
        '
        ._meta = {
            schema_version: 2,
            traffic_accounting_model: $model,
            port_multipliers: (
                ($config[0].ports // {}) |
                with_entries(
                    .value = if (.value.billing_mode // "double") == "double" then
                        {input: 2, output: 2}
                    else
                        {input: 1, output: 1}
                    end
                )
            )
        }
        ' "$data_file" > "$metadata_temp" || ! mv "$metadata_temp" "$data_file"; then
        rm -f "$metadata_temp"
        return 1
    fi
}

get_traffic_backup_rule_multiplier() {
    local port="$1"
    local direction="$2"
    local target_multiplier="$3"
    [ -f "$TRAFFIC_DATA_FILE" ] || return 1

    local backup_multiplier
    backup_multiplier=$(jq -r \
        --arg port "$port" \
        --arg direction "$direction" \
        --arg model "$TRAFFIC_ACCOUNTING_MODEL" \
        --argjson target "$target_multiplier" \
        '
        if ((._meta.port_multipliers[$port][$direction] // 0) | type) == "number" and
           (._meta.port_multipliers[$port][$direction] // 0) >= 1 then
            ._meta.port_multipliers[$port][$direction]
        elif (._meta.traffic_accounting_model // "") == $model then
            $target
        else
            empty
        end
        ' "$TRAFFIC_DATA_FILE" 2>/dev/null || true)
    [[ "$backup_multiplier" =~ ^[0-9]+$ ]] && [ "$backup_multiplier" -ge 1 ] || return 1
    echo "$backup_multiplier"
}

resolve_legacy_counter_multiplier() {
    local port="$1"
    local direction="$2"
    local rule_count="$3"
    local target_multiplier="$4"
    local counter_bytes="$5"

    if [[ "$rule_count" =~ ^[0-9]+$ ]] && [ "$rule_count" -ge 4 ] && [ $((rule_count % 4)) -eq 0 ]; then
        echo $((rule_count / 4))
        return 0
    fi
    if [[ "$rule_count" =~ ^[0-9]+$ ]] && [ "$rule_count" -gt 0 ]; then
        echo "$target_multiplier"
        return 0
    fi
    if get_traffic_backup_rule_multiplier "$port" "$direction" "$target_multiplier"; then
        return 0
    fi
    if [[ "$counter_bytes" =~ ^[0-9]+$ ]] && [ "$counter_bytes" -eq 0 ]; then
        echo "$target_multiplier"
        return 0
    fi
    return 1
}



save_traffic_data_locked() {
    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)

    if [ ${#active_ports[@]} -eq 0 ]; then
        rm -f "$TRAFFIC_DATA_FILE"
        return 0
    fi

    local port
    for port in "${active_ports[@]}"; do
        if ! port_counter_objects_exist "$port"; then
            return 1
        fi
    done

    mkdir -p "$CONFIG_DIR"
    local entries_file
    local temp_file
    entries_file=$(mktemp "$CONFIG_DIR/.traffic_data.entries.XXXXXX") || return 1
    temp_file=$(mktemp "$CONFIG_DIR/.traffic_data.json.tmp.XXXXXX") || {
        rm -f "$entries_file"
        return 1
    }
    local backup_time
    backup_time=$(get_beijing_time -Iseconds)

    for port in "${active_ports[@]}"; do
        local traffic_data=()
        read -r -a traffic_data < <(get_nftables_counter_data "$port")
        local current_input=${traffic_data[0]}
        local current_output=${traffic_data[1]}
        [[ "$current_input" =~ ^[0-9]+$ ]] || current_input=0
        [[ "$current_output" =~ ^[0-9]+$ ]] || current_output=0
        jq -cn \
            --arg port "$port" \
            --arg time "$backup_time" \
            --argjson input "$current_input" \
            --argjson output "$current_output" \
            '{key:$port,value:{input:$input,output:$output,backup_time:$time}}' >> "$entries_file" || {
            rm -f "$entries_file" "$temp_file"
            return 1
        }
    done

    if ! jq -s 'from_entries' "$entries_file" > "$temp_file" ||
       ! write_traffic_backup_metadata "$temp_file" ||
       ! mv "$temp_file" "$TRAFFIC_DATA_FILE"; then
        rm -f "$entries_file" "$temp_file"
        return 1
    fi
    chmod 600 "$TRAFFIC_DATA_FILE" 2>/dev/null || true
    rm -f "$entries_file"
}

save_traffic_data() {
    if directory_lock_owned_by_current_process "$TRAFFIC_STATS_LOCK_DIR"; then
        save_traffic_data_locked
        return $?
    fi
    acquire_traffic_stats_lock || return 1
    local result=0
    save_traffic_data_locked || result=$?
    release_traffic_stats_lock
    return "$result"
}

setup_exit_hooks() {
    # 进程退出时自动保存数据，避免重启丢失
    trap 'save_traffic_data_on_exit' EXIT
    trap 'save_traffic_data_on_exit; exit 1' INT TERM
}

save_traffic_data_on_exit() {
    save_traffic_data >/dev/null 2>&1
}

restore_monitoring_if_needed() {
    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)

    if [ ${#active_ports[@]} -eq 0 ]; then
        return 0
    fi

    local need_restore=false

    local port
    for port in "${active_ports[@]}"; do
        if ! port_runtime_rules_complete "$port"; then
            need_restore=true
            break
        fi
    done

    if [ "$need_restore" = "true" ]; then
        restore_runtime_state
    fi
}

restore_traffic_data_from_backup() {
    if [ ! -f "$TRAFFIC_DATA_FILE" ]; then
        return 0
    fi

    if ! jq -e 'type == "object"' "$TRAFFIC_DATA_FILE" >/dev/null 2>&1; then
        return 1
    fi

    local backup_ports=()
    mapfile -t backup_ports < <(jq -r 'keys[]' "$TRAFFIC_DATA_FILE" 2>/dev/null | tr -d '\r' || true)
    local failed=false

    local port
    for port in "${backup_ports[@]}"; do
        if ! jq -e --arg port "$port" '.ports[$port] != null' "$CONFIG_FILE" >/dev/null 2>&1; then
            continue
        fi
        local backup_input
        local backup_output
        backup_input=$(jq -r --arg port "$port" '.[$port].input // 0' "$TRAFFIC_DATA_FILE" 2>/dev/null || echo "0")
        backup_output=$(jq -r --arg port "$port" '.[$port].output // 0' "$TRAFFIC_DATA_FILE" 2>/dev/null || echo "0")
        [[ "$backup_input" =~ ^[0-9]+$ ]] || backup_input=0
        [[ "$backup_output" =~ ^[0-9]+$ ]] || backup_output=0

        if ! restore_counter_value "$port" "$backup_input" "$backup_output"; then
            failed=true
        fi
    done

    [ "$failed" = "false" ]
}

restore_counter_value() {
    local port=$1
    local target_input=$2
    local target_output=$3
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")

    [[ "$target_input" =~ ^[0-9]+$ ]] || return 1
    [[ "$target_output" =~ ^[0-9]+$ ]] || return 1

    local prefix
    prefix=$(get_port_counter_prefix "$port")
    nft add counter "$family" "$table_name" "${prefix}_in" { packets 0 bytes "$target_input" } 2>/dev/null || true
    nft add counter "$family" "$table_name" "${prefix}_out" { packets 0 bytes "$target_output" } 2>/dev/null || true

    local restored_data=()
    read -r -a restored_data < <(get_nftables_counter_data "$port")
    [ "${restored_data[0]:--1}" = "$target_input" ] && [ "${restored_data[1]:--1}" = "$target_output" ]
}

restore_all_monitoring_rules() {
    restore_runtime_state
}

restore_port_counters_from_backup() {
    local port="$1"
    acquire_traffic_stats_lock || return 1

    local current_data=()
    read -r -a current_data < <(get_nftables_counter_data "$port")
    local target_input=${current_data[0]:-0}
    local target_output=${current_data[1]:-0}
    [[ "$target_input" =~ ^[0-9]+$ ]] || target_input=0
    [[ "$target_output" =~ ^[0-9]+$ ]] || target_output=0

    if [ -f "$TRAFFIC_DATA_FILE" ] && jq -e --arg port "$port" '.[$port] | type == "object"' "$TRAFFIC_DATA_FILE" >/dev/null 2>&1; then
        local backup_input
        local backup_output
        backup_input=$(jq -r --arg port "$port" '.[$port].input // 0' "$TRAFFIC_DATA_FILE")
        backup_output=$(jq -r --arg port "$port" '.[$port].output // 0' "$TRAFFIC_DATA_FILE")
        [[ "$backup_input" =~ ^[0-9]+$ ]] || backup_input=0
        [[ "$backup_output" =~ ^[0-9]+$ ]] || backup_output=0
        [ "$backup_input" -gt "$target_input" ] && target_input=$backup_input
        [ "$backup_output" -gt "$target_output" ] && target_output=$backup_output
    fi

    local result=0
    rebuild_port_counter_objects \
        "$port" "$target_input" "$target_output" rebuild || result=$?
    release_traffic_stats_lock
    return "$result"
}

port_runtime_rules_complete() {
    local port="$1"
    port_counter_objects_exist "$port" || return 1

    local billing_mode
    billing_mode=$(jq -r --arg port "$port" '.ports[$port].billing_mode // "double"' "$CONFIG_FILE")
    local expected_counter_count
    expected_counter_count=$(get_expected_counter_rule_count "$billing_mode")
    [ "$(count_counter_rules "$port" in)" -eq "$expected_counter_count" ] || return 1
    [ "$(count_counter_rules "$port" out)" -eq "$expected_counter_count" ] || return 1

    local expected_quota_count=0
    local quota_enabled
    local monthly_limit
    quota_enabled=$(jq -r --arg port "$port" '.ports[$port].quota.enabled // true' "$CONFIG_FILE")
    monthly_limit=$(jq -r --arg port "$port" '.ports[$port].quota.monthly_limit // "unlimited"' "$CONFIG_FILE")
    if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ]; then
        expected_quota_count=$(get_expected_quota_rule_count "$billing_mode")
    fi
    [ "$(count_quota_rules "$port")" -eq "$expected_quota_count" ] || return 1
    if [ "$expected_quota_count" -gt 0 ]; then
        nftables_quota_limit_matches "$port" "$monthly_limit"
    else
        nftables_quota_is_absent "$port"
    fi
}

restore_runtime_state() {
    validate_config_file "$CONFIG_FILE" >/dev/null || return 1
    init_nftables
    local convert_legacy_multiplier=false
    if [ "$(jq -r '.global.traffic_accounting_model // ""' "$CONFIG_FILE" 2>/dev/null || true)" != "$TRAFFIC_ACCOUNTING_MODEL" ]; then
        convert_legacy_multiplier=true
    fi
    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    local failed=false
    local port
    local tc_ports=()
    local tc_limits=()

    if ! reconcile_orphaned_runtime_objects; then
        log_notification "orphaned nftables runtime objects could not be reconciled"
        failed=true
    fi

    for port in "${active_ports[@]}"; do
        if ! port_counter_objects_exist "$port"; then
            if ! restore_port_counters_from_backup "$port"; then
                failed=true
                continue
            fi
        fi

        if ! repair_port_traffic_rules "$port" false "$convert_legacy_multiplier" >/dev/null 2>&1 ||
           ! repair_port_quota_rules "$port" >/dev/null 2>&1; then
            failed=true
            continue
        fi

        local limit_enabled
        local rate_limit
        limit_enabled=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.enabled // false' "$CONFIG_FILE")
        rate_limit=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.rate // "unlimited"' "$CONFIG_FILE")
        if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
            local tc_limit
            tc_limit=$(convert_bandwidth_to_tc "$rate_limit")
            if [ -n "$tc_limit" ]; then
                tc_ports+=("$port")
                tc_limits+=("$tc_limit")
            fi
        fi
    done

    if [ ${#tc_ports[@]} -gt 0 ]; then
        if begin_tc_update; then
            local restore_interface
            restore_interface=$(get_default_interface 2>/dev/null || true)
            # 先在完整旧层级仍可验证时认领/规范化，再删除端口对象。否则从
            # v1.5.2 直接升级时会先销毁归属证据，导致后续安全检查拒绝恢复。
            if [ -z "$restore_interface" ] ||
               ! ensure_owned_tc_hierarchy_locked "$restore_interface"; then
                failed=true
            else
                local tc_index
                for tc_index in "${!tc_ports[@]}"; do
                    remove_tc_limit_locked "${tc_ports[$tc_index]}" >/dev/null 2>&1 || true
                    apply_tc_limit_locked "${tc_ports[$tc_index]}" "${tc_limits[$tc_index]}" >/dev/null 2>&1 || failed=true
                done
            fi
            if [ "$failed" = "true" ] && [ "$TC_UPDATE_MIGRATED_LEGACY_TBF" = "true" ]; then
                local rollback_interface
                rollback_interface=$(get_default_interface 2>/dev/null || true)
                if [ -n "$rollback_interface" ]; then
                    rollback_legacy_trafficcop_tbf "$rollback_interface" >/dev/null 2>&1 || true
                fi
            fi
            finish_tc_update
        else
            log_notification "无法取得共享TC锁，已停止恢复端口限速"
            failed=true
        fi
    fi
    [ "$failed" = "false" ]
}

calculate_total_traffic() {
    local input_bytes=$1
    local output_bytes=$2
    # 计费倍率已经由 nftables 规则体现：双向每个方向 ×2，单向每个方向 ×1。
    echo $((input_bytes + output_bytes))
}

extract_hour_minute_from_iso() {
    local time_value="$1"
    if [[ "$time_value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T([0-9]{2}):([0-9]{2}) ]]; then
        echo "$((10#${BASH_REMATCH[1]})) $((10#${BASH_REMATCH[2]}))"
        return 0
    fi
    return 1
}

should_carry_cross_day_snapshot_delta() {
    local state_date="$1"
    local state_time="$2"
    local snapshot_date="$3"
    local snapshot_time="$4"

    is_valid_date "$state_date" || return 1
    [ "$(add_days_to_date "$snapshot_date" -1 2>/dev/null || true)" = "$state_date" ] || return 1
    [[ "$state_time" == "$state_date"T* ]] || return 1
    [[ "$snapshot_time" == "$snapshot_date"T* ]] || return 1

    local last_hm=()
    local current_hm=()
    read -r -a last_hm < <(extract_hour_minute_from_iso "$state_time") || return 1
    read -r -a current_hm < <(extract_hour_minute_from_iso "$snapshot_time") || return 1

    [ "${last_hm[0]}" -eq 23 ] || return 1
    [ "${last_hm[1]}" -eq 59 ] || return 1
    [ "${current_hm[0]}" -eq 0 ] || return 1
    [ "${current_hm[1]}" -eq 0 ] || return 1
}

acquire_traffic_stats_lock() {
    acquire_directory_lock "$TRAFFIC_STATS_LOCK_DIR"
}

release_traffic_stats_lock() {
    release_directory_lock "$TRAFFIC_STATS_LOCK_DIR"
}

ensure_traffic_stats_file() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$TRAFFIC_STATS_FILE" ]; then
        printf '{"last_snapshot":{},"daily":{}}\n' > "$TRAFFIC_STATS_FILE"
        return 0
    fi
    if ! jq empty "$TRAFFIC_STATS_FILE" >/dev/null 2>&1; then
        local corrupt_file="${TRAFFIC_STATS_FILE}.corrupt.$(date +%s).${BASHPID:-$$}"
        mv "$TRAFFIC_STATS_FILE" "$corrupt_file" || return 1
        chmod 600 "$corrupt_file" 2>/dev/null || true
        return 1
    fi

    if ! jq 'has("last_snapshot") and has("daily")' "$TRAFFIC_STATS_FILE" 2>/dev/null | grep -q true; then
        local temp_file
        temp_file=$(mktemp "$CONFIG_DIR/.traffic_stats.json.tmp.XXXXXX")
        if jq '
            .last_snapshot = (.last_snapshot // {}) |
            .daily = (.daily // {})
        ' "$TRAFFIC_STATS_FILE" > "$temp_file"; then
            mv "$temp_file" "$TRAFFIC_STATS_FILE"
        else
            rm -f "$temp_file"
            return 1
        fi
    fi
}

record_traffic_snapshot() {
    [ -f "$CONFIG_FILE" ] || return 0
    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    [ ${#active_ports[@]} -gt 0 ] || return 0

    local port
    for port in "${active_ports[@]}"; do
        port_counter_objects_exist "$port" || return 1
    done

    acquire_traffic_stats_lock || return 1
    if ! ensure_traffic_stats_file; then
        release_traffic_stats_lock
        return 1
    fi

    local snapshot_date
    snapshot_date=$(get_current_date)
    local snapshot_time
    snapshot_time=$(get_beijing_time -Iseconds)
    local retention_days
    retention_days=$(jq -r --argjson fallback "$DEFAULT_TRAFFIC_RETENTION_DAYS" \
        '.global.data_retention_days // $fallback' "$CONFIG_FILE" 2>/dev/null || echo "$DEFAULT_TRAFFIC_RETENTION_DAYS")
    if ! [[ "$retention_days" =~ ^[0-9]+$ ]] || [ "$retention_days" -lt 1 ] || [ "$retention_days" -gt 3650 ]; then
        retention_days=$DEFAULT_TRAFFIC_RETENTION_DAYS
    fi
    local retention_cutoff
    retention_cutoff=$(add_days_to_date "$snapshot_date" "-$retention_days")

    local updates_file
    local stats_temp
    local backup_temp
    local states_file
    updates_file=$(mktemp "$CONFIG_DIR/.traffic_snapshot.updates.XXXXXX") || {
        release_traffic_stats_lock
        return 1
    }
    stats_temp=$(mktemp "$CONFIG_DIR/.traffic_stats.json.tmp.XXXXXX") || {
        rm -f "$updates_file"
        release_traffic_stats_lock
        return 1
    }
    backup_temp=$(mktemp "$CONFIG_DIR/.traffic_data.json.tmp.XXXXXX") || {
        rm -f "$updates_file" "$stats_temp"
        release_traffic_stats_lock
        return 1
    }
    states_file=$(mktemp "$CONFIG_DIR/.traffic_snapshot.states.XXXXXX") || {
        rm -f "$updates_file" "$stats_temp" "$backup_temp"
        release_traffic_stats_lock
        return 1
    }

    # 一次读取全部端口的历史状态，避免端口数和历史天数增大时反复解析同一个 JSON。
    local ports_json
    ports_json=$(printf '%s\n' "${active_ports[@]}" |
        jq -Rsc 'split("\n") | map(select(length > 0))') || {
        rm -f "$updates_file" "$stats_temp" "$backup_temp" "$states_file"
        release_traffic_stats_lock
        return 1
    }
    if ! jq -r --arg date "$snapshot_date" --argjson ports "$ports_json" '
        . as $root |
        $ports[] as $port |
        ($root.state[$port] // {}) as $s |
        ($s.date // "") as $state_date |
        [
            $state_date,
            ($s.time // $root.last_snapshot[$port].time // ""),
            ($s.input_base // 0),
            ($s.output_base // 0),
            ($s.input_offset // 0),
            ($s.output_offset // 0),
            ($s.last_input // 0),
            ($s.last_output // 0),
            ($root.daily[$port][$date].input // 0),
            ($root.daily[$port][$date].output // 0),
            ($root.daily[$port][$state_date].input // 0),
            ($root.daily[$port][$state_date].output // 0)
        ] | map(tostring) | join("|")
    ' "$TRAFFIC_STATS_FILE" > "$states_file"; then
        rm -f "$updates_file" "$stats_temp" "$backup_temp" "$states_file"
        release_traffic_stats_lock
        return 1
    fi

    exec 3< "$states_file"
    for port in "${active_ports[@]}"; do
        local traffic_data=()
        read -r -a traffic_data < <(get_nftables_counter_data "$port")
        local current_input=${traffic_data[0]:-0}
        local current_output=${traffic_data[1]:-0}
        [[ "$current_input" =~ ^[0-9]+$ ]] || current_input=0
        [[ "$current_output" =~ ^[0-9]+$ ]] || current_output=0

        local snapshot_state
        if ! IFS= read -r snapshot_state <&3; then
            exec 3<&-
            rm -f "$updates_file" "$stats_temp" "$backup_temp" "$states_file"
            release_traffic_stats_lock
            return 1
        fi
        local state_date state_time input_base output_base input_offset output_offset
        local last_input last_output existing_input existing_output previous_input previous_output
        IFS='|' read -r state_date state_time input_base output_base input_offset output_offset \
            last_input last_output existing_input existing_output previous_input previous_output <<< "$snapshot_state"
        local has_state=false
        if [ "$state_date" = "$snapshot_date" ]; then
            has_state=true
        fi

        for value_name in input_base output_base input_offset output_offset last_input last_output \
            existing_input existing_output previous_input previous_output current_input current_output; do
            local value="${!value_name}"
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                printf -v "$value_name" '%s' 0
            fi
        done

        local rollover_date=""
        local rollover_input=0
        local rollover_output=0

        if [ "$has_state" != "true" ]; then
            local cross_day_input=0
            local cross_day_output=0
            if is_valid_date "$state_date" && [ "$state_date" != "$snapshot_date" ] &&
               date_le "$state_date" "$snapshot_date"; then
                if [ "$current_input" -ge "$last_input" ]; then
                    cross_day_input=$((current_input - last_input))
                fi
                if [ "$current_output" -ge "$last_output" ]; then
                    cross_day_output=$((current_output - last_output))
                fi
            fi
            if should_carry_cross_day_snapshot_delta "$state_date" "$state_time" "$snapshot_date" "$snapshot_time"; then
                if [ "$cross_day_input" -gt 0 ] || [ "$cross_day_output" -gt 0 ]; then
                    rollover_date="$state_date"
                    rollover_input=$((previous_input + cross_day_input))
                    rollover_output=$((previous_output + cross_day_output))
                fi
            elif [ "$cross_day_input" -gt 0 ] || [ "$cross_day_output" -gt 0 ]; then
                # 无法精确拆分跨日区间时归入当前日，保留总量且避免污染已结束的账期。
                existing_input=$((existing_input + cross_day_input))
                existing_output=$((existing_output + cross_day_output))
            fi
            input_base="$current_input"
            output_base="$current_output"
            input_offset="$existing_input"
            output_offset="$existing_output"
            last_input="$current_input"
            last_output="$current_output"
        elif [ "$current_input" -lt "$last_input" ]; then
            input_offset="$existing_input"
            input_base=0
        fi
        if [ "$has_state" = "true" ] && [ "$current_output" -lt "$last_output" ]; then
            output_offset="$existing_output"
            output_base=0
        fi

        local total_input
        if [ "$current_input" -ge "$input_base" ]; then
            total_input=$((input_offset + current_input - input_base))
        else
            total_input=$((input_offset + current_input))
        fi

        local total_output
        if [ "$current_output" -ge "$output_base" ]; then
            total_output=$((output_offset + current_output - output_base))
        else
            total_output=$((output_offset + current_output))
        fi

        if ! printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$port" "$snapshot_date" "$snapshot_time" "$rollover_date" \
            "$current_input" "$current_output" "$input_base" "$output_base" \
            "$input_offset" "$output_offset" "$total_input" "$total_output" \
            "$rollover_input" "$rollover_output" >> "$updates_file"; then
            exec 3<&-
            rm -f "$updates_file" "$stats_temp" "$backup_temp" "$states_file"
            release_traffic_stats_lock
            return 1
        fi
    done
    exec 3<&-
    rm -f "$states_file"

    local updates_json
    updates_json=$(mktemp "$CONFIG_DIR/.traffic_snapshot.json.XXXXXX") || {
        rm -f "$updates_file" "$stats_temp" "$backup_temp"
        release_traffic_stats_lock
        return 1
    }
    if ! jq -Rn '
        inputs |
        split("|") as $v |
        {
            port:$v[0], date:$v[1], time:$v[2], rollover_date:$v[3],
            cin:($v[4] | tonumber), cout:($v[5] | tonumber),
            ibase:($v[6] | tonumber), obase:($v[7] | tonumber),
            ioffset:($v[8] | tonumber), ooffset:($v[9] | tonumber),
            tin:($v[10] | tonumber), tout:($v[11] | tonumber),
            rin:($v[12] | tonumber), rout:($v[13] | tonumber)
        }
    ' "$updates_file" > "$updates_json"; then
        rm -f "$updates_file" "$updates_json" "$stats_temp" "$backup_temp"
        release_traffic_stats_lock
        return 1
    fi
    mv "$updates_json" "$updates_file"

    if ! jq --slurpfile updates "$updates_file" --arg cutoff "$retention_cutoff" '
        .last_snapshot = (.last_snapshot // {}) |
        .state = (.state // {}) |
        .daily = (.daily // {}) |
        reduce $updates[] as $u (.;
            .daily[$u.port] = (.daily[$u.port] // {}) |
            if $u.rollover_date != "" then
                .daily[$u.port][$u.rollover_date] = ((.daily[$u.port][$u.rollover_date] // {}) + {
                    input:$u.rin, output:$u.rout, time:$u.time, closed_by_next_day_snapshot:true
                })
            else . end |
            .daily[$u.port][$u.date] = {input:$u.tin, output:$u.tout, time:$u.time} |
            .state[$u.port] = {
                date:$u.date, input_base:$u.ibase, output_base:$u.obase,
                input_offset:$u.ioffset, output_offset:$u.ooffset,
                last_input:$u.cin, last_output:$u.cout, time:$u.time
            } |
            .last_snapshot[$u.port] = {input:$u.cin, output:$u.cout, date:$u.date, time:$u.time}
        ) |
        .daily |= with_entries(.value |= with_entries(select(.key >= $cutoff)))
    ' "$TRAFFIC_STATS_FILE" > "$stats_temp" ||
       ! jq -s 'map({key:.port,value:{input:.cin,output:.cout,backup_time:.time}}) | from_entries' \
            "$updates_file" > "$backup_temp" ||
       ! write_traffic_backup_metadata "$backup_temp"; then
        rm -f "$updates_file" "$stats_temp" "$backup_temp" "$states_file"
        release_traffic_stats_lock
        return 1
    fi

    if ! mv "$backup_temp" "$TRAFFIC_DATA_FILE" || ! mv "$stats_temp" "$TRAFFIC_STATS_FILE"; then
        rm -f "$updates_file" "$stats_temp" "$backup_temp" "$states_file"
        release_traffic_stats_lock
        return 1
    fi
    chmod 600 "$TRAFFIC_STATS_FILE" "$TRAFFIC_DATA_FILE" 2>/dev/null || true
    rm -f "$updates_file"

    release_traffic_stats_lock
}

update_traffic_snapshot_baseline_locked() {
    local port="$1"
    local mode="${2:-preserve_today}"
    local input_adjustment="${3:-0}"
    local output_adjustment="${4:-0}"
    [ -f "$CONFIG_FILE" ] || return 0
    ensure_traffic_stats_file || return 1
    [[ "$input_adjustment" =~ ^[0-9]+$ ]] || return 1
    [[ "$output_adjustment" =~ ^[0-9]+$ ]] || return 1

    local traffic_data=($(get_nftables_counter_data "$port"))
    local current_input=${traffic_data[0]:-0}
    local current_output=${traffic_data[1]:-0}
    [[ "$current_input" =~ ^[0-9]+$ ]] || current_input=0
    [[ "$current_output" =~ ^[0-9]+$ ]] || current_output=0
    local snapshot_date
    snapshot_date=$(get_current_date)
    local snapshot_time
    snapshot_time=$(get_beijing_time -Iseconds)
    local existing_input
    existing_input=$(jq -r --arg port "$port" --arg date "$snapshot_date" '.daily[$port][$date].input // 0' "$TRAFFIC_STATS_FILE" 2>/dev/null || echo 0)
    local existing_output
    existing_output=$(jq -r --arg port "$port" --arg date "$snapshot_date" '.daily[$port][$date].output // 0' "$TRAFFIC_STATS_FILE" 2>/dev/null || echo 0)
    [[ "$existing_input" =~ ^[0-9]+$ ]] || existing_input=0
    [[ "$existing_output" =~ ^[0-9]+$ ]] || existing_output=0
    if [ "$mode" = "reset_today" ]; then
        existing_input=0
        existing_output=0
    else
        existing_input=$((existing_input + input_adjustment))
        existing_output=$((existing_output + output_adjustment))
    fi

    local stats_temp
    local backup_temp
    stats_temp=$(mktemp "$CONFIG_DIR/.traffic_stats.json.tmp.XXXXXX") || return 1
    backup_temp=$(mktemp "$CONFIG_DIR/.traffic_data.json.tmp.XXXXXX") || {
        rm -f "$stats_temp"
        return 1
    }

    if jq \
        --arg port "$port" \
        --arg date "$snapshot_date" \
        --arg time "$snapshot_time" \
        --argjson cin "$current_input" \
        --argjson cout "$current_output" \
        --argjson ein "$existing_input" \
        --argjson eout "$existing_output" \
        '
        .last_snapshot = (.last_snapshot // {}) |
        .state = (.state // {}) |
        .daily = (.daily // {}) |
        .daily[$port] = (.daily[$port] // {}) |
        .daily[$port][$date] = {
            "input": $ein,
            "output": $eout,
            "time": $time
        } |
        .state[$port] = {
            "date": $date,
            "input_base": $cin,
            "output_base": $cout,
            "input_offset": $ein,
            "output_offset": $eout,
            "last_input": $cin,
            "last_output": $cout,
            "time": $time
        } |
        .last_snapshot[$port] = {
            "input": $cin,
            "output": $cout,
            "date": $date,
            "time": $time
        }
        ' "$TRAFFIC_STATS_FILE" > "$stats_temp"; then
        :
    else
        rm -f "$stats_temp" "$backup_temp"
        return 1
    fi

    if [ -f "$TRAFFIC_DATA_FILE" ] &&
       jq -e 'type == "object"' "$TRAFFIC_DATA_FILE" >/dev/null 2>&1; then
        if ! jq \
            --arg port "$port" \
            --arg time "$snapshot_time" \
            --argjson input "$current_input" \
            --argjson output "$current_output" \
            '.[$port] = {input:$input, output:$output, backup_time:$time}' \
            "$TRAFFIC_DATA_FILE" > "$backup_temp"; then
            rm -f "$stats_temp" "$backup_temp"
            return 1
        fi
    elif ! jq -n \
        --arg port "$port" \
        --arg time "$snapshot_time" \
        --argjson input "$current_input" \
        --argjson output "$current_output" \
        '{($port): {input:$input, output:$output, backup_time:$time}}' > "$backup_temp"; then
        rm -f "$stats_temp" "$backup_temp"
        return 1
    fi

    if ! write_traffic_backup_metadata "$backup_temp"; then
        rm -f "$stats_temp" "$backup_temp"
        return 1
    fi

    # 先刷新灾备计数，避免规则意外丢失时把重置前的旧值恢复回来。
    if ! mv "$backup_temp" "$TRAFFIC_DATA_FILE"; then
        rm -f "$stats_temp" "$backup_temp"
        return 1
    fi
    if ! mv "$stats_temp" "$TRAFFIC_STATS_FILE"; then
        rm -f "$stats_temp"
        return 1
    fi
    chmod 600 "$TRAFFIC_STATS_FILE" "$TRAFFIC_DATA_FILE" 2>/dev/null || true
}

update_traffic_snapshot_baseline() {
    local port="$1"
    local mode="${2:-preserve_today}"
    local input_adjustment="${3:-0}"
    local output_adjustment="${4:-0}"
    acquire_traffic_stats_lock || return 1
    local result=0
    update_traffic_snapshot_baseline_locked \
        "$port" "$mode" "$input_adjustment" "$output_adjustment" || result=$?
    release_traffic_stats_lock
    return "$result"
}

scale_current_day_traffic_stats() {
    local port="$1"
    local input_source="${2:-1}"
    local input_target="${3:-1}"
    local output_source="${4:-1}"
    local output_target="${5:-1}"

    [ -f "$TRAFFIC_STATS_FILE" ] || return 0
    if [ "$input_source" -eq "$input_target" ] && [ "$output_source" -eq "$output_target" ]; then
        return 0
    fi

    acquire_traffic_stats_lock || return 1
    if ! ensure_traffic_stats_file; then
        release_traffic_stats_lock
        return 1
    fi

    local snapshot_date
    snapshot_date=$(get_current_date)
    local temp_file
    temp_file=$(mktemp)
    if jq \
        --arg port "$port" \
        --arg date "$snapshot_date" \
        --argjson input_source "$input_source" \
        --argjson input_target "$input_target" \
        --argjson output_source "$output_source" \
        --argjson output_target "$output_target" \
        '
        if .daily[$port][$date] != null then
            .daily[$port][$date].input = (((.daily[$port][$date].input // 0) * $input_target / $input_source) | floor) |
            .daily[$port][$date].output = (((.daily[$port][$date].output // 0) * $output_target / $output_source) | floor)
        else
            .
        end
        ' "$TRAFFIC_STATS_FILE" > "$temp_file"; then
        mv "$temp_file" "$TRAFFIC_STATS_FILE"
    else
        rm -f "$temp_file"
        release_traffic_stats_lock
        return 1
    fi
    release_traffic_stats_lock
}

remove_port_traffic_state() {
    local port="$1"

    if [ -f "$TRAFFIC_STATS_FILE" ] && jq empty "$TRAFFIC_STATS_FILE" >/dev/null 2>&1; then
        acquire_traffic_stats_lock || return 1
        local stats_temp
        stats_temp=$(mktemp "$CONFIG_DIR/.traffic_stats.json.tmp.XXXXXX")
        if jq --arg port "$port" '
            del(.last_snapshot[$port]) |
            del(.state[$port]) |
            del(.daily[$port])
        ' "$TRAFFIC_STATS_FILE" > "$stats_temp"; then
            mv "$stats_temp" "$TRAFFIC_STATS_FILE"
        else
            rm -f "$stats_temp"
            release_traffic_stats_lock
            return 1
        fi
        release_traffic_stats_lock
    fi

    if [ -f "$TRAFFIC_DATA_FILE" ] && jq empty "$TRAFFIC_DATA_FILE" >/dev/null 2>&1; then
        local backup_temp
        backup_temp=$(mktemp "$CONFIG_DIR/.traffic_data.json.tmp.XXXXXX")
        if jq --arg port "$port" 'del(.[$port]) | del(._meta.port_multipliers[$port])' \
            "$TRAFFIC_DATA_FILE" > "$backup_temp"; then
            if [ "$(jq '[keys[] | select(. != "_meta")] | length' "$backup_temp" 2>/dev/null || echo 0)" -gt 0 ]; then
                mv "$backup_temp" "$TRAFFIC_DATA_FILE"
            else
                rm -f "$backup_temp" "$TRAFFIC_DATA_FILE"
            fi
        else
            rm -f "$backup_temp"
            return 1
        fi
    fi
}

get_port_cycle_start_date() {
    local port="$1"
    local policy_type
    policy_type=$(get_reset_policy_type "$port")

    if [ "$policy_type" != "monthly" ]; then
        local start_date
        start_date=$(jq -r ".ports.\"$port\".quota.reset_policy.last_reset_date // .ports.\"$port\".quota.reset_policy.anchor_date // empty" "$CONFIG_FILE" 2>/dev/null)
        if ! is_valid_date "$start_date"; then
            start_date=$(get_port_created_date "$port")
        fi
        echo "$start_date"
        return
    fi

    local reset_day_raw
    reset_day_raw=$(jq -r ".ports.\"$port\".quota.reset_policy.day // .ports.\"$port\".quota.reset_day // null" "$CONFIG_FILE" 2>/dev/null)
    local reset_day=1
    if [[ "$reset_day_raw" =~ ^[0-9]+$ ]] && [ "$reset_day_raw" -ge 1 ] && [ "$reset_day_raw" -le 31 ]; then
        reset_day="$reset_day_raw"
    fi

    local time_info=($(get_beijing_month_year))
    local current_day="${time_info[0]}"
    local current_month="${time_info[1]}"
    local current_year="${time_info[2]}"
    local start_year
    local start_month

    local current_reset_day
    current_reset_day=$(clamp_day_to_month "$current_year" "$current_month" "$reset_day")
    if [ "$current_day" -ge "$current_reset_day" ]; then
        start_year="$current_year"
        start_month="$current_month"
    else
        local prev=($(normalize_year_month "$current_year" "$((current_month - 1))"))
        start_year="${prev[0]}"
        start_month="${prev[1]}"
    fi

    local start_day
    start_day=$(clamp_day_to_month "$start_year" "$start_month" "$reset_day")
    format_date "$start_year" "$start_month" "$start_day"
}

sum_port_traffic_by_dates() {
    local port="$1"
    local start_date="$2"
    local end_date="$3"
    local input_total=0
    local output_total=0

    if ! is_valid_date "$start_date" || ! is_valid_date "$end_date" || date_lt "$end_date" "$start_date"; then
        echo "0 0"
        return
    fi

    if [ ! -f "$TRAFFIC_STATS_FILE" ]; then
        echo "0 0"
        return
    fi

    local cursor="$start_date"
    while true; do
        local day_input
        day_input=$(jq -r --arg port "$port" --arg date "$cursor" '.daily[$port][$date].input // 0' "$TRAFFIC_STATS_FILE" 2>/dev/null || echo 0)
        local day_output
        day_output=$(jq -r --arg port "$port" --arg date "$cursor" '.daily[$port][$date].output // 0' "$TRAFFIC_STATS_FILE" 2>/dev/null || echo 0)
        [[ "$day_input" =~ ^[0-9]+$ ]] || day_input=0
        [[ "$day_output" =~ ^[0-9]+$ ]] || day_output=0
        input_total=$((input_total + day_input))
        output_total=$((output_total + day_output))

        [ "$cursor" = "$end_date" ] && break
        cursor=$(add_days_to_date "$cursor" 1)
    done

    echo "$input_total $output_total"
}

get_port_cycle_traffic() {
    local port="$1"
    local start_date
    start_date=$(get_port_cycle_start_date "$port")
    local end_date
    end_date=$(get_current_date)
    sum_port_traffic_by_dates "$port" "$start_date" "$end_date"
}

clear_port_traffic_stats_by_dates() {
    local port="$1"
    local start_date="$2"
    local end_date="$3"

    if ! is_valid_date "$start_date" || ! is_valid_date "$end_date" || date_lt "$end_date" "$start_date"; then
        return 0
    fi

    acquire_traffic_stats_lock || return 1
    if ! ensure_traffic_stats_file; then
        release_traffic_stats_lock
        return 1
    fi

    local reset_time
    reset_time=$(get_beijing_time -Iseconds)
    local cursor="$start_date"
    while true; do
        local temp_file
        temp_file=$(mktemp)
        if jq \
            --arg port "$port" \
            --arg date "$cursor" \
            --arg time "$reset_time" \
            '
            .daily = (.daily // {}) |
            .daily[$port] = (.daily[$port] // {}) |
            .daily[$port][$date] = {
                "input": 0,
                "output": 0,
                "reset_time": $time
            }
            ' "$TRAFFIC_STATS_FILE" > "$temp_file"; then
            mv "$temp_file" "$TRAFFIC_STATS_FILE"
        else
            rm -f "$temp_file"
            release_traffic_stats_lock
            return 1
        fi

        [ "$cursor" = "$end_date" ] && break
        cursor=$(add_days_to_date "$cursor" 1)
    done

    release_traffic_stats_lock
}

clear_current_cycle_traffic_stats() {
    local port="$1"
    local start_date
    start_date=$(get_port_cycle_start_date "$port")
    local end_date
    end_date=$(get_current_date)
    clear_port_traffic_stats_by_dates "$port" "$start_date" "$end_date"
}

get_port_counter_prefix() {
    local port="$1"
    if is_port_range "$port"; then
        local port_safe
        port_safe=$(echo "$port" | tr '-' '_')
        echo "port_${port_safe}"
    else
        echo "port_${port}"
    fi
}

count_counter_rules() {
    local port="$1"
    local direction="$2"
    local table_name
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_name
    counter_name="$(get_port_counter_prefix "$port")_${direction}"

    nft -a list table "$family" "$table_name" 2>/dev/null | \
        grep -F "counter name \"$counter_name\"" | wc -l | awk '{print $1}' || true
}

get_port_quota_name() {
    local port="$1"
    if is_port_range "$port"; then
        local port_safe
        port_safe=$(echo "$port" | tr '-' '_')
        echo "port_${port_safe}_quota"
    else
        echo "port_${port}_quota"
    fi
}

count_quota_rules() {
    local port="$1"
    local table_name
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local quota_name
    quota_name=$(get_port_quota_name "$port")

    nft -a list table "$family" "$table_name" 2>/dev/null | \
        grep -F "quota name \"$quota_name\"" | wc -l | awk '{print $1}' || true
}

get_active_runtime_prefixes_json() {
    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    local port
    {
        for port in "${active_ports[@]}"; do
            get_port_counter_prefix "$port"
        done
    } | jq -Rsc 'split("\n") | map(select(length > 0)) | unique'
}

# 只识别本脚本固定命名格式的对象，避免触碰同表中的外部规则。
list_orphaned_runtime_objects() {
    local table_name
    local family
    local table_json
    local allowed_prefixes
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    table_json=$(nft -j -a list table "$family" "$table_name" 2>/dev/null) || return 1
    allowed_prefixes=$(get_active_runtime_prefixes_json) || return 1

    printf '%s\n' "$table_json" | jq -r --argjson allowed "$allowed_prefixes" '
        def is_owned_counter:
            type == "string" and test("^port_[0-9]+(_[0-9]+)?_(in|out)$");
        def is_owned_quota:
            type == "string" and test("^port_[0-9]+(_[0-9]+)?_quota$");
        def is_allowed($name):
            ($name | sub("_(in|out|quota)$"; "")) as $prefix |
            ($allowed | index($prefix)) != null;
        [
            .nftables[] |
            if .counter?.name? | is_owned_counter then
                select(is_allowed(.counter.name) | not) |
                "counter \(.counter.name)"
            elif .quota?.name? | is_owned_quota then
                select(is_allowed(.quota.name) | not) |
                "quota \(.quota.name)"
            else
                empty
            end
        ] | unique[]
    ' || return 1
}

reconcile_orphaned_runtime_objects() {
    local orphaned
    orphaned=$(list_orphaned_runtime_objects) || return 1
    [ -n "$orphaned" ] || return 0

    local table_name
    local family
    local rules_json
    local cleanup_batch
    local orphan_names
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    rules_json=$(mktemp "$CONFIG_DIR/.nft-orphans.XXXXXX") || return 1
    cleanup_batch=$(mktemp "$CONFIG_DIR/.nft-cleanup.XXXXXX") || {
        rm -f "$rules_json"
        return 1
    }
    orphan_names=$(printf '%s\n' "$orphaned" | awk '{print $2}' |
        jq -Rsc 'split("\n") | map(select(length > 0)) | unique') || {
        rm -f "$rules_json" "$cleanup_batch"
        return 1
    }

    if ! nft -j -a list table "$family" "$table_name" > "$rules_json" 2>/dev/null ||
       ! jq -r \
            --arg family "$family" \
            --arg table "$table_name" \
            --argjson orphan_names "$orphan_names" '
            def named_refs($kind):
                [
                    .expr[]? | .[$kind]? |
                    if type == "string" then .
                    elif type == "object" then (.name // empty)
                    else empty end
                ];
            .nftables[] |
            select(.rule != null and .rule.handle != null) |
            .rule as $rule |
            ((($rule | named_refs("counter")) + ($rule | named_refs("quota"))) |
                any(.[]; . as $name | ($orphan_names | index($name)) != null)) as $owned |
            select($owned) |
            "delete rule \($family) \($table) \($rule.chain) handle \($rule.handle)"
        ' "$rules_json" > "$cleanup_batch"; then
        rm -f "$rules_json" "$cleanup_batch"
        return 1
    fi

    while read -r object_type object_name; do
        [ -n "$object_type" ] && [ -n "$object_name" ] || continue
        printf 'delete %s %s %s %s\n' \
            "$object_type" "$family" "$table_name" "$object_name" >> "$cleanup_batch"
    done <<< "$orphaned"

    if ! nft -f "$cleanup_batch" >/dev/null 2>&1; then
        rm -f "$rules_json" "$cleanup_batch"
        return 1
    fi
    rm -f "$rules_json" "$cleanup_batch"

    [ -z "$(list_orphaned_runtime_objects)" ]
}

# 返回 0 表示目标方向存在位于 counter 之前的终止规则，1 表示顺序正常，2 表示无法读取。
counter_direction_has_preceding_terminal_rule() {
    local port="$1"
    local direction="$2"
    local table_name
    local family
    local prefix
    local quota_name
    local bounds=()
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    prefix=$(get_port_counter_prefix "$port")
    quota_name=$(get_port_quota_name "$port")
    read -r -a bounds < <(get_port_spec_bounds "$port") || return 2
    [ ${#bounds[@]} -eq 2 ] || return 2

    local counter_name="${prefix}_${direction}"
    local chain
    local field
    local chain_json
    local invalid
    local chain_fields=()
    if [ "$direction" = "in" ]; then
        chain_fields=("input:dport" "forward:dport")
    elif [ "$direction" = "out" ]; then
        chain_fields=("output:sport" "forward:sport")
    else
        return 2
    fi

    local chain_field
    for chain_field in "${chain_fields[@]}"; do
        chain="${chain_field%%:*}"
        field="${chain_field##*:}"
        chain_json=$(nft -j -a list chain "$family" "$table_name" "$chain" 2>/dev/null) || return 2
        invalid=$(printf '%s\n' "$chain_json" | jq -r \
            --arg field "$field" \
            --arg counter "$counter_name" \
            --arg quota "$quota_name" \
            --argjson start "${bounds[0]}" \
            --argjson finish "${bounds[1]}" '
            def named_ref($kind; $name):
                any(.expr[]?;
                    (.[$kind]? |
                        if type == "string" then . == $name
                        elif type == "object" then (.name // "") == $name
                        else false end));
            def value_overlaps($value; $start; $finish):
                if ($value | type) == "number" then
                    $value >= $start and $value <= $finish
                elif ($value | type) == "object" and ($value.range? | type) == "array" then
                    $value.range[0] <= $finish and $value.range[1] >= $start
                elif ($value | type) == "object" and ($value.set? | type) == "array" then
                    any($value.set[]; value_overlaps(.; $start; $finish))
                else
                    true
                end;
            def port_match_may_apply($match; $start; $finish):
                ($match.op // "==") as $op |
                if $op == "==" or $op == "in" then
                    value_overlaps($match.right; $start; $finish)
                elif $op == "!=" then
                    ($start != $finish) or
                    (value_overlaps($match.right; $start; $finish) | not)
                else
                    true
                end;
            def protocol_value_may_apply($value):
                if ($value | type) == "string" then
                    $value == "tcp" or $value == "udp"
                elif ($value | type) == "number" then
                    $value == 6 or $value == 17
                elif ($value | type) == "object" and ($value.set? | type) == "array" then
                    any($value.set[]; protocol_value_may_apply(.))
                else
                    true
                end;
            def protocol_match_may_apply($match):
                ($match.op // "==") as $op |
                if $op == "==" or $op == "in" then
                    protocol_value_may_apply($match.right)
                else
                    true
                end;
            def rule_protocol_may_apply:
                [
                    .expr[]? | .match? |
                    select(
                        .left.meta.key? == "l4proto" or
                        (.left.payload.protocol? == "ip" and .left.payload.field? == "protocol") or
                        (.left.payload.protocol? == "ip6" and .left.payload.field? == "nexthdr")
                    )
                ] as $protocol_matches |
                [
                    .expr[]? |
                    (.match?.left.payload.protocol? //
                        .vmap?.key.payload.protocol? // empty) as $protocol |
                    select(
                        ["tcp", "udp", "icmp", "icmpv6", "sctp", "dccp"] |
                        index($protocol) != null
                    ) |
                    $protocol
                ] as $payload_protocols |
                (($protocol_matches | length) == 0 or
                    all($protocol_matches[]; protocol_match_may_apply(.))) and
                (($payload_protocols | length) == 0 or
                    any($payload_protocols[]; . == "tcp" or . == "udp"));
            def rule_port_may_apply($field; $start; $finish):
                [
                    .expr[]? | .match? |
                    select(.left.payload.field? == $field)
                ] as $matches |
                [
                    .expr[]? | .vmap? |
                    select(.key.payload.field? == $field)
                ] as $vmaps |
                (($matches | length) == 0 or
                    all($matches[]; port_match_may_apply(.; $start; $finish))) and
                (($vmaps | length) == 0 or
                    all($vmaps[];
                        if (.data.set? | type) == "array" then
                            any(.data.set[]?;
                                value_overlaps(
                                    if type == "array" then .[0] else . end;
                                    $start; $finish
                                ))
                        else
                            true
                        end));
            def rule_may_apply($field; $start; $finish):
                rule_protocol_may_apply and rule_port_may_apply($field; $start; $finish);
            def terminal_verdict:
                any(.expr[]?;
                    type == "object" and
                    (has("accept") or has("drop") or has("reject") or
                        has("queue") or has("return") or has("jump") or
                        has("goto") or has("vmap")));
            reduce (
                .nftables[] | .rule? |
                select(rule_may_apply($field; $start; $finish))
            ) as $rule (
                {terminal:false, invalid:false};
                if ($rule | named_ref("quota"; $quota)) then .
                elif ($rule | named_ref("counter"; $counter)) then
                    if .terminal then .invalid = true else . end
                elif ($rule | terminal_verdict) then .terminal = true
                else . end
            ) |
            .invalid
        ') || return 2
        case "$invalid" in
            true) return 0 ;;
            false) ;;
            *) return 2 ;;
        esac
    done
    return 1
}

get_invalid_counter_order_directions() {
    local port="$1"
    local invalid=()
    local direction
    local status
    for direction in in out; do
        status=0
        counter_direction_has_preceding_terminal_rule "$port" "$direction" || status=$?
        case "$status" in
            0) invalid+=("$direction") ;;
            1) ;;
            *) return 1 ;;
        esac
    done
    echo "${invalid[*]}"
}

remove_nftables_counter_rules() {
    local port="$1"
    local table_name
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local counter_prefix
    counter_prefix=$(get_port_counter_prefix "$port")

    local deleted_count=0
    while true; do
        local match_line
        match_line=$(nft -a list table "$family" "$table_name" 2>/dev/null | awk -v prefix="$counter_prefix" '
            /^[[:space:]]*chain[[:space:]]+/ {
                chain = $2
                next
            }
            index($0, "counter name \"" prefix "_") && $0 ~ /# handle [0-9]+/ {
                handle = $0
                sub(/^.*# handle /, "", handle)
                sub(/[^0-9].*$/, "", handle)
                print chain " " handle
                exit
            }
        ' || true)

        if [ -z "$match_line" ]; then
            break
        fi

        local chain="${match_line%% *}"
        local handle="${match_line##* }"
        if [ -z "$chain" ] || [ -z "$handle" ]; then
            break
        fi

        if nft delete rule "$family" "$table_name" "$chain" handle "$handle" 2>/dev/null; then
            deleted_count=$((deleted_count + 1))
        else
            break
        fi

        if [ "$deleted_count" -ge 150 ]; then
            break
        fi
    done
}

repair_port_traffic_rules() {
    local port="$1"
    local force_rebuild="${2:-false}"
    local convert_legacy_multiplier="${3:-false}"
    LAST_REPAIR_CHANGED=false
    local billing_mode
    billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local expected_in_count
    expected_in_count=$(get_expected_counter_rule_count "$billing_mode")
    local expected_out_count="$expected_in_count"

    local in_rule_count
    in_rule_count=$(count_counter_rules "$port" "in")
    local out_rule_count
    out_rule_count=$(count_counter_rules "$port" "out")

    local needs_rebuild=false
    local repair_directions=()
    if [ "$in_rule_count" -ne "$expected_in_count" ]; then
        needs_rebuild=true
        repair_directions+=("in")
    fi
    if [ "$out_rule_count" -ne "$expected_out_count" ]; then
        needs_rebuild=true
        repair_directions+=("out")
    fi

    if [ "$force_rebuild" = "true" ]; then
        needs_rebuild=true
    fi

    local invalid_order=""
    if [ "$in_rule_count" -eq "$expected_in_count" ] && \
       [ "$out_rule_count" -eq "$expected_out_count" ]; then
        invalid_order=$(get_invalid_counter_order_directions "$port") || {
            log_notification "port $port traffic rule order could not be inspected"
            return 1
        }
        if [ -n "$invalid_order" ]; then
            needs_rebuild=true
            local invalid_direction
            for invalid_direction in $invalid_order; do
                [[ " ${repair_directions[*]} " == *" $invalid_direction "* ]] ||
                    repair_directions+=("$invalid_direction")
            done
        fi
    fi
    [ "$needs_rebuild" = "true" ] || return 0

    local quota_enabled
    quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // true" "$CONFIG_FILE")
    local monthly_limit
    monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
    local recovered_input=0
    local recovered_output=0

    if [ ${#repair_directions[@]} -gt 0 ]; then
        # 先记录现有自然日增量，再以单个 nft 事务重建 counter 与 quota。
        record_traffic_snapshot >/dev/null 2>&1 || true
    fi

    local traffic_data=()
    local quota_used=-1
    if [ ${#repair_directions[@]} -gt 0 ] && [ "$quota_enabled" = "true" ] && \
       [ "$monthly_limit" != "unlimited" ]; then
        local usage_snapshot=()
        read -r -a usage_snapshot < <(get_port_runtime_usage_snapshot "$port") || {
            log_notification "port $port runtime counter/quota snapshot failed"
            return 1
        }
        traffic_data=("${usage_snapshot[0]:-0}" "${usage_snapshot[1]:-0}")
        quota_used="${usage_snapshot[2]:--1}"
    else
        read -r -a traffic_data < <(get_nftables_counter_data "$port")
    fi
    local current_input=${traffic_data[0]:-0}
    local current_output=${traffic_data[1]:-0}
    [[ "$current_input" =~ ^[0-9]+$ ]] || current_input=0
    [[ "$current_output" =~ ^[0-9]+$ ]] || current_output=0

    if [[ "$quota_used" =~ ^[0-9]+$ ]]; then
        local current_total=$((current_input + current_output))
        if [ "$quota_used" -gt "$current_total" ]; then
            local missing_bytes=$((quota_used - current_total))
            local invalid_in=false
            local invalid_out=false
            [[ " ${repair_directions[*]} " == *" in "* ]] && invalid_in=true
            [[ " ${repair_directions[*]} " == *" out "* ]] && invalid_out=true
            if [ "$invalid_in" = "true" ] && [ "$invalid_out" = "false" ]; then
                current_input=$((current_input + missing_bytes))
                recovered_input="$missing_bytes"
            elif [ "$invalid_out" = "true" ] && [ "$invalid_in" = "false" ]; then
                current_output=$((current_output + missing_bytes))
                recovered_output="$missing_bytes"
            elif [ "$missing_bytes" -gt $((1024 * 1024)) ]; then
                log_notification "port $port counter/quota gap cannot be assigned safely: bytes=$missing_bytes, directions=${repair_directions[*]}"
                return 1
            fi
        fi
    fi

    local target_multiplier
    target_multiplier=$(get_billing_rule_multiplier "$billing_mode")
    local input_source_multiplier="$target_multiplier"
    local output_source_multiplier="$target_multiplier"
    if [ "$convert_legacy_multiplier" = "true" ]; then
        if ! input_source_multiplier=$(resolve_legacy_counter_multiplier \
            "$port" "input" "$in_rule_count" "$target_multiplier" "$current_input") ||
           ! output_source_multiplier=$(resolve_legacy_counter_multiplier \
            "$port" "output" "$out_rule_count" "$target_multiplier" "$current_output"); then
            log_notification "port $port legacy traffic multiplier is unknown; preserved counters and stopped automatic conversion"
            return 1
        fi
    fi
    local repaired_input
    repaired_input=$(scale_counter_for_rule_multiplier "$current_input" "$input_source_multiplier" "$target_multiplier")
    local repaired_output
    repaired_output=$(scale_counter_for_rule_multiplier "$current_output" "$output_source_multiplier" "$target_multiplier")
    local repaired_recovered_input
    repaired_recovered_input=$(scale_counter_for_rule_multiplier "$recovered_input" "$input_source_multiplier" "$target_multiplier")
    local repaired_recovered_output
    repaired_recovered_output=$(scale_counter_for_rule_multiplier "$recovered_output" "$output_source_multiplier" "$target_multiplier")

    if ! rebuild_port_counter_objects \
        "$port" "$repaired_input" "$repaired_output" rebuild; then
        log_notification "port $port traffic rules rebuild failed"
        return 1
    fi

    scale_current_day_traffic_stats \
        "$port" \
        "$input_source_multiplier" "$target_multiplier" \
        "$output_source_multiplier" "$target_multiplier" >/dev/null 2>&1 || true
    update_traffic_snapshot_baseline \
        "$port" "preserve_today" \
        "$repaired_recovered_input" "$repaired_recovered_output" >/dev/null 2>&1 || true

    LAST_REPAIR_CHANGED=true
    log_notification "port $port traffic rules rebuilt: in_rules=$in_rule_count/$expected_in_count, out_rules=$out_rule_count/$expected_out_count, order=${invalid_order:-ok}, recovered_in=$repaired_recovered_input, recovered_out=$repaired_recovered_output, in_multiplier=$input_source_multiplier->$target_multiplier, out_multiplier=$output_source_multiplier->$target_multiplier"
    return 0
}

repair_port_quota_rules() {
    local port="$1"
    LAST_REPAIR_CHANGED=false
    local quota_enabled
    quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // true" "$CONFIG_FILE")
    local monthly_limit
    monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
    if [ "$quota_enabled" != "true" ] || [ "$monthly_limit" = "unlimited" ]; then
        local quota_name
        local family
        local table_name
        quota_name=$(get_port_quota_name "$port")
        family=$(jq -r '.nftables.family' "$CONFIG_FILE")
        table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
        if [ "$(count_quota_rules "$port")" -gt 0 ] ||
           nft list quota "$family" "$table_name" "$quota_name" >/dev/null 2>&1; then
            remove_nftables_quota "$port" >/dev/null 2>&1 || true
            nftables_quota_is_absent "$port" || return 1
            LAST_REPAIR_CHANGED=true
        fi
        return 0
    fi

    local billing_mode
    billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local expected_count
    expected_count=$(get_expected_quota_rule_count "$billing_mode")

    local quota_rule_count
    quota_rule_count=$(count_quota_rules "$port")
    if [ "$quota_rule_count" -eq "$expected_count" ] && \
       nftables_quota_limit_matches "$port" "$monthly_limit"; then
        return 0
    fi

    if ! apply_nftables_quota "$port" "$monthly_limit"; then
        log_notification "port $port quota rules rebuild failed: quota_rules=$quota_rule_count, expected=$expected_count, limit=$monthly_limit"
        return 1
    fi
    nftables_quota_limit_matches "$port" "$monthly_limit" || return 1
    LAST_REPAIR_CHANGED=true
    log_notification "port $port quota rules rebuilt: quota_rules=$quota_rule_count, expected=$expected_count, limit=$monthly_limit"
    return 0
}

repair_duplicate_traffic_rules() {
    local force_rebuild="${1:-false}"
    local convert_legacy_multiplier="${2:-false}"
    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    local repaired_count=0
    local failed_count=0
    local port
    for port in "${active_ports[@]}"; do
        local repaired=false
        if repair_port_traffic_rules "$port" "$force_rebuild" "$convert_legacy_multiplier" >/dev/null 2>&1; then
            [ "$LAST_REPAIR_CHANGED" = "true" ] && repaired=true
        else
            failed_count=$((failed_count + 1))
            continue
        fi
        if repair_port_quota_rules "$port" >/dev/null 2>&1; then
            [ "$LAST_REPAIR_CHANGED" = "true" ] && repaired=true
        else
            failed_count=$((failed_count + 1))
            continue
        fi
        if [ "$repaired" = "true" ]; then
            repaired_count=$((repaired_count + 1))
        fi
    done
    echo "$repaired_count"
    [ "$failed_count" -eq 0 ]
}

ensure_traffic_accounting_model() {
    local current_model
    current_model=$(jq -r '.global.traffic_accounting_model // ""' "$CONFIG_FILE" 2>/dev/null || true)
    [ "$current_model" = "$TRAFFIC_ACCOUNTING_MODEL" ] && return 0

    # 只有缺少模型标记的一次性升级允许按旧规则数量换算历史 counter。
    repair_duplicate_traffic_rules true true >/dev/null || return 1

    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    local port
    for port in "${active_ports[@]}"; do
        local billing_mode
        billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local expected_counter_count
        expected_counter_count=$(get_expected_counter_rule_count "$billing_mode")
        [ "$(count_counter_rules "$port" in)" -eq "$expected_counter_count" ] || return 1
        [ "$(count_counter_rules "$port" out)" -eq "$expected_counter_count" ] || return 1

        local quota_enabled
        quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // true" "$CONFIG_FILE")
        local monthly_limit
        monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
        local expected_quota_count=0
        if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ]; then
            expected_quota_count=$(get_expected_quota_rule_count "$billing_mode")
        fi
        [ "$(count_quota_rules "$port")" -eq "$expected_quota_count" ] || return 1
    done

    update_config_file \
        '.global = (.global // {}) | .global.traffic_accounting_model = $model' \
        --arg model "$TRAFFIC_ACCOUNTING_MODEL"
}

ensure_tc_runtime_model() {
    local current_model
    current_model=$(jq -r '.global.tc_runtime_model // ""' "$CONFIG_FILE" 2>/dev/null || true)
    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    local has_bandwidth_limits=false
    local port
    for port in "${active_ports[@]}"; do
        local limit_enabled
        local rate_limit
        limit_enabled=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.enabled // false' "$CONFIG_FILE")
        rate_limit=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.rate // "unlimited"' "$CONFIG_FILE")
        if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
            has_bandwidth_limits=true
            break
        fi
    done

    local need_restore=false
    if [ "$has_bandwidth_limits" = "true" ] && [ "$current_model" != "$TC_RUNTIME_MODEL" ]; then
        need_restore=true
    fi
    for port in "${active_ports[@]}"; do
        local limit_enabled
        local rate_limit
        limit_enabled=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.enabled // false' "$CONFIG_FILE")
        rate_limit=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.rate // "unlimited"' "$CONFIG_FILE")
        if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ] &&
           ! tc_limit_runtime_complete "$port"; then
            need_restore=true
            break
        fi
    done

    if [ "$need_restore" = "true" ]; then
        restore_runtime_state || return 1
    fi

    [ "$current_model" = "$TC_RUNTIME_MODEL" ] && return 0
    update_config_file \
        '.global = (.global // {}) | .global.tc_runtime_model = $model' \
        --arg model "$TC_RUNTIME_MODEL"
}


get_port_status_label() {
    local port=$1
    local port_config=$(jq -r ".ports.\"$port\"" "$CONFIG_FILE" 2>/dev/null)

    local remark=$(echo "$port_config" | jq -r '.remark // ""')
    local billing_mode=$(echo "$port_config" | jq -r '.billing_mode // "single"')
    local limit_enabled=$(echo "$port_config" | jq -r '.bandwidth_limit.enabled // false')
    local rate_limit=$(echo "$port_config" | jq -r '.bandwidth_limit.rate // "unlimited"')
    local quota_enabled=$(echo "$port_config" | jq -r '.quota.enabled // true')
    local monthly_limit=$(echo "$port_config" | jq -r '.quota.monthly_limit // "unlimited"')
    local status_tags=()

    if [ -n "$remark" ] && [ "$remark" != "null" ] && [ "$remark" != "" ]; then
        status_tags+=("[备注:$remark]")
    fi

    if [ "$quota_enabled" = "true" ]; then
        if [ "$monthly_limit" != "unlimited" ]; then
            local current_usage=$(get_port_monthly_usage "$port")
            local limit_bytes
            limit_bytes=$(parse_size_to_bytes "$monthly_limit" 2>/dev/null || echo 0)
            if ! [[ "$limit_bytes" =~ ^[0-9]+$ ]] || [ "$limit_bytes" -le 0 ]; then
                status_tags+=("[配额配置异常:${monthly_limit}]")
            else
                local usage_percent=$((current_usage * 100 / limit_bytes))

                local quota_display="$monthly_limit"
                if [ "$billing_mode" = "double" ]; then
                    status_tags+=("[双向${quota_display}]")
                else
                    status_tags+=("[单向${quota_display}]")
                fi

                local next_reset_label
                next_reset_label=$(get_port_next_reset_label "$port" 2>/dev/null || true)
                if [ -n "$next_reset_label" ]; then
                    status_tags+=("[$next_reset_label]")
                fi

                if [ $usage_percent -ge 100 ]; then
                    status_tags+=("[已超限]")
                fi
            fi
        else
            if [ "$billing_mode" = "double" ]; then
                status_tags+=("[双向无限制]")
            else
                status_tags+=("[单向无限制]")
            fi
        fi
    fi

    if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ]; then
        status_tags+=("[限制带宽${rate_limit}]")
    fi

    if [ ${#status_tags[@]} -gt 0 ]; then
        printf '%s' "${status_tags[@]}"
        echo
    fi
}

get_port_monthly_usage() {
    local port=$1
    local traffic_data=($(get_nftables_counter_data "$port"))
    local input_bytes=${traffic_data[0]}
    local output_bytes=${traffic_data[1]}
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")

    calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode"
}

validate_bandwidth() {
    local input="$1"
    local lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')

    if [[ "$input" == "0" ]]; then
        return 0
    elif [[ "$lower_input" =~ ^[0-9]+kbps$ ]] || [[ "$lower_input" =~ ^[0-9]+mbps$ ]] || [[ "$lower_input" =~ ^[0-9]+gbps$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_quota() {
    local input="$1"
    local lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')

    if [[ "$input" == "0" ]]; then
        return 0
    elif [[ "$lower_input" =~ ^[0-9]+(mb|gb|tb|m|g|t)$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_day_1_31() {
    local day="$1"
    [[ "$day" =~ ^[0-9]+$ ]] && [ "$day" -ge 1 ] && [ "$day" -le 31 ]
}

validate_month_1_12() {
    local month="$1"
    [[ "$month" =~ ^[0-9]+$ ]] && [ "$month" -ge 1 ] && [ "$month" -le 12 ]
}

build_reset_policy_json() {
    local type="$1"
    shift || true
    case "$type" in
        none)
            echo '{"type":"none"}'
            ;;
        monthly)
            local day="$1"
            printf '{"type":"monthly","day":%s}\n' "$day"
            ;;
        interval_days)
            local every="$1"
            local anchor_date="$2"
            printf '{"type":"interval_days","every":%s,"anchor_date":"%s"}\n' "$every" "$anchor_date"
            ;;
        interval_months)
            local every="$1"
            local anchor_date="$2"
            local day="$3"
            printf '{"type":"interval_months","every":%s,"anchor_date":"%s","day":%s}\n' "$every" "$anchor_date" "$day"
            ;;
        yearly)
            local month="$1"
            local day="$2"
            printf '{"type":"yearly","month":%s,"day":%s}\n' "$month" "$day"
            ;;
        fixed_date)
            local date_value="$1"
            local reset_now="${2:-false}"
            printf '{"type":"fixed_date","date":"%s","reset_now":%s}\n' "$date_value" "$reset_now"
            ;;
    esac
}

prompt_reset_policy() {
    local default_day="${1:-1}"
    RESET_POLICY_CONFIG=""

    while true; do
        echo
        echo -e "${BLUE}=== 自动重置策略 ===${NC}"
        echo "1. 每月几号重置（默认每月${default_day}日）"
        echo "2. 每隔多少天重置"
        echo "3. 每隔多少个月重置"
        echo "4. 每年几月几号重置"
        echo "5. 指定到期日期重置一次"
        echo "0. 不自动重置"
        echo
        read -p "请选择(回车默认1) [0-5]: " policy_choice

        case "$policy_choice" in
            1|"")
                read -p "每月几号重置(回车默认${default_day}) [1-31]: " reset_day
                reset_day="${reset_day:-$default_day}"
                if validate_day_1_31 "$reset_day"; then
                    RESET_POLICY_CONFIG=$(build_reset_policy_json "monthly" "$reset_day")
                    return 0
                fi
                echo -e "${RED}日期无效，必须是1-31之间的数字${NC}"
                ;;
            2)
                read -p "每隔多少天重置 [1-3650]: " every_days
                if ! [[ "$every_days" =~ ^[0-9]+$ ]] || [ "$every_days" -lt 1 ] || [ "$every_days" -gt 3650 ]; then
                    echo -e "${RED}天数无效，必须是1-3650之间的数字${NC}"
                    continue
                fi
                local default_anchor
                default_anchor=$(get_current_date)
                read -p "起算日期(回车默认今天${default_anchor}) [YYYY-MM-DD]: " anchor_date
                anchor_date="${anchor_date:-$default_anchor}"
                if ! is_valid_date "$anchor_date"; then
                    echo -e "${RED}起算日期无效，请使用YYYY-MM-DD格式${NC}"
                    continue
                fi
                RESET_POLICY_CONFIG=$(build_reset_policy_json "interval_days" "$every_days" "$anchor_date")
                return 0
                ;;
            3)
                read -p "每隔多少个月重置 [1-120]: " every_months
                if ! [[ "$every_months" =~ ^[0-9]+$ ]] || [ "$every_months" -lt 1 ] || [ "$every_months" -gt 120 ]; then
                    echo -e "${RED}月份间隔无效，必须是1-120之间的数字${NC}"
                    continue
                fi
                local default_anchor
                default_anchor=$(get_current_date)
                read -p "起算日期(回车默认今天${default_anchor}) [YYYY-MM-DD]: " anchor_date
                anchor_date="${anchor_date:-$default_anchor}"
                if ! is_valid_date "$anchor_date"; then
                    echo -e "${RED}起算日期无效，请使用YYYY-MM-DD格式${NC}"
                    continue
                fi
                local anchor_parts=($(date_parts "$anchor_date"))
                read -p "每次按几号重置(回车默认${anchor_parts[2]}) [1-31]: " reset_day
                reset_day="${reset_day:-${anchor_parts[2]}}"
                if ! validate_day_1_31 "$reset_day"; then
                    echo -e "${RED}日期无效，必须是1-31之间的数字${NC}"
                    continue
                fi
                RESET_POLICY_CONFIG=$(build_reset_policy_json "interval_months" "$every_months" "$anchor_date" "$reset_day")
                return 0
                ;;
            4)
                read -p "每年几月重置 [1-12]: " reset_month
                read -p "每月几号重置 [1-31]: " reset_day
                if ! validate_month_1_12 "$reset_month" || ! validate_day_1_31 "$reset_day"; then
                    echo -e "${RED}月份或日期无效${NC}"
                    continue
                fi
                RESET_POLICY_CONFIG=$(build_reset_policy_json "yearly" "$reset_month" "$reset_day")
                return 0
                ;;
            5)
                read -p "到期日期 [YYYY-MM-DD]: " fixed_date
                if ! is_valid_date "$fixed_date"; then
                    echo -e "${RED}到期日期无效，请使用YYYY-MM-DD格式${NC}"
                    continue
                fi
                if date_lt "$fixed_date" "$(get_current_date)"; then
                    echo -e "${RED}到期日期不能早于今天${NC}"
                    continue
                fi
                local reset_now="false"
                if [ "$fixed_date" = "$(get_current_date)" ]; then
                    read -p "到期日期是今天，是否立即重置当前流量? [y/N]: " reset_now_choice
                    if [[ "$reset_now_choice" =~ ^[Yy]$ ]]; then
                        reset_now="true"
                    else
                        echo -e "${YELLOW}未立即重置，将在下一次周期检查时执行${NC}"
                    fi
                fi
                RESET_POLICY_CONFIG=$(build_reset_policy_json "fixed_date" "$fixed_date" "$reset_now")
                return 0
                ;;
            0)
                RESET_POLICY_CONFIG=$(build_reset_policy_json "none")
                return 0
                ;;
            *)
                echo -e "${RED}无效选择，请输入0-5${NC}"
                ;;
        esac
    done
}

apply_reset_policy_to_port() {
    local port="$1"
    local policy_json="$2"
    local current_date
    current_date=$(get_current_date)
    local policy_type
    policy_type=$(printf '%s' "$policy_json" | jq -r '.type')
    local reset_now
    reset_now=$(printf '%s' "$policy_json" | jq -r '.reset_now // false')
    local previous_quota
    previous_quota=$(jq -c --arg port "$port" '.ports[$port].quota' "$CONFIG_FILE") || return 1

    if ! update_config_file '
        .ports[$port].quota.reset_policy = ($policy | del(.reset_now)) |
        if $policy.type == "monthly" then
            .ports[$port].quota.reset_day = $policy.day
        else
            del(.ports[$port].quota.reset_day)
        end
    ' --arg port "$port" --argjson policy "$policy_json"; then
        return 1
    fi

    if [ "$policy_type" = "fixed_date" ] && [ "$reset_now" = "true" ]; then
        check_reset_port_due "$port"
        return $?
    fi

    if [ "$policy_type" != "none" ]; then
        local from_date="$current_date"
        if [ "$policy_type" != "fixed_date" ]; then
            from_date=$(add_days_to_date "$current_date" 1)
        fi
        local next_reset_date
        next_reset_date=$(calculate_port_next_reset_date "$port" "$from_date")
        if [ -n "$next_reset_date" ]; then
            if ! update_config_file '
                .ports[$port].quota.reset_policy.next_reset_date = $next
            ' --arg port "$port" --arg next "$next_reset_date"; then
                update_config_file '.ports[$port].quota = $quota' \
                    --arg port "$port" --argjson quota "$previous_quota" >/dev/null 2>&1 || true
                return 1
            fi
        fi
    fi
    return 0
}

parse_size_to_bytes() {
    local size_str=$1
    local number=$(echo "$size_str" | grep -o '^[0-9]\+')
    local unit=$(echo "$size_str" | grep -o '[A-Za-z]\+$' | tr '[:lower:]' '[:upper:]')

    [ -z "$number" ] && echo "0" && return 1

    case $unit in
        "MB"|"M") echo $((number * 1048576)) ;;
        "GB"|"G") echo $((number * 1073741824)) ;;
        "TB"|"T") echo $((number * 1099511627776)) ;;
        *) echo "0" ;;
    esac
}


get_active_ports() {
    jq -r '.ports | keys[]' "$CONFIG_FILE" 2>/dev/null | tr -d '\r' | sort -n
}

has_active_ports() {
    [ -f "$CONFIG_FILE" ] || return 1
    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    [ ${#active_ports[@]} -gt 0 ]
}

is_port_range() {
    local port=$1
    [[ "$port" =~ ^[0-9]+-[0-9]+$ ]]
}

get_port_spec_bounds() {
    local port_spec="$1"
    if [[ "$port_spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    elif [[ "$port_spec" =~ ^[0-9]+$ ]]; then
        echo "$port_spec $port_spec"
    else
        return 1
    fi
}

port_specs_overlap() {
    local first_bounds=()
    local second_bounds=()
    read -r -a first_bounds < <(get_port_spec_bounds "$1") || return 1
    read -r -a second_bounds < <(get_port_spec_bounds "$2") || return 1
    [ "${first_bounds[0]}" -le "${second_bounds[1]}" ] &&
        [ "${second_bounds[0]}" -le "${first_bounds[1]}" ]
}

validate_config_file() {
    local file="$1"
    local error=""

    if ! jq -e '
        type == "object" and
        (.ports | type == "object") and
        ((.nftables // {}) | type == "object") and
        ([.ports[] | type == "object"] | all)
    ' "$file" >/dev/null 2>&1; then
        echo "配置根结构、ports 或端口配置项类型无效" >&2
        return 1
    fi

    local family
    local table_name
    family=$(jq -r '.nftables.family // "inet"' "$file")
    table_name=$(jq -r '.nftables.table_name // "port_traffic_monitor"' "$file")
    if [[ ! "$family" =~ ^(inet|ip|ip6)$ ]] || [[ ! "$table_name" =~ ^[A-Za-z_][A-Za-z0-9_]{0,31}$ ]]; then
        echo "nftables family 或 table_name 无效" >&2
        return 1
    fi

    local ports=()
    mapfile -t ports < <(jq -r '.ports | keys[]' "$file" 2>/dev/null | tr -d '\r')
    local port
    for port in "${ports[@]}"; do
        local bounds=()
        if ! read -r -a bounds < <(get_port_spec_bounds "$port") ||
           [ "${bounds[0]:-0}" -lt 1 ] || [ "${bounds[1]:-0}" -gt 65535 ] ||
           [ "${bounds[0]:-0}" -gt "${bounds[1]:-0}" ]; then
            echo "端口或端口段无效: $port" >&2
            return 1
        fi

        local billing_mode
        billing_mode=$(jq -r --arg port "$port" '.ports[$port].billing_mode // "double"' "$file")
        if [ "$billing_mode" != "single" ] && [ "$billing_mode" != "double" ]; then
            echo "端口 $port 的计费模式无效" >&2
            return 1
        fi

        local quota_enabled
        local quota_limit
        quota_enabled=$(jq -r --arg port "$port" '.ports[$port].quota.enabled // true' "$file")
        quota_limit=$(jq -r --arg port "$port" '.ports[$port].quota.monthly_limit // "unlimited"' "$file")
        if [ "$quota_enabled" != "true" ] && [ "$quota_enabled" != "false" ]; then
            echo "端口 $port 的配额开关无效" >&2
            return 1
        fi
        if [ "$quota_limit" != "unlimited" ]; then
            local quota_bytes
            quota_bytes=$(parse_size_to_bytes "$quota_limit" 2>/dev/null || echo 0)
            if ! [[ "$quota_bytes" =~ ^[0-9]+$ ]] || [ "$quota_bytes" -le 0 ]; then
                echo "端口 $port 的流量配额无效" >&2
                return 1
            fi
        fi

        local limit_enabled
        local rate_limit
        limit_enabled=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.enabled // false' "$file")
        rate_limit=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.rate // "unlimited"' "$file")
        if [ "$limit_enabled" != "true" ] && [ "$limit_enabled" != "false" ]; then
            echo "端口 $port 的带宽限制开关无效" >&2
            return 1
        fi
        if [ "$rate_limit" != "unlimited" ] && [ -z "$(convert_bandwidth_to_tc "$rate_limit")" ]; then
            echo "端口 $port 的带宽限制格式无效" >&2
            return 1
        fi

        local policy_type
        policy_type=$(jq -r --arg port "$port" '.ports[$port].quota.reset_policy.type // empty' "$file")
        if [ -n "$policy_type" ] && ! is_known_reset_policy_type "$policy_type"; then
            echo "端口 $port 的重置策略类型无效" >&2
            return 1
        fi
        if [ -n "$policy_type" ] && [ "$policy_type" != "none" ]; then
            local policy_day
            local policy_month
            local policy_every
            local policy_date
            local next_reset_date
            policy_day=$(jq -r --arg port "$port" '.ports[$port].quota.reset_policy.day // .ports[$port].quota.reset_day // empty' "$file")
            policy_month=$(jq -r --arg port "$port" '.ports[$port].quota.reset_policy.month // empty' "$file")
            policy_every=$(jq -r --arg port "$port" '.ports[$port].quota.reset_policy.every // empty' "$file")
            policy_date=$(jq -r --arg port "$port" '.ports[$port].quota.reset_policy.date // .ports[$port].quota.reset_policy.anchor_date // empty' "$file")
            next_reset_date=$(jq -r --arg port "$port" '.ports[$port].quota.reset_policy.next_reset_date // empty' "$file")
            case "$policy_type" in
                monthly)
                    validate_day_1_31 "${policy_day:-1}" || return 1
                    ;;
                interval_days)
                    [[ "$policy_every" =~ ^[0-9]+$ ]] && [ "$policy_every" -ge 1 ] && [ "$policy_every" -le 36500 ] || return 1
                    is_valid_date "$policy_date" || return 1
                    ;;
                interval_months)
                    [[ "$policy_every" =~ ^[0-9]+$ ]] && [ "$policy_every" -ge 1 ] && [ "$policy_every" -le 1200 ] || return 1
                    is_valid_date "$policy_date" || return 1
                    [ -z "$policy_day" ] || validate_day_1_31 "$policy_day" || return 1
                    ;;
                yearly)
                    [[ "$policy_month" =~ ^[0-9]+$ ]] && [ "$policy_month" -ge 1 ] && [ "$policy_month" -le 12 ] || return 1
                    validate_day_1_31 "$policy_day" || return 1
                    ;;
                fixed_date)
                    is_valid_date "$policy_date" || return 1
                    ;;
            esac
            [ -z "$next_reset_date" ] || is_valid_date "$next_reset_date" || return 1
        fi
    done

    local i j
    for ((i=0; i<${#ports[@]}; i++)); do
        for ((j=i+1; j<${#ports[@]}; j++)); do
            if port_specs_overlap "${ports[$i]}" "${ports[$j]}"; then
                error="${ports[$i]} 与 ${ports[$j]} 重叠"
                echo "监控端口配置重叠: $error" >&2
                return 1
            fi
        done
    done

    return 0
}

generate_port_range_mark() {
    local port_range=$1
    local start_port=$(echo "$port_range" | cut -d'-' -f1)
    local end_port=$(echo "$port_range" | cut -d'-' -f2)
    # 仅用于清理 1.4.x 及更早版本的旧 TC 过滤器。
    echo $(( (start_port * 1000 + end_port) % 65536 ))
}

get_or_create_port_range_mark() {
    local port="$1"
    local class_id="$2"
    local minor
    minor=$(tc_class_id_minor "$class_id") || return 1
    # 仅占用高 20 位，保留低 12 位给策略路由、透明代理等其他使用方。
    local mark_id=$((0x50000000 | (minor << 12)))
    if ! update_config_file \
        '.ports[$port].bandwidth_limit.mark_id = $mark' \
        --arg port "$port" --argjson mark "$mark_id"; then
        return 1
    fi
    echo "$mark_id"
}

get_port_range_mark_comment() {
    local port_safe
    port_safe=$(echo "$1" | tr '-' '_')
    echo "ptd_tc_mark_${port_safe}"
}

remove_port_range_mark_rules() {
    local port="$1"
    is_port_range "$port" || return 0
    local table_name
    local family
    local comment
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    comment=$(get_port_range_mark_comment "$port")

    while true; do
        local match_line
        match_line=$(nft -a list table "$family" "$table_name" 2>/dev/null | awk -v marker="$comment" '
            /^[[:space:]]*chain[[:space:]]+/ { chain=$2; next }
            index($0, "comment \"" marker "\"") && /# handle [0-9]+/ {
                handle=$0; sub(/^.*# handle /, "", handle); sub(/[^0-9].*$/, "", handle)
                print chain " " handle; exit
            }
        ' || true)
        [ -n "$match_line" ] || break
        local chain="${match_line%% *}"
        local handle="${match_line##* }"
        nft delete rule "$family" "$table_name" "$chain" handle "$handle" 2>/dev/null || return 1
    done
}

add_port_range_mark_rules() {
    local port="$1"
    local mark_id="$2"
    local table_name
    local family
    local comment
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    comment=$(get_port_range_mark_comment "$port")
    remove_port_range_mark_rules "$port" || return 1

    nft add rule "$family" "$table_name" output tcp sport "$port" \
        meta mark set meta mark \& "$TC_MARK_PRESERVE_MASK" \| "$mark_id" comment "$comment" || return 1
    nft add rule "$family" "$table_name" output udp sport "$port" \
        meta mark set meta mark \& "$TC_MARK_PRESERVE_MASK" \| "$mark_id" comment "$comment" || return 1
    nft add rule "$family" "$table_name" forward tcp dport "$port" \
        meta mark set meta mark \& "$TC_MARK_PRESERVE_MASK" \| "$mark_id" comment "$comment" || return 1
    nft add rule "$family" "$table_name" forward udp dport "$port" \
        meta mark set meta mark \& "$TC_MARK_PRESERVE_MASK" \| "$mark_id" comment "$comment" || return 1
    nft add rule "$family" "$table_name" forward tcp sport "$port" \
        meta mark set meta mark \& "$TC_MARK_PRESERVE_MASK" \| "$mark_id" comment "$comment" || return 1
    nft add rule "$family" "$table_name" forward udp sport "$port" \
        meta mark set meta mark \& "$TC_MARK_PRESERVE_MASK" \| "$mark_id" comment "$comment" || return 1

    [ "$(nft -a list table "$family" "$table_name" 2>/dev/null | grep -Fc "comment \"$comment\"")" -eq 6 ]
}

port_range_mark_rules_complete() {
    local port="$1"
    local mark_id="$2"
    local table_name
    local family
    local comment
    local combined_mask=$((mark_id | TC_MARK_PRESERVE_MASK))
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    comment=$(get_port_range_mark_comment "$port")

    nft -j list table "$family" "$table_name" 2>/dev/null |
        jq -e --arg comment "$comment" --argjson mark "$mark_id" --argjson mask "$combined_mask" '
            [.nftables[] | .rule? | select(.comment == $comment) |
                select(any(.expr[]?; .mangle? |
                    .key.meta.key? == "mark" and
                    .value["|"][1]? == $mark and
                    .value["|"][0]["&"][1]? == $mask
                ))
            ] | length == 6
        ' >/dev/null
}

# burst速率突发计算
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
    local total_limit=$1
    if [[ "$total_limit" =~ gbit$ ]]; then
        local rate=$(echo "$total_limit" | sed 's/gbit$//')
        echo $((rate * 1000000))
    elif [[ "$total_limit" =~ mbit$ ]]; then
        local rate=$(echo "$total_limit" | sed 's/mbit$//')
        echo $((rate * 1000))
    else
        echo $(echo "$total_limit" | sed 's/kbit$//')
    fi
}

# 将用户输入的带宽值(Kbps/Mbps/Gbps)转换为TC格式(kbit/mbit/gbit)
convert_bandwidth_to_tc() {
    local rate="$1"
    local lower=$(echo "$rate" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" =~ kbps$ ]]; then
        echo "${lower/%kbps/kbit}"
    elif [[ "$lower" =~ mbps$ ]]; then
        echo "${lower/%mbps/mbit}"
    elif [[ "$lower" =~ gbps$ ]]; then
        echo "${lower/%gbps/gbit}"
    elif [[ "$lower" =~ ^[0-9]+(kbit|mbit|gbit|bit)$ ]]; then
        echo "$lower"
    fi
}

generate_tc_class_id() {
    local port=$1

    local stored_class_id
    stored_class_id=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.class_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
    local stored_minor
    if tc_port_class_id_valid "$stored_class_id" >/dev/null 2>&1 &&
       stored_minor=$(tc_class_id_minor "$stored_class_id" 2>/dev/null); then
        if ! tc_minor_in_use "$port" "$stored_minor"; then
            echo "$stored_class_id"
            return
        fi
    fi

    local minor
    minor=$(generate_tc_minor_base "$port")
    local attempts=0
    while [ "$attempts" -lt 65534 ]; do
        local class_id="1:$(printf '%x' "$minor")"
        if ! tc_minor_in_use "$port" "$minor" && ! tc_class_id_exists "$class_id"; then
            if save_tc_class_id "$port" "$class_id"; then
                echo "$class_id"
                return
            fi
            return 1
        fi

        minor=$((minor + 1))
        if [ "$minor" -gt 65535 ]; then
            minor=2
        fi
        attempts=$((attempts + 1))
    done

    return 1
}

tc_class_id_minor() {
    local class_id="$1"
    [[ "$class_id" =~ ^1:([0-9a-fA-F]+)$ ]] || return 1
    local minor=$((16#${BASH_REMATCH[1]}))
    [ "$minor" -ge 2 ] && [ "$minor" -le 65535 ] || return 1
    echo "$minor"
}

tc_minor_is_reserved() {
    local minor="$1"
    [ "$minor" -eq 1 ] || [ "$minor" -eq $((16#30)) ]
}

tc_port_class_id_valid() {
    local class_id="$1"
    local minor
    minor=$(tc_class_id_minor "$class_id") || return 1
    ! tc_minor_is_reserved "$minor"
}

tc_minor_in_use() {
    local current_port="$1"
    local target_minor="$2"
    tc_minor_is_reserved "$target_minor" && return 0
    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    local other
    for other in "${active_ports[@]}"; do
        [ "$other" = "$current_port" ] && continue
        local class_id
        class_id=$(jq -r --arg port "$other" '.ports[$port].bandwidth_limit.class_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
        local other_minor
        if tc_port_class_id_valid "$class_id" >/dev/null 2>&1 &&
           other_minor=$(tc_class_id_minor "$class_id" 2>/dev/null); then
            if [ "$other_minor" -eq "$target_minor" ]; then
                return 0
            fi
        fi
    done
    return 1
}

tc_class_id_exists() {
    local class_id="$1"
    local interface
    interface=$(get_default_interface 2>/dev/null || true)
    [ -n "$interface" ] || return 1
    tc class show dev "$interface" 2>/dev/null |
        awk -v class_id="$class_id" '$1 == "class" && $3 == class_id { found=1 } END { exit found ? 0 : 1 }'
}

save_tc_class_id() {
    local port="$1"
    local class_id="$2"

    tc_port_class_id_valid "$class_id" >/dev/null 2>&1 || return 1
    jq -e --arg port "$port" '.ports[$port] // empty' "$CONFIG_FILE" >/dev/null 2>&1 || return 1
    update_config_file '
        if ([.ports | to_entries[] |
            select(.key != $port and (.value.bandwidth_limit.class_id // "") == $class_id)] | length) == 0 then
            .ports[$port].bandwidth_limit.class_id = $class_id
        else
            error("tc class id collision")
        end
    ' \
        --arg port "$port" \
        --arg class_id "$class_id"
}

generate_legacy_tc_class_id() {
    local port=$1
    local minor
    if is_port_range "$port"; then
        local mark_id
        mark_id=$(generate_port_range_mark "$port")
        minor=$((0x2000 + mark_id))
    else
        minor=$((0x1000 + port))
    fi
    echo "1:$(printf '%x' "$minor")"
}

generate_tc_minor_base() {
    local port=$1
    local preferred_minor
    local fallback_minor
    if is_port_range "$port"; then
        local mark_id
        mark_id=$(generate_port_range_mark "$port")
        preferred_minor=$((0x2000 + mark_id))
        fallback_minor=$((0x8000 + (mark_id % 0x7fff)))
    else
        preferred_minor=$((0x1000 + port))
        fallback_minor=$((2 + (((port * 1103515245 + 12345) & 0x7fffffff) % 65534)))
    fi

    if [ "$preferred_minor" -ge 2 ] && [ "$preferred_minor" -le 65535 ]; then
        echo "$preferred_minor"
    else
        echo "$fallback_minor"
    fi
}

get_daily_total_traffic() {
    local total_bytes=0
    local ports=($(get_active_ports))
    for port in "${ports[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local port_total=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        total_bytes=$(( total_bytes + port_total ))
    done
    format_bytes $total_bytes
}

is_leap_year() {
    local year="$1"
    (( (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0) ))
}

get_days_in_month() {
    local year="$1"
    local month="$2"
    case "$month" in
        1|3|5|7|8|10|12) echo 31 ;;
        4|6|9|11) echo 30 ;;
        2)
            if is_leap_year "$year"; then
                echo 29
            else
                echo 28
            fi
            ;;
        *) echo 30 ;;
    esac
}

normalize_year_month() {
    local year="$1"
    local month="$2"

    while [ "$month" -lt 1 ]; do
        month=$((month + 12))
        year=$((year - 1))
    done
    while [ "$month" -gt 12 ]; do
        month=$((month - 12))
        year=$((year + 1))
    done

    echo "$year $month"
}

clamp_day_to_month() {
    local year="$1"
    local month="$2"
    local day="$3"
    local month_days
    month_days=$(get_days_in_month "$year" "$month")

    if [ "$day" -lt 1 ]; then
        day=1
    fi
    if [ "$day" -gt "$month_days" ]; then
        day="$month_days"
    fi

    echo "$day"
}

get_current_date() {
    get_beijing_time +%Y-%m-%d
}

date_parts() {
    local date_value="$1"
    echo "${date_value:0:4} $((10#${date_value:5:2})) $((10#${date_value:8:2}))"
}

format_date() {
    local year="$1"
    local month="$2"
    local day="$3"
    printf '%04d-%02d-%02d\n' "$year" "$month" "$day"
}

is_valid_date() {
    local date_value="$1"
    [[ "$date_value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1

    local parts=($(date_parts "$date_value"))
    local year="${parts[0]}"
    local month="${parts[1]}"
    local day="${parts[2]}"

    [ "$year" -ge 1 ] && [ "$year" -le 9999 ] || return 1
    [ "$month" -ge 1 ] && [ "$month" -le 12 ] || return 1
    local month_days
    month_days=$(get_days_in_month "$year" "$month")
    [ "$day" -ge 1 ] && [ "$day" -le "$month_days" ]
}

date_lt() {
    [[ "$1" < "$2" ]]
}

date_le() {
    [[ "$1" < "$2" || "$1" = "$2" ]]
}

is_before_daily_reset_check() {
    local hm
    hm=$(get_beijing_time +%H%M)
    [ "$((10#$hm))" -lt 5 ]
}

days_before_year() {
    local year="$1"
    local previous_year=$((year - 1))
    echo $((365 * previous_year + previous_year / 4 - previous_year / 100 + previous_year / 400))
}

date_to_ordinal() {
    local date_value="$1"
    is_valid_date "$date_value" || return 1
    local parts=($(date_parts "$date_value"))
    local year="${parts[0]}"
    local month="${parts[1]}"
    local day="${parts[2]}"
    local month_offsets=(0 0 31 59 90 120 151 181 212 243 273 304 334)
    local ordinal
    ordinal=$(days_before_year "$year")
    ordinal=$((ordinal + month_offsets[month] + day))
    if [ "$month" -gt 2 ] && is_leap_year "$year"; then
        ordinal=$((ordinal + 1))
    fi
    echo "$ordinal"
}

ordinal_to_date() {
    local ordinal="$1"
    local max_ordinal
    max_ordinal=$(date_to_ordinal "9999-12-31")
    [[ "$ordinal" =~ ^[0-9]+$ ]] && [ "$ordinal" -ge 1 ] && [ "$ordinal" -le "$max_ordinal" ] || return 1

    local low=1
    local high=9999
    local year=1
    while [ "$low" -le "$high" ]; do
        local middle=$(((low + high) / 2))
        local first_day=$(( $(days_before_year "$middle") + 1 ))
        if [ "$first_day" -le "$ordinal" ]; then
            year="$middle"
            low=$((middle + 1))
        else
            high=$((middle - 1))
        fi
    done

    local day_of_year=$((ordinal - $(days_before_year "$year")))
    local month=1
    local month_days
    while :; do
        month_days=$(get_days_in_month "$year" "$month")
        [ "$day_of_year" -le "$month_days" ] && break
        day_of_year=$((day_of_year - month_days))
        month=$((month + 1))
    done
    format_date "$year" "$month" "$day_of_year"
}

add_days_to_date() {
    local date_value="$1"
    local days="$2"
    [[ "$days" =~ ^-?[0-9]+$ ]] || return 1
    local ordinal
    ordinal=$(date_to_ordinal "$date_value") || return 1
    ordinal_to_date "$((ordinal + days))"
}

add_months_to_date() {
    local date_value="$1"
    local months="$2"
    local desired_day="${3:-}"
    local parts=($(date_parts "$date_value"))
    local year="${parts[0]}"
    local month="${parts[1]}"
    local day="${parts[2]}"

    if [ -n "$desired_day" ]; then
        day="$desired_day"
    fi

    local normalized=($(normalize_year_month "$year" "$((month + months))"))
    year="${normalized[0]}"
    month="${normalized[1]}"
    day=$(clamp_day_to_month "$year" "$month" "$day")

    format_date "$year" "$month" "$day"
}

add_years_to_date() {
    local date_value="$1"
    local years="$2"
    local desired_month="${3:-}"
    local desired_day="${4:-}"
    local parts=($(date_parts "$date_value"))
    local year="${parts[0]}"
    local month="${parts[1]}"
    local day="${parts[2]}"

    year=$((year + years))
    if [ -n "$desired_month" ]; then
        month="$desired_month"
    fi
    if [ -n "$desired_day" ]; then
        day="$desired_day"
    fi
    day=$(clamp_day_to_month "$year" "$month" "$day")

    format_date "$year" "$month" "$day"
}

get_port_created_date() {
    local port="$1"
    local created_at
    created_at=$(jq -r ".ports.\"$port\".created_at // empty" "$CONFIG_FILE" 2>/dev/null)
    if [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        echo "${created_at:0:10}"
    else
        get_current_date
    fi
}

calculate_monthly_next_date() {
    local day="$1"
    local from_date="$2"
    local parts=($(date_parts "$from_date"))
    local year="${parts[0]}"
    local month="${parts[1]}"
    local candidate_day
    candidate_day=$(clamp_day_to_month "$year" "$month" "$day")
    local candidate
    candidate=$(format_date "$year" "$month" "$candidate_day")

    if date_lt "$candidate" "$from_date"; then
        local next=($(normalize_year_month "$year" "$((month + 1))"))
        year="${next[0]}"
        month="${next[1]}"
        candidate_day=$(clamp_day_to_month "$year" "$month" "$day")
        candidate=$(format_date "$year" "$month" "$candidate_day")
    fi

    echo "$candidate"
}

calculate_interval_days_next_date() {
    local anchor_date="$1"
    local every_days="$2"
    local from_date="$3"
    [[ "$every_days" =~ ^[0-9]+$ ]] && [ "$every_days" -ge 1 ] || return 1
    local anchor_ordinal
    local from_ordinal
    anchor_ordinal=$(date_to_ordinal "$anchor_date") || return 1
    from_ordinal=$(date_to_ordinal "$from_date") || return 1
    if [ "$anchor_ordinal" -ge "$from_ordinal" ]; then
        echo "$anchor_date"
        return
    fi
    local distance=$((from_ordinal - anchor_ordinal))
    local steps=$(((distance + every_days - 1) / every_days))
    ordinal_to_date "$((anchor_ordinal + steps * every_days))"
}

calculate_interval_months_next_date() {
    local anchor_date="$1"
    local every_months="$2"
    local desired_day="$3"
    local from_date="$4"
    [[ "$every_months" =~ ^[0-9]+$ ]] && [ "$every_months" -ge 1 ] || return 1
    if ! date_lt "$anchor_date" "$from_date"; then
        echo "$anchor_date"
        return
    fi

    local anchor_parts=($(date_parts "$anchor_date"))
    local from_parts=($(date_parts "$from_date"))
    local anchor_month_index=$((anchor_parts[0] * 12 + anchor_parts[1] - 1))
    local from_month_index=$((from_parts[0] * 12 + from_parts[1] - 1))
    local month_distance=$((from_month_index - anchor_month_index))
    local steps=$((month_distance / every_months))
    local candidate
    candidate=$(add_months_to_date "$anchor_date" "$((steps * every_months))" "$desired_day")
    if date_lt "$candidate" "$from_date"; then
        candidate=$(add_months_to_date "$anchor_date" "$(((steps + 1) * every_months))" "$desired_day")
    fi
    echo "$candidate"
}

calculate_yearly_next_date() {
    local month="$1"
    local day="$2"
    local from_date="$3"
    local parts=($(date_parts "$from_date"))
    local year="${parts[0]}"
    local candidate_day
    candidate_day=$(clamp_day_to_month "$year" "$month" "$day")
    local candidate
    candidate=$(format_date "$year" "$month" "$candidate_day")

    if date_lt "$candidate" "$from_date"; then
        year=$((year + 1))
        candidate_day=$(clamp_day_to_month "$year" "$month" "$day")
        candidate=$(format_date "$year" "$month" "$candidate_day")
    fi

    echo "$candidate"
}

get_quota_limit() {
    local port="$1"
    jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE" 2>/dev/null
}

get_quota_enabled() {
    local port="$1"
    jq -r ".ports.\"$port\".quota.enabled // true" "$CONFIG_FILE" 2>/dev/null
}

is_known_reset_policy_type() {
    case "$1" in
        monthly|interval_days|interval_months|yearly|fixed_date|none) return 0 ;;
        *) return 1 ;;
    esac
}

get_reset_policy_type() {
    local port="$1"
    local policy_type
    policy_type=$(jq -r ".ports.\"$port\".quota.reset_policy.type // empty" "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$policy_type" ] && [ "$policy_type" != "null" ] && is_known_reset_policy_type "$policy_type"; then
        echo "$policy_type"
        return
    fi

    local reset_day_raw
    reset_day_raw=$(jq -r ".ports.\"$port\".quota.reset_day // null" "$CONFIG_FILE" 2>/dev/null)
    if [[ "$reset_day_raw" =~ ^[0-9]+$ ]] && [ "$reset_day_raw" -ge 1 ] && [ "$reset_day_raw" -le 31 ]; then
        echo "monthly"
    else
        echo "none"
    fi
}

port_has_auto_reset_policy() {
    local port="$1"
    local quota_enabled
    quota_enabled=$(get_quota_enabled "$port")
    local quota_limit
    quota_limit=$(get_quota_limit "$port")
    local policy_type
    policy_type=$(get_reset_policy_type "$port")

    [ "$quota_enabled" = "true" ] && [ "$quota_limit" != "unlimited" ] && [ "$policy_type" != "none" ]
}

calculate_port_next_reset_date() {
    local port="$1"
    local from_date="${2:-$(get_current_date)}"
    local policy_type
    policy_type=$(get_reset_policy_type "$port")

    case "$policy_type" in
        monthly)
            local day
            day=$(jq -r ".ports.\"$port\".quota.reset_policy.day // .ports.\"$port\".quota.reset_day // 1" "$CONFIG_FILE" 2>/dev/null)
            if ! [[ "$day" =~ ^[0-9]+$ ]] || [ "$day" -lt 1 ] || [ "$day" -gt 31 ]; then
                day=1
            fi
            calculate_monthly_next_date "$day" "$from_date"
            ;;
        interval_days)
            local every_days
            every_days=$(jq -r ".ports.\"$port\".quota.reset_policy.every // 30" "$CONFIG_FILE" 2>/dev/null)
            local anchor_date
            anchor_date=$(jq -r ".ports.\"$port\".quota.reset_policy.anchor_date // empty" "$CONFIG_FILE" 2>/dev/null)
            if ! [[ "$every_days" =~ ^[0-9]+$ ]] || [ "$every_days" -lt 1 ]; then
                every_days=30
            fi
            if ! is_valid_date "$anchor_date"; then
                anchor_date=$(get_port_created_date "$port")
            fi
            calculate_interval_days_next_date "$anchor_date" "$every_days" "$from_date"
            ;;
        interval_months)
            local every_months
            every_months=$(jq -r ".ports.\"$port\".quota.reset_policy.every // 1" "$CONFIG_FILE" 2>/dev/null)
            local anchor_date
            anchor_date=$(jq -r ".ports.\"$port\".quota.reset_policy.anchor_date // empty" "$CONFIG_FILE" 2>/dev/null)
            local day
            day=$(jq -r ".ports.\"$port\".quota.reset_policy.day // empty" "$CONFIG_FILE" 2>/dev/null)
            if ! [[ "$every_months" =~ ^[0-9]+$ ]] || [ "$every_months" -lt 1 ]; then
                every_months=1
            fi
            if ! is_valid_date "$anchor_date"; then
                anchor_date=$(get_port_created_date "$port")
            fi
            if ! [[ "$day" =~ ^[0-9]+$ ]] || [ "$day" -lt 1 ] || [ "$day" -gt 31 ]; then
                local parts=($(date_parts "$anchor_date"))
                day="${parts[2]}"
            fi
            calculate_interval_months_next_date "$anchor_date" "$every_months" "$day" "$from_date"
            ;;
        yearly)
            local month
            local day
            month=$(jq -r ".ports.\"$port\".quota.reset_policy.month // 1" "$CONFIG_FILE" 2>/dev/null)
            day=$(jq -r ".ports.\"$port\".quota.reset_policy.day // 1" "$CONFIG_FILE" 2>/dev/null)
            if ! [[ "$month" =~ ^[0-9]+$ ]] || [ "$month" -lt 1 ] || [ "$month" -gt 12 ]; then
                month=1
            fi
            if ! [[ "$day" =~ ^[0-9]+$ ]] || [ "$day" -lt 1 ] || [ "$day" -gt 31 ]; then
                day=1
            fi
            calculate_yearly_next_date "$month" "$day" "$from_date"
            ;;
        fixed_date)
            local date_value
            date_value=$(jq -r ".ports.\"$port\".quota.reset_policy.date // empty" "$CONFIG_FILE" 2>/dev/null)
            if is_valid_date "$date_value"; then
                echo "$date_value"
            else
                echo ""
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

ensure_port_next_reset_date() {
    local port="$1"
    port_has_auto_reset_policy "$port" || return 1

    local policy_type
    policy_type=$(get_reset_policy_type "$port")
    local migrated_legacy_monthly="false"
    if [ "$policy_type" = "monthly" ]; then
        local policy_saved_type
        policy_saved_type=$(jq -r ".ports.\"$port\".quota.reset_policy.type // empty" "$CONFIG_FILE" 2>/dev/null)
        if [ -z "$policy_saved_type" ] || ! is_known_reset_policy_type "$policy_saved_type"; then
            migrated_legacy_monthly="true"
            local reset_day
            reset_day=$(jq -r ".ports.\"$port\".quota.reset_policy.day // .ports.\"$port\".quota.reset_day // 1" "$CONFIG_FILE" 2>/dev/null)
            if ! [[ "$reset_day" =~ ^[0-9]+$ ]] || [ "$reset_day" -lt 1 ] || [ "$reset_day" -gt 31 ]; then
                reset_day=1
            fi
            update_config_file '
                .ports[$port].quota.reset_policy.type = "monthly" |
                .ports[$port].quota.reset_policy.day = $day |
                .ports[$port].quota.reset_day = $day
            ' --arg port "$port" --argjson day "$reset_day"
        fi
    fi

    local next_reset_date
    next_reset_date=$(jq -r ".ports.\"$port\".quota.reset_policy.next_reset_date // empty" "$CONFIG_FILE" 2>/dev/null)
    if ! is_valid_date "$next_reset_date"; then
        local from_date
        from_date=$(get_current_date)
        if [ "$policy_type" != "fixed_date" ]; then
            if [ "$migrated_legacy_monthly" != "true" ] || ! is_before_daily_reset_check; then
                from_date=$(add_days_to_date "$from_date" 1)
            fi
        fi
        next_reset_date=$(calculate_port_next_reset_date "$port" "$from_date")
        [ -n "$next_reset_date" ] || return 1
        update_config_file '
            .ports[$port].quota.reset_policy.next_reset_date = $next
        ' --arg port "$port" --arg next "$next_reset_date"
    fi

    echo "$next_reset_date"
}

advance_port_next_reset_date() {
    local port="$1"
    local after_date="${2:-$(get_current_date)}"
    local policy_type
    policy_type=$(get_reset_policy_type "$port")

    if [ "$policy_type" = "fixed_date" ]; then
        update_config_file '
            .ports[$port].quota.reset_policy.type = "none" |
            del(.ports[$port].quota.reset_policy.next_reset_date)
        ' --arg port "$port"
        setup_port_auto_reset_cron "$port"
        return
    fi

    local from_date
    from_date=$(add_days_to_date "$after_date" 1)
    local next_reset_date
    next_reset_date=$(calculate_port_next_reset_date "$port" "$from_date")
    [ -n "$next_reset_date" ] || return 1

    update_config_file '
        .ports[$port].quota.reset_policy.last_reset_date = $last |
        .ports[$port].quota.reset_policy.next_reset_date = $next
    ' --arg port "$port" --arg last "$after_date" --arg next "$next_reset_date"
}

get_port_next_reset_label() {
    local port="$1"
    port_has_auto_reset_policy "$port" || return 1

    local next_reset_date
    next_reset_date=$(ensure_port_next_reset_date "$port" 2>/dev/null || true)
    [ -n "$next_reset_date" ] || return 1

    local policy_type
    policy_type=$(get_reset_policy_type "$port")
    case "$policy_type" in
        monthly) echo "${next_reset_date}重置" ;;
        interval_days)
            local every
            every=$(jq -r ".ports.\"$port\".quota.reset_policy.every // 30" "$CONFIG_FILE" 2>/dev/null)
            echo "每${every}天，${next_reset_date}重置"
            ;;
        interval_months)
            local every
            every=$(jq -r ".ports.\"$port\".quota.reset_policy.every // 1" "$CONFIG_FILE" 2>/dev/null)
            echo "每${every}个月，${next_reset_date}重置"
            ;;
        yearly) echo "每年，${next_reset_date}重置" ;;
        fixed_date) echo "${next_reset_date}到期重置一次" ;;
        *) return 1 ;;
    esac
}

get_port_cycle_range() {
    local port="$1"
    local policy_type
    policy_type=$(get_reset_policy_type "$port")

    if [ "$policy_type" != "monthly" ]; then
        local start_date
        start_date=$(jq -r ".ports.\"$port\".quota.reset_policy.last_reset_date // .ports.\"$port\".quota.reset_policy.anchor_date // empty" "$CONFIG_FILE" 2>/dev/null)
        if ! is_valid_date "$start_date"; then
            start_date=$(get_port_created_date "$port")
        fi

        local next_date
        next_date=$(ensure_port_next_reset_date "$port" 2>/dev/null || true)
        if is_valid_date "$next_date"; then
            if [ "$policy_type" = "fixed_date" ]; then
                echo "${start_date}-${next_date}"
            else
                local end_date
                end_date=$(add_days_to_date "$next_date" -1 2>/dev/null || true)
                if [ -n "$end_date" ] && ! date_lt "$end_date" "$start_date"; then
                    echo "${start_date}-${end_date}"
                else
                    echo "${start_date}-${next_date}"
                fi
            fi
        else
            echo "${start_date}-未设置"
        fi
        return
    fi

    local reset_day_raw
    reset_day_raw=$(jq -r ".ports.\"$port\".quota.reset_policy.day // .ports.\"$port\".quota.reset_day // null" "$CONFIG_FILE" 2>/dev/null)

    local reset_day=1
    if [[ "$reset_day_raw" =~ ^[0-9]+$ ]] && [ "$reset_day_raw" -ge 1 ] && [ "$reset_day_raw" -le 31 ]; then
        reset_day="$reset_day_raw"
    fi

    local time_info=($(get_beijing_month_year))
    local current_day="${time_info[0]}"
    local current_month="${time_info[1]}"
    local current_year="${time_info[2]}"

    local start_year
    local start_month
    local current_reset_day
    current_reset_day=$(clamp_day_to_month "$current_year" "$current_month" "$reset_day")
    if [ "$current_day" -ge "$current_reset_day" ]; then
        start_year="$current_year"
        start_month="$current_month"
    else
        local prev=($(normalize_year_month "$current_year" "$((current_month - 1))"))
        start_year="${prev[0]}"
        start_month="${prev[1]}"
    fi

    local start_day
    start_day=$(clamp_day_to_month "$start_year" "$start_month" "$reset_day")

    local end_year
    local end_month
    local end_day
    if [ "$reset_day" -eq 1 ]; then
        end_year="$start_year"
        end_month="$start_month"
        end_day=$(get_days_in_month "$end_year" "$end_month")
    else
        local next=($(normalize_year_month "$start_year" "$((start_month + 1))"))
        end_year="${next[0]}"
        end_month="${next[1]}"
        end_day=$(clamp_day_to_month "$end_year" "$end_month" "$((reset_day - 1))")
    fi

    echo "${start_year}/${start_month}/${start_day}-${end_year}/${end_month}/${end_day}"
}

build_usage_progress_bar() {
    local percent="${1:-0}"
    local width=20
    local capped="$percent"

    if [ "$capped" -lt 0 ]; then
        capped=0
    fi
    if [ "$capped" -gt 100 ]; then
        capped=100
    fi

    local filled=0
    if [ "$capped" -le 0 ]; then
        filled=0
    elif [ "$capped" -lt 50 ]; then
        # 50%以下按5%一格向上取整：1%-5%显示1格
        filled=$(((capped + 4) / 5))
    else
        # 50%及以上保持线性：50%=10格，100%=20格
        filled=$((capped / 5))
    fi
    if [ "$filled" -gt "$width" ]; then
        filled="$width"
    fi
    local empty=$((width - filled))
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do
        bar="${bar}█"
    done
    for ((i=0; i<empty; i++)); do
        bar="${bar}░"
    done

    echo "$bar"
}

format_port_list() {
    local format_type="$1"
    local active_ports=($(get_active_ports))
    local result=""
    local index=1

    for port in "${active_ports[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        local total_formatted=$(format_bytes $total_bytes)
        local output_formatted=$(format_bytes $output_bytes)
        local status_label=$(get_port_status_label "$port")

        local input_formatted=$(format_bytes $input_bytes)


        if [ "$format_type" = "display" ]; then
            echo -e "端口:${GREEN}$port${NC} | 总流量:${GREEN}$total_formatted${NC} | 入站(下载):${GREEN}$input_formatted${NC} | 出站(上传):${GREEN}$output_formatted${NC} | ${YELLOW}$status_label${NC}"
        elif [ "$format_type" = "markdown" ]; then
            result+="> 端口:**${port}** | 总流量:**${total_formatted}** | 入站:**${input_formatted}** | 出站:**${output_formatted}** | ${status_label}
"
        elif [ "$format_type" = "telegram" ]; then
            local status_prefix=""
            if [ -n "$status_label" ]; then
                status_prefix="${status_label} | "
            fi

            if [ -n "$result" ]; then
                result+="

"
            fi

            result+="${index}. ${status_prefix}端口:${port}
总流量:${total_formatted} | 入站(下载):${input_formatted} | 出站(上传):${output_formatted}"

            local quota_enabled=$(jq -r ".ports.\"$port\".quota.enabled // true" "$CONFIG_FILE")
            local monthly_limit=$(jq -r ".ports.\"$port\".quota.monthly_limit // \"unlimited\"" "$CONFIG_FILE")
            if [ "$quota_enabled" = "true" ] && [ "$monthly_limit" != "unlimited" ]; then
                local limit_bytes=$(parse_size_to_bytes "$monthly_limit")
                local usage_percent=0
                if [ "$limit_bytes" -gt 0 ]; then
                    usage_percent=$((total_bytes * 100 / limit_bytes))
                fi

                local cycle_range
                cycle_range=$(get_port_cycle_range "$port")
                local progress_bar
                progress_bar=$(build_usage_progress_bar "$usage_percent")

                local percent_text="${usage_percent}%"
                if [ "$usage_percent" -ge 100 ]; then
                    percent_text="${usage_percent}% (超限)"
                fi

                result+="
${total_formatted}/${monthly_limit} | ${percent_text} | ${cycle_range}
[${progress_bar}]"
            fi
        else
            result+="
端口:${port} | 总流量:${total_formatted} | 入站(下载):${input_formatted} | 出站(上传):${output_formatted} | ${status_label}"
        fi

        index=$((index + 1))
    done

    if [ "$format_type" = "message" ] || [ "$format_type" = "markdown" ] || [ "$format_type" = "telegram" ]; then
        echo "$result"
    fi
}

# Dog 与 NTC 共用同一个恢复入口和同一个 systemd oneshot，避免两边各自抢 root。
tc_recovery_systemd_available() {
    command -v "$TC_RECOVERY_SYSTEMCTL" >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

install_tc_recovery_service_files() {
    local runner_dir unit_dir runner_tmp unit_tmp
    runner_dir=$(dirname "$TC_RECOVERY_RUNNER")
    unit_dir=$(dirname "$TC_RECOVERY_UNIT_FILE")
    runner_tmp="${TC_RECOVERY_RUNNER}.tmp.$$"
    unit_tmp="${TC_RECOVERY_UNIT_FILE}.tmp.$$"

    if [ -e "$TC_RECOVERY_RUNNER" ] &&
       ! grep -Fq '# traffic-tools-tc-recovery-v1' "$TC_RECOVERY_RUNNER" 2>/dev/null; then
        echo "共享 TC 恢复入口已被其他文件占用: $TC_RECOVERY_RUNNER" >&2
        return 1
    fi
    mkdir -p "$runner_dir" || return 1
    cat > "$runner_tmp" <<'EOF'
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

if [ -r "$dog_script" ] && [ -r "$dog_config" ]; then
    bash "$dog_script" --recover-tc "$mode"
    handled=true
fi
if [ -r "$ntc_monitor" ] && [ -r "$ntc_config" ]; then
    bash "$ntc_monitor" --tc-recover-owned "$mode"
    handled=true
fi

$handled || exit 0
EOF
    chmod 755 "$runner_tmp" || { rm -f "$runner_tmp"; return 1; }
    if ! cmp -s "$runner_tmp" "$TC_RECOVERY_RUNNER"; then
        mv -f "$runner_tmp" "$TC_RECOVERY_RUNNER" || { rm -f "$runner_tmp"; return 1; }
    else
        rm -f "$runner_tmp"
    fi

    tc_recovery_systemd_available || return 0
    if [ -e "$TC_RECOVERY_UNIT_FILE" ] &&
       ! grep -Fq '# traffic-tools-tc-recovery-v1' "$TC_RECOVERY_UNIT_FILE" 2>/dev/null; then
        echo "共享 TC 恢复服务名已被其他 unit 占用: $TC_RECOVERY_UNIT_FILE" >&2
        return 1
    fi
    mkdir -p "$unit_dir" || return 1
    cat > "$unit_tmp" <<EOF
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
    "$TC_RECOVERY_SYSTEMCTL" disable "$TC_RECOVERY_SERVICE" >/dev/null 2>&1 || true
}

cleanup_tc_recovery_files_if_unused() {
    if { [ -r /usr/local/bin/port-traffic-dog.sh ] && [ -r /etc/port-traffic-dog/config.json ]; } ||
       { [ -r /etc/trafficcop-lite/trafficcop-lite-monitor.sh ] && [ -r /etc/trafficcop-lite/traffic_monitor_config.txt ]; }; then
        return 0
    fi
    if tc_recovery_systemd_available; then
        "$TC_RECOVERY_SYSTEMCTL" disable --now "$TC_RECOVERY_SERVICE" >/dev/null 2>&1 || true
    fi
    if grep -Fq '# traffic-tools-tc-recovery-v1' "$TC_RECOVERY_UNIT_FILE" 2>/dev/null; then
        rm -f "$TC_RECOVERY_UNIT_FILE"
    fi
    if grep -Fq '# traffic-tools-tc-recovery-v1' "$TC_RECOVERY_RUNNER" 2>/dev/null; then
        rm -f "$TC_RECOVERY_RUNNER"
    fi
    tc_recovery_systemd_available && "$TC_RECOVERY_SYSTEMCTL" daemon-reload >/dev/null 2>&1 || true
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

show_tc_takeover_warning() {
    echo -e "${RED}检测到当前 TC 配置可能已被其他程序修改。${NC}"
    echo "继续操作将删除当前冲突的 TC/qdisc 配置，"
    echo "并只重新建立 Dog/NTC 体系自身管理的规则。"
    echo "其他程序创建的 TC 配置不会被保留。"
    echo
    echo -e "${YELLOW}如果其他 TC 管理脚本或服务仍然存在，其之后再次启动或重启时，"
    echo -e "仍可能覆盖 Dog/NTC。建议卸载、关闭或禁用这些冲突程序。${NC}"
}

run_shared_tc_recovery() {
    local mode="${1:---manual}"
    install_tc_recovery_service_files || return 1
    bash "$TC_RECOVERY_RUNNER" "$mode"
}

manage_tc_recovery() {
    clear 2>/dev/null || true
    echo -e "${BLUE}=== TC 冲突处理 / 自动恢复 ===${NC}"
    echo "TC 状态: $(dog_tc_status_label)"
    echo "自动恢复: $(tc_auto_recovery_state)"
    echo "恢复方式: 单一 systemd oneshot；启用后在网络就绪时执行一次"
    echo
    echo "1. 立即检测并重建 Dog/NTC 规则"
    echo "2. 立即重建，并启用开机自动恢复"
    echo "3. 启用开机自动恢复"
    echo "4. 关闭开机自动恢复"
    echo "0. 返回主菜单"
    echo
    read -r -p "请选择操作 [0-4]: " tc_choice
    case "$tc_choice" in
        1|2)
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
        3)
            show_tc_takeover_warning
            echo
            echo "启用后，恢复服务在开机时检测到既有 Dog/NTC 规则失效，"
            echo "会按上述授权删除冲突 root 并重建；运行期间不会高频轮询或抢占。"
            read -r -p "确认启用请输入 ENABLE: " confirm
            if [ "$confirm" = "ENABLE" ] && enable_tc_auto_recovery; then
                echo -e "${GREEN}开机自动恢复已启用。${NC}"
            else
                echo "未启用。"
            fi
            ;;
        4)
            disable_tc_auto_recovery
            echo -e "${GREEN}开机自动恢复已关闭。${NC}"
            ;;
        0) show_main_menu; return ;;
        *) echo -e "${RED}无效选择。${NC}" ;;
    esac
    echo
    read -r -p "按回车键返回主菜单..."
    show_main_menu
}

# 显示主界面
show_main_menu() {
    clear 2>/dev/null || true

    local active_ports=($(get_active_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    echo -e "${BLUE}=== 端口流量狗 v$SCRIPT_VERSION ===${NC}"
    echo

    echo -e "${GREEN}状态: 监控中${NC} | ${BLUE}守护端口: ${port_count}个${NC} | ${YELLOW}端口总流量: $daily_total${NC}"
    echo -e "${BLUE}TC 状态:${NC} $(dog_tc_status_label) | ${BLUE}自动恢复:${NC} $(tc_auto_recovery_state)"
    echo "────────────────────────────────────────────────────────"

    if [ $port_count -gt 0 ]; then
        format_port_list "display"
    else
        echo -e "${YELLOW}暂无监控端口${NC}"
    fi

    echo "────────────────────────────────────────────────────────"

    echo -e "${BLUE}1.${NC} 添加/删除端口监控     ${BLUE}2.${NC} 端口限制设置管理"
    echo -e "${BLUE}3.${NC} 流量重置管理          ${BLUE}4.${NC} 一键导出/导入配置"
    echo -e "${BLUE}5.${NC} 安装依赖(更新)脚本    ${BLUE}6.${NC} 卸载脚本"
    echo -e "${BLUE}7.${NC} 通知管理              ${BLUE}8.${NC} 系统自检/修复"
    echo -e "${BLUE}9.${NC} TC 冲突处理/自动恢复"
    echo -e "${BLUE}0.${NC} 退出"
    echo
    read -p "请选择操作 [0-9]: " choice

    case $choice in
        1) manage_port_monitoring ;;
        2) manage_traffic_limits ;;
        3) manage_traffic_reset ;;
        4) manage_configuration ;;
        5) install_update_script ;;
        6) uninstall_script ;;
        7) manage_notifications ;;
        8) system_check_and_repair ;;
        9) manage_tc_recovery ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择，请输入0-9${NC}"; sleep 1; show_main_menu ;;
    esac
}

manage_port_monitoring() {
    echo -e "${BLUE}=== 端口监控管理 ===${NC}"
    echo "1. 添加端口监控"
    echo "2. 删除端口监控"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-2]: " choice

    case $choice in
        1) add_port_monitoring ;;
        2) remove_port_monitoring ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_port_monitoring ;;
    esac
}

add_port_monitoring() {
    echo -e "${BLUE}=== 添加端口监控 ===${NC}"
    echo

    echo -e "${GREEN}当前系统端口使用情况:${NC}"
    printf "%-15s %-9s\n" "程序名" "端口"
    echo "────────────────────────────────────────────────────────"

    # 解析ss输出，聚合同程序的端口
    declare -A program_ports
    while read line; do
        if [[ "$line" =~ LISTEN|UNCONN ]]; then
            local_addr=$(echo "$line" | awk '{print $5}')
            port=$(echo "$local_addr" | grep -o ':[0-9]*$' | cut -d':' -f2)
            program=$(echo "$line" | awk '{print $7}' | cut -d'"' -f2 2>/dev/null || echo "")

            if [ -n "$port" ] && [ -n "$program" ] && [ "$program" != "-" ]; then
                if [ -z "${program_ports[$program]:-}" ]; then
                    program_ports[$program]="$port"
                else
                    # 避免重复端口
                    if [[ ! "${program_ports[$program]}" =~ (^|.*\|)$port(\||$) ]]; then
                        program_ports[$program]="${program_ports[$program]}|$port"
                    fi
                fi
            fi
        fi
    done < <(ss -tulnp 2>/dev/null || true)

    if [ ${#program_ports[@]} -gt 0 ]; then
        for program in $(printf '%s\n' "${!program_ports[@]}" | sort); do
            ports="${program_ports[$program]}"
            printf "%-10s | %-9s\n" "$program" "$ports"
        done
    else
        echo "无活跃端口"
    fi

    echo "────────────────────────────────────────────────────────"
    echo

    read -p "请输入要监控的端口号（多端口使用逗号,分隔,端口段使用-分隔）: " port_input

    local PORTS=()
    if ! parse_port_range_input "$port_input" PORTS; then
        sleep 2
        add_port_monitoring
        return
    fi
    local valid_ports=()

    for port in "${PORTS[@]}"; do
        if jq -e ".ports.\"$port\"" "$CONFIG_FILE" >/dev/null 2>&1; then
            echo -e "${YELLOW}端口 $port 已在监控列表中，跳过${NC}"
            continue
        fi

        local overlap_port=""
        local configured_port
        while IFS= read -r configured_port; do
            if port_specs_overlap "$port" "$configured_port"; then
                overlap_port="$configured_port"
                break
            fi
        done < <(jq -r '.ports // {} | keys[]' "$CONFIG_FILE" 2>/dev/null || true)
        if [ -z "$overlap_port" ]; then
            for configured_port in "${valid_ports[@]}"; do
                if port_specs_overlap "$port" "$configured_port"; then
                    overlap_port="$configured_port"
                    break
                fi
            done
        fi
        if [ -n "$overlap_port" ]; then
            echo -e "${YELLOW}端口 $port 与已选或已配置的 $overlap_port 重叠，跳过以避免重复计量${NC}"
            continue
        fi

        valid_ports+=("$port")
    done

    if [ ${#valid_ports[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可添加${NC}"
        sleep 2
        manage_port_monitoring
        return
    fi

    echo
    echo -e "${GREEN}说明:${NC}"
    echo "1. 双向流量统计"
    echo "   沿用上游规则，总流量 = 入站×2 + 出站×2"
    echo
    echo "2. 单向流量统计"
    echo "   双向规则减半，总流量 = 入站 + 出站"
    echo
    echo "请选择统计模式:"
    echo "1. 双向流量统计"
    echo "2. 单向流量统计"
    read -p "请选择(回车默认1) [1-2]: " billing_choice

    local billing_mode="double"
    case $billing_choice in
        1|"") billing_mode="double" ;;
        2) billing_mode="single" ;;
        *) billing_mode="double" ;;
    esac

    echo
    local port_list
    port_list=$(IFS=','; echo "${valid_ports[*]}")
    while true; do
        echo "为端口 $port_list 设置流量配额（总量控制）:"
        echo "请输入配额值（0为无限制）（要带单位MB/GB/T）:"
        echo "(多端口分别配额使用逗号,分隔)(只输入一个值，应用到所有端口):"
        read -p "流量配额(回车默认0): " quota_input

        if [ -z "$quota_input" ]; then
            quota_input="0"
        fi

        local QUOTAS=()
        parse_comma_separated_input "$quota_input" QUOTAS

        local all_valid=true
        for quota in "${QUOTAS[@]}"; do
            if [ "$quota" != "0" ] && ! validate_quota "$quota"; then
                echo -e "${RED}配额格式错误: $quota，请使用如：100MB, 1GB, 2T${NC}"
                all_valid=false
                break
            fi
        done

        if [ "$all_valid" = false ]; then
            echo "请重新输入配额值"
            continue
        fi

        expand_single_value_to_array QUOTAS ${#valid_ports[@]}
        if [ ${#QUOTAS[@]} -ne ${#valid_ports[@]} ]; then
            echo -e "${RED}配额值数量与端口数量不匹配${NC}"
            continue
        fi

        break
    done

    local reset_policy_config=""
    local RESET_POLICY_CONFIGS=()
    local separate_policy="false"
    local has_limited_quota=false
    local limited_quota_count=0
    for quota in "${QUOTAS[@]}"; do
        quota=$(echo "$quota" | tr -d ' ')
        if [ "$quota" != "0" ] && [ -n "$quota" ]; then
            has_limited_quota=true
            limited_quota_count=$((limited_quota_count + 1))
        fi
    done

    if [ "$has_limited_quota" = "true" ]; then
        echo
        echo "检测到已设置流量配额，请设置自动重置策略:"
        if [ "$limited_quota_count" -gt 1 ]; then
            read -p "是否为每个有限配额端口分别设置策略? [y/N]: " separate_choice
            if [[ "$separate_choice" =~ ^[Yy]$ ]]; then
                separate_policy="true"
            fi
        fi

        if [ "$separate_policy" = "true" ]; then
            for i in "${!valid_ports[@]}"; do
                local quota=$(echo "${QUOTAS[$i]}" | tr -d ' ')
                if [ "$quota" != "0" ] && [ -n "$quota" ]; then
                    local port="${valid_ports[$i]}"
                    echo
                    echo "设置端口 $port 的自动重置策略:"
                    prompt_reset_policy 1
                    RESET_POLICY_CONFIGS[$i]="$RESET_POLICY_CONFIG"
                fi
            done
        else
            prompt_reset_policy 1
            reset_policy_config="$RESET_POLICY_CONFIG"
        fi
    fi

    echo
    echo -e "${BLUE}=== 规则备注配置 ===${NC}"
    echo "请输入当前规则备注(可选，直接回车跳过):"
    echo "(多端口排序分别备注使用逗号,分隔)(只输入一个值，应用到所有端口):"
    read -p "备注: " remark_input

    local REMARKS=()
    if [ -n "$remark_input" ]; then
        parse_comma_separated_input "$remark_input" REMARKS

        expand_single_value_to_array REMARKS ${#valid_ports[@]}
        if [ ${#REMARKS[@]} -ne ${#valid_ports[@]} ]; then
            echo -e "${RED}备注数量与端口数量不匹配${NC}"
            sleep 2
            add_port_monitoring
            return
        fi
    fi

    local added_count=0
    for i in "${!valid_ports[@]}"; do
        local port="${valid_ports[$i]}"
        local quota=$(echo "${QUOTAS[$i]}" | tr -d ' ')
        local remark=""
        if [ ${#REMARKS[@]} -gt $i ]; then
            remark=$(echo "${REMARKS[$i]}" | tr -d ' ')
        fi

        local monthly_limit="unlimited"

        if [ "$quota" != "0" ] && [ -n "$quota" ]; then
            monthly_limit="$quota"
        fi

        local created_at
        created_at=$(get_beijing_time -Iseconds)
        local config_written=false
        if [ "$monthly_limit" != "unlimited" ]; then
            if update_config_file '.ports[$port] = {
                   "name": $name,
                   "enabled": true,
                   "billing_mode": $billing,
                   "bandwidth_limit": {
                       "enabled": false,
                       "rate": "unlimited"
                   },
                   "quota": {
                       "enabled": true,
                       "monthly_limit": $monthly,
                       "reset_day": 1
                   },
                   "remark": $remark,
                   "created_at": $created
               }' \
               --arg port "$port" \
               --arg name "端口$port" \
               --arg billing "$billing_mode" \
               --arg monthly "$monthly_limit" \
               --arg remark "$remark" \
               --arg created "$created_at"; then
                config_written=true
            fi
        else
            if update_config_file '.ports[$port] = {
                   "name": $name,
                   "enabled": true,
                   "billing_mode": $billing,
                   "bandwidth_limit": {
                       "enabled": false,
                       "rate": "unlimited"
                   },
                   "quota": {
                       "enabled": true,
                       "monthly_limit": $monthly
                   },
                   "remark": $remark,
                   "created_at": $created
               }' \
               --arg port "$port" \
               --arg name "端口$port" \
               --arg billing "$billing_mode" \
               --arg monthly "$monthly_limit" \
               --arg remark "$remark" \
               --arg created "$created_at"; then
                config_written=true
            fi
        fi

        if [ "$config_written" != "true" ]; then
            echo -e "${RED}端口 $port 配置写入失败，已跳过添加规则${NC}"
            continue
        fi

        local port_add_ok=true
        if ! add_nftables_rules "$port"; then
            port_add_ok=false
        fi
        if [ "$monthly_limit" != "unlimited" ]; then
            if [ "$port_add_ok" = "true" ] && ! apply_nftables_quota "$port" "$quota"; then
                port_add_ok=false
            fi
            local port_reset_policy_config="$reset_policy_config"
            if [ "$separate_policy" = "true" ]; then
                port_reset_policy_config="${RESET_POLICY_CONFIGS[$i]:-}"
            fi
            if [ "$port_add_ok" = "true" ] && [ -n "$port_reset_policy_config" ] &&
               ! apply_reset_policy_to_port "$port" "$port_reset_policy_config"; then
                port_add_ok=false
            fi
        fi

        if [ "$port_add_ok" != "true" ]; then
            remove_nftables_quota "$port" >/dev/null 2>&1 || true
            remove_nftables_rules "$port" >/dev/null 2>&1 || true
            update_config_file 'del(.ports[$port])' --arg port "$port" >/dev/null 2>&1 || true
            remove_port_traffic_state "$port" >/dev/null 2>&1 || true
            echo -e "${RED}端口 $port 监控规则应用失败，已回滚该端口配置${NC}"
            continue
        fi

        update_traffic_snapshot_baseline "$port" >/dev/null 2>&1 || true

        echo -e "${GREEN}端口 $port 监控添加成功${NC}"
        added_count=$((added_count + 1))
    done

    refresh_port_auto_reset_cron_from_config
    refresh_notification_cron_from_config
    setup_traffic_snapshot_cron

    echo
    echo -e "${GREEN}成功添加 $added_count 个端口监控${NC}"

    sleep 2
    manage_port_monitoring
}

clear_port_conntrack_state() {
    local port_spec="$1"
    local destination_port="$port_spec"
    if is_port_range "$port_spec"; then
        destination_port="${port_spec%%-*}:${port_spec##*-}"
    fi
    conntrack -D -p tcp --dport "$destination_port" 2>/dev/null || true
    conntrack -D -p udp --dport "$destination_port" 2>/dev/null || true
}

remove_port_monitoring() {
    echo -e "${BLUE}=== 删除端口监控 ===${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_port_monitoring
        return
    fi
    echo

    read -p "请选择要删除的端口（多端口使用逗号,分隔）: " choice_input

    local valid_choices=()
    local ports_to_delete=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_delete+=("$port")
    done

    if [ ${#ports_to_delete[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可删除${NC}"
        sleep 2
        remove_port_monitoring
        return
    fi

    echo
    echo "将删除以下端口的监控:"
    for port in "${ports_to_delete[@]}"; do
        echo "  端口 $port"
    done
    echo

    read -p "确认删除这些端口的监控? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local deleted_count=0
        local deleted_ports=()
        for port in "${ports_to_delete[@]}"; do
            local saved_class_id
            local saved_mark_id
            saved_class_id=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.class_id // empty' "$CONFIG_FILE")
            saved_mark_id=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.mark_id // empty' "$CONFIG_FILE")
            if ! save_traffic_data; then
                echo -e "${RED}端口 $port 流量备份失败，已取消删除以避免数据丢失${NC}"
                continue
            fi
            if ! update_config_file 'del(.ports[$port])' --arg port "$port"; then
                echo -e "${RED}端口 $port 配置写入失败，未删除任何监控数据${NC}"
                continue
            fi

            remove_nftables_rules "$port"
            remove_nftables_quota "$port"
            if ! remove_tc_limit "$port" "$saved_class_id" "$saved_mark_id"; then
                echo -e "${YELLOW}端口 $port 配置已删除，但 TC 清理不完整，请运行 dog --self-check${NC}"
            fi
            remove_port_traffic_state "$port" >/dev/null 2>&1 || true

            # 清理历史记录
            local history_file="$CONFIG_DIR/reset_history.log"
            if [ -f "$history_file" ]; then
                grep -v "|$port|" "$history_file" > "${history_file}.tmp" 2>/dev/null || true
                mv "${history_file}.tmp" "$history_file" 2>/dev/null || true
            fi

            local notification_log="$CONFIG_DIR/logs/notification.log"
            if [ -f "$notification_log" ]; then
                grep -v "端口 $port " "$notification_log" > "${notification_log}.tmp" 2>/dev/null || true
                mv "${notification_log}.tmp" "$notification_log" 2>/dev/null || true
            fi

            remove_port_auto_reset_cron "$port"

            echo -e "${GREEN}端口 $port 监控及相关数据删除成功${NC}"
            deleted_count=$((deleted_count + 1))
            deleted_ports+=("$port")
        done

        if [ "$deleted_count" -gt 0 ] && ! reconcile_orphaned_runtime_objects; then
            echo -e "${RED}端口配置已删除，但 nftables 遗留对象清理失败，请运行 dog --self-check${NC}"
        fi

        echo
        echo -e "${GREEN}成功删除 $deleted_count 个端口监控${NC}"

        if [ "$deleted_count" -gt 0 ]; then
            # 清理连接跟踪：确保已删除端口的现有连接不再受限制。
            echo "正在清理网络状态..."
            for port in "${deleted_ports[@]}"; do
                if is_port_range "$port"; then
                    echo "清理端口段 $port 连接状态..."
                else
                    echo "清理端口 $port 连接状态..."
                fi
                clear_port_conntrack_state "$port"
            done

            echo -e "${GREEN}网络状态已清理，现有连接的限制应该已解除${NC}"
            echo -e "${YELLOW}提示：新建连接将不受任何限制${NC}"
        fi

        local remaining_ports=($(get_active_ports))
        if [ ${#remaining_ports[@]} -eq 0 ]; then
            echo -e "${YELLOW}所有端口已删除，自动重置功能已停用${NC}"
        fi
        refresh_notification_cron_from_config
        setup_traffic_snapshot_cron
    else
        echo "取消删除"
    fi

    sleep 2
    manage_port_monitoring
}

add_nftables_rules() {
    local port="$1"
    local current_traffic=()
    read -r -a current_traffic < <(get_nftables_counter_data "$port")
    local current_input="${current_traffic[0]:-0}"
    local current_output="${current_traffic[1]:-0}"
    [[ "$current_input" =~ ^[0-9]+$ ]] || current_input=0
    [[ "$current_output" =~ ^[0-9]+$ ]] || current_output=0
    rebuild_port_counter_objects \
        "$port" "$current_input" "$current_output" rebuild
}

remove_nftables_rules() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")

    if is_port_range "$port"; then
        local port_safe=$(echo "$port" | tr '-' '_')
        local search_pattern="port_${port_safe}_"
    else
        local search_pattern="port_${port}_"
    fi

    # 使用handle删除法：逐个删除匹配的规则
    local deleted_count=0
    while true; do
        local handle=$(nft -a list table $family $table_name 2>/dev/null | \
            grep -E "(tcp|udp).*(dport|sport).*$search_pattern" | \
            head -n1 | \
            sed -n 's/.*# handle \([0-9]\+\)$/\1/p')

        if [ -z "$handle" ]; then
            break
        fi

        for chain in input output forward; do
            if nft delete rule $family $table_name $chain handle $handle 2>/dev/null; then
                deleted_count=$((deleted_count + 1))
                break
            fi
        done

        if [ $deleted_count -ge 150 ]; then
            break
        fi
    done

    # 删除计数器
    if is_port_range "$port"; then
        local port_safe=$(echo "$port" | tr '-' '_')
        nft delete counter $family $table_name "port_${port_safe}_in" 2>/dev/null || true
        nft delete counter $family $table_name "port_${port_safe}_out" 2>/dev/null || true
    else
        nft delete counter $family $table_name "port_${port}_in" 2>/dev/null || true
        nft delete counter $family $table_name "port_${port}_out" 2>/dev/null || true
    fi
}

restore_previous_tc_limit() {
    local port="$1"
    local old_enabled="$2"
    local old_rate="$3"
    if [ "$old_enabled" = "true" ] && [ "$old_rate" != "unlimited" ]; then
        local old_tc_limit
        old_tc_limit=$(convert_bandwidth_to_tc "$old_rate")
        [ -n "$old_tc_limit" ] && replace_tc_limit "$port" "$old_tc_limit" >/dev/null 2>&1
    else
        remove_tc_limit "$port" >/dev/null 2>&1
    fi
}

set_port_bandwidth_limit() {
    echo -e "${BLUE}设置端口带宽限制${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_traffic_limits
        return
    fi
    echo

    read -p "请选择要限制的端口（多端口使用逗号,分隔） [1-${#active_ports[@]}]: " choice_input

    local valid_choices=()
    local ports_to_limit=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_limit+=("$port")
    done

    if [ ${#ports_to_limit[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置限制${NC}"
        sleep 2
        set_port_bandwidth_limit
        return
    fi

    echo
    local port_list
    port_list=$(IFS=','; echo "${ports_to_limit[*]}")
    echo "为端口 $port_list 设置带宽限制（速率控制）:"
    echo "请输入限制值（0为无限制）（要带单位Kbps/Mbps/Gbps）:"
    echo "(多端口排序分别限制使用逗号,分隔)(只输入一个值，应用到所有端口):"
    read -p "带宽限制: " limit_input

    local LIMITS=()
    parse_comma_separated_input "$limit_input" LIMITS

    expand_single_value_to_array LIMITS ${#ports_to_limit[@]}
    if [ ${#LIMITS[@]} -ne ${#ports_to_limit[@]} ]; then
        echo -e "${RED}限制值数量与端口数量不匹配${NC}"
        sleep 2
        set_port_bandwidth_limit
        return
    fi

    local success_count=0
    for i in "${!ports_to_limit[@]}"; do
        local port="${ports_to_limit[$i]}"
        local limit=$(echo "${LIMITS[$i]}" | tr -d ' ')
        local old_limit_enabled
        old_limit_enabled=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.enabled // false' "$CONFIG_FILE")
        local old_rate_limit
        old_rate_limit=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.rate // "unlimited"' "$CONFIG_FILE")

        if [ "$limit" = "0" ] || [ -z "$limit" ]; then
            if ! remove_tc_limit "$port"; then
                echo -e "${RED}端口 $port 带宽限制移除失败，配置未修改${NC}"
                continue
            fi
            if ! update_config_file '
                .ports[$port].bandwidth_limit.enabled = false |
                .ports[$port].bandwidth_limit.rate = "unlimited"
            ' --arg port "$port"; then
                if ! restore_previous_tc_limit "$port" "$old_limit_enabled" "$old_rate_limit"; then
                    echo -e "${RED}端口 $port 配置写入失败且原限速恢复失败，请运行 dog --self-check${NC}"
                else
                    echo -e "${RED}端口 $port 配置写入失败，原限速已恢复${NC}"
                fi
                continue
            fi
            echo -e "${GREEN}端口 $port 带宽限制已移除${NC}"
            success_count=$((success_count + 1))
            continue
        fi

        if ! validate_bandwidth "$limit"; then
            echo -e "${RED}端口 $port 格式错误，请使用如：500Kbps, 100Mbps, 1Gbps${NC}"
            continue
        fi

        # 转换为TC格式
        local tc_limit=$(convert_bandwidth_to_tc "$limit")

        if replace_tc_limit "$port" "$tc_limit"; then
            if update_config_file '
                .ports[$port].bandwidth_limit.enabled = true |
                .ports[$port].bandwidth_limit.rate = $rate
            ' --arg port "$port" --arg rate "$limit"; then
                echo -e "${GREEN}端口 $port 带宽限制设置成功: $limit${NC}"
                success_count=$((success_count + 1))
            elif ! restore_previous_tc_limit "$port" "$old_limit_enabled" "$old_rate_limit"; then
                echo -e "${RED}端口 $port 配置写入失败且原限速恢复失败，请运行 dog --self-check${NC}"
            else
                echo -e "${RED}端口 $port 配置写入失败，原限速已恢复${NC}"
            fi
        else
            if restore_previous_tc_limit "$port" "$old_limit_enabled" "$old_rate_limit"; then
                echo -e "${RED}端口 $port 带宽限制应用失败，原限速已恢复${NC}"
            else
                echo -e "${RED}端口 $port 带宽限制应用失败且原限速恢复失败，请运行 dog --self-check${NC}"
            fi
        fi
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的带宽限制${NC}"
    sleep 3
    manage_traffic_limits
}

restore_previous_quota_limit() {
    local port="$1"
    local old_enabled="$2"
    local old_limit="$3"
    if [ "$old_enabled" = "true" ] && [ "$old_limit" != "unlimited" ]; then
        apply_nftables_quota "$port" "$old_limit" >/dev/null 2>&1
    else
        remove_nftables_quota "$port" >/dev/null 2>&1 || true
        nftables_quota_is_absent "$port"
    fi
}

set_port_quota_limit() {
    echo -e "${BLUE}=== 设置端口流量配额 ===${NC}"
    echo

    local active_ports=($(get_active_ports))
    if ! show_port_list; then
        sleep 2
        manage_traffic_limits
        return
    fi
    echo

    read -p "请选择要设置配额的端口（多端口使用逗号,分隔） [1-${#active_ports[@]}]: " choice_input

    local valid_choices=()
    local ports_to_quota=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_quota+=("$port")
    done

    if [ ${#ports_to_quota[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置配额${NC}"
        sleep 2
        set_port_quota_limit
        return
    fi

    echo
    local port_list
    port_list=$(IFS=','; echo "${ports_to_quota[*]}")
    while true; do
        echo "为端口 $port_list 设置流量配额（总量控制）:"
        echo "请输入配额值（0为无限制）（要带单位MB/GB/T）:"
        echo "(多端口分别配额使用逗号,分隔)(只输入一个值，应用到所有端口):"
        read -p "流量配额(回车默认0): " quota_input

        if [ -z "$quota_input" ]; then
            quota_input="0"
        fi

        local QUOTAS=()
        parse_comma_separated_input "$quota_input" QUOTAS

        local all_valid=true
        for quota in "${QUOTAS[@]}"; do
            if [ "$quota" != "0" ] && ! validate_quota "$quota"; then
                echo -e "${RED}配额格式错误: $quota，请使用如：100MB, 1GB, 2T${NC}"
                all_valid=false
                break
            fi
        done

        if [ "$all_valid" = false ]; then
            echo "请重新输入配额值"
            continue
        fi

        expand_single_value_to_array QUOTAS ${#ports_to_quota[@]}
        if [ ${#QUOTAS[@]} -ne ${#ports_to_quota[@]} ]; then
            echo -e "${RED}配额值数量与端口数量不匹配${NC}"
            continue
        fi

        break
    done

    local reset_policy_config=""
    local has_limited_quota=false
    for quota in "${QUOTAS[@]}"; do
        quota=$(echo "$quota" | tr -d ' ')
        if [ "$quota" != "0" ] && [ -n "$quota" ]; then
            has_limited_quota=true
            break
        fi
    done

    if [ "$has_limited_quota" = "true" ]; then
        echo
        read -p "是否同时修改自动重置策略? [y/N]: " change_reset_policy
        if [[ "$change_reset_policy" =~ ^[Yy]$ ]]; then
            prompt_reset_policy 1
            reset_policy_config="$RESET_POLICY_CONFIG"
        fi
    fi

    local success_count=0
    for i in "${!ports_to_quota[@]}"; do
        local port="${ports_to_quota[$i]}"
        local quota=$(echo "${QUOTAS[$i]}" | tr -d ' ')
        local current_monthly_limit
        current_monthly_limit=$(jq -r --arg port "$port" '.ports[$port].quota.monthly_limit // "unlimited"' "$CONFIG_FILE")
        local current_quota_enabled
        current_quota_enabled=$(jq -r --arg port "$port" '.ports[$port].quota.enabled // true' "$CONFIG_FILE")

        if [ "$quota" = "0" ] || [ -z "$quota" ]; then
            remove_nftables_quota "$port"
            if ! nftables_quota_is_absent "$port"; then
                echo -e "${RED}端口 $port 流量配额清理失败，配置未修改${NC}"
                continue
            fi
            # 设为无限额时删除自动重置策略并清除定时任务
            if ! update_config_file '
                .ports[$port].quota.enabled = true |
                .ports[$port].quota.monthly_limit = "unlimited" |
                del(.ports[$port].quota.reset_day) |
                del(.ports[$port].quota.reset_policy)
            ' --arg port "$port"; then
                if ! restore_previous_quota_limit "$port" "$current_quota_enabled" "$current_monthly_limit"; then
                    echo -e "${RED}端口 $port 配置写入失败且原配额恢复失败，请运行 dog --self-check${NC}"
                else
                    echo -e "${RED}端口 $port 配置写入失败，原配额已恢复${NC}"
                fi
                continue
            fi
            remove_port_auto_reset_cron "$port"
            echo -e "${GREEN}端口 $port 流量配额设置为无限制${NC}"
            success_count=$((success_count + 1))
            continue
        fi

        if ! apply_nftables_quota "$port" "$quota"; then
            if restore_previous_quota_limit "$port" "$current_quota_enabled" "$current_monthly_limit"; then
                echo -e "${RED}端口 $port 流量配额应用失败，原配额已恢复${NC}"
            else
                echo -e "${RED}端口 $port 流量配额应用失败且原配额恢复失败，请运行 dog --self-check${NC}"
            fi
            continue
        fi

        local was_unlimited=false
        [ "$current_monthly_limit" = "unlimited" ] && was_unlimited=true
        if ! update_config_file '
            .ports[$port].quota.enabled = true |
            .ports[$port].quota.monthly_limit = $quota |
            if $was_unlimited then .ports[$port].quota.reset_day = 1 else . end
        ' --arg port "$port" --arg quota "$quota" --argjson was_unlimited "$was_unlimited"; then
            if ! restore_previous_quota_limit "$port" "$current_quota_enabled" "$current_monthly_limit"; then
                echo -e "${RED}端口 $port 配置写入失败且原配额恢复失败，请运行 dog --self-check${NC}"
            else
                echo -e "${RED}端口 $port 配置写入失败，原配额已恢复${NC}"
            fi
            continue
        fi

        local reset_policy_ok=true
        if [ -n "$reset_policy_config" ]; then
            if ! apply_reset_policy_to_port "$port" "$reset_policy_config"; then
                reset_policy_ok=false
            fi
        fi
        setup_port_auto_reset_cron "$port"
        if [ "$reset_policy_ok" = "true" ]; then
            echo -e "${GREEN}端口 $port 流量配额设置成功: $quota${NC}"
        else
            echo -e "${YELLOW}端口 $port 配额已设置为 $quota，但自动重置策略写入失败${NC}"
        fi
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的流量配额${NC}"
    sleep 3
    manage_traffic_limits
}

manage_traffic_limits() {
    echo -e "${BLUE}=== 端口限制设置管理 ===${NC}"
    echo "1. 设置端口带宽限制（速率控制）"
    echo "2. 设置端口流量配额（总量控制）"
    echo "3. 修改端口统计方式（双向/单向）"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-3]: " choice

    case $choice in
        1) set_port_bandwidth_limit ;;
        2) set_port_quota_limit ;;
        3) change_port_billing_mode ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_traffic_limits ;;
    esac
}

# 修改端口计费模式（流量数据不丢失）
change_port_billing_mode() {
    echo -e "${BLUE}=== 修改端口统计方式 ===${NC}"
    
    local active_ports=$(jq -r '.ports | keys[]' "$CONFIG_FILE" 2>/dev/null | sort -n)
    if [ -z "$active_ports" ]; then
        echo -e "${RED}没有正在监控的端口${NC}"
        sleep 2
        manage_traffic_limits
        return
    fi
    
    echo -e "${YELLOW}当前监控的端口列表：${NC}"
    local port_list=()
    local idx=1
    for port in $active_ports; do
        local current_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
        local mode_display=$([ "$current_mode" = "double" ] && echo "双向" || echo "单向")
        echo -e "  $idx. 端口 $port - 当前模式: ${BLUE}${mode_display}${NC}"
        port_list+=("$port")
        ((idx++))
    done
    echo "  0. 返回上级菜单"
    echo
    
    read -p "请选择要修改的端口 [0-$((idx-1))]: " port_choice
    
    if [ "$port_choice" = "0" ]; then
        manage_traffic_limits
        return
    fi
    
    if ! [[ "$port_choice" =~ ^[0-9]+$ ]] || [ "$port_choice" -lt 1 ] || [ "$port_choice" -gt ${#port_list[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        sleep 1
        change_port_billing_mode
        return
    fi
    
    local target_port="${port_list[$((port_choice-1))]}"
    local current_mode=$(jq -r ".ports.\"$target_port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local current_display=$([ "$current_mode" = "double" ] && echo "双向" || echo "单向")
    local current_multiplier
    current_multiplier=$(get_billing_rule_multiplier "$current_mode")
    
    echo
    echo -e "端口 $target_port 当前统计方式: ${BLUE}$current_display${NC}"
    echo
    echo "1. 双向流量统计"
    echo "2. 单向流量统计"
    echo "0. 取消"
    echo
    read -p "请选择统计模式 [0-2]: " mode_choice
    
    local new_mode=""
    case $mode_choice in
        1) new_mode="double" ;;
        2) new_mode="single" ;;
        0|"") change_port_billing_mode; return ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; change_port_billing_mode; return ;;
    esac
    
    local new_display=$([ "$new_mode" = "double" ] && echo "双向" || echo "单向")
    local new_multiplier
    new_multiplier=$(get_billing_rule_multiplier "$new_mode")

    if [ "$new_mode" = "$current_mode" ]; then
        echo -e "${GREEN}端口 $target_port 已是 $new_display 模式，无需修改${NC}"
        sleep 1
        change_port_billing_mode
        return
    fi
    
    echo
    echo -e "${YELLOW}正在应用 $new_display 模式...${NC}"

    if ! repair_port_traffic_rules "$target_port" >/dev/null 2>&1 ||
       ! repair_port_quota_rules "$target_port" >/dev/null 2>&1; then
        echo -e "${RED}当前规则状态异常且自动修复失败，已取消模式切换${NC}"
        sleep 2
        change_port_billing_mode
        return
    fi
    
    # 读取当前流量
    local traffic_data=($(get_nftables_counter_data "$target_port"))
    local saved_input=${traffic_data[0]:-0}
    local saved_output=${traffic_data[1]:-0}
    echo -e "  读取流量: 入站=$(format_bytes $saved_input), 出站=$(format_bytes $saved_output)"
    local converted_input
    converted_input=$(scale_counter_for_rule_multiplier "$saved_input" "$current_multiplier" "$new_multiplier")
    local converted_output
    converted_output=$(scale_counter_for_rule_multiplier "$saved_output" "$current_multiplier" "$new_multiplier")
    
    local mode_change_ok=true
    if ! update_config_file \
        '.ports[$port].billing_mode = $mode' \
        --arg port "$target_port" \
        --arg mode "$new_mode"; then
        mode_change_ok=false
    fi

    if [ "$mode_change_ok" = "true" ] &&
       ! rebuild_port_counter_objects \
            "$target_port" "$converted_input" "$converted_output" rebuild; then
        mode_change_ok=false
    fi

    if [ "$mode_change_ok" != "true" ]; then
        update_config_file '.ports[$port].billing_mode = $mode' \
            --arg port "$target_port" --arg mode "$current_mode" >/dev/null 2>&1 || true
        local rollback_ok=true
        rebuild_port_counter_objects \
            "$target_port" "$saved_input" "$saved_output" rebuild \
            >/dev/null 2>&1 || rollback_ok=false
        if [ "$rollback_ok" = "true" ]; then
            echo -e "${RED}模式切换失败，已恢复原模式和流量数据${NC}"
        else
            echo -e "${RED}模式切换失败且回滚不完整，请立即运行 dog --self-check${NC}"
        fi
        sleep 2
        change_port_billing_mode
        return
    fi
    scale_current_day_traffic_stats \
        "$target_port" \
        "$current_multiplier" "$new_multiplier" \
        "$current_multiplier" "$new_multiplier" >/dev/null 2>&1 || true
    update_traffic_snapshot_baseline "$target_port" >/dev/null 2>&1 || true
    
    echo -e "${GREEN}✓ 已应用 $new_display 模式，流量数据已保留${NC}"
    sleep 2
    
    change_port_billing_mode
}

apply_nftables_quota() {
    local port="$1"
    local quota_limit="$2"
    local table_name
    local family
    local billing_mode
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    billing_mode=$(jq -r --arg port "$port" '.ports[$port].billing_mode // "double"' "$CONFIG_FILE")

    local quota_bytes
    quota_bytes=$(parse_size_to_bytes "$quota_limit" 2>/dev/null || echo 0)
    if ! [[ "$quota_bytes" =~ ^[0-9]+$ ]] || [ "$quota_bytes" -le 0 ]; then
        log_notification "端口 $port 配额值无效，已保留现有限额规则: $quota_limit"
        return 1
    fi
    if ! port_counter_objects_exist "$port"; then
        log_notification "端口 $port counter 对象缺失，已保留原有限额规则"
        return 1
    fi

    local current_traffic=()
    read -r -a current_traffic < <(get_nftables_counter_data "$port")
    local current_input="${current_traffic[0]:-0}"
    local current_output="${current_traffic[1]:-0}"
    [[ "$current_input" =~ ^[0-9]+$ ]] || current_input=0
    [[ "$current_output" =~ ^[0-9]+$ ]] || current_output=0
    local current_total
    current_total=$(calculate_total_traffic "$current_input" "$current_output" "$billing_mode")

    local quota_name
    quota_name=$(get_port_quota_name "$port")
    local rules_json
    local quota_batch
    rules_json=$(mktemp "$CONFIG_DIR/.nft-quota-rules.XXXXXX") || return 1
    quota_batch=$(mktemp "$CONFIG_DIR/.nft-quota-rebuild.XXXXXX") || {
        rm -f "$rules_json"
        return 1
    }

    if ! nft -j -a list table "$family" "$table_name" > "$rules_json" 2>/dev/null ||
       ! jq -r \
            --arg family "$family" \
            --arg table "$table_name" \
            --arg quota "$quota_name" '
            .nftables[] |
            select(.rule != null and .rule.handle != null) |
            .rule as $rule |
            [
                $rule.expr[]? | .quota? |
                if type == "string" then .
                elif type == "object" then (.name // empty)
                else empty end
            ] as $quotas |
            select(any($quotas[]; . == $quota)) |
            "delete rule \($family) \($table) \($rule.chain) handle \($rule.handle)"
        ' "$rules_json" > "$quota_batch"; then
        rm -f "$rules_json" "$quota_batch"
        return 1
    fi

    local listed_rule_count
    listed_rule_count=$(wc -l < "$quota_batch" 2>/dev/null || echo 0)
    if [ "$listed_rule_count" -ne "$(count_quota_rules "$port")" ]; then
        rm -f "$rules_json" "$quota_batch"
        return 1
    fi
    if jq -e --arg name "$quota_name" 'any(.nftables[]; .quota?.name? == $name)' \
        "$rules_json" >/dev/null 2>&1; then
        printf 'delete quota %s %s %s\n' "$family" "$table_name" "$quota_name" >> "$quota_batch"
    fi
    printf 'add quota %s %s %s { over %s bytes used %s bytes }\n' \
        "$family" "$table_name" "$quota_name" "$quota_bytes" "$current_total" >> "$quota_batch"
    local multiplier
    multiplier=$(get_billing_rule_multiplier "$billing_mode")
    write_port_quota_rule_commands \
        "$family" "$table_name" "$port" "$quota_name" "$multiplier" >> "$quota_batch"

    if ! nft -f "$quota_batch" >/dev/null 2>&1; then
        rm -f "$rules_json" "$quota_batch"
        log_notification "端口 $port 配额事务应用失败，已保留原有限额规则"
        return 1
    fi
    rm -f "$rules_json" "$quota_batch"

    local expected_rule_count
    expected_rule_count=$(get_expected_quota_rule_count "$billing_mode")
    local actual_rule_count
    actual_rule_count=$(count_quota_rules "$port")
    if ! nft list quota "$family" "$table_name" "$quota_name" >/dev/null 2>&1 ||
       [ "$actual_rule_count" -ne "$expected_rule_count" ] ||
       ! nftables_quota_limit_matches "$port" "$quota_limit"; then
        log_notification "端口 $port 配额规则创建不完整: rules=${actual_rule_count}/${expected_rule_count}"
        return 1
    fi
}

nftables_quota_is_absent() {
    local port="$1"
    local table_name
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local quota_name
    quota_name=$(get_port_quota_name "$port")

    [ "$(count_quota_rules "$port")" -eq 0 ] &&
        ! nft list quota "$family" "$table_name" "$quota_name" >/dev/null 2>&1
}

# 删除nftables配额限制 - 使用handle删除法
remove_nftables_quota() {
    local port=$1
    local table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    local family=$(jq -r '.nftables.family' "$CONFIG_FILE")

    # 检查是否为端口段
    if is_port_range "$port"; then
        local port_safe=$(echo "$port" | tr '-' '_')
        local quota_name="port_${port_safe}_quota"
    else
        local quota_name="port_${port}_quota"
    fi

    # 循环删除所有包含配额名称的规则 - 每次只获取一个handle
    local deleted_count=0
    while true; do
        # 每次只获取第一个匹配的配额规则handle
        local handle=$(nft -a list table $family $table_name 2>/dev/null | \
            grep "quota name \"$quota_name\"" | \
            head -n1 | \
            sed -n 's/.*# handle \([0-9]\+\)$/\1/p')

        if [ -z "$handle" ]; then
            break
        fi

        for chain in input output forward; do
            if nft delete rule $family $table_name $chain handle $handle 2>/dev/null; then
                deleted_count=$((deleted_count + 1))
                break
            fi
        done

        if [ $deleted_count -ge 150 ]; then
            break
        fi
    done

    if nft list quota "$family" "$table_name" "$quota_name" >/dev/null 2>&1; then
        nft delete quota "$family" "$table_name" "$quota_name" 2>/dev/null || true
    fi
}

get_tc_root_owner_file() {
    echo "$CONFIG_DIR/tc-root-qdisc.owner"
}

mark_tc_root_owned() {
    local interface="$1"
    local machine_id=""
    [ -r /etc/machine-id ] && machine_id=$(tr -d '\r\n' < /etc/machine-id)
    printf '%s|%s\n' "$interface" "$machine_id" > "$(get_tc_root_owner_file)"
    chmod 600 "$(get_tc_root_owner_file)" 2>/dev/null || true
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
    [ "$count" -eq 1 ] && grep "^${key}=" "$state_file" | cut -d'=' -f2-
}

# 返回值：0=当前接口存在有效统一限速；1=无状态；2=状态无效；3=旧版状态；4=其他接口。
trafficcop_unified_state_rate() {
    local interface="$1"
    local schema
    local provider
    local state_interface
    local speed

    [ -e "$TRAFFICCOP_TC_STATE_FILE" ] || return 1
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

adopt_legacy_tc_root_if_safe() {
    local interface="$1"
    local legacy_qdisc_line
    legacy_qdisc_line=$(tc_root_qdisc_line "$interface") || return 1
    grep -Eq '^qdisc htb 1: root([[:space:]]|$)' <<< "$legacy_qdisc_line" || return 1
    grep -Eq ' default (0x)?30([[:space:]]|$)' <<< "$legacy_qdisc_line" || return 1
    tc_root_is_managed "$interface" && return 0

    local configured_class_ids=()
    local configured_class_ports=()
    local missing_class_id_ports=()
    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    local port
    for port in "${active_ports[@]}"; do
        local limit_enabled
        local rate_limit
        local class_id
        limit_enabled=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.enabled // false' "$CONFIG_FILE")
        rate_limit=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.rate // "unlimited"' "$CONFIG_FILE")
        [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ] || continue
        class_id=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.class_id // empty' "$CONFIG_FILE")
        if ! tc_port_class_id_valid "$class_id" >/dev/null 2>&1; then
            class_id=$(generate_legacy_tc_class_id "$port")
            tc_port_class_id_valid "$class_id" >/dev/null 2>&1 || return 1
            missing_class_id_ports+=("$port")
        fi
        configured_class_ids+=("$class_id")
        configured_class_ports+=("$port")
    done
    [ ${#configured_class_ids[@]} -gt 0 ] || return 1

    local class_state
    class_state=$(tc class show dev "$interface" 2>/dev/null) || return 1
    grep -Eq '^class htb 1:1 root([[:space:]]|$)' <<< "$class_state" || return 1
    local actual_class_ids=()
    mapfile -t actual_class_ids < <(printf '%s\n' "$class_state" |
        awk '$1 == "class" && $2 == "htb" {print $3}')
    local actual_class_id
    for actual_class_id in "${actual_class_ids[@]}"; do
        if [ "$actual_class_id" = "1:1" ] || [ "$actual_class_id" = "1:30" ]; then
            continue
        fi
        [[ " ${configured_class_ids[*]} " == *" $actual_class_id "* ]] || return 1
    done

    local filter_state
    filter_state=$(tc filter show dev "$interface" parent 1:0 2>/dev/null) || return 1
    local configured_class_id
    for configured_class_id in "${configured_class_ids[@]}"; do
        [[ " ${actual_class_ids[*]} " == *" $configured_class_id "* ]] || return 1
        grep -Eq "(flowid|classid)[[:space:]]+$configured_class_id([[:space:]]|$)" <<< "$filter_state" || return 1
    done
    local filter_class_ids=()
    mapfile -t filter_class_ids < <(printf '%s\n' "$filter_state" |
        grep -Eo '(flowid|classid)[[:space:]]+1:[0-9a-fA-F]+' |
        awk '{print $2}' | sort -u)
    for actual_class_id in "${filter_class_ids[@]}"; do
        [[ " ${configured_class_ids[*]} " == *" $actual_class_id "* ]] || return 1
    done

    mark_tc_root_owned "$interface" || return 1
    local missing_port
    for missing_port in "${missing_class_id_ports[@]}"; do
        local index
        for index in "${!configured_class_ports[@]}"; do
            [ "${configured_class_ports[$index]}" = "$missing_port" ] || continue
            if ! save_tc_class_id "$missing_port" "${configured_class_ids[$index]}"; then
                rm -f "$(get_tc_root_owner_file)"
                return 1
            fi
            break
        done
    done
}

tc_root_qdisc_is_replaceable() {
    local qdisc_state="$1"
    local qdisc_type
    qdisc_type=$(printf '%s\n' "$qdisc_state" | awk 'NR == 1 {print $2}')
    case "$qdisc_type" in
        ""|noqueue|fq_codel|pfifo_fast|mq|fq) return 0 ;;
        *) return 1 ;;
    esac
}

ENSURE_TC_ROOT_CREATED=false
ENSURE_TC_ROOT_MIGRATED=false

desired_tc_parent_rate() {
    local interface="$1"
    local rate
    local result=0
    rate=$(trafficcop_unified_state_rate "$interface" 2>/dev/null) || result=$?
    case "$result" in
        0) printf '%s\n' "$rate" ;;
        1|4) printf '%s\n' "$TC_PARENT_RATE" ;;
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
    qdisc_state=$(tc qdisc show dev "$interface" 2>/dev/null || true)
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
        if ! tc_root_is_managed "$interface" && ! adopt_legacy_tc_root_if_safe "$interface"; then
            tc_root_owner_marker_matches "$interface" && rm -f "$(get_tc_root_owner_file)"
            log_notification "检测到不属于Dog/TrafficCop统一协议的HTB根队列，已拒绝接管: $interface"
            return 1
        fi
        read -r previous_parent_rate previous_parent_ceil < <(
            tc_class_rate_and_ceil "$interface" "1:1"
        ) || true
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
    local result=0
    begin_tc_update || return 1
    ensure_owned_tc_hierarchy_locked "$@" || result=$?
    finish_tc_update
    return "$result"
}

cleanup_owned_tc_root_if_unused_locked() {
    local interface="${1:-$(get_default_interface)}"
    [ -n "$interface" ] && tc_root_is_owned "$interface" || return 0

    # 1:1 与 1:30 是统一层级的基础分类；其他分类或过滤器表示端口限速仍在使用。
    local class_output
    local filter_output
    class_output=$(tc class show dev "$interface" 2>/dev/null) || return 0
    if printf '%s\n' "$class_output" |
       awk '$1 == "class" && $2 == "htb" && $3 != "1:1" && $3 != "1:30" { found=1 } END { exit found ? 0 : 1 }'; then
        return 0
    fi
    filter_output=$(tc filter show dev "$interface" parent 1:0 2>/dev/null) || return 0
    if [ -n "$filter_output" ]; then
        return 0
    fi

    local ntc_status=0
    trafficcop_unified_state_rate "$interface" >/dev/null 2>&1 || ntc_status=$?
    if [ "$ntc_status" -eq 0 ]; then
        rm -f "$(get_tc_root_owner_file)"
        return 0
    fi
    if [ -e "$TRAFFICCOP_TC_STATE_FILE" ] && [ "$ntc_status" -ne 1 ] && [ "$ntc_status" -ne 4 ]; then
        # NTC 状态存在但无法安全解释时宁可保留基础层级，也不删除其全局限速。
        return 1
    fi

    if tc qdisc del dev "$interface" root handle 1: 2>/dev/null; then
        rm -f "$(get_tc_root_owner_file)"
    fi
}

cleanup_owned_tc_root_if_unused() {
    local result=0
    begin_tc_update || return 1
    cleanup_owned_tc_root_if_unused_locked "$@" || result=$?
    finish_tc_update
    return "$result"
}

get_tc_ipv6_filter_handle() {
    local port="$1"
    local offset="$2"
    printf '0x%x\n' $((port * 4 + offset))
}

apply_tc_limit_locked() {
    local port=$1
    local total_limit=$2
    local interface=$(get_default_interface)

    if [ -z "$interface" ]; then
        log_notification "端口 $port 无法确定默认网卡，已跳过带宽限制"
        return 1
    fi

    ensure_owned_tc_hierarchy_locked "$interface" || return 1
    local created_root="$ENSURE_TC_ROOT_CREATED"
    local class_state

    local class_id
    if ! class_id=$(generate_tc_class_id "$port"); then
        [ "$created_root" = "true" ] && cleanup_owned_tc_root_if_unused_locked "$interface"
        log_notification "端口 $port 无法分配TC class ID，已跳过带宽限制"
        return 1
    fi
    local legacy_class_id
    legacy_class_id=$(generate_legacy_tc_class_id "$port")
    # 计算burst参数以优化性能
    local base_rate=$(parse_tc_rate_to_kbps "$total_limit")
    local burst_bytes=$(calculate_tc_burst "$base_rate")
    local burst_size=$(format_tc_burst "$burst_bytes")

    if ! tc class replace dev "$interface" parent 1:1 classid "$class_id" htb \
        rate "$TC_PORT_CLASS_RATE" ceil "$total_limit" burst "$burst_size" 2>/dev/null; then
        [ "$created_root" = "true" ] && cleanup_owned_tc_root_if_unused_locked "$interface"
        log_notification "端口 $port 无法创建TC限速分类: $class_id"
        return 1
    fi

    if is_port_range "$port"; then
        # 端口段：使用fw分类器根据标记分类
        local mark_id
        if ! mark_id=$(get_or_create_port_range_mark "$port" "$class_id") ||
           ! add_port_range_mark_rules "$port" "$mark_id"; then
            tc class del dev "$interface" classid "$class_id" 2>/dev/null || true
            remove_port_range_mark_rules "$port" >/dev/null 2>&1 || true
            log_notification "端口段 $port 无法创建唯一标记规则"
            return 1
        fi
        local mark_handle
        mark_handle=$(printf '0x%x/0x%x' "$mark_id" "$TC_MARK_MASK")
        if ! tc filter add dev "$interface" protocol all parent 1:0 prio 1 \
            handle "$mark_handle" fw flowid "$class_id" 2>/dev/null; then
            tc class del dev "$interface" classid "$class_id" 2>/dev/null || true
            remove_port_range_mark_rules "$port" >/dev/null 2>&1 || true
            log_notification "端口段 $port 无法创建TC过滤器"
            return 1
        fi

    else
        # 单端口：使用u32精确匹配，避免优先级冲突
        local filter_prio=$((port % 1000 + 1))

        # TCP协议过滤器
        if ! tc filter add dev "$interface" protocol ip parent 1:0 prio "$filter_prio" u32 \
            match ip protocol 6 0xff match ip sport "$port" 0xffff flowid "$class_id" 2>/dev/null ||
           ! tc filter add dev "$interface" protocol ip parent 1:0 prio "$filter_prio" u32 \
            match ip protocol 6 0xff match ip dport "$port" 0xffff flowid "$class_id" 2>/dev/null ||
           ! tc filter add dev "$interface" protocol ip parent 1:0 prio "$((filter_prio + 1000))" u32 \
            match ip protocol 17 0xff match ip sport "$port" 0xffff flowid "$class_id" 2>/dev/null ||
           ! tc filter add dev "$interface" protocol ip parent 1:0 prio "$((filter_prio + 1000))" u32 \
            match ip protocol 17 0xff match ip dport "$port" 0xffff flowid "$class_id" 2>/dev/null; then
            remove_tc_limit_locked "$port" >/dev/null 2>&1 || true
            log_notification "端口 $port 无法创建完整TC过滤器"
            return 1
        fi

        local ipv6_tcp_sport_handle
        local ipv6_tcp_dport_handle
        local ipv6_udp_sport_handle
        local ipv6_udp_dport_handle
        ipv6_tcp_sport_handle=$(get_tc_ipv6_filter_handle "$port" 0)
        ipv6_tcp_dport_handle=$(get_tc_ipv6_filter_handle "$port" 1)
        ipv6_udp_sport_handle=$(get_tc_ipv6_filter_handle "$port" 2)
        ipv6_udp_dport_handle=$(get_tc_ipv6_filter_handle "$port" 3)
        if ! tc filter add dev "$interface" protocol ipv6 parent 1:0 prio 2 \
            handle "$ipv6_tcp_sport_handle" flower ip_proto tcp src_port "$port" flowid "$class_id" 2>/dev/null ||
           ! tc filter add dev "$interface" protocol ipv6 parent 1:0 prio 2 \
            handle "$ipv6_tcp_dport_handle" flower ip_proto tcp dst_port "$port" flowid "$class_id" 2>/dev/null ||
           ! tc filter add dev "$interface" protocol ipv6 parent 1:0 prio 2 \
            handle "$ipv6_udp_sport_handle" flower ip_proto udp src_port "$port" flowid "$class_id" 2>/dev/null ||
           ! tc filter add dev "$interface" protocol ipv6 parent 1:0 prio 2 \
            handle "$ipv6_udp_dport_handle" flower ip_proto udp dst_port "$port" flowid "$class_id" 2>/dev/null; then
            remove_tc_limit_locked "$port" >/dev/null 2>&1 || true
            log_notification "端口 $port 无法创建完整IPv6 TC过滤器"
            return 1
        fi
    fi

    class_state=$(tc class show dev "$interface" 2>/dev/null || true)
    grep -Fq "class htb $class_id " <<< "$class_state" || return 1
    if [ "$legacy_class_id" != "$class_id" ]; then
        tc class del dev "$interface" classid "$legacy_class_id" 2>/dev/null || true
    fi
    if is_port_range "$port"; then
        local comment
        comment=$(get_port_range_mark_comment "$port")
        [ "$(nft -a list table "$(jq -r '.nftables.family' "$CONFIG_FILE")" \
            "$(jq -r '.nftables.table_name' "$CONFIG_FILE")" 2>/dev/null | grep -Fc "comment \"$comment\"")" -eq 6 ]
    fi
}

apply_tc_limit() {
    local result=0
    local interface
    interface=$(get_default_interface 2>/dev/null || true)
    begin_tc_update || return 1
    apply_tc_limit_locked "$@" || result=$?
    if [ "$result" -ne 0 ] && [ -n "$interface" ]; then
        rollback_legacy_trafficcop_tbf "$interface" >/dev/null 2>&1 || true
    fi
    finish_tc_update
    return "$result"
}

replace_tc_limit() {
    local port="$1"
    local total_limit="$2"
    local result=0
    local interface
    interface=$(get_default_interface 2>/dev/null || true)
    begin_tc_update || return 1
    remove_tc_limit_locked "$port" >/dev/null 2>&1 || result=$?
    if [ "$result" -eq 0 ]; then
        apply_tc_limit_locked "$port" "$total_limit" || result=$?
    fi
    if [ "$result" -ne 0 ] && [ -n "$interface" ]; then
        rollback_legacy_trafficcop_tbf "$interface" >/dev/null 2>&1 || true
    fi
    finish_tc_update
    return "$result"
}

# 删除TC带宽限制
remove_tc_limit_locked() {
    local port=$1
    local interface=$(get_default_interface)
    local class_id="${2:-}"
    local supplied_mark_id="${3:-}"

    [ -n "$interface" ] || return 1
    local qdisc_state
    qdisc_state=$(tc qdisc show dev "$interface" 2>/dev/null || true)
    if grep -Eq '^qdisc htb 1:' <<< "$qdisc_state" &&
       ! tc_root_is_managed "$interface" &&
       ! adopt_legacy_tc_root_if_safe "$interface"; then
        log_notification "端口 $port 检测到不属于Dog/TrafficCop统一协议的HTB，已拒绝删除TC对象: $interface"
        return 1
    fi

    if [ -z "$class_id" ]; then
        class_id=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.class_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
    fi
    tc_port_class_id_valid "$class_id" >/dev/null 2>&1 || class_id=""
    local legacy_class_id
    legacy_class_id=$(generate_legacy_tc_class_id "$port")

    if is_port_range "$port"; then
        # 端口段：删除基于标记的过滤器
        local mark_id
        mark_id="$supplied_mark_id"
        if [ -z "$mark_id" ]; then
            mark_id=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.mark_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
        fi
        local legacy_mark_id
        legacy_mark_id=$(generate_port_range_mark "$port")
        [ -n "$mark_id" ] || mark_id="$legacy_mark_id"
        local mark_hex=$(printf '0x%x' "$mark_id")

        local mark_handle
        mark_handle=$(printf '0x%x/0x%x' "$mark_id" "$TC_MARK_MASK")
        tc filter del dev "$interface" protocol all parent 1:0 prio 1 handle "$mark_handle" fw 2>/dev/null || true
        # 十六进制handle删除
        tc filter del dev $interface protocol all parent 1:0 prio 1 handle $mark_hex fw 2>/dev/null || true
        tc filter del dev $interface protocol all parent 1:0 prio 1 handle $mark_id fw 2>/dev/null || true
        tc filter del dev $interface protocol ip parent 1:0 prio 1 handle $mark_hex fw 2>/dev/null || true
        # 备选：十进制handle删除
        tc filter del dev $interface protocol ip parent 1:0 prio 1 handle $mark_id fw 2>/dev/null || true
        if [ "$legacy_mark_id" != "$mark_id" ]; then
            local legacy_mark_hex
            legacy_mark_hex=$(printf '0x%x' "$legacy_mark_id")
            tc filter del dev "$interface" protocol all parent 1:0 prio 1 handle "$legacy_mark_hex" fw 2>/dev/null || true
            tc filter del dev "$interface" protocol all parent 1:0 prio 1 handle "$legacy_mark_id" fw 2>/dev/null || true
            tc filter del dev "$interface" protocol ip parent 1:0 prio 1 handle "$legacy_mark_hex" fw 2>/dev/null || true
            tc filter del dev "$interface" protocol ip parent 1:0 prio 1 handle "$legacy_mark_id" fw 2>/dev/null || true
        fi
        remove_port_range_mark_rules "$port" >/dev/null 2>&1 || true
        update_config_file 'del(.ports[$port].bandwidth_limit.mark_id)' --arg port "$port" >/dev/null 2>&1 || true
    else
        # 单端口：删除u32精确匹配过滤器
        local filter_prio=$((port % 1000 + 1))

        tc filter del dev $interface protocol ip parent 1:0 prio $filter_prio u32 \
            match ip protocol 6 0xff match ip sport $port 0xffff 2>/dev/null || true
        tc filter del dev $interface protocol ip parent 1:0 prio $filter_prio u32 \
            match ip protocol 6 0xff match ip dport $port 0xffff 2>/dev/null || true

        tc filter del dev $interface protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
            match ip protocol 17 0xff match ip sport $port 0xffff 2>/dev/null || true
        tc filter del dev $interface protocol ip parent 1:0 prio $((filter_prio + 1000)) u32 \
            match ip protocol 17 0xff match ip dport $port 0xffff 2>/dev/null || true

        local ipv6_offset
        for ipv6_offset in 0 1 2 3; do
            tc filter del dev "$interface" protocol ipv6 parent 1:0 prio 2 \
                handle "$(get_tc_ipv6_filter_handle "$port" "$ipv6_offset")" flower 2>/dev/null || true
        done
    fi

    if [ -n "$class_id" ]; then
        tc class del dev $interface classid $class_id 2>/dev/null || true
    fi
    if [ "$legacy_class_id" != "$class_id" ]; then
        tc class del dev $interface classid $legacy_class_id 2>/dev/null || true
    fi
    cleanup_owned_tc_root_if_unused_locked "$interface"

    local cleanup_ok=true
    if [ -n "$class_id" ] && tc_class_id_exists "$class_id"; then
        cleanup_ok=false
    fi
    if [ -n "$class_id" ] && tc filter show dev "$interface" parent 1:0 2>/dev/null |
        grep -Eq "(flowid|classid)[[:space:]]+$class_id([[:space:]]|$)"; then
        cleanup_ok=false
    fi
    if is_port_range "$port"; then
        local remaining_comment
        remaining_comment=$(get_port_range_mark_comment "$port")
        if nft -a list table "$(jq -r '.nftables.family' "$CONFIG_FILE")" \
            "$(jq -r '.nftables.table_name' "$CONFIG_FILE")" 2>/dev/null |
            grep -Fq "comment \"$remaining_comment\""; then
            cleanup_ok=false
        fi
    fi
    [ "$cleanup_ok" = "true" ]
}

remove_tc_limit() {
    local result=0
    begin_tc_update || return 1
    remove_tc_limit_locked "$@" || result=$?
    finish_tc_update
    return "$result"
}

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

tc_single_port_filters_complete() {
    local interface="$1"
    local port="$2"
    local class_id="$3"
    local filter_prio=$((port % 1000 + 1))
    local sport_hex
    local dport_hex
    sport_hex=$(printf '%x' "$((port << 16))")
    dport_hex=$(printf '%x' "$port")

    local filter_json
    filter_json=$(tc -j filter show dev "$interface" parent 1:0 2>/dev/null) || return 1
    jq -e \
        --arg class_id "$class_id" \
        --arg sport_hex "$sport_hex" \
        --arg dport_hex "$dport_hex" \
        --argjson port "$port" \
        --argjson tcp_pref "$filter_prio" \
        --argjson udp_pref "$((filter_prio + 1000))" '
        def normhex:
            tostring | ascii_downcase | sub("^0x"; "") | sub("^0+"; "") |
            if . == "" then "0" else . end;
        def u32_count($pref; $value; $mask):
            [.[] | select(
                .protocol == "ip" and .kind == "u32" and .pref == $pref and
                .options.flowid == $class_id and
                ((.options.match.value // "") | normhex) == ($value | normhex) and
                ((.options.match.mask // "") | normhex) == ($mask | normhex) and
                (.options.match.off // -1) == 20
            )] | length;
        def flower_count($proto; $key):
            [.[] | select(
                .protocol == "ipv6" and .kind == "flower" and
                .options.classid == $class_id and
                .options.keys.ip_proto == $proto and
                .options.keys[$key] == $port
            )] | length;
        u32_count($tcp_pref; $sport_hex; "ffff0000") == 1 and
        u32_count($tcp_pref; $dport_hex; "ffff") == 1 and
        u32_count($udp_pref; $sport_hex; "ffff0000") == 1 and
        u32_count($udp_pref; $dport_hex; "ffff") == 1 and
        flower_count("tcp"; "src_port") == 1 and
        flower_count("tcp"; "dst_port") == 1 and
        flower_count("udp"; "src_port") == 1 and
        flower_count("udp"; "dst_port") == 1
    ' <<< "$filter_json" >/dev/null
}

tc_port_range_filter_complete() {
    local interface="$1"
    local class_id="$2"
    local mark_id="$3"
    local mark_handle
    mark_handle=$(printf '0x%x/0x%x' "$mark_id" "$TC_MARK_MASK")
    local filter_state
    filter_state=$(tc filter show dev "$interface" parent 1:0 2>/dev/null) || return 1
    [ "$(printf '%s\n' "$filter_state" |
        grep -F "handle $mark_handle" |
        grep -Fc "classid $class_id")" -eq 1 ]
}

tc_limit_runtime_rules_complete() {
    local port="$1"
    local interface
    local class_id
    interface=$(get_default_interface)
    class_id=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.class_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
    [ -n "$interface" ] && tc_port_class_id_valid "$class_id" >/dev/null 2>&1 || return 1
    local expected_parent_rate
    expected_parent_rate=$(desired_tc_parent_rate "$interface") || return 1
    tc_class_rate_matches "$interface" "1:1" "$expected_parent_rate" || return 1
    tc_class_rate_matches "$interface" "1:30" "$TC_DEFAULT_CLASS_RATE" "$expected_parent_rate" || return 1

    local rate_limit
    local expected_rate
    rate_limit=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.rate // "unlimited"' "$CONFIG_FILE")
    expected_rate=$(convert_bandwidth_to_tc "$rate_limit")
    [ -n "$expected_rate" ] || return 1
    tc_class_rate_matches "$interface" "$class_id" "$TC_PORT_CLASS_RATE" "$expected_rate" || return 1

    if is_port_range "$port"; then
        local mark_id
        local minor
        local expected_mark
        mark_id=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.mark_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
        minor=$(tc_class_id_minor "$class_id") || return 1
        expected_mark=$((0x50000000 | (minor << 12)))
        [[ "$mark_id" =~ ^[0-9]+$ ]] && [ "$mark_id" -eq "$expected_mark" ] || return 1
        tc_port_range_filter_complete "$interface" "$class_id" "$mark_id" || return 1

        port_range_mark_rules_complete "$port" "$mark_id" || return 1
    else
        tc_single_port_filters_complete "$interface" "$port" "$class_id" || return 1
    fi
}

tc_limit_runtime_complete() {
    local port="$1"
    local interface
    interface=$(get_default_interface)
    [ -n "$interface" ] && tc_root_is_owned "$interface" || return 1
    tc_limit_runtime_rules_complete "$port"
}

# 返回值：0=存在且完整；1=存在但失效/状态不可解释；2=当前不需要 TC。
dog_tc_runtime_complete_all() {
    local interface="$1"
    local expected=false
    local ntc_rate=""
    local ntc_status=0

    ntc_rate=$(trafficcop_unified_state_rate "$interface" 2>/dev/null) || ntc_status=$?
    case "$ntc_status" in
        0)
            expected=true
            tc_root_is_managed "$interface" || return 1
            tc_class_rate_matches "$interface" "1:1" "$ntc_rate" "$ntc_rate" || return 1
            tc_class_rate_matches "$interface" "1:30" "$TC_DEFAULT_CLASS_RATE" "$ntc_rate" || return 1
            ;;
        1|4) ;;
        *)
            [ -e "$TRAFFICCOP_TC_STATE_FILE" ] && return 1
            ;;
    esac

    local active_ports=()
    local port
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    for port in "${active_ports[@]}"; do
        local limit_enabled
        local rate_limit
        limit_enabled=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.enabled // false' "$CONFIG_FILE")
        rate_limit=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.rate // "unlimited"' "$CONFIG_FILE")
        [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ] || continue
        expected=true
        tc_limit_runtime_complete "$port" || return 1
    done

    [ "$expected" = "true" ] && return 0
    return 2
}

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
    dog_tc_runtime_complete_all "$interface" || runtime_status=$?
    qdisc_state=$(tc qdisc show dev "$interface" 2>/dev/null || true)

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

    validate_config_file "$CONFIG_FILE" >/dev/null || {
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
       [ "$ntc_status" -ne 0 ] && [ "$ntc_status" -ne 1 ] && [ "$ntc_status" -ne 4 ]; then
        finish_tc_update
        echo "TrafficCop TC 状态文件无法安全解释，拒绝自动删除 qdisc。" >&2
        return 1
    fi
    if [ "$mode" = "--auto" ] && [ "$runtime_status" -eq 2 ]; then
        finish_tc_update
        echo "当前没有需要自动恢复的 Dog/NTC TC 规则。"
        return 0
    fi

    local qdisc_state
    qdisc_state=$(tc qdisc show dev "$interface" 2>/dev/null || true)
    if [ "$runtime_status" -eq 2 ] && tc_root_qdisc_is_replaceable "$qdisc_state"; then
        finish_tc_update
        echo "当前 TC 为空闲状态，无需处理。"
        return 0
    fi

    local tc_ports=()
    local tc_limits=()
    local active_ports=()
    local port
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    for port in "${active_ports[@]}"; do
        local limit_enabled
        local rate_limit
        local tc_limit
        limit_enabled=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.enabled // false' "$CONFIG_FILE")
        rate_limit=$(jq -r --arg port "$port" '.ports[$port].bandwidth_limit.rate // "unlimited"' "$CONFIG_FILE")
        [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ] || continue
        tc_limit=$(convert_bandwidth_to_tc "$rate_limit")
        [ -n "$tc_limit" ] || {
            finish_tc_update
            echo "端口 $port 的带宽配置无效，未删除当前 qdisc。" >&2
            return 1
        }
        tc_ports+=("$port")
        tc_limits+=("$tc_limit")
    done

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
            if ! apply_tc_limit_locked "${tc_ports[$tc_index]}" "${tc_limits[$tc_index]}"; then
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

manage_traffic_reset() {
    echo -e "${BLUE}流量重置管理${NC}"
    echo "1. 自动重置策略设置"
    echo "2. 立即重置"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-2]: " choice

    case $choice in
        1) set_reset_day ;;
        2) immediate_reset ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择，请输入0-2${NC}"; sleep 1; manage_traffic_reset ;;
    esac
}

set_reset_day() {
    echo -e "${BLUE}=== 自动重置策略设置 ===${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_traffic_reset
        return
    fi
    echo

    read -p "请选择要设置重置日期的端口（多端口使用逗号,分隔） [1-${#active_ports[@]}]: " choice_input

    local valid_choices=()
    local ports_to_set=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_set+=("$port")
    done

    if [ ${#ports_to_set[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可设置${NC}"
        sleep 2
        set_reset_day
        return
    fi

    echo
    local port_list
    port_list=$(IFS=','; echo "${ports_to_set[*]}")
    echo "为端口 $port_list 设置自动重置策略:"
    local reset_policy_config=""
    local RESET_POLICY_CONFIGS=()
    local separate_policy="false"

    if [ ${#ports_to_set[@]} -gt 1 ]; then
        read -p "是否为每个端口分别设置策略? [y/N]: " separate_choice
        if [[ "$separate_choice" =~ ^[Yy]$ ]]; then
            separate_policy="true"
        fi
    fi

    if [ "$separate_policy" = "true" ]; then
        for port in "${ports_to_set[@]}"; do
            echo
            echo "设置端口 $port 的自动重置策略:"
            prompt_reset_policy 1
            RESET_POLICY_CONFIGS+=("$RESET_POLICY_CONFIG")
        done
    else
        prompt_reset_policy 1
        reset_policy_config="$RESET_POLICY_CONFIG"
    fi

    local success_count=0
    for i in "${!ports_to_set[@]}"; do
        local port="${ports_to_set[$i]}"
        local current_policy_config="$reset_policy_config"
        if [ "$separate_policy" = "true" ]; then
            current_policy_config="${RESET_POLICY_CONFIGS[$i]}"
        fi
        local policy_type
        policy_type=$(printf '%s' "$current_policy_config" | jq -r '.type')

        if [ "$policy_type" = "none" ]; then
            if ! update_config_file '
                del(.ports[$port].quota.reset_day) |
                del(.ports[$port].quota.reset_policy)
            ' --arg port "$port"; then
                echo -e "${RED}端口 $port 自动重置配置写入失败，原配置已保留${NC}"
                continue
            fi
            remove_port_auto_reset_cron "$port"
            echo -e "${GREEN}端口 $port 已取消自动重置${NC}"
        else
            # 无流量配额的端口不需要自动重置
            local monthly_limit=$(get_quota_limit "$port")
            if [ "$monthly_limit" = "unlimited" ]; then
                echo -e "${YELLOW}端口 $port 未设置流量配额，请先通过「端口限制设置管理→设置端口流量配额」设置配额后再设置自动重置策略${NC}"
                continue
            fi
            if ! apply_reset_policy_to_port "$port" "$current_policy_config"; then
                echo -e "${RED}端口 $port 自动重置策略写入失败，原配置已保留${NC}"
                continue
            fi
            setup_port_auto_reset_cron "$port"
            local next_reset_label
            next_reset_label=$(get_port_next_reset_label "$port" 2>/dev/null || true)
            echo -e "${GREEN}端口 $port 自动重置策略设置成功${NC}${next_reset_label:+: $next_reset_label}"
        fi
        
        success_count=$((success_count + 1))
    done

    echo
    echo -e "${GREEN}成功设置 $success_count 个端口的自动重置策略${NC}"

    sleep 2
    manage_traffic_reset
}

immediate_reset() {
    echo -e "${BLUE}=== 立即重置 ===${NC}"
    echo

    local active_ports=($(get_active_ports))

    if ! show_port_list; then
        sleep 2
        manage_traffic_reset
        return
    fi
    echo

    read -p "请选择要立即重置的端口（多端口使用逗号,分隔） [1-${#active_ports[@]}]: " choice_input

    # 处理多选择输入
    local valid_choices=()
    local ports_to_reset=()
    parse_multi_choice_input "$choice_input" "${#active_ports[@]}" valid_choices

    for choice in "${valid_choices[@]}"; do
        local port=${active_ports[$((choice-1))]}
        ports_to_reset+=("$port")
    done

    if [ ${#ports_to_reset[@]} -eq 0 ]; then
        echo -e "${RED}没有有效的端口可重置${NC}"
        sleep 2
        immediate_reset
        return
    fi

    record_traffic_snapshot >/dev/null 2>&1 || true

    # 显示要重置的端口及其当前流量
    echo
    echo "将重置以下端口的流量统计:"
    local total_all_traffic=0
    for port in "${ports_to_reset[@]}"; do
        local traffic_data=($(get_nftables_counter_data "$port"))
        local input_bytes=${traffic_data[0]}
        local output_bytes=${traffic_data[1]}
        local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")
        local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")
        local total_formatted=$(format_bytes $total_bytes)

        echo "  端口 $port: $total_formatted"
        total_all_traffic=$((total_all_traffic + total_bytes))
    done

    echo
    echo "总计流量: $(format_bytes $total_all_traffic)"
    echo -e "${YELLOW}警告：重置后流量统计将清零，此操作不可撤销！${NC}"
    read -p "确认重置选定端口的流量统计? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if ! acquire_reset_lock; then
            echo -e "${RED}流量重置任务正在运行，请稍后重试${NC}"
            sleep 2
            manage_traffic_reset
            return
        fi

        local reset_count=0
        local failed_count=0
        for port in "${ports_to_reset[@]}"; do
            # 获取当前流量用于记录
            record_traffic_snapshot >/dev/null 2>&1 || true
            local traffic_data=($(get_nftables_counter_data "$port"))
            local input_bytes=${traffic_data[0]}
            local output_bytes=${traffic_data[1]}
            local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"single\"" "$CONFIG_FILE")
            local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")

            if reset_port_nftables_counters "$port"; then
                record_reset_history "$port" "$total_bytes"
                echo -e "${GREEN}端口 $port 流量统计重置成功${NC}"
                reset_count=$((reset_count + 1))
            else
                echo -e "${RED}端口 $port 流量统计重置失败，原重置策略未改变${NC}"
                failed_count=$((failed_count + 1))
            fi
        done
        release_reset_lock

        echo
        echo -e "${GREEN}成功重置 $reset_count 个端口的流量统计${NC}"
        if [ "$failed_count" -gt 0 ]; then
            echo -e "${RED}失败 $failed_count 个端口，请运行 dog --self-check 检查规则${NC}"
        fi
        echo "重置前总流量: $(format_bytes $total_all_traffic)"
    else
        echo "取消重置"
    fi

    sleep 3
    manage_traffic_reset
}

# 在已持有重置锁时重置指定端口。
perform_auto_reset_port() {
    local port="$1"
    local due_date="${2:-}"

    record_traffic_snapshot >/dev/null 2>&1 || true
    local traffic_data=($(get_nftables_counter_data "$port"))
    local input_bytes=${traffic_data[0]}
    local output_bytes=${traffic_data[1]}
    local billing_mode=$(jq -r ".ports.\"$port\".billing_mode // \"double\"" "$CONFIG_FILE")
    local total_bytes=$(calculate_total_traffic "$input_bytes" "$output_bytes" "$billing_mode")

    if ! reset_port_nftables_counters "$port"; then
        log_notification "端口 $port 自动重置失败，counter/quota 未全部清零，将保留到期日期等待重试"
        return 1
    fi
    if ! record_reset_history "$port" "$total_bytes" "$due_date"; then
        log_notification "端口 $port 自动重置已完成，但写入重置历史失败"
    fi

    log_notification "端口 $port 自动重置完成，重置前流量: $(format_bytes $total_bytes)"

    echo "端口 $port 自动重置完成"
}

# 自动重置指定端口的流量
auto_reset_port() {
    local port="$1"
    if ! acquire_reset_lock; then
        log_notification "端口 $port 自动重置跳过：已有重置任务正在运行"
        return 1
    fi

    local result=0
    perform_auto_reset_port "$port" || result=$?
    release_reset_lock
    return "$result"
}

check_reset_port_due() {
    local port="$1"
    port_has_auto_reset_policy "$port" || return 0

    if ! acquire_reset_lock; then
        log_notification "端口 $port 到期检查跳过：已有重置任务正在运行"
        return 1
    fi

    local today
    today=$(get_current_date)
    local next_reset_date
    next_reset_date=$(ensure_port_next_reset_date "$port" 2>/dev/null || true)

    if [ -z "$next_reset_date" ] || ! is_valid_date "$next_reset_date"; then
        release_reset_lock
        return 0
    fi

    local result=0
    if date_le "$next_reset_date" "$today"; then
        if reset_history_has_due "$port" "$next_reset_date"; then
            # 上次已清零但配置日期推进失败时，只补推进日期，禁止重复清零。
            advance_port_next_reset_date "$port" "$today" || result=$?
        elif perform_auto_reset_port "$port" "$next_reset_date"; then
            advance_port_next_reset_date "$port" "$today" || result=$?
        else
            result=$?
        fi
    fi
    release_reset_lock
    return "$result"
}

check_scheduled_resets() {
    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    local failed=false
    local port
    for port in "${active_ports[@]}"; do
        check_reset_port_due "$port" >/dev/null 2>&1 || failed=true
    done
    [ "$failed" = "false" ]
}

write_port_counter_rule_commands() {
    local family="$1"
    local table_name="$2"
    local port="$3"
    local input_counter="$4"
    local output_counter="$5"
    local multiplier="$6"
    local copy
    local protocol
    for ((copy=0; copy<multiplier; copy++)); do
        for protocol in tcp udp; do
            printf 'insert rule %s %s input %s dport %s counter name "%s"\n' \
                "$family" "$table_name" "$protocol" "$port" "$input_counter"
            printf 'insert rule %s %s forward %s dport %s counter name "%s"\n' \
                "$family" "$table_name" "$protocol" "$port" "$input_counter"
            printf 'insert rule %s %s output %s sport %s counter name "%s"\n' \
                "$family" "$table_name" "$protocol" "$port" "$output_counter"
            printf 'insert rule %s %s forward %s sport %s counter name "%s"\n' \
                "$family" "$table_name" "$protocol" "$port" "$output_counter"
        done
    done
}

write_port_quota_rule_commands() {
    local family="$1"
    local table_name="$2"
    local port="$3"
    local quota_name="$4"
    local multiplier="$5"
    local copy
    local protocol
    for ((copy=0; copy<multiplier; copy++)); do
        for protocol in tcp udp; do
            printf 'insert rule %s %s input %s dport %s quota name "%s" drop\n' \
                "$family" "$table_name" "$protocol" "$port" "$quota_name"
            printf 'insert rule %s %s forward %s dport %s quota name "%s" drop\n' \
                "$family" "$table_name" "$protocol" "$port" "$quota_name"
            printf 'insert rule %s %s output %s sport %s quota name "%s" drop\n' \
                "$family" "$table_name" "$protocol" "$port" "$quota_name"
            printf 'insert rule %s %s forward %s sport %s quota name "%s" drop\n' \
                "$family" "$table_name" "$protocol" "$port" "$quota_name"
        done
    done
}

# 在单个 nft 事务中重建目标端口。旧 true/reset 参数也通过重建配额对象完成清零。
rebuild_port_counter_objects() {
    local port="$1"
    local target_input="${2:-0}"
    local target_output="${3:-0}"
    local quota_action="${4:-false}"
    [[ "$target_input" =~ ^[0-9]+$ ]] || return 1
    [[ "$target_output" =~ ^[0-9]+$ ]] || return 1
    case "$quota_action" in
        false) quota_action="keep" ;;
        true|reset) quota_action="rebuild" ;;
        keep|rebuild) ;;
        *) return 1 ;;
    esac

    local table_name
    local family
    local billing_mode
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    billing_mode=$(jq -r --arg port "$port" '.ports[$port].billing_mode // "double"' "$CONFIG_FILE")

    local object_prefix
    object_prefix=$(get_port_counter_prefix "$port")
    local input_counter="${object_prefix}_in"
    local output_counter="${object_prefix}_out"
    local quota_name="${object_prefix}_quota"
    local rules_json
    local rebuild_batch
    rules_json=$(mktemp "$CONFIG_DIR/.nft-rules.XXXXXX") || return 1
    rebuild_batch=$(mktemp "$CONFIG_DIR/.nft-rebuild.XXXXXX") || {
        rm -f "$rules_json"
        return 1
    }

    if ! nft -j -a list table "$family" "$table_name" > "$rules_json" 2>/dev/null; then
        rm -f "$rules_json" "$rebuild_batch"
        return 1
    fi

    local input_exists=false
    local output_exists=false
    local quota_exists=false
    jq -e --arg name "$input_counter" 'any(.nftables[]; .counter?.name? == $name)' \
        "$rules_json" >/dev/null 2>&1 && input_exists=true
    jq -e --arg name "$output_counter" 'any(.nftables[]; .counter?.name? == $name)' \
        "$rules_json" >/dev/null 2>&1 && output_exists=true
    jq -e --arg name "$quota_name" 'any(.nftables[]; .quota?.name? == $name)' \
        "$rules_json" >/dev/null 2>&1 && quota_exists=true
    if ! jq -r \
            --arg family "$family" \
            --arg table "$table_name" \
            --arg input "$input_counter" \
            --arg output "$output_counter" \
            --arg quota "$quota_name" \
            --arg quota_action "$quota_action" '
            .nftables[] |
            select(.rule != null and .rule.handle != null) |
            .rule as $rule |
            [
                $rule.expr[]? | .counter? |
                if type == "string" then .
                elif type == "object" then (.name // empty)
                else empty end
            ] as $counters |
            [
                $rule.expr[]? | .quota? |
                if type == "string" then .
                elif type == "object" then (.name // empty)
                else empty end
            ] as $quotas |
            select(
                any($counters[]; . == $input or . == $output) or
                ($quota_action != "keep" and any($quotas[]; . == $quota))
            ) |
            "delete rule \($family) \($table) \($rule.chain) handle \($rule.handle)"
        ' "$rules_json" > "$rebuild_batch"; then
        rm -f "$rules_json" "$rebuild_batch"
        return 1
    fi

    local listed_rule_count
    local actual_rule_count
    listed_rule_count=$(wc -l < "$rebuild_batch" 2>/dev/null || echo 0)
    actual_rule_count=$(( $(count_counter_rules "$port" in) + $(count_counter_rules "$port" out) ))
    if [ "$quota_action" != "keep" ]; then
        actual_rule_count=$((actual_rule_count + $(count_quota_rules "$port")))
    fi
    if [ "$listed_rule_count" -ne "$actual_rule_count" ]; then
        rm -f "$rules_json" "$rebuild_batch"
        return 1
    fi

    [ "$input_exists" = "true" ] &&
        printf 'delete counter %s %s %s\n' "$family" "$table_name" "$input_counter" >> "$rebuild_batch"
    [ "$output_exists" = "true" ] &&
        printf 'delete counter %s %s %s\n' "$family" "$table_name" "$output_counter" >> "$rebuild_batch"
    if [ "$quota_action" = "rebuild" ] && [ "$quota_exists" = "true" ]; then
        printf 'delete quota %s %s %s\n' "$family" "$table_name" "$quota_name" >> "$rebuild_batch"
    fi
    printf 'add counter %s %s %s { packets 0 bytes %s }\n' \
        "$family" "$table_name" "$input_counter" "$target_input" >> "$rebuild_batch"
    printf 'add counter %s %s %s { packets 0 bytes %s }\n' \
        "$family" "$table_name" "$output_counter" "$target_output" >> "$rebuild_batch"

    local multiplier
    multiplier=$(get_billing_rule_multiplier "$billing_mode")
    write_port_counter_rule_commands \
        "$family" "$table_name" "$port" "$input_counter" "$output_counter" "$multiplier" \
        >> "$rebuild_batch"

    local quota_required=false
    if [ "$quota_action" = "rebuild" ]; then
        local quota_enabled
        local quota_limit
        local quota_bytes
        quota_enabled=$(jq -r --arg port "$port" '.ports[$port].quota.enabled // true' "$CONFIG_FILE")
        quota_limit=$(jq -r --arg port "$port" '.ports[$port].quota.monthly_limit // "unlimited"' "$CONFIG_FILE")
        if [ "$quota_enabled" = "true" ] && [ "$quota_limit" != "unlimited" ]; then
            quota_bytes=$(parse_size_to_bytes "$quota_limit" 2>/dev/null || echo 0)
            if ! [[ "$quota_bytes" =~ ^[0-9]+$ ]] || [ "$quota_bytes" -le 0 ]; then
                rm -f "$rules_json" "$rebuild_batch"
                return 1
            fi
            quota_required=true
            printf 'add quota %s %s %s { over %s bytes used %s bytes }\n' \
                "$family" "$table_name" "$quota_name" "$quota_bytes" \
                "$((target_input + target_output))" >> "$rebuild_batch"
        fi
    fi
    if [ "$quota_required" = "true" ]; then
        write_port_quota_rule_commands \
            "$family" "$table_name" "$port" "$quota_name" "$multiplier" >> "$rebuild_batch"
    fi

    if ! nft -f "$rebuild_batch" >/dev/null 2>&1; then
        rm -f "$rules_json" "$rebuild_batch"
        return 1
    fi
    rm -f "$rules_json" "$rebuild_batch"

    local expected_count
    expected_count=$(get_expected_counter_rule_count "$billing_mode")
    port_counter_objects_exist "$port" &&
        [ "$(count_counter_rules "$port" in)" -eq "$expected_count" ] &&
        [ "$(count_counter_rules "$port" out)" -eq "$expected_count" ] || return 1
    if [ "$quota_action" != "keep" ]; then
        local expected_quota_count=0
        [ "$quota_required" = "true" ] && expected_quota_count=$(get_expected_quota_rule_count "$billing_mode")
        [ "$(count_quota_rules "$port")" -eq "$expected_quota_count" ] || return 1
    fi
    return 0
}

# 重置端口 nftables 计数器和配额。
reset_port_nftables_counters() {
    local port="$1"
    local table_name
    local family
    table_name=$(jq -r '.nftables.table_name' "$CONFIG_FILE")
    family=$(jq -r '.nftables.family' "$CONFIG_FILE")
    local object_prefix
    object_prefix=$(get_port_counter_prefix "$port")
    local input_counter="${object_prefix}_in"
    local output_counter="${object_prefix}_out"
    local quota_name="${object_prefix}_quota"
    local quota_required=false
    if [ "$(get_quota_enabled "$port")" = "true" ] && [ "$(get_quota_limit "$port")" != "unlimited" ]; then
        quota_required=true
    fi

    if ! nft list counter "$family" "$table_name" "$input_counter" >/dev/null 2>&1 ||
       ! nft list counter "$family" "$table_name" "$output_counter" >/dev/null 2>&1; then
        log_notification "端口 $port 重置失败：流量 counter 对象缺失"
        return 1
    fi
    if [ "$quota_required" = "true" ] &&
       ! nft list quota "$family" "$table_name" "$quota_name" >/dev/null 2>&1; then
        log_notification "端口 $port 重置失败：quota 对象缺失"
        return 1
    fi

    # 与快照和灾备恢复共用锁，保证旧备份不能在重置窗口内重新写回 counter。
    acquire_traffic_stats_lock || return 1
    local reset_ok=true
    if ! rebuild_port_counter_objects "$port" 0 0 "$quota_required"; then
        reset_ok=false
    elif ! update_traffic_snapshot_baseline_locked "$port" "preserve_today"; then
        # 宁可丢弃灾备文件并由下一次快照重建，也不能保留重置前的旧计数。
        rm -f "$TRAFFIC_DATA_FILE"
        log_notification "端口 $port 已完成内核计数重置，但重置后基线写入失败，已丢弃旧灾备计数"
    fi
    release_traffic_stats_lock

    if [ "$reset_ok" != "true" ]; then
        log_notification "端口 $port 重置失败：nftables counter 原子重建事务未提交"
        return 1
    fi

    if [ "$quota_required" = "true" ]; then
        nft list quota "$family" "$table_name" "$quota_name" >/dev/null 2>&1 || return 1
    fi
}

record_reset_history() {
    local port=$1
    local traffic_bytes=$2
    local due_date="${3:-}"
    local timestamp=$(get_beijing_time +%s)
    local history_file="$CONFIG_DIR/reset_history.log"

    mkdir -p "$(dirname "$history_file")"

    printf '%s|%s|%s|%s\n' "$timestamp" "$port" "$traffic_bytes" "$due_date" >> "$history_file" || return 1

    # 限制历史记录条数，避免文件过大
    if [ $(wc -l < "$history_file" 2>/dev/null || echo 0) -gt 100 ]; then
        tail -n 100 "$history_file" > "${history_file}.tmp"
        mv "${history_file}.tmp" "$history_file"
    fi
}

reset_history_has_due() {
    local port="$1"
    local due_date="$2"
    local history_file="$CONFIG_DIR/reset_history.log"
    [ -f "$history_file" ] || return 1
    awk -F'|' -v port="$port" -v due="$due_date" \
        '$2 == port && $4 == due { found=1 } END { exit found ? 0 : 1 }' "$history_file"
}

manage_configuration() {
    echo -e "${BLUE}=== 配置文件管理 ===${NC}"
    echo
    echo "请选择操作:"
    echo "1. 导出配置包"
    echo "2. 导入配置包"
    echo "0. 返回上级菜单"
    echo
    read -p "请输入选择 [0-2]: " choice

    case $choice in
        1) export_config ;;
        2) import_config ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择，请输入0-2${NC}"; sleep 1; manage_configuration ;;
    esac
}

export_config() {
    echo -e "${BLUE}=== 导出配置包 ===${NC}"
    echo

    # 检查配置目录是否存在
    if [ ! -d "$CONFIG_DIR" ]; then
        echo -e "${RED}错误：配置目录不存在${NC}"
        sleep 2
        manage_configuration
        return
    fi

    # 生成时间戳文件名
    local timestamp=$(get_beijing_time +%Y%m%d-%H%M%S)
    local backup_name="port-traffic-dog-config-${timestamp}.tar.gz"
    local backup_path="/root/${backup_name}"

    echo "正在导出配置包..."
    echo "包含内容："
    echo "  - 主配置文件 (config.json)"
    echo "  - 端口监控数据"
    echo "  - 通知配置"
    echo "  - 日志文件"
    echo

    # 打包前刷新自然日统计和内核计数备份，失败时不生成伪成功的旧数据包。
    if has_active_ports &&
       { ! record_traffic_snapshot >/dev/null 2>&1 || ! save_traffic_data >/dev/null 2>&1; }; then
        echo -e "${RED}配置包导出失败：无法刷新当前流量数据，请稍后重试${NC}"
        read -p "按回车键返回..."
        manage_configuration
        return 1
    fi

    # 创建临时目录用于打包
    local temp_dir
    temp_dir=$(mktemp -d) || {
        echo -e "${RED}配置包导出失败：无法创建临时目录${NC}"
        read -p "按回车键返回..."
        manage_configuration
        return
    }
    local package_dir="$temp_dir/port-traffic-dog-config"
    local archive_temp
    archive_temp=$(mktemp "/root/.${backup_name}.XXXXXX") || {
        rm -rf "$temp_dir"
        echo -e "${RED}配置包导出失败：无法创建临时归档${NC}"
        read -p "按回车键返回..."
        manage_configuration
        return
    }
    local export_ok=true

    # 复制配置目录到临时位置
    if ! cp -r "$CONFIG_DIR" "$package_dir"; then
        export_ok=false
    fi
    if [ "$export_ok" = "true" ]; then
        rm -rf "$package_dir/config.lock" "$package_dir/traffic_stats.lock" "$package_dir/reset.lock"
    fi

    # 生成端口流量狗配置包信息文件
    if [ "$export_ok" = "true" ] && ! cat > "$package_dir/package_info.txt" << EOF
===================
导出时间: $(get_beijing_time '+%Y-%m-%d %H:%M:%S')
脚本版本: $SCRIPT_VERSION
配置目录: $CONFIG_DIR
导出主机: $(hostname)
包含端口: $(jq -r '.ports | keys | join(", ")' "$CONFIG_FILE" 2>/dev/null || echo "无")
EOF
    then
        export_ok=false
    fi

    # 打包配置
    if [ "$export_ok" = "true" ] &&
       tar -czf "$archive_temp" -C "$temp_dir" port-traffic-dog-config/ 2>/dev/null &&
       tar -tzf "$archive_temp" >/dev/null 2>&1 &&
       chmod 600 "$archive_temp" && mv "$archive_temp" "$backup_path"; then
        export_ok=true
    else
        export_ok=false
    fi

    # 清理临时目录
    rm -rf "$temp_dir"
    rm -f "$archive_temp" 2>/dev/null || true

    if [ "$export_ok" = "true" ]; then
        local file_size=$(du -h "$backup_path" | cut -f1)
        echo -e "${GREEN}配置包导出成功${NC}"
        echo
        echo "文件信息："
        echo "  文件名: $backup_name"
        echo "  路径: $backup_path"
        echo "  大小: $file_size"
    else
        echo -e "${RED}配置包导出失败${NC}"
    fi

    echo
    read -p "按回车键返回..."
    manage_configuration
}

# 导入配置包
import_config() {
    echo -e "${BLUE}=== 导入配置包 ===${NC}"
    echo

    echo "请输入配置包路径 (支持绝对路径或相对路径):"
    echo "例如: /root/port-traffic-dog-config-20241227-143022.tar.gz"
    echo
    read -p "配置包路径: " package_path

    # 检查输入是否为空
    if [ -z "$package_path" ]; then
        echo -e "${RED}错误：路径不能为空${NC}"
        sleep 2
        import_config
        return
    fi

    # 检查文件是否存在
    if [ ! -f "$package_path" ]; then
        echo -e "${RED}错误：配置包文件不存在${NC}"
        echo "路径: $package_path"
        sleep 2
        import_config
        return
    fi
    package_path=$(realpath "$package_path")

    # 检查文件格式
    if [[ ! "$package_path" =~ \.tar\.gz$ ]]; then
        echo -e "${RED}错误：配置包必须是 .tar.gz 格式${NC}"
        sleep 2
        import_config
        return
    fi

    echo
    echo "正在验证配置包..."

    # 创建临时目录用于解压验证
    local temp_dir=$(mktemp -d)

    # 解压到临时目录进行验证
    if ! tar -tzf "$package_path" >/dev/null 2>&1; then
        echo -e "${RED}错误：配置包文件损坏或格式错误${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    if tar -tzf "$package_path" | awk '
        /^\// || /(^|\/)\.\.(\/|$)/ || !/^port-traffic-dog-config(\/|$)/ { bad=1 }
        END { exit bad ? 0 : 1 }
    '; then
        echo -e "${RED}错误：配置包包含不安全或异常路径${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    if tar -tvzf "$package_path" | awk 'substr($1, 1, 1) !~ /^[-d]$/ { found=1 } END { exit found ? 0 : 1 }'; then
        echo -e "${RED}错误：配置包只能包含普通文件和目录${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    # 解压配置包
    tar -xzf "$package_path" -C "$temp_dir" 2>/dev/null

    # 验证配置包结构
    local config_dir_name="port-traffic-dog-config"
    if [ ! -d "$temp_dir/$config_dir_name" ]; then
        echo -e "${RED}错误：配置包结构异常${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    local extracted_config="$temp_dir/$config_dir_name"

    # 检查必要文件
    if [ ! -f "$extracted_config/config.json" ]; then
        echo -e "${RED}错误：配置包中缺少 config.json 文件${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi
    if ! jq empty "$extracted_config/config.json" >/dev/null 2>&1; then
        echo -e "${RED}错误：配置包中的 config.json 不是有效 JSON${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi
    if ! validate_config_file "$extracted_config/config.json"; then
        echo -e "${RED}错误：配置包中的端口、配额、限速或重置策略无效${NC}"
        rm -rf "$temp_dir"
        sleep 2
        import_config
        return
    fi

    # 显示端口流量狗配置包信息
    echo -e "${GREEN}配置包验证通过${NC}"
    echo

    if [ -f "$extracted_config/package_info.txt" ]; then
        echo -e "${GREEN}端口流量狗配置包信息：${NC}"
        cat "$extracted_config/package_info.txt"
        echo
    fi

    # 显示将要导入的端口
    local import_ports=$(jq -r '.ports | keys | join(", ")' "$extracted_config/config.json" 2>/dev/null || echo "无")
    echo "包含端口: $import_ports"
    echo

    # 确认导入
    echo -e "${YELLOW}警告：导入配置将会：${NC}"
    echo "  1. 停止当前所有端口监控"
    echo "  2. 替换为新的配置"
    echo "  3. 重新应用监控规则"
    echo
    read -p "确认导入配置包? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消导入"
        rm -rf "$temp_dir"
        sleep 1
        manage_configuration
        return
    fi

    echo
    echo "开始导入配置..."

    # 在停止旧规则前保存最新内核计数，供失败回滚使用。
    record_traffic_snapshot >/dev/null 2>&1 || true
    if has_active_ports && ! save_traffic_data; then
        echo -e "${RED}错误：无法保存当前流量计数，已停止导入${NC}"
        rm -rf "$temp_dir"
        sleep 2
        manage_configuration
        return
    fi

    # 1. 停止当前监控
    echo "正在停止当前端口监控..."
    local current_ports=()
    mapfile -t current_ports < <(get_active_ports 2>/dev/null || true)
    for port in "${current_ports[@]}"; do
        remove_nftables_rules "$port" 2>/dev/null || true
        remove_nftables_quota "$port" 2>/dev/null || true
        remove_tc_limit "$port" 2>/dev/null || true
    done

    # 2. 替换配置；保留同文件系统备份，复制失败时可立即恢复。
    echo "正在导入新配置..."
    local previous_config_dir="${CONFIG_DIR}.import-backup.$$"
    rm -rf "$previous_config_dir" 2>/dev/null || true
    if [ -d "$CONFIG_DIR" ] && ! mv "$CONFIG_DIR" "$previous_config_dir"; then
        restore_runtime_state >/dev/null 2>&1 || true
        refresh_all_cron_from_config >/dev/null 2>&1 || true
        echo -e "${RED}错误：无法备份当前配置，已停止导入并恢复原监控${NC}"
        rm -rf "$temp_dir"
        sleep 2
        manage_configuration
        return
    fi
    if ! cp -r "$extracted_config" "$CONFIG_DIR"; then
        rm -rf "$CONFIG_DIR" 2>/dev/null || true
        if [ -d "$previous_config_dir" ]; then
            mv "$previous_config_dir" "$CONFIG_DIR" 2>/dev/null || true
            restore_runtime_state >/dev/null 2>&1 || true
            refresh_all_cron_from_config >/dev/null 2>&1 || true
        fi
        echo -e "${RED}错误：复制新配置失败，已恢复原配置${NC}"
        rm -rf "$temp_dir"
        sleep 2
        manage_configuration
        return
    fi
    rm -rf "$CONFIG_LOCK_DIR" "$TRAFFIC_STATS_LOCK_DIR" "$RESET_LOCK_DIR" "$CRON_LOCK_DIR"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true

    # 3. 重新应用规则；任一步失败都回滚旧配置和旧运行状态。
    echo "正在重新应用监控规则..."
    local new_ports=()
    mapfile -t new_ports < <(get_active_ports 2>/dev/null || true)
    local import_ok=true
    if ! validate_config_file "$CONFIG_FILE" >/dev/null ||
       ! restore_runtime_state ||
       ! refresh_all_cron_from_config; then
        import_ok=false
    fi

    if [ "$import_ok" != "true" ]; then
        for port in "${new_ports[@]}"; do
            remove_tc_limit "$port" >/dev/null 2>&1 || true
            remove_nftables_quota "$port" >/dev/null 2>&1 || true
            remove_nftables_rules "$port" >/dev/null 2>&1 || true
        done
        rm -rf "$CONFIG_DIR" 2>/dev/null || true
        local rollback_ok=true
        if [ -d "$previous_config_dir" ]; then
            mv "$previous_config_dir" "$CONFIG_DIR" || rollback_ok=false
        else
            rollback_ok=false
        fi
        if [ "$rollback_ok" = "true" ]; then
            restore_runtime_state >/dev/null 2>&1 || rollback_ok=false
            refresh_all_cron_from_config >/dev/null 2>&1 || rollback_ok=false
        fi
        rm -rf "$temp_dir"
        if [ "$rollback_ok" = "true" ]; then
            echo -e "${RED}配置导入失败，已恢复导入前的配置与监控状态${NC}"
        else
            echo -e "${RED}配置导入失败，自动回滚未完整成功；旧备份保留在 $previous_config_dir${NC}"
        fi
        sleep 2
        manage_configuration
        return
    fi

    echo "正在更新通知模块..."
    download_notification_modules >/dev/null 2>&1 || true

    rm -rf "$previous_config_dir" 2>/dev/null || true
    rm -rf "$temp_dir"

    echo
    echo -e "${GREEN}配置导入完成${NC}"
    echo
    echo "导入结果："
    echo "  导入端口数: ${#new_ports[@]} 个"
    if [ ${#new_ports[@]} -gt 0 ]; then
        echo "  端口列表: $(IFS=','; echo "${new_ports[*]}")"
    fi
    echo
    echo -e "${YELLOW}提示：${NC}"
    echo "  - 所有端口监控规则已重新应用"
    echo "  - 通知配置已恢复"
    echo "  - 历史数据已恢复"

    echo
    read -p "按回车键返回..."
    manage_configuration
}

# 统一下载函数
download_with_sources() {
    local url=$1
    local output_file=$2

    if curl -fsSL --connect-timeout "$SHORT_CONNECT_TIMEOUT" --max-time "$SHORT_MAX_TIMEOUT" "$url" -o "$output_file" 2>/dev/null; then
        if [ -s "$output_file" ]; then
            echo -e "${GREEN}下载成功${NC}"
            return 0
        fi
    fi

    echo -e "${RED}下载失败${NC}"
    return 1
}

get_script_version_from_file() {
    local script_file="$1"
    [ -f "$script_file" ] || return 1
    awk -F'"' '/^readonly SCRIPT_VERSION="[0-9]+(\.[0-9]+)+"/ { print $2; exit }' "$script_file"
}

script_version_is_valid() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]
}

script_version_is_older() {
    local candidate="$1"
    local current="$2"
    script_version_is_valid "$candidate" || return 2
    script_version_is_valid "$current" || return 2

    local candidate_parts=()
    local current_parts=()
    local IFS='.'
    read -r -a candidate_parts <<< "$candidate"
    read -r -a current_parts <<< "$current"

    local index
    for index in 0 1 2; do
        local candidate_part=${candidate_parts[$index]:-0}
        local current_part=${current_parts[$index]:-0}
        if ((10#$candidate_part < 10#$current_part)); then
            return 0
        fi
        if ((10#$candidate_part > 10#$current_part)); then
            return 1
        fi
    done
    return 1
}

# 下载通知模块
download_notification_modules() {
    local sync_mode="${1:-fill_missing}"
    local notifications_dir="$CONFIG_DIR/notifications"
    local temp_dir=$(mktemp -d)
    local script_dir
    script_dir=$(dirname "$(get_script_exec_path)")

    mkdir -p "$notifications_dir"

    # 优先使用主脚本同目录下的通知模块
    for local_module in "$script_dir"/telegram.sh "$script_dir"/wecom.sh; do
        [ -f "$local_module" ] || continue

        local module_name=$(basename "$local_module")
        local target_file="$notifications_dir/$module_name"

        if [ "$sync_mode" = "force" ] || [ ! -f "$target_file" ]; then
            cp "$local_module" "$target_file"
        fi
    done

    if [ "$sync_mode" != "force" ] && [ -f "$notifications_dir/telegram.sh" ] && [ -f "$notifications_dir/wecom.sh" ]; then
        chmod +x "$notifications_dir"/*.sh 2>/dev/null || true
        rm -rf "$temp_dir"
        return 0
    fi

    # 下载解压后同步通知模块：默认只补齐缺失；force 模式覆盖同步
    local archive_url="${MODULES_ARCHIVE_URL}?cache_bust=$(date +%s)"
    if download_with_sources "$archive_url" "$temp_dir/repo.zip" &&
       (cd "$temp_dir" && unzip -q repo.zip); then
        local extracted_root=""
        local d
        for d in "$temp_dir"/*; do
            [ -d "$d" ] || continue
            if [ "$(basename "$d")" != "." ] && [ "$(basename "$d")" != ".." ]; then
                extracted_root="$d"
                break
            fi
        done

        if [ -z "$extracted_root" ]; then
            rm -rf "$temp_dir"
            return 1
        fi

        local remote_telegram=""
        local remote_wecom=""
        if [ -f "$extracted_root/notifications/telegram.sh" ]; then
            remote_telegram="$extracted_root/notifications/telegram.sh"
        elif [ -f "$extracted_root/telegram.sh" ]; then
            remote_telegram="$extracted_root/telegram.sh"
        fi
        if [ -f "$extracted_root/notifications/wecom.sh" ]; then
            remote_wecom="$extracted_root/notifications/wecom.sh"
        elif [ -f "$extracted_root/wecom.sh" ]; then
            remote_wecom="$extracted_root/wecom.sh"
        fi

        local module_file
        for module_file in "$remote_telegram" "$remote_wecom"; do
            [ -n "$module_file" ] || continue
            [ -f "$module_file" ] || continue

            local module_name
            module_name=$(basename "$module_file")
            local target_file="$notifications_dir/$module_name"

            if [ "$sync_mode" = "force" ] || [ ! -f "$target_file" ]; then
                cp "$module_file" "$target_file"
            fi
        done

        if [ -f "$notifications_dir/telegram.sh" ] && [ -f "$notifications_dir/wecom.sh" ]; then
            chmod +x "$notifications_dir"/*.sh 2>/dev/null || true
            rm -rf "$temp_dir"
            return 0
        fi
    fi

    rm -rf "$temp_dir"
    return 1
}

finalize_script_update() {
    echo -e "${YELLOW}[1/3] 初始化并迁移现有配置...${NC}"
    check_dependencies true
    if ! init_config; then
        echo -e "${RED}新版本配置初始化失败${NC}"
        return 1
    fi
    if ! install_tc_recovery_service_files; then
        echo -e "${YELLOW}共享 TC 恢复入口安装失败；不影响现有监控，但自动恢复暂不可用。${NC}"
    fi

    echo -e "${YELLOW}[2/3] 刷新定时任务...${NC}"
    if ! refresh_all_cron_from_config; then
        echo -e "${RED}新版本定时任务刷新失败${NC}"
        return 1
    fi

    echo -e "${YELLOW}[3/3] 校验并恢复流量与限速状态...${NC}"
    if ! restore_runtime_state; then
        echo -e "${RED}新版本流量或限速状态恢复失败${NC}"
        return 1
    fi

    echo -e "${GREEN}新版本维护步骤完成${NC}"
}

# 安装(更新)脚本
install_update_script() {
    local reload_after_update="${1:-true}"
    echo -e "${BLUE}安装依赖(更新)脚本${NC}"
    echo "────────────────────────────────────────────────────────"

    echo -e "${YELLOW}正在检查系统依赖...${NC}"
    check_dependencies true
    init_config || return 1
    record_traffic_snapshot >/dev/null 2>&1 || true
    if has_active_ports && ! save_traffic_data; then
        echo -e "${RED}无法保存当前流量计数，已停止更新${NC}"
        return 1
    fi

    echo -e "${YELLOW}正在下载最新版本...${NC}"

    local temp_dir
    temp_dir=$(mktemp -d)
    local new_script=""
    local archive="$temp_dir/repo.zip"
    local extracted_root=""
    local new_telegram=""
    local new_wecom=""
    local archive_url="${MODULES_ARCHIVE_URL}?cache_bust=$(date +%s)"

    if ! download_with_sources "$archive_url" "$archive" ||
       ! (cd "$temp_dir" && unzip -q "$archive"); then
        echo -e "${RED}下载或解压失败，已保留当前版本${NC}"
        rm -rf "$temp_dir"
        return 1
    fi

    local directory
    for directory in "$temp_dir"/*; do
        [ -d "$directory" ] || continue
        extracted_root="$directory"
        break
    done
    if [ -n "$extracted_root" ]; then
        [ -f "$extracted_root/port-traffic-dog.sh" ] &&
            new_script="$extracted_root/port-traffic-dog.sh"
        [ -f "$extracted_root/notifications/telegram.sh" ] &&
            new_telegram="$extracted_root/notifications/telegram.sh"
        [ -f "$extracted_root/telegram.sh" ] && new_telegram="$extracted_root/telegram.sh"
        [ -f "$extracted_root/notifications/wecom.sh" ] &&
            new_wecom="$extracted_root/notifications/wecom.sh"
        [ -f "$extracted_root/wecom.sh" ] && new_wecom="$extracted_root/wecom.sh"
    fi

    local downloaded_version=""
    downloaded_version=$(get_script_version_from_file "$new_script" 2>/dev/null || true)

    if [ ! -s "$new_script" ] || [ -z "$new_telegram" ] || [ -z "$new_wecom" ] ||
       ! script_version_is_valid "$downloaded_version" ||
       ! grep -q "端口流量狗" "$new_script" 2>/dev/null ||
       ! bash -n "$new_script" || ! bash -n "$new_telegram" || ! bash -n "$new_wecom" ||
       ! bash "$new_script" --validate-config "$CONFIG_FILE" >/dev/null; then
        echo -e "${RED}下载文件、脚本语法或当前配置验证失败，已保留当前版本${NC}"
        rm -rf "$temp_dir"
        return 1
    fi
    if script_version_is_older "$downloaded_version" "$SCRIPT_VERSION"; then
        echo -e "${RED}下载版本 v$downloaded_version 早于当前版本 v$SCRIPT_VERSION，已拒绝降级${NC}"
        rm -rf "$temp_dir"
        return 1
    fi
    echo -e "${BLUE}版本: v$SCRIPT_VERSION -> v$downloaded_version${NC}"

    local backup_dir="$temp_dir/backup"
    local notifications_dir="$CONFIG_DIR/notifications"
    local shortcut_path="/usr/local/bin/$SHORTCUT_COMMAND"
    mkdir -p "$backup_dir"
    [ -f "$INSTALLED_SCRIPT_PATH" ] && cp -a "$INSTALLED_SCRIPT_PATH" "$backup_dir/port-traffic-dog.sh"
    [ -f "$shortcut_path" ] && cp -a "$shortcut_path" "$backup_dir/dog"
    [ -d "$CONFIG_DIR" ] && cp -a "$CONFIG_DIR" "$backup_dir/config"
    if ! read_root_crontab_locked > "$backup_dir/root.crontab"; then
        echo -e "${RED}无法备份 root crontab，已停止更新${NC}"
        rm -rf "$temp_dir"
        return 1
    fi

    local update_ok=true
    local failed_stage=""
    mkdir -p "$notifications_dir"
    if ! install -m 755 "$new_script" "${INSTALLED_SCRIPT_PATH}.new.$$" ||
       ! mv "${INSTALLED_SCRIPT_PATH}.new.$$" "$INSTALLED_SCRIPT_PATH"; then
        update_ok=false
        failed_stage="安装主脚本"
    elif ! install -m 755 "$new_telegram" "$notifications_dir/telegram.sh" ||
         ! install -m 755 "$new_wecom" "$notifications_dir/wecom.sh"; then
        update_ok=false
        failed_stage="安装通知模块"
    elif ! create_shortcut_command >/dev/null; then
        update_ok=false
        failed_stage="重建 dog 快捷命令"
    elif ! bash "$INSTALLED_SCRIPT_PATH" --finalize-update; then
        update_ok=false
        failed_stage="应用新版本配置与运行状态"
    elif ! bash "$INSTALLED_SCRIPT_PATH" --version 2>/dev/null |
         grep -Fq "v$downloaded_version"; then
        update_ok=false
        failed_stage="核验安装版本"
    fi

    if [ "$update_ok" != "true" ]; then
        echo -e "${RED}更新失败阶段: ${failed_stage:-未知}${NC}"
        local rollback_ok=true
        local current_ports=()
        mapfile -t current_ports < <(get_active_ports 2>/dev/null || true)
        local current_port
        for current_port in "${current_ports[@]}"; do
            remove_tc_limit "$current_port" >/dev/null 2>&1 || true
        done
        local current_family
        local current_table
        current_family=$(jq -r '.nftables.family // "inet"' "$CONFIG_FILE" 2>/dev/null || echo inet)
        current_table=$(jq -r '.nftables.table_name // "port_traffic_monitor"' "$CONFIG_FILE" 2>/dev/null || echo port_traffic_monitor)
        nft delete table "$current_family" "$current_table" >/dev/null 2>&1 || true

        rm -f "${INSTALLED_SCRIPT_PATH}.new.$$" "$INSTALLED_SCRIPT_PATH" "$shortcut_path"
        rm -rf "$CONFIG_DIR"
        if [ -f "$backup_dir/port-traffic-dog.sh" ]; then
            cp -a "$backup_dir/port-traffic-dog.sh" "$INSTALLED_SCRIPT_PATH" || rollback_ok=false
        else
            rollback_ok=false
        fi
        if [ -f "$backup_dir/dog" ]; then
            cp -a "$backup_dir/dog" "$shortcut_path" || rollback_ok=false
        fi
        if [ -d "$backup_dir/config" ]; then
            cp -a "$backup_dir/config" "$CONFIG_DIR" || rollback_ok=false
        else
            rollback_ok=false
        fi
        rm -rf "$CONFIG_LOCK_DIR" "$TRAFFIC_STATS_LOCK_DIR" "$RESET_LOCK_DIR" "$CRON_LOCK_DIR"
        if begin_cron_update; then
            crontab "$backup_dir/root.crontab" >/dev/null 2>&1 || rollback_ok=false
            release_cron_update
        else
            rollback_ok=false
        fi
        if [ "$rollback_ok" = "true" ] && [ -f "$INSTALLED_SCRIPT_PATH" ]; then
            bash "$INSTALLED_SCRIPT_PATH" --restore-runtime >/dev/null 2>&1 || rollback_ok=false
        fi
        if [ "$rollback_ok" = "true" ]; then
            rm -rf "$temp_dir"
            echo -e "${RED}更新后的维护步骤失败，已恢复更新前版本、配置和运行状态${NC}"
        else
            echo -e "${RED}更新失败且自动回滚未完整成功，请从备份目录手动恢复: $backup_dir${NC}"
        fi
        return 1
    fi

    rm -rf "$temp_dir"
    echo -e "${GREEN}依赖检查、主脚本和通知模块更新完成${NC}"
    if [ "$reload_after_update" = "true" ]; then
        echo -e "${YELLOW}正在重新加载新版本...${NC}"
        sleep 1
        exec bash "$INSTALLED_SCRIPT_PATH"
    fi
    return 0
}

create_shortcut_command() {
    if [ "$SCRIPT_PATH" != "$INSTALLED_SCRIPT_PATH" ] && [ ! -f "$INSTALLED_SCRIPT_PATH" ]; then
        cp "$SCRIPT_PATH" "$INSTALLED_SCRIPT_PATH"
        chmod +x "$INSTALLED_SCRIPT_PATH" 2>/dev/null || true
    elif [ -f "$INSTALLED_SCRIPT_PATH" ]; then
        chmod +x "$INSTALLED_SCRIPT_PATH" 2>/dev/null || true
    fi

    cat > "/usr/local/bin/$SHORTCUT_COMMAND" << EOF
#!/bin/bash
exec bash "$INSTALLED_SCRIPT_PATH" "\$@"
EOF
    chmod 755 "/usr/local/bin/$SHORTCUT_COMMAND" 2>/dev/null || true
    echo -e "${GREEN}快捷命令 '$SHORTCUT_COMMAND' 创建成功${NC}"
}

ensure_installation_files() {
    local shortcut_path="/usr/local/bin/$SHORTCUT_COMMAND"
    if [ -f "$INSTALLED_SCRIPT_PATH" ] && [ -f "$shortcut_path" ]; then
        install_tc_recovery_service_files >/dev/null 2>&1 || true
        return 0
    fi

    # 首次直接运行下载脚本时，保留原有的安装与快捷命令行为。
    create_shortcut_command >/dev/null
    download_notification_modules >/dev/null 2>&1 || true
    install_tc_recovery_service_files >/dev/null 2>&1 || true
}

cleanup_owned_tc_root_without_config() {
    local owner_file
    local owner_interface=""
    local ntc_uninstall_status=0

    owner_file=$(get_tc_root_owner_file)
    [ -r "$owner_file" ] || return 0
    IFS='|' read -r owner_interface _ < "$owner_file" || true
    [ -n "$owner_interface" ] || return 0

    if ! begin_tc_update; then
        log_notification "卸载时无法取得共享TC锁，已保留现有qdisc避免并发破坏"
        return 1
    fi

    # 归属与 NTC 状态必须在共享锁内重新确认，避免检查后另一项目接管层级。
    if tc_root_is_owned "$owner_interface"; then
        trafficcop_unified_state_rate "$owner_interface" >/dev/null 2>&1 || ntc_uninstall_status=$?
        if [ "$ntc_uninstall_status" -eq 0 ] ||
           { [ -e "$TRAFFICCOP_TC_STATE_FILE" ] && [ "$ntc_uninstall_status" -ne 1 ] && [ "$ntc_uninstall_status" -ne 4 ]; }; then
            rm -f "$owner_file"
            log_notification "卸载Dog时保留TrafficCop正在使用的统一HTB: $owner_interface"
        else
            tc qdisc del dev "$owner_interface" root handle 1: 2>/dev/null || true
        fi
    fi

    finish_tc_update
}

# 卸载脚本
uninstall_script() {
    echo -e "${BLUE}卸载脚本${NC}"
    echo "────────────────────────────────────────────────────────"

    echo -e "${YELLOW}将要删除以下内容:${NC}"
    echo "  - 脚本文件: $INSTALLED_SCRIPT_PATH"
    echo "  - 快捷命令: /usr/local/bin/$SHORTCUT_COMMAND"
    echo "  - 配置目录: $CONFIG_DIR"
    echo "  - 所有nftables规则"
    echo "  - 所有TC限制规则"
    echo "  - 通知定时任务"
    echo
    echo -e "${RED}警告：此操作将完全删除端口流量狗及其所有数据！${NC}"
    read -p "确认卸载? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在卸载...${NC}"

        local config_valid=false
        if [ -f "$CONFIG_FILE" ] && validate_config_file "$CONFIG_FILE" >/dev/null 2>&1; then
            config_valid=true
        fi
        local active_ports=()
        if [ "$config_valid" = "true" ]; then
            mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
        fi
        if begin_tc_update; then
            local uninstall_interface
            uninstall_interface=$(get_default_interface 2>/dev/null || true)
            if [ -n "$uninstall_interface" ] && \
               tc qdisc show dev "$uninstall_interface" 2>/dev/null | grep -Eq '^qdisc htb 1:' && \
               ! tc_root_is_managed "$uninstall_interface"; then
                adopt_legacy_tc_root_if_safe "$uninstall_interface" >/dev/null 2>&1 || true
            fi
            for port in "${active_ports[@]}"; do
                remove_nftables_rules "$port" 2>/dev/null || true
                remove_tc_limit_locked "$port" 2>/dev/null || true
            done
            finish_tc_update
        else
            log_notification "卸载时无法取得共享TC锁，已保留现有qdisc避免并发破坏"
            for port in "${active_ports[@]}"; do
                remove_nftables_rules "$port" 2>/dev/null || true
            done
        fi

        local table_name="port_traffic_monitor"
        local family="inet"
        if [ "$config_valid" = "true" ]; then
            table_name=$(jq -r '.nftables.table_name // "port_traffic_monitor"' "$CONFIG_FILE")
            family=$(jq -r '.nftables.family // "inet"' "$CONFIG_FILE")
        else
            cleanup_owned_tc_root_without_config || true
        fi
        nft delete table "$family" "$table_name" >/dev/null 2>&1 || true

        remove_telegram_notification_cron 2>/dev/null || true
        remove_wecom_notification_cron 2>/dev/null || true
        remove_all_port_auto_reset_cron 2>/dev/null || true
        remove_traffic_snapshot_cron 2>/dev/null || true
        remove_runtime_restore_cron 2>/dev/null || true

        # 菜单模式已注册退出保存钩子，卸载前关闭，避免删除后重新创建空配置目录。
        trap - EXIT INT TERM
        rm -rf "$CONFIG_DIR" 2>/dev/null || true
        rm -f "/usr/local/bin/$SHORTCUT_COMMAND" 2>/dev/null || true
        rm -f "$INSTALLED_SCRIPT_PATH" 2>/dev/null || true
        cleanup_tc_recovery_files_if_unused

        echo -e "${GREEN}卸载完成！${NC}"
        echo -e "${YELLOW}感谢使用端口流量狗！${NC}"
        exit 0
    else
        echo "取消卸载"
        sleep 1
        show_main_menu
    fi
}

manage_notifications() {
    echo -e "${BLUE}=== 通知管理 ===${NC}"
    echo "1. Telegram机器人通知"
    echo "2. 邮箱通知 [敬请期待]"
    echo "3. 企业wx 机器人通知"
    echo "4. Telegram通信线路切换"
    echo "5. 强制同步通知模块(覆盖本地)"
    echo "0. 返回主菜单"
    echo
    read -p "请选择操作 [0-5]: " choice

    case $choice in
        1) manage_telegram_notifications ;;
        2)
            echo -e "${YELLOW}预留的邮箱通知功能(画饼的)${NC}"
            sleep 2
            manage_notifications
            ;;
        3) manage_wecom_notifications ;;
        4) manage_telegram_api_route ;;
        5) force_sync_notification_modules ;;
        0) show_main_menu ;;
        *) echo -e "${RED}无效选择${NC}"; sleep 1; manage_notifications ;;
    esac
}

force_sync_notification_modules() {
    echo -e "${BLUE}=== 强制同步通知模块 ===${NC}"
    echo -e "${YELLOW}此操作会覆盖当前通知模块(telegram.sh/wecom.sh)${NC}"
    read -p "确认继续? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消"
        sleep 1
        manage_notifications
        return
    fi

    echo -e "${YELLOW}正在强制同步通知模块...${NC}"
    if download_notification_modules "force" >/dev/null 2>&1; then
        echo -e "${GREEN}通知模块强制同步完成${NC}"
    else
        echo -e "${RED}通知模块同步失败，请检查网络后重试${NC}"
    fi
    sleep 2
    manage_notifications
}

load_telegram_module() {
    local telegram_script="$CONFIG_DIR/notifications/telegram.sh"
    local local_telegram_script="$(dirname "$(get_script_exec_path)")/telegram.sh"

    if [ -f "$telegram_script" ]; then
        source "$telegram_script" 2>/dev/null || true
    fi

    # 运行目录模块缺能力时，回退加载主脚本同目录模块
    if ! declare -F telegram_send_status_notification >/dev/null 2>&1; then
        if [ -f "$local_telegram_script" ]; then
            source "$local_telegram_script" 2>/dev/null || true

            # 仅在缺失能力时补齐，避免覆盖用户自定义模块
            if declare -F telegram_send_status_notification >/dev/null 2>&1; then
                mkdir -p "$CONFIG_DIR/notifications"
                cp "$local_telegram_script" "$telegram_script"
                chmod +x "$telegram_script" 2>/dev/null || true
            fi
        fi
    fi

    declare -F telegram_send_status_notification >/dev/null 2>&1
}

manage_telegram_notifications() {
    # 导出通知管理函数供模块使用
    export_notification_functions

    if load_telegram_module && declare -F telegram_configure >/dev/null 2>&1; then
        telegram_configure
        manage_notifications
    else
        echo -e "${RED}Telegram 通知模块不存在${NC}"
        echo "请检查文件: $CONFIG_DIR/notifications/telegram.sh"
        sleep 2
        manage_notifications
    fi
}

manage_telegram_api_route() {
    load_telegram_module || true

    if declare -F telegram_switch_api_route >/dev/null 2>&1; then
        telegram_switch_api_route
    else
        telegram_switch_api_route_fallback
    fi

    manage_notifications
}

telegram_switch_api_route_fallback() {
    local current_route=$(jq -r '.notifications.telegram.api_route // "official"' "$CONFIG_FILE" 2>/dev/null || echo "official")
    local custom_base=$(jq -r '.notifications.telegram.custom_api_base // ""' "$CONFIG_FILE" 2>/dev/null || true)
    custom_base=$(echo "$custom_base" | tr -d ' ')
    custom_base="${custom_base%/}"

    local current_route_display="官方"
    if [ "$current_route" = "custom" ]; then
        current_route_display="自定义"
    fi

    echo -e "${BLUE}=== Telegram通信线路切换 ===${NC}"
    echo "当前线路: ${current_route_display}"
    if [ -n "$custom_base" ] && [ "$custom_base" != "null" ]; then
        echo "当前自定义地址: ${custom_base}"
    fi
    echo
    echo "1. 官方线路 (https://api.telegram.org)"
    echo "2. 自定义线路"
    echo "0. 返回"
    echo
    read -p "请选择 [0-2]: " route_choice

    case "$route_choice" in
        1)
            update_config ".notifications.telegram.api_route = \"official\""
            echo -e "${GREEN}已切换到官方线路${NC}"
            ;;
        2)
            if [ -n "$custom_base" ] && [ "$custom_base" != "null" ]; then
                read -p "请输入自定义API基础地址 (回车沿用: ${custom_base}): " input_custom
            else
                read -p "请输入自定义API基础地址: " input_custom
            fi
            if [ -z "$input_custom" ] && [ -n "$custom_base" ] && [ "$custom_base" != "null" ]; then
                input_custom="$custom_base"
            fi
            if [ -z "$input_custom" ]; then
                echo -e "${RED}自定义API基础地址不能为空${NC}"
                return 1
            fi
            input_custom=$(echo "$input_custom" | tr -d ' ')
            input_custom="${input_custom%/}"
            if [[ ! "$input_custom" =~ ^https:// ]] &&
               [[ ! "$input_custom" =~ ^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/|$) ]]; then
                echo -e "${RED}地址不安全：远程线路必须使用 HTTPS，HTTP 仅允许本机回环地址${NC}"
                sleep 2
                return 1
            fi

            if ! update_config_file \
                '.notifications.telegram.custom_api_base = $base | .notifications.telegram.api_route = "custom"' \
                --arg base "$input_custom"; then
                echo -e "${RED}配置保存失败，请检查 $CONFIG_FILE${NC}"
                return 1
            fi

            echo -e "${GREEN}已切换到自定义线路${NC}"
            echo "当前地址: $input_custom"
            ;;
        0|"")
            return 0
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac

    sleep 1
}

manage_wecom_notifications() {
    local wecom_script="$CONFIG_DIR/notifications/wecom.sh"

    if [ -f "$wecom_script" ]; then
        # 导出通知管理函数供模块使用
        export_notification_functions
        source "$wecom_script"
        wecom_configure
        manage_notifications
    else
        echo -e "${RED}企业wx 通知模块不存在${NC}"
        echo "请检查文件: $wecom_script"
        sleep 2
        manage_notifications
    fi
}

notification_interval_cron_expression() {
    case "$1" in
        "1m")  echo "* * * * *" ;;
        "15m") echo "*/15 * * * *" ;;
        "30m") echo "*/30 * * * *" ;;
        "1h")  echo "0 * * * *" ;;
        "2h")  echo "0 */2 * * *" ;;
        "6h")  echo "0 */6 * * *" ;;
        "12h") echo "0 */12 * * *" ;;
        "24h") echo "0 0 * * *" ;;
        *) return 1 ;;
    esac
}

setup_telegram_notification_cron() {
    local script_path
    script_path=$(get_script_exec_path)
    local temp_cron=$(mktemp)
    local current_cron

    begin_cron_update || { rm -f "$temp_cron"; return 1; }
    if ! current_cron=$(read_current_crontab); then
        rm -f "$temp_cron"
        release_cron_update
        return 1
    fi
    printf '%s\n' "$current_cron" | grep -v "# 端口流量狗Telegram通知" > "$temp_cron" || true

    # 通道总开关和状态通知开关必须同时启用。
    local telegram_channel_enabled=$(jq -r '.notifications.telegram.enabled // false' "$CONFIG_FILE")
    local telegram_status_enabled=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$telegram_channel_enabled" = "true" ] && [ "$telegram_status_enabled" = "true" ] && has_active_ports; then
        local status_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")
        local schedule
        if schedule=$(notification_interval_cron_expression "$status_interval"); then
            echo "$schedule $script_path --send-telegram-status >/dev/null 2>&1  # 端口流量狗Telegram通知" >> "$temp_cron"
        fi
    fi

    finish_cron_update "$temp_cron"
}

setup_wecom_notification_cron() {
    local script_path
    script_path=$(get_script_exec_path)
    local temp_cron=$(mktemp)
    local current_cron
    begin_cron_update || { rm -f "$temp_cron"; return 1; }
    if ! current_cron=$(read_current_crontab); then
        rm -f "$temp_cron"
        release_cron_update
        return 1
    fi
    printf '%s\n' "$current_cron" | grep -v "# 端口流量狗企业wx 通知" > "$temp_cron" || true

    # 通道总开关和状态通知开关必须同时启用。
    local wecom_channel_enabled=$(jq -r '.notifications.wecom.enabled // false' "$CONFIG_FILE")
    local wecom_status_enabled=$(jq -r '.notifications.wecom.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$wecom_channel_enabled" = "true" ] && [ "$wecom_status_enabled" = "true" ] && has_active_ports; then
        local wecom_interval=$(jq -r '.notifications.wecom.status_notifications.interval' "$CONFIG_FILE")
        local schedule
        if schedule=$(notification_interval_cron_expression "$wecom_interval"); then
            echo "$schedule $script_path --send-wecom-status >/dev/null 2>&1  # 端口流量狗企业wx 通知" >> "$temp_cron"
        fi
    fi

    finish_cron_update "$temp_cron"
}

# 通用间隔选择函数
select_notification_interval() {
    # 显示选择菜单到stderr，避免被变量捕获
    echo "请选择状态通知发送间隔:" >&2
    echo "1. 1分钟   2. 15分钟  3. 30分钟  4. 1小时" >&2
    echo "5. 2小时   6. 6小时   7. 12小时  8. 24小时" >&2
    read -p "请选择(回车默认1小时) [1-8]: " interval_choice >&2

    # 默认1小时
    local interval="1h"
    case $interval_choice in
        1) interval="1m" ;;
        2) interval="15m" ;;
        3) interval="30m" ;;
        4|"") interval="1h" ;;
        5) interval="2h" ;;
        6) interval="6h" ;;
        7) interval="12h" ;;
        8) interval="24h" ;;
        *) interval="1h" ;;
    esac

    echo "$interval"
}

remove_telegram_notification_cron() {
    local temp_cron=$(mktemp)
    local current_cron
    begin_cron_update || { rm -f "$temp_cron"; return 1; }
    if ! current_cron=$(read_current_crontab); then
        rm -f "$temp_cron"
        release_cron_update
        return 1
    fi
    printf '%s\n' "$current_cron" | grep -v "# 端口流量狗Telegram通知" > "$temp_cron" || true
    finish_cron_update "$temp_cron"
}

remove_wecom_notification_cron() {
    local temp_cron=$(mktemp)
    local current_cron
    begin_cron_update || { rm -f "$temp_cron"; return 1; }
    if ! current_cron=$(read_current_crontab); then
        rm -f "$temp_cron"
        release_cron_update
        return 1
    fi
    printf '%s\n' "$current_cron" | grep -v "# 端口流量狗企业wx 通知" > "$temp_cron" || true
    finish_cron_update "$temp_cron"
}

remove_all_port_auto_reset_cron() {
    local temp_cron=$(mktemp)
    local current_cron
    begin_cron_update || { rm -f "$temp_cron"; return 1; }
    if ! current_cron=$(read_current_crontab); then
        rm -f "$temp_cron"
        release_cron_update
        return 1
    fi
    printf '%s\n' "$current_cron" | \
        grep -v "端口流量狗自动重置端口" | \
        grep -v "# port-traffic-dog scheduled reset check" | \
        grep -vE '(^|[[:space:]])[^[:space:]]*port-traffic-dog\.sh[[:space:]]+--reset-port([[:space:]]|$)' | \
        grep -vE '(^|[[:space:]])[^[:space:]]*port-traffic-dog\.sh[[:space:]]+--check-reset-port([[:space:]]|$)' | \
        grep -vE '(^|[[:space:]])[^[:space:]]*port-traffic-dog\.sh[[:space:]]+--check-scheduled-resets([[:space:]]|$)' \
        > "$temp_cron" || true
    finish_cron_update "$temp_cron"
}

ensure_cron_service_running() {
    # Debian/Ubuntu
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable cron >/dev/null 2>&1 || true
        systemctl start cron >/dev/null 2>&1 || true
    fi

    if command -v service >/dev/null 2>&1; then
        service cron start >/dev/null 2>&1 || true
    fi

    # Alpine/OpenRC
    if command -v rc-update >/dev/null 2>&1; then
        rc-update add crond default >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service crond start >/dev/null 2>&1 || true
    fi
    if command -v crond >/dev/null 2>&1 && ! pgrep -x crond >/dev/null 2>&1; then
        crond -b >/dev/null 2>&1 || true
    fi
}

refresh_notification_cron_from_config() {
    local result=0
    setup_telegram_notification_cron || result=1
    setup_wecom_notification_cron || result=1
    ensure_cron_service_running
    return "$result"
}

filter_traffic_snapshot_cron_entries() {
    awk '
        /# port-traffic-dog traffic snapshot/ { next }
        /port-traffic-dog.*--snapshot-traffic/ { next }
        /port-traffic-dog.*--send-snapshot/ { next }
        /port-traffic-dog.*--create-snapshot/ { next }
        /\/etc\/port-traffic-dog\/data\/snapshots/ { next }
        { print }
    '
}

setup_traffic_snapshot_cron() {
    local script_path
    script_path=$(get_script_exec_path)
    local temp_cron
    temp_cron=$(mktemp)
    local current_cron

    begin_cron_update || { rm -f "$temp_cron"; return 1; }
    if ! current_cron=$(read_current_crontab); then
        rm -f "$temp_cron"
        release_cron_update
        return 1
    fi
    printf '%s\n' "$current_cron" | filter_traffic_snapshot_cron_entries > "$temp_cron" || true

    if has_active_ports; then
        echo "* * * * * $script_path --snapshot-traffic >/dev/null 2>&1  # port-traffic-dog traffic snapshot" >> "$temp_cron"
    fi
    local result=0
    finish_cron_update "$temp_cron" || result=1
    setup_runtime_restore_cron || result=1
    ensure_cron_service_running
    return "$result"
}

remove_traffic_snapshot_cron() {
    local temp_cron
    temp_cron=$(mktemp)
    local current_cron

    begin_cron_update || { rm -f "$temp_cron"; return 1; }
    if ! current_cron=$(read_current_crontab); then
        rm -f "$temp_cron"
        release_cron_update
        return 1
    fi
    printf '%s\n' "$current_cron" | filter_traffic_snapshot_cron_entries > "$temp_cron" || true

    finish_cron_update "$temp_cron"
}

filter_runtime_restore_cron_entries() {
    awk '
        /# port-traffic-dog runtime restore/ { next }
        /port-traffic-dog.*--restore-runtime/ { next }
        { print }
    '
}

setup_runtime_restore_cron() {
    command -v crontab >/dev/null 2>&1 || return 0
    local script_path
    script_path=$(get_script_exec_path)
    local temp_cron
    temp_cron=$(mktemp)
    local current_cron
    begin_cron_update || { rm -f "$temp_cron"; return 1; }
    if ! current_cron=$(read_current_crontab); then
        rm -f "$temp_cron"
        release_cron_update
        return 1
    fi
    printf '%s\n' "$current_cron" | filter_runtime_restore_cron_entries > "$temp_cron" || true
    echo "@reboot sleep 15 && $script_path --restore-runtime >/dev/null 2>&1  # port-traffic-dog runtime restore" >> "$temp_cron"
    finish_cron_update "$temp_cron"
}

remove_runtime_restore_cron() {
    command -v crontab >/dev/null 2>&1 || return 0
    local temp_cron
    temp_cron=$(mktemp)
    local current_cron
    begin_cron_update || { rm -f "$temp_cron"; return 1; }
    if ! current_cron=$(read_current_crontab); then
        rm -f "$temp_cron"
        release_cron_update
        return 1
    fi
    printf '%s\n' "$current_cron" | filter_runtime_restore_cron_entries > "$temp_cron" || true
    finish_cron_update "$temp_cron"
}

export_notification_functions() {
    export -f setup_telegram_notification_cron
    export -f setup_wecom_notification_cron
    export -f select_notification_interval
}

setup_port_auto_reset_cron() {
    setup_auto_reset_cron
}

setup_auto_reset_cron() {
    local script_path
    script_path=$(get_script_exec_path)
    local temp_cron=$(mktemp)
    local current_cron

    begin_cron_update || { rm -f "$temp_cron"; return 1; }
    if ! current_cron=$(read_current_crontab); then
        rm -f "$temp_cron"
        release_cron_update
        return 1
    fi
    printf '%s\n' "$current_cron" | \
        grep -v "端口流量狗自动重置端口" | \
        grep -v "# port-traffic-dog scheduled reset check" | \
        grep -vE '(^|[[:space:]])[^[:space:]]*port-traffic-dog\.sh[[:space:]]+--reset-port([[:space:]]|$)' | \
        grep -vE '(^|[[:space:]])[^[:space:]]*port-traffic-dog\.sh[[:space:]]+--check-reset-port([[:space:]]|$)' | \
        grep -vE '(^|[[:space:]])[^[:space:]]*port-traffic-dog\.sh[[:space:]]+--check-scheduled-resets([[:space:]]|$)' \
        > "$temp_cron" || true

    local active_ports=()
    mapfile -t active_ports < <(get_active_ports 2>/dev/null || true)
    local has_reset_policy=false
    local port
    for port in "${active_ports[@]}"; do
        if port_has_auto_reset_policy "$port"; then
            ensure_port_next_reset_date "$port" >/dev/null 2>&1 || true
            has_reset_policy=true
        fi
    done
    if [ "$has_reset_policy" = "true" ]; then
        # 每次都按北京时间日期判断，五分钟轮询不依赖 VPS/cron 自身时区。
        echo "*/5 * * * * $script_path --check-scheduled-resets >/dev/null 2>&1  # port-traffic-dog scheduled reset check" >> "$temp_cron"
    fi

    local result=0
    finish_cron_update "$temp_cron" || result=1
    ensure_cron_service_running
    return "$result"
}

refresh_port_auto_reset_cron_from_config() {
    setup_auto_reset_cron
}

refresh_all_cron_from_config() {
    local result=0
    setup_cron_environment
    refresh_port_auto_reset_cron_from_config || result=1
    refresh_notification_cron_from_config || result=1
    setup_traffic_snapshot_cron || result=1
    return "$result"
}

legacy_cron_needs_migration() {
    command -v crontab >/dev/null 2>&1 || return 1
    local cron_content=""
    cron_content=$(read_root_crontab_locked 2>/dev/null) || return 1
    if printf '%s\n' "$cron_content" | grep -Eq \
        'port-traffic-dog(\.sh)?.*--(reset-port|check-reset-port|send-snapshot|create-snapshot)|/etc/port-traffic-dog/data/snapshots'; then
        return 0
    fi
    if has_active_ports &&
       ! printf '%s\n' "$cron_content" | grep -q 'port-traffic-dog.*--restore-runtime'; then
        return 0
    fi
    return 1
}

migrate_legacy_cron_if_needed() {
    if legacy_cron_needs_migration; then
        refresh_all_cron_from_config
    fi
}

remove_port_auto_reset_cron() {
    setup_auto_reset_cron
}

# 格式化状态消息（HTML格式）
format_status_message() {
    local server_name="${1:-$(hostname)}"  # 接受服务器名称参数
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local active_ports=($(get_active_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="🔗 服务器: ${server_name} | ⏰ ${timestamp}
────────────────────────────────────────
状态: 监控中 | 守护端口: ${port_count}个 | 端口总流量: ${daily_total}
────────────────────────────────────────
$(format_port_list "telegram")"

    echo "$message"
}

# 格式化状态消息（纯文本text格式）
format_text_status_message() {
    local server_name="${1:-$(hostname)}"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local active_ports=($(get_active_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="🔗 服务器: ${server_name} | ⏰ ${timestamp}
────────────────────────────────────────
状态: 监控中 | 守护端口: ${port_count}个 | 端口总流量: ${daily_total}
────────────────────────────────────────
$(format_port_list "telegram")"

    echo "$message"
}

# 格式化状态消息（Markdown格式）
format_markdown_status_message() {
    local server_name="${1:-$(hostname)}"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local active_ports=($(get_active_ports))
    local port_count=${#active_ports[@]}
    local daily_total=$(get_daily_total_traffic)

    local message="🔗 **服务器**: ${server_name} | ⏰ ${timestamp}
────────────────────────────────────────
**状态**: 监控中 | **守护端口**: ${port_count}个 | **端口总流量**: ${daily_total}
────────────────────────────────────────
$(format_port_list "telegram")"

    echo "$message"
}

# 记录通知日志
log_notification() {
    local message="$1"
    local timestamp=$(get_beijing_time '+%Y-%m-%d %H:%M:%S')
    local log_file="$CONFIG_DIR/logs/notification.log"

    mkdir -p "$(dirname "$log_file")"

    echo "[$timestamp] $message" >> "$log_file"

    # 日志轮转：防止日志文件过大
    if [ -f "$log_file" ] && [ $(wc -l < "$log_file") -gt 1000 ]; then
        tail -n 500 "$log_file" > "${log_file}.tmp"
        mv "${log_file}.tmp" "$log_file"
    fi
}

# 通用状态通知发送函数
send_status_notification() {
    has_active_ports || return 0

    local success_count=0
    local total_count=0

    # 发送Telegram通知
    if load_telegram_module; then
        total_count=$((total_count + 1))
        if telegram_send_status_notification; then
            success_count=$((success_count + 1))
        fi
    fi

    # 发送企业wx 通知
    local wecom_script="$CONFIG_DIR/notifications/wecom.sh"
    if [ -f "$wecom_script" ]; then
        source "$wecom_script"
        total_count=$((total_count + 1))
        if wecom_send_status_notification; then
            success_count=$((success_count + 1))
        fi
    fi

    if [ $total_count -eq 0 ]; then
        log_notification "通知模块不存在"
        echo -e "${RED}通知模块不存在${NC}"
        return 1
    elif [ $success_count -gt 0 ]; then
        echo -e "${GREEN}状态通知发送成功 ($success_count/$total_count)${NC}"
        return 0
    else
        echo -e "${RED}状态通知发送失败${NC}"
        return 1
    fi
}

self_check() {
    local total=0
    local failed=0
    local warned=0

    check_ok() {
        total=$((total + 1))
        echo -e "${GREEN}[OK]${NC} $1"
    }

    check_warn() {
        total=$((total + 1))
        warned=$((warned + 1))
        echo -e "${YELLOW}[WARN]${NC} $1"
    }

    check_fail() {
        total=$((total + 1))
        failed=$((failed + 1))
        echo -e "${RED}[FAIL]${NC} $1"
    }

    echo -e "${BLUE}=== 端口流量狗 自检 ===${NC}"
    echo

    if [ -f "$CONFIG_FILE" ]; then
        if validate_config_file "$CONFIG_FILE" >/dev/null 2>&1; then
            check_ok "配置文件结构、端口范围与兼容字段有效: $CONFIG_FILE"
        else
            check_fail "配置文件无效或存在重叠端口: $CONFIG_FILE"
        fi
    else
        check_fail "配置文件不存在: $CONFIG_FILE"
    fi

    local invalid_quota_ports=()
    local configured_ports=()
    mapfile -t configured_ports < <(get_active_ports 2>/dev/null || true)
    local configured_port
    for configured_port in "${configured_ports[@]}"; do
        local quota_enabled
        quota_enabled=$(jq -r --arg port "$configured_port" '.ports[$port].quota.enabled // true' "$CONFIG_FILE" 2>/dev/null || echo true)
        local quota_limit
        quota_limit=$(jq -r --arg port "$configured_port" '.ports[$port].quota.monthly_limit // "unlimited"' "$CONFIG_FILE" 2>/dev/null || echo unlimited)
        if [ "$quota_enabled" = "true" ] && [ "$quota_limit" != "unlimited" ]; then
            local quota_bytes
            quota_bytes=$(parse_size_to_bytes "$quota_limit" 2>/dev/null || echo 0)
            if ! [[ "$quota_bytes" =~ ^[0-9]+$ ]] || [ "$quota_bytes" -le 0 ]; then
                invalid_quota_ports+=("$configured_port")
            fi
        fi
    done
    if [ ${#invalid_quota_ports[@]} -eq 0 ]; then
        check_ok "端口配额配置有效"
    else
        check_fail "端口配额配置无效: ${invalid_quota_ports[*]}"
    fi

    local corrupt_stats_files=()
    shopt -s nullglob
    corrupt_stats_files=("${TRAFFIC_STATS_FILE}.corrupt."*)
    shopt -u nullglob
    if [ -f "$TRAFFIC_STATS_FILE" ]; then
        if jq -e 'type == "object" and (.daily | type == "object") and (.last_snapshot | type == "object")' \
            "$TRAFFIC_STATS_FILE" >/dev/null 2>&1; then
            if [ ${#corrupt_stats_files[@]} -gt 0 ]; then
                check_warn "自然日流量统计文件有效，但存在 ${#corrupt_stats_files[@]} 个已隔离的损坏备份"
            else
                check_ok "自然日流量统计文件有效"
            fi
        else
            check_fail "自然日流量统计文件损坏: $TRAFFIC_STATS_FILE"
        fi
    elif [ ${#corrupt_stats_files[@]} -gt 0 ]; then
        check_fail "自然日流量统计文件损坏并已隔离: ${corrupt_stats_files[-1]}"
    else
        check_warn "尚未生成自然日流量统计文件"
    fi

    if [ ${#configured_ports[@]} -gt 0 ]; then
        if [ -f "$TRAFFIC_DATA_FILE" ] && jq -e 'type == "object"' "$TRAFFIC_DATA_FILE" >/dev/null 2>&1; then
            check_ok "流量恢复备份文件有效"
        else
            check_warn "流量恢复备份尚未生成，下一次分钟快照会自动创建"
        fi
    fi

    if command -v nft >/dev/null 2>&1; then
        local invalid_rule_ports=()
        for configured_port in "${configured_ports[@]}"; do
            local billing_mode
            billing_mode=$(jq -r --arg port "$configured_port" '.ports[$port].billing_mode // "double"' "$CONFIG_FILE" 2>/dev/null || echo double)
            local expected_in_count
            expected_in_count=$(get_expected_counter_rule_count "$billing_mode")
            local expected_out_count="$expected_in_count"

            local actual_in_count
            actual_in_count=$(count_counter_rules "$configured_port" in)
            local actual_out_count
            actual_out_count=$(count_counter_rules "$configured_port" out)
            local expected_quota_count=0
            local quota_enabled
            quota_enabled=$(jq -r --arg port "$configured_port" '.ports[$port].quota.enabled // true' "$CONFIG_FILE" 2>/dev/null || echo true)
            local quota_limit
            quota_limit=$(jq -r --arg port "$configured_port" '.ports[$port].quota.monthly_limit // "unlimited"' "$CONFIG_FILE" 2>/dev/null || echo unlimited)
            if [ "$quota_enabled" = "true" ] && [ "$quota_limit" != "unlimited" ]; then
                expected_quota_count=$(get_expected_quota_rule_count "$billing_mode")
            fi
            local actual_quota_count
            actual_quota_count=$(count_quota_rules "$configured_port")
            local quota_limit_matches=true
            if [ "$expected_quota_count" -gt 0 ]; then
                if ! nftables_quota_limit_matches "$configured_port" "$quota_limit"; then
                    quota_limit_matches=false
                fi
            elif ! nftables_quota_is_absent "$configured_port"; then
                quota_limit_matches=false
            fi
            local invalid_order=""
            if [ "$actual_in_count" -eq "$expected_in_count" ] && \
               [ "$actual_out_count" -eq "$expected_out_count" ]; then
                invalid_order=$(get_invalid_counter_order_directions "$configured_port" 2>/dev/null) || invalid_order="unknown"
            fi

            if [ "$actual_in_count" -ne "$expected_in_count" ] || \
               [ "$actual_out_count" -ne "$expected_out_count" ] || \
               [ "$actual_quota_count" -ne "$expected_quota_count" ] || \
               [ "$quota_limit_matches" != "true" ] || \
               [ -n "$invalid_order" ]; then
                invalid_rule_ports+=("$configured_port")
            fi
        done
        if [ ${#invalid_rule_ports[@]} -eq 0 ]; then
            check_ok "流量计数与配额规则完整"
        else
            check_fail "流量计数或配额规则数量、顺序或额度异常: ${invalid_rule_ports[*]}"
        fi

        local orphaned_runtime_objects=""
        local orphan_status=0
        orphaned_runtime_objects=$(list_orphaned_runtime_objects 2>/dev/null) || orphan_status=$?
        if [ "$orphan_status" -ne 0 ]; then
            check_fail "无法核对 nftables 孤儿运行对象"
        elif [ -z "$orphaned_runtime_objects" ]; then
            check_ok "nftables 运行对象与当前端口配置一致"
        else
            check_fail "发现未被当前配置使用的 nftables 对象: $(printf '%s' "$orphaned_runtime_objects" | tr '\n' ' ')"
        fi

        local inconsistent_usage_ports=()
        for configured_port in "${configured_ports[@]}"; do
            if ! port_counter_quota_usage_consistent "$configured_port"; then
                inconsistent_usage_ports+=("$configured_port")
            fi
        done
        if [ ${#inconsistent_usage_ports[@]} -eq 0 ]; then
            check_ok "流量 counter 与 quota 当前周期用量一致"
        else
            check_fail "流量 counter 与 quota 当前周期用量不一致: ${inconsistent_usage_ports[*]}"
        fi

        local invalid_tc_ports=()
        for configured_port in "${configured_ports[@]}"; do
            local limit_enabled
            local rate_limit
            limit_enabled=$(jq -r --arg port "$configured_port" '.ports[$port].bandwidth_limit.enabled // false' "$CONFIG_FILE")
            rate_limit=$(jq -r --arg port "$configured_port" '.ports[$port].bandwidth_limit.rate // "unlimited"' "$CONFIG_FILE")
            if [ "$limit_enabled" = "true" ] && [ "$rate_limit" != "unlimited" ] &&
               ! tc_limit_runtime_complete "$configured_port"; then
                invalid_tc_ports+=("$configured_port")
            fi
        done
        if [ ${#invalid_tc_ports[@]} -eq 0 ]; then
            check_ok "带宽限制运行状态有效"
        else
            check_fail "带宽限制规则不完整: ${invalid_tc_ports[*]}"
        fi

        local self_tc_interface
        local ntc_rate=""
        local ntc_state_status=0
        self_tc_interface=$(get_default_interface 2>/dev/null || true)
        if [ -z "$self_tc_interface" ]; then
            check_fail "无法确定统一HTB使用的默认网卡"
        else
            ntc_rate=$(trafficcop_unified_state_rate "$self_tc_interface" 2>/dev/null) || ntc_state_status=$?
            case "$ntc_state_status" in
                0)
                    if tc_root_is_managed "$self_tc_interface" &&
                       tc_class_rate_matches "$self_tc_interface" "1:1" "$ntc_rate" &&
                       tc_class_rate_matches "$self_tc_interface" "1:30" "$TC_DEFAULT_CLASS_RATE" "$ntc_rate"; then
                        check_ok "TrafficCop整机上限优先，父类与Dog端口子类共用统一HTB"
                    else
                        check_fail "TrafficCop统一状态与1:1/1:30运行层级不一致"
                    fi
                    ;;
                1|4)
                    check_ok "当前网卡没有TrafficCop整机限速状态"
                    ;;
                3)
                    local legacy_qdisc
                    legacy_qdisc=$(tc_root_qdisc_line "$self_tc_interface" 2>/dev/null || true)
                    if trafficcop_legacy_tbf_rate "$self_tc_interface" "$legacy_qdisc" >/dev/null 2>&1; then
                        check_warn "检测到TrafficCop旧TBF；启用Dog端口限速时会安全迁移为统一HTB"
                    elif tc_root_is_owned "$self_tc_interface" &&
                         desired_tc_parent_rate "$self_tc_interface" >/dev/null 2>&1; then
                        check_warn "TrafficCop仍是旧状态格式，统一HTB已迁移，请让NTC重新应用整机限速以升级状态"
                    else
                        check_fail "TrafficCop旧TC状态与当前root qdisc不一致"
                    fi
                    ;;
                *)
                    check_fail "TrafficCop TC状态文件格式、归属或权限无效"
                    ;;
            esac
        fi
    else
        check_warn "nft 命令不可用，跳过流量规则核对"
    fi

    if command -v crontab >/dev/null 2>&1; then
        local cron_content
        cron_content=$(read_root_crontab_locked 2>/dev/null || true)
        local expected_reset_count=0
        local has_reset_policy=false
        local cron_matches_config=true
        for configured_port in "${configured_ports[@]}"; do
            if port_has_auto_reset_policy "$configured_port"; then
                has_reset_policy=true
            fi
        done
        if [ "$has_reset_policy" = "true" ]; then
            expected_reset_count=1
            if ! printf '%s\n' "$cron_content" | grep -Eq '^\*/5[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+.*port-traffic-dog\.sh[[:space:]]+--check-scheduled-resets([[:space:]]|$)'; then
                cron_matches_config=false
            fi
        fi

        local actual_reset_count
        actual_reset_count=$(printf '%s\n' "$cron_content" | grep -Ec 'port-traffic-dog\.sh[[:space:]]+--(reset-port|check-reset-port|check-scheduled-resets)' || true)
        local actual_snapshot_count
        actual_snapshot_count=$(printf '%s\n' "$cron_content" | grep -Ec 'port-traffic-dog\.sh[[:space:]]+--snapshot-traffic' || true)
        local actual_telegram_count
        actual_telegram_count=$(printf '%s\n' "$cron_content" | grep -Ec 'port-traffic-dog\.sh[[:space:]]+--send-telegram-status' || true)
        local actual_wecom_count
        actual_wecom_count=$(printf '%s\n' "$cron_content" | grep -Ec 'port-traffic-dog\.sh[[:space:]]+--send-wecom-status' || true)
        local actual_restore_count
        actual_restore_count=$(printf '%s\n' "$cron_content" | grep -Ec 'port-traffic-dog\.sh[[:space:]]+--restore-runtime' || true)

        local expected_snapshot_count=0
        local expected_telegram_count=0
        local expected_wecom_count=0
        local expected_restore_count=1
        if ! printf '%s\n' "$cron_content" | grep -Eq '^@reboot[[:space:]]+.*port-traffic-dog\.sh[[:space:]]+--restore-runtime([[:space:]]|$)'; then
            cron_matches_config=false
        fi
        if [ ${#configured_ports[@]} -gt 0 ]; then
            expected_snapshot_count=1
            if ! printf '%s\n' "$cron_content" | grep -Eq '^\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+.*port-traffic-dog\.sh[[:space:]]+--snapshot-traffic([[:space:]]|$)'; then
                cron_matches_config=false
            fi
            if [ "$(jq -r '.notifications.telegram.enabled // false' "$CONFIG_FILE" 2>/dev/null || echo false)" = "true" ] &&
               [ "$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE" 2>/dev/null || echo false)" = "true" ]; then
                expected_telegram_count=1
                local telegram_interval
                local telegram_schedule
                telegram_interval=$(jq -r '.notifications.telegram.status_notifications.interval // "1h"' "$CONFIG_FILE")
                telegram_schedule=$(notification_interval_cron_expression "$telegram_interval" 2>/dev/null || true)
                if [ -z "$telegram_schedule" ] ||
                   ! printf '%s\n' "$cron_content" | awk -v schedule="$telegram_schedule " '
                       index($0, schedule) == 1 && /port-traffic-dog\.sh[[:space:]]+--send-telegram-status/ { found=1 }
                       END { exit found ? 0 : 1 }
                   '; then
                    cron_matches_config=false
                fi
            fi
            if [ "$(jq -r '.notifications.wecom.enabled // false' "$CONFIG_FILE" 2>/dev/null || echo false)" = "true" ] &&
               [ "$(jq -r '.notifications.wecom.status_notifications.enabled // false' "$CONFIG_FILE" 2>/dev/null || echo false)" = "true" ]; then
                expected_wecom_count=1
                local wecom_interval
                local wecom_schedule
                wecom_interval=$(jq -r '.notifications.wecom.status_notifications.interval // "1h"' "$CONFIG_FILE")
                wecom_schedule=$(notification_interval_cron_expression "$wecom_interval" 2>/dev/null || true)
                if [ -z "$wecom_schedule" ] ||
                   ! printf '%s\n' "$cron_content" | awk -v schedule="$wecom_schedule " '
                       index($0, schedule) == 1 && /port-traffic-dog\.sh[[:space:]]+--send-wecom-status/ { found=1 }
                       END { exit found ? 0 : 1 }
                   '; then
                    cron_matches_config=false
                fi
            fi
        fi

        if [ "$actual_reset_count" -ne "$expected_reset_count" ] || \
           [ "$actual_snapshot_count" -ne "$expected_snapshot_count" ] || \
           [ "$actual_telegram_count" -ne "$expected_telegram_count" ] || \
           [ "$actual_wecom_count" -ne "$expected_wecom_count" ] || \
           [ "$actual_restore_count" -ne "$expected_restore_count" ]; then
            cron_matches_config=false
        fi

        if [ "$cron_matches_config" = "true" ]; then
            check_ok "定时任务与当前配置一致"
        else
            check_fail "定时任务与当前配置不一致（重置 ${actual_reset_count}/${expected_reset_count}，快照 ${actual_snapshot_count}/${expected_snapshot_count}，恢复 ${actual_restore_count}/${expected_restore_count}，Telegram ${actual_telegram_count}/${expected_telegram_count}，企业微信 ${actual_wecom_count}/${expected_wecom_count}）"
        fi
    else
        check_warn "crontab 命令不可用，跳过定时任务核对"
    fi

    if [ -f "$INSTALLED_SCRIPT_PATH" ]; then
        check_ok "主脚本安装路径存在: $INSTALLED_SCRIPT_PATH"
    else
        check_warn "主脚本安装路径不存在，当前使用: $SCRIPT_PATH"
    fi

    local dep_tools=("nft" "tc" "ss" "jq" "awk" "bc" "unzip" "cron" "curl" "conntrack" "flock")
    local missing_dep=()
    local dep
    for dep in "${dep_tools[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_dep+=("$dep")
        fi
    done
    if [ ${#missing_dep[@]} -eq 0 ]; then
        check_ok "依赖命令完整"
    else
        check_fail "缺少依赖命令: ${missing_dep[*]}"
    fi

    local telegram_script="$CONFIG_DIR/notifications/telegram.sh"
    local wecom_script="$CONFIG_DIR/notifications/wecom.sh"
    if [ -f "$telegram_script" ] && [ -f "$wecom_script" ]; then
        check_ok "通知模块文件存在"
    else
        check_fail "通知模块缺失(telegram.sh 或 wecom.sh)"
    fi

    if load_telegram_module; then
        if declare -F send_telegram_message >/dev/null 2>&1 && declare -F telegram_send_status_notification >/dev/null 2>&1; then
            check_ok "Telegram模块函数完整"
        else
            check_fail "Telegram模块函数不完整"
        fi
    else
        check_fail "Telegram模块加载失败"
    fi

    local telegram_route
    local telegram_custom_base
    telegram_route=$(jq -r '.notifications.telegram.api_route // "official"' "$CONFIG_FILE" 2>/dev/null || echo official)
    telegram_custom_base=$(jq -r '.notifications.telegram.custom_api_base // ""' "$CONFIG_FILE" 2>/dev/null || true)
    telegram_custom_base="${telegram_custom_base%/}"
    if [ "$telegram_route" = "custom" ] && declare -F telegram_api_base_is_secure >/dev/null 2>&1 &&
       ! telegram_api_base_is_secure "$telegram_custom_base"; then
        check_warn "Telegram自定义线路不安全，当前已自动回退官方 HTTPS 线路"
    fi

    local telegram_enabled
    telegram_enabled=$(jq -r '.notifications.telegram.enabled // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
    local bot_token
    bot_token=$(jq -r '.notifications.telegram.bot_token // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ "$telegram_enabled" = "true" ] && [ -n "$bot_token" ] && [ "$bot_token" != "null" ]; then
        local api_base
        api_base=$(get_telegram_api_base 2>/dev/null || echo "https://api.telegram.org")
        local getme_url
        if [[ "$api_base" =~ /bot$ ]]; then
            getme_url="${api_base}${bot_token}/getMe"
        else
            getme_url="${api_base}/bot${bot_token}/getMe"
        fi
        local getme_resp
        getme_resp=$(curl -sS --connect-timeout 5 --max-time 12 "$getme_url" 2>/dev/null || true)
        if echo "$getme_resp" | grep -q '"ok":true'; then
            check_ok "Telegram线路与Token可用(getMe通过)"
        else
            local err_desc
            err_desc=$(echo "$getme_resp" | jq -r '.description // empty' 2>/dev/null || true)
            if [ -z "$err_desc" ]; then
                err_desc=$(echo "$getme_resp" | tr '\n' ' ' | cut -c1-160)
            fi
            check_warn "Telegram连通性异常: ${err_desc:-无响应}"
        fi
    else
        check_warn "Telegram未启用或Token为空，跳过连通性检测"
    fi

    echo
    echo "自检汇总: 总计 ${total} 项 | 失败 ${failed} 项 | 警告 ${warned} 项"
    if [ "$failed" -eq 0 ]; then
        echo -e "${GREEN}自检完成：可用${NC}"
        return 0
    fi
    echo -e "${RED}自检完成：存在失败项，请先修复${NC}"
    return 1
}

system_check_and_repair() {
    clear 2>/dev/null || true
    echo -e "${BLUE}=== 系统自检/修复 ===${NC}"
    echo

    echo -e "${YELLOW}[1/6] 检查依赖、权限和本地配置...${NC}"
    check_dependencies true
    if ! init_config; then
        echo -e "${RED}本地配置无效，无法继续自动修复${NC}"
        return 1
    fi
    setup_script_permissions
    setup_cron_environment
    create_shortcut_command >/dev/null
    install_tc_recovery_service_files >/dev/null 2>&1 || true
    echo -e "${GREEN}基础运行环境已就绪${NC}"

    echo -e "${YELLOW}[2/6] 检查通知模块...${NC}"
    if download_notification_modules >/dev/null 2>&1; then
        echo -e "${GREEN}通知模块已就绪${NC}"
    else
        echo -e "${YELLOW}通知模块补齐失败，将在自检结果中显示${NC}"
    fi

    echo -e "${YELLOW}[3/6] 重建端口重置和通知定时任务...${NC}"
    refresh_all_cron_from_config
    echo -e "${GREEN}定时任务已按当前配置刷新${NC}"

    echo -e "${YELLOW}[4/6] 检查并修复流量与配额规则...${NC}"
    local repaired_count
    if repaired_count=$(repair_duplicate_traffic_rules 2>/dev/null); then
        echo -e "${GREEN}流量规则检查完成，修复端口数: ${repaired_count}${NC}"
    else
        echo -e "${RED}流量规则修复失败，将在最终自检中显示异常端口${NC}"
    fi
    if restore_runtime_state >/dev/null 2>&1; then
        echo -e "${GREEN}nftables 与 TC 运行状态已按当前配置恢复${NC}"
    else
        echo -e "${RED}运行状态恢复失败，将在最终自检中显示异常端口${NC}"
    fi

    echo -e "${YELLOW}[5/6] 更新自然日流量快照...${NC}"
    if record_traffic_snapshot >/dev/null 2>&1; then
        echo -e "${GREEN}流量快照已更新${NC}"
    else
        echo -e "${YELLOW}流量快照更新失败，将保留现有统计数据${NC}"
    fi

    echo
    echo -e "${YELLOW}[6/6] 执行最终自检...${NC}"
    if self_check; then
        echo -e "${GREEN}系统自检/修复完成${NC}"
    else
        echo -e "${YELLOW}修复后仍有异常，请根据上方 FAIL/WARN 处理${NC}"
    fi

    echo
    read -r -p "按回车键返回主菜单..."
    show_main_menu
}

main() {
    check_root

    # cron 快速路径：跳过重型初始化（依赖检查、通知模块下载、规则恢复等）
    if [ $# -gt 0 ]; then
        case $1 in
            --version)
                echo -e "${BLUE}$SCRIPT_NAME v$SCRIPT_VERSION${NC}"
                exit 0
                ;;
            --reset-port)
                if [ $# -lt 2 ]; then
                    echo -e "${RED}错误：--reset-port 需要指定端口号${NC}"
                    exit 1
                fi
                local reset_status=0
                auto_reset_port "$2" || reset_status=$?
                exit "$reset_status"
                ;;
            --check-reset-port)
                if [ $# -lt 2 ]; then
                    echo -e "${RED}错误：--check-reset-port 需要指定端口号${NC}"
                    exit 1
                fi
                local reset_check_status=0
                check_reset_port_due "$2" || reset_check_status=$?
                exit "$reset_check_status"
                ;;
            --check-scheduled-resets)
                local scheduled_reset_status=0
                check_scheduled_resets || scheduled_reset_status=$?
                exit "$scheduled_reset_status"
                ;;
            --restore-runtime)
                [ -f "$CONFIG_FILE" ] || exit 0
                validate_config_file "$CONFIG_FILE" >/dev/null || exit 1
                restore_runtime_state
                exit $?
                ;;
            --tc-status)
                [ -f "$CONFIG_FILE" ] || {
                    echo "TC_STATUS=ERROR REASON=config-missing"
                    exit 1
                }
                validate_config_file "$CONFIG_FILE" >/dev/null || exit 1
                local tc_status=0
                dog_tc_status || tc_status=$?
                exit "$tc_status"
                ;;
            --recover-tc)
                [ -f "$CONFIG_FILE" ] || exit 0
                local recovery_status=0
                recover_tc_runtime "${2:---manual}" || recovery_status=$?
                exit "$recovery_status"
                ;;
            --snapshot-traffic)
                if ! has_active_ports; then
                    remove_traffic_snapshot_cron >/dev/null 2>&1 || true
                    exit 0
                fi
                if ! runtime_counter_objects_complete; then
                    restore_runtime_state >/dev/null 2>&1 || exit 1
                fi
                record_traffic_snapshot >/dev/null 2>&1
                exit $?
                ;;
            --send-telegram-status)
                if ! has_active_ports; then
                    remove_telegram_notification_cron >/dev/null 2>&1 || true
                    exit 0
                fi
                load_telegram_module || exit 1
                local telegram_status=0
                telegram_send_status_notification || telegram_status=$?
                exit "$telegram_status"
                ;;
            --send-wecom-status)
                if ! has_active_ports; then
                    remove_wecom_notification_cron >/dev/null 2>&1 || true
                    exit 0
                fi
                local wecom_script="$CONFIG_DIR/notifications/wecom.sh"
                [ -f "$wecom_script" ] || exit 1
                source "$wecom_script" || exit 1
                declare -F wecom_send_status_notification >/dev/null || exit 1
                local wecom_status=0
                wecom_send_status_notification || wecom_status=$?
                exit "$wecom_status"
                ;;
            --send-status)
                has_active_ports || exit 0
                local notification_status=0
                send_status_notification || notification_status=$?
                exit "$notification_status"
                ;;
        esac
    fi

    if [ $# -gt 0 ]; then
        case $1 in
            --validate-config)
                [ $# -eq 2 ] && validate_config_file "$2"
                exit $?
                ;;
            --check-deps)
                check_dependencies
                exit 0
                ;;
            --finalize-update)
                local finalize_status=0
                finalize_script_update || finalize_status=$?
                exit "$finalize_status"
                ;;
            --install)
                local install_status=0
                install_update_script false || install_status=$?
                exit "$install_status"
                ;;
            --uninstall)
                uninstall_script
                exit 0
                ;;
            --self-check)
                self_check
                exit $?
                ;;
            --sync-notification-modules)
                mkdir -p "$CONFIG_DIR"
                echo -e "${YELLOW}正在强制同步通知模块...${NC}"
                if download_notification_modules "force"; then
                    echo -e "${GREEN}通知模块强制同步完成${NC}"
                    exit 0
                else
                    echo -e "${RED}通知模块同步失败，请检查网络后重试${NC}"
                    exit 1
                fi
                ;;
            --refresh-notification-cron)
                check_dependencies true
                init_config || exit 1
                refresh_notification_cron_from_config || exit 1
                echo -e "${GREEN}通知定时任务已刷新${NC}"
                exit 0
                ;;
            --refresh-port-reset-cron)
                check_dependencies true
                init_config || exit 1
                setup_cron_environment
                refresh_port_auto_reset_cron_from_config || exit 1
                ensure_cron_service_running
                echo -e "${GREEN}端口自动重置定时任务已刷新${NC}"
                exit 0
                ;;
            --refresh-all-cron)
                check_dependencies true
                init_config || exit 1
                refresh_all_cron_from_config || exit 1
                echo -e "${GREEN}全部定时任务已按当前配置刷新${NC}"
                exit 0
                ;;
            --repair-traffic-rules)
                check_dependencies true
                init_config || exit 1
                if reconcile_orphaned_runtime_objects &&
                   repaired_count=$(repair_duplicate_traffic_rules 2>/dev/null); then
                    echo -e "${GREEN}流量计数/配额规则检查完成，修复端口数: ${repaired_count}${NC}"
                    exit 0
                fi
                echo -e "${RED}流量计数/配额规则修复失败，请运行 --self-check 查看异常端口${NC}"
                exit 1
                ;;
            *)
                echo -e "${YELLOW}用法: $0 [选项]${NC}"
                echo "选项:"
                echo "  --check-deps              检查依赖工具"
                echo "  --version                 显示版本信息"
                echo "  --install                 安装/更新脚本"
                echo "  --finalize-update         执行更新后的配置和运行状态迁移"
                echo "  --uninstall               卸载脚本"
                echo "  --send-status             发送所有启用的状态通知"
                echo "  --send-telegram-status    发送Telegram状态通知"
                echo "  --send-wecom-status       发送企业wx 状态通知"
                echo "  --self-check              执行一键自检"
                echo "  --tc-status               检查 Dog/NTC TC 运行状态"
                echo "  --recover-tc [--auto|--manual]  由共享恢复入口重建统一 HTB"
                echo "  --validate-config FILE    只校验指定配置文件"
                echo "  --sync-notification-modules  强制同步通知模块(覆盖本地)"
                echo "  --refresh-notification-cron  刷新通知定时任务并拉起cron服务"
                echo "  --refresh-port-reset-cron    刷新端口自动重置定时任务"
                echo "  --refresh-all-cron           刷新全部定时任务并清理旧任务"
                echo "  --repair-traffic-rules  按计费模式修复流量计数/配额规则"
                echo "  --snapshot-traffic       写入自然日流量快照"
                echo "  --restore-runtime        恢复 nftables/TC 运行状态"
                echo "  --reset-port PORT         重置指定端口流量"
                echo "  --check-reset-port PORT   检查指定端口是否到期重置"
                echo "  --check-scheduled-resets  检查所有端口是否到期重置"
                echo
                echo -e "${GREEN}快捷命令: $SHORTCUT_COMMAND${NC}"
                exit 1
                ;;
        esac
    fi

    # 普通菜单只做本地轻量初始化；重型修复由菜单 8 主动执行。
    check_dependencies true
    init_config || exit 1
    ensure_installation_files
    migrate_legacy_cron_if_needed
    show_main_menu
}

main "$@"
