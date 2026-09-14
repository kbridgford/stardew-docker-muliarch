#!/usr/bin/env bash
# Sourceable API (no writes at source time):
#   migration_verify ROOT RECEIPT
#     Read-only, exclusively locked verification; stdout is the validated receipt
#     JSON, so capture it privately. Returns nonzero on any unverifiable evidence.
#     Like v1, validates recorded container checks, not present-day containers:
#     disposable validation may use the same name without mounting normal state.
#     Cleanup callers must separately check current exact resource identities.
#   migration_inventory TREE
#     Read-only JSON {entries,stability_sha256}; contains PRIVATE relative names.
#   migration_verify_retained ROOT MIGRATION_RECEIPT CLEANUP_RECEIPT
#     Requires completed retirement evidence and ABSENT source; verifies only
#     backup/destination, never claims a present-day source-stability check.
#     Returns a distinct stardew-retained-state-verification report, not a fresh
#     copy of the original receipt's historical three-tree verification claim.
#     Both receipt paths may be canonical repository-relative or absolute paths.
# v1 inventories are checked against their ORIGINAL bytes, not reserialized JSON.
# Stability uses v1 ASCII JSON and exact integer nanoseconds, never jq arithmetic.
MIGRATION_LIBRARY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

migration_digest() {
    local value
    value=$(sha256sum) || return 1
    printf '%s\n' "${value%% *}"
}

