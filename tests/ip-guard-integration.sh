#!/bin/bash
set -euo pipefail
[ "${PI_NTC_DOG_ISOLATED:-}" = 1 ] || { echo 'requires isolated harness' >&2; exit 90; }
exec timeout -k 3 100 python3 "$(dirname "${BASH_SOURCE[0]}")/ip-guard-integration.py"
