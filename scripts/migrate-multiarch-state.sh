#!/usr/bin/env bash
# Explicit backup/copy only; never removes legacy state or starts a workload.
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/state-inventory.sh"

usage() {
    printf '%s\n' \
        'Usage: scripts/migrate-multiarch-state.sh --dry-run|--execute' \
        '       scripts/migrate-multiarch-state.sh --verify RECEIPT' \
        '       scripts/migrate-multiarch-state.sh --verify-retained RECEIPT CLEANUP_RECEIPT' \
        'Dry-run and verification never create state, locks or evidence.' \
        'Execute retains original state and a verified private backup; no overwrite or automatic rollback.' \
        'Verification checks receipt ownership, source stability and all three complete inventories.' \
        'Retained verification requires completed cleanup evidence and absent source; checks backup/destination only.'
}
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --dry-run|--execute) [[ $# == 1 ]] || { usage >&2; exit 2; }; mode=${1#--} ;;
    --verify) [[ $# == 2 ]] || { usage >&2; exit 2; }; mode=verify ;;
    --verify-retained) [[ $# == 3 ]] || { usage >&2; exit 2; }; mode=verify-retained ;;
    *) usage >&2; exit 2 ;;
esac
if [[ "$mode" == verify-retained ]]; then
    receipt=$(migration_verify_retained "$ROOT" "$2" "$3")
    printf 'Retained verification passed: %s entries; backup/destination exact; source retired, stability not checked.\n' \
        "$(jq -r .entries <<< "$receipt")"
elif [[ "$mode" == verify ]]; then
    receipt=$(migration_verify "$ROOT" "$2")
    printf 'Verification passed: %s entries; source/backup/destination exact and private.\n' \
        "$(jq -r .inventory.entries <<< "$receipt")"
else
    migration_run "$ROOT" "$mode"
fi
