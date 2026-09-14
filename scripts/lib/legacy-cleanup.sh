#!/usr/bin/env bash
# Bounded retirement of the four explicitly approved legacy references. No image
# object GC: ordinary images and all members remain unless sharing is disproven.
# The fixed IDs are approval boundaries, not candidates discovered for deletion.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/state-inventory.sh"

cleanup_allowlist() {
    jq -nc '[
      {tag:"v3arm64",id:"0acd962313535f2135853fef514d0a9454c91ecc19ae8617393e706f9725bab2",kind:"manifest"},
      {tag:"v4x86-x11vnc",id:"58fd3ce832bd7baa7dcd71e85a48d898f1b4f1880bea17d7be1c62fdccda985b",kind:"image"},
      {tag:"v3x86",id:"97d1d4edb4763f533b018e52e4ec3f3e12a731157b89bd426046b0c43a66462c",kind:"image"},
      {tag:"v3arm-amd64",id:"20179bb2e1d3146fdc709deb97924e62fd2baedcf38bbff82750b2f3cee1761a",kind:"image"}]'
}

cleanup_private_evidence() {
    local path=$1 parent=${1%/*}
    [[ $path == "$ROOT/.local/validation/"* ]] || return 1
    safe_path "$path" || return 1
    while [[ $parent != "$ROOT" ]]; do
        migration_private "$parent" || return 1
        parent=${parent%/*}
    done
    migration_private "$path" file
}

cleanup_file_hash() {
    local before digest
    migration_private "$1" file || return 1
    before=$(migration_stamp "$1") || return 1
    digest=$(dd if="$1" iflag=nofollow,nonblock,noatime status=none | migration_digest) || return 1
    [[ $(migration_stamp "$1") == "$before" ]] || return 1
    printf '%s\n' "$digest"
}

cleanup_gate() {
    local path=$1 gate sha row file expected manifest current gate_time migration_time
    [[ $path == "$ROOT/.local/validation/consolidate-final-gate/gate.json" ]] || return 1
    cleanup_private_evidence "$path" || return 1
    migration_read_private "$path" || return 1
    gate=$MI_READ_JSON; sha=$MI_READ_SHA
    jq -e --arg root "$ROOT" --arg project "$PROJECT" '
        keys == ["checks","complete","created_at","manifest","migration","project","schema","version"] and
        (.created_at | type == "string") and
        .schema == "stardew-consolidation-gate" and .version == 1 and .complete == true and
        .project == {root:$root,hash:$project} and
        (.migration | keys == ["receipt","sha256"]) and
        (.migration.sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
        .manifest.reference == ("localhost/stardew-dev-"+$project+":multiarch") and
        (.manifest.canonical_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
        (.manifest.members | type == "array" and length == 2) and
        ([.manifest.members[].platform | .os+"/"+.architecture] | sort) == ["linux/amd64","linux/arm64"] and
        all(.manifest.members[]; .digest | type == "string" and test("^sha256:[a-f0-9]{64}$")) and
        (.checks | type == "array" and length == 9) and
        ([.checks[].name] | sort) == ["archprobe-amd64","archprobe-arm64","build-first","build-repeat",
          "lifecycle","regressions","shellcheck","smoke-amd64","smoke-arm64"] and
        ([.checks[].path] | unique | length) == 9 and
        all(.checks[]; keys == ["exit_code","name","path","sha256"] and .exit_code == 0 and
          (.path | type == "string" and startswith($root+"/.local/validation/")) and
          (.sha256 | type == "string" and test("^[a-f0-9]{64}$")))' <<< "$gate" >/dev/null || return 1
    while IFS= read -r row; do
        file=$(jq -r .path <<< "$row") || return 1
        expected=$(jq -r .sha256 <<< "$row") || return 1
        cleanup_private_evidence "$file" || return 1
        [[ $(cleanup_file_hash "$file") == "$expected" ]] || return 1
    done < <(jq -c '.checks[]' <<< "$gate")
    CK_MIGRATION=$(jq -r .migration.receipt <<< "$gate") || return 1
    safe_path "$CK_MIGRATION" || return 1
    [[ ${CK_MIGRATION##*/} == receipt.json && ${CK_MIGRATION%/*/*} == "$MI_MIGRATIONS" &&
        ${CK_MIGRATION%/*} == "$MI_MIGRATIONS/v3arm64-"* ]] || return 1
    migration_private "${CK_MIGRATION%/*}" || return 1
    migration_read_private "$CK_MIGRATION" || return 1
    CK_MIGRATION_SHA=$MI_READ_SHA
    [[ $CK_MIGRATION_SHA == "$(jq -r .migration.sha256 <<< "$gate")" ]] || return 1
    CK_MIGRATION_JSON=$MI_READ_JSON
    gate_time=$(date -u -d "$(jq -r .created_at <<< "$gate")" +%s) || return 1
    migration_time=$(date -u -d "$(jq -r .completed_at <<< "$CK_MIGRATION_JSON")" +%s) || return 1
    (( gate_time >= migration_time && gate_time <= $(date -u +%s) + 300 )) || return 1
    jq -e --arg root "$ROOT" --arg hash "$PROJECT" --argjson uid "$EUID" --argjson gid "$(id -g)" \
        --arg source "$MI_SOURCE" --arg destination "$MI_DESTINATION" --arg run "${CK_MIGRATION%/*}" '
        .schema == "stardew-state-migration" and .version == 1 and .completion == true and .status == "complete" and
        .project == {root:$root,hash:$hash,uid:$uid,gid:$gid} and
        .paths == {source:$source,destination:$destination,backup:($run+"/state"),inventory:($run+"/inventory.json")} and
        .inventory.verified == ["source","backup","destination"] and
        .containers[0].id == "7882f8783d741d4abfbb211cb87c73ae6a52c1a75642426ac074aa8171333599"' \
        <<< "$CK_MIGRATION_JSON" >/dev/null || return 1
    CK_BACKUP=${CK_MIGRATION%/*}/state
    CK_DIRECTORY=${CK_MIGRATION%/*}/cleanup
    CK_JOURNAL=$CK_DIRECTORY/journal.json
    CK_RECEIPT=$CK_DIRECTORY/receipt.json
    migration_read_private "${CK_MIGRATION%/*}/inventory.json" || return 1
    [[ $MI_READ_SHA == "$(jq -r .inventory.sha256 <<< "$CK_MIGRATION_JSON")" ]] || return 1
    jq -e --argjson count "$(jq .inventory.entries <<< "$CK_MIGRATION_JSON")" '
        .schema == "stardew-state-inventory" and .version == 1 and
        (.entries | type == "array" and length == $count)' <<< "$MI_READ_JSON" >/dev/null || return 1
    CK_ENTRIES=$(jq -Sc .entries <<< "$MI_READ_JSON") || return 1
    CK_RETAINED_REFERENCE=$(jq -r .manifest.reference <<< "$gate") || return 1
    timeout 45 podman manifest exists "$CK_RETAINED_REFERENCE" || return 1
    manifest=$(timeout 45 podman manifest inspect "$CK_RETAINED_REFERENCE" | jq -Sc .) || return 1
    [[ $(printf '%s\n' "$manifest" | migration_digest) == "$(jq -r .manifest.canonical_sha256 <<< "$gate")" ]] || return 1
    [[ $(jq -Sc .manifests <<< "$manifest") == "$(jq -Sc .manifest.members <<< "$gate")" ]] || return 1
    current=$(timeout 45 podman info --format json) || return 1
    jq -e '.host.security.rootless == true' <<< "$current" >/dev/null || return 1
    migration_read_private "$path" || return 1
    [[ $MI_READ_SHA == "$sha" && $MI_READ_JSON == "$gate" ]] || return 1
    CK_GATE=$gate; CK_GATE_SHA=$sha; CK_GATE_PATH=$path
}

cleanup_images() {
    local listing protected members row tag expected kind reference found ident names inspect digest
    local -a rows=()
    listing=$(timeout 45 podman images --all --no-trunc --format json |
        jq -Sc '[.[]|{id:.Id,names:(.Names // [] | sort),digest:.Digest}] | unique | sort_by(.id)') || return 1
    jq -e 'all(.[]; (.id | type == "string" and test("^[a-f0-9]{64}$")) and (.names|type == "array")) and
        ([.[].id] | unique | length) == length' <<< "$listing" >/dev/null || return 1
    CK_IMAGE_LISTING=$listing
    protected=$(jq -Sc --arg ref "$CK_RETAINED_REFERENCE" '[.[]|select(.names|index($ref))]' <<< "$listing") || return 1
    jq -e 'length == 1 and .[0].id == "db60eb79a477cb7b4ea5e68647090985473f707bdcfe9aca0b47c4fae0bcd83c"' \
        <<< "$protected" >/dev/null || return 1
    members=$(jq -Sc --argjson gate "$CK_GATE" '[.[] | select(.digest as $d | any($gate.manifest.members[]; .digest == $d))]' \
        <<< "$listing") || return 1
    [[ $(jq length <<< "$members") == 2 ]] || return 1
    CK_PROTECTED=$(jq -nSc --argjson index "$protected" --argjson members "$members" '{index:$index[0],members:$members}') || return 1
    while IFS= read -r row; do
        tag=$(jq -r .tag <<< "$row"); expected=$(jq -r .id <<< "$row"); kind=$(jq -r .kind <<< "$row")
        reference=localhost/stardew-dev-$PROJECT:$tag
        found=$(jq -Sc --arg ref "$reference" '[.[]|select(.names|index($ref))]' <<< "$listing") || return 1
        [[ $(jq length <<< "$found") -le 1 ]] || return 1
        if [[ $found == '[]' ]]; then
            rows+=("$(jq -nc --arg ref "$reference" --arg expected "$expected" \
                '{reference:$ref,expected_id:$expected,id:null,kind:"absent",members:[]}')")
            continue
        fi
        ident=$(jq -r '.[0].id' <<< "$found"); names=$(jq -Sc '.[0].names' <<< "$found")
        digest=$(jq -r '.[0].digest' <<< "$found")
        [[ $ident == "$expected" && $ident != "$(jq -r .index.id <<< "$CK_PROTECTED")" ]] || return 1
        members='[]'
        if [[ $kind == manifest ]]; then
            # manifest rm deletes the index object, so EVERY alias must be
            # explicitly authorized. Never untag a manifest via host dispatch.
            [[ $names == "$(jq -nc --arg ref "$reference" '[$ref]')" ]] || return 1
            timeout 45 podman manifest exists "$ident" || return 1
            inspect=$(timeout 45 podman manifest inspect "$ident" | jq -Sc .) || return 1
            jq -e '.manifests | type == "array" and length > 0 and
                all(.[]; .digest | test("^sha256:[a-f0-9]{64}$"))' <<< "$inspect" >/dev/null || return 1
            members=$(jq -Sc .manifests <<< "$inspect") || return 1
        else
            inspect=$(timeout 45 podman image inspect "$ident") || return 1
            jq -e --arg id "$ident" 'length == 1 and .[0].Id == $id and
                (.[0].ManifestType | IN("application/vnd.oci.image.manifest.v1+json",
                 "application/vnd.docker.distribution.manifest.v2+json"))' <<< "$inspect" >/dev/null || return 1
        fi
        rows+=("$(jq -nc --arg ref "$reference" --arg id "$ident" --arg kind "$kind" --arg digest "$digest" \
            --argjson aliases "$names" --argjson members "$members" \
            '{reference:$ref,expected_id:$id,id:$id,kind:$kind,digest:$digest,aliases:$aliases,members:$members}')")
    done < <(cleanup_allowlist | jq -c '.[]')
    CK_IMAGES=$(printf '%s\n' "${rows[@]}" | jq -Scs .) || return 1
}

cleanup_containers() {
    local target name expected rc item immutable id
    local -a rows=()
    for target in v3arm64 v4x86-x11vnc v3x86 v3arm-amd64 multiarch; do
        name=stardew-dev-$PROJECT-$target
        expected=''
        [[ $target != v3arm64 ]] || expected=7882f8783d741d4abfbb211cb87c73ae6a52c1a75642426ac074aa8171333599
        if timeout 45 podman container exists "$name"; then rc=0; else rc=$?; fi
        case $rc in
            1)
                if [[ -n $expected ]]; then
                    if timeout 45 podman container exists "$expected"; then return 1; else rc=$?; fi
                    [[ $rc == 1 ]] || return 1
                fi
                [[ $target == multiarch ]] || rows+=("$(jq -nc --arg name "$name" '{name:$name,id:null}')")
                continue ;;
            0) ;;
            *) return 1 ;;
        esac
        # No unknown IDs and no new-target workload may cross this gate.
        [[ -n $expected ]] || return 1
        item=$(timeout 45 podman inspect "$name" | jq -Sc 'if length == 1 then .[0] else error("count") end') || return 1
        jq -e --arg id "$expected" --arg name "$name" --arg project "$PROJECT" '
            .Id == $id and (.Name|ltrimstr("/")) == $name and
            .Config.Labels["io.stardew.local-project"] == $project and
            (.State.Status|IN("running","exited","stopped","created","configured")) and
            ((.State.Paused // false) == false) and ((.State.Restarting // false) == false)' <<< "$item" >/dev/null || return 1
        id=$(jq -r .Id <<< "$item")
        immutable=$(timeout 45 podman inspect "$id" | jq -Sc 'if length == 1 then .[0] else error("count") end') || return 1
        [[ $immutable == "$item" ]] || return 1
        rows+=("$(jq -Sc --arg name "$name" '{name:$name,id:.Id,status:.State.Status,image_id:.Image}' <<< "$item")")
    done
    CK_CONTAINERS=$(printf '%s\n' "${rows[@]}" | jq -Scs .) || return 1
}

cleanup_retained_trees() {
    local tree snapshot
    for tree in "$CK_BACKUP" "$MI_DESTINATION"; do
        snapshot=$(migration_inventory "$tree") || return 1
        [[ $(jq -Sc .entries <<< "$snapshot") == "$CK_ENTRIES" ]] || return 1
        [[ $(migration_inventory "$tree") == "$snapshot" ]] || return 1
    done
}

cleanup_store_journal() {
    local stage=$CK_DIRECTORY/.journal-write-$BASHPID-$RANDOM
    migration_private "$CK_DIRECTORY" || return 1
    if [[ -e $CK_JOURNAL || -L $CK_JOURNAL ]]; then migration_private "$CK_JOURNAL" file || return 1; fi
    migration_write_private "$stage" "$CK_JOURNAL_JSON" || return 1
    mv -T --no-copy -- "$stage" "$CK_JOURNAL" || return 1
    sync -f "$CK_DIRECTORY"
}

cleanup_event() {
    CK_JOURNAL_JSON=$(jq -Sc --arg operation "$1" --arg target "$2" --arg status "$3" \
        '.actions += [{operation:$operation,target:$target,status:$status}]' <<< "$CK_JOURNAL_JSON") || return 1
    cleanup_store_journal
}

cleanup_phase() {
    CK_JOURNAL_JSON=$(jq -Sc --arg phase "$1" '.phase=$phase | .status="in-progress"' <<< "$CK_JOURNAL_JSON") || return 1
    cleanup_store_journal
}

cleanup_exit() {
    local rc=$1
    trap - EXIT INT TERM HUP
    if (( rc != 0 )) && [[ ${CK_JOURNAL_READY:-false} == true ]]; then
        if CK_JOURNAL_JSON=$(jq -Sc '.status="failed"' <<< "$CK_JOURNAL_JSON"); then
            cleanup_store_journal || :
        fi
    fi
    exit "$rc"
}

cleanup_load_journal() {
    local quarantine
    migration_private "$CK_DIRECTORY" || return 1
    migration_read_private "$CK_JOURNAL" || return 1
    CK_JOURNAL_JSON=$MI_READ_JSON
    jq -e --arg root "$ROOT" --arg hash "$PROJECT" --argjson uid "$EUID" --argjson gid "$(id -g)" \
        --arg gate "$CK_GATE_PATH" --arg gate_sha "$CK_GATE_SHA" --arg migration "$CK_MIGRATION" \
        --arg migration_sha "$CK_MIGRATION_SHA" --arg source "$MI_SOURCE" --argjson protected "$CK_PROTECTED" \
        --argjson allowlist "$(cleanup_allowlist)" '
        .schema == "stardew-legacy-cleanup-journal" and .version == 1 and
        .project == {root:$root,hash:$hash,uid:$uid,gid:$gid} and
        .gate == {path:$gate,sha256:$gate_sha} and .migration == {receipt:$migration,sha256:$migration_sha} and
        .source.path == $source and (.source.identity|test("^[0-9]+:[0-9]+$")) and
        (.status|IN("in-progress","failed","complete")) and (.phase|IN("resources","retirement-prepared","retiring","retired","complete")) and
        .protected == $protected and (.actions|type == "array") and (.planned.images|length == 4) and
        . as $journal | all(range(0;4); . as $i |
          $journal.planned.images[$i].reference == ("localhost/stardew-dev-"+$hash+":"+$allowlist[$i].tag) and
          $journal.planned.images[$i].expected_id == $allowlist[$i].id and
          (if $journal.planned.images[$i].id == null then $journal.planned.images[$i].kind == "absent" else
             $journal.planned.images[$i].id == $allowlist[$i].id and $journal.planned.images[$i].kind == $allowlist[$i].kind end))' \
        <<< "$CK_JOURNAL_JSON" >/dev/null || return 1
    quarantine=$(jq -r .source.quarantine <<< "$CK_JOURNAL_JSON") || return 1
    [[ ${quarantine%/*} == "$ROOT/.local/podman" && ${quarantine##*/} =~ ^\.v3arm64-retired-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{24}$ ]] || return 1
    safe_path "$quarantine" || return 1
    CK_QUARANTINE=$quarantine
}

