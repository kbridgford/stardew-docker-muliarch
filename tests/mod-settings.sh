#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
for tool in jq envsubst; do
    command -v "$tool" >/dev/null || { printf 'Missing test prerequisite: %s\n' "$tool" >&2; exit 1; }
done
umask 077
[[ ! -L "$ROOT/.local" && ! -L "$ROOT/.local/validation" ]]
work="$ROOT/.local/validation/mod-settings-$BASHPID-$RANDOM"
mkdir -p "$work"
trap 'rm -rf -- "$work"' EXIT
number=0

fixture() {
    number=$((number + 1))
    current="$work/$number"
    mkdir -p "$current/game/Mods" "$current/config" "$current/tmp"
    for mod in 'Crops Anytime Anywhere' TimeSpeed; do
        mkdir "$current/game/Mods/$mod"
        cp "$ROOT/mods/$mod/config.json.template" "$ROOT/mods/$mod/config.json.template.jq" \
            "$current/game/Mods/$mod/"
    done
    cat > "$current/game/StardewModdingAPI" <<'SH'
#!/bin/bash
printf 'started\n' > "$FIXTURE_STARTED"
SH
    chmod +x "$current/game/StardewModdingAPI"
    printf '#!/bin/bash\nexec "$@"\n' > "$current/dispatch"
    chmod +x "$current/dispatch"
    sed -e "s#HOME=/config#HOME=$current/config#" \
        -e "s#:-/config/#:-$current/config/#g" -e "s#touch /config/#touch $current/config/#" \
        -e "s#/opt/stardew/container/exec-game.sh#$current/dispatch#g" \
        "$ROOT/scripts/container/startapp.sh" > "$current/startapp.sh"
    crops="$current/game/Mods/Crops Anytime Anywhere/config.json"
    time="$current/game/Mods/TimeSpeed/config.json"
}

render() (
    source "$ROOT/scripts/lib/steam-cache.sh"
    source "$ROOT/scripts/lib/podman-steam.sh"
    while IFS= read -r key; do
        case "$key" in TIME_SPEED_*|CROPS_ANYTIME_ANYWHERE_*|ENABLE_*) unset "$key" ;; esac
    done < <(compgen -e)
    declare -A SETTINGS=() PRIVATE_ENV=([VNC_PASSWORD]=synthetic-password
        [ENABLE_TIMESPEED_MOD]=true [ENABLE_CROPSANYTIMEANYWHERE_MOD]=true)
    for assignment in "$@"; do PRIVATE_ENV["${assignment%%=*}"]=${assignment#*=}; done
    select_target multiarch
    compose_environment
    for key in "${!SETTINGS[@]}"; do export "$key=${SETTINGS[$key]}"; done
    export GAME_PATH="$current/game" STARDEW_MODDED=1 TMPDIR="$current/tmp"
    export XDG_CONFIG_HOME="$current/config/xdg/config" XDG_DATA_HOME="$current/config/xdg/data"
    export XDG_CACHE_HOME="$current/config/xdg/cache" FIXTURE_STARTED="$current/started"
    bash "$current/startapp.sh"
)

expect_invalid() {
    fixture
    if render "$@" > "$current/error" 2>&1; then
        printf 'Unexpected acceptance: %s\n' "$*" >&2; exit 1
    fi
    grep -q 'Invalid generated configuration for' "$current/error"
    [[ ! -e "$current/started" ]]
    [[ -z "$(find "$current/tmp" -mindepth 1 -print -quit)" ]]
}

fixture
render > "$current/output"
jq -e '.EnableOnFestivalDays == false and .LocationNotify == false and
    .LetFarmhandsManageTime == false and
    ([.SecondsPerMinute.Indoors, .SecondsPerMinute.Outdoors, .SecondsPerMinute.Mines,
      .SecondsPerMinute.SkullCavern, .SecondsPerMinute.VolcanoDungeon] | all(.[]; . == 0.7)) and
    .FreezeTime.AnywhereAtTime == null and .FreezeTime.PassOut == false and
    .Keys.FreezeTime == "N" and .Keys.IncreaseTickInterval == "OemPeriod" and
    .Keys.DecreaseTickInterval == "OemComma" and .Keys.ReloadConfig == "B" and
    (has("DefaultTickLength") or has("TickLengthByLocation") or has("FreezeTimeAt") | not)' "$time" >/dev/null
