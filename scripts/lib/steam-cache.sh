#!/usr/bin/env bash

STEAM_CACHE_HELP='Run ./pullValleyBin.sh explicitly on the host; builds never download Steam or game files.'

steam_die() {
    printf 'Steam cache: %s\n' "$*" >&2
    exit 1
}

steam_require_tools() {
    local tool
    for tool in jq sha256sum flock realpath find sort stat cmp mktemp; do
        command -v "$tool" >/dev/null || steam_die "Missing prerequisite: $tool"
    done
}

steam_lock() {
    local root=$1 mode=$2
    [[ ! -L "$root/src" && ! -L "$root/src/.steam-cache.lock" ]] ||
        steam_die 'Cache and lock paths must not be symlinks.'
    mkdir -p "$root/src"
    exec 9>"$root/src/.steam-cache.lock"
    flock "$mode" 9
}

steam_inventory() (
    set -euo pipefail
    local cache=$1 work path name lower base hash executable size target entry
    [[ -d "$cache" && ! -L "$cache" ]] || steam_die "Missing/unsafe cache. $STEAM_CACHE_HELP"
    cache=$(realpath "$cache")
    work=$(mktemp -d)
    trap 'rm -f "$work/files" "$work/entries"; rmdir "$work"' EXIT
    find "$cache" -mindepth 1 -maxdepth 1 -print0 > "$work/files"
    while IFS= read -r -d '' path; do
        case "${path##*/}" in
            game|steam-sdk|manifest.json|SHA256SUMS) ;;
            *) steam_die 'Unexpected top-level cache content; keep account state outside src.' ;;
        esac
    done < "$work/files"
    : > "$work/entries"
    for base in game steam-sdk; do
        [[ -d "$cache/$base" && ! -L "$cache/$base" ]] ||
            steam_die "Missing/unsafe payload directory: $base"
        find "$cache/$base" -mindepth 1 -print0 | LC_ALL=C sort -z > "$work/files"
        while IFS= read -r -d '' path; do
            name=${path#"$cache/"}
            case "$name" in
                *$'\n'*|*$'\r'*|*$'\t'*|*\\*) steam_die 'Unsupported control character in filename.' ;;
            esac
            lower="/${name,,}/"
            case "$lower" in
                */mods/*|*/saves/*|*/steamapps/*|*/userdata/*|*/config/*|*/stardewmoddingapi*|*/ssfn*)
                    steam_die "Non-vanilla or session content: $name" ;;
            esac
            if [[ -L "$path" ]]; then
                target=$(realpath -e "$path") || steam_die "Broken symlink: $name"
                [[ "$target" == "$cache/$base/"* && -f "$target" ]] ||
                    steam_die "Escaping or non-file symlink: $name"
                entry=$(readlink "$path")
                case "$entry" in
                    /*|*$'\n'*|*$'\r'*|*$'\t'*|*\\*) steam_die "Unsupported symlink: $name" ;;
                esac
                hash=$(sha256sum < "$target")
                printf '%s\tlink\t%s\t%s\t0\tfalse\n' "$name" "${hash%% *}" "$entry" >> "$work/entries"
            elif [[ -f "$path" ]]; then
                hash=$(sha256sum < "$path")
                size=$(stat -c %s "$path")
                executable=false
                [[ ! -x "$path" ]] || executable=true
                printf '%s\tfile\t%s\t\t%s\t%s\n' "$name" "${hash%% *}" "$size" "$executable" >> "$work/entries"
            elif [[ ! -d "$path" ]]; then
                steam_die "Unsupported payload file type: $name"
            fi
        done < "$work/files"
    done
    for name in 'game/StardewValley' 'game/Stardew Valley' 'game/Stardew Valley.dll' \
        'game/Stardew Valley.runtimeconfig.json' \
        'steam-sdk/sdk32/steamclient.so' 'steam-sdk/sdk64/steamclient.so'; do
        [[ -s "$cache/$name" ]] || steam_die "Missing/empty required artifact: $name"
    done
    [[ -x "$cache/game/StardewValley" ]] || steam_die 'Game launcher lost its executable bit.'
    [[ -x "$cache/game/Stardew Valley" ]] || steam_die 'Linux apphost lost its executable bit.'
    grep -q '^game/Content/' "$work/entries" || steam_die 'Missing game Content files.'
    jq -e 'type == "object" and (.runtimeOptions | type == "object")' \
        "$cache/game/Stardew Valley.runtimeconfig.json" >/dev/null ||
        steam_die 'Invalid game runtime configuration.'
    jq -Rn '[inputs | split("\t") | {
        key: .[0], value: {type: .[1], sha256: .[2], link: .[3],
                          size: (.[4] | tonumber), executable: (.[5] == "true")}
    }] | from_entries' < "$work/entries"
)

steam_validate() (
    set -euo pipefail
    local cache=$1 work name
    [[ -d "$cache" && ! -L "$cache" ]] || steam_die "Missing/unsafe cache. $STEAM_CACHE_HELP"
    for name in manifest.json SHA256SUMS; do
        [[ -f "$cache/$name" && ! -L "$cache/$name" ]] ||
            steam_die "Missing/unsafe $name. $STEAM_CACHE_HELP"
    done
    jq -e '.schema == 1 and .app_id == "413150" and .platform == "linux"
           and .branch == "public" and (.files | type == "object")' \
        "$cache/manifest.json" >/dev/null || steam_die 'Unsupported cache schema/app/platform/branch.'
    work=$(mktemp -d)
    trap 'rm -f "$work/actual" "$work/expected" "$work/checksums"; rmdir "$work"' EXIT
    steam_inventory "$cache" | jq -S . > "$work/actual"
    jq -S .files "$cache/manifest.json" > "$work/expected"
    cmp -s "$work/actual" "$work/expected" ||
        steam_die 'Manifest mismatch; restore vanilla inputs or explicitly refresh.'
    jq -r 'to_entries | sort_by(.key)[] | "\(.value.sha256)  \(.key)"' \
        "$work/actual" > "$work/checksums"
    cmp -s "$work/checksums" "$cache/SHA256SUMS" || steam_die 'Checksum inventory mismatch.'
)

steam_seal() (
    set -euo pipefail
    local cache=$1 build_id=${2:-} identity=${3:-} work
    work=$(mktemp)
    trap 'rm -f "$work"' EXIT
    steam_inventory "$cache" > "$work"
    jq -n --slurpfile files "$work" --arg date "$(date -u +%FT%TZ)" \
        --arg build "$build_id" --arg identity "$identity" \
        '{schema: 1, app_id: "413150", platform: "linux", branch: "public",
          acquired_at: $date, steam_build_id: (if $build == "" then null else $build end),
          steamcmd_launcher_sha256: (if $identity == "" then null else $identity end),
          files: $files[0]}' > "$cache/manifest.json"
    jq -r 'to_entries | sort_by(.key)[] | "\(.value.sha256)  \(.key)"' \
        "$work" > "$cache/SHA256SUMS"
    steam_validate "$cache"
)

steam_check_recovery() {
    local root=$1
    [[ ! -e "$root/src/.steam-backup" && ! -L "$root/src/.steam-backup" ]] ||
        steam_die 'Interrupted publication: use ./pullValleyBin.sh --recover before building or refreshing.'
}

steam_recover() {
    local root=$1 cache=$1/src/steam backup=$1/src/.steam-backup
    [[ -e "$backup" || -L "$backup" ]] || steam_die 'No interrupted publication to recover.'
    if [[ -e "$cache" || -L "$cache" ]]; then
        steam_validate "$cache"
        steam_die 'Published cache is valid. Move src/.steam-backup outside src to retain or discard it explicitly.'
    fi
    steam_validate "$backup"
    mv -T "$backup" "$cache"
    printf 'Recovered the verified previous cache.\n'
}

steam_publish() {
    local root=$1 stage=$2 cache=$1/src/steam backup=$1/src/.steam-backup
    steam_check_recovery "$root"
    steam_validate "$stage"
    [[ ! -L "$cache" ]] || steam_die 'Refusing to replace a symlink cache.'
    if [[ -e "$cache" ]]; then
        [[ -d "$cache" ]] || steam_die 'Cache path is not a directory.'
        mv -T "$cache" "$backup"
    fi
    if ! mv -T "$stage" "$cache"; then
        if [[ -d "$backup" ]]; then
            mv -T "$backup" "$cache"
        fi
        steam_die 'Publication failed; prior cache restored when present.'
    fi
    if [[ -d "$backup" ]]; then
        rm -rf -- "$backup"
    fi
}
