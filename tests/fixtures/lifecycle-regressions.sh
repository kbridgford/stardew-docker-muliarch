#!/usr/bin/env bash
# Isolated helper/runner regressions: no real Podman, credentials, or game files.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
umask 077
[[ ! -L "$ROOT/.local" && ! -L "$ROOT/.local/validation" ]] || exit 1
work="$ROOT/.local/validation/lifecycle-fixture-$BASHPID-$RANDOM"
mkdir -p "$work"
trap 'rm -rf -- "$work"' EXIT
for name in success success-amd64 success-arm64 failure-arm64 conflict query-error no-create startup-failed owner-changed bad-receipt symlink-receipt stale-pid wait-failed false-ready cleanup-failed; do
    repo="$work/$name"
    mkdir -p "$repo/scripts/lib" "$repo/tests/fixtures" "$repo/multiarch" "$repo/bin" "$repo/mock" \
        "$repo/.local/podman/multiarch/config" "$repo/.local/podman/v3arm64/config"
    printf 'untouched normal state\n' > "$repo/.local/podman/multiarch/config/production-marker"
    printf 'untouched legacy state\n' > "$repo/.local/podman/v3arm64/config/production-marker"
    original=$(find "$repo/.local/podman" -type f -exec sha256sum {} +)
    cp "$ROOT/scripts/podman-steam.sh" "$repo/scripts/"
    cp "$ROOT/scripts/lib/"{podman-steam,steam-cache}.sh "$repo/scripts/lib/"
    printf '\nrequire_handler() { :; }\n' >> "$repo/scripts/lib/podman-steam.sh"
    cp "$ROOT/multiarch/docker-compose-steam.yml" "$repo/multiarch/"
    cp "$ROOT/tests/runtime-lifecycle.sh" "$repo/tests/"
    cp "$ROOT/tests/fixtures/lifecycle-process.sh" "$repo/tests/fixtures/"
    cp "$ROOT/tests/fixtures/lifecycle-podman" "$repo/bin/podman"
    chmod +x "$repo/bin/podman"
    cat > "$repo/scripts/wait-steam.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -e "$MOCK_STATE/exit" ]]; then
    [[ "$MOCK_CASE" == false-ready ]]
else
    [[ "$MOCK_CASE" != interrupted ]] || sleep 3
    if [[ "$MOCK_CASE" == failure-arm64 && "$(cat "$MOCK_STATE/platform")" == linux/arm64 ]]; then exit 1; fi
    [[ "$MOCK_CASE" != startup-failed ]]