jq -e '.PlantRules[0].ForLocations == [] and
    .PlantRules[0].ForSeasons == ["Fall","Spring","Summer","Winter"] and
    .PlantRules[0].CanPlant and .PlantRules[0].CanGrowOutOfSeason and
    (.PlantRules[0].UseFruitTreesSeasonalSprites | not) and
    .TillableRules[0].Dirt and .TillableRules[0].Grass and
    (.TillableRules[0].Stone | not) and (.TillableRules[0].Other | not) and
    (has("EnableInSeasons") or has("FarmAnyLocation") or has("ForceTillable") | not)' "$crops" >/dev/null
printf 'PASS legacy-intent defaults expressed only in current mod schemas\n'

fixture
render TIME_SPEED_SECONDS_PER_MINUTE_INDOORS=1.2 TIME_SPEED_SECONDS_PER_MINUTE_OUTDOORS=0.4 \
    TIME_SPEED_SECONDS_PER_MINUTE_MINES=0.8 TIME_SPEED_SECONDS_PER_MINUTE_SKULL_CAVERN=0.9 \
    TIME_SPEED_SECONDS_PER_MINUTE_VOLCANO_DUNGEON=1.1 TIME_SPEED_FREEZE_ANYWHERE_AT_TIME=2200 \
    TIME_SPEED_FREEZE_BEFORE_PASS_OUT=true TIME_SPEED_FREEZE_INDOORS=true TIME_SPEED_FREEZE_OUTDOORS=true \
    TIME_SPEED_FREEZE_MINES=true TIME_SPEED_FREEZE_SKULL_CAVERN=true TIME_SPEED_FREEZE_VOLCANO_DUNGEON=true \
    TIME_SPEED_ENABLE_ON_FESTIVAL_DAYS=true TIME_SPEED_LOCATION_NOTIFY=true \
    TIME_SPEED_LET_FARMHANDS_MANAGE_TIME=true 'TIME_SPEED_KEYS_FREEZE_TIME=LeftShift + N' \
    TIME_SPEED_KEYS_RELOAD_CONFIG= 'CROPS_ANYTIME_ANYWHERE_SEASONS=["winter","SUMMER","winter"]' \
    'CROPS_ANYTIME_ANYWHERE_LOCATIONS=["Farm","Greenhouse"]' 'CROPS_ANYTIME_ANYWHERE_LOCATION_CONTEXTS=["Default"]' \
    CROPS_ANYTIME_ANYWHERE_CAN_PLANT=false CROPS_ANYTIME_ANYWHERE_CAN_GROW_OUT_OF_SEASON=false \
    CROPS_ANYTIME_ANYWHERE_USE_FRUIT_TREES_SEASONAL_SPRITES=true CROPS_ANYTIME_ANYWHERE_TILLABLE_DIRT=false \
    CROPS_ANYTIME_ANYWHERE_TILLABLE_GRASS=false CROPS_ANYTIME_ANYWHERE_TILLABLE_STONE=true \
    CROPS_ANYTIME_ANYWHERE_TILLABLE_OTHER=true > "$current/output"
jq -e '.SecondsPerMinute == {Indoors:1.2,Outdoors:0.4,Mines:0.8,SkullCavern:0.9,VolcanoDungeon:1.1,ByLocationName:{}} and
    .EnableOnFestivalDays and .LocationNotify and .LetFarmhandsManageTime and
    .FreezeTime.AnywhereAtTime == 2200 and
    ([.FreezeTime.PassOut,.FreezeTime.Indoors,.FreezeTime.Outdoors,.FreezeTime.Mines,
      .FreezeTime.SkullCavern,.FreezeTime.VolcanoDungeon] | all(.[]; . == true)) and
    .Keys.FreezeTime == "LeftShift + N" and .Keys.ReloadConfig == ""' "$time" >/dev/null
