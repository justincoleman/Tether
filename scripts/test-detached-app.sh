#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
[[ -f "$repo/scripts/detached-app.sh" ]] || { echo 'FAIL: detached helper is missing' >&2; exit 1; }
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/tether detached.XXXXXX")
trap 'touch "$check_dir/release"; rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/repo with spaces/scripts" "$check_dir/fake commands"
cp "$repo/scripts/detached-app.sh" "$check_dir/repo with spaces/scripts/"
export TETHER_TEST_DIR="$check_dir"
export TETHER_PKILL_COMMAND="$check_dir/fake commands/pkill"
export TETHER_SLEEP_COMMAND="$check_dir/fake commands/sleep"
export TETHER_OPEN_COMMAND="$check_dir/fake commands/open"
cat > "$TETHER_PKILL_COMMAND" <<'FAKE'
#!/bin/bash
printf 'pkill:%s:%s\n' "$1" "$2" >> "$TETHER_TEST_DIR/events"
FAKE
cat > "$TETHER_SLEEP_COMMAND" <<'FAKE'
#!/bin/bash
printf '%s\n' "$PPID" > "$TETHER_TEST_DIR/worker-pid"
printf 'sleep:%s\n' "$1" >> "$TETHER_TEST_DIR/events"
for ((i=0; i<200; i++)); do
    [[ -e "$TETHER_TEST_DIR/release" ]] && exit 0
    /bin/sleep 0.05
done
exit 1
FAKE
cat > "$TETHER_OPEN_COMMAND" <<'FAKE'
#!/bin/bash
printf 'open:%s\n' "$1" >> "$TETHER_TEST_DIR/events"
FAKE
chmod +x "$TETHER_PKILL_COMMAND" "$TETHER_SLEEP_COMMAND" "$TETHER_OPEN_COMMAND"
helper="$check_dir/repo with spaces/scripts/detached-app.sh"
app="$check_dir/repo with spaces/build/App with spaces.app"
log="$check_dir/repo with spaces/build/dev.log"
wait_for() {
    local file=$1 text=$2
    for ((i=0; i<100; i++)); do
        [[ -f "$file" ]] && /usr/bin/grep -Fq "$text" "$file" && return 0
        /bin/sleep 0.05
    done
    echo "FAIL: timed out waiting for $text in $file" >&2
    [[ ! -f "$log" ]] || cat "$log" >&2
    return 1
}
# This parent exits while its child is held in fake sleep. The helper must
# return before release, and the worker must finish after the parent is gone.
/bin/bash -c '/bin/bash "$1" restart "$2"; touch "$3/parent-returned"' -- "$helper" "$app" "$check_dir"
[[ -e "$check_dir/parent-returned" ]]
wait_for "$check_dir/events" 'sleep:1'
# Simulate the hangup sent when a hosting terminal closes. This PID belongs
# only to the copied helper using fake commands.
kill -HUP "$(cat "$check_dir/worker-pid")"
! /usr/bin/grep -Fq 'open:' "$check_dir/events"
touch "$check_dir/release"
wait_for "$log" 'Completed restart'
printf 'pkill:-x:Tether\nsleep:1\nopen:%s\n' "$app" > "$check_dir/expected"
diff -u "$check_dir/expected" "$check_dir/events"
echo 'PASS: restart returns before stop completes; detached child survives parent exit; stop precedes open; paths with spaces preserved'
: > "$check_dir/events"
/bin/bash "$helper" stop
wait_for "$log" 'Completed stop'
printf 'pkill:-x:Tether\nsleep:1\n' > "$check_dir/expected"
diff -u "$check_dir/expected" "$check_dir/events"
echo 'PASS: detached stop never opens the app; worker output uses build/dev.log'
# Inspect Make dependencies without building or invoking real process commands.
run_log=$(make -np -f "$repo/Makefile" run-log 2>/dev/null | /usr/bin/sed -n '/^run-log:/p')
[[ "$run_log" != *' stop'* ]]
echo 'PASS: run-log has no stop prerequisite'
