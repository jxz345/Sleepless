#!/bin/bash
# Exercises timerd.sh (the background service's check) with stubbed pmset/pgrep/logger.
# The test hooks are honored only when not running as root, so nothing here touches the Mac.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
[ "$(id -u)" != 0 ] || { echo "Run as a normal user." >&2; exit 1; }
FIXTURE=$(mktemp -d)
trap '/bin/rm -rf "$FIXTURE"' EXIT

cat > "$FIXTURE/pmset" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIXTURE/calls"
case "$*" in
    "-g") echo " SleepDisabled		$(cat "$FIXTURE/sleep")" ;;
    "-g batt") cat "$FIXTURE/batt" ;;
    "-a disablesleep 1") echo 1 > "$FIXTURE/sleep" ;;
    "-a disablesleep 0") echo 0 > "$FIXTURE/sleep" ;;
esac
STUB
printf '#!/bin/bash\n[ -e "$FIXTURE/app-running" ]\n' > "$FIXTURE/pgrep"
printf '#!/bin/bash\necho "$*" >> "$FIXTURE/log"\n' > "$FIXTURE/logger"
chmod +x "$FIXTURE/pmset" "$FIXTURE/pgrep" "$FIXTURE/logger"
export FIXTURE SLEEPLESS_PMSET="$FIXTURE/pmset" SLEEPLESS_PGREP="$FIXTURE/pgrep" SLEEPLESS_LOGGER="$FIXTURE/logger"
export SLEEPLESS_STATE="$FIXTURE/timer" SLEEPLESS_DONE="$FIXTURE/handled" SLEEPLESS_NOW=1000000

AC=" -InternalBattery-0	80%; charged; 0:00 remaining present: true
Now drawing from 'AC Power'"
BATT=" -InternalBattery-0	12%; discharging; 1:00 remaining present: true
Now drawing from 'Battery Power'"

# check <name> <state file or -> <SleepDisabled> <battery> <app running?> <expected calls> <expected sleep>
check() {
    local name=$1 state=$2 sleep=$3 batt=$4 app=$5 calls=$6 final=$7
    rm -f "$FIXTURE/timer" "$FIXTURE/handled" "$FIXTURE/app-running" "$FIXTURE/log"
    : > "$FIXTURE/calls"
    [ "$state" = - ] || printf '%b' "$state" > "$FIXTURE/timer"
    echo "$sleep" > "$FIXTURE/sleep"
    printf '%s\n' "$batt" > "$FIXTURE/batt"
    [ "$app" = no ] || touch "$FIXTURE/app-running"
    bash "$REPO/timerd.sh" "$(id -un)"
    local got; got=$( (grep -v '^-g' "$FIXTURE/calls" || true) | paste -sd ';' -)
    [ "$got" = "$calls" ] || { echo "FAIL: $name: calls '$got', expected '$calls'"; exit 1; }
    [ "$(cat "$FIXTURE/sleep")" = "$final" ] || { echo "FAIL: $name: SleepDisabled $(cat "$FIXTURE/sleep")"; exit 1; }
    [ -e "$FIXTURE/timer" ] || [ "$state" = - ] || { echo "FAIL: $name: the user's timer file was deleted"; exit 1; }
    echo "PASS: $name"
}
OFF="-a disablesleep 0;-a powermode 0"
check "no timer file: nothing" - 0 "$AC" no "" 0
check "app running: the app owns the timer" 'end=2000000\nfloor=15\n' 0 "$AC" yes "" 0
check "after reboot: keep awake + High Power" 'end=2000000\nfloor=15\n' 0 "$AC" no "-a disablesleep 1;-a powermode 2" 1
check "already awake: no change" 'end=2000000\nfloor=15\n' 1 "$AC" no "" 1
check "timer ended: off + off-state Energy Mode" 'end=999999\nfloor=15\n' 1 "$AC" no "$OFF" 0
check "battery at floor: off" 'end=2000000\nfloor=15\n' 1 "$BATT" no "$OFF" 0
check "battery above floor: stays awake" 'end=2000000\nfloor=10\n' 1 "$BATT" no "" 1
check "malformed file: ignored" 'end=soon; rm -rf /\nfloor=15\n' 0 "$AC" no "" 0
for who in "" root; do
    : > "$FIXTURE/calls"; printf 'end=2000000\nfloor=15\n' > "$FIXTURE/timer"; echo 0 > "$FIXTURE/sleep"
    bash "$REPO/timerd.sh" $who
    [ -z "$(grep -v '^-g' "$FIXTURE/calls" || true)" ] && [ "$(cat "$FIXTURE/sleep")" = 0 ]
done
echo "PASS: no user or root given: nothing"

# A handled timer is not re-applied (e.g. the user turned it off; the app clears the file at login).
rm -f "$FIXTURE/handled"; : > "$FIXTURE/calls"
printf 'end=999999\nfloor=15\n' > "$FIXTURE/timer"; echo 1 > "$FIXTURE/sleep"; printf '%s\n' "$AC" > "$FIXTURE/batt"
bash "$REPO/timerd.sh" "$(id -un)"
[ "$(cat "$FIXTURE/handled")" = 999999 ]
echo 1 > "$FIXTURE/sleep"; : > "$FIXTURE/calls"
bash "$REPO/timerd.sh" "$(id -un)"
[ -z "$(grep -v '^-g' "$FIXTURE/calls" || true)" ] && [ "$(cat "$FIXTURE/sleep")" = 1 ]
echo "PASS: a handled timer is never acted on twice"

# Hooks are ignored for root: the script must reference the real tools by absolute path.
grep -q 'if \[ "$(/usr/bin/id -u)" != 0 \]; then' "$REPO/timerd.sh"
echo "PASS: test hooks are disabled under launchd (root)"
