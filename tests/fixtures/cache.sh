#!/usr/bin/env bash

cache_fixture() {
    local destination=$1
    mkdir -p "$destination/game/Content" "$destination/steam-sdk/sdk32" "$destination/steam-sdk/sdk64"
    printf '#!/bin/sh\nexit 0\n' > "$destination/game/StardewValley"
    chmod +x "$destination/game/StardewValley"
    cp -p "$destination/game/StardewValley" "$destination/game/Stardew Valley"
    printf 'synthetic game DLL fixture\n' > "$destination/game/Stardew Valley.dll"
    printf '{"runtimeOptions":{"tfm":"net6.0"}}\n' > "$destination/game/Stardew Valley.runtimeconfig.json"
    printf 'synthetic content\n' > "$destination/game/Content/test file.txt"
    printf 'synthetic library\n' > "$destination/steam-sdk/sdk32/steamclient.so"
    printf 'synthetic library\n' > "$destination/steam-sdk/sdk64/steamclient.so"
    ln -s 'Content/test file.txt' "$destination/game/content-link"
    steam_seal "$destination" 123 test-launcher
}
