#!/usr/bin/env bash
# Real rootless Podman, but only an imported EMPTY synthetic filesystem and two
# unique disposable indexes. No game, network, containers or existing members.
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/state-inventory.sh"
source "$ROOT/scripts/lib/steam-cache.sh"
source "$ROOT/scripts/lib/podman-steam.sh"
[[ $EUID -ne 0 && $# == 1 ]] || exit 1
work=$1
safe_path "$work"
[[ $work == "$ROOT/.local/validation/"* && ! -e $work ]] || exit 1
parent=${work%/*}
while [[ $parent != "$ROOT" ]]; do
    migration_private "$parent"
    parent=${parent%/*}
done
timeout 45 podman info --format json | jq -e '.host.security.rootless == true' >/dev/null
mkdir -m 700 -- "$work" "$work/empty-root"
token=$(date -u +%Y%m%dt%H%M%Sz)-$BASHPID-$RANDOM
reference=localhost/stardew-cleanup-probe-$token
member='' legacy='' keep=''
cleanup_probe() {
    local rc=$? current
    trap - EXIT
    for current in "$legacy" "$keep"; do
        [[ -n $current ]] || continue
        # IDs are captured ONLY from this invocation's successful create calls.
        timeout 45 podman manifest rm "$current" >> "$work/operations.log" 2>&1 || rc=1
    done
    if [[ -n $member ]]; then
        if timeout 45 podman image inspect "$member" | jq -e --arg id "$member" --arg token "$token" \
            --arg name "$reference:member" 'length == 1 and .[0].Id == $id and .[0].RepoTags == [$name] and
            .[0].Config.Labels["io.stardew.cleanup-probe"] == $token' >/dev/null; then
            timeout 45 podman image rm "$member" >> "$work/operations.log" 2>&1 || rc=1
        else rc=1; fi
    fi
    exit "$rc"
}
trap cleanup_probe EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
tar -C "$work/empty-root" -cf "$work/empty.tar" .
member=$(timeout 45 podman import --change "LABEL io.stardew.cleanup-probe=$token" \
    "$work/empty.tar" "$reference:member" 2>> "$work/operations.log")
member=${member#sha256:}
[[ $member =~ ^[a-f0-9]{64}$ ]] || exit 1
legacy=$(timeout 45 podman manifest create "$reference:legacy" 2>> "$work/operations.log")
[[ $legacy =~ ^[a-f0-9]{64}$ ]] || exit 1
keep=$(timeout 45 podman manifest create "$reference:keep" 2>> "$work/operations.log")
[[ $keep =~ ^[a-f0-9]{64}$ && $keep != "$legacy" ]] || exit 1
timeout 45 podman manifest add "$reference:legacy" "containers-storage:$member" >> "$work/operations.log" 2>&1
timeout 45 podman manifest add "$reference:keep" "containers-storage:$member" >> "$work/operations.log" 2>&1
before=$(timeout 45 podman manifest inspect "$reference:keep" | jq -Sc .)
deleted=$legacy
timeout 45 podman manifest rm "$legacy" >> "$work/operations.log" 2>&1
legacy=''
if timeout 45 podman manifest exists "$reference:legacy" 2>> "$work/operations.log"; then exit 1; else rc=$?; fi
[[ $rc == 1 ]]
[[ $(timeout 45 podman manifest inspect "$reference:keep" | jq -Sc .) == "$before" ]]
timeout 45 podman image exists "$member"
jq -nSc --arg removed "$deleted" --arg retained_index "$keep" --arg member "$member" \
    '{schema:"stardew-cleanup-manifest-probe",version:1,complete:true,
    removed_index:$removed,protected_index_verified:$retained_index,shared_synthetic_member_verified:$member,
    cleanup:"EXIT trap removes only the remaining probe index and labeled imported image"}' > "$work/result.json"
printf 'Real manifest-aware probe passed: one index removed; other index and shared synthetic member preserved.\n'
