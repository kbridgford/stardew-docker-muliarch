#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib/steam-cache.sh"
source "$ROOT/scripts/lib/podman-steam.sh"

usage() {
    printf '%s\n' \
        'Usage: scripts/podman-steam.sh doctor|build|run|smoke|logs|stop TARGET [options]' \
        'Targets: multiarch, all (shortcut to the sole project, not both runtime platforms)' \
        'Run/smoke: --env-file FILE --web-port 5801 --vnc-port 5902 --game-port 24642' \
        '         --timeout 180 --lan (game UDP only) --cid-file FILE (removed with container)' \
        '         --state-root DIR (private descendant under .local/validation; appends /multiarch)' \
        '         --platform linux/amd64|linux/arm64 (run/smoke/doctor; default arm64)' \
        'Build:   --no-cache (bypass image layers, never bypass or acquire the local Steam cache)' \
        'Building multiarch uses Podman buildx for both platforms in one local manifest.' \
        'Game acquisition is always explicit: ./pullValleyBin.sh'
}
[[ "${1:-}" != --help && "${1:-}" != -h ]] || { usage; exit; }
[[ $# -ge 2 ]] || { usage >&2; exit 1; }
ACTION=$1; target=$2; shift 2
case "$ACTION" in doctor|build|run|smoke|logs|stop) ;; *) steam_die "Unknown action: $ACTION" ;; esac
[[ "$target" != all ]] || target=multiarch
RUNTIME_PLATFORM=''
select_target "$target"
ENV_FILE='' CID_FILE='' STATE_ROOT='' NO_CACHE=no WEB_PORT=5801 VNC_PORT=5902 GAME_PORT=24642 STARTUP_TIMEOUT=180 GAME_BIND=127.0.0.1
while (( $# )); do
    case "$1" in
        --no-cache)
            [[ "$ACTION" == build ]] || steam_die '--no-cache is build-only.'
            NO_CACHE=yes; shift ;;
        --env-file|--cid-file|--state-root|--platform|--web-port|--vnc-port|--game-port|--timeout)
            [[ $# -ge 2 ]] || steam_die "Missing value for $1"
            [[ -n "$2" ]] || steam_die "Empty value for $1"
            if [[ "$1" == --platform ]]; then
                [[ "$ACTION" =~ ^(run|smoke|doctor)$ ]] ||
                    steam_die '--platform is supported only for run, smoke or doctor; build always includes both platforms.'
            else
                [[ "$ACTION" =~ ^(run|smoke)$ ]] || steam_die "$1 is supported only for run or smoke."
            fi
            case "$1" in
                --env-file) ENV_FILE=$2 ;;
                --cid-file) CID_FILE=$2 ;;
                --state-root) STATE_ROOT=$2 ;;
                --platform) RUNTIME_PLATFORM=$2 ;;
                --web-port) WEB_PORT=$2 ;;
                --vnc-port) VNC_PORT=$2 ;;
                --game-port) GAME_PORT=$2 ;;
                --timeout) STARTUP_TIMEOUT=$2 ;;
            esac
            shift 2 ;;
        --lan)
            [[ "$ACTION" =~ ^(run|smoke)$ ]] || steam_die '--lan is supported only for run or smoke.'
            GAME_BIND=0.0.0.0; shift ;;
        *) steam_die "Unknown option: $1" ;;
    esac
done
select_target "$target"
steam_require_tools
for port in "$WEB_PORT" "$VNC_PORT" "$GAME_PORT"; do
    if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
        steam_die 'Ports must be integers in 1..65535.'
    fi
