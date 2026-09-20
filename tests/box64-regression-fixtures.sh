#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
umask 077
[[ ! -L "$ROOT/.local" && ! -L "$ROOT/.local/validation" ]]
work="$ROOT/.local/validation/box64-fixtures-$BASHPID-$RANDOM"
mkdir -p "$work/repo/tests" "$work/repo/scripts/lib" "$work/bin"
trap 'rm -rf -- "$work"' EXIT
cp "$ROOT/tests/box64-regression.sh" "$work/repo/tests/"
cp "$ROOT/scripts/lib/steam-cache.sh" "$ROOT/scripts/lib/podman-steam.sh" "$work/repo/scripts/lib/"
cp "$ROOT/tests/fixtures/box64-podman" "$work/bin/podman"
chmod +x "$work/bin/podman"
export PATH="$work/bin:$PATH"
image=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
for scenario in ready timeout exited create-failure interrupt ownership cleanup wrong-arch native-image bad-image bad-setting bad-timeout; do
    export BOX64_MOCK="$work/$scenario" MOCK_CASE="$scenario" MOCK_ARCH=arm64
    mkdir "$BOX64_MOCK"
    arguments=(--image "$image" --timeout 1 --env BOX64_DYNAREC_BIGBLOCK=0)
    case "$scenario" in
        wrong-arch) MOCK_ARCH=amd64 ;;
        bad-image) arguments=(--image mutable-tag) ;;
        bad-setting) arguments+=(--env VNC_PASSWORD=12345) ;;
        bad-timeout) arguments+=(--timeout 601) ;;
    esac
    status=0
    if [[ "$scenario" == interrupt ]]; then
        bash "$work/repo/tests/box64-regression.sh" "${arguments[@]}" --timeout 30 > "$BOX64_MOCK/output" 2>&1 &
        child=$!
        for ((attempt=0; attempt<100; attempt++)); do
            [[ ! -e "$BOX64_MOCK/started" ]] || break
            sleep 0.05
        done
        [[ -e "$BOX64_MOCK/started" ]]
        kill -TERM "$child"
        wait "$child" || status=$?
    else
        bash "$work/repo/tests/box64-regression.sh" "${arguments[@]}" > "$BOX64_MOCK/output" 2>&1 || status=$?
    fi
    if [[ "$scenario" == ready ]]; then
        [[ "$status" == 0 ]]
    elif [[ "$scenario" == timeout ]]; then
        [[ "$status" == 124 ]]
    elif [[ "$scenario" == interrupt ]]; then
        [[ "$status" == 143 ]]
    elif [[ "$scenario" == create-failure ]]; then
        [[ "$status" == 42 ]]
    else
        [[ "$status" != 0 ]]
    fi
    evidence=$(sed -n 's/^Private Box64 evidence: //p' "$BOX64_MOCK/output")
    case "$scenario" in
        ready|timeout|exited|create-failure|interrupt)
            jq -e --argjson status "$status" '.status==$status and .cleanup_verified==true' "$evidence/result.json" >/dev/null
            grep -q '^run --detach --pull=never --platform linux/arm64 --network none ' "$BOX64_MOCK/calls"
            grep -q -- '--tmpfs /config:rw,mode=700' "$BOX64_MOCK/calls"
            grep -q -- '--env BOX64_DYNAREC_BIGBLOCK=0' "$BOX64_MOCK/calls"
            grep -q '^rm bbbbb' "$BOX64_MOCK/calls"
            if grep -q -- '--volume\|--mount\|--privileged' "$BOX64_MOCK/calls"; then exit 1; fi ;;
        ownership|cleanup)
            jq -e '.status!=0 and .cleanup_verified==false' "$evidence/result.json" >/dev/null
            if grep -q '^rm ' "$BOX64_MOCK/calls"; then exit 1; fi ;;
        wrong-arch|native-image)
            if grep -q '^run ' "$BOX64_MOCK/calls"; then exit 1; fi ;;
        bad-*) [[ ! -e "$BOX64_MOCK/calls" ]] ;;
    esac
    printf 'PASS Box64 diagnostic %s\n' "$scenario"
done
