#!/usr/bin/env bash
set -euo pipefail
printf 'acquisition\n' >> "${MOCK_STEAM_CALLS:?}"
[[ "${MOCK_STEAM_FAIL:-0}" == 0 ]] || exit 42
destination=
while (( $# )); do
    if [[ "$1" == +force_install_dir ]]; then destination=$2; shift 2; else shift; fi
done
[[ -n "$destination" ]]
cp -a "${MOCK_STEAM_FIXTURE:?}/game/." "$destination/"
