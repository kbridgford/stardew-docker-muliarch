#!/usr/bin/env bash
# Fed over stdin so the probe's argv cannot match the game executable.
set -euo pipefail
action=${1:?}
executable=${2:?}

application_argv() {
    (( ${#argv[@]} > 0 )) || return 1
    [[ "${argv[0]}" != "$executable" ]] || return 0
    case "${argv[0]##*/}" in
        box64) [[ "${argv[1]:-}" == "$executable" ]] ;;
        aarch64-binfmt-P|qemu-aarch64|qemu-aarch64-static)
            # binfmt's P flag preserves argv[0] after the Box64 executable.
            [[ "${argv[1]:-}" == */box64 ]] || return 1
            [[ "${argv[2]:-}" == "$executable" ||
                ( "${argv[2]:-}" == box64 && "${argv[3]:-}" == "$executable" ) ]] ;;
        *) return 1 ;;
    esac
}

identity() {
    local proc=$1 stat_line rest
    [[ -r "$proc/stat" && -r "$proc/cmdline" ]] || return 1
    IFS= read -r stat_line < "$proc/stat" || return 1
    rest=${stat_line##*) }
    read -r -a fields <<< "$rest"
    [[ ${#fields[@]} -ge 20 && "${fields[0]}" != Z ]] || return 1
    start=${fields[19]}
    [[ "$start" =~ ^[0-9]+$ ]] || return 1
    mapfile -d '' -t argv < "$proc/cmdline" || return 1
    application_argv || return 1
    uid='' gid=''
    while read -r key real effective _; do
        case "$key" in Uid:) uid="$real:$effective" ;; Gid:) gid="$real:$effective" ;; esac
    done < "$proc/status"
    [[ "$uid" == 1000:1000 && "$gid" == 1000:1000 ]]
}

case "$action" in
    match-argv)
        argv=("${@:3}")
        application_argv
        ;;
    identify)
        matches=0
        for proc in /proc/[0-9]*; do
            if identity "$proc"; then
                pid=${proc##*/}
                [[ "$pid" =~ ^[1-9][0-9]*$ ]] && (( pid > 1 ))
                printf '%s\t%s\t%s\t%s\t' "$pid" "$start" "$uid" "$gid"
                printf '%q ' "${argv[@]}"
                printf '\n'
                matches=$((matches + 1))
            fi
        done
        [[ "$matches" == 1 ]] || { printf 'Expected exactly one live application, found %s.\n' "$matches" >&2; exit 1; }
        ;;
    signal)
        pid=${3:?} expected_start=${4:?} signal=${5:?}
        [[ "$pid" =~ ^[1-9][0-9]*$ && "$expected_start" =~ ^[0-9]+$ ]] && (( pid > 1 ))
        [[ "$signal" == TERM || "$signal" == KILL ]]
        if ! identity "/proc/$pid" || [[ "$start" != "$expected_start" ]]; then
            printf 'Application identity changed; refusing signal.\n' >&2
            exit 1
        fi
        kill -s "$signal" -- "$pid"
        ;;
    *) exit 2 ;;
esac
