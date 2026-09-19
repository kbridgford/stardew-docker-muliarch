#!/usr/bin/env bash
# Generated fixture scripts expand their variables when executed.
# shellcheck disable=SC2016
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
umask 077
[[ ! -L "$ROOT/.local" && ! -L "$ROOT/.local/validation" ]] || exit 1
work="$ROOT/.local/validation/architecture-$BASHPID-$RANDOM"
mkdir -p "$work"
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$TEST_ARCH"\n' > "$work/bin/dpkg"
printf '#!/bin/bash\nprintf "native:%%s\\n" "$*"\nprintf "game-callret:%%s\\ngame-dynarec:%%s\\n" "${BOX64_DYNAREC_CALLRET-unset}" "${BOX64_DYNAREC-unset}"\nexit "${TEST_EXIT:-0}"\n' > "$work/game app"
printf '#!/bin/bash\nprintf "box64\\n"\nexec "$@"\n' > "$work/bin/box64"
chmod +x "$work/bin/dpkg" "$work/bin/box64" "$work/game app"
export PATH="$work/bin:$PATH"
for architecture in amd64 arm64; do
    TEST_ARCH=$architecture bash "$ROOT/scripts/container/exec-game.sh" "$work/game app" 'argument with spaces' \
        > "$work/output"
    grep -qx 'native:argument with spaces' "$work/output"
    if [[ "$architecture" == arm64 ]]; then
        grep -qx box64 "$work/output"
    elif grep -qx box64 "$work/output"; then
        echo 'amd64 unexpectedly invoked Box64.' >&2; exit 1
    fi
    status=0
    TEST_ARCH=$architecture TEST_EXIT=37 bash "$ROOT/scripts/container/exec-game.sh" "$work/game app" \
        > "$work/output" || status=$?
    [[ "$status" == 37 ]]
    printf 'PASS %s dispatch, argument preservation and exit propagation\n' "$architecture"
done
if TEST_ARCH=riscv64 bash "$ROOT/scripts/container/exec-game.sh" "$work/game app" > "$work/error" 2>&1; then
    echo 'Unsupported architecture accepted.' >&2; exit 1
fi
grep -q 'Unsupported container architecture' "$work/error"
printf 'PASS unsupported architecture fails explicitly\n'
TEST_ARCH=amd64 TARGETARCH=amd64 bash "$ROOT/multiarch/docker/build/setup-arch" > "$work/output"
grep -q 'Box64 is not required' "$work/output"
if TEST_ARCH=amd64 TARGETARCH=arm64 bash "$ROOT/multiarch/docker/build/setup-arch" > "$work/error" 2>&1; then
    echo 'Mismatched build/container architectures accepted.' >&2; exit 1
fi
printf 'PASS native setup skips Box64 and mismatched architecture fails\n'

for apphost in StardewModdingAPI 'Stardew Valley'; do
    cp "$work/game app" "$work/$apphost"
    for architecture in amd64 arm64; do
        TEST_ARCH=$architecture BOX64_DYNAREC_CALLRET=2 BOX64_DYNAREC=1 \
            bash "$ROOT/scripts/container/exec-game.sh" "$work/$apphost" 'argument with spaces' > "$work/output"
        expected=2
        [[ "$architecture" != arm64 ]] || expected=0
        grep -qx "game-callret:$expected" "$work/output"
        grep -qx 'game-dynarec:1' "$work/output"
        grep -qx 'native:argument with spaces' "$work/output"
    done
done
TEST_ARCH=arm64 BOX64_DYNAREC_CALLRET=2 bash "$ROOT/scripts/container/exec-game.sh" "$work/game app" > "$work/output"
grep -qx 'game-callret:2' "$work/output"
printf 'PASS CALLRET compatibility is ARM game-only, overrides unsafe mode, and preserves dynarec/arguments\n'