migration_stamp() {
    local data dev ino hex uid gid links size sec_m sec_c time_m time_c frac_m frac_c
    data=$(LC_ALL=C TZ=UTC stat --printf='%d|%i|%f|%u|%g|%h|%s|%Y|%Z|%y|%z' -- "$1") || return 1
    IFS='|' read -r dev ino hex uid gid links size sec_m sec_c time_m time_c <<< "$data"
    frac_m=${time_m#*.}; frac_m=${frac_m%% *}
    frac_c=${time_c#*.}; frac_c=${frac_c%% *}
    [[ $frac_m =~ ^[0-9]{9}$ && $frac_c =~ ^[0-9]{9}$ ]] || return 1
    printf '[%s,%s,%s,%s,%s,%s,%s,%s,%s]\n' \
        "$dev" "$ino" "$((16#$hex))" "$uid" "$gid" "$links" "$size" \
        "$((sec_m * 1000000000 + 10#$frac_m))" "$((sec_c * 1000000000 + 10#$frac_c))"
}

migration_private() {
    local path=$1 kind=${2:-directory} mode
    safe_path "$path" || return 1
    [[ -e $path && ! -L $path && $(stat -c %u -- "$path") == "$EUID" ]] || return 1
    mode=$(stat -c %a -- "$path") || return 1
    (( (8#$mode & 077) == 0 )) || return 1
    if [[ $kind == directory ]]; then
        [[ -d $path ]] && (( (8#$mode & 0700) == 0700 )) || return 1
    else
        [[ -f $path && $(stat -c %h -- "$path") == 1 ]] || return 1
    fi
}

migration_entry_metadata() {
    local stamp=$1 fields mode uid gid links
    fields=${stamp#[}; fields=${fields%]}
    IFS=, read -r _ _ mode uid gid links _ _ _ <<< "$fields"
    [[ $uid == "$EUID" && $gid == "$(id -g)" ]] || return 1
    (( (mode & 06000) == 0 )) || return 1
    case $((mode & 0170000)) in
        32768) (( links == 1 && (mode & 0400) && !(mode & 022) )) || return 1 ;;
        16384) (( (mode & 0700) == 0700 && (!(mode & 022) || (mode & 07777) == 01777) )) || return 1 ;;
        40960) (( links == 1 )) || return 1 ;;
        *) return 1 ;;
    esac
}

# Reject symlinked ancestors even for entries with embedded newlines.
migration_entry_parents() {
    local parent=${1%/*}
    while [[ -n $parent ]]; do
        [[ ! -L $parent && -d $parent ]] || return 1
        parent=${parent%/*}
    done
}

migration_inventory_impl() (
    set +x
    set -euo pipefail
    export LC_ALL=C
    [[ $EUID -ne 0 ]] || return 1
    source "$MIGRATION_LIBRARY_DIR/steam-cache.sh"
    source "$MIGRATION_LIBRARY_DIR/podman-steam.sh"
    local root=$1 listing name path before after fields mode uid gid size type row
    local target resolved hash encoded_name entries identities stability root_before
    local -a names rows=() stamps=()
    migration_private "$root" || return 1
    root_before=$(migration_stamp "$root") || return 1
    # NUL framing preserves arbitrary names. Base64 also propagates find/sort
    # failures, unlike a process substitution directly feeding read/mapfile.
    listing=$(find -P "$root" -printf '%P\0' | sort -z | base64 -w0) || return 1
    mapfile -d '' -t names < <(printf '%s' "$listing" | base64 -d)
    for name in "${names[@]}"; do
        if [[ -z $name ]]; then name=.; path=$root; else path=$root/$name; fi
        migration_entry_parents "$path" || return 1
        before=$(migration_stamp "$path") || return 1
        migration_entry_metadata "$before" || return 1
        fields=${before#[}; fields=${fields%]}
        IFS=, read -r _ _ mode uid gid _ size _ _ <<< "$fields"
        encoded_name=$(printf '%s' "$name" | jq -Rsa .) || return 1
        # jq replaces invalid UTF-8; refuse rather than alias two filenames.
        [[ $(printf '%s\n' "$encoded_name" | jq -jr . | base64 -w0) == \
            "$(printf '%s' "$name" | base64 -w0)" ]] || return 1
        row=$(jq -nac --argjson path "$encoded_name" --argjson mode "$((mode & 07777))" \
            --argjson uid "$uid" --argjson gid "$gid" '{path:$path,mode:$mode,uid:$uid,gid:$gid}') || return 1
        type=$((mode & 0170000))
        case $type in
            16384) row=$(jq -ac '. + {type:"directory"}' <<< "$row") || return 1 ;;
            40960)
                IFS= read -r -d '' target < <(readlink -z -- "$path") || return 1
                [[ $target != /* ]] || return 1
                IFS= read -r -d '' resolved < <(realpath -zm -- "${path%/*}/$target") || return 1
                [[ $resolved == "$root" || $resolved == "$root/"* ]] || return 1
                [[ $(printf '%s' "$target" | jq -Rs . | jq -jr . | base64 -w0) == \
                    "$(printf '%s' "$target" | base64 -w0)" ]] || return 1
                row=$(jq -ac --arg target "$target" '. + {type:"symlink",target:$target}' <<< "$row") || return 1
                ;;
            32768)
                # No shell input-redirection open that could block on a FIFO
                # or follow a swapped final symlink. Exclude atime side effects.
                hash=$(dd if="$path" iflag=nofollow,nonblock,noatime status=none | migration_digest) || return 1
                row=$(jq -ac --arg sha "$hash" --argjson size "$size" \
                    '. + {type:"file",size:$size,sha256:$sha}' <<< "$row") || return 1
                ;;
        esac
        after=$(migration_stamp "$path") || return 1
        [[ $before == "$after" ]] || return 1
        rows+=("$row")
        stamps+=("[$encoded_name,$before]")
    done
    [[ $(migration_stamp "$root") == "$root_before" ]] || return 1
    # Recheck every inode, including directories after all descendants are read.
    for row in "${stamps[@]}"; do
        IFS= read -r -d '' name < <(jq -jr '.[0],"\u0000"' <<< "$row") || return 1
        path=$root; [[ $name == . ]] || path=$root/$name
        migration_entry_parents "$path" || return 1
        [[ $(migration_stamp "$path") == "$(jq -c '.[1]' <<< "$row")" ]] || return 1
    done
    entries=$(printf '%s\n' "${rows[@]}" | jq -Sac 'sort_by(.path)' -s) || return 1
    identities=$(printf '%s\n' "${stamps[@]}" | jq -sac 'sort_by(.[0])') || return 1
    stability=$(printf '%s\n' "$identities" | migration_digest) || return 1
    printf '%s\n' "$entries" | jq -Sc --arg stability "$stability" \
        '{entries:.,stability_sha256:$stability}'
)

migration_inventory() {
    migration_inventory_impl "$@" 2>/dev/null || {
        printf 'Migration inventory refused: unsafe or changing state.\n' >&2
        return 1
    }
}

migration_context() {
    ROOT=$1
    source "$MIGRATION_LIBRARY_DIR/steam-cache.sh"
    source "$MIGRATION_LIBRARY_DIR/podman-steam.sh"
    [[ $EUID -ne 0 ]] || return 1
    local tool
    for tool in jq podman flock realpath stat sha256sum find sort base64 dd cp mv sync timeout \
        id date readlink od tr grep mkdir rm; do
        command -v "$tool" >/dev/null || return 1
    done
    # jq must preserve integer literals: v1 nanosecond stamps exceed 2^53.
    [[ $(printf '1789357989278123456\n' | jq -c .) == 1789357989278123456 ]] || return 1
    safe_path "$ROOT" || return 1
    # Consumed by the sourced target-selection helper.
    # shellcheck disable=SC2034
    RUNTIME_PLATFORM=''
    select_target multiarch
    MI_SOURCE=$ROOT/.local/podman/v3arm64
    MI_DESTINATION=$ROOT/.local/podman/multiarch
    MI_MIGRATIONS=$ROOT/.local/migrations
    migration_private "$ROOT/.local" || return 1
    migration_private "$ROOT/.local/podman" || return 1
    case "${2:-present}" in
        present) migration_private "$MI_SOURCE" || return 1 ;;
        absent) safe_path "$MI_SOURCE" || return 1; [[ ! -e $MI_SOURCE && ! -L $MI_SOURCE ]] || return 1 ;;
        optional) safe_path "$MI_SOURCE" || return 1
            if [[ -e $MI_SOURCE ]]; then migration_private "$MI_SOURCE" || return 1; fi ;;
        *) return 1 ;;
    esac
    safe_path "$MI_DESTINATION" || return 1
    safe_path "$MI_MIGRATIONS" || return 1
    if [[ -e $MI_MIGRATIONS ]]; then migration_private "$MI_MIGRATIONS" || return 1; fi
}

migration_check_lock() {
    local lock=$ROOT/.local/podman/.multiarch-migration.lock
    migration_private "$lock" file || return 1
    [[ $(stat -c %d:%i -- "$lock") == "$(stat -Lc %d:%i -- "/proc/self/fd/$MIGRATION_LOCK_FD")" ]] || return 1
    flock -xn "$MIGRATION_LOCK_FD"
}

migration_lock() {
    local mode=$1 lock=$ROOT/.local/podman/.multiarch-migration.lock
    # A cleanup caller retains this same open file description throughout its
    # critical section. Nested verifier subshells must not reopen or unlock it.
    if [[ -v MIGRATION_LOCK_FD ]]; then migration_check_lock; return "$?"; fi
    safe_path "$lock" || return 1
    if [[ -e $lock ]]; then migration_private "$lock" file || return 1; fi
    if [[ -e $lock || $mode == execute ]]; then
        # Same append-opened persistent inode as lock_normal_state; never unlink.
        exec {MIGRATION_LOCK_FD}>>"$lock" || return 1
        migration_check_lock || return 1
    else
        unset MIGRATION_LOCK_FD
    fi
}

migration_containers() {
    local info name result ident immutable status rc target
    local -a rows=()
    info=$(timeout 45 podman info --format json) || return 1
    jq -e '.host.security.rootless == true' <<< "$info" >/dev/null || return 1
    for target in v3arm64 multiarch; do
        name=stardew-dev-$PROJECT-$target
        if timeout 45 podman container exists "$name"; then rc=0; else rc=$?; fi
        case $rc in
            1) rows+=("$(jq -nc --arg name "$name" '{name:$name,id:null}')"); continue ;;
            0) ;;
            *) return 1 ;;
        esac
        result=$(timeout 45 podman inspect "$name" | jq -Sc 'if length == 1 then .[0] else error("count") end') || return 1
        jq -e --arg project "$PROJECT" '
            (.Id | type == "string" and test("^[a-f0-9]{64}$")) and
            .Config.Labels["io.stardew.local-project"] == $project and
            (.State.Status | IN("exited","stopped","created","configured")) and
            ((.State.Running // false) == false) and
            ((.State.Paused // false) == false) and
            ((.State.Restarting // false) == false)' <<< "$result" >/dev/null || return 1
        ident=$(jq -r .Id <<< "$result") || return 1
        immutable=$(timeout 45 podman inspect "$ident" | jq -Sc 'if length == 1 then .[0] else error("count") end') || return 1
        [[ $immutable == "$result" ]] || return 1
        status=$(jq -r .State.Status <<< "$result") || return 1
        rows+=("$(jq -nc --arg name "$name" --arg id "$ident" --arg status "$status" \
            '{name:$name,id:$id,status:$status}')")
    done
    printf '%s\n' "${rows[@]}" | jq -Scs .
}

migration_read_private() {
    local path=$1 before bytes
    migration_private "$path" file || return 1
    before=$(migration_stamp "$path") || return 1
    bytes=$(dd if="$path" iflag=nofollow,nonblock,noatime status=none | base64 -w0) || return 1
    [[ $(migration_stamp "$path") == "$before" ]] || return 1
    MI_READ_SHA=$(printf '%s' "$bytes" | base64 -d | migration_digest) || return 1
    MI_READ_JSON=$(printf '%s' "$bytes" | base64 -d | jq -Scs 'if length == 1 then .[0] else error("count") end') || return 1
}

migration_verify_impl() (
    set +x
    set -euo pipefail
    umask 077
    local receipt_path=$2 run receipt receipt_checksum recorded checksum expected tree snapshot count
    local mode=${3:-present} cleanup_path=${4:-}
    local -a snapshots=() trees=()
    [[ $mode == present || $mode == absent ]] || return 1
    migration_context "$1" "$mode" || return 1
    migration_lock verify || return 1
    safe_path "$receipt_path" || return 1
    receipt_path=$SAFE_PATH
    run=${receipt_path%/*}
    [[ ${run%/*} == "$MI_MIGRATIONS" && ${run##*/} == v3arm64-* && ${receipt_path##*/} == receipt.json ]] || return 1
    migration_private "$MI_MIGRATIONS" || return 1
    migration_private "$run" || return 1
    migration_read_private "$receipt_path" || return 1
    receipt=$MI_READ_JSON
    receipt_checksum=$MI_READ_SHA
    if [[ $mode == absent ]]; then
        safe_path "$cleanup_path" || return 1
        cleanup_path=$SAFE_PATH
        migration_retirement_evidence "$cleanup_path" "$receipt_path" "$receipt_checksum" || return 1
    fi
    jq -e --arg root "$ROOT" --arg project "$PROJECT" --argjson uid "$EUID" --argjson gid "$(id -g)" \
        --arg source "$MI_SOURCE" --arg destination "$MI_DESTINATION" --arg run "$run" '
        .schema == "stardew-state-migration" and .version == 1 and
        .status == "complete" and .completion == true and
        .project == {root:$root,hash:$project,uid:$uid,gid:$gid} and
        .paths == {source:$source,destination:$destination,backup:($run+"/state"),inventory:($run+"/inventory.json")} and
        (.source_stability_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
        (.inventory.sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
        .inventory.verified == ["source","backup","destination"] and
        (.containers | type == "array" and length == 2) and
        ([.containers[].name] == ["stardew-dev-"+$project+"-v3arm64","stardew-dev-"+$project+"-multiarch"]) and
        all(.containers[]; if .id == null then keys == ["id","name"] else
            (.id | type == "string" and test("^[a-f0-9]{64}$")) and
            (.status | IN("exited","stopped","created","configured")) end)' <<< "$receipt" >/dev/null || return 1
    migration_read_private "$run/inventory.json" || return 1
    recorded=$MI_READ_JSON; checksum=$MI_READ_SHA
    jq -e '.schema == "stardew-state-inventory" and .version == 1 and
        (.entries | type == "array")' <<< "$recorded" >/dev/null || return 1
    count=$(jq '.entries | length' <<< "$recorded") || return 1
    jq -e --arg checksum "$checksum" --argjson count "$count" '
        .inventory.sha256 == $checksum and .inventory.entries == $count' \
        <<< "$receipt" >/dev/null || return 1
    expected=$(jq -Sc '.entries' <<< "$recorded") || return 1
    if [[ $mode == present ]]; then trees+=("$MI_SOURCE"); fi
    trees+=("$run/state" "$MI_DESTINATION")
    for tree in "${trees[@]}"; do
        snapshot=$(migration_inventory "$tree") || return 1
        [[ $(jq -Sc .entries <<< "$snapshot") == "$expected" ]] || return 1
        if [[ $tree == "$MI_SOURCE" ]]; then
            [[ $(jq -r .stability_sha256 <<< "$snapshot") == \
                "$(jq -r .source_stability_sha256 <<< "$receipt")" ]] || return 1
        fi
        snapshots+=("$snapshot")
    done
    local i=0
    for tree in "${trees[@]}"; do
        [[ $(migration_inventory "$tree") == "${snapshots[$i]}" ]] || return 1
        i=$((i + 1))
    done
    migration_read_private "$receipt_path" || return 1
    [[ $MI_READ_JSON == "$receipt" && $MI_READ_SHA == "$receipt_checksum" ]] || return 1
    migration_read_private "$run/inventory.json" || return 1
    [[ $MI_READ_SHA == "$checksum" && $MI_READ_JSON == "$recorded" ]] || return 1
    if [[ -v MIGRATION_LOCK_FD ]]; then migration_check_lock || return 1; fi
    if [[ $mode == absent ]]; then
        [[ ! -e $MI_SOURCE && ! -L $MI_SOURCE ]] || return 1
        migration_retirement_evidence "$cleanup_path" "$receipt_path" "$receipt_checksum" || return 1
        jq -nSc --arg migration "$receipt_path" --arg cleanup "$cleanup_path" --argjson entries "$count" '
            {schema:"stardew-retained-state-verification",version:1,verified:true,entries:$entries,
            migration_receipt:$migration,cleanup_receipt:$cleanup,scope:["backup","destination"],
            source_absent:true,source_stability_verified:false}'
    else
        printf '%s\n' "$receipt"
    fi
)

migration_verify() {
    migration_verify_impl "$@" 2>/dev/null || {
        printf 'Migration verification refused: unsafe, changed or unverifiable evidence/state.\n' >&2
        return 1
    }
}

migration_retirement_evidence() {
    local proof=$1 migration=$2 migration_sha=$3 run=${2%/*} saved gate quarantine
    [[ $proof == "$run/cleanup/receipt.json" ]] || return 1
    migration_private "$run/cleanup" || return 1
    migration_read_private "$proof" || return 1
    saved=$MI_READ_JSON
    jq -e --arg root "$ROOT" --arg hash "$PROJECT" --argjson uid "$EUID" --argjson gid "$(id -g)" \
        --arg migration "$migration" --arg sha "$migration_sha" --arg source "$MI_SOURCE" \
        --arg backup "$run/state" --arg destination "$MI_DESTINATION" '
        .schema == "stardew-legacy-cleanup" and .version == 1 and .status == "complete" and .completion == true and
        .project == {root:$root,hash:$hash,uid:$uid,gid:$gid} and
        .migration == {receipt:$migration,sha256:$sha} and
        .source.path == $source and .source.retired == true and
        (.source.identity | type == "string" and test("^[0-9]+:[0-9]+$")) and
        (.source.quarantine | type == "string" and startswith($root+"/.local/podman/.v3arm64-retired-")) and
        .retained.backup == $backup and .retained.destination == $destination and
        .verification.scope == ["backup","destination"] and .verification.source_stability_verified == false and
        .gate.path == ($root+"/.local/validation/consolidate-final-gate/gate.json") and
        (.gate.sha256 | type == "string" and test("^[a-f0-9]{64}$"))' <<< "$saved" >/dev/null || return 1
    quarantine=$(jq -r .source.quarantine <<< "$saved") || return 1
    [[ ${quarantine%/*} == "$ROOT/.local/podman" &&
        ${quarantine##*/} =~ ^\.v3arm64-retired-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{24}$ ]] || return 1
    safe_path "$quarantine" || return 1
    [[ ! -e $quarantine && ! -L $quarantine ]] || return 1
    gate=$(jq -r .gate.path <<< "$saved") || return 1
    migration_private "$ROOT/.local/validation" || return 1
    migration_private "${gate%/*}" || return 1
    migration_read_private "$gate" || return 1
    [[ $MI_READ_SHA == "$(jq -r .gate.sha256 <<< "$saved")" ]] || return 1
    jq -e --arg root "$ROOT" --arg hash "$PROJECT" --arg migration "$migration" --arg sha "$migration_sha" '
        .schema == "stardew-consolidation-gate" and .version == 1 and .complete == true and
        .project == {root:$root,hash:$hash} and .migration == {receipt:$migration,sha256:$sha}' \
        <<< "$MI_READ_JSON" >/dev/null
}

migration_verify_retained() {
    migration_verify_impl "$1" "$2" absent "$3" 2>/dev/null || {
        printf 'Retained-state verification refused: retirement evidence or retained state invalid.\n' >&2
        return 1
    }
}

migration_write_private() {
    local path=$1 value=$2
    (set -o noclobber; printf '%s\n' "$value" > "$path") || return 1
    migration_private "$path" file || return 1
    sync -f "$path" && sync -f "${path%/*}"
}

migration_copy() {
    [[ ! -e $2 && ! -L $2 ]] || return 1
    # No dereference, no shared hardlinks/reflinks with the source. Ownership,
    # permissions and timestamps are preserved, and every copy is re-inventoried.
    cp -a --no-dereference --reflink=never -- "$1" "$2" || return 1
    sync -f "$2"
}

migration_publish() {
    # GNU mv uses RENAME_NOREPLACE on Linux. Never fall back to cross-device copy;
    # none-fail also rejects an existing EMPTY directory, unlike plain rename.
    mv -T --no-copy --update=none-fail -- "$1" "$2"
}

migration_cleanup() {
    local rc=$1 identity
    trap - EXIT INT TERM HUP
    if [[ -n ${MI_STAGE_ID:-} && -d $MI_STAGE && ! -L $MI_STAGE ]]; then
        identity=$(stat -c %d:%i -- "$MI_STAGE") || identity=''
        if [[ $identity == "$MI_STAGE_ID" ]]; then
            # Only this invocation's wrapper; never destination, backup or source.
            rm -rf --one-file-system -- "$MI_STAGE" || rc=1
        else
            rc=1
        fi
    fi
    if (( rc != 0 )) && [[ -n ${MI_RUN_ID:-} && -d $MI_RUN && ! -L $MI_RUN ]]; then
        identity=$(stat -c %d:%i -- "$MI_RUN") || identity=''
        if [[ $identity == "$MI_RUN_ID" ]]; then
            migration_write_private "$MI_RUN/failure.json" \
                "$(jq -nc --arg phase "$MI_PHASE" --argjson published "$MI_PUBLISHED" \
                '{schema:"stardew-state-migration-failure",version:1,completion:false,phase:$phase,destination_published:$published}')" || :
        fi
    fi
    exit "$rc"
}

migration_run_impl() (
    set +x
    set -euo pipefail
    umask 077
    local mode=$2 initial snapshot entries stability token backup recorded checksum base receipt count
    migration_context "$1" || return 1
    [[ ! -e $MI_DESTINATION && ! -L $MI_DESTINATION ]] || return 1
    migration_lock "$mode" || return 1
    initial=$(migration_containers) || return 1
    snapshot=$(migration_inventory "$MI_SOURCE") || return 1
    [[ $(migration_inventory "$MI_SOURCE") == "$snapshot" ]] || return 1
    [[ $(migration_containers) == "$initial" ]] || return 1
    entries=$(jq -Sc .entries <<< "$snapshot") || return 1
    count=$(jq length <<< "$entries") || return 1
    stability=$(jq -r .stability_sha256 <<< "$snapshot") || return 1
    if [[ $mode == dry-run ]]; then
        printf 'Dry-run passed: %s entries; no state/evidence created.\n' "$count"
        return 0
    fi
    [[ $mode == execute ]] || return 1
    mv --help | grep -q -- '--no-copy' || return 1
    mv --help | grep -q -- 'none-fail' || return 1
    [[ -d $MI_MIGRATIONS ]] || mkdir -m 700 -- "$MI_MIGRATIONS" || return 1
    migration_private "$MI_MIGRATIONS" || return 1
    token=$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
    [[ $token =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{24}$ ]] || return 1
    MI_RUN=$MI_MIGRATIONS/v3arm64-$token
    MI_STAGE=$ROOT/.local/podman/.multiarch-migration-stage-$token
    MI_STAGE_ID=''; MI_RUN_ID=''; MI_PHASE=backup; MI_PUBLISHED=false
    mkdir -m 700 -- "$MI_RUN" || return 1
    MI_RUN_ID=$(stat -c %d:%i -- "$MI_RUN") || return 1
    trap 'migration_cleanup "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    backup=$MI_RUN/state
    base=$(jq -nSc --arg root "$ROOT" --arg project "$PROJECT" --argjson uid "$EUID" --argjson gid "$(id -g)" \
        --arg source "$MI_SOURCE" --arg destination "$MI_DESTINATION" --arg run "$MI_RUN" '
        {schema:"stardew-state-migration",version:1,completion:false,status:"in-progress",
        project:{root:$root,hash:$project,uid:$uid,gid:$gid},
        paths:{source:$source,destination:$destination,backup:($run+"/state"),inventory:($run+"/inventory.json")}}') || return 1
    migration_write_private "$MI_RUN/attempt.json" "$base" || return 1
    migration_copy "$MI_SOURCE" "$backup" || return 1
    [[ $(migration_inventory "$backup" | jq -Sc .entries) == "$entries" ]] || return 1
    [[ $(migration_inventory "$MI_SOURCE") == "$snapshot" ]] || return 1
    recorded=$(printf '%s\n' "$entries" | jq -Sc '{schema:"stardew-state-inventory",version:1,entries:.}') || return 1
    migration_write_private "$MI_RUN/inventory.json" "$recorded" || return 1
    checksum=$(printf '%s\n' "$recorded" | migration_digest) || return 1
    migration_write_private "$MI_RUN/backup-verified.json" \
        "$(jq -nc --arg checksum "$checksum" --argjson count "$count" \
        '{completion:true,inventory_sha256:$checksum,entries:$count}')" || return 1
    MI_PHASE=stage
    mkdir -m 700 -- "$MI_STAGE" || return 1
    MI_STAGE_ID=$(stat -c %d:%i -- "$MI_STAGE") || return 1
    migration_copy "$backup" "$MI_STAGE/state" || return 1
    [[ $(migration_inventory "$MI_STAGE/state" | jq -Sc .entries) == "$entries" ]] || return 1
    [[ $(migration_inventory "$backup" | jq -Sc .entries) == "$entries" ]] || return 1
    [[ $(migration_inventory "$MI_SOURCE") == "$snapshot" ]] || return 1
    [[ $(migration_containers) == "$initial" ]] || return 1
    migration_context "$ROOT" || return 1
    migration_check_lock || return 1
    [[ ! -e $MI_DESTINATION && ! -L $MI_DESTINATION ]] || return 1
    receipt=$(jq -Sc --arg time "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" --arg stability "$stability" \
        --argjson containers "$initial" --arg checksum "$checksum" --argjson count "$count" '
        . + {completion:true,status:"complete",completed_at:$time,source_stability_sha256:$stability,
        containers:$containers,inventory:{sha256:$checksum,entries:$count,verified:["source","backup","destination"]}}' \
        <<< "$base") || return 1
    migration_write_private "$MI_RUN/ready.json" \
        "$(jq -Sc '. + {completion:false,status:"verified-unpublished"}' <<< "$receipt")" || return 1
    migration_write_private "$MI_RUN/commit.json" "$receipt" || return 1
    MI_PHASE=publish
    # Bash has no pthread_sigmask. Ignore catchable termination in BOTH parent
    # and children only across rename + durable receipt. SIGKILL/power loss can
    # still leave ready/commit evidence; never roll back or overwrite destination.
    trap '' INT TERM HUP
    migration_publish "$MI_STAGE/state" "$MI_DESTINATION" || return 1
    MI_PUBLISHED=true
    migration_publish "$MI_RUN/commit.json" "$MI_RUN/receipt.json" || return 1
    sync -f "$MI_DESTINATION" && sync -f "$MI_RUN" || return 1
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    printf 'Migration complete: %s entries; source preserved.\nBackup: %s\nReceipt: %s\n' \
        "$count" "$backup" "$MI_RUN/receipt.json"
)

migration_run() {
    migration_run_impl "$@" 2>/dev/null || {
        printf 'Migration refused/failed: unsafe, conflicting, changed or unverifiable state; no legacy state removed.\n' >&2
        return 1
    }
}
