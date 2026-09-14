#!/usr/bin/env bash
# All deletion tests use owned synthetic roots and a non-forwarding Podman model.
set +x
set -euo pipefail
umask 077
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
ROOT=$REPO
source "$REPO/scripts/lib/legacy-cleanup.sh"
source "$REPO/scripts/lib/steam-cache.sh"
source "$REPO/scripts/lib/podman-steam.sh"
[[ $EUID -ne 0 ]] || exit 1
safe_path "$REPO/.local"
private_directory "$REPO/.local"
workspace=$REPO/.local/cleanup-tests-$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID-$RANDOM
mkdir -m 700 -- "$workspace"
workspace_id=$(stat -c %d:%i -- "$workspace")
finish() {
    local rc=$?
    trap - EXIT
    if [[ -d $workspace && ! -L $workspace && $(stat -c %d:%i -- "$workspace") == "$workspace_id" ]]; then
        rm -rf --one-file-system -- "$workspace"
    fi
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
count=0
fail() { printf 'FAIL cleanup case %s: %s\n' "$count" "$1" >&2; exit 1; }
check() { "$@" || fail assertion; }
passed() { printf 'ok %s - %s\n' "$count" "$1"; }
model_edit() { jq -Sc "$1" "$troot/model.json" > "$troot/model-edit"; mv -- "$troot/model-edit" "$troot/model.json"; }
gate_edit() { jq -Sc "$1" "$gate" > "$troot/gate-edit"; cat "$troot/gate-edit" > "$gate"; }

setup() {
    count=$((count + 1))
    troot=$workspace/case-$count
    mkdir -p -- "$troot/scripts/lib" "$troot/bin" "$troot/.local/podman/v3arm64" \
        "$troot/.local/validation/consolidate-final-gate"
    for rel in scripts/cleanup-legacy-state.sh scripts/migrate-multiarch-state.sh \
        scripts/lib/legacy-cleanup.sh scripts/lib/state-inventory.sh scripts/lib/steam-cache.sh scripts/lib/podman-steam.sh; do
        cp -- "$REPO/$rel" "$troot/$rel"
    done
    cp -- "$REPO/tests/fixtures/migration-podman" "$troot/bin/podman"
    chmod 700 -- "$troot/bin/podman"
    src=$troot/.local/podman/v3arm64
    dst=$troot/.local/podman/multiarch
    mkdir -- "$src/nested"
    printf 'synthetic confidential fixture\n' > "$src/private"
    printf 'synthetic nested\n' > "$src/nested/payload"
    ln -s -- nested/payload "$src/link"
    id=7882f8783d741d4abfbb211cb87c73ae6a52c1a75642426ac074aa8171333599
    jq -nc --arg id "$id" '{id:$id}' > "$troot/container.json"
    PATH="$troot/bin:$PATH" MIGRATION_FIXTURE_ROOT=$troot \
        bash "$troot/scripts/migrate-multiarch-state.sh" --execute > "$troot/migration-output" 2>&1 || fail fixture-migration
    local -a receipts=("$troot/.local/migrations/"*/receipt.json)
    migration=${receipts[0]}
    backup=${migration%/*}/state
    cleanup_dir=${migration%/*}/cleanup
    cleanup_receipt=$cleanup_dir/receipt.json
    gate=$troot/.local/validation/consolidate-final-gate/gate.json
    project=$(printf '%s' "$troot" | migration_digest); project=${project:0:12}
    local members manifest allowlist images checks name log sha
    members=$(jq -nc '[
        {digest:("sha256:"+("a"*64)),size:1,mediaType:"application/vnd.oci.image.manifest.v1+json",platform:{os:"linux",architecture:"arm64"}},
        {digest:("sha256:"+("b"*64)),size:1,mediaType:"application/vnd.oci.image.manifest.v1+json",platform:{os:"linux",architecture:"amd64"}}]')
    manifest=$(jq -nSc --argjson members "$members" \
        '{schemaVersion:2,mediaType:"application/vnd.oci.image.index.v1+json",manifests:$members}')
    allowlist=$(cleanup_allowlist)
    images=$(jq -nc --arg project "$project" --argjson list "$allowlist" --argjson manifest "$manifest" '
        [$list[] | {Id:.id,Names:["localhost/stardew-dev-"+$project+":"+.tag],Digest:("sha256:"+.id),
        ManifestType:(if .kind=="manifest" then "application/vnd.oci.image.index.v1+json" else "application/vnd.oci.image.manifest.v1+json" end),
        Manifest:(if .kind=="manifest" then $manifest else null end)}] +
        [{Id:"db60eb79a477cb7b4ea5e68647090985473f707bdcfe9aca0b47c4fae0bcd83c",Names:["localhost/stardew-dev-"+$project+":multiarch"],
        Digest:("sha256:"+("c"*64)),ManifestType:"application/vnd.oci.image.index.v1+json",Manifest:$manifest},
        {Id:("1"*64),Names:[],Digest:("sha256:"+("a"*64)),ManifestType:"application/vnd.oci.image.manifest.v1+json"},
        {Id:("2"*64),Names:[],Digest:("sha256:"+("b"*64)),ManifestType:"application/vnd.oci.image.manifest.v1+json"},
        {Id:("3"*64),Names:["localhost/unrelated:keep"],Digest:("sha256:"+("d"*64)),ManifestType:"application/vnd.oci.image.manifest.v1+json"}]')
    jq -nc --argjson images "$images" --arg project "$project" --arg id "$id" \
        '{images:$images,containers:[{Id:$id,Name:("stardew-dev-"+$project+"-v3arm64"),Image:("2"*64),
        Config:{Labels:{"io.stardew.local-project":$project}},State:{Status:"exited",Running:false,Paused:false,Restarting:false}}]}' \
        > "$troot/model.json"
    cp -- "$REPO/tests/fixtures/cleanup-podman" "$troot/bin/podman"
    for tool in rm mv; do cp -- "$REPO/tests/fixtures/cleanup-io" "$troot/bin/$tool"; done
    chmod 700 -- "$troot/bin/"*
    checks='[]'
    for name in build-first build-repeat archprobe-amd64 archprobe-arm64 smoke-amd64 smoke-arm64 lifecycle regressions shellcheck; do
        log=$troot/.local/validation/consolidate-final-gate/$name.log
        printf 'Synthetic passing evidence %s\n' "$name" > "$log"
        sha=$(migration_digest < "$log")
        checks=$(jq -nc --argjson checks "$checks" --arg name "$name" --arg path "$log" --arg sha "$sha" \
            '$checks+[{name:$name,path:$path,sha256:$sha,exit_code:0}]')
    done
    jq -nSc --arg root "$troot" --arg project "$project" --arg migration "$migration" --arg sha "$(migration_digest < "$migration")" \
        --arg ref "localhost/stardew-dev-$project:multiarch" --arg manifest_sha "$(printf '%s\n' "$manifest" | migration_digest)" \
        --argjson members "$members" --argjson checks "$checks" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schema:"stardew-consolidation-gate",version:1,complete:true,created_at:$time,project:{root:$root,hash:$project},
        migration:{receipt:$migration,sha256:$sha},manifest:{reference:$ref,canonical_sha256:$manifest_sha,members:$members},checks:$checks}' > "$gate"
    mkdir -p -- "$troot/.local/podman/v3x86" "$troot/src/steam" "$troot/mods"
    printf keep > "$troot/.local/podman/v3x86/keep"
    printf keep > "$troot/src/steam/keep"
    printf keep > "$troot/mods/keep"
    printf 'synthetic private env\n' > "$troot/.local/validation/runtime.local.env"
    before=$(migration_inventory "$src")
    migration_sha=$(migration_digest < "$migration")
    inventory_sha=$(migration_digest < "${migration%/*}/inventory.json")
}

cli() {
    local expect=$1 rc=0
    shift
    PATH="$troot/bin:$PATH" CLEANUP_FIXTURE_ROOT=$troot \
        bash "$troot/scripts/cleanup-legacy-state.sh" "$@" > "$troot/output" 2>&1 || rc=$?
    if [[ $expect == success ]]; then ((rc == 0)) || fail cli-success
    else ((rc != 0)) || fail cli-refusal; fi
    if grep -qE 'confidential|payload|synthetic private env' "$troot/output"; then fail disclosure; fi
}
no_mutation() {
    check test "$(migration_inventory "$src")" = "$before"
    check test ! -e "$cleanup_dir"
    if [[ -f $troot/operations.jsonl ]]; then
        jq -se 'all(.[]; .[0]!="stop" and .[0]!="rm" and .[0]!="untag" and .[0:2]!=["manifest","rm"])' \
            "$troot/operations.jsonl" >/dev/null || fail unexpected-mutation
    fi
}
retained() {
    local tree
    for tree in "$backup" "$dst"; do
        check test "$(migration_inventory "$tree" | jq -Sc .entries)" = "$(jq -Sc .entries <<< "$before")"
    done
    check test "$(migration_digest < "$migration")" = "$migration_sha"
    check test "$(migration_digest < "${migration%/*}/inventory.json")" = "$inventory_sha"
    check test "$(cat "$troot/.local/podman/v3x86/keep")" = keep
    check test "$(cat "$troot/src/steam/keep")" = keep
    check test "$(cat "$troot/mods/keep")" = keep
    jq -e '[.images[].Id] | contains([("1"*64),("2"*64),("3"*64),
        "db60eb79a477cb7b4ea5e68647090985473f707bdcfe9aca0b47c4fae0bcd83c"])' "$troot/model.json" >/dev/null || fail retained-members
}
verify_retained_cli() {
    local rc=0 expect=$1 paths=${2:-absolute} migration_arg=$migration cleanup_arg=$cleanup_receipt
    case "$paths" in
        absolute) ;;
        relative) migration_arg=${migration#"$troot/"}; cleanup_arg=${cleanup_receipt#"$troot/"} ;;
        relative-migration) migration_arg=${migration#"$troot/"} ;;
        relative-cleanup) cleanup_arg=${cleanup_receipt#"$troot/"} ;;
        noncanonical-cleanup) cleanup_arg=${cleanup_receipt#"$troot/"}; cleanup_arg=${cleanup_arg%/*}/./receipt.json ;;
        *) fail path-mode ;;
    esac
    (
        cd -- "$troot"
        PATH="$troot/bin:$PATH" CLEANUP_FIXTURE_ROOT=$troot \
            ./scripts/migrate-multiarch-state.sh --verify-retained "$migration_arg" "$cleanup_arg"
    ) > "$troot/verify-output" 2>&1 || rc=$?
    if [[ $expect == success ]]; then ((rc == 0)) || fail retained-verification
    else ((rc != 0)) || fail retained-refusal; fi
}

setup
cli refusal
cli refusal --execute extra
cli success --dry-run
no_mutation
passed 'strict CLI and no-write gate-aware dry-run'

setup
cli success --execute
check test ! -e "$src"
check test -f "$cleanup_receipt"
retained
verify_retained_cli success
verify_retained_cli success relative
verify_retained_cli success relative-migration
verify_retained_cli success relative-cleanup
verify_retained_cli refusal noncanonical-cleanup
report=$(PATH="$troot/bin:$PATH" CLEANUP_FIXTURE_ROOT=$troot migration_verify_retained "$troot" "$migration" "$cleanup_receipt")
jq -e '.schema=="stardew-retained-state-verification" and .verified==true and
    .scope==["backup","destination"] and .source_absent==true and .source_stability_verified==false' <<< "$report" >/dev/null ||
    fail retained-report
cli success --execute
PATH="$troot/bin:$PATH" CLEANUP_FIXTURE_ROOT=$troot \
    bash "$troot/scripts/migrate-multiarch-state.sh" --verify "$migration" > "$troot/pre-verify" 2>&1 && fail absent-source-accepted
check test "$(jq -r .status "$cleanup_dir/journal.json")" = complete
check test "$(jq -r '.removed.references|length' "$cleanup_receipt")" = 4
check test "$(jq -r '.retained.ordinary_objects|length' "$cleanup_receipt")" = 3
passed 'complete cleanup, absolute/relative/mixed receipt paths, strict path guards and idempotence'

for filter in '.complete=false' '.project.hash="forged"' '.checks[0].exit_code=1' \
    '.checks[0].name=.checks[1].name' '.checks|=.[1:]' '.checks[0].path=.checks[1].path' \
    '.migration.sha256=("0"*64)' '.manifest.canonical_sha256=("0"*64)' '.created_at="2000-01-01T00:00:00Z"'; do
    setup
    gate_edit "$filter"
    cli refusal --execute
    no_mutation
    passed 'failed, forged or stale gate rejected before mutation'
done

setup
printf changed >> "$troot/.local/validation/consolidate-final-gate/build-first.log"
cli refusal --execute
no_mutation
passed 'evidence checksum changes rejected'

setup
for path in "$gate" "$troot/.local/validation/consolidate-final-gate/build-first.log"; do
    chmod 644 -- "$path"
    cli refusal --execute
    chmod 600 -- "$path"
    ln -- "$path" "$troot/hard-evidence"
    cli refusal --execute
    rm -- "$troot/hard-evidence"
done
chmod 755 -- "$troot/.local/validation"
cli refusal --execute
chmod 700 -- "$troot/.local/validation"
no_mutation
passed 'private single-link evidence and parent guards'

setup
model_edit '.images |= map(if .Id=="db60eb79a477cb7b4ea5e68647090985473f707bdcfe9aca0b47c4fae0bcd83c"
    then .Manifest.manifests[0].size=2 else . end)'
cli refusal --execute
no_mutation
passed 'current manifest differs from authoritative gate'

setup
model_edit '.images += [.images[0],.images[4],.images[5]]'
cli success --dry-run
no_mutation
passed 'identical per-tag image-list records deduplicated without weakening identity checks'

for tree_name in source backup destination; do
    setup
    case $tree_name in source) tree=$src ;; backup) tree=$backup ;; destination) tree=$dst ;; esac
    printf 'changed synthetic\n' > "$tree/private"
    cli refusal --execute
    check test ! -e "$cleanup_dir"
    passed 'changed source/backup/destination rejected before deletion'
done

setup
model_edit '.containers[0].Config.Labels["io.stardew.local-project"]="foreign"'
cli refusal --execute
no_mutation
passed 'foreign container ownership rejected'

setup
model_edit '.containers[0].Id=("9"*64)'
cli refusal --execute
no_mutation
passed 'unexpected immutable container substitution rejected'

setup
model_edit '.containers += [(.containers[0] | .Id=("9"*64) | .Name|=sub("v3arm64$";"v3x86"))]'
cli refusal --execute
no_mutation
passed 'unexpected allowlisted-name container rejected'

setup
model_edit '.images |= map(if .Id=="0acd962313535f2135853fef514d0a9454c91ecc19ae8617393e706f9725bab2" then .Id=("8"*64) else . end)'
cli refusal --execute
no_mutation
passed 'unexpected legacy index substitution rejected'

setup
model_edit '.images |= map(if .Id=="0acd962313535f2135853fef514d0a9454c91ecc19ae8617393e706f9725bab2"
    then .Names+=["localhost/unrelated:protected-index-alias"] else . end)'
cli refusal --execute
no_mutation
passed 'index aliases block object-wide manifest removal'

setup
model_edit '.images |= map(if .Id=="58fd3ce832bd7baa7dcd71e85a48d898f1b4f1880bea17d7be1c62fdccda985b"
    then .Names+=["localhost/unrelated:retained-image-alias"] else . end)'
cli success --execute
retained
jq -e 'any(.images[]; any(.Names[]?; .=="localhost/unrelated:retained-image-alias"))' "$troot/model.json" >/dev/null || fail alias-lost
passed 'ordinary-image untag preserves object and unrelated alias'

for fault in stop-fail rm-fail manifest-fail manifest-noop untag-fail; do
    setup
    model_edit ".fault=\"$fault\""
    cli refusal --execute
    check test -d "$src"
    check test ! -e "$cleanup_receipt"
    retained
    model_edit 'del(.fault)'
    cli success --execute
    retained
    verify_retained_cli success
    passed 'failed operation is explicit and journaled partial retry completes'
done

for fault in rename-signal delete-fail delete-signal; do
    setup
    printf '%s\n' "$fault" > "$troot/io-fault"
    cli refusal --execute
    check test ! -e "$src"
    check test ! -e "$cleanup_receipt"
    retained
    verify_retained_cli refusal
    rm -- "$troot/io-fault"
    cli success --execute
    retained
    verify_retained_cli success
    passed 'interrupted source retirement resumes only verified owned leftovers'
done

setup
printf 'delete-fail\n' > "$troot/io-fault"
cli refusal --execute
quarantine=$(jq -r .source.quarantine "$cleanup_dir/journal.json")
printf 'foreign new data\n' > "$quarantine/new-entry"
rm -- "$troot/io-fault"
cli refusal --dry-run
cli refusal --execute
check test -f "$quarantine/new-entry"
check test ! -e "$cleanup_receipt"
retained
passed 'partial-retirement retry refuses unexpected new data'

setup
cli success --execute
verify_retained_cli success
mv -- "$cleanup_receipt" "$troot/saved-cleanup"
verify_retained_cli refusal
mv -- "$troot/saved-cleanup" "$cleanup_receipt"
jq '.completion=false' "$cleanup_receipt" > "$troot/forged-cleanup"
cp -- "$cleanup_receipt" "$troot/saved-cleanup"
cat "$troot/forged-cleanup" > "$cleanup_receipt"
verify_retained_cli refusal
cat "$troot/saved-cleanup" > "$cleanup_receipt"
mkdir -- "$src"
verify_retained_cli refusal
rmdir -- "$src"
chmod 644 -- "$cleanup_receipt"
verify_retained_cli refusal
chmod 600 -- "$cleanup_receipt"
printf changed > "$dst/private"
verify_retained_cli refusal
passed 'post-retirement verification rejects missing/forged proof, present source and changed retained state'

printf 'Cleanup regressions passed: %s synthetic cases.\n' "$count"