cleanup_final_resources() {
    local row id ref aliases
    cleanup_images || return 1
    cleanup_containers || return 1
    [[ $CK_PROTECTED == "$(jq -Sc .protected <<< "$CK_JOURNAL_JSON")" ]] || return 1
    jq -e 'all(.[]; .id == null)' <<< "$CK_IMAGES" >/dev/null || return 1
    jq -e 'all(.[]; .id == null)' <<< "$CK_CONTAINERS" >/dev/null || return 1
    while IFS= read -r row; do
        id=$(jq -r '.id // empty' <<< "$row")
        [[ -n $id ]] || continue
        if [[ $(jq -r .kind <<< "$row") == manifest ]]; then
            jq -e --arg id "$id" 'all(.[]; .id != $id)' <<< "$CK_IMAGE_LISTING" >/dev/null || return 1
        else
            ref=$(jq -r .reference <<< "$row")
            aliases=$(jq -Sc --arg ref "$ref" '.aliases - [$ref] | sort' <<< "$row") || return 1
            jq -e --arg id "$id" --arg digest "$(jq -r .digest <<< "$row")" --argjson aliases "$aliases" '
                any(.[]; .id == $id and .digest == $digest and .names == $aliases)' <<< "$CK_IMAGE_LISTING" >/dev/null || return 1
        fi
    done < <(jq -c '.planned.images[]' <<< "$CK_JOURNAL_JSON")
}

