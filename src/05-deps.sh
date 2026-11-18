# 依赖账本独立于配置；保留现有软件包的归属，不自动认领旧安装。
# 2.0 起不再使用 bc、unzip、conntrack；此前由 Dog 安装并记入账本的仍可用 --dependencies remove 卸载。
dependency_manifest() {
    cat <<'PACKAGES'
nftables|nft|防火墙与流量统计
iproute2|ip tc ss|连接、网卡与限速
jq|jq|配置处理
mawk|awk|文本处理（任意可用 awk 均可）
cron|cron crontab|定时任务
curl|curl|下载与通知
util-linux|flock|并发锁
procps|pgrep|守护进程状态检测
kmod|modprobe|IFB 内核模块加载
ca-certificates|@ca-certificates|HTTPS 证书
PACKAGES
    if [ "${1:-all}" = all ]; then
        printf '%s\n' 'python3|python3|IP Guard 准入引擎' 'libnetfilter-queue1|@nfqueue|IP Guard 首 SYN 准入运行库'
    fi
}

dependency_peer_uses_package() {
    [ -f /etc/trafficcop-lite/trafficcop-lite-monitor.sh ] ||
        [ -f /etc/trafficcop-lite/trafficcop-lite.sh ] || [ -e /usr/local/bin/ntc ] || return 1
    # 保守保留可能的传递依赖，只允许移除明确属于 Dog 的非共享项。
    case "${1%%:*}" in nftables|conntrack|unzip|libnetfilter-queue1) return 1 ;; *) return 0 ;; esac
}

dependency_removal_is_safe() {
    if [ -e "$INSTALLED_SCRIPT_PATH" ] || [ -e "$CONFIG_FILE" ] || [ -e "$IP_GUARD_SERVICE_FILE" ]; then
        dependency_error 'Dog 或 IP Guard 仍已安装；请先卸载脚本，再用下载的脚本执行 --dependencies remove。'
        return 1
    fi
}

dependency_audit() {
    [ ! -d "$CONFIG_DIR" ] || dog_log_event "$@"
    return 0
}

# BEGIN MANAGED DEPENDENCIES
# Adapted from easy_Caddy 843e7b4; embedded so standalone installs need no helper file.
dependency_error() { printf '依赖管理：%s\n' "$*" >&2; }

dependency_package_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9-]+)?$ ]]; }

dependency_installed() {
    local state
    state=$(dpkg-query -W -f='${db:Status-Status}\n' -- "$1" 2>/dev/null) || return 1
    [ "$state" = installed ]
}

dependency_tools_available() {
    local package="$1" tools="$2" tool
    if [ -z "$tools" ]; then dependency_installed "$package"; return; fi
    for tool in $tools; do
        case "$tool" in
            @ca-certificates)
                [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -s /etc/ssl/cert.pem ] || return 1
                ;;
            @nfqueue)
                command -v python3 >/dev/null 2>&1 || return 3
                python3 -c 'import ctypes; ctypes.CDLL("libnetfilter_queue.so.1")' >/dev/null 2>&1 || return 1
                ;;
            *) command -v "$tool" >/dev/null 2>&1 || return 1 ;;
        esac
    done
}

dependency_portable_report() {
    local package tools description status missing=0
    printf '依赖检测（当前平台；包账本安装/卸载仅支持 Debian/Ubuntu）：\n'
    while IFS='|' read -r package tools description; do
        [ -n "$package" ] || continue
        status=0
        if [ -z "$tools" ]; then
            [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -s /etc/ssl/cert.pem ] || status=1
        else dependency_tools_available "$package" "$tools" || status=$?; fi
        if [ "$status" -eq 0 ]; then printf '  [可用] %s\n' "$package"
        else printf '  [缺失] %s：%s\n' "$package" "$description"; DEPENDENCY_MISSING_PACKAGES+=("$package"); missing=1; fi
    done < <(dependency_manifest "${1:-all}")
    return "$missing"
}

