# ── 通用工具 ──────────────────────────────────────────────────────

beijing_date() {
    TZ="$DOG_TZ" date "$@"
}

get_current_date() {
    beijing_date +%Y-%m-%d
}

get_script_exec_path() {
    if [ -f "$INSTALLED_SCRIPT_PATH" ]; then
        echo "$INSTALLED_SCRIPT_PATH"
    else
        echo "$SCRIPT_PATH"
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本需要 root 权限运行${NC}" >&2
        exit 1
    fi
}

is_interactive() {
    [ "$DOG_NONINTERACTIVE" != "true" ] && [ -t 0 ]
}

# 询问 y/N；非交互模式（--yes）直接同意。
confirm() {
    local prompt="$1" answer=""
    [ "$DOG_NONINTERACTIVE" = "true" ] && return 0
    read -r -p "$prompt [y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}

pause() {
    is_interactive || return 0
    read -r -p "按回车继续..." _ || true
}

get_network_interfaces() {
    ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -vx 'lo' || true
}

get_default_interface() {
    local dev
    dev=$(ip -o route show default 2>/dev/null |
        awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [ -n "$dev" ] || dev=$(ip -o -6 route show default 2>/dev/null |
        awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [ -n "$dev" ] || dev=$(get_network_interfaces | head -n1)
    if [ -z "$dev" ]; then
        # 不能猜网卡名：猜错会在错误的设备上重建 HTB。
        echo "无法确定默认出口网卡，已中止 TC 相关操作" >&2
        return 1
    fi
    echo "$dev"
}

# 字节数格式化为二进制单位（KB/MB/GB/TB，1024 进制，保留两位小数）。
format_bytes() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB PB", u, " "); i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%dB\n", b; else printf "%.2f%s\n", b, u[i]
    }'
}

# "240GB" / "1.5T" / "500M" / "800KB" → 字节；无法解析返回 1。
parse_size_to_bytes() {
    local s="${1^^}"
    s="${s// /}"
    [[ "$s" =~ ^([0-9]+(\.[0-9]+)?)(K|KB|M|MB|G|GB|T|TB)$ ]] || return 1
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[3]:0:1}" pow
    case "$unit" in K) pow=1 ;; M) pow=2 ;; G) pow=3 ;; T) pow=4 ;; esac
    awk -v n="$num" -v p="$pow" 'BEGIN { v = n * (1024 ^ p); printf "%.0f\n", v - (v % 1) }'
}

validate_quota() {
    local bytes
    bytes=$(parse_size_to_bytes "$1") || return 1
    [ "$bytes" -gt 0 ]
}

# 带宽：0 或 数字+kbps/mbps/gbps（不区分大小写）。
validate_bandwidth() {
    local v="${1,,}"
    [ "$v" = "0" ] || [[ "$v" =~ ^[1-9][0-9]*(kbps|mbps|gbps)$ ]]
}

# 用户输入的带宽（100Mbps）→ tc 速率（100mbit）。
convert_bandwidth_to_tc() {
    local v="${1,,}"
    case "$v" in
        *kbps) echo "${v%kbps}kbit" ;;
        *mbps) echo "${v%mbps}mbit" ;;
        *gbps) echo "${v%gbps}gbit" ;;
        *) return 1 ;;
    esac
}

# tc 速率（100mbit）→ 显示用（100Mbps）。
format_tc_rate() {
    case "$1" in
        *kbit) echo "${1%kbit}Kbps" ;;
        *mbit) echo "${1%mbit}Mbps" ;;
        *gbit) echo "${1%gbit}Gbps" ;;
        *) echo "$1" ;;
    esac
}

validate_day_1_31() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 31 ]
}

validate_month_1_12() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 12 ]
}

# 解析菜单多选输入 "1,3,5" → 去重后的合法序号数组（nameref）。
parse_multi_choice_input() {
    local input="$1" max_choice="$2"
    local -n _pmc_out=$3
    local choice
    _pmc_out=()
    IFS=',' read -ra _pmc_items <<< "$input"
    for choice in "${_pmc_items[@]}"; do
        choice="${choice//[[:space:]]/}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$max_choice" ]; then
            [[ " ${_pmc_out[*]} " == *" $choice "* ]] || _pmc_out+=("$choice")
        elif [ -n "$choice" ]; then
            echo -e "${RED}无效选择: $choice${NC}" >&2
        fi
    done
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
    beijing_date +%Y-%m-%d
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

    local -a parts; read -ra parts <<< "$(date_parts "$date_value")"
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

days_before_year() {
    local year="$1"
    local previous_year=$((year - 1))
    echo $((365 * previous_year + previous_year / 4 - previous_year / 100 + previous_year / 400))
}

date_to_ordinal() {
    local date_value="$1"
    is_valid_date "$date_value" || return 1
    local -a parts; read -ra parts <<< "$(date_parts "$date_value")"
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
    local -a parts; read -ra parts <<< "$(date_parts "$date_value")"
    local year="${parts[0]}"
    local month="${parts[1]}"
    local day="${parts[2]}"

    if [ -n "$desired_day" ]; then
        day="$desired_day"
    fi

    local -a normalized; read -ra normalized <<< "$(normalize_year_month "$year" "$((month + months))")"
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
    local -a parts; read -ra parts <<< "$(date_parts "$date_value")"
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
