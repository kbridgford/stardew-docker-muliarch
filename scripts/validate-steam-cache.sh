#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib/steam-cache.sh"
steam_require_tools
[[ $# -le 1 ]] || steam_die 'Usage: validate-steam-cache.sh [cache-directory]'
if [[ $# -eq 0 ]]; then
    steam_lock "$ROOT" -s
    steam_check_recovery "$ROOT"
fi
steam_validate "${1:-$ROOT/src/steam}"
printf 'Steam cache valid.\n'
