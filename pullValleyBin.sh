#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$ROOT/scripts/lib/steam-cache.sh"

mode=${1:-acquire}
[[ $# -le 1 ]] || steam_die 'Usage: ./pullValleyBin.sh [--validate|--refresh|--recover]'
case "$mode" in
    acquire|--validate|--refresh|--recover) ;;
    --help|-h)
        printf 'Usage: ./pullValleyBin.sh [--validate|--refresh|--recover]\n'
        exit 0 ;;
    *) steam_die "Unknown option: $mode" ;;
esac
[[ $EUID -ne 0 ]] || steam_die 'Use your ordinary user, not root, for acquisition.'
steam_require_tools
steam_lock "$ROOT" -x
cache="$ROOT/src/steam"
if [[ "$mode" == --recover ]]; then
    steam_recover "$ROOT"
    exit
fi
steam_check_recovery "$ROOT"
if [[ "$mode" == --validate || ( "$mode" != --refresh && -e "$cache" ) ]]; then
    steam_validate "$cache"
    printf 'Steam cache valid; reused without network access.\n'
    exit
fi
[[ -t 0 && -t 1 ]] || steam_die 'Acquisition requires an interactive terminal for Steam authentication.'
[[ "$(uname -m)" == x86_64 ]] ||
    steam_die 'Acquire on x86_64 Linux, then transfer the complete cache to other hosts.'
for tool in curl tar; do
    command -v "$tool" >/dev/null || steam_die "Missing acquisition prerequisite: $tool"
done
home="${XDG_DATA_HOME:-$HOME/.local/share}/stardew-dev/steamcmd"
home=$(realpath -m "$home")
[[ "$home" != "$ROOT" && "$home" != "$ROOT/"* ]] ||
    steam_die 'Steam account state must be stored outside the repository.'
mkdir -p "$home"
[[ ! -L "$home" && "$(stat -c %u "$home")" == "$EUID" ]] ||
    steam_die 'SteamCMD storage must be owned by the invoking user.'
chmod 700 "$home"
# Also serialize the private Steam session across multiple repository checkouts.
[[ ! -L "$home/session.lock" ]] || steam_die 'Unsafe Steam session lock.'
exec 8>"$home/session.lock"
flock -x 8
if [[ ! -e "$home/steamcmd.sh" ]]; then
    curl --fail --location --retry 3 \
        https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
        --output "$home/bootstrap.tar.gz"
    tar -tzf "$home/bootstrap.tar.gz" > "$home/bootstrap.files"
    while IFS= read -r member; do
        case "/$member" in
            //*|*/../*|*$'\t'*|*$'\r'*|*\\*) steam_die 'Unsafe SteamCMD bootstrap archive path.' ;;
        esac
    done < "$home/bootstrap.files"
    tar -tvzf "$home/bootstrap.tar.gz" > "$home/bootstrap.types"
    if grep -qvE '^[-d]' "$home/bootstrap.types"; then
        steam_die 'SteamCMD bootstrap archive must contain only regular files/directories.'
    fi
    tar --extract --gzip --file "$home/bootstrap.tar.gz" --directory "$home" \
        --no-same-owner --no-same-permissions
    rm -f "$home/bootstrap.tar.gz" "$home/bootstrap.files" "$home/bootstrap.types"
fi
[[ -f "$home/steamcmd.sh" && ! -L "$home/steamcmd.sh" ]] || steam_die 'Invalid SteamCMD launcher.'
[[ ! -L "$ROOT/src/.steam-staging" ]] || steam_die 'Staging path must not be a symlink.'
mkdir -p "$ROOT/src/.steam-staging"
temporary=$(mktemp -d "$ROOT/src/.steam-staging/download-XXXXXXXX")
cleanup() {
    local status=$?
    trap - EXIT
    rm -rf -- "$temporary"
    if (( status != 0 )); then
        printf 'Acquisition failed; previous cache retained or recoverable with --recover.\n' >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage="$temporary/payload"
mkdir -p "$stage/game"
read -r -p 'Steam account (SteamCMD will prompt for password/Guard): ' account
[[ "$account" =~ ^[A-Za-z0-9_@.-]+$ ]] || steam_die 'Invalid or empty account name.'
(
    cd "$home"
    HOME="$home" bash ./steamcmd.sh +@sSteamCmdForcePlatformType linux \
        +force_install_dir "$stage/game" +login "$account" +app_update 413150 validate +quit
)
build_id=
acf="$stage/game/steamapps/appmanifest_413150.acf"
if [[ -f "$acf" ]]; then
    build_id=$(sed -n 's/.*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$acf")
fi
[[ ! -L "$stage/game/steamapps" ]] || steam_die 'Unexpected steamapps symlink.'
if [[ -d "$stage/game/steamapps" ]]; then
    rm -rf -- "$stage/game/steamapps"
fi
for bits in 32 64; do
    mkdir -p "$stage/steam-sdk/sdk$bits"
    cp -p "$home/linux$bits/steamclient.so" "$stage/steam-sdk/sdk$bits/steamclient.so"
done
identity=$(sha256sum < "$home/steamcmd.sh")
steam_seal "$stage" "$build_id" "${identity%% *}"
steam_publish "$ROOT" "$stage"
printf 'Published verified vanilla files to src/steam.\n'
