#!/usr/bin/env bash
# Synthetic only. All fixtures/evidence stay beneath this repository's .local.
set +x
set -euo pipefail
umask 077
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
[[ $EUID -ne 0 ]] || { printf 'Run migration tests as a non-root user.\n' >&2; exit 1; }
ROOT=$REPO
source "$REPO/scripts/lib/steam-cache.sh"
source "$REPO/scripts/lib/podman-steam.sh"
source "$REPO/scripts/lib/state-inventory.sh"
safe_path "$REPO/.local"
private_directory "$REPO/.local"
mkdir -p -- "$REPO/.local"
workspace=$REPO/.local/migration-tests-$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID-$RANDOM
mkdir -m 700 -- "$workspace"
workspace_id=$(stat -c %d:%i -- "$workspace")
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -d $workspace && ! -L $workspace && $(stat -c %d:%i -- "$workspace") == "$workspace_id" ]]; then
        rm -rf --one-file-system -- "$workspace"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
count=0

fail() { printf 'FAIL: migration case %s (%s).\n' "$count" "$1" >&2; exit 1; }
check() { "$@" || fail assertion; }

setup() {
    count=$((count + 1))
    troot=$workspace/case-$count
    mkdir -p -- "$troot/scripts/lib" "$troot/bin" "$troot/.local/podman/v3arm64"
    for rel in scripts/migrate-multiarch-state.sh scripts/lib/state-inventory.sh \
        scripts/lib/steam-cache.sh scripts/lib/podman-steam.sh; do
        cp -- "$REPO/$rel" "$troot/$rel"
    done
    cp -- "$REPO/tests/fixtures/migration-podman" "$troot/bin/podman"
    for tool in cp mv; do cp -- "$REPO/tests/fixtures/migration-io" "$troot/bin/$tool"; done
    chmod 700 -- "$troot/bin/"*
    src=$troot/.local/podman/v3arm64
    dst=$troot/.local/podman/multiarch
    evidence=$troot/.local/migrations
    lock=$troot/.local/podman/.multiarch-migration.lock
    mkdir -- "$src/nested" "$src/tmp"
    chmod 755 -- "$src/nested"
    chmod 1777 -- "$src/tmp"
    printf 'synthetic data only\n' > "$src/nested/payload"
    chmod 640 -- "$src/nested/payload"
    printf 'synthetic private data\n' > "$src/private"
    printf 'synthetic special filename\n' > "$src/"$'odd\nname'
    printf 'unicode\n' > "$src/"$'\303\251\360\237\214\210'
    printf 'sort before dot\n' > "$src/!first"
    ln -s -- nested/payload "$src/link"
    printf '{}\n' > "$troot/container.json"
    before=$(migration_inventory "$src") || fail fixture
}

cli() {
    local expect=$1 rc=0
    shift
    PATH="$troot/bin:$PATH" MIGRATION_FIXTURE_ROOT=$troot \
        bash "$troot/scripts/migrate-multiarch-state.sh" "$@" > "$troot/output" 2>&1 || rc=$?
    if [[ $expect == success ]]; then (( rc == 0 )) || fail cli-success
    else (( rc != 0 )) || fail cli-refusal; fi
    if grep -qE 'synthetic private data|odd|payload' "$troot/output"; then fail disclosure; fi
}

