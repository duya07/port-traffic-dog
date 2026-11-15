# ── 锁与原子写入 ──────────────────────────────────────────────────
# fd 约定：7=日志锁（子 shell 内）、8=Dog 状态锁、9=与 NTC 共享的 TC 锁。

# 获取 Dog 状态锁（可重入）。$1 可指定等待秒数，0 表示不等待。
dog_lock() {
    local wait_seconds="${1:-$DOG_LOCK_WAIT}"
    if [ "$DOG_LOCK_DEPTH" -gt 0 ]; then
        DOG_LOCK_DEPTH=$((DOG_LOCK_DEPTH + 1))
        return 0
    fi
    mkdir -p "$(dirname "$DOG_LOCK_FILE")" 2>/dev/null || true
    exec 8>>"$DOG_LOCK_FILE" || return 1
    if [ "$wait_seconds" -eq 0 ]; then
        flock -n 8 || { exec 8>&-; return 1; }
    else
        flock -w "$wait_seconds" 8 || { exec 8>&-; return 1; }
    fi
    DOG_LOCK_DEPTH=1
}

dog_unlock() {
    [ "$DOG_LOCK_DEPTH" -gt 0 ] || return 0
    DOG_LOCK_DEPTH=$((DOG_LOCK_DEPTH - 1))
    if [ "$DOG_LOCK_DEPTH" -eq 0 ]; then
        flock -u 8 2>/dev/null || true
        exec 8>&-
    fi
}

# 在锁内执行一条命令，返回该命令的退出码。
with_dog_lock() {
    dog_lock || { echo -e "${RED}另一个 Dog 进程正在修改配置，请稍后再试${NC}" >&2; return 75; }
    local rc=0
    "$@" || rc=$?
    dog_unlock
    return "$rc"
}

# 把标准输入原子写入目标文件：同目录临时文件 + fsync + rename。
# 用法：producer | atomic_write <目标> [权限]
atomic_write() {
    local target="$1" mode="${2:-600}" dir tmp
    dir=$(dirname "$target")
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.${target##*/}.tmp.XXXXXX") || return 1
    if ! cat > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    chmod "$mode" "$tmp" 2>/dev/null || true
    sync "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

# 对 JSON 文件执行 jq 变换并原子替换；jq 失败或结果不是对象时保持原文件。
# 用法：json_update <文件> <jq 过滤器> [jq 参数...]
json_update() {
    local file="$1" filter="$2" out
    shift 2
    out=$(jq "$@" "$filter" "$file") || return 1
    jq -e 'type == "object"' <<< "$out" >/dev/null 2>&1 || return 1
    printf '%s\n' "$out" | atomic_write "$file" 600
}
