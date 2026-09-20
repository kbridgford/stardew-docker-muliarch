#!/bin/bash
set -euo pipefail
export HOME=/config
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/config/xdg/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/config/xdg/data}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/config/xdg/cache}"
export TERM=xterm
export SMAPI_USE_CURRENT_SHELL=true
: "${GAME_PATH:?}"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
touch /config/.dev-launch-start

if [ "${STARDEW_MODDED:-1}" = 1 ]; then
    shopt -s nullglob
    for mod_path in "$GAME_PATH"/Mods/*/; do
        mod=$(basename "$mod_path")
        variable="ENABLE_$(printf '%s' "$mod" | tr '[:lower:]' '[:upper:]' | LC_ALL=C tr -cd '[:upper:]')_MOD"
        enabled=$(printenv "$variable" || test "$?" = 1)
        if [ "$enabled" != true ]; then
            # Keep disabled files recoverable when this same container restarts.
            mkdir -p "$GAME_PATH/DisabledMods"
            mv "$mod_path" "$GAME_PATH/DisabledMods/$mod"
            continue
        fi
    done
    for mod_path in "$GAME_PATH"/DisabledMods/*/; do
        mod=$(basename "$mod_path")
        variable="ENABLE_$(printf '%s' "$mod" | tr '[:lower:]' '[:upper:]' | LC_ALL=C tr -cd '[:upper:]')_MOD"
        enabled=$(printenv "$variable" || test "$?" = 1)
        if [ "$enabled" = true ]; then
            mv "$mod_path" "$GAME_PATH/Mods/$mod"
        fi
    done
    for mod_path in "$GAME_PATH"/Mods/*/; do
        if [ -f "$mod_path/config.json.template" ] && [ ! -s "$mod_path/config.json" ]; then
            temporary=$(mktemp)
            envsubst < "$mod_path/config.json.template" > "$temporary"
            if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$temporary" >/dev/null; then
                rm -f "$temporary"
                echo "Invalid generated configuration for $(basename "$mod_path")." >&2
                exit 1
            fi
            if [ -f "$mod_path/config.json.template.jq" ]; then
                filtered=$(mktemp)
                if ! jq -e -f "$mod_path/config.json.template.jq" "$temporary" > "$filtered"; then
                    rm -f "$temporary" "$filtered"
                    echo "Invalid generated configuration for $(basename "$mod_path")." >&2
                    exit 1
                fi
                mv "$filtered" "$temporary"
            fi
            cat "$temporary" > "$mod_path/config.json"
            rm -f "$temporary"
        fi
    done
    executable="$GAME_PATH/StardewModdingAPI"
else
    executable="$GAME_PATH/Stardew Valley"
fi

if [ ! -x "$executable" ]; then
    echo "Missing executable: $executable" >&2
    exit 1
fi
cd "$GAME_PATH"
printf 'Starting %s\n' "$(basename "$executable")"
exec /opt/stardew/container/exec-game.sh "$executable" "$@"
