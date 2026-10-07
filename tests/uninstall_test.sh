#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
source "$REPO/uninstall.sh"
FIXTURE=$(mktemp -d)
FIXTURE=$(cd -P "$FIXTURE" && pwd)
trap '/bin/rm -rf "$FIXTURE"' EXIT

# No production command is executed by this runner. Unexpected calls fail closed.
run() {
    printf '%s\n' "$*" >> "$FIXTURE/calls"
    case "$1" in
        /usr/bin/id) echo 501 ;;
        /usr/bin/pmset)
            [ "$SCENARIO" != read_failure ] || return 1
            cat "$FIXTURE/state" ;;
        /usr/bin/sudo)
            if [ "$2" = -v ]; then [ "$SCENARIO" != auth_cancel ]; return; fi
            if [ "$2" = -k ]; then return 0; fi
            [ "$SCENARIO" != reset_denied ] || return 1
            [ "$SCENARIO" = wrong_readback ] || echo 'SleepDisabled 0' > "$FIXTURE/state" ;;
        *) echo "Unexpected command: $*" >&2; return 97 ;;
    esac
}
validate_app() { return 0; }
find_brew_owner() { BREW=''; return 0; }
remove_setup() {
    touch "$FIXTURE/removal-started"
    [ "$SCENARIO" != removal_failure ]
}

check() {
    SCENARIO=$1
    local initial=$2 expected=$3 result=0
    rm -f "$FIXTURE/removal-started"
    : > "$FIXTURE/calls"
    printf '%s\n' "$initial" > "$FIXTURE/state"
    uninstall_main --yes > "$FIXTURE/output" 2>&1 || result=$?
    [ "$(grep -c '^/usr/bin/sudo -v$' "$FIXTURE/calls")" = 1 ]
    if [ "$expected" = success ]; then
        [ "$result" = 0 ] && [ -e "$FIXTURE/removal-started" ]
        grep -q '^Done\.' "$FIXTURE/output"
    else
        [ "$result" != 0 ]
        ! grep -q '^Done\.' "$FIXTURE/output"
        if [ "$SCENARIO" != removal_failure ]; then [ ! -e "$FIXTURE/removal-started" ]; fi
    fi
    echo "PASS: $SCENARIO"
}
check already_off 'SleepDisabled 0' success
check turn_off 'SleepDisabled 1' success
check read_failure 'SleepDisabled 1' failure
check missing_state 'Currently in use:' failure
check reset_denied 'SleepDisabled 1' failure
check wrong_readback 'SleepDisabled 1' failure
check auth_cancel 'SleepDisabled 1' failure
check removal_failure 'SleepDisabled 0' failure

# Validate a real fixture including a quoted path; commands are still stubbed.
source "$REPO/uninstall.sh"
APP="$FIXTURE/A user's copy/Sleepless.app"
BUNDLE_ID=com.aboudjem.Sleepless
mkdir -p "$APP/Contents/MacOS"
touch "$APP/Contents/MacOS/Sleepless"
chmod +x "$APP/Contents/MacOS/Sleepless"
run() { [ "$1" = /usr/libexec/PlistBuddy ] && echo "$FIXTURE_ID"; }
FIXTURE_ID=$BUNDLE_ID
validate_app
FIXTURE_ID=other.app
if validate_app 2>/dev/null; then exit 1; fi
FIXTURE_ID=$BUNDLE_ID
ln -s "$APP" "$FIXTURE/linked.app"
APP="$FIXTURE/linked.app"
if validate_app 2>/dev/null; then exit 1; fi
echo 'PASS: quoted bundle path, wrong identity, symlink rejection'

# Ownership must match the app link, and malformed receipt links must fail closed.
source "$REPO/uninstall.sh"
APP="$FIXTURE/installed/Sleepless.app"
mkdir -p "$APP" "$FIXTURE/caskroom/sleepless/1.2.7-jxz.1" "$FIXTURE/caskroom/sleepless/.metadata"
touch "$FIXTURE/caskroom/sleepless/.metadata/INSTALL_RECEIPT.json"
ln -s "$APP" "$FIXTURE/caskroom/sleepless/1.2.7-jxz.1/Sleepless.app"
run() {
    if [ "${2:-}" = --caskroom ]; then echo "$FIXTURE/caskroom"; return; fi
    case "${3:-}" in
        source.version) echo '1.2.7-jxz.1' ;;
        source.tap) echo 'jxz345/tap' ;;
        explicit.appdir) return 1 ;;
        default.appdir) echo "$FIXTURE/installed" ;;
        *) return 97 ;;
    esac
}
find_brew_owner
[ "$CASK" = jxz345/tap/sleepless ]
rm "$FIXTURE/caskroom/sleepless/1.2.7-jxz.1/Sleepless.app"
if find_brew_owner 2>/dev/null; then exit 1; fi
ln -s "$FIXTURE/installed/Sleepless.app" "$FIXTURE/caskroom/sleepless/1.2.7-jxz.1/Sleepless.app"
APP="$FIXTURE/manual/Sleepless.app"
mkdir -p "$APP"
find_brew_owner
[ -z "$BREW" ]
echo 'PASS: matching receipt, damaged receipt, separately installed copy'

# Exercise full cleanup without privileges; only fixture paths may be deleted.
source "$REPO/uninstall.sh"
USER_ID=501
BUNDLE_ID=com.aboudjem.Sleepless
SUDOERS_DST="$FIXTURE/grant"
LAUNCH_AGENT="$FIXTURE/login.plist"
PREFERENCES="$FIXTURE/preferences.plist"
BREW=/opt/homebrew/bin/brew
CASK=jxz345/tap/sleepless
CASKROOM="$FIXTURE/caskroom"
touch "$SUDOERS_DST" "$LAUNCH_AGENT" "$PREFERENCES"
run() {
    case "$1" in
        /usr/bin/pmset) echo 'SleepDisabled 0' ;;
        /usr/bin/pgrep|/bin/launchctl|/usr/bin/defaults) return 1 ;;
        "$APP/Contents/MacOS/Sleepless") [ "$2" = --unregister-login-item ] ;;
        "$BREW")
            [ "$*" = "$BREW uninstall --cask $CASK" ] || return 97
            /bin/rm -rf "$APP" "$CASKROOM/sleepless" ;;
        /usr/bin/sudo)
            [ "$2" = -n ] || return 97
            case "$3" in
                /bin/rm) [ "$5" = "$SUDOERS_DST" ] && /bin/rm -f "$SUDOERS_DST" ;;
                /usr/sbin/visudo) return 0 ;;
                *) return 97 ;;
            esac ;;
        /bin/rm)
            case "$3" in "$FIXTURE"/*) /bin/rm "$2" "$3" ;; *) return 97 ;; esac ;;
        *) echo "Unexpected cleanup command: $*" >&2; return 97 ;;
    esac
}
remove_setup
[ ! -e "$APP" ] && [ ! -e "$SUDOERS_DST" ] && [ ! -e "$PREFERENCES" ] && [ ! -e "$LAUNCH_AGENT" ]
echo 'PASS: complete cleanup uses plain brew uninstall and noninteractive sudo only'
