#!/usr/bin/env bash
set -euo pipefail
[[ $# -ge 1 && -x "$1" ]] || { echo 'Missing executable game apphost.' >&2; exit 1; }
architecture=$(dpkg --print-architecture)
case "$architecture" in
    amd64)
        printf 'Container architecture amd64: native game execution.\n'
        exec "$@" ;;
    arm64)
        command -v box64 >/dev/null ||
            { echo 'ARM64 requires Box64, but it is not installed in this image.' >&2; exit 1; }
        case "${1##*/}" in
            StardewModdingAPI|'Stardew Valley')
                # Avoid observed .NET startup stalls with newer CALLRET=2 under host QEMU.
                # Disable this optimization for the game, not the dynarec itself.
                export BOX64_DYNAREC_CALLRET=0
                printf 'Box64 game compatibility: BOX64_DYNAREC_CALLRET=0.\n' ;;
        esac
        printf 'Container architecture arm64: executing x86_64 game through Box64.\n'
        exec box64 "$@" ;;
    *)
        printf 'Unsupported container architecture: %s\n' "$architecture" >&2
        exit 1 ;;
esac
