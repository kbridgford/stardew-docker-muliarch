#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib/steam-cache.sh"
source "$ROOT/scripts/lib/podman-steam.sh"

podman() {
    case "$1" in
        inspect) printf '%s\n' "$mock_running" ;;
        exec)
            case "$3" in
                pgrep) [[ "$process" == yes ]] ;;
                test) [[ "$fresh" == yes ]] ;;
                grep)
                    [[ "$4" == -Eq ]]
                    printf '%s\n' "$log" | grep -Eq "$5" ;;
                *) return 2 ;;
            esac ;;
        *) return 2 ;;
    esac
}
curl() { [[ "$browser_ready" == yes ]]; }
sleep() { :; }

CONTAINER=synthetic WEB_PORT=5801 STARTUP_TIMEOUT=2
for case_name in ready early-log stale-log no-process no-browser exited vanilla; do
    MODDED=1 mock_running=true process=yes browser_ready=yes fresh=yes
    log='[12:00:00 INFO  SMAPI] Loaded 3 mods:'
    expected=0
    case "$case_name" in
        early-log) log='[12:00:00 INFO SMAPI] SMAPI 4.0.8'; expected=1 ;;
        stale-log) fresh=no; expected=1 ;;
        no-process) process=no; expected=1 ;;
        no-browser) browser_ready=no; expected=1 ;;
        exited) mock_running=false; expected=1 ;;
        vanilla) MODDED=0; log=''; fresh=no ;;
    esac
    status=0
    (wait_for_game) >/dev/null 2>&1 || status=$?
    if [[ "$status" != "$expected" ]]; then
        printf 'FAIL %s: expected exit %s, got %s\n' "$case_name" "$expected" "$status" >&2
        exit 1
    fi
    printf 'PASS %s\n' "$case_name"
done
