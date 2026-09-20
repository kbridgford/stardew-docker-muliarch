#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/native-game.sh"
: "${GAME_PATH:?}"
: "${VALLEYCORE_VERSION:?}"
: "${VALLEYCORE_SHA256:?}"
: "${SMAPI_VERSION:?}"
[[ "$VALLEYCORE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+[a-z]?$ &&
    "$VALLEYCORE_SHA256" =~ ^[a-f0-9]{64}$ ]] || native_die 'Require exact ValleyCore version and SHA-256.'
[[ "$(cat "$GAME_PATH/.smapi-version")" == "$SMAPI_VERSION" ]] ||
    native_die 'Prepare the matching official SMAPI version first.'
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
curl --fail --location --retry 3 \
    "https://github.com/a9ix/ValleyCore/releases/download/$VALLEYCORE_VERSION/ValleyCore-SMAPI.tar.gz" \
    --output "$work/bundle.tar.gz"
printf '%s  %s\n' "$VALLEYCORE_SHA256" "$work/bundle.tar.gz" | sha256sum --check --status ||
    native_die 'ValleyCore archive checksum mismatch.'
tar -tzf "$work/bundle.tar.gz" --quoting-style=escape > "$work/names"
tar -tvzf "$work/bundle.tar.gz" > "$work/types"
grep -qvE '^[-d]' "$work/types" && native_die 'Overlay must contain only files and directories.'
while IFS= read -r name; do
    [[ "$name" == ./ ]] && continue
    name=${name#./}
    case "/$name/" in
        //*|*/../*|*/./*|*\\*|*$'\t'*|*$'\r'*) native_die 'Unsafe overlay archive path.' ;;
    esac
done < "$work/names"
mkdir "$work/overlay"
tar -xzf "$work/bundle.tar.gz" -C "$work/overlay" --no-same-owner --no-same-permissions
for name in 'Stardew Valley' StardewModdingAPI libcoreclr.so libclrjit.so libhostfxr.so \
    libhostpolicy.so libSkiaSharp.so liblwjgl_lz4.so; do
    native_elf "$work/overlay/$name" arm64
done
for name in StardewModdingAPI.dll StardewModdingAPI.runtimeconfig.json; do
    [[ -s "$work/overlay/$name" && ! -L "$work/overlay/$name" ]] ||
        native_die "Missing overlay artifact: $name"
done
for name in ConsoleCommands SaveBackup; do
    [[ $(jq -er .Version "$work/overlay/Mods/$name/manifest.json") == "$SMAPI_VERSION" ]] ||
        native_die 'Overlay SMAPI bundled component version mismatch.'
done
required=('Stardew Valley.dll' MonoGame.Framework.dll xTile.dll StardewValley.GameData.dll \
    BmFont.dll Lidgren.Network.dll Steamworks.NET.dll StardewModdingAPI.dll)
for name in "${required[@]}"; do native_pe "$GAME_PATH/$name"; done
find "$GAME_PATH/Mods" -name '*.dll' -type f -print0 > "$work/mod-dlls"
while IFS= read -r -d '' file; do native_pe "$file"; done < "$work/mod-dlls"

cp -a "$work/overlay/." "$GAME_PATH/"
cp "$GAME_PATH/Stardew Valley.deps.json" "$GAME_PATH/StardewModdingAPI.deps.json"
cmp "$GAME_PATH/Stardew Valley.deps.json" "$GAME_PATH/StardewModdingAPI.deps.json"
for name in "${required[@]}"; do native_patch "$GAME_PATH/$name"; done
find "$GAME_PATH/Mods" -name '*.dll' -type f -print0 > "$work/mod-dlls"
while IFS= read -r -d '' file; do native_patch "$file"; done < "$work/mod-dlls"

# Unprovided native store/audio libraries cannot be used by an ARM64 process.
# Keep their identities, not search-path shadows or guessed ABI replacements.
unsupported="$GAME_PATH/../unsupported-x86"
mkdir -p "$unsupported"
for name in libSDL2-2.0.so.0 libopenal.so.1 libFAudio.so.0 libsteam_api.so \
    libGalaxy64.so libGalaxyCSharpGlue.so; do
    [[ -e "$GAME_PATH/$name" ]] || continue
    native_elf "$GAME_PATH/$name" amd64
    [[ ! -e "$unsupported/$name" ]] || native_die "Duplicate unsupported library: $name"
    mv "$GAME_PATH/$name" "$unsupported/$name"
done
for name in 'Stardew Valley' StardewModdingAPI; do
    native_elf "$GAME_PATH/$name" arm64
    chmod +x "$GAME_PATH/$name"
done
native_mods "$GAME_PATH"
printf '%s\n' "$VALLEYCORE_VERSION $VALLEYCORE_SHA256" > "$GAME_PATH/.valleycore-version"
printf 'Prepared native ARM64 SMAPI %s; store APIs require separate runtime verification.\n' "$SMAPI_VERSION"
