#!/bin/bash
# Stop/reopen outside the terminal that may itself belong to Tether.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ "${1:-}" == --worker ]]; then
    action=$2
    app=$3
    echo "Started $action"
    status=0
    "${TETHER_PKILL_COMMAND:-/usr/bin/pkill}" -x Tether || status=$?
    # pkill returns 1 when no copy is running, which is a normal launch case.
    [[ "$status" -le 1 ]] || exit "$status"
    "${TETHER_SLEEP_COMMAND:-/bin/sleep}" 1
    if [[ "$action" == restart ]]; then
        "${TETHER_OPEN_COMMAND:-/usr/bin/open}" "$app"
    fi
    echo "Completed $action"
    exit 0
fi
case "${1:-}" in
    stop|restart) action=$1 ;;
    *) echo "Usage: $0 stop|restart [app-path]" >&2; exit 2 ;;
esac
app=${2:-"$repo/build/mac/Build/Products/Debug/Tether.app"}
[[ "$app" == /* ]] || app="$PWD/$app"
mkdir -p "$repo/build"
nohup /bin/bash "$repo/scripts/detached-app.sh" --worker "$action" "$app" \
    </dev/null >>"$repo/build/dev.log" 2>&1 &
echo "Scheduled $action; log: $repo/build/dev.log"
