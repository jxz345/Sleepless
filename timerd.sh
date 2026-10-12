#!/bin/bash
# sleepless-timerd: the optional background service's check, run by launchd as root at boot
# and every 60 seconds (com.aboudjem.Sleepless.timer). It only acts on an auto-off timer that
# the app handed over at logout, restart, or Quit, so a timer survives the user session:
#   - no timer file, or the Sleepless app is running (the app owns the timer): do nothing
#   - the timer ended, or the battery is at the user's floor: restore normal sleep and the
#     off-state Energy Mode (Automatic)
#   - otherwise (e.g. just rebooted, so disablesleep reset to 0): keep the Mac awake again
# It never writes to the user's home: a handled timer is recorded in a root-owned file, and
# the app removes its own timer file at the next login.
# Usage: sleepless-timerd <user>
set -u

USER_NAME=${1:-}
PMSET=/usr/bin/pmset PGREP=/usr/bin/pgrep LOGGER=/usr/bin/logger
DONE_FILE="/Library/Application Support/Sleepless/handled"
NOW=$(/bin/date +%s)
STATE=""
# Test hooks (tests/timerd_test.sh). Ignored when running as root, i.e. under launchd.
if [ "$(/usr/bin/id -u)" != 0 ]; then
    PMSET=${SLEEPLESS_PMSET:-$PMSET} PGREP=${SLEEPLESS_PGREP:-$PGREP} LOGGER=${SLEEPLESS_LOGGER:-$LOGGER}
    DONE_FILE=${SLEEPLESS_DONE:-$DONE_FILE} NOW=${SLEEPLESS_NOW:-$NOW} STATE=${SLEEPLESS_STATE:-}
fi

log() { "$LOGGER" -t sleepless-timerd "$*"; }

[ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] || { log "no user given; nothing to do"; exit 0; }
USER_ID=$(/usr/bin/id -u "$USER_NAME" 2>/dev/null) || exit 0
if [ -z "$STATE" ]; then
    HOME_DIR=$(/usr/bin/dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
    [ -n "$HOME_DIR" ] || exit 0
    STATE="$HOME_DIR/Library/Application Support/Sleepless/timer"
fi

[ -f "$STATE" ] && [ ! -L "$STATE" ] || exit 0
"$PGREP" -x Sleepless -U "$USER_ID" >/dev/null 2>&1 && exit 0

END="" FLOOR=""
while IFS='=' read -r key value; do
    case "$key" in end) END=$value ;; floor) FLOOR=$value ;; esac
done < <(/usr/bin/head -c 256 "$STATE")
[[ "$END" =~ ^[0-9]{1,12}$ && "$FLOOR" =~ ^[0-9]{1,3}$ ]] || { log "ignoring a malformed timer file"; exit 0; }
[ "$(/bin/cat "$DONE_FILE" 2>/dev/null)" != "$END" ] || exit 0

turn_off() {
    "$PMSET" -a disablesleep 0
    "$PMSET" -a powermode 0
    printf '%s\n' "$END" > "$DONE_FILE"
    log "$1; restored normal sleep"
}

BATT=$("$PMSET" -g batt)
PERCENT=$(printf '%s\n' "$BATT" | /usr/bin/grep -Eo '[0-9]+%' | /usr/bin/head -1 | /usr/bin/tr -d %)
if [ "$NOW" -ge "$END" ]; then
    turn_off "auto-off timer ended"
elif printf '%s\n' "$BATT" | /usr/bin/grep -q "Battery Power" &&
     printf '%s\n' "$BATT" | /usr/bin/grep -qi "discharging" &&
     [ -n "$PERCENT" ] && [ "$PERCENT" -le "$FLOOR" ]; then
    turn_off "battery at ${PERCENT}%"
else
    STATE_NOW=$("$PMSET" -g | /usr/bin/awk '$1 == "SleepDisabled" {print $2}')
    if [ "$STATE_NOW" != 1 ]; then
        "$PMSET" -a disablesleep 1
        "$PMSET" -a powermode 2
        log "kept awake until $(/bin/date -r "$END" '+%Y-%m-%d %H:%M')"
    fi
fi
exit 0