jq -e '.PlantRules[0].ForSeasons == ["Summer","Winter"] and
    .PlantRules[0].ForLocations == ["Farm","Greenhouse"] and .PlantRules[0].ForLocationContexts == ["Default"] and
    (.PlantRules[0].CanPlant | not) and (.PlantRules[0].CanGrowOutOfSeason | not) and
    .PlantRules[0].UseFruitTreesSeasonalSprites and (.TillableRules[0].Dirt | not) and
    (.TillableRules[0].Grass | not) and .TillableRules[0].Stone and .TillableRules[0].Other and
    .TillableRules[0].ForSeasons == .PlantRules[0].ForSeasons and
    .TillableRules[0].ForLocations == .PlantRules[0].ForLocations' "$crops" >/dev/null
printf 'PASS custom seconds/minute, freeze, multiplayer, key, season/location and tilling controls\n'

fixture
render 'CROPS_ANYTIME_ANYWHERE_SEASONS=[]' TIME_SPEED_FREEZE_ANYWHERE_AT_TIME=2600 \
    TIME_SPEED_SECONDS_PER_MINUTE_INDOORS=0.001 TIME_SPEED_SECONDS_PER_MINUTE_OUTDOORS=214748.364 > "$current/output"
jq -e '.PlantRules == [] and .TillableRules == []' "$crops" >/dev/null
jq -e '.SecondsPerMinute.Indoors == 0.001 and .SecondsPerMinute.Outdoors == 214748.364 and
    .FreezeTime.AnywhereAtTime == 2600' "$time" >/dev/null
printf 'PASS empty seasons disables overrides; numeric limits accepted\n'

for value in 0 -1 0.0009 214748.365 2147483.647 '"0.7"' null 1e999; do
    expect_invalid "TIME_SPEED_SECONDS_PER_MINUTE_INDOORS=$value"
done
for value in 599 2601 1260 2200.5 '"2200"'; do expect_invalid "TIME_SPEED_FREEZE_ANYWHERE_AT_TIME=$value"; done
for setting in 'TIME_SPEED_LET_FARMHANDS_MANAGE_TIME="true"' 'TIME_SPEED_FREEZE_MINES=1' \
    'CROPS_ANYTIME_ANYWHERE_CAN_PLANT="true"' 'CROPS_ANYTIME_ANYWHERE_SEASONS=["monsoon"]' \
    'CROPS_ANYTIME_ANYWHERE_SEASONS="Winter"' 'CROPS_ANYTIME_ANYWHERE_LOCATIONS=["Indoors"]' \
    'CROPS_ANYTIME_ANYWHERE_LOCATIONS=["outdoors"]' 'CROPS_ANYTIME_ANYWHERE_LOCATIONS=[null]' \
    'CROPS_ANYTIME_ANYWHERE_LOCATION_CONTEXTS=[1]' 'CROPS_ANYTIME_ANYWHERE_TILLABLE_DIRT=garbage'; do
    expect_invalid "$setting"
done
printf 'PASS malformed/wrong-type values, invalid clock/speed, and inverted location aliases fail before game launch\n'

fixture
printf '{"operator":"preserve exactly"}\n' > "$crops"
printf '{"operator":"preserve exactly"}\n' > "$time"
render TIME_SPEED_SECONDS_PER_MINUTE_INDOORS=invalid CROPS_ANYTIME_ANYWHERE_CAN_PLANT=invalid > "$current/output"
grep -Fxq '{"operator":"preserve exactly"}' "$crops"
grep -Fxq '{"operator":"preserve exactly"}' "$time"
[[ -s "$current/started" ]]
printf 'PASS existing nonempty configurations remain authoritative\n'

fixture
render ENABLE_TIMESPEED_MOD=false ENABLE_CROPSANYTIMEANYWHERE_MOD=false \
    TIME_SPEED_SECONDS_PER_MINUTE_INDOORS=invalid CROPS_ANYTIME_ANYWHERE_CAN_PLANT=invalid > "$current/output"
[[ -d "$current/game/DisabledMods/TimeSpeed" && -d "$current/game/DisabledMods/Crops Anytime Anywhere" ]]
[[ -z "$(find "$current/game" -name config.json -print -quit)" ]]
render > "$current/output"
[[ -s "$time" && -s "$crops" ]]
printf 'PASS disabled mods skip generation and re-enabled mods receive validated tuning\n'
