#!/usr/bin/env bash
# Shared target metadata is consumed by the caller.
# shellcheck disable=SC2034

STARDEW_LABEL=io.stardew.local-project
STEAM_TARGETS=(multiarch)

select_target() {
    TARGET=$1
    DOCKERFILE=Dockerfile-steam
    ARCH=arm64
    MODDED=1
    case "$TARGET" in
        multiarch) DIRECTORY=multiarch; COMPOSE_DIRECTORY=multiarch ;;
        *) steam_die "Unknown target: $TARGET" ;;
    esac
    case "${RUNTIME_PLATFORM:-}" in
        '') ;;
        linux/amd64) ARCH=amd64 ;;
        linux/arm64) ARCH=arm64 ;;
        *) steam_die 'Supported runtime platforms: linux/amd64, linux/arm64.' ;;
    esac
    local hash
    hash=$(printf '%s' "$ROOT" | sha256sum)
    PROJECT=${hash:0:12}
    CONTAINER="stardew-dev-$PROJECT-$TARGET"
    IMAGE="localhost/stardew-dev-$PROJECT:$TARGET"
}

require_handler() {
    local arch=$1 handler
    case "$arch" in
        arm64) handler=/proc/sys/fs/binfmt_misc/qemu-aarch64 ;;
        amd64) handler=/proc/sys/fs/binfmt_misc/qemu-x86_64 ;;
        *) steam_die "Unsupported emulated architecture: $arch" ;;
    esac
    if [[ ! -f "$handler" ]] || ! grep -qx enabled "$handler" || ! grep -q '^flags:.*F' "$handler"; then
        steam_die "Missing enabled persistent (F) handler: $handler. See docs/local-development.md."
    fi
}

podman_doctor() {
    local mode=${1:-runtime} info host tool build_arch
    [[ $EUID -ne 0 ]] || steam_die 'Use rootless Podman, never sudo podman.'
    for tool in podman curl timeout; do
        command -v "$tool" >/dev/null || steam_die "Missing prerequisite: $tool"
    done
    info=$(podman info --format json)
    jq -e '.host.security.rootless == true' <<< "$info" >/dev/null ||
        steam_die 'Podman is not rootless.'
    host=$(jq -er .host.arch <<< "$info")
    if [[ "$mode" == build ]]; then
        for build_arch in amd64 arm64; do
            [[ "$host" == "$build_arch" ]] || require_handler "$build_arch"
        done
    elif [[ "$mode" != management ]]; then
        [[ "$host" == "$ARCH" ]] || require_handler "$ARCH"
    fi
    printf 'Rootless Podman: host %s, target %s.\n' "$host" "$ARCH"
}

verify_runtime_image() {
    podman manifest exists "$IMAGE" ||
        steam_die 'Missing local multiarchitecture manifest; build multiarch first.'
    podman manifest inspect "$IMAGE" | jq -e \
        '([.manifests[].platform | .os + "/" + .architecture] | sort) == ["linux/amd64", "linux/arm64"]' >/dev/null ||
        steam_die 'Local manifest must contain exactly linux/amd64 and linux/arm64.'
}

