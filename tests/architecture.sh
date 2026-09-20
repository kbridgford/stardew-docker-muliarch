#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
umask 077
[[ ! -L "$ROOT/.local" && ! -L "$ROOT/.local/validation" ]]
work="$ROOT/.local/validation/architecture-$BASHPID-$RANDOM"
mkdir -p "$work/bin"
trap 'rm -rf -- "$work"' EXIT
cat > "$work/bin/dpkg" <<'SH'
#!/bin/bash
printf '%s\n' "$TEST_ARCH"
SH
# Isolate dispatch from header parsing, which tests/native-preparation.sh
# exercises using binary fixtures rather than mocked inspection.
cat > "$work/bin/od" <<'SH'
#!/bin/bash
case "$*" in
    *' -j 0 '*) printf '1179403647\n' ;;
    *' -j 4 '*) printf '2\n' ;;
    *' -j 5 '*) printf '1\n' ;;
    *' -j 18 '*)
        case "$TEST_ELF" in amd64) printf '62\n' ;; arm64) printf '183\n' ;; *) printf '0\n' ;; esac ;;
    *) exit 1 ;;
esac
SH
cat > "$work/bin/box64" <<'SH'
#!/bin/bash
echo 'Unexpected emulator invocation' >&2
exit 99
SH
cat > "$work/game app" <<'SH'
#!/bin/bash
printf 'arguments:%s:%s\n' "$#" "${1:-}"
printf 'callret:%s\n' "${BOX64_DYNAREC_CALLRET-unset}"
exit "${TEST_EXIT:-0}"
SH
chmod +x "$work/bin/"* "$work/game app"
export PATH="$work/bin:$PATH"
for architecture in amd64 arm64; do
    TEST_ARCH=$architecture TEST_ELF=$architecture BOX64_DYNAREC_CALLRET=2 \
        bash "$ROOT/scripts/container/exec-game.sh" "$work/game app" 'argument with spaces' > "$work/output"
    grep -Fxq 'arguments:1:argument with spaces' "$work/output"
    grep -Fxq 'callret:2' "$work/output"
    grep -Fxq "Container architecture $architecture: native game execution." "$work/output"
    status=0
    TEST_ARCH=$architecture TEST_ELF=$architecture TEST_EXIT=37 \
        bash "$ROOT/scripts/container/exec-game.sh" "$work/game app" > "$work/output" || status=$?
    [[ "$status" == 37 ]]
    if TEST_ARCH=$architecture TEST_ELF=invalid \
        bash "$ROOT/scripts/container/exec-game.sh" "$work/game app" > "$work/error" 2>&1; then exit 1; fi
    grep -q 'Wrong ELF architecture' "$work/error"
    printf 'PASS %s native dispatch, argument/exit preservation, wrong ELF rejection; no fallback\n' "$architecture"
done
if TEST_ARCH=riscv64 TEST_ELF=arm64 bash "$ROOT/scripts/container/exec-game.sh" "$work/game app" > "$work/error" 2>&1; then exit 1; fi
grep -q 'Unsupported architecture' "$work/error"
if bash "$ROOT/scripts/container/exec-game.sh" "$work/missing" > "$work/error" 2>&1; then exit 1; fi
grep -q 'Missing executable' "$work/error"
if TEST_ARCH=arm64 TARGETARCH=arm64 bash "$ROOT/multiarch/docker/build/setup-arch" > "$work/error" 2>&1; then exit 1; fi
grep -q 'Unexpected Box64' "$work/error"
rm "$work/bin/box64"
for architecture in amd64 arm64; do
    TEST_ARCH=$architecture TARGETARCH=$architecture bash "$ROOT/multiarch/docker/build/setup-arch" > "$work/output"
done
if TEST_ARCH=amd64 TARGETARCH=arm64 bash "$ROOT/multiarch/docker/build/setup-arch" > "$work/error" 2>&1; then exit 1; fi
grep -q 'does not match' "$work/error"
grep -Fxq 'ARG SMAPI_VERSION=4.5.2' "$ROOT/multiarch/docker/Dockerfile-steam"
grep -Fxq 'ARG SMAPI_SHA256=dd01ddca7b566bfe0d3b3d2d03833496abc56c53da976241f2ab443f5484acc4' "$ROOT/multiarch/docker/Dockerfile-steam"
grep -Fxq 'ARG VALLEYCORE_VERSION=1.6.15g' "$ROOT/multiarch/docker/Dockerfile-steam"
grep -Fxq 'ARG VALLEYCORE_SHA256=e5949546b0574aaa7b8bf87939569c3cd4d1336857717d01aa9fb88bb3d7c467' "$ROOT/multiarch/docker/Dockerfile-steam"
printf 'PASS native setup, architecture guards and exact artifact pins\n'
mkdir -p "$work/payload" "$work/config"
cp "$work/game app" "$work/payload/Stardew Valley"
cat > "$work/capture" <<'SH'
#!/bin/bash
[[ $# == 2 && "$2" == 'argument with spaces' ]]
printf 'forwarded\n'
SH
chmod +x "$work/capture"
sed -e "s#/config#$work/config#g" \
    -e "s#/opt/stardew/container/exec-game.sh#$work/capture#g" \
    "$ROOT/scripts/container/startapp.sh" > "$work/startapp.sh"
GAME_PATH="$work/payload" STARDEW_MODDED=0 XDG_CONFIG_HOME="$work/config/xdg/config" \
    XDG_DATA_HOME="$work/config/xdg/data" XDG_CACHE_HOME="$work/config/xdg/cache" \
    bash "$work/startapp.sh" 'argument with spaces' > "$work/output"
grep -Fxq forwarded "$work/output"
printf 'PASS outer startup forwards arguments through direct exec\n'
cp "$work/game app" "$work/payload/StardewModdingAPI"
mkdir -p "$work/payload/Mods"
for mod in 'Crops Anytime Anywhere' TimeSpeed; do
    cp -a "$ROOT/mods/$mod" "$work/payload/Mods/$mod"
    [[ ! -e "$work/payload/Mods/$mod/config.json" ]]
done
for state in fresh existing; do
    GAME_PATH="$work/payload" STARDEW_MODDED=1 \
        ENABLE_CROPSANYTIMEANYWHERE_MOD=true ENABLE_TIMESPEED_MOD=true \
        XDG_CONFIG_HOME="$work/config/xdg/config" XDG_DATA_HOME="$work/config/xdg/data" \
        XDG_CACHE_HOME="$work/config/xdg/cache" \
        bash "$work/startapp.sh" 'argument with spaces' > "$work/output"
    grep -Fxq forwarded "$work/output"
    for mod in 'Crops Anytime Anywhere' TimeSpeed; do
        config="$work/payload/Mods/$mod/config.json"
        if [[ "$state" == fresh ]]; then
            [[ ! -e "$config" ]]
            printf '{"preserve":"operator configuration"}\n' > "$config"
        else
            grep -Fxq '{"preserve":"operator configuration"}' "$config"
        fi
    done
done
printf 'PASS optional mods receive no generated config; existing config is preserved\n'
