#!/usr/bin/env bash
# Generated fixture scripts expand their variables when executed.
# shellcheck disable=SC2016
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/stardew-architecture-test-XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$TEST_ARCH"\n' > "$work/bin/dpkg"
printf '#!/bin/bash\nprintf "native:%%s\\n" "$*"\nexit "${TEST_EXIT:-0}"\n' > "$work/game app"
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
TEST_ARCH=amd64 TARGETARCH=amd64 bash "$ROOT/v3arm64/docker/build/setup-arch" > "$work/output"
grep -q 'Box64 is not required' "$work/output"
if TEST_ARCH=amd64 TARGETARCH=arm64 bash "$ROOT/v3arm64/docker/build/setup-arch" > "$work/error" 2>&1; then
    echo 'Mismatched build/container architectures accepted.' >&2; exit 1
fi
printf 'PASS native setup skips Box64 and mismatched architecture fails\n'
