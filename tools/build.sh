#!/usr/bin/env bash
# 把 src/ 下按文件名排序的模块拼接成可分发的单文件 port-traffic-dog.sh。
# 用法：tools/build.sh [输出路径]      tools/build.sh --check（产物与源码不一致时返回 1）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/port-traffic-dog.sh"
CHECK=false
case "${1:-}" in
    --check) CHECK=true ;;
    "") ;;
    *) OUT="$1" ;;
esac
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
{
    first=true
    for f in "$ROOT"/src/[0-9][0-9]-*.sh; do
        if [ "$first" = true ]; then first=false; else printf '\n'; fi
        cat "$f"
    done
    printf '\nmain "$@"\n'
} > "$tmp"
bash -n "$tmp"
if [ "$CHECK" = true ]; then
    if cmp -s "$tmp" "$OUT"; then echo "build: up to date"; exit 0; fi
    echo "build: port-traffic-dog.sh 与 src/ 不一致，请运行 tools/build.sh" >&2
    exit 1
fi
install -m 0755 "$tmp" "$OUT"
echo "build: wrote $OUT ($(wc -l < "$OUT") lines)"