dependency_report() {
    local profile="${1:-all}" package tools description status broken=0
    DEPENDENCY_MISSING_PACKAGES=()
    command -v dpkg-query >/dev/null 2>&1 || { dependency_portable_report "$profile"; return $?; }
    printf '依赖检测（命令与运行库实际可用性）：\n'
    dependency_no_pending || broken=1
    while IFS='|' read -r package tools description; do
        [ -n "$package" ] || continue
        status=0
        dependency_tools_available "$package" "$tools" || status=$?
        if [ "$status" -eq 0 ]; then
            printf '  [可用] %s%s\n' "$package" "${description:+：$description}"
        elif [ "$status" -eq 3 ] && dependency_installed "$package"; then
            printf '  [待复检] %s：先安装 Python 3，再验证运行库。\n' "$package"
        elif dependency_installed "$package"; then
            printf '  [异常] %s：包已安装，但命令或运行库不可用；请检查 PATH 或修复软件包。\n' "$package"
            broken=1
        else
            printf '  [缺失] %s%s\n' "$package" "${description:+：$description}"
            DEPENDENCY_MISSING_PACKAGES+=("$package")
        fi
    done < <(dependency_manifest "$profile")
    [ "$broken" -eq 0 ] || return 2
    [ "${#DEPENDENCY_MISSING_PACKAGES[@]}" -eq 0 ]
}

