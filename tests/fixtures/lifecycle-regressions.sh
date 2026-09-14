#!/usr/bin/env bash
# Isolated helper/runner regressions: no real Podman, credentials, or game files.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
umask 077
work="$ROOT/.local/validation/lifecycle-fixture-$BASHPID-$RANDOM"
mkdir -p "$work"
trap 'rm -rf -- "$work"' EXIT
for name in success conflict query-error no-create startup-failed owner-changed stale-pid wait-failed false-ready cleanup-failed; do
    repo="$work/$name"
    mkdir -p "$repo/scripts/lib" "$repo/tests/fixtures" "$repo/v3x86" "$repo/bin" "$repo/mock"
    cp "$ROOT/scripts/podman-steam.sh" "$repo/scripts/"
    cp "$ROOT/scripts/lib/"{podman-steam,steam-cache}.sh "$repo/scripts/lib/"
    cp "$ROOT/v3x86/docker-compose-steam.yml" "$repo/v3x86/"
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
    [[ "$MOCK_CASE" != startup-failed ]]
fi
EOF
    printf 'VNC_PASSWORD=synthetic-password\n' > "$repo/private.env"
    hash=$(printf '%s' "$repo" | sha256sum)
    status=0
    PATH="$repo/bin:$PATH" MOCK_CALLS="$repo/calls" MOCK_STATE="$repo/mock" MOCK_CASE=$name MOCK_OWNER="${hash:0:12}" \
        bash "$repo/tests/runtime-lifecycle.sh" v3x86 --env-file "$repo/private.env" --timeout 2 > "$repo/output" 2>&1 || status=$?
    if [[ "$name" == success ]]; then
        [[ "$status" == 0 ]]
        grep -q 'TERM=143, KILL=137' "$repo/output"
        [[ "$(grep -c '^rm ' "$repo/calls")" == 2 ]]
    else
        [[ "$status" != 0 ]]
        case "$name" in
            conflict|query-error|no-create|owner-changed)
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
    if grep -q 'synthetic-password' "$repo/calls" "$repo/output"; then exit 1; fi
    if [[ "$name" == conflict || "$name" == query-error ]]; then
        if grep -q '^run ' "$repo/calls"; then exit 1; fi
    fi
    printf 'PASS lifecycle %s\n' "$name"
done

# Termination must reach the active target's EXIT cleanup and retain its receipt.
status=0
# The prior cleanup-failed case intentionally retained its synthetic container.
rm -f "$repo/mock/live"
PATH="$repo/bin:$PATH" MOCK_CALLS="$repo/calls" MOCK_STATE="$repo/mock" MOCK_CASE=interrupted MOCK_OWNER="${hash:0:12}" \
    bash "$repo/tests/runtime-lifecycle.sh" v3x86 --env-file "$repo/private.env" --timeout 5 > "$repo/interrupt-output" 2>&1 &
runner_pid=$!
for ((attempt=0; attempt<10; attempt++)); do
    [[ ! -e "$repo/mock/live" ]] || break
    sleep 1
done
[[ -e "$repo/mock/live" ]]
kill -TERM "$runner_pid"
wait "$runner_pid" || status=$?
[[ "$status" == 143 && ! -e "$repo/mock/live" ]]
[[ "$(find "$repo/.local" -name '*.marker' | wc -l)" == 0 ]]
[[ "$(find "$repo/.local" -name runtime.local.env | wc -l)" == 0 ]]
printf 'PASS lifecycle interrupt cleanup\n'

probe="$ROOT/tests/fixtures/lifecycle-process.sh"
app=/data/Stardew/game/StardewModdingAPI
bash "$probe" match-argv "$app" "$app"
bash "$probe" match-argv "$app" /usr/local/bin/box64 "$app"
bash "$probe" match-argv "$app" /usr/libexec/qemu-binfmt/aarch64-binfmt-P /usr/local/bin/box64 box64 "$app"
bash "$probe" match-argv "$app" /usr/bin/qemu-aarch64-static /usr/local/bin/box64 "$app"
if bash "$probe" match-argv "$app" bash -c "$app"; then exit 1; fi
if bash "$probe" match-argv "$app" /usr/local/bin/box64 "/stale$app"; then exit 1; fi
if bash "$probe" match-argv "$app" /usr/bin/qemu-aarch64-static /usr/bin/bash "$app"; then exit 1; fi
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
