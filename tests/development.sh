#!/usr/bin/env bash
# The PTY child expands its environment; sourced helper scratch variables are subshell-local.
# shellcheck disable=SC2016,SC2031
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

cases=(cache-valid cache-corrupt cache-missing cache-symlink cache-contamination cache-permissions
    cache-schema cache-extra-file cache-symlink-change publication recovery
    downloader-reuse downloader-failure downloader-refresh
    compose-parity compose-empty missing-build build-matrix build-failure build-lock
    buildx-manifest buildx-failure buildx-invalid buildx-preflight build-no-cache runtime-platform runtime-manifest-missing
    runtime-manifest-invalid manifest-shapes runtime-conflict rejected-targets irrelevant-options state-isolation state-paths migration-lock
    private-env private-paths run-command run-failure smoke-cleanup ownership)

if (( $# == 0 )); then
    failed=0
    for name in "${cases[@]}"; do
        if bash "${BASH_SOURCE[0]}" "$name"; then
            printf 'PASS %s\n' "$name"
        else
            printf 'FAIL %s\n' "$name" >&2
            failed=$((failed + 1))
        fi
    done
    printf '%s cases, %s failures\n' "${#cases[@]}" "$failed"
    exit "$((failed != 0))"
fi

umask 077
[[ ! -L "$ROOT/.local" && ! -L "$ROOT/.local/validation" ]] || exit 1
work="$ROOT/.local/validation/development-$BASHPID-$RANDOM"
mkdir -p "$work"
export TMPDIR="$work"
trap 'rm -rf -- "$work"' EXIT
test_repo="$work/repo"
mkdir -p "$test_repo/scripts/lib" "$test_repo/src" "$work/bin"
cp "$ROOT"/scripts/*.sh "$test_repo/scripts/"
cp "$ROOT"/scripts/lib/*.sh "$test_repo/scripts/lib/"
cp "$ROOT/pullValleyBin.sh" "$test_repo/"
mkdir -p "$test_repo/multiarch/docker"
cp "$ROOT/multiarch/docker-compose-steam.yml" "$test_repo/multiarch/"
cp "$ROOT/multiarch/docker/Dockerfile-steam" "$test_repo/multiarch/docker/"
cp "$ROOT/multiarch/docker/Dockerfile-steam.dockerignore" "$test_repo/multiarch/docker/"
source "$ROOT/scripts/lib/steam-cache.sh"
source "$ROOT/tests/fixtures/cache.sh"

fixture() {
    cache_fixture "$1"
}

expect_invalid() {
    if bash "$test_repo/scripts/validate-steam-cache.sh" "$1" > "$work/error" 2>&1; then
        echo 'Invalid fixture was accepted.' >&2
        exit 1
    fi
}

mock_podman() {
    cp "$ROOT/tests/fixtures/podman" "$work/bin/podman"
    chmod +x "$work/bin/podman"
    export PATH="$work/bin:$PATH" MOCK_PODMAN_CALLS="$work/podman.calls"
    export MOCK_RUNTIME_ENV="$work/runtime.env"
    local hash
    hash=$(printf '%s' "$test_repo" | sha256sum)
    export MOCK_OWNER="${hash:0:12}"
    # Exercise host/handler combinations explicitly in buildx-preflight.
    printf '\nrequire_handler() { :; }\n' >> "$test_repo/scripts/lib/podman-steam.sh"
}

private_env() {
    printf 'VNC_PASSWORD=synthetic-test-password\nALWAYS_ON_SERVER_PET_NAME=Dev pet\n' > "$work/private.env"
    chmod 600 "$work/private.env"
}

downloader_setup() {
    command -v script >/dev/null
    export XDG_DATA_HOME="$work/user-data" TEST_REPO="$test_repo"
    export MOCK_STEAM_CALLS="$work/steam.calls" MOCK_STEAM_FIXTURE="$work/download"
    fixture "$MOCK_STEAM_FIXTURE"
    local home="$XDG_DATA_HOME/stardew-dev/steamcmd"
    mkdir -p "$home/linux32" "$home/linux64"
    cp "$ROOT/tests/fixtures/steamcmd.sh" "$home/steamcmd.sh"
    cp "$MOCK_STEAM_FIXTURE/steam-sdk/sdk32/steamclient.so" "$home/linux32/"
    cp "$MOCK_STEAM_FIXTURE/steam-sdk/sdk64/steamclient.so" "$home/linux64/"
}

case "$1" in
    cache-valid)
        fixture "$test_repo/src/steam"
        steam_validate "$test_repo/src/steam" ;;
    cache-missing) expect_invalid "$test_repo/src/steam" ;;
    cache-corrupt)
        fixture "$test_repo/src/steam"
        printf bad >> "$test_repo/src/steam/game/Stardew Valley.dll"
        expect_invalid "$test_repo/src/steam" ;;
    cache-symlink)
        fixture "$test_repo/src/steam"
        ln -s /etc/passwd "$test_repo/src/steam/game/escape"
        expect_invalid "$test_repo/src/steam" ;;
    cache-contamination)
        fixture "$test_repo/src/steam"
        mkdir "$test_repo/src/steam/game/Mods"
        expect_invalid "$test_repo/src/steam" ;;
    cache-permissions)
        fixture "$test_repo/src/steam"
        chmod -x "$test_repo/src/steam/game/StardewValley"
        expect_invalid "$test_repo/src/steam" ;;
    cache-schema)
        fixture "$test_repo/src/steam"
        sed -i 's/"schema": 1/"schema": 9/' "$test_repo/src/steam/manifest.json"
        expect_invalid "$test_repo/src/steam" ;;
    cache-extra-file)
        fixture "$test_repo/src/steam"
        printf unexpected > "$test_repo/src/steam/game/extra"
        expect_invalid "$test_repo/src/steam" ;;
    cache-symlink-change)
        fixture "$test_repo/src/steam"
        ln -snf './Content/test file.txt' "$test_repo/src/steam/game/content-link"
        expect_invalid "$test_repo/src/steam" ;;
    publication)
        fixture "$test_repo/src/steam"
        fixture "$work/new"
        printf updated >> "$work/new/game/Stardew Valley.dll"
        steam_seal "$work/new" 456
        steam_lock "$test_repo" -x
        steam_publish "$test_repo" "$work/new"
        [[ ! -d "$test_repo/src/.steam-backup" ]]
        [[ "$(jq -r .steam_build_id "$test_repo/src/steam/manifest.json")" == 456 ]]
        steam_validate "$test_repo/src/steam" ;;
    recovery)
        fixture "$test_repo/src/.steam-backup"
        steam_lock "$test_repo" -x
        steam_recover "$test_repo"
        steam_validate "$test_repo/src/steam"
        fixture "$test_repo/src/.steam-backup"
        if (steam_check_recovery "$test_repo") > "$work/error" 2>&1; then exit 1; fi ;;
    downloader-reuse)
        fixture "$test_repo/src/steam"
        bash "$test_repo/pullValleyBin.sh" > "$work/output"
        grep -q 'without network access' "$work/output" ;;
    downloader-failure)
        downloader_setup
        fixture "$test_repo/src/steam"
        original=$(sha256sum < "$test_repo/src/steam/manifest.json")
        export MOCK_STEAM_FAIL=1
        if printf 'mock-account\n' | script -q -e -c 'bash "$TEST_REPO/pullValleyBin.sh" --refresh' \
            /dev/null > "$work/output"; then exit 1; fi
        [[ "$(sha256sum < "$test_repo/src/steam/manifest.json")" == "$original" ]]
        [[ "$(wc -l < "$MOCK_STEAM_CALLS")" == 1 ]]
        steam_validate "$test_repo/src/steam" ;;
    downloader-refresh)
        downloader_setup
        printf 'mock-account\n' | script -q -e -c 'bash "$TEST_REPO/pullValleyBin.sh"' /dev/null > "$work/output"
        steam_validate "$test_repo/src/steam"
        printf updated >> "$MOCK_STEAM_FIXTURE/game/Stardew Valley.dll"
        printf 'mock-account\n' | script -q -e -c 'bash "$TEST_REPO/pullValleyBin.sh" --refresh' /dev/null > "$work/output"
        steam_validate "$test_repo/src/steam"
        [[ "$(wc -l < "$MOCK_STEAM_CALLS")" == 2 ]]
        grep -q updated "$test_repo/src/steam/game/Stardew Valley.dll" ;;
    compose-parity)
        ROOT=$test_repo
        source "$ROOT/scripts/lib/podman-steam.sh"
        declare -A SETTINGS=() PRIVATE_ENV=([VNC_PASSWORD]=synthetic-password)
        export ENABLE_AUTOLOADGAME=false ENABLE_UNLIMITEDPLAYERS=true
        sed -i 's/UNLIMITED_PLAYERS_PLAYER_LIMIT-10/UNLIMITED_PLAYERS_PLAYER_LIMIT-12/' \
            "$test_repo/multiarch/docker-compose-steam.yml"
        for target in "${STEAM_TARGETS[@]}"; do
            select_target "$target"
            [[ "$COMPOSE_DIRECTORY" == "$DIRECTORY" ]]
            compose_environment
            [[ "${SETTINGS[ENABLE_AUTOLOADGAME_MOD]}" == false ]]
            [[ "${SETTINGS[ENABLE_UNLIMITEDPLAYERS_MOD]}" == true ]]
            [[ "${SETTINGS[UNLIMITED_PLAYERS_PLAYER_LIMIT]}" == 12 ]]
            [[ "${SETTINGS[VNC_PASSWORD]}" == synthetic-password ]]
        done ;;
    compose-empty)
        ROOT=$test_repo
        source "$ROOT/scripts/lib/podman-steam.sh"
        declare -A SETTINGS=([STALE_SETTING]=old-value) PRIVATE_ENV=()
        select_target multiarch
        printf 'services:\n' > "$test_repo/multiarch/docker-compose-steam.yml"
        if (compose_environment) > "$work/error" 2>&1; then exit 1; fi
        grep -q 'Compose environment contract is empty' "$work/error" ;;
    missing-build)
        mock_podman
        if bash "$test_repo/scripts/podman-steam.sh" build multiarch > "$work/error" 2>&1; then exit 1; fi
        [[ ! -e "$MOCK_PODMAN_CALLS" ]]
        grep -q 'builds never download' "$work/error" ;;
    build-matrix)
        fixture "$test_repo/src/steam"
        mock_podman
        bash "$test_repo/scripts/podman-steam.sh" build all > "$work/output"
        [[ "$(grep -c '^buildx build --platform linux/amd64,linux/arm64' "$MOCK_PODMAN_CALLS")" == 1 ]]
        grep -q 'multiarch/docker/Dockerfile-steam' "$MOCK_PODMAN_CALLS"
        grep -q -- "--build-context steam=$test_repo/src/steam" "$MOCK_PODMAN_CALLS"
        grep -q -- "--build-context devtools=$test_repo/scripts" "$MOCK_PODMAN_CALLS"
        [[ "$(grep -c -- "--build-context mods=$test_repo/mods" "$MOCK_PODMAN_CALLS")" == 1 ]]
        grep -qx '        mods: ../mods' "$test_repo/multiarch/docker-compose-steam.yml"
        grep -qx 'FROM scratch AS mods' "$test_repo/multiarch/docker/Dockerfile-steam"
        grep -qx 'COPY --from=mods / /data/Stardew/game/Mods/' "$test_repo/multiarch/docker/Dockerfile-steam"
        if grep -q 'extends:' "$test_repo/multiarch/docker-compose-steam.yml"; then exit 1; fi
        grep -q -- "$test_repo/multiarch/docker\$" "$MOCK_PODMAN_CALLS"
        if grep -E 'STEAM_PASS|app_update|steamcmd' "$MOCK_PODMAN_CALLS"; then exit 1; fi ;;
    build-failure)
        fixture "$test_repo/src/steam"
        mock_podman
        export MOCK_BUILD_FAIL=1
        if bash "$test_repo/scripts/podman-steam.sh" build multiarch > "$work/error" 2>&1; then exit 1; fi ;;
    build-lock)
        fixture "$test_repo/src/steam"
        mock_podman
        export MOCK_CHECK_LOCK="$test_repo/src/.steam-cache.lock"
        bash "$test_repo/scripts/podman-steam.sh" build multiarch > "$work/output" ;;
    buildx-manifest|buildx-failure|buildx-invalid|build-no-cache)
        fixture "$test_repo/src/steam"
        mock_podman
        export MOCK_CHECK_LOCK="$test_repo/src/.steam-cache.lock"
        expected=0
        case "$1" in
            buildx-failure) export MOCK_BUILD_FAIL=1; expected=23 ;;
            buildx-invalid) export MOCK_MANIFEST_BAD=1; expected=1 ;;
        esac
        status=0
        extra=()
        [[ "$1" != build-no-cache ]] || extra=(--no-cache)
        bash "$test_repo/scripts/podman-steam.sh" build multiarch "${extra[@]}" > "$work/output" 2>&1 || status=$?
        [[ "$status" == "$expected" ]]
        grep -q '^buildx build --platform linux/amd64,linux/arm64 --manifest ' "$MOCK_PODMAN_CALLS"
        grep -q -- "--build-context mods=$test_repo/mods" "$MOCK_PODMAN_CALLS"
        if [[ "$expected" == 0 ]]; then
            grep -q '^tag .*:multiarch$' "$MOCK_PODMAN_CALLS"
            grep -q '^manifest rm ' "$MOCK_PODMAN_CALLS"
            if grep -q '^untag ' "$MOCK_PODMAN_CALLS"; then exit 1; fi
        else
            grep -q '^manifest rm ' "$MOCK_PODMAN_CALLS"
            if grep -q '^tag ' "$MOCK_PODMAN_CALLS"; then exit 1; fi
        fi
        if [[ "$1" == build-no-cache ]]; then
            grep '^buildx build ' "$MOCK_PODMAN_CALLS" | grep -q -- ' --no-cache '
        elif grep -q -- ' --no-cache ' "$MOCK_PODMAN_CALLS"; then exit 1; fi ;;
    buildx-preflight)
        mock_podman
        ROOT=$test_repo
        source "$ROOT/scripts/lib/podman-steam.sh"
        select_target multiarch
        require_handler() { printf '%s\n' "$1" >> "$work/handlers"; }
        MOCK_HOST_ARCH=amd64 podman_doctor build >/dev/null
        [[ "$(cat "$work/handlers")" == arm64 ]]
        : > "$work/handlers"
        MOCK_HOST_ARCH=arm64 podman_doctor build >/dev/null
        [[ "$(cat "$work/handlers")" == amd64 ]]
        ;;
    runtime-platform|runtime-manifest-missing|runtime-manifest-invalid)
        mock_podman
        private_env
        printf '#!/bin/bash\nexit 0\n' > "$test_repo/scripts/wait-steam.sh"
        if [[ "$1" != runtime-platform ]]; then
            if [[ "$1" == runtime-manifest-missing ]]; then export MOCK_MANIFEST_MISSING=1
            else export MOCK_MANIFEST_BAD=1; fi
            if bash "$test_repo/scripts/podman-steam.sh" run multiarch --platform linux/amd64 \
                --env-file "$work/private.env" > "$work/output" 2>&1; then exit 1; fi
            grep -Eq 'build multiarch first|exactly linux/amd64 and linux/arm64' "$work/output"
            if grep -q '^run ' "$MOCK_PODMAN_CALLS"; then exit 1; fi
        else
            for platform in default linux/amd64 linux/arm64; do
                extra=()
                [[ "$platform" == default ]] || extra=(--platform "$platform")
                bash "$test_repo/scripts/podman-steam.sh" smoke all "${extra[@]}" \
                    --env-file "$work/private.env" > "$work/output"
            done
            [[ "$(grep '^run ' "$MOCK_PODMAN_CALLS" | grep -c -- '--platform linux/amd64')" == 1 ]]
            [[ "$(grep '^run ' "$MOCK_PODMAN_CALLS" | grep -c -- '--platform linux/arm64')" == 2 ]]
            if bash "$test_repo/scripts/podman-steam.sh" build multiarch --platform linux/amd64 > "$work/error" 2>&1; then exit 1; fi
            if bash "$test_repo/scripts/podman-steam.sh" run multiarch --platform linux/386 > "$work/error" 2>&1; then exit 1; fi
        fi ;;
    private-env)
        ROOT=$test_repo
        source "$ROOT/scripts/lib/podman-steam.sh"
        declare -A PRIVATE_ENV=()
        private_env
        read_private_env "$work/private.env"
        [[ "${PRIVATE_ENV[ALWAYS_ON_SERVER_PET_NAME]}" == 'Dev pet' ]]
        chmod 644 "$work/private.env"
        if (read_private_env "$work/private.env") > "$work/error" 2>&1; then exit 1; fi ;;
    manifest-shapes)
        fixture "$test_repo/src/steam"
        mock_podman
        for shape in duplicate extra wrong-os malformed; do
            export MOCK_MANIFEST_SHAPE=$shape
            : > "$MOCK_PODMAN_CALLS"
            if bash "$test_repo/scripts/podman-steam.sh" build multiarch > "$work/error" 2>&1; then exit 1; fi
            grep -q 'exactly the two requested platforms' "$work/error"
            grep -q '^manifest rm ' "$MOCK_PODMAN_CALLS"
            if grep -q '^tag ' "$MOCK_PODMAN_CALLS"; then exit 1; fi
        done
        unset MOCK_MANIFEST_SHAPE
        export MOCK_TAG_FAIL=1
        : > "$MOCK_PODMAN_CALLS"
        status=0
        bash "$test_repo/scripts/podman-steam.sh" build multiarch > "$work/error" 2>&1 || status=$?
        [[ "$status" == 26 ]]
        grep -q '^manifest rm .*:multiarch-build-' "$MOCK_PODMAN_CALLS"
        if grep -Eq '^(rmi|image rm|untag|system prune)|v3arm|v3x86|v4x86' "$MOCK_PODMAN_CALLS"; then exit 1; fi ;;
    runtime-conflict)
        mock_podman
        private_env
        for result in 0 125; do
            export MOCK_CONTAINER_EXISTS=$result
            if bash "$test_repo/scripts/podman-steam.sh" smoke multiarch \
                --env-file "$work/private.env" > "$work/error" 2>&1; then exit 1; fi
            [[ ! -e "$test_repo/.local" ]]
            if grep -Eq '^(run|stop|rm) ' "$MOCK_PODMAN_CALLS"; then exit 1; fi
        done ;;
    rejected-targets)
        mock_podman
        for old in v3arm v3arm64 v3x86 v3arm-amd64 v4x86_x11vnc v4x86-x11vnc unknown; do
            for action in doctor build run smoke logs stop; do
                if bash "$test_repo/scripts/podman-steam.sh" "$action" "$old" > "$work/error" 2>&1; then exit 1; fi
                grep -q 'Unknown target:' "$work/error"
            done
        done
        [[ ! -e "$MOCK_PODMAN_CALLS" && ! -e "$test_repo/.local" ]] ;;
    irrelevant-options)
        mock_podman
        for action in doctor run smoke logs stop; do
            if bash "$test_repo/scripts/podman-steam.sh" "$action" multiarch --no-cache > "$work/error" 2>&1; then exit 1; fi
            grep -q 'build-only' "$work/error"
        done
        for action in doctor build logs stop; do
            for option in --state-root --env-file --cid-file --web-port --vnc-port --game-port --timeout; do
                if bash "$test_repo/scripts/podman-steam.sh" "$action" multiarch "$option" unused > "$work/error" 2>&1; then exit 1; fi
                grep -q 'only for run or smoke' "$work/error"
            done
            if bash "$test_repo/scripts/podman-steam.sh" "$action" multiarch --lan > "$work/error" 2>&1; then exit 1; fi
        done
        for action in build logs stop; do
            if bash "$test_repo/scripts/podman-steam.sh" "$action" multiarch --platform linux/amd64 > "$work/error" 2>&1; then exit 1; fi
        done
        [[ ! -e "$MOCK_PODMAN_CALLS" && ! -e "$test_repo/.local" ]] ;;
    state-isolation)
        mock_podman
        private_env
        printf '#!/bin/bash\nexit 0\n' > "$test_repo/scripts/wait-steam.sh"
        state_root="$test_repo/.local/validation/isolated/state"
        mkdir -p "$test_repo/.local/podman/multiarch/config" "$test_repo/.local/podman/v3arm64/config" \
            "$test_repo/.local/validation/isolated"
        printf 'do not touch\n' > "$test_repo/.local/podman/multiarch/config/user-marker"
        printf 'legacy do not touch\n' > "$test_repo/.local/podman/v3arm64/config/user-marker"
        original=$(find "$test_repo/.local/podman" -type f -exec sha256sum {} +)
        for platform in linux/amd64 linux/arm64; do
            receipt="$test_repo/.local/validation/isolated/${platform#linux/}.cid"
            selected_root=$state_root
            [[ "$platform" != linux/arm64 ]] || selected_root=.local/validation/isolated/state
            bash "$test_repo/scripts/podman-steam.sh" smoke multiarch --platform "$platform" \
                --env-file "$work/private.env" --state-root "$selected_root" --cid-file "$receipt" > "$work/output"
            [[ "$(cat "$receipt")" =~ ^[a-f0-9]{64}$ ]]
        done
        [[ "$original" == "$(find "$test_repo/.local/podman" -type f -exec sha256sum {} +)" ]]
        grep '^run ' "$MOCK_PODMAN_CALLS" | grep -q -- "--volume $state_root/multiarch/config:/config:Z"
        [[ -f "$state_root/multiarch/.disposable-state" ]]
        [[ "$(find "$state_root" -name runtime.local.env | wc -l)" == 0 ]] ;;
    state-paths)
        mock_podman
        private_env
        base="$test_repo/.local/validation"
        mkdir -p "$base/good" "$base/unmarked/multiarch" "$base/public" "$test_repo/.local/podman/v3arm64"
        chmod 755 "$base/public"
        ln -s "$base/good" "$base/link"
        ln -s "$test_repo/.local/podman/v3arm64" "$base/good/multiarch"
        for state_root in "$test_repo" "$base" "$test_repo/.local/podman" "$test_repo/.local/podman/v3arm64" \
            "$work/outside" "$base/../podman" "$base//extra" "$base/link/state" "$base/good" \
            "$base/v3arm64/state" "$base/migrated/state" "$base/public/state" "$base/unmarked"; do
            if bash "$test_repo/scripts/podman-steam.sh" run multiarch --state-root "$state_root" \
                --env-file "$work/private.env" > "$work/error" 2>&1; then exit 1; fi
        done
        [[ ! -e "$MOCK_PODMAN_CALLS" ]]
        rm "$base/good/multiarch"
        mkdir -p "$test_repo/.local/podman"
        ln -s "$base/good" "$test_repo/.local/podman/multiarch"
        if bash "$test_repo/scripts/podman-steam.sh" run multiarch --env-file "$work/private.env" > "$work/error" 2>&1; then exit 1; fi
        [[ ! -e "$MOCK_PODMAN_CALLS" ]] ;;
    private-paths)
        mock_podman
        private_env
        base="$test_repo/.local/validation"
        mkdir -p "$base/receipts" "$base/public"
        chmod 755 "$base/public"
        ln -s "$base/receipts" "$base/link"
        printf 'existing\n' > "$base/receipts/existing.cid"
        for receipt in "$base/receipts/existing.cid" "$base/link/new.cid" "$base/public/new.cid" \
            "$base/missing/new.cid" "$work/outside.cid" "$base/../new.cid"; do
            if bash "$test_repo/scripts/podman-steam.sh" run multiarch --env-file "$work/private.env" \
                --cid-file "$receipt" > "$work/error" 2>&1; then exit 1; fi
        done
        [[ ! -e "$MOCK_PODMAN_CALLS" ]]
        ROOT=$test_repo
        source "$ROOT/scripts/lib/podman-steam.sh"
        declare -A PRIVATE_ENV=()
        ln -s "$work" "$base/env-link"
        if (read_private_env "$base/env-link/private.env") > "$work/error" 2>&1; then exit 1; fi
        ln "$work/private.env" "$base/linked.env"
        if (read_private_env "$base/linked.env") > "$work/error" 2>&1; then exit 1; fi
        [[ ! -e "$test_repo/.local/podman" ]] ;;
    migration-lock)
        mock_podman
        private_env
        printf '#!/bin/bash\nexit 0\n' > "$test_repo/scripts/wait-steam.sh"
        mkdir -p "$test_repo/.local/podman"
        lock="$test_repo/.local/podman/.multiarch-migration.lock"
        exec {lock_fd}>"$lock"
        flock -x "$lock_fd"
        # Disposable runs must not wait for migration or create production state.
        bash "$test_repo/scripts/podman-steam.sh" smoke multiarch --env-file "$work/private.env" \
            --state-root "$test_repo/.local/validation/disposable" > "$work/output"
        [[ ! -e "$test_repo/.local/podman/multiarch" ]]
        : > "$MOCK_PODMAN_CALLS"
        export MOCK_START_LOCK="$lock"
        (exec {lock_fd}>&-; bash "$test_repo/scripts/podman-steam.sh" smoke multiarch \
            --env-file "$work/private.env" > "$work/output") &
        runner=$!
        trap 'kill -TERM "$runner" 2>/dev/null || :; wait "$runner" 2>/dev/null || :; rm -rf -- "$work"' EXIT
        for ((attempt=0; attempt<50; attempt++)); do
            if grep -q '^manifest inspect ' "$MOCK_PODMAN_CALLS"; then break; fi
            sleep 0.1
        done
        sleep 0.2
        kill -0 "$runner"
        [[ ! -e "$test_repo/.local/podman/multiarch" ]]
        if grep -q '^run ' "$MOCK_PODMAN_CALLS"; then exit 1; fi
        flock -u "$lock_fd"
        wait "$runner"
        trap 'rm -rf -- "$work"' EXIT
        flock -n -x "$lock_fd"
        flock -u "$lock_fd"
        unset MOCK_START_LOCK
        rm "$lock"
        ln -s "$work/private.env" "$lock"
        if bash "$test_repo/scripts/podman-steam.sh" smoke multiarch --env-file "$work/private.env" > "$work/error" 2>&1; then exit 1; fi
        grep -q 'lock must not be a symlink' "$work/error" ;;
    run-command|smoke-cleanup)
        mock_podman
        private_env
        # Replace only readiness in this isolated fixture; no game is executed.
        printf '#!/bin/bash\nexit 0\n' > "$test_repo/scripts/wait-steam.sh"
        action=run
        [[ "$1" != smoke-cleanup ]] || action=smoke
        bash "$test_repo/scripts/podman-steam.sh" "$action" multiarch --env-file "$work/private.env" > "$work/output"
        grep -q -- '--userns=keep-id:uid=1000,gid=1000 --user 0:0' "$MOCK_PODMAN_CALLS"
        grep -q -- '--publish 127.0.0.1:5801:5800' "$MOCK_PODMAN_CALLS"
        grep -q '^ALWAYS_ON_SERVER_PET_NAME=Dev pet$' "$MOCK_RUNTIME_ENV"
        if grep -q 'synthetic-test-password' "$MOCK_PODMAN_CALLS" "$work/output"; then exit 1; fi
        [[ "$(find "$test_repo/.local" -name runtime.local.env | wc -l)" == 0 ]]
        if [[ "$action" == run ]]; then
            if grep -q '^stop ' "$MOCK_PODMAN_CALLS"; then exit 1; fi
        else
            grep -q '^exec --user 1000:1000 --env DISPLAY=:0 .* glxinfo -B$' "$MOCK_PODMAN_CALLS"
            grep -q '^stop --time 20 ' "$MOCK_PODMAN_CALLS"
            grep -q '^rm ' "$MOCK_PODMAN_CALLS"
        fi ;;
    run-failure)
        mock_podman
        private_env
        export MOCK_RUN_FAIL=1
        if bash "$test_repo/scripts/podman-steam.sh" run multiarch --env-file "$work/private.env" > "$work/error" 2>&1; then exit 1; fi
        grep -q 'Private diagnostics:' "$work/error"
        [[ "$(find "$test_repo/.local" -name runtime.local.env | wc -l)" == 0 ]] ;;
    ownership)
        mock_podman
        export MOCK_CONTAINER_EXISTS=0 MOCK_OWNER=some-other-project
        if bash "$test_repo/scripts/podman-steam.sh" stop multiarch > "$work/error" 2>&1; then exit 1; fi
        if grep -q '^stop ' "$MOCK_PODMAN_CALLS"; then exit 1; fi ;;
    *) echo "Unknown case: $1" >&2; exit 1 ;;
esac