dependency_safe_record() {
    local mode
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u -- "$1")" = 0 ] || return 1
    mode=$(stat -c %a -- "$1") || return 1
    (( (8#$mode & 0022) == 0 ))
}

dependency_prepare_state() {
    local part current='' mode file
    [ "$EUID" -eq 0 ] || { dependency_error '安装或卸载需要 root。'; return 1; }
    command -v apt-get >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || {
        dependency_error '需要 apt-get 和 flock；请先确认系统包管理器及基础工具。'; return 1;
    }
    [[ "$DEPENDENCY_STATE_DIR" == /* && "$DEPENDENCY_STATE_DIR" != / ]] || return 1
    local -a parts=()
    IFS=/ read -r -a parts <<< "$DEPENDENCY_STATE_DIR"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        case "$part" in .|..) return 1 ;; esac
        current+="/$part"
        [ ! -L "$current" ] || { dependency_error '依赖状态路径包含符号链接，已拒绝。'; return 1; }
    done
    if [ -e "$DEPENDENCY_STATE_DIR" ]; then
        [ -d "$DEPENDENCY_STATE_DIR" ] && [ "$(stat -c %u -- "$DEPENDENCY_STATE_DIR")" = 0 ] || return 1
        mode=$(stat -c %a -- "$DEPENDENCY_STATE_DIR") || return 1
        (( (8#$mode & 0022) == 0 )) || { dependency_error '依赖目录可被其他用户写入，已拒绝。'; return 1; }
    else
        mkdir -p -- "$DEPENDENCY_STATE_DIR" || return 1
    fi
    chmod 700 -- "$DEPENDENCY_STATE_DIR" || return 1
    for file in installed-packages pending-before pending-plan lock; do
        if [ -e "$DEPENDENCY_STATE_DIR/$file" ] || [ -L "$DEPENDENCY_STATE_DIR/$file" ]; then
            dependency_safe_record "$DEPENDENCY_STATE_DIR/$file" || { dependency_error "不安全的依赖记录：$file"; return 1; }
        fi
    done
}

dependency_read_owned() {
    local package path="$DEPENDENCY_STATE_DIR/installed-packages"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then return 0; fi
    dependency_safe_record "$path" || { dependency_error '新增包账本不是安全的普通文件。'; return 1; }
    while IFS= read -r package || [ -n "$package" ]; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || { dependency_error '新增包账本含无效包名。'; return 1; }
        printf '%s\n' "$package"
    done < "$path"
}

dependency_snapshot() {
    local rows
    rows=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${Essential}\t${Protected}\n') || return 1
    printf '%s\n' "$rows" | awk -F '\t' -v phase="${2:-after}" '
        (phase == "before" && $2 != "not-installed") || (phase == "after" && $2 == "installed") ||
        (phase == "incomplete" && $2 ~ /^(unpacked|half-installed|half-configured|triggers-awaited|triggers-pending)$/) {print $1}
    ' | LC_ALL=C sort -u > "$1" || return 1
    chmod 600 -- "$1"
}

dependency_save_owned() {
    local stage
    stage=$(mktemp "$DEPENDENCY_STATE_DIR/.owned.XXXXXX") || return 1
    if ! LC_ALL=C sort -u -- "$1" > "$stage" || ! chmod 600 -- "$stage" ||
       ! mv -f -- "$stage" "$DEPENDENCY_STATE_DIR/installed-packages"; then
        rm -f -- "$stage"
        dependency_error '新增包账本保存失败，事务快照已保留。'
        return 1
    fi
}

dependency_no_pending() {
    if [ -e "$DEPENDENCY_STATE_DIR/pending-before" ] || [ -L "$DEPENDENCY_STATE_DIR/pending-before" ] ||
       [ -e "$DEPENDENCY_STATE_DIR/pending-plan" ] || [ -L "$DEPENDENCY_STATE_DIR/pending-plan" ]; then
        dependency_error "发现未完成安装事务；请核对 $DEPENDENCY_STATE_DIR 的 pending-before/pending-plan，本次不自动认领或卸载。"
        return 1
    fi
}

dependency_install_missing() (
    umask 077
    local assume_yes="${1:-false}" profile="${2:-all}" status=0 answer stage plan owned package rc=0 lock_fd incomplete=false
    dependency_report "$profile" || status=$?
    [ "$status" -ne 2 ] || return 1
    [ "${#DEPENDENCY_MISSING_PACKAGES[@]}" -gt 0 ] || { printf '依赖全部可用，无需安装；原有包不会记为新增。\n'; return 0; }
    printf '仅安装缺失项：\n'; printf '  %s\n' "${DEPENDENCY_MISSING_PACKAGES[@]}"
    if [ "$assume_yes" != true ]; then
        read -r -p '确认安装？[y/yes，默认 n]：' answer || return 1
        case "${answer,,}" in y|yes) ;; *) printf '安装已取消。\n'; return 1 ;; esac
    fi
    dependency_prepare_state || return 1
    exec {lock_fd}> "$DEPENDENCY_STATE_DIR/lock" || return 1
    chmod 600 -- "$DEPENDENCY_STATE_DIR/lock" || return 1
    flock -x -w 30 "$lock_fd" || { dependency_error '依赖管理锁暂忙。'; return 1; }
    dependency_no_pending || return 1
    owned=$(dependency_read_owned) || return 1
    status=0; dependency_report "$profile" || status=$?
    [ "$status" -ne 2 ] || return 1
    [ "${#DEPENDENCY_MISSING_PACKAGES[@]}" -gt 0 ] || return 0
    stage=$(mktemp -d "$DEPENDENCY_STATE_DIR/.transaction.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    apt-get update || { dependency_error '软件包索引更新失败，未安装。'; return 1; }
    dependency_snapshot "$stage/before" before || return 1
    plan=$(LC_ALL=C apt-get --simulate --no-remove --no-install-recommends install -- "${DEPENDENCY_MISSING_PACKAGES[@]}") || return 1
    if grep -q '^Remv ' <<< "$plan"; then dependency_error '安装计划包含删除，已停止。'; return 1; fi
    printf '%s\n' "$plan" | awk '$1 == "Inst" {print $2}' | LC_ALL=C sort -u > "$stage/plan"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
    done < "$stage/plan"
    printf '安装计划（含传递依赖）：\n'; cat -- "$stage/plan"
    install -m 600 -- "$stage/before" "$DEPENDENCY_STATE_DIR/pending-before" &&
        install -m 600 -- "$stage/plan" "$DEPENDENCY_STATE_DIR/pending-plan" || return 1
    apt-get --no-remove --no-install-recommends install -y -- "${DEPENDENCY_MISSING_PACKAGES[@]}" || rc=$?
    dependency_snapshot "$stage/after" || { dependency_error '无法读取安装后状态，保留事务快照。'; return 1; }
    dependency_snapshot "$stage/incomplete" incomplete || { dependency_error '无法读取未完成包状态，保留事务快照。'; return 1; }
    printf '%s\n' "$owned" | sed '/^$/d' > "$stage/owned"
    LC_ALL=C comm -13 "$stage/before" "$stage/after" > "$stage/new" || return 1
    local -A planned=()
    while IFS= read -r package; do
        [ -n "$package" ] && planned["${package%%:*}"]=1
    done < "$stage/plan"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        if [ "${planned[${package%%:*}]:-0}" = 1 ]; then incomplete=true; fi
    done < "$stage/incomplete"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        if [ "${planned[${package%%:*}]:-0}" = 1 ]; then
            printf '%s\n' "$package" >> "$stage/owned"
            printf '已记录本脚本新增依赖：%s\n' "$package"
        fi
    done < "$stage/new"
    dependency_save_owned "$stage/owned" || return 1
    if [ "$incomplete" = true ]; then
        dependency_error '安装后仍有未配置完成的计划包；已记录成功新增项并保留事务快照，请人工核对。'
        dependency_audit dependency_install 1
        return 1
    fi
    rm -f -- "$DEPENDENCY_STATE_DIR/pending-before" "$DEPENDENCY_STATE_DIR/pending-plan" || return 1
    if [ "$rc" -ne 0 ]; then
        dependency_error '安装未全部成功；实际已装的新包已记录，可重试或按账本卸载。'
        dependency_audit dependency_install "$rc"
        return "$rc"
    fi
    if ! dependency_report "$profile"; then
        dependency_error '安装命令已完成，但命令/运行库复检失败，未报告成功。'
        dependency_audit dependency_install 1
        return 1
    fi
    dependency_audit dependency_install 0
    printf '依赖安装并复检完成；已有依赖的归属保持不变。\n'
)

dependency_protected() {
    local flags base="${1%%:*}"
    case "$base" in bash|apt|dpkg|systemd*|libsystemd*|libpam*|libudev*|coreutils|findutils|grep|sed|mawk|gawk|util-linux|libc6|libc-bin|libgcc-s1|libstdc++6) return 0 ;; esac
    flags=$(dpkg-query -W -f='${Essential}\t${Protected}\n' -- "$1" 2>/dev/null) || return 0
    [[ "$flags" == *yes* ]]
}

dependency_retained_dependencies() {
    [ "$#" -gt 0 ] || return 0
    local records
    records=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${Pre-Depends}, ${Depends}\n') || return 1
    # 保留受保护包及其已安装的直接/间接依赖；替代依赖保守保留已安装项。
    printf '%s\n' "$records" | awk -F '\t' -v roots="$*" '
        function base(name) { sub(/:[A-Za-z0-9-]+$/, "", name); return name }
        $2 == "installed" { name=base($1); present[name]=1; deps[name]=$3 }
        END {
            count=split(roots, initial, " "); last=0
            for (i=1; i<=count; i++) { name=base(initial[i]); if (!seen[name]++) queue[++last]=name }
            for (first=1; first<=last; first++) {
                name=queue[first]; print name
                count=split(deps[name], edges, /[,|]/)
                for (i=1; i<=count; i++) {
                    gsub(/^[ \t]+|[ \t]+$/, "", edges[i]); split(edges[i], words, /[ \t]+/)
                    child=base(words[1]); if (present[child] && !seen[child]++) queue[++last]=child
                }
            }
        }'
}

dependency_remove() (
    umask 077
    local scope="${1:-owned}" assume_yes="${2:-false}" owned candidates package plan answer stage rc=0 lock_fd
    dependency_removal_is_safe || return 1
    dependency_prepare_state || return 1
    exec {lock_fd}> "$DEPENDENCY_STATE_DIR/lock" || return 1
    chmod 600 -- "$DEPENDENCY_STATE_DIR/lock" || return 1
    flock -x -w 30 "$lock_fd" || return 1
    dependency_no_pending || return 1
    owned=$(dependency_read_owned) || return 1
    if [ "$scope" = all ]; then
        candidates=$(printf '%s\n%s\n' "$(dependency_manifest all | cut -d '|' -f1)" "$owned" | sed '/^$/d' | LC_ALL=C sort -u)
        printf '已选择全部相关依赖，包括安装前已有的包；系统基础包和另一脚本仍使用的包仍会保留。\n'
    else
        candidates="$owned"
        printf '卸载范围：仅本脚本新增并记录的依赖。\n'
    fi
    local -a selected=() removals=() protected_roots=() filtered=()
    local -A allowed=()
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
        dependency_installed "$package" || continue
        if dependency_protected "$package"; then printf '保留系统基础/受保护包：%s\n' "$package"; protected_roots+=("$package"); continue; fi
        if dependency_peer_uses_package "$package"; then printf '保留另一脚本仍需使用的包：%s\n' "$package"; protected_roots+=("$package"); continue; fi
        selected+=("$package"); allowed["${package%%:*}"]=1
    done <<< "$candidates"
    local retained
    retained=$(dependency_retained_dependencies "${protected_roots[@]}") || return 1
    local -A required=()
    while IFS= read -r package; do [ -z "$package" ] || required["${package%%:*}"]=1; done <<< "$retained"
    allowed=()
    for package in "${selected[@]}"; do
        if [ "${required[${package%%:*}]:-0}" = 1 ]; then
            printf '保留受保护/共享组件所需的依赖：%s\n' "$package"
        else filtered+=("$package"); allowed["${package%%:*}"]=1; fi
    done
    selected=("${filtered[@]}")
    [ "${#selected[@]}" -gt 0 ] || { printf '没有可卸载的新依赖；未改动系统软件包。\n'; return 0; }
    plan=$(LC_ALL=C apt-get --simulate -o APT::Get::AutomaticRemove=false remove -- "${selected[@]}") || return 1
    if grep -q '^Inst ' <<< "$plan"; then dependency_error '卸载计划会安装其他包，已停止。'; return 1; fi
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        dependency_package_name "$package" || return 1
        if [ "${allowed[${package%%:*}]:-0}" != 1 ] || dependency_protected "$package" || dependency_peer_uses_package "$package"; then
            dependency_error "计划会额外删除范围外/受保护包 $package，已停止。"
            return 1
        fi
        removals+=("$package")
    done < <(printf '%s\n' "$plan" | awk '$1 == "Remv" {print $2}')
    [ "${#removals[@]}" -gt 0 ] || { printf '卸载计划为空，未改动软件包。\n'; return 0; }
    printf '本次将删除以下依赖，不执行 autoremove/purge：\n'; printf '  %s\n' "${removals[@]}"
    if [ "$assume_yes" != true ]; then
        read -r -p '确认卸载上述依赖？[y/yes，默认 n]：' answer || return 0
        case "${answer,,}" in y|yes) ;; *) printf '卸载已取消。\n'; return 0 ;; esac
    fi
    stage=$(mktemp -d "$DEPENDENCY_STATE_DIR/.uninstall.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    apt-get -o APT::Get::AutomaticRemove=false remove -y -- "${removals[@]}" || rc=$?
    : > "$stage/owned"
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        if dependency_installed "$package"; then printf '%s\n' "$package" >> "$stage/owned"; fi
    done <<< "$owned"
    dependency_save_owned "$stage/owned" || return 1
    for package in "${removals[@]}"; do
        if dependency_installed "$package"; then rc=1; fi
    done
    dependency_audit dependency_remove "$rc"
    [ "$rc" -eq 0 ] || { dependency_error '卸载未全部完成；剩余新增依赖已保留在账本中。'; return "$rc"; }
    printf '依赖卸载完成；范围外和原有依赖保持不变。\n'
)

dependency_cli() {
    # main() 已把 --yes/-y 从参数中取出并设置 DOG_NONINTERACTIVE；这里两种来源都认。
    local action="${1:-check}" scope=owned yes="${DOG_NONINTERACTIVE:-false}" option
    [ "$#" -eq 0 ] || shift
    for option in "$@"; do
        case "$option" in --yes) yes=true ;; --all) scope=all ;; *) dependency_error "未知参数：$option"; return 2 ;; esac
    done
    case "$action" in
        check) [ "$scope" = owned ] && [ "$yes" = false ] || return 2; dependency_report all ;;
        install) [ "$scope" = owned ] || return 2; dependency_install_missing "$yes" all ;;
        remove) dependency_remove "$scope" "$yes" ;;
        owned) [ "$scope" = owned ] && [ "$yes" = false ] || return 2; dependency_read_owned ;;
        *) dependency_error '用法：--dependencies check|install [--yes]|remove [--all] [--yes]|owned'; return 2 ;;
    esac
}

dependency_menu() {
    local choice scope
    while true; do
        ui_title "依赖检测、安装与卸载"
        ui_option 1 "检测全部依赖（只读）"
        ui_option 2 "仅安装缺失依赖"
        ui_option 3 "查看本脚本新增包账本"
        ui_option 4 "卸载依赖"
        ui_option 0 "返回"
        ui_prompt 4 choice || return 0
        case "$choice" in
            1) dependency_report all || true ;;
            2) dependency_install_missing false all || true ;;
            3) dependency_read_owned || true; printf '账本位置：%s/installed-packages\n' "$DEPENDENCY_STATE_DIR" ;;
            4)
                read -r -p ' 范围：1 仅本脚本新增（默认），2 全部相关，0 取消：' scope || return 0
                case "$scope" in ''|1) dependency_remove owned false || true ;; 2) dependency_remove all false || true ;; 0) ;; *) printf '无效范围。\n' ;; esac
                ;;
            0) return 0 ;;
            *) printf '无效选择。\n' ;;
        esac
        read -r -p ' 按回车返回依赖管理...' choice || return 0
    done
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

# 保持原自动检查调用约定；显式更新和 Guard 使用 all，普通监控仅 core。
install_missing_tools() { dependency_install_missing true core; }

check_dependencies() {
    local silent_mode="${1:-false}" profile="${2:-core}" report status=0
    report=$(dependency_report "$profile") || status=$?
    if [ "$status" -eq 2 ]; then
        printf '%s\n' "$report" >&2
        return 1
    fi
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$report"
        dependency_install_missing true "$profile" || return 1
    elif [ "$silent_mode" != true ]; then
        printf '%s\n依赖检查通过。\n' "$report"
    fi
}
