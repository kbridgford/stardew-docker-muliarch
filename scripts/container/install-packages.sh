#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export PATH="/opt/base/bin:$PATH"
# jlesage recreates its user/group databases during init. Package postinst
# scripts need the same temporary environment used by its add-pkg helper.
source /opt/base/bin/cmn-pkg
trap cleanup_env EXIT
init_env
shopt -s nullglob
for source in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$source" ]] || continue
    sed -i \
        -e 's|http://security.debian.org/debian-security|https://deb.debian.org/debian-security|g' \
        -e 's|http://deb.debian.org/|https://deb.debian.org/|g' "$source"
done
apt-get -o APT::Update::Error-Mode=any update
apt-get install -y --no-install-recommends "$@"
