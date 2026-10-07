#!/bin/bash
# Full removal from Terminal or the app's Uninstall button. Never run brew as root.
# Usage: /bin/bash uninstall.sh [--app /path/to/Sleepless.app] [--yes]
# Functions are sourceable so failure paths can be tested without changing this Mac.

run() { "$@"; }
fail() { echo "Uninstall stopped: $*" >&2; return 1; }

sleep_state() {
    local output state
    output=$(run /usr/bin/pmset -g) || return 1
    state=$(printf '%s\n' "$output" | /usr/bin/awk '$1 == "SleepDisabled" {print $2}')
    case "$state" in 0|1) printf '%s\n' "$state" ;; *) return 1 ;; esac
}

restore_sleep() {
    local state
    state=$(sleep_state) || { fail "Could not read the sleep setting; nothing will be removed."; return 1; }
    if [ "$state" != 0 ]; then
        run /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 || {
                fail "Could not restore normal sleep; nothing will be removed."; return 1;
            }
    fi
    [ "$(sleep_state)" = 0 ] || { fail "Normal sleep could not be verified; nothing will be removed."; return 1; }
    echo "Normal sleep verified (SleepDisabled 0)."
}

validate_app() {
    [ -d "$APP" ] && [ ! -L "$APP" ] && [[ "$APP" == /*.app ]] || {
        fail "Expected an existing app bundle, not a symlink: $APP"; return 1;
    }
    APP="$(cd -P "$APP" && pwd)" || return 1
    [ "$(run /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "$BUNDLE_ID" ] || {
        fail "This bundle is not Sleepless."; return 1;
    }
    [ -x "$APP/Contents/MacOS/Sleepless" ] || { fail "The Sleepless executable is missing."; return 1; }
}

find_brew_owner() {
    BREW=""; CASK=""; CASKROOM=""
    local candidate room receipt version tap link target appdir
    for candidate in "$(command -v brew || true)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue
        room=$(run "$candidate" --caskroom) || { fail "Could not inspect Homebrew."; return 1; }
        [ "$room" != "$CASKROOM" ] || continue
        receipt="$room/sleepless/.metadata/INSTALL_RECEIPT.json"
        [ -f "$receipt" ] || continue
        version=$(run /usr/bin/plutil -extract source.version raw -o - "$receipt") || return 1
        tap=$(run /usr/bin/plutil -extract source.tap raw -o - "$receipt") || return 1
        [[ "$version" != */* && "$version" != .* && "$tap" =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$ ]] || {
            fail "Invalid Homebrew receipt; refusing to guess ownership."; return 1;
        }
        link="$room/sleepless/$version/Sleepless.app"
        if [ -L "$link" ] && [ -d "$link" ]; then
            target=$(cd -P "$link" && pwd) || return 1
        else
            appdir=$(run /usr/bin/plutil -extract explicit.appdir raw -o - "$room/sleepless/.metadata/config.json" 2>/dev/null) ||
                appdir=$(run /usr/bin/plutil -extract default.appdir raw -o - "$room/sleepless/.metadata/config.json") || return 1
            target="$appdir/Sleepless.app"
            if [ "$target" = "$APP" ]; then
                fail "Homebrew's app link is missing or invalid. Repair the installation before uninstalling."; return 1
            fi
        fi
        [ "$target" = "$APP" ] || continue
        [ -z "$BREW" ] || { fail "More than one Homebrew installation owns this app."; return 1; }
        BREW="$candidate"; CASK="$tap/sleepless"; CASKROOM="$room"
    done
}

stop_app() {
    local pid command attempt
    for pid in $(run /usr/bin/pgrep -x Sleepless || true); do
        command=$(run /bin/ps -p "$pid" -o comm=) || continue
        [ "$command" = "$APP/Contents/MacOS/Sleepless" ] || continue
        run /bin/kill -TERM "$pid" || return 1
        for attempt in {1..30}; do
            run /bin/kill -0 "$pid" 2>/dev/null || break
            /bin/sleep 0.1
        done
        if run /bin/kill -0 "$pid" 2>/dev/null; then
            fail "Sleepless did not quit. Quit it and retry; the app and grant have been kept."; return 1
        fi
    done
}

