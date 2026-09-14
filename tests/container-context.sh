#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib/steam-cache.sh"
source "$ROOT/tests/fixtures/cache.sh"

[[ $EUID -ne 0 ]] || steam_die 'Run integration checks through rootless Podman.'
podman info --format json | jq -e '.host.security.rootless' >/dev/null
umask 077
[[ ! -L "$ROOT/.local" && ! -L "$ROOT/.local/validation" ]] || steam_die 'Unsafe context evidence parents.'
work="$ROOT/.local/validation/context-$BASHPID-$RANDOM"
mkdir -p "$work"
export TMPDIR="$work"
suffix=${work##*/}
suffix=${suffix,,}
images=()
container=
cleanup() {
    status=$?
    trap - EXIT
    if [[ -n "$container" ]] && podman container exists "$container"; then
        podman rm "$container" >/dev/null || status=1
    fi
    for image in "${images[@]}"; do
        if podman image exists "$image"; then
            podman image rm "$image" >/dev/null || status=1
        fi
    done
    if (( status != 0 )); then
        printf 'Context test diagnostics retained at %s\n' "$work" >&2
    else
        rm -rf -- "$work"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cache_fixture "$work/steam"
mkdir "$work/empty"

project=multiarch
image="localhost/stardew-context-test-$suffix:$project"
if podman image exists "$image"; then steam_die 'Conflicting context-test image exists.'; fi
images+=("$image")
contexts=(--build-context "steam=$work/steam" --build-context "devtools=$ROOT/scripts")
contexts+=(--build-context "mods=$ROOT/mods")
if ! podman build --platform linux/amd64 --layers --target validated --tag "$image" \
    "${contexts[@]}" --ignorefile "$ROOT/$project/docker/Dockerfile-steam.dockerignore" \
    --file "$ROOT/$project/docker/Dockerfile-steam" "$ROOT/$project/docker" \
    > "$work/$project.log" 2>&1; then
    tail -40 "$work/$project.log" >&2
    exit 1
fi
printf 'PASS %s local context + named vanilla cache validation\n' "$project"

if podman build --platform linux/amd64 --layers --target validated \
    --build-context "steam=$work/empty" --build-context "devtools=$ROOT/scripts" \
    --build-context "mods=$ROOT/mods" \
    --ignorefile "$ROOT/multiarch/docker/Dockerfile-steam.dockerignore" \
    --file "$ROOT/multiarch/docker/Dockerfile-steam" "$ROOT/multiarch/docker" \
    > "$work/missing.log" 2>&1; then
    steam_die 'Empty named cache unexpectedly passed image validation.'
fi
grep -q 'builds never download Steam or game files' "$work/missing.log"
printf 'PASS empty named cache fails with actionable diagnostics\n'

mkdir -p "$work/context/game_data" "$work/context/mods" "$work/context/rootfs" "$work/context/build"
printf 'FROM scratch\nCOPY . /context/\n' > "$work/context/Dockerfile-steam"
printf 'exclude this installer\n' > "$work/context/game_data/installer"
printf 'exclude this private input\n' > "$work/context/runtime.local.env"
printf 'include when required\n' > "$work/context/mods/manifest.json"
printf 'include when required\n' > "$work/context/rootfs/service"
printf 'include when required\n' > "$work/context/build/setup-arch"
image="localhost/stardew-context-test-$suffix:ignore-$project"
if podman image exists "$image"; then steam_die 'Conflicting context-test image exists.'; fi
images+=("$image")
podman build --quiet --tag "$image" \
    --ignorefile "$ROOT/$project/docker/Dockerfile-steam.dockerignore" \
    --file "$work/context/Dockerfile-steam" "$work/context" > "$work/ignore-$project.log" 2>&1
container="stardew-context-test-$suffix"
container=$(podman create --name "$container" "$image" /unused)
[[ "$container" =~ ^[a-f0-9]{64}$ ]] || steam_die 'Invalid context container ID.'
podman export "$container" | tar -tf - > "$work/export-$project"
if grep -qE 'game_data|runtime.local.env|context/mods/' "$work/export-$project"; then
    steam_die "Forbidden input leaked through $project ignore rules."
fi
podman rm "$container" > /dev/null
container=
printf 'PASS %s context excludes installers and private runtime settings\n' "$project"
