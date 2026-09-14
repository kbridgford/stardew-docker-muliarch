#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib/steam-cache.sh"
source "$ROOT/scripts/lib/podman-steam.sh"
[[ $# -eq 4 ]] || steam_die 'Internal readiness helper requires container, modded flag, port and timeout.'
CONTAINER=$1 MODDED=$2 WEB_PORT=$3 STARTUP_TIMEOUT=$4
wait_for_game
