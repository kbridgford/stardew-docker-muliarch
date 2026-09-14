#!/usr/bin/env bash
# Real cached-image integration; never acquires game files or exercises saves.
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib/steam-cache.sh"
source "$ROOT/scripts/lib/podman-steam.sh"

usage() {
    printf '%s\n' 'Usage: tests/runtime-lifecycle.sh all|TARGET --env-file FILE [--timeout 600]' \
        'Runs sequential cached-image marker recreation, exact game-PID TERM/KILL and owned cleanup.' \
        'Private evidence: .local/validation/lifecycle-*/; no authentication or gameplay certification.'
}
[[ "${1:-}" != --help ]] || { usage; exit 0; }
[[ $# -ge 3 ]] || { usage >&2; exit 2; }
requested=$1; shift
ENV_FILE='' STARTUP_TIMEOUT=600
while (( $# )); do
    [[ $# -ge 2 ]] || steam_die "Missing value for $1"
    case "$1" in
        --env-file) ENV_FILE=$2 ;;
        --timeout) STARTUP_TIMEOUT=$2 ;;
        *) steam_die "Unknown option: $1" ;;
    esac
    shift 2
done
[[ "$STARTUP_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || steam_die 'Timeout must be 1..9999 seconds.'
[[ -n "$ENV_FILE" ]] || steam_die 'A private --env-file is required.'
for tool in podman jq timeout flock stat cmp; do
    command -v "$tool" >/dev/null || steam_die "Missing prerequisite: $tool"
done
if [[ "$requested" == all ]]; then targets=("${STEAM_TARGETS[@]}"); else
    select_target "$requested"
    targets=("$TARGET")
fi
[[ ! -L "$ROOT/.local" && ! -L "$ROOT/.local/validation" ]] || steam_die 'Evidence parents must not be symlinks.'
mkdir -p "$ROOT/.local/validation"
exec {lock_fd}>"$ROOT/.local/validation/lifecycle.lock"
flock -n "$lock_fd" || steam_die 'Another lifecycle runner holds the project lock.'
run_id="lifecycle-$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID-$RANDOM"
evidence="$ROOT/.local/validation/$run_id"
mkdir -m 700 "$evidence"
printf 'Private lifecycle evidence: %s\n' "$evidence"

# Bound management calls as well as startup; preserve the command's real status.
PODMAN=$(command -v podman)
podman() { timeout --kill-after=5 45 "$PODMAN" "$@"; }

run_target() {
    set -euo pipefail
    select_target "$1"
    local_dir="$evidence/$TARGET"
    mkdir -m 700 "$local_dir"
    receipt='' marker='' marker_path='' container_id=''
    # Invoked by the target subprocess's EXIT trap, including failure paths.
    # shellcheck disable=SC2317
    cleanup() {
        status=$?
        set +e
        trap - EXIT INT TERM
        if [[ -n "$receipt" && -s "$receipt" ]]; then
            container_id=$(cat "$receipt") || status=1
            if [[ "$container_id" =~ ^[a-f0-9]{64}$ ]]; then
                CONTAINER=$container_id
                if podman container exists "$CONTAINER"; then
                    if (require_owned); then
                        podman logs --tail 300 "$CONTAINER" > "$local_dir/cleanup-container.log" 2>&1 || status=1
                        (stop_container) >> "$local_dir/cleanup.log" 2>&1 || status=1
                    else status=1; fi
                else
                    query_status=$?
                    [[ "$query_status" == 1 ]] || status=1
                fi
            else
                printf 'Invalid receipt; refusing container cleanup.\n' >&2
                status=1
            fi
        fi
        if [[ -n "$marker_path" && -e "$marker_path" ]]; then
            if [[ ! -L "$marker_path" && -f "$marker_path" ]] && cmp -s "$local_dir/expected" "$marker_path"; then
                rm -- "$marker_path" || status=1
            else
                printf 'Marker changed unexpectedly; retained for diagnosis: %s\n' "$marker_path" >&2
                status=1
            fi
        fi
        printf '%s\n' "$status" > "$local_dir/status"
        exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    podman_doctor runtime
    container_exists && steam_die 'Conflicting container exists; lifecycle will not adopt or stop it.'
    verify_runtime_image
    marker=".${run_id}-${TARGET}.marker"
    marker_path="$ROOT/.local/podman/$TARGET/config/$marker"
    [[ ! -e "$marker_path" && ! -L "$marker_path" ]] || steam_die 'Marker path already exists.'
    printf '%s\n' "$run_id:$TARGET:application-owned persistence" > "$local_dir/expected"
    for signal in TERM KILL; do
        select_target "$1"
        receipt="$local_dir/$signal.cid"
        timeout --kill-after=15 "$((STARTUP_TIMEOUT + 90))" \
            bash "$ROOT/scripts/podman-steam.sh" run "$TARGET" --env-file "$ENV_FILE" \
            --timeout "$STARTUP_TIMEOUT" --cid-file "$receipt" > "$local_dir/$signal-startup.log" 2>&1
        container_id=$(cat "$receipt")
        [[ "$container_id" =~ ^[a-f0-9]{64}$ ]] || steam_die 'Invalid created-container ID.'
        CONTAINER=$container_id
        require_owned
        if [[ "$signal" == TERM ]]; then
            podman exec -i --user 1000:1000 "$CONTAINER" bash -c \
                'set -euo pipefail; set -o noclobber; cat > "/config/$1"' bash "$marker" < "$local_dir/expected"
        else
            podman exec --user 1000:1000 "$CONTAINER" cat "/config/$marker" > "$local_dir/recreated-marker"
            cmp "$local_dir/expected" "$local_dir/recreated-marker"
        fi
        cmp "$local_dir/expected" "$marker_path"
        ownership=$(stat -c '%u:%g' "$marker_path")
        [[ "$ownership" == "$(id -u):$(id -g)" ]] || steam_die 'Application marker is not mapped to host UID/GID.'
        printf '%s marker exact; host ownership %s\n' "$signal" "$ownership" >> "$local_dir/results"
        executable='/data/Stardew/game/StardewModdingAPI'
        [[ "$MODDED" == 1 ]] || executable='/data/Stardew/game/Stardew Valley'
        podman exec -i "$CONTAINER" bash -s -- identify "$executable" \
            < "$ROOT/tests/fixtures/lifecycle-process.sh" > "$local_dir/$signal-process.tsv"
        [[ "$(wc -l < "$local_dir/$signal-process.tsv")" == 1 ]]
        IFS=$'\t' read -r pid start _ < "$local_dir/$signal-process.tsv"
        [[ "$pid" =~ ^[1-9][0-9]*$ && "$start" =~ ^[0-9]+$ ]] && (( pid > 1 ))
        podman exec -i "$CONTAINER" bash -s -- signal "$executable" "$pid" "$start" "$signal" \
            < "$ROOT/tests/fixtures/lifecycle-process.sh" > "$local_dir/$signal-signal.log" 2>&1
        timeout --kill-after=5 90 "$PODMAN" wait "$CONTAINER" > "$local_dir/$signal-wait"
        exit_code=$(cat "$local_dir/$signal-wait")
        expected_exit=143
        [[ "$signal" != KILL ]] || expected_exit=137
        [[ "$exit_code" == "$expected_exit" ]] || steam_die "Unexpected $signal container exit: $exit_code (expected $expected_exit)."
        podman inspect --format '{{json .State}}' "$CONTAINER" > "$local_dir/$signal-state.json"
        jq -e --argjson code "$expected_exit" '.Running == false and .ExitCode == $code' \
            "$local_dir/$signal-state.json" >/dev/null
        readiness_status=0
        timeout --kill-after=5 15 bash "$ROOT/scripts/wait-steam.sh" "$CONTAINER" "$MODDED" 5801 4 \
            > "$local_dir/$signal-dead-readiness.log" 2>&1 || readiness_status=$?
        [[ "$readiness_status" == 1 ]] || steam_die "Dead application readiness returned $readiness_status, expected explicit rejection."
        podman logs --tail 300 "$CONTAINER" > "$local_dir/$signal-container.log" 2>&1
        printf '%s exact PID %s; container exit %s; dead readiness exit %s\n' \
            "$signal" "$pid" "$exit_code" "$readiness_status" >> "$local_dir/results"
        stop_container >> "$local_dir/cleanup.log" 2>&1
        if container_exists; then steam_die 'Container survived cleanup.'; fi
        receipt=''
    done
}

failures=0
child=''
interrupt() {
    trap - INT TERM
    if [[ -n "$child" ]]; then
        kill -TERM "$child" 2>/dev/null || :
        wait "$child" || :
    fi
    exit "$1"
}
trap 'interrupt 130' INT
trap 'interrupt 143' TERM
for target in "${targets[@]}"; do
    status=0
    # Do not put run_target in an `if`: doing so disables errexit throughout it.
    set +e
    run_target "$target" > "$evidence/$target.log" 2>&1 &
    child=$!
    wait "$child"
    status=$?
    child=''
    set -e
    if (( status == 0 )); then
        printf 'PASS %s: recreation/host ownership, TERM=143, KILL=137, dead-readiness rejection, cleanup\n' "$target"
    else
        printf 'FAIL/BLOCKED %s: exit %s; private evidence %s\n' "$target" "$status" "$evidence/$target" >&2
        failures=$((failures + 1))
    fi
done
printf '%s targets, %s failures\n' "${#targets[@]}" "$failures"
(( failures == 0 ))