remove_setup() {
    echo "==> Disabling Launch at login"
    run "$APP/Contents/MacOS/Sleepless" --unregister-login-item || return 1
    if run /bin/launchctl print "gui/$USER_ID/$BUNDLE_ID" >/dev/null 2>&1; then
        run /bin/launchctl bootout "gui/$USER_ID/$BUNDLE_ID" || return 1
    fi
    stop_app || return 1
    restore_sleep || return 1
    run /bin/rm -f "$LAUNCH_AGENT" || return 1
    if [ -n "$BREW" ]; then
        echo "==> Removing the Homebrew installation ($CASK)"
        # Remove the app/receipt through brew. Do the explicit full cleanup below so
        # brew's separate --zap authorization does not ask for a second password.
        run "$BREW" uninstall --cask "$CASK" || return 1
        [ ! -e "$CASKROOM/sleepless/.metadata/INSTALL_RECEIPT.json" ] || {
            fail "Homebrew still records Sleepless as installed."; return 1;
        }
    else
        echo "==> Removing $APP"
        run /bin/rm -rf "$APP" || { fail "Could not remove the app. Check Terminal's App Management permission."; return 1; }
    fi
    # Clear cached defaults after the app exits, as well as the on-disk preference file.
    run /usr/bin/sudo -n /bin/rm -f "$SUDOERS_DST" || return 1
    if run /usr/bin/defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
        run /usr/bin/defaults delete "$BUNDLE_ID" || return 1
    fi
    run /bin/rm -f "$PREFERENCES" || return 1
    run /usr/bin/sudo -n /usr/sbin/visudo -c || return 1
    [ ! -e "$APP" ] && [ ! -e "$SUDOERS_DST" ] && [ ! -e "$LAUNCH_AGENT" ] && [ ! -e "$PREFERENCES" ] || {
        fail "Some Sleepless files remain. Review the errors above."; return 1;
    }
    [ "$(sleep_state)" = 0 ] || { fail "The final sleep setting could not be verified."; return 1; }
}

uninstall_main() {
    APP="/Applications/Sleepless.app"
    BUNDLE_ID="com.aboudjem.Sleepless"
    SUDOERS_DST="/etc/sudoers.d/sleepless-disablesleep"
    USER_ID=$(run /usr/bin/id -u) || return 1
    [ "$USER_ID" != 0 ] || { fail "Run this as your normal user, without sudo. It requests authentication when needed."; return 1; }
    LAUNCH_AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
    PREFERENCES="$HOME/Library/Preferences/$BUNDLE_ID.plist"
    local confirmed=0 reply
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --app) [ "$#" -ge 2 ] || return 1; APP="$2"; shift 2 ;;
            --yes) confirmed=1; shift ;;
            *) fail "Unknown argument: $1"; return 1 ;;
        esac
    done
    validate_app || return 1
    find_brew_owner || return 1
    echo "Sleepless complete uninstall"
    echo "Restores normal sleep and removes the app, login item, permission grant, and preferences."
    if [ "$confirmed" != 1 ]; then
        read -r -p "Continue? [y/N] " reply || return 1
        case "$reply" in y|Y|yes|YES) ;; *) echo "Cancelled. Nothing removed."; return 1 ;; esac
    fi
    # Exactly one interactive authorization. Every later sudo is noninteractive,
    # including recovery when the scoped grant is absent. brew stays unprivileged.
    run /usr/bin/sudo -v || { fail "Authentication cancelled or denied. Nothing removed."; return 1; }
    restore_sleep || return 1
    if ! remove_setup; then
        fail "Cleanup did not finish. Review the error above; normal sleep was restored before removal."
        return 1
    fi
    run /usr/bin/sudo -k
    echo "Done. Sleepless and its setup are removed. Normal sleep is enabled (SleepDisabled 0)."
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    set -uo pipefail
    # This copy survives deletion of the bundle containing the original script.
    if [ "${1:-}" = --run-staged ]; then
        shift
        uninstall_main "$@"
    else
        stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/Sleepless-uninstall.XXXXXX") || exit 1
        trap '/bin/rm -f "$stage/uninstall.sh"; /bin/rmdir "$stage"' EXIT
        /bin/cp "${BASH_SOURCE[0]}" "$stage/uninstall.sh" || exit 1
        /bin/bash "$stage/uninstall.sh" --run-staged "$@"
    fi
fi