cleanup_snapshot_retirement() {
    local name path listing stamp row expected actual
    local -a rows=()
    actual=$(migration_inventory "$CK_QUARANTINE") || return 1
    [[ $(jq -Sc .entries <<< "$actual") == "$CK_ENTRIES" ]] || return 1
    listing=$(find -P "$CK_QUARANTINE" -printf '%P\0' | sort -z | base64 -w0) || return 1
    while IFS= read -r -d '' name; do
        path=$CK_QUARANTINE
        if [[ -z $name ]]; then name=.; else path=$CK_QUARANTINE/$name; fi
        stamp=$(migration_stamp "$path") || return 1
        rows+=("$(jq -nc --arg path "$name" --arg stamp "$stamp" '{path:$path,stamp:$stamp}')")
    done < <(printf '%s' "$listing" | base64 -d)
    expected=$(printf '%s\n' "${rows[@]}" | jq -Scs 'sort_by(.path)') || return 1
    [[ $(migration_inventory "$CK_QUARANTINE") == "$actual" ]] || return 1
    row=$CK_DIRECTORY/retirement-inventory.json
    if [[ -e $row ]]; then
        migration_read_private "$row" || return 1
        [[ $MI_READ_JSON == "$expected" ]] || return 1
    else
        migration_write_private "$row" "$expected" || return 1
    fi
    CK_JOURNAL_JSON=$(jq -Sc --arg path "$row" --arg sha "$(cleanup_file_hash "$row")" \
        '.retirement_inventory={path:$path,sha256:$sha}' <<< "$CK_JOURNAL_JSON") || return 1
    cleanup_phase retiring
}

