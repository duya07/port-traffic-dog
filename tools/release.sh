#!/bin/bash
# 生成 GitHub Release 资产：dist/port-traffic-dog.sh、dist/port-ip-guard.sh、dist/SHA256SUMS。
# Dog 2.x 的 --update 与 migrate-to-custom.sh 只接受与 SHA256SUMS 一致的 Release 资产。
#
# 用法：tools/release.sh [v版本号]
#   给出版本号（如 v2.0.0）时，核对它与脚本内 SCRIPT_VERSION 一致。
# 发布：gh release create vX.Y.Z dist/port-traffic-dog.sh dist/port-ip-guard.sh dist/SHA256SUMS
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
cd "$ROOT"

tools/build.sh >/dev/null
tools/build.sh --check >/dev/null || { echo "构建产物与 src/ 不一致" >&2; exit 1; }
for f in port-traffic-dog.sh port-ip-guard.sh; do
    bash -n "$f" || { echo "$f 语法检查失败" >&2; exit 1; }
done
grep -Fq '# PORT_TRAFFIC_DOG_IP_GUARD' port-ip-guard.sh || { echo "port-ip-guard.sh 缺少组件标记" >&2; exit 1; }

version=$(awk -F'"' '/^readonly SCRIPT_VERSION="[0-9]+(\.[0-9]+)+"/ { print $2; exit }' port-traffic-dog.sh)
[ -n "$version" ] || { echo "无法读取 SCRIPT_VERSION" >&2; exit 1; }
if [ -n "${1:-}" ] && [ "${1#v}" != "$version" ]; then
    echo "版本不一致：参数 $1，脚本 $version" >&2; exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST"
install -m 755 port-traffic-dog.sh port-ip-guard.sh "$DIST/"
(cd "$DIST" && sha256sum port-traffic-dog.sh port-ip-guard.sh > SHA256SUMS && sha256sum -c --quiet SHA256SUMS)
echo "Dog $version → $DIST"
cat "$DIST/SHA256SUMS"