read_private_env() {
    local path=$1 line key value permissions
    safe_path "$path"
    path=$SAFE_PATH
    [[ -f "$path" && ! -L "$path" ]] || steam_die 'Use --env-file with a private regular file.'
    [[ "$(stat -c %u "$path")" == "$EUID" ]] || steam_die 'Runtime env file must belong to you.'
    [[ "$(stat -c %h "$path")" == 1 ]] || steam_die 'Runtime env file must not have hard links.'
    permissions=$(stat -c %a "$path")
    (( (8#$permissions & 077) == 0 )) || steam_die 'Runtime env file must have mode 600 or stricter.'
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "$line" != \#* ]] || continue
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ && "$line" != *$'\r'* ]] ||
            steam_die 'Runtime env file requires literal unquoted KEY=value lines.'
        key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
        [[ "$key" != STEAM_* ]] || steam_die 'Never supply Steam account settings to a container.'
        PRIVATE_ENV["$key"]=$value
    done < "$path"
}

resolve_value() {
    local key=$1 fallback=$2 required=$3 value status
    if [[ -v "PRIVATE_ENV[$key]" ]]; then
        value=${PRIVATE_ENV[$key]}
    elif value=$(printenv "$key"); then
        :
    else
        status=$?
        [[ "$status" == 1 ]] || steam_die "Cannot read runtime setting: $key"
        value=$fallback
    fi
    [[ "$required" != yes || -n "$value" ]] || steam_die "Required runtime setting missing: $key"
    printf '%s' "$value"
}

compose_environment() {
    local line active=no key expression source operator fallback
    local -a environment_keys
    mapfile -t environment_keys < <(compgen -e)
    for key in "${environment_keys[@]}" "${!PRIVATE_ENV[@]}"; do
        case "$key" in
            TIME_SPEED_*|CROPS_ANYTIME_ANYWHERE_*)
                steam_die "Retired setting: $key. Remove it; TimeSpeed and Crops Anytime Anywhere now use mod defaults or an existing config.json." ;;
        esac
    done
    local assignment='^      - ([A-Z][A-Z0-9_]*)=(.*)$'
    local substitution='^\$\{([A-Z][A-Z0-9_]*)(-|:\?)(.*)\}$'
    SETTINGS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == '    environment:' ]]; then active=yes; continue; fi
        [[ "$active" == yes ]] || continue
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^'    '[^[:space:]] ]] && break
        [[ "$line" =~ $assignment ]] || steam_die 'Unsupported Compose environment syntax; update the reader.'
        key=${BASH_REMATCH[1]}; expression=${BASH_REMATCH[2]}
        if [[ "$expression" == "\${"* ]]; then
            [[ "$expression" =~ $substitution ]] || steam_die "Unsupported substitution for $key."
            source=${BASH_REMATCH[1]}; operator=${BASH_REMATCH[2]}; fallback=${BASH_REMATCH[3]}
            if [[ "$operator" == ':?' ]]; then
                SETTINGS["$key"]=$(resolve_value "$source" '' yes)
            else
                SETTINGS["$key"]=$(resolve_value "$source" "$fallback" no)
            fi
        else
            SETTINGS["$key"]=$expression
        fi
    done < "$ROOT/$COMPOSE_DIRECTORY/docker-compose-steam.yml"
    (( ${#SETTINGS[@]} > 0 )) || steam_die 'Compose environment contract is empty.'
    for key in "${!PRIVATE_ENV[@]}"; do
        if [[ -v "SETTINGS[$key]" ]]; then SETTINGS["$key"]=${PRIVATE_ENV[$key]}; fi
    done
}

container_exists() {
    local status
    if podman container exists "$CONTAINER"; then return 0; else status=$?; fi
    [[ "$status" == 1 ]] || steam_die 'Unable to query development container.'
    return 1
}

require_owned() {
    local owner
    owner=$(podman inspect --format "{{index .Config.Labels \"$STARDEW_LABEL\"}}" "$CONTAINER")
    [[ "$owner" == "$PROJECT" ]] || steam_die 'Refusing to operate on a container not owned by this helper.'
}

stop_container() {
    if container_exists; then
        require_owned
        CONTAINER=$(podman inspect --format '{{.Id}}' "$CONTAINER")
        [[ "$CONTAINER" =~ ^[a-f0-9]{64}$ ]] || steam_die 'Invalid immutable container ID.'
        require_owned
        podman stop --time 20 "$CONTAINER" || return "$?"
        podman rm "$CONTAINER"
    fi
}

safe_path() {
    local input=$1 part path=''
    [[ "$input" == /* ]] || input="$ROOT/$input"
    [[ "$input" != *$'\n'* && "$input" != *$'\r'* ]] || steam_die 'Unsafe path.'
    [[ "$input" == "$(realpath -ms -- "$input")" ]] || steam_die 'Use a canonical path without dot segments or repeated separators.'
    local -a parts
    IFS=/ read -r -a parts <<< "$input"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        path="$path/$part"
        [[ ! -L "$path" ]] || steam_die 'Path parents and entries must not be symlinks.'
    done
    SAFE_PATH=$input
}

private_directory() {
    local path=$1 permissions
    [[ ! -L "$path" ]] || steam_die 'Private directories must not be symlinks.'
    if [[ -e "$path" ]]; then
        [[ -d "$path" && "$(stat -c %u "$path")" == "$EUID" ]] ||
            steam_die 'Private directories must belong to you.'
        permissions=$(stat -c %a "$path")
        (( (8#$permissions & 077) == 0 )) || steam_die 'Private directories must have mode 700 or stricter.'
    fi
}

validation_path() {
    safe_path "$1"
    [[ "$SAFE_PATH" == "$ROOT/.local/validation/"* ]] ||
        steam_die 'Explicit paths must be descendants beneath this repository .local/validation.'
    local path="$SAFE_PATH" component
    while [[ "$path" != "$ROOT" ]]; do
        component=${path##*/}
        case "$component" in
            v3arm|v3arm64|v3x86|v3arm-amd64|v4x86_x11vnc|v4x86-x11vnc|migrations|migrated)
                steam_die 'Legacy or migrated state is not disposable validation state.' ;;
        esac
        [[ ! -e "$path" || -d "$path" ]] || steam_die 'Validation path must be a directory.'
        private_directory "$path"
        path=${path%/*}
    done
}

validate_state_root() {
    if [[ -n "${STATE_ROOT:-}" ]]; then
        validation_path "$STATE_ROOT"
        STATE_ROOT=$SAFE_PATH
        STATE="$STATE_ROOT/$TARGET"
        safe_path "$STATE"
        private_directory "$STATE"
        if [[ -e "$STATE" ]]; then
            if ! [[ -f "$STATE/.disposable-state" && ! -L "$STATE/.disposable-state" &&
                "$(stat -c %u:%h "$STATE/.disposable-state")" == "$EUID:1" &&
                "$(cat "$STATE/.disposable-state")" == "$PROJECT:$STATE_ROOT" ]]; then
                steam_die 'Existing state is not owned disposable validation state.'
            fi
        fi
    else
        STATE="$ROOT/.local/podman/$TARGET"
        safe_path "$STATE"
        private_directory "$ROOT/.local"
        private_directory "$ROOT/.local/podman"
        private_directory "$STATE"
    fi
}

validate_cid_file() {
    [[ -n "${CID_FILE:-}" ]] || return 0
    safe_path "$CID_FILE"
    CID_FILE=$SAFE_PATH
    [[ ! -e "$CID_FILE" && ! -L "$CID_FILE" ]] || steam_die 'CID receipt must not already exist.'
    validation_path "${CID_FILE%/*}"
    [[ -d "${CID_FILE%/*}" ]] || steam_die 'CID receipt parent must already exist.'
}

lock_normal_state() {
    [[ -z "${STATE_ROOT:-}" ]] || return 0
    validate_state_root
    mkdir -p "$ROOT/.local/podman"
    local lock="$ROOT/.local/podman/.multiarch-migration.lock" permissions
    [[ ! -L "$lock" ]] || steam_die 'Migration lock must not be a symlink.'
    if [[ -e "$lock" ]]; then
        [[ -f "$lock" && "$(stat -c %u:%h "$lock")" == "$EUID:1" ]] ||
            steam_die 'Migration lock must be a private owned regular file.'
        permissions=$(stat -c %a "$lock")
        (( (8#$permissions & 077) == 0 )) || steam_die 'Migration lock must be private.'
    fi
    exec {MIGRATION_LOCK_FD}>>"$lock"
    flock -s "$MIGRATION_LOCK_FD"
}

prepare_state() {
    local path
    validate_state_root
    if [[ -n "${STATE_ROOT:-}" ]]; then
        if [[ ! -e "$STATE" ]]; then
            mkdir -p "$STATE_ROOT"
            mkdir "$STATE"
            (set -o noclobber; printf '%s\n' "$PROJECT:$STATE_ROOT" > "$STATE/.disposable-state")
        fi
    else
        mkdir -p "$STATE"
    fi
    for path in "$STATE/config" "$STATE/autoload.json"; do
        [[ ! -L "$path" ]] || steam_die 'Runtime config paths must not be symlinks.'
    done
    [[ ! -e "$STATE/config" || -d "$STATE/config" ]] || steam_die 'Runtime config must be a directory.'
    if [[ -e "$STATE/autoload.json" ]]; then
        [[ -f "$STATE/autoload.json" && "$(stat -c %h "$STATE/autoload.json")" == 1 ]] ||
            steam_die 'Runtime autoload config must be a regular file without hard links.'
    fi
    mkdir -p "$STATE/config"
    if [[ ! -e "$STATE/autoload.json" ]]; then
        printf '%s\n' '{"LastFileLoaded":null,"LoadIntoMultiplayer":true,"ForgetLastFileOnTitle":true}' \
            > "$STATE/autoload.json"
    fi
}

wait_for_game() {
    local elapsed=0 running process_pattern game=no browser=no logs=no mods=no
    if [[ "$MODDED" == 1 ]]; then process_pattern='[S]tardewModdingAPI'; else process_pattern='[S]tardew Valley'; fi
    while (( elapsed < STARTUP_TIMEOUT )); do
        running=$(podman inspect --format '{{.State.Running}}' "$CONTAINER")
        [[ "$running" == true ]] || steam_die 'Container exited before game readiness; inspect private logs.'
        game=no; browser=no; logs=no; mods=no
        if podman exec "$CONTAINER" pgrep -f "$process_pattern" >/dev/null 2>&1; then game=yes; fi
        if curl --fail --silent --max-time 2 "http://127.0.0.1:$WEB_PORT/" >/dev/null; then browser=yes; fi
        if [[ "$MODDED" == 0 ]]; then
            logs=yes; mods=yes
        elif podman exec "$CONTAINER" test /config/xdg/config/StardewValley/ErrorLogs/SMAPI-latest.txt \
                -nt /config/.dev-launch-start >/dev/null 2>&1; then
            logs=yes
            if podman exec "$CONTAINER" grep -Eq \
                    'INFO[[:space:]]+SMAPI\] Loaded [0-9]+ mods?:' \
                    /config/xdg/config/StardewValley/ErrorLogs/SMAPI-latest.txt; then
                mods=yes
            fi
        fi
        if [[ "$game" == yes && "$browser" == yes && "$logs" == yes && "$mods" == yes ]]; then return; fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    steam_die "Startup timeout (game=$game browser=$browser fresh-smapi-log=$logs mods-loaded=$mods); desktop visibility alone is not readiness."
}
