#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/native-game.sh"
umask 077
[[ ! -L "$ROOT/.local" && ! -L "$ROOT/.local/validation" ]]
work="$ROOT/.local/validation/native-fixtures-$BASHPID-$RANDOM"
mkdir -p "$work"
trap 'rm -rf -- "$work"' EXIT

put() {
    local file=$1 offset=$2 value=$3 width=${4:-4} i
    for ((i=0; i<width; i++)); do
        printf '%b' "$(printf '\\%03o' "$(( (value >> (8*i)) & 255 ))")"
    done | dd of="$file" bs=1 seek="$offset" count="$width" conv=notrunc status=none
}
managed() {
    local file=$1 machine=${2:-34404} flags=${3:-1} pe=${4:-128} optional table
    dd if=/dev/zero of="$file" bs=2048 count=1 status=none
    optional=$((pe+24)); table=$((optional+240))
    put "$file" 0 23117 2; put "$file" 60 "$pe"
    put "$file" "$pe" 17744; put "$file" "$((pe+4))" "$machine" 2
    put "$file" "$((pe+6))" 1 2; put "$file" "$((pe+20))" 240 2
    put "$file" "$optional" 523 2
    put "$file" "$((optional+108))" 16
    put "$file" "$((optional+224))" 4096; put "$file" "$((optional+228))" 72
    put "$file" "$((table+12))" 4096; put "$file" "$((table+16))" 512
    put "$file" "$((table+20))" 1024
    put "$file" 1024 72; put "$file" 1032 4224; put "$file" 1036 32
    put "$file" 1040 "$flags"; put "$file" 1152 1112167234
}
elf() {
    local file=$1 machine=${2:-183}
    dd if=/dev/zero of="$file" bs=64 count=1 status=none
    put "$file" 0 1179403647; put "$file" 4 2 1; put "$file" 5 1 1
    put "$file" 18 "$machine" 2
}
reject() {
    if ("$@") > "$work/error" 2>&1; then printf 'Unexpected acceptance: %s\n' "$*" >&2; exit 1; fi
    grep -q 'Native game:' "$work/error"
}
for pe in 128 256; do
    managed "$work/assembly" 34404 1 "$pe"
    native_patch "$work/assembly" > "$work/patch.log"
    native_pe "$work/assembly"
    [[ "$PE_MACHINE" == 43620 && "$PE_MACHINE_OFFSET" == "$((pe+4))" ]]
    before=$(sha256sum "$work/assembly")
    native_patch "$work/assembly"
    [[ "$before" == "$(sha256sum "$work/assembly")" ]]
done
for flags in 1 3; do
    managed "$work/assembly" 332 "$flags"
    before=$(sha256sum "$work/assembly")
    native_patch "$work/assembly" > "$work/patch.log"
    [[ "$before" == "$(sha256sum "$work/assembly")" ]]
done
for invalid in signature offset sections optional machine clr mixed native metadata truncated; do
    managed "$work/assembly"
    case "$invalid" in
        signature) put "$work/assembly" 128 0 ;;
        offset) put "$work/assembly" 60 999999 ;;
        sections) put "$work/assembly" 134 97 2 ;;
        optional) put "$work/assembly" 152 999 2 ;;
        machine) put "$work/assembly" 132 999 2 ;;
        clr) put "$work/assembly" 376 0 ;;
        mixed) put "$work/assembly" 1040 0 ;;
        native) put "$work/assembly" 1088 4096 ;;
        metadata) put "$work/assembly" 1152 0 ;;
        truncated) truncate -s 200 "$work/assembly" ;;
    esac
    reject native_patch "$work/assembly"
done
elf "$work/elf"
native_elf "$work/elf" arm64
reject native_elf "$work/elf" amd64
put "$work/elf" 4 1 1
reject native_elf "$work/elf" arm64
printf 'PASS PE parsing, exact architecture patch, idempotency, AnyCPU/32-bit preservation and invalid binary guards\n'

mkdir -p "$work/game/Mods/ConsoleCommands" "$work/game/Mods/SaveBackup" "$work/root-mods/Example" "$work/overlay/Mods" "$work/bin"
for component in ConsoleCommands SaveBackup; do
    printf '{"UniqueId":"SMAPI.%s","Version":"4.5.2"}\n' "$component" > "$work/game/Mods/$component/manifest.json"
    managed "$work/game/Mods/$component/component.dll" 332