fi
EOF
    printf 'VNC_PASSWORD=synthetic-password\n' > "$repo/private.env"
    hash=$(printf '%s' "$repo" | sha256sum)
    status=0
    extra=()
    case "$name" in
        success-amd64) extra=(--platform linux/amd64) ;;
        success-arm64) extra=(--platform linux/arm64) ;;
    esac
    PATH="$repo/bin:$PATH" MOCK_CALLS="$repo/calls" MOCK_STATE="$repo/mock" MOCK_CASE=$name MOCK_OWNER="${hash:0:12}" \
        bash "$repo/tests/runtime-lifecycle.sh" all "${extra[@]}" --env-file "$repo/private.env" --timeout 2 > "$repo/output" 2>&1 || status=$?
    if [[ "$name" == success* ]]; then
        [[ "$status" == 0 ]]
        grep -q 'TERM=143, KILL=137' "$repo/output"
        expected_runs=2
        [[ "$name" != success ]] || expected_runs=4
        [[ "$(grep -c '^rm ' "$repo/calls")" == "$expected_runs" ]]
        [[ "$(grep -c '^run ' "$repo/calls")" == "$expected_runs" ]]
        if [[ "$name" == success ]]; then
            [[ "$(grep '^run ' "$repo/calls" | grep -c -- '--platform linux/amd64')" == 2 ]]
            [[ "$(grep '^run ' "$repo/calls" | grep -c -- '--platform linux/arm64')" == 2 ]]
            mapfile -t statuses < <(find "$repo/.local/validation" -name status)
            [[ "${#statuses[@]}" == 2 ]]
        else
            grep '^run ' "$repo/calls" | grep -q -- "--platform linux/${name#success-}"
            if grep '^run ' "$repo/calls" | grep -v -- "--platform linux/${name#success-}"; then exit 1; fi
        fi
    else
        [[ "$status" != 0 ]]
        case "$name" in
            conflict|query-error|no-create|owner-changed|bad-receipt|symlink-receipt)
                if grep -Eq '^(stop|rm) ' "$repo/calls"; then
                    printf 'Unsafe cleanup in %s\n' "$name" >&2; exit 1
                fi ;;
            cleanup-failed)
                grep -q '^stop ' "$repo/calls"
                if grep -q '^rm ' "$repo/calls"; then exit 1; fi ;;
            *)
                grep -q '^rm ' "$repo/calls"
                mapfile -t diagnostics < <(find "$repo/.local/validation" -name cleanup-container.log)
                (( ${#diagnostics[@]} > 0 ))
                for diagnostic in "${diagnostics[@]}"; do
                    grep -q 'private container diagnostics' "$diagnostic"
                done
                ;;
        esac
    fi
    [[ "$(find "$repo/.local" -name '*.marker' | wc -l)" == 0 ]]
    [[ "$(find "$repo/.local" -name runtime.local.env | wc -l)" == 0 ]]
    [[ "$original" == "$(find "$repo/.local/podman" -type f -exec sha256sum {} +)" ]]
    if grep '^run ' "$repo/calls" | grep -q -- "--volume $repo/.local/podman/"; then exit 1; fi
    if [[ "$name" == failure-arm64 ]]; then
        grep -q '^PASS multiarch linux/amd64:' "$repo/output"
        grep -q '^FAIL/BLOCKED multiarch linux/arm64:' "$repo/output"
    fi
    if grep -q 'synthetic-password' "$repo/calls" "$repo/output"; then exit 1; fi
    if [[ "$name" == conflict || "$name" == query-error ]]; then
        if grep -q '^run ' "$repo/calls"; then exit 1; fi
    fi
    printf 'PASS lifecycle %s\n' "$name"
done

# Termination must reach each architecture's EXIT cleanup and retain its receipt.
for platform in linux/amd64 linux/arm64; do
    status=0
    # The prior cleanup-failed case intentionally retained its synthetic container.
    rm -f "$repo/mock/live"
    PATH="$repo/bin:$PATH" MOCK_CALLS="$repo/calls" MOCK_STATE="$repo/mock" MOCK_CASE=interrupted MOCK_OWNER="${hash:0:12}" \
        bash "$repo/tests/runtime-lifecycle.sh" multiarch --platform "$platform" --env-file "$repo/private.env" \
            --timeout 5 > "$repo/interrupt-output" 2>&1 &
    runner_pid=$!
    trap 'kill -TERM "$runner_pid" 2>/dev/null || :; wait "$runner_pid" 2>/dev/null || :; rm -rf -- "$work"' EXIT
    for ((attempt=0; attempt<10; attempt++)); do
        [[ ! -e "$repo/mock/live" ]] || break
        sleep 1
    done
    [[ -e "$repo/mock/live" ]]
    kill -TERM "$runner_pid"
    wait "$runner_pid" || status=$?
    trap 'rm -rf -- "$work"' EXIT
    [[ "$status" == 143 && ! -e "$repo/mock/live" ]]
    [[ "$(find "$repo/.local" -name '*.marker' | wc -l)" == 0 ]]
    [[ "$(find "$repo/.local" -name runtime.local.env | wc -l)" == 0 ]]
    [[ "$original" == "$(find "$repo/.local/podman" -type f -exec sha256sum {} +)" ]]
    printf 'PASS lifecycle %s interrupt cleanup\n' "$platform"
done

# Removed targets and malformed selectors fail before evidence or Podman calls.
before=$(wc -l < "$repo/calls")
for target in v3arm v3arm64 v3x86 v3arm-amd64 v4x86_x11vnc v4x86-x11vnc; do
    if PATH="$repo/bin:$PATH" MOCK_CALLS="$repo/calls" bash "$repo/tests/runtime-lifecycle.sh" "$target" \
        --env-file "$repo/private.env" > "$repo/reject-output" 2>&1; then exit 1; fi
    grep -q 'Unknown target' "$repo/reject-output"
done
if PATH="$repo/bin:$PATH" MOCK_CALLS="$repo/calls" bash "$repo/tests/runtime-lifecycle.sh" multiarch \
    --platform linux/386 --env-file "$repo/private.env" > "$repo/reject-output" 2>&1; then exit 1; fi
[[ "$before" == "$(wc -l < "$repo/calls")" ]]
printf 'PASS lifecycle removed targets and invalid platform rejection\n'

before_runs=$(grep -c '^run ' "$repo/calls")
lock="$repo/.local/validation/lifecycle.lock"
rm "$lock"
ln -s "$repo/private.env" "$lock"
if PATH="$repo/bin:$PATH" MOCK_CALLS="$repo/calls" MOCK_STATE="$repo/mock" MOCK_CASE=success \
    bash "$repo/tests/runtime-lifecycle.sh" multiarch --env-file "$repo/private.env" \
    > "$repo/lock-output" 2>&1; then exit 1; fi
grep -q 'must not be symlinks' "$repo/lock-output"
rm "$lock"
exec {fixture_lock}>"$lock"
flock -x "$fixture_lock"
if PATH="$repo/bin:$PATH" MOCK_CALLS="$repo/calls" MOCK_STATE="$repo/mock" MOCK_CASE=success \
    bash "$repo/tests/runtime-lifecycle.sh" multiarch --env-file "$repo/private.env" \
    > "$repo/lock-output" 2>&1; then exit 1; fi
grep -q 'Another lifecycle runner' "$repo/lock-output"
flock -u "$fixture_lock"
chmod 644 "$repo/private.env"
if PATH="$repo/bin:$PATH" MOCK_CALLS="$repo/calls" bash "$repo/tests/runtime-lifecycle.sh" multiarch \
    --env-file "$repo/private.env" > "$repo/env-output" 2>&1; then exit 1; fi
grep -q '600 or stricter' "$repo/env-output"
[[ "$before_runs" == "$(grep -c '^run ' "$repo/calls")" ]]
printf 'PASS lifecycle lock conflict, symlink and private env guards\n'

probe="$ROOT/tests/fixtures/lifecycle-process.sh"
app=/data/Stardew/game/StardewModdingAPI
bash "$probe" match-argv "$app" "$app"
bash "$probe" match-argv "$app" /usr/local/bin/box64 "$app"
bash "$probe" match-argv "$app" /usr/libexec/qemu-binfmt/aarch64-binfmt-P /usr/local/bin/box64 box64 "$app"
bash "$probe" match-argv "$app" /usr/bin/qemu-aarch64-static /usr/local/bin/box64 "$app"
bash "$probe" match-argv "$app" /usr/libexec/qemu-binfmt/aarch64-binfmt-P "$app" "$app"
bash "$probe" match-argv "$app" /usr/bin/qemu-aarch64-static "$app"
if bash "$probe" match-argv "$app" bash -c "$app"; then exit 1; fi
if bash "$probe" match-argv "$app" /usr/local/bin/box64 "/stale$app"; then exit 1; fi
if bash "$probe" match-argv "$app" /usr/bin/qemu-aarch64-static /usr/bin/bash "$app"; then exit 1; fi
if bash "$probe" match-argv "$app" /usr/bin/qemu-aarch64-static "/stale$app" "$app"; then exit 1; fi
printf 'PASS lifecycle exact native/Box64/QEMU argv; probe-shell and stale-path rejection\n'

# Verify the signal probe rejects a stale start time without touching the PID.
if [[ "$(id -u):$(id -g)" == 1000:1000 ]]; then
    bash -c 'exec -a /lifecycle-fixture-game sleep 60' &
    fixture_pid=$!
    trap 'kill -TERM "$fixture_pid" 2>/dev/null || :; wait "$fixture_pid" 2>/dev/null || :; rm -rf -- "$work"' EXIT
    for ((attempt=0; attempt<5; attempt++)); do
        if bash "$ROOT/tests/fixtures/lifecycle-process.sh" identify /lifecycle-fixture-game \
                > "$work/identity" 2> "$work/identify-error"; then break; fi
        sleep 1
    done
    IFS=$'\t' read -r observed_pid start _ < "$work/identity"
    [[ "$observed_pid" == "$fixture_pid" && "$start" =~ ^[0-9]+$ ]]
    status=0
    bash "$ROOT/tests/fixtures/lifecycle-process.sh" signal /lifecycle-fixture-game "$fixture_pid" "$((start + 1))" TERM \
        > "$work/stale.log" 2>&1 || status=$?
    [[ "$status" != 0 ]]
    kill -0 "$fixture_pid"
    kill -TERM "$fixture_pid"
    wait "$fixture_pid" 2>/dev/null || :
    trap 'rm -rf -- "$work"' EXIT
    printf 'PASS lifecycle real stale-PID refusal\n'
else
    printf 'BLOCKED stale-PID fixture needs application UID/GID 1000:1000\n' >&2
    exit 1
fi
