#!/usr/bin/env bash
# Explicit gate-authorized retirement; never a build/run side effect.
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/legacy-cleanup.sh"
usage() {
    printf '%s\n' \
        'Usage: scripts/cleanup-legacy-state.sh --dry-run|--execute' \
        'Requires .local/validation/consolidate-final-gate/gate.json and its exact private evidence.' \
        'Execute resumes its private journal; only approved legacy references/container and v3arm64 state are retired.' \
        'Backup, migrated state, other legacy state, shared members and ambiguous image objects are retained.'
}
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --dry-run|--execute) [[ $# == 1 ]] || { usage >&2; exit 2; }; mode=${1#--} ;;
    *) usage >&2; exit 2 ;;
esac
cleanup_run "$ROOT" "$mode" "$ROOT/.local/validation/consolidate-final-gate/gate.json"