cleanup_delete_retirement() {
    local recorded snapshot actual name path row stamp fields expected_fields type listing identity mode=${1:-execute}
    [[ $mode == execute || $mode == check ]] || return 1
    row=$(jq -r .retirement_inventory.path <<< "$CK_JOURNAL_JSON")
    [[ $row == "$CK_DIRECTORY/retirement-inventory.json" ]] || return 1
    migration_read_private "$row" || return 1
    [[ $MI_READ_SHA == "$(jq -r .retirement_inventory.sha256 <<< "$CK_JOURNAL_JSON")" ]] || return 1
    recorded=$MI_READ_JSON
    [[ ! -e $MI_SOURCE && ! -L $MI_SOURCE ]] || return 1
    if [[ ! -e $CK_QUARANTINE && ! -L $CK_QUARANTINE ]]; then return 0; fi
    migration_private "$CK_QUARANTINE" || return 1
    identity=$(jq -r .source.identity <<< "$CK_JOURNAL_JSON")
    [[ $(stat -c %d:%i -- "$CK_QUARANTINE") == "$identity" ]] || return 1
    snapshot=$(migration_inventory "$CK_QUARANTINE") || return 1
    # Interrupted deletion may leave a strict subset, but never new/changed data.
    actual=$(jq -Sc .entries <<< "$snapshot") || return 1
    jq -e --argjson expected "$CK_ENTRIES" 'all(.[]; . as $row | any($expected[]; . == $row))' \
        <<< "$actual" >/dev/null || return 1
    listing=$(find -P "$CK_QUARANTINE" -depth -printf '%P\0' | base64 -w0) || return 1
    while IFS= read -r -d '' name; do
        migration_check_lock || return 1
        migration_private "$ROOT/.local/podman" || return 1
        [[ $(stat -c %d:%i -- "$CK_QUARANTINE") == "$identity" ]] || return 1
        path=$CK_QUARANTINE
        if [[ -z $name ]]; then name=.; else path=$CK_QUARANTINE/$name; fi
        migration_entry_parents "$path" || return 1
        row=$(jq -er --arg name "$name" '[.[]|select(.path == $name)] | if length == 1 then .[0].stamp else error("entry") end' \
            <<< "$recorded") || return 1
        stamp=$(migration_stamp "$path") || return 1
        fields=${stamp#[}; fields=${fields%]}
        IFS=, read -r _ _ type _ <<< "$fields"
        if (( (type & 0170000) == 0040000 )); then
            # Child removals legitimately change directory links/size/timestamps.
            fields=$(jq -c '.[0:5]' <<< "$stamp"); expected_fields=$(jq -c '.[0:5]' <<< "$row")
            [[ $fields == "$expected_fields" ]] || return 1
            if [[ $mode == execute ]]; then rmdir -- "$path" || return 1; fi
        else
            [[ $stamp == "$row" ]] || return 1
            if [[ $mode == execute ]]; then rm -- "$path" || return 1; fi
        fi
    done < <(printf '%s' "$listing" | base64 -d)
    if [[ $mode == execute ]]; then sync -f "$ROOT/.local/podman" || return 1; fi
}

cleanup_run_impl() (
    set +x
    set -euo pipefail
    umask 077
    local mode=$2 gate_path=$3 token row id ref kind phase protected receipt
    local CK_JOURNAL_READY=false
    unset CK_JOURNAL_JSON CK_QUARANTINE
    migration_context "$1" optional || return 1
    migration_lock "$mode" || return 1
    cleanup_gate "$gate_path" || return 1
    cleanup_images || return 1
    cleanup_containers || return 1
    protected=$CK_PROTECTED
    if [[ -e $CK_DIRECTORY || -L $CK_DIRECTORY ]]; then
        cleanup_load_journal || return 1
        phase=$(jq -r .phase <<< "$CK_JOURNAL_JSON")
    else
        [[ -e $MI_SOURCE && ! -L $MI_SOURCE ]] || return 1
        migration_verify "$ROOT" "$CK_MIGRATION" >/dev/null || return 1
        phase=resources
    fi
    cleanup_retained_trees || return 1
    if [[ -e $MI_SOURCE ]]; then
        [[ $phase == resources || $phase == retirement-prepared ]] || return 1
        migration_verify "$ROOT" "$CK_MIGRATION" >/dev/null || return 1
        if [[ -v CK_JOURNAL_JSON ]]; then
            [[ $(stat -c %d:%i -- "$MI_SOURCE") == "$(jq -r .source.identity <<< "$CK_JOURNAL_JSON")" ]] || return 1
        fi
    else
        [[ -v CK_JOURNAL_JSON && $phase != resources ]] || return 1
        case $phase in
            retirement-prepared)
                migration_private "$CK_QUARANTINE" || return 1
                [[ $(stat -c %d:%i -- "$CK_QUARANTINE") == "$(jq -r .source.identity <<< "$CK_JOURNAL_JSON")" ]] || return 1
                [[ $(migration_inventory "$CK_QUARANTINE" | jq -Sc .entries) == "$CK_ENTRIES" ]] || return 1 ;;
            retiring) cleanup_delete_retirement check || return 1 ;;
            retired|complete) [[ ! -e $CK_QUARANTINE && ! -L $CK_QUARANTINE ]] || return 1 ;;
        esac
    fi
    if [[ $phase == complete ]]; then
        migration_verify_retained "$ROOT" "$CK_MIGRATION" "$CK_RECEIPT" >/dev/null || return 1
        cleanup_final_resources || return 1
        printf 'Cleanup already complete; retained backup/destination verified.\n'
        return 0
    fi
    if [[ $mode == dry-run ]]; then
        printf 'Cleanup dry-run passed: exact gate, state and four legacy reference boundaries verified; no changes.\n'
        return 0
    fi
    [[ $mode == execute ]] || return 1
    if [[ ! -v CK_JOURNAL_JSON ]]; then
        token=$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
        CK_QUARANTINE=$ROOT/.local/podman/.v3arm64-retired-$token
        [[ ! -e $CK_QUARANTINE && ! -L $CK_QUARANTINE ]] || return 1
        mkdir -m 700 -- "$CK_DIRECTORY" || return 1
        CK_JOURNAL_JSON=$(jq -nSc --arg root "$ROOT" --arg hash "$PROJECT" --argjson uid "$EUID" --argjson gid "$(id -g)" \
            --arg gate "$CK_GATE_PATH" --arg gate_sha "$CK_GATE_SHA" --arg migration "$CK_MIGRATION" \
            --arg migration_sha "$CK_MIGRATION_SHA" --arg source "$MI_SOURCE" --arg quarantine "$CK_QUARANTINE" \
            --arg identity "$(stat -c %d:%i -- "$MI_SOURCE")" --argjson images "$CK_IMAGES" \
            --argjson containers "$CK_CONTAINERS" --argjson protected "$CK_PROTECTED" '
            {schema:"stardew-legacy-cleanup-journal",version:1,status:"in-progress",phase:"resources",
            project:{root:$root,hash:$hash,uid:$uid,gid:$gid},gate:{path:$gate,sha256:$gate_sha},
            migration:{receipt:$migration,sha256:$migration_sha},
            source:{path:$source,identity:$identity,quarantine:$quarantine,retired:false},
            planned:{images:$images,containers:$containers},protected:$protected,actions:[]}') || return 1
        cleanup_store_journal || return 1
    fi
    CK_JOURNAL_READY=true
    trap 'cleanup_exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if [[ $phase == resources ]]; then
        while IFS= read -r row; do
            id=$(jq -r '.id // empty' <<< "$row")
            [[ -n $id ]] || continue
            cleanup_gate "$gate_path" || return 1
            cleanup_containers || return 1
            if jq -e --arg id "$id" 'any(.[]; .id == $id)' <<< "$CK_CONTAINERS" >/dev/null; then
                cleanup_event stop-container "$id" intent || return 1
                timeout 45 podman stop --time 20 "$id" >/dev/null || return 1
                cleanup_containers || return 1
                jq -e --arg id "$id" 'any(.[]; .id == $id and (.status|IN("exited","stopped","created","configured")))' \
                    <<< "$CK_CONTAINERS" >/dev/null || return 1
                cleanup_event stop-container "$id" 'done' || return 1
                cleanup_event remove-container "$id" intent || return 1
                timeout 45 podman rm "$id" >/dev/null || return 1
                cleanup_containers || return 1
                jq -e 'all(.[]; .id == null)' <<< "$CK_CONTAINERS" >/dev/null || return 1
                cleanup_event remove-container "$id" 'done' || return 1
            fi
        done < <(jq -c '.planned.containers[]' <<< "$CK_JOURNAL_JSON")
        cleanup_containers || return 1
        jq -e 'all(.[]; .id == null)' <<< "$CK_CONTAINERS" >/dev/null || return 1
        while IFS= read -r row; do
            id=$(jq -r '.id // empty' <<< "$row"); ref=$(jq -r .reference <<< "$row"); kind=$(jq -r .kind <<< "$row")
            [[ -n $id ]] || continue
            cleanup_gate "$gate_path" || return 1
            cleanup_images || return 1
            [[ $CK_PROTECTED == "$protected" ]] || return 1
            if jq -e --arg ref "$ref" 'any(.[]; .reference == $ref and .id != null)' <<< "$CK_IMAGES" >/dev/null; then
                # IDs for the operation come from freshly verified resources,
                # never unchecked journal input.
                [[ $(jq -r --arg ref "$ref" '.[]|select(.reference == $ref)|.id' <<< "$CK_IMAGES") == "$id" ]] || return 1
                [[ $(jq -r --arg ref "$ref" '.[]|select(.reference == $ref)|.kind' <<< "$CK_IMAGES") == "$kind" ]] || return 1
                cleanup_event remove-reference "$ref" intent || return 1
                if [[ $kind == manifest ]]; then
                    timeout 45 podman manifest rm "$id" >/dev/null || return 1
                elif [[ $kind == image ]]; then
                    timeout 45 podman untag "$id" "$ref" >/dev/null || return 1
                else return 1; fi
                cleanup_gate "$gate_path" || return 1
                cleanup_images || return 1
                [[ $CK_PROTECTED == "$protected" ]] || return 1
                jq -e --arg ref "$ref" 'any(.[]; .reference == $ref and .id == null)' <<< "$CK_IMAGES" >/dev/null || return 1
                cleanup_event remove-reference "$ref" 'done' || return 1
            fi
        done < <(jq -c '.planned.images[]' <<< "$CK_JOURNAL_JSON")
        cleanup_gate "$gate_path" || return 1
        cleanup_final_resources || return 1
        migration_verify "$ROOT" "$CK_MIGRATION" >/dev/null || return 1
        [[ $(stat -c %d:%i -- "$MI_SOURCE") == "$(jq -r .source.identity <<< "$CK_JOURNAL_JSON")" ]] || return 1
        cleanup_phase retirement-prepared || return 1
        phase=retirement-prepared
    fi
    if [[ $phase == retirement-prepared ]]; then
        cleanup_retained_trees || return 1
        if [[ -e $MI_SOURCE ]]; then
            migration_verify "$ROOT" "$CK_MIGRATION" >/dev/null || return 1
            [[ ! -e $CK_QUARANTINE && ! -L $CK_QUARANTINE ]] || return 1
            migration_publish "$MI_SOURCE" "$CK_QUARANTINE" || return 1
            sync -f "$ROOT/.local/podman" || return 1
        fi
        migration_private "$CK_QUARANTINE" || return 1
        [[ $(stat -c %d:%i -- "$CK_QUARANTINE") == "$(jq -r .source.identity <<< "$CK_JOURNAL_JSON")" ]] || return 1
        cleanup_snapshot_retirement || return 1
        phase=retiring
    fi
    if [[ $phase == retiring ]]; then
        cleanup_retained_trees || return 1
        cleanup_delete_retirement || return 1
        cleanup_phase retired || return 1
    fi
    cleanup_gate "$gate_path" || return 1
    cleanup_final_resources || return 1
    [[ $CK_PROTECTED == "$protected" ]] || return 1
    jq -e 'all(.[]; .id == null)' <<< "$CK_IMAGES" >/dev/null || return 1
    jq -e 'all(.[]; .id == null)' <<< "$CK_CONTAINERS" >/dev/null || return 1
    [[ ! -e $MI_SOURCE && ! -L $MI_SOURCE && ! -e $CK_QUARANTINE && ! -L $CK_QUARANTINE ]] || return 1
    cleanup_retained_trees || return 1
    migration_check_lock || return 1
    receipt=$(jq -Sc --arg backup "$CK_BACKUP" --arg destination "$MI_DESTINATION" --arg ref "$CK_RETAINED_REFERENCE" \
        --argjson verified "$CK_PROTECTED" '
        {schema:"stardew-legacy-cleanup",version:1,status:"complete",completion:true,project,gate,migration,
        source:(.source+{retired:true}),removed:{containers:[.planned.containers[]|select(.id!=null)],
        references:[.planned.images[]|select(.id!=null)]},
        absent_before:{containers:[.planned.containers[]|select(.id==null)],references:[.planned.images[]|select(.id==null)]},
        retained:{backup:$backup,destination:$destination,manifest:$ref,index:$verified.index,members:$verified.members,
          ordinary_objects:[.planned.images[]|select(.kind=="image")|{id,reason:"reference-safety-unproven-object-retained"}],
          legacy_members:[.planned.images[]|select(.kind=="manifest")|.members[]|
            {digest,reason:"shared-or-reference-safety-unproven-member-retained"}]},
        verification:{scope:["backup","destination"],source_stability_verified:false,resources_requeried:true}}' \
        <<< "$CK_JOURNAL_JSON") || return 1
    if [[ -e $CK_RECEIPT ]]; then
        migration_read_private "$CK_RECEIPT" || return 1
        [[ $MI_READ_JSON == "$receipt" ]] || return 1
    else
        migration_write_private "$CK_RECEIPT" "$receipt" || return 1
    fi
    migration_verify_retained "$ROOT" "$CK_MIGRATION" "$CK_RECEIPT" >/dev/null || return 1
    CK_JOURNAL_JSON=$(jq -Sc '.phase="complete"|.status="complete"|.source.retired=true' <<< "$CK_JOURNAL_JSON") || return 1
    cleanup_store_journal || return 1
    printf 'Cleanup complete: legacy references/container retired; exact original source removed; backup/destination verified.\nReceipt: %s\n' "$CK_RECEIPT"
)

cleanup_run() {
    cleanup_run_impl "$@" 2>/dev/null || {
        printf 'Cleanup refused/incomplete: gate, identity, state or operation failed; retained data preserved. Check private journal before retry.\n' >&2
        return 1
    }
}