done
printf '{"UniqueID":"example.mod"}\n' > "$work/root-mods/Example/manifest.json"
native_mods "$work/game" "$work/root-mods"
printf '\357\273\277{/* block */"UniqueID":"example.mod",// line\n"url":"https://example.test/*keep*/","quote":"\\\"//keep"}\n' \
    > "$work/root-mods/Example/manifest.json"
native_mods "$work/game" "$work/root-mods"
native_manifest "$work/root-mods/Example/manifest.json" |
    jq -e '.url=="https://example.test/*keep*/" and .quote=="\"//keep"' >/dev/null
printf '{"UniqueID":"example.mod", /* unterminated}\n' > "$work/root-mods/Example/manifest.json"
reject native_mods "$work/game" "$work/root-mods"
printf '{"UniqueID":"example.mod","invalid":1/* separator */2}\n' > "$work/root-mods/Example/manifest.json"
reject native_mods "$work/game" "$work/root-mods"
printf '{"UniqueID":"smapi.consolecommands"}\n' > "$work/root-mods/Example/manifest.json"
reject native_mods "$work/game" "$work/root-mods"
printf '{"UniqueID":"example.mod","UniqueId":"ambiguous"}\n' > "$work/root-mods/Example/manifest.json"
reject native_mods "$work/game" "$work/root-mods"
printf 'PASS case-insensitive mod IDs and collision/malformed identity guards\n'
for name in 'Stardew Valley.dll' MonoGame.Framework.dll xTile.dll StardewValley.GameData.dll \
    BmFont.dll Lidgren.Network.dll Steamworks.NET.dll StardewModdingAPI.dll; do managed "$work/game/$name"; done
printf '4.5.2\n' > "$work/game/.smapi-version"
printf '{}\n' > "$work/game/Stardew Valley.deps.json"
cp -a "$work/game/Mods/." "$work/overlay/Mods/"
for name in 'Stardew Valley' StardewModdingAPI libcoreclr.so libclrjit.so libhostfxr.so \
    libhostpolicy.so libSkiaSharp.so liblwjgl_lz4.so; do elf "$work/overlay/$name"; done
managed "$work/overlay/StardewModdingAPI.dll"
printf '{}\n' > "$work/overlay/StardewModdingAPI.runtimeconfig.json"
tar -czf "$work/bundle.tar.gz" -C "$work/overlay" .
cat > "$work/bin/curl" <<'SH'
#!/bin/bash
set -euo pipefail
while (( $# )); do
    if [[ "$1" == --output ]]; then cp "$FIXTURE_ARCHIVE" "$2"; exit; fi
    shift
done
exit 1
SH
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH" FIXTURE_ARCHIVE="$work/bundle.tar.gz"
export GAME_PATH="$work/game" VALLEYCORE_VERSION=1.6.15g SMAPI_VERSION=4.5.2
VALLEYCORE_SHA256=$(sha256sum "$FIXTURE_ARCHIVE"); export VALLEYCORE_SHA256=${VALLEYCORE_SHA256%% *}
hash=$VALLEYCORE_SHA256
VALLEYCORE_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
    reject bash "$ROOT/scripts/container/prepare-valleycore.sh"
mv "$work/game/BmFont.dll" "$work/BmFont.dll"
reject bash "$ROOT/scripts/container/prepare-valleycore.sh"
mv "$work/BmFont.dll" "$work/game/BmFont.dll"
bash "$ROOT/scripts/container/prepare-valleycore.sh" > "$work/prepare.log"
find "$work/game" -type f -print0 | sort -z | xargs -0 sha256sum > "$work/before"
bash "$ROOT/scripts/container/prepare-valleycore.sh" > "$work/prepare.log"
find "$work/game" -type f -print0 | sort -z | xargs -0 sha256sum > "$work/after"
cmp "$work/before" "$work/after"
printf 'unsafe\n' > "$work/safe"
tar -czf "$work/unsafe.tar.gz" --transform='s#^safe#../escape#' -C "$work" safe
export FIXTURE_ARCHIVE="$work/unsafe.tar.gz"
VALLEYCORE_SHA256=$(sha256sum "$FIXTURE_ARCHIVE"); export VALLEYCORE_SHA256=${VALLEYCORE_SHA256%% *}
reject bash "$ROOT/scripts/container/prepare-valleycore.sh"
[[ ! -e "$work/escape" ]]
[[ "$hash" == "$(sha256sum "$work/bundle.tar.gz" | cut -d ' ' -f1)" ]]
printf 'PASS verified overlay, checksum/missing-file/archive-path failures and repeat preparation\n'