export BOX64_VERSION=0.4.5+20260919.38f4831-1
export BOX64_REPO_COMMIT=d444abc7fb30603e3129c338cd880dab1a2723f9
grep -Fxq "ARG BOX64_VERSION=$BOX64_VERSION" "$ROOT/multiarch/docker/Dockerfile-steam"
grep -Fxq "ARG BOX64_REPO_COMMIT=$BOX64_REPO_COMMIT" "$ROOT/multiarch/docker/Dockerfile-steam"
for invalid in missing-version missing-snapshot branch-snapshot invalid-package wildcard-version; do
    case "$invalid" in
        missing-version) pin_options=(-u BOX64_VERSION) ;;
        missing-snapshot) pin_options=(-u BOX64_REPO_COMMIT) ;;
        branch-snapshot) pin_options=(BOX64_REPO_COMMIT=main) ;;
        invalid-package) pin_options=(BOX64_PACKAGE=--allow-unauthenticated) ;;
        wildcard-version) pin_options=('BOX64_VERSION=0.4.*') ;;
    esac
    if TEST_ARCH=arm64 TARGETARCH=arm64 env "${pin_options[@]}" \
        bash "$ROOT/multiarch/docker/build/setup-arch" > "$work/error" 2>&1; then
        echo "Unsafe Box64 pin accepted: $invalid" >&2; exit 1
    fi
    grep -Eq 'Set an exact|Set an immutable|Invalid Box64' "$work/error"
done
printf 'PASS ARM setup rejects missing, mutable and malformed pins before installation\n'

export TEST_PIN_CALLS="$work/pin-calls" TEST_INSTALLED_VERSION="$BOX64_VERSION"
mkdir -p "$work/keyrings" "$work/sources"
sed -e "s|/install-packages.sh|$work/install-packages.sh|g" \
    -e "s|/usr/share/keyrings|$work/keyrings|g" \
    -e "s|/etc/apt/sources.list.d|$work/sources|g" \
    "$ROOT/multiarch/docker/build/setup-arch" > "$work/setup-arch"
printf '#!/bin/bash\nprintf "install:%%s\\n" "$*" >> "$TEST_PIN_CALLS"\n' > "$work/install-packages.sh"
printf '#!/bin/bash\nprintf "curl:%%s\\n" "$*" >> "$TEST_PIN_CALLS"\nprintf "fixture key\\n"\n' > "$work/bin/curl"
printf '#!/bin/bash\n[[ "$*" == "--dearmor --batch --yes -o "* ]]\noutput=${*: -1}\ncat > "$output"\n' > "$work/bin/gpg"
printf '#!/bin/bash\nprintf "%%s" "$TEST_INSTALLED_VERSION"\n' > "$work/bin/dpkg-query"
printf '#!/bin/bash\nprintf "apt:%%s\\n" "$*" >> "$TEST_PIN_CALLS"\n' > "$work/bin/apt-get"
chmod +x "$work/bin/"*
TEST_ARCH=arm64 TARGETARCH=arm64 bash "$work/setup-arch" > "$work/output"
grep -Fxq "install:box64=$BOX64_VERSION" "$TEST_PIN_CALLS"
grep -Fxq "curl:--fail --location https://raw.githubusercontent.com/ryanfortner/box64-debs/$BOX64_REPO_COMMIT/KEY.gpg" "$TEST_PIN_CALLS"
grep -Fxq "deb [arch=arm64 signed-by=$work/keyrings/box64.gpg] https://raw.githubusercontent.com/ryanfortner/box64-debs/$BOX64_REPO_COMMIT/debian/ ./" "$work/sources/box64.list"
grep -Fxq 'fixture key' "$work/keyrings/box64.gpg"
if TEST_ARCH=arm64 TARGETARCH=arm64 TEST_INSTALLED_VERSION=0.0.0 bash "$work/setup-arch" > "$work/error" 2>&1; then
    echo 'Mismatched installed Box64 version accepted.' >&2; exit 1
fi
grep -q 'Installed Box64 version does not match' "$work/error"
printf 'PASS ARM setup uses signed immutable snapshot, exact version and mismatch rejection\n'
