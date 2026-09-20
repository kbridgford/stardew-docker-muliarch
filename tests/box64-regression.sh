#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/steam-cache.sh"
source "$ROOT/scripts/lib/podman-steam.sh"

usage() {
    printf '%s\n' \
        'Usage: bash tests/box64-regression.sh --image ARM_IMAGE_ID [--timeout 120]' \
        '       [--env BOX64_NAME=NUMBER ...]' \
        'Opt-in, offline headless SMAPI-banner diagnostic, NOT game readiness.' \
        'Calls Box64 directly, bypassing the game launcher compatibility settings.' \
        'Legacy Box64 images only; native ValleyCore images are not supported.' \
        'Uses an existing immutable ARM image and container-only state; never builds or downloads.' \
        'Exit 0: managed banner observed; 124: deadline; other nonzero: failure.'
}
requested_image='' limit=120 settings=()
while (( $# )); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --image|--timeout|--env)
            [[ $# -ge 2 ]] || steam_die "Missing value for $1"
            case "$1" in
                --image) requested_image=${2#sha256:} ;;
                --timeout) limit=$2 ;;
                --env)
                    [[ "$2" =~ ^BOX64_[A-Z0-9_]+=[0-9]{1,5}$ ]] ||
                        steam_die 'Diagnostic settings must be numeric BOX64_NAME=NUMBER.'
                    settings+=("$2") ;;
            esac
            shift 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ "$requested_image" =~ ^[a-f0-9]{64}$ ]] || steam_die 'Use an immutable local ARM image ID.'
if [[ ! "$limit" =~ ^[1-9][0-9]{0,2}$ ]] || (( limit > 600 )); then
    steam_die 'Diagnostic timeout must be 1..600 seconds.'
fi
RUNTIME_PLATFORM=linux/arm64
select_target multiarch
podman_doctor runtime
PODMAN=$(command -v podman)
podman() { timeout --kill-after=5 30 "$PODMAN" "$@"; }
metadata=$(podman image inspect "$requested_image")
jq -e --arg id "$requested_image" 'length==1 and .[0].Id==$id and
    .[0].Architecture=="arm64" and .[0].Os=="linux"' <<< "$metadata" >/dev/null ||
    steam_die 'Diagnostic image must be the exact local Linux ARM64 member.'
if jq -e '.[0].Config.Labels["io.stardew.game-runtime"] == "native"' <<< "$metadata" >/dev/null; then
    steam_die 'Native runtime image: use startup/lifecycle acceptance, not the legacy Box64 diagnostic.'
fi
run_id="box64-probe-$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID-$RANDOM"
evidence="$ROOT/.local/validation/$run_id"
validation_path "$evidence"
mkdir -p "$ROOT/.local/validation"
mkdir -m 700 "$evidence"
printf '%s\n' "$metadata" > "$evidence/image.json"
printf '%s\n' "${settings[@]}" > "$evidence/settings"
printf 'Private Box64 evidence: %s\n' "$evidence"
CONTAINER=''
milestone=false
started=$SECONDS
# Invoked through the EXIT trap, including failure and interruption paths.
# shellcheck disable=SC2317
cleanup() {
    status=$?
    trap - EXIT
    if [[ -s "$evidence/cid" && ! -L "$evidence/cid" ]]; then
        CONTAINER=$(cat "$evidence/cid")
    elif [[ -s "$evidence/podman.cid" && ! -L "$evidence/podman.cid" ]]; then
        CONTAINER=$(cat "$evidence/podman.cid")
    fi
    cleanup_ok=false
    if [[ "$CONTAINER" =~ ^[a-f0-9]{64}$ ]] && (require_owned); then
        if podman logs "$CONTAINER" > "$evidence/console.log" 2>&1 &&
            podman inspect --format '{{json .State}}' "$CONTAINER" > "$evidence/state.json" &&
            podman stop --time 5 "$CONTAINER" >> "$evidence/cleanup.log" 2>&1 &&
            podman rm "$CONTAINER" >> "$evidence/cleanup.log" 2>&1; then
            if podman container exists "$CONTAINER"; then
                status=1
            else
                query_status=$?
                if [[ "$query_status" == 1 ]]; then cleanup_ok=true; else status=1; fi
            fi
        else status=1; fi
    else
        printf 'No verified created-container ID; cleanup not claimed.\n' >&2
        status=1
    fi
    jq -n --arg id "$CONTAINER" --arg image "$requested_image" \
        --argjson status "$status" --argjson banner "$milestone" \
        --argjson cleaned "$cleanup_ok" --argjson elapsed "$((SECONDS-started))" \
        '{scope:"headless-smapi-banner-only",image:$image,container:$id,
          status:$status,banner_observed:$banner,cleanup_verified:$cleaned,elapsed_seconds:$elapsed}' \
        > "$evidence/result.json" || status=1
    printf 'Box64 banner diagnostic: exit %s, banner %s, cleanup %s\n' "$status" "$milestone" "$cleanup_ok"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
arguments=()
for setting in "${settings[@]}"; do arguments+=(--env "$setting"); done
podman run --detach --pull=never --platform linux/arm64 --network none \
    --tmpfs /config:rw,mode=700 \
    --name "stardew-$PROJECT-$run_id" --label "$STARDEW_LABEL=$PROJECT" \
    --cidfile "$evidence/podman.cid" --log-driver k8s-file --log-opt max-size=16mb \
    --userns=keep-id:uid=1000,gid=1000 --user 0:0 \
    --env SMAPI_USE_CURRENT_SHELL=true --env TERM=xterm --env BOX64_LOG=1 \
    "${arguments[@]}" --entrypoint /bin/bash "$requested_image" -ec '
        test "$(dpkg --print-architecture)" = arm64
        dpkg-query -W box64 libc6
        export HOME=/tmp/box64-probe
        export XDG_CONFIG_HOME=$HOME/config XDG_DATA_HOME=$HOME/data XDG_CACHE_HOME=$HOME/cache
        mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
        cd /data/Stardew/game
        exec box64 ./StardewModdingAPI
    ' > "$evidence/cid" 2> "$evidence/create.log"
CONTAINER=$(cat "$evidence/cid")
[[ "$CONTAINER" =~ ^[a-f0-9]{64}$ ]] || steam_die 'Invalid created-container ID.'
require_owned
while (( SECONDS-started < limit )); do
    podman logs "$CONTAINER" > "$evidence/console.log" 2>&1
    if grep -Eq '^\[SMAPI\] SMAPI [0-9]+\.[0-9]+' "$evidence/console.log"; then
        milestone=true
        printf '%s\n' "$((SECONDS-started))" > "$evidence/banner-seconds"
        exit 0
    fi
    [[ $(podman inspect --format '{{.State.Running}}' "$CONTAINER") == true ]] ||
        steam_die 'Process exited before the managed SMAPI banner.'
    sleep 1
done
podman exec "$CONTAINER" ps -eLo pid,tid,comm,stat,wchan,pcpu,etime > "$evidence/threads.log" 2>&1 ||
    steam_die 'Unable to capture deadline process diagnostics.'
printf 'Managed startup milestone not reached within %s seconds.\n' "$limit" >&2
exit 124
