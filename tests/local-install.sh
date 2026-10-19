#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Public CLI: reject an incomplete bundle before touching the installed version.
printf '%s\n' 'unrelated-installed-content' > /usr/local/bin/port-traffic-dog.sh
before=$(sha256sum /usr/local/bin/port-traffic-dog.sh)
if bash "$root/port-traffic-dog.sh" --install-local "$work" > "$work/out" 2>&1; then
 echo 'FAIL: incomplete local bundle unexpectedly installed' >&2; exit 1
fi
[ "$before" = "$(sha256sum /usr/local/bin/port-traffic-dog.sh)" ]
grep -Fq '本地安装包不完整' "$work/out"
printf 'local-install validation passed\n'
