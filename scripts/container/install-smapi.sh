#!/bin/bash
set -euo pipefail
: "${GAME_PATH:?}"
: "${SMAPI_VERSION:?}"

if [ "$(uname -m)" != x86_64 ]; then
    echo "The pinned Linux SMAPI installer requires an x86_64 build host." >&2
    exit 1
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --fail --location --retry 3 \
    "https://github.com/Pathoschild/SMAPI/releases/download/${SMAPI_VERSION}/SMAPI-${SMAPI_VERSION}-installer.zip" \
    --output "$work/installer.zip"
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
printf '%s\n' "$SMAPI_VERSION" > "$GAME_PATH/.smapi-version"
