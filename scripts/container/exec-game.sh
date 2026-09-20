#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/native-game.sh"
[[ $# -ge 1 && -x "$1" ]] || native_die 'Missing executable game apphost.'
architecture=$(dpkg --print-architecture)
native_elf "$1" "$architecture"
printf 'Container architecture %s: native game execution.\n' "$architecture"
exec "$@"
