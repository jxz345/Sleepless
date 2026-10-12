#!/bin/bash
# daemon.sh: install or remove Sleepless's optional background service, a root LaunchDaemon
# that carries an auto-off timer across logout and restart (see timerd.sh). Runs as root; the
# app calls it through one native macOS authentication sheet.
#   daemon.sh install [user]   copy the check to a root-owned location and load it
#                              (user defaults to SUDO_USER, e.g. under Homebrew's sudo)
#   daemon.sh remove           unload it and delete its files
# The check is copied out of the app bundle on purpose: launchd must never run root code
# from a location the user can modify.
set -euo pipefail

LABEL="com.aboudjem.Sleepless.timer"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
DIR="/Library/Application Support/Sleepless"
CHECK="$DIR/sleepless-timerd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "error: run as root." >&2; exit 1; }

case "${1:-}" in
install)
    USER_NAME="${2:-${SUDO_USER:-}}"
    if [ -z "$USER_NAME" ] || [ "$USER_NAME" = root ] || ! id -u "$USER_NAME" >/dev/null 2>&1; then
        echo "error: a valid non-root user is required." >&2; exit 1
    fi
    [[ "$USER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "error: unsupported user name." >&2; exit 1; }
    install -d -m 0755 -o root -g wheel "$DIR"
    install -m 0755 -o root -g wheel "$SCRIPT_DIR/timerd.sh" "$CHECK"
    TMP="$(mktemp)"
    cat > "$TMP" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>$LABEL</string>
    <key>ProgramArguments</key> <array><string>$CHECK</string><string>$USER_NAME</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>StartInterval</key>    <integer>60</integer>
</dict>
</plist>
PLIST
    plutil -lint "$TMP" >/dev/null
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    install -m 0644 -o root -g wheel "$TMP" "$PLIST"
    rm -f "$TMP"
    launchctl enable "system/$LABEL"
    launchctl bootstrap system "$PLIST"
    echo "Background service installed and running ($LABEL)."
    ;;
remove)
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    launchctl enable "system/$LABEL" 2>/dev/null || true   # clear a Stop's persistent override
    rm -f "$PLIST"
    rm -rf "$DIR"
    echo "Background service removed."
    ;;
*)
    echo "usage: daemon.sh install [user] | remove" >&2; exit 2 ;;
esac
