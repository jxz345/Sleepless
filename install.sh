#!/usr/bin/env bash
# install.sh — build Sleepless, install it to /Applications, and add the passwordless
# grant that lets it toggle lid-close sleep. Opening at login comes with the optional
# Background service, which you turn on from the popover.
#
# This is the ONLY script that touches sudo. It tells you exactly what it will write
# before it writes it. To back everything out, run ./uninstall.sh.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Sleepless"
APP="/Applications/$APP_NAME.app"
SUDOERS_DST="/etc/sudoers.d/sleepless-disablesleep"
USER_NAME="$(id -un)"

echo "Sleepless installer"
echo "==================="
echo "This will:"
echo "  1. Build $APP_NAME.app and copy it to /Applications."
echo "  2. Install a passwordless sudo grant at $SUDOERS_DST so the app can flip"
echo "     lid-close sleep without prompting. The grant (root:wheel, 0440) is EXACTLY:"
echo ""
echo "       $(sed -n "s/^__USER__/$USER_NAME/p" "$REPO/sleepless.sudoers.template")"
echo ""
echo "     It permits only: turning lid-close sleep on or off, switching Energy Mode, and"
echo "     starting/stopping/restarting Sleepless's optional background service. Nothing else."
echo ""
read -r -p "Continue? [y/N] " reply
case "$reply" in [yY]*) ;; *) echo "Aborted."; exit 1 ;; esac

# 1. Build into /Applications.
echo "==> Building into /Applications"
DEST=/Applications "$REPO/build.sh" /Applications

# 2. Passwordless grant (delegated to grant.sh, the single source of truth).
echo "==> Installing passwordless grant (you'll be asked for your password once)"
"$REPO/grant.sh" --yes

# Launch now.
open "$APP"

echo ""
echo "✅ Installed. The coffee cup is in your menu bar — click it to toggle."
echo "   Turn ON, close the lid: your Mac stays awake on battery (auto-off at the floor you set)."
echo "   To open it at login and keep timers across logout/restart, turn on Background service"
echo "   in the popover."
echo "   To remove everything (including the grant): ./uninstall.sh"