receipt_path() {
    local -a receipts
    shopt -s nullglob
    receipts=("$evidence/"*/receipt.json)
    shopt -u nullglob
    [[ ${#receipts[@]} == 1 ]] || fail receipt-count
    receipt=${receipts[0]}
}

unchanged() {
    check test "$(migration_inventory "$src")" = "$before"
    check test ! -e "$dst"
    check test ! -L "$dst"
    local leftovers
    leftovers=$(find "$troot/.local/podman" -maxdepth 1 -name '.multiarch-migration-stage-*' -printf x)
    check test -z "$leftovers"
}

no_receipt() {
    local found=''
    if [[ -d $evidence ]]; then found=$(find "$evidence" -name receipt.json -printf x); fi
    check test -z "$found"
}

fault() { printf '%s\n' "$1" > "$troot/fault"; }
configure() { printf '%s\n' "$1" > "$troot/container.json"; }
passed() { printf 'ok %s - %s\n' "$count" "$1"; }

setup
cli refusal
cli refusal --execute extra
cli success --dry-run
unchanged
check test ! -e "$evidence"
check test ! -e "$lock"
: > "$lock"
stamp=$(migration_stamp "$lock")
cli success --dry-run
check test "$(migration_stamp "$lock")" = "$stamp"
passed 'explicit modes and read-only dry-run'

setup
cli success --execute
receipt_path
cli success --verify "$receipt"
result=$(PATH="$troot/bin:$PATH" MIGRATION_FIXTURE_ROOT=$troot migration_verify "$troot" "$receipt") || fail api
check test "$(migration_inventory "$src")" = "$before"
expected=$(jq -Sc .entries <<< "$before")
backup=$(jq -r .paths.backup <<< "$result")
for tree in "$backup" "$dst"; do
    check test "$(migration_inventory "$tree" | jq -Sc .entries)" = "$expected"
    check test "$(stat -c %a -- "$tree")" = 700
done
for path in "$evidence" "${receipt%/*}"; do check test "$(stat -c %a -- "$path")" = 700; done
for path in "${receipt%/*}/"*.json "$lock"; do check test "$(stat -c %a -- "$path")" = 600; done
check test "$(migration_digest < "${receipt%/*}/inventory.json")" = "$(jq -r .inventory.sha256 <<< "$result")"
cli refusal --execute
passed 'execute, backup, private evidence and reusable verifier'

setup
mkdir -- "$dst"
cli refusal --execute
printf keep > "$dst/keep"
cli refusal --execute
check test "$(cat "$dst/keep")" = keep
check test ! -e "$evidence"
passed 'empty and populated destination refusal'

setup
for config in '{"status":"running"}' '{"status":"paused"}' '{"owned":false}' \
    '{"new":true,"status":"running"}' '{"new":true,"owned":false}' '{"rootless":false}' \
    '{"restarting":true}' '{"error":true}' '{"identity_change":true}'; do
    configure "$config"
    cli refusal --execute
    unchanged
    check test ! -e "$evidence"
done
passed 'bounded rootless, ownership, immutable-ID and activity refusals'

setup
mv -- "$src" "$troot/saved"
cli refusal --execute
check test ! -e "$evidence"
passed 'missing source refusal'

setup
for target in ../../outside "$troot/container.json"; do
    ln -s -- "$target" "$src/unsafe"
    cli refusal --execute
    rm -- "$src/unsafe"
    check test ! -e "$evidence"
done
passed 'escaping and absolute symlink refusal'

setup
mv -- "$src" "$troot/.local/podman/saved"
ln -s -- saved "$src"
cli refusal --execute
rm -- "$src"
mv -- "$troot/.local/podman/saved" "$src"
ln -s -- absent "$dst"
cli refusal --execute
rm -- "$dst"
ln -s -- "$troot/bin" "$evidence"
cli refusal --execute
rm -- "$evidence"
mv -- "$troot/.local/podman" "$troot/.local/saved"
ln -s -- saved "$troot/.local/podman"
cli refusal --execute
passed 'source, destination, evidence and parent symlink refusal'

setup
for spec in 'root:755' 'parent:755' 'local:755' 'file:666' 'file:4600' 'nested:777' 'file:200'; do
    case ${spec%:*} in
        root) path=$src ;; parent) path=${src%/*} ;; local) path=$troot/.local ;;
        file) path=$src/private ;; nested) path=$src/nested ;;
    esac
    saved_mode=$(stat -c %a -- "$path")
    chmod "${spec#*:}" -- "$path"
    cli refusal --execute
    chmod "$saved_mode" -- "$path"
    check test ! -e "$evidence"
done
passed 'private parent and entry mode refusal'

setup
ln -- "$src/private" "$src/hard"
cli refusal --execute
rm -- "$src/hard"
ln -P -- "$src/link" "$src/hard"
cli refusal --execute
rm -- "$src/hard"
mkfifo -m 600 -- "$src/fifo"
cli refusal --execute
check test ! -e "$evidence"
passed 'hardlinked files/symlinks and special-file refusal'

setup
sample=$(migration_stamp "$src/private")
foreign=$(jq -c --argjson uid "$((EUID + 1))" '.[3]=$uid' <<< "$sample")
if migration_entry_metadata "$foreign"; then fail foreign-owner; fi
foreign=$(jq -c --argjson gid "$(($(id -g) + 1))" '.[4]=$gid' <<< "$sample")
if migration_entry_metadata "$foreign"; then fail foreign-group; fi
passed 'unexpected ownership refusal'

setup
: > "$lock"; chmod 644 -- "$lock"
cli refusal --execute
chmod 600 -- "$lock"
ln -- "$lock" "$troot/hardlock"
cli refusal --execute
rm -- "$troot/hardlock" "$lock"
ln -s -- "$troot/container.json" "$lock"
cli refusal --execute
rm -- "$lock"
(
    ROOT=$troot
    # Inputs to the sourced runtime helper's target and lock functions.
    # shellcheck disable=SC2034
    RUNTIME_PLATFORM=''; STATE_ROOT=''
    select_target multiarch
    lock_normal_state
    printf ready > "$troot/lock-ready"
    # Both children inherit the runtime helper's actual shared lock.
    cli refusal --execute
    cli refusal --dry-run
)
check test "$(cat "$troot/lock-ready")" = ready
inode=$(stat -c %i -- "$lock")
unchanged
cli success --execute
check test "$(stat -c %i -- "$lock")" = "$inode"
passed 'lock security and actual runtime-helper shared-flock coordination'

for kind in backup-fail stage-fail backup-corrupt stage-corrupt; do
    setup
    fault "$kind"
    cli refusal --execute
    unchanged
    no_receipt
    check test "$(find "$evidence" -name failure.json -printf x)" = x
    if [[ $kind == stage-* ]]; then
        check test "$(find "$evidence" -name backup-verified.json -printf x)" = x
    fi
    passed "$kind preserves source and scopes cleanup"
done

setup
fault source-change
cli refusal --execute
check test "$(cat "$src/private")" = 'synthetic external change'
check test ! -e "$dst"
no_receipt
passed 'source mutation during copy refusal'

setup
fault containers-change
cli refusal --execute
unchanged
no_receipt
passed 'container activity before publication refusal'

setup
fault destination-conflict
cli refusal --execute
check test -d "$dst"
check test -z "$(find "$dst" -mindepth 1 -printf x)"
check test "$(migration_inventory "$src")" = "$before"
check test -z "$(find "${src%/*}" -maxdepth 1 -name '.multiarch-migration-stage-*' -printf x)"
no_receipt
passed 'atomic fail-if-exists publication including empty destination'

setup
mkdir -- "${src%/*}/.multiarch-migration-stage-unrelated"
printf keep > "${src%/*}/.multiarch-migration-stage-unrelated/keep"
fault signal-stage
cli refusal --execute
check test "$(cat "${src%/*}/.multiarch-migration-stage-unrelated/keep")" = keep
rm -- "${src%/*}/.multiarch-migration-stage-unrelated/keep"
rmdir -- "${src%/*}/.multiarch-migration-stage-unrelated"
unchanged
no_receipt
check test "$(find "$evidence" -name failure.json -printf x)" = x
passed 'termination cleans only the owned staging inode'

setup
fault signal-publish
cli success --execute
receipt_path
cli success --verify "$receipt"
check test -z "$(find "$evidence" -name failure.json -printf x)"
passed 'termination during protected publication commits receipt'

setup
cli success --execute
receipt_path
backup=$(jq -r .paths.backup "$receipt")
for tree in "$dst" "$backup"; do
    cp -- "$tree/private" "$troot/saved-content"
    printf 'synthetic changed contents\n' > "$tree/private"
    cli refusal --verify "$receipt"
    cat "$troot/saved-content" > "$tree/private"
    cli success --verify "$receipt"
done
cp -- "$src/private" "$troot/saved-content"
printf 'synthetic changed contents\n' > "$src/private"
cli refusal --verify "$receipt"
cat "$troot/saved-content" > "$src/private"
cli refusal --verify "$receipt"
passed 'content tampering and restored-source stability refusal'

setup
cli success --execute
receipt_path
for path in "$receipt" "${receipt%/*}/inventory.json"; do
    chmod 644 -- "$path"
    cli refusal --verify "$receipt"
    chmod 600 -- "$path"
    ln -- "$path" "$troot/hard-evidence"
    cli refusal --verify "$receipt"
    rm -- "$troot/hard-evidence"
    mv -- "$path" "$troot/saved-evidence"
    ln -s -- "$troot/saved-evidence" "$path"
    cli refusal --verify "$receipt"
    rm -- "$path"
    mv -- "$troot/saved-evidence" "$path"
done
chmod 755 -- "${receipt%/*}"
cli refusal --verify "$receipt"
chmod 700 -- "${receipt%/*}"
cli success --verify "$receipt"
passed 'receipt/inventory ownership, links and private-parent guards'

setup
cli success --execute
receipt_path
cp -- "$receipt" "$troot/saved-receipt"
for filter in '.version=2' '.completion=false' '.project.hash="other"' \
    '.paths.backup="/outside"' '.inventory.sha256=("0"*64)' '.containers=[]' \
    '.inventory.entries+=1' '.source_stability_sha256=("0"*64)'; do
    jq -Sc "$filter" "$troot/saved-receipt" > "$receipt"
    cli refusal --verify "$receipt"
done
cat "$troot/saved-receipt" > "$receipt"
printf ' ' >> "${receipt%/*}/inventory.json"
cli refusal --verify "$receipt"
passed 'receipt fields and original inventory byte-checksum tampering'

setup
cli success --execute
receipt_path
# Serialization is not identity: simulate v1 alternate whitespace/key ordering,
# retaining an exact receipt checksum of those stored bytes.
jq '.entries |= map(with_entries(.))' "${receipt%/*}/inventory.json" > "$troot/inventory-formatted"
cat "$troot/inventory-formatted" > "${receipt%/*}/inventory.json"
hash=$(migration_digest < "${receipt%/*}/inventory.json")
jq --arg hash "$hash" '.inventory.sha256=$hash' "$receipt" > "$troot/receipt-formatted"
cat "$troot/receipt-formatted" > "$receipt"
cli success --verify "$receipt"
passed 'v1 structured inventory interoperability without reformatting evidence'

setup
cli success --execute
receipt_path
configure '{"new":true,"status":"running"}'
cli success --verify "$receipt"
passed 'historical receipt verification does not operate on disposable containers'

setup
fault receipt-fail
cli refusal --execute
check test -d "$dst"
check test "$(migration_inventory "$src")" = "$before"
no_receipt
check test "$(find "$evidence" -name failure.json -printf x)" = x
check test "$(jq -r .destination_published "$evidence/"*/failure.json)" = true
passed 'receipt publication failure retains destination and failure evidence'

setup
printf invalid > "$src/"$'\377'
cli refusal --execute
check test ! -e "$evidence"
passed 'invalid UTF-8 refused without filename aliasing'

setup
cp -- "$troot/bin/podman" "$troot/bin/podman.saved"
cat > "$troot/bin/podman" <<'EOF'
#!/usr/bin/env bash
exit 97
EOF
export MIGRATION_FIXTURE_ROOT=$troot
PATH="$troot/bin:$PATH" bash -c '
    set -euo pipefail
    source "$1/scripts/lib/state-inventory.sh"
    migration_inventory "$2" >/dev/null
' bash "$troot" "$src"
passed 'standalone inventory API needs no runtime helper imports or Podman calls'

printf 'Migration regressions passed: %s cases (synthetic roots only).\n' "$count"
