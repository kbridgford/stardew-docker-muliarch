#!/usr/bin/env bash
# Run inside an owned test container after identifying its exact live game PID.
set -euo pipefail
# shellcheck source=scripts/lib/native-game.sh
source /opt/stardew/lib/native-game.sh
architecture=${1:?}
pid=${2:?}
if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] || (( pid <= 1 )); then native_die 'Invalid game PID.'; fi
[[ "$(dpkg --print-architecture)" == "$architecture" ]] || native_die 'Container architecture mismatch.'
if command -v box64 >/dev/null; then native_die 'Unexpected emulator in native image.'; fi
game=/data/Stardew/game
[[ "$(cat "$game/.smapi-version")" == 4.5.2 ]] || native_die 'Unexpected SMAPI version.'
native_elf "$game/StardewModdingAPI" "$architecture"
native_elf "$game/Stardew Valley" "$architecture"
mapfile -d '' -t argv < "/proc/$pid/cmdline"
for arg in "${argv[@]}"; do
    [[ "${arg##*/}" != box64 ]] || native_die 'Emulated game process.'
done
printf 'Architecture=%s PID=%s\n' "$architecture" "$pid"
printf 'argv: '; printf '%q ' "${argv[@]}"; printf '\n'
printf 'process-exe: %s\n' "$(readlink "/proc/$pid/exe")"
for name in libcoreclr.so libclrjit.so libhostfxr.so libhostpolicy.so libSkiaSharp.so liblwjgl_lz4.so; do
    native_elf "$game/$name" "$architecture"
    printf 'static-%s: %s\n' "$architecture" "$game/$name"
done
case "$architecture" in amd64) triplet=x86_64-linux-gnu ;; arm64) triplet=aarch64-linux-gnu ;; esac
if [[ "$architecture" == arm64 ]]; then
    [[ "$(cat "$game/.valleycore-version")" == '1.6.15g e5949546b0574aaa7b8bf87939569c3cd4d1336857717d01aa9fb88bb3d7c467' ]] ||
        native_die 'Unexpected ValleyCore version.'
    [[ -z "$(find /data/.steam -mindepth 1 -print -quit)" ]] || native_die 'x86 Steam SDK leaked into ARM output.'
fi
for name in libSDL2-2.0.so.0 libopenal.so.1; do
    file=$(realpath -e "/usr/lib/$triplet/$name")
    native_elf "$file" "$architecture"
    printf 'static-%s: %s\n' "$architecture" "$file"
done
maps=$(cat "/proc/$pid/maps")
if grep -q '/unsupported-x86/' <<< "$maps"; then native_die 'Quarantined library was loaded.'; fi
for name in libcoreclr.so libclrjit.so libhostfxr.so libhostpolicy.so; do
    grep -Fq "$game/$name" <<< "$maps" || native_die "Runtime library not mapped: $name"
done
paths=$(awk -v triplet="$triplet" '$6 ~ /\.so/ &&
    (index($6,"/data/Stardew/game/")==1 || index($6,"/usr/lib/"triplet"/")==1 ||
     index($6,"/lib/"triplet"/")==1) {print $6}' <<< "$maps" | sort -u)
[[ -n "$paths" ]] || native_die 'No guest library mappings found.'
while IFS= read -r file; do
    native_elf "$(realpath -e "$file")" "$architecture"
    printf 'mapped-%s: %s\n' "$architecture" "$file"
done <<< "$paths"
printf '%s\n' '--- raw maps (host emulator mappings are separate from the guest libraries above) ---'
printf '%s\n' "$maps"
