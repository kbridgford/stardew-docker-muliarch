#!/bin/bash
set -euo pipefail
: "${GAME_PATH:?}"
: "${SMAPI_VERSION:?}"
: "${SMAPI_SHA256:?Set the exact installer SHA-256.}"
[[ "$SMAPI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ &&
    "$SMAPI_SHA256" =~ ^[a-f0-9]{64}$ ]] ||
    { printf 'Invalid SMAPI version or installer checksum.\n' >&2; exit 1; }

if [ "$(uname -m)" != x86_64 ]; then
    echo "The pinned Linux SMAPI installer requires an x86_64 build host." >&2
    exit 1
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --fail --location --retry 3 \
    "https://github.com/Pathoschild/SMAPI/releases/download/${SMAPI_VERSION}/SMAPI-${SMAPI_VERSION}-installer.zip" \
    --output "$work/installer.zip"
printf '%s  %s\n' "$SMAPI_SHA256" "$work/installer.zip" | sha256sum --check --status ||
    { printf 'SMAPI installer checksum mismatch.\n' >&2; exit 1; }
unzip -q "$work/installer.zip" -d "$work/unpacked"
mapfile -d '' installers < <(find "$work/unpacked" -type f -path '*/internal/linux/SMAPI.Installer' -print0)
if [ "${#installers[@]}" -ne 1 ]; then
    echo "Expected exactly one Linux SMAPI installer." >&2
    exit 1
fi
chmod +x "${installers[0]}"
"${installers[0]}" --install --no-prompt --game-path "$GAME_PATH"
test -s "$GAME_PATH/StardewModdingAPI.dll"
test -s "$GAME_PATH/StardewModdingAPI.runtimeconfig.json"
test -x "$GAME_PATH/StardewModdingAPI"
for component in ConsoleCommands SaveBackup; do
    [[ "$(jq -er .Version "$GAME_PATH/Mods/$component/manifest.json")" == "$SMAPI_VERSION" ]] ||
        { printf 'SMAPI bundled component version mismatch.\n' >&2; exit 1; }
done
cmp "$GAME_PATH/Stardew Valley.deps.json" "$GAME_PATH/StardewModdingAPI.deps.json"
printf '%s\n' "$SMAPI_VERSION" > "$GAME_PATH/.smapi-version"