done
[[ "$WEB_PORT" != "$VNC_PORT" ]] || steam_die 'Browser and VNC ports must differ.'
[[ "$STARTUP_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ ]] || steam_die 'Timeout must be a positive integer (maximum 99999).'
case "$ACTION" in
    doctor)
        podman_doctor build
        steam_lock "$ROOT" -s
        steam_check_recovery "$ROOT"
        steam_validate "$ROOT/src/steam"
        printf 'Cache valid; rootless/platform prerequisites available (not a runtime pass).\n'
        ;;
    build)
        steam_lock "$ROOT" -s
        steam_check_recovery "$ROOT"
        steam_validate "$ROOT/src/steam"
        podman_doctor build
        contexts=(--build-context "steam=$ROOT/src/steam" --build-context "devtools=$ROOT/scripts")
        if [[ "$MODDED" == 1 ]]; then
            contexts+=(--build-context "mods=$ROOT/mods")
        fi
        build_args=(--layers "${contexts[@]}"
            --ignorefile "$ROOT/$DIRECTORY/docker/$DOCKERFILE.dockerignore"
            --file "$ROOT/$DIRECTORY/docker/$DOCKERFILE" "$ROOT/$DIRECTORY/docker")
        [[ "$NO_CACHE" != yes ]] || build_args=(--no-cache "${build_args[@]}")
        candidate="$IMAGE-build-$BASHPID-$RANDOM"
        podman manifest create "$candidate" >/dev/null
        cleanup_build() {
            status=$?
            trap - EXIT
            podman manifest rm "$candidate" >/dev/null || status=1
            exit "$status"
        }
        trap cleanup_build EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        podman buildx build --platform linux/amd64,linux/arm64 --manifest "$candidate" "${build_args[@]}"
        podman manifest inspect "$candidate" | jq -e \
            '([.manifests[].platform | .os + "/" + .architecture] | sort) == ["linux/amd64", "linux/arm64"]' >/dev/null ||
            steam_die 'Build did not produce exactly the two requested platforms.'
        podman tag "$candidate" "$IMAGE"
        # Manifest-aware removal drops only this alias, not the host-specific member.
        podman manifest rm "$candidate" >/dev/null
        trap - EXIT
        verify_runtime_image
        printf 'Built local manifest %s: linux/amd64, linux/arm64 (not pushed).\n' "$IMAGE"
        ;;
    logs|stop)
        podman_doctor management
        if [[ "$ACTION" == stop ]]; then stop_container; else
            require_owned
            podman logs --tail 100 "$CONTAINER"
        fi
        ;;
    run|smoke)
        validate_state_root
        validate_cid_file
        podman_doctor runtime
        container_exists && steam_die "$CONTAINER exists; stop it explicitly before recreating."
        verify_runtime_image
        [[ -n "$ENV_FILE" ]] || steam_die 'Use --env-file with a private VNC_PASSWORD file.'
        declare -A PRIVATE_ENV=() SETTINGS=()
        read_private_env "$ENV_FILE"
        compose_environment
        [[ ${#SETTINGS[VNC_PASSWORD]} -ge 6 ]] || steam_die 'VNC_PASSWORD must contain at least six characters.'
        [[ "${PRIVATE_ENV[SECURE_CONNECTION]:-0}" == 0 && "${PRIVATE_ENV[WEB_AUTHENTICATION]:-0}" == 0 ]] ||
            steam_die 'Local helper supports VNC auth over loopback/SSH; secure/web-auth modes require separate configuration.'
        lock_normal_state
        container_exists && steam_die "$CONTAINER exists; stop it explicitly before recreating."
        prepare_state
        attempt="$STATE/attempt-$BASHPID-$RANDOM-$RANDOM"
        mkdir -m 700 "$attempt"
        cid_path=${CID_FILE:-$attempt/cid}
        [[ ! -e "$cid_path" && ! -L "$cid_path" ]] || steam_die 'CID receipt must not already exist.'
        created=no
        cleanup() {
            status=$?
            trap - EXIT
            # Remove the private env even if subsequent diagnostics/cleanup fail.
            rm -f "$attempt/runtime.local.env" || status=1
            if [[ ! -L "$cid_path" && -f "$cid_path" && -s "$cid_path" ]]; then
                receipt=$(cat "$cid_path")
                if [[ "$receipt" =~ ^[a-f0-9]{64}$ ]]; then
                    CONTAINER=$receipt
                    created=yes
                else
                    printf 'Invalid container ID receipt; refusing name-based cleanup.\n' >&2
                    created=no
                    status=1
                fi
            elif [[ -e "$cid_path" || -L "$cid_path" ]]; then
                printf 'Unsafe container ID receipt; refusing cleanup.\n' >&2
                created=no
                status=1
            fi
            if (( status != 0 )); then
                printf 'Podman start/readiness failed. Private diagnostics: %s\n' "$attempt" >&2
            fi
            if [[ "$created" == yes ]]; then
                if ! (require_owned); then
                    printf 'Container ownership could not be verified; refusing diagnostics and cleanup.\n' >&2
                    status=1
                else
                    if (( status != 0 )); then
                        if ! podman logs --tail 200 "$CONTAINER" > "$attempt/failure.log" 2>&1; then
                            printf 'Could not collect container logs; inspect the Podman error in %s.\n' "$attempt" >&2
                        fi
                    fi
                    if [[ "$ACTION" == smoke ]]; then
                        (stop_container) || status=1
                    elif (( status != 0 )); then
                        printf 'Container retained for diagnosis: %s (use this helper to stop).\n' "$CONTAINER" >&2
                    fi
                fi
            fi
            [[ -n "$CID_FILE" ]] || rm -f "$attempt/cid"
            exit "$status"
        }
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        for key in "${!SETTINGS[@]}"; do
            value=${SETTINGS[$key]}
            [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || steam_die "Multiline setting unsupported: $key"
            printf '%s=%s\n' "$key" "$value"
        done > "$attempt/runtime.local.env"
        arguments=(run --detach --pull=never --name "$CONTAINER" --cidfile "$cid_path"
            --label "$STARDEW_LABEL=$PROJECT" --platform "linux/$ARCH"
            "--userns=keep-id:uid=1000,gid=1000" --user 0:0
            --env-file "$attempt/runtime.local.env"
            --volume "$STATE/config:/config:Z"
            --publish "127.0.0.1:$WEB_PORT:5800" --publish "127.0.0.1:$VNC_PORT:5900"
            --publish "$GAME_BIND:$GAME_PORT:24642/udp")
        if [[ "$MODDED" == 1 ]]; then
            arguments+=(--volume "$STATE/autoload.json:/data/Stardew/game/Mods/AutoLoadGame/config.json:Z")
        fi
        podman "${arguments[@]}" "$IMAGE" > "$attempt/start.log" 2>&1
        if [[ -n "${MIGRATION_LOCK_FD:-}" ]]; then
            flock -u "$MIGRATION_LOCK_FD"
            exec {MIGRATION_LOCK_FD}>&-
        fi
        [[ ! -L "$cid_path" && -f "$cid_path" ]] || steam_die 'Missing safe container ID receipt.'
        CONTAINER=$(cat "$cid_path")
        [[ "$CONTAINER" =~ ^[a-f0-9]{64}$ ]] || steam_die 'Invalid container ID receipt.'
        require_owned
        created=yes
        timeout "$STARTUP_TIMEOUT" bash "$ROOT/scripts/wait-steam.sh" \
            "$CONTAINER" "$MODDED" "$WEB_PORT" "$STARTUP_TIMEOUT"
        printf '%s: startup checks passed (mod loading required for SMAPI targets); not proof of world hosting or client compatibility.\n' "$CONTAINER"
        printf 'Browser http://127.0.0.1:%s/ ; VNC 127.0.0.1::%s\n' "$WEB_PORT" "$VNC_PORT"
        if [[ "$ACTION" == smoke ]]; then
            podman exec --user 1000:1000 --env DISPLAY=:0 "$CONTAINER" glxinfo -B
            printf 'Graphics probe passed; authentication is a separate automated check, not repeated here. Gameplay, multiplayer and actual game-save checks are optional human follow-up, not certified by startup.\n'
        fi
        ;;
esac
