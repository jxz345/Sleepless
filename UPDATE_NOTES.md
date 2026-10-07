# Update notes: jxz345 fork of Sleepless

A reference for future work on this fork: what changed compared with upstream
[Aboudjem/Sleepless](https://github.com/Aboudjem/Sleepless), what we found while testing, and why
each decision was made. The user-facing summary is in [README.md](README.md) and
[CHANGELOG.md](CHANGELOG.md).

- **Fork base:** upstream `v1.2.7` (commit `2a690e5`)
- **First fork release:** `1.2.7-jxz.1` (October 2026)

---

## 1. Upstream pull requests: what was taken and why

When the work started, upstream had four PRs:

| PR | State | What it does | Decision |
|---|---|---|---|
| [#1](https://github.com/Aboudjem/Sleepless/pull/1) | open | Draws every icon state on one shared canvas; square status-item slot | **Taken** (merged with #5) |
| [#5](https://github.com/Aboudjem/Sleepless/pull/5) | open | #1, plus `autosaveName`, recreating the item if its button goes nil, and an `animator()` pulse instead of a CALayer animation (icon vanishing on macOS 26) | **Taken**, with one change (below) |
| [#6](https://github.com/Aboudjem/Sleepless/pull/6) | closed | Adds 15m and 30m presets | **Skipped**: the custom duration covers it |
| [#7](https://github.com/Aboudjem/Sleepless/pull/7) | closed, +1172 lines | Root helper `powerctl.sh` that snapshots and restores pmset timers, plus `caffeinate`, with a wider sudoers grant | **Skipped**: gives the privileged code much more power and is a large change; revisit only if `disablesleep` alone turns out to be unreliable |

**The change to #5:** #5 sets `statusItem.isVisible = true` on every 60-second poll. On macOS 26 a user
can hide a menu-bar extra in System Settings → Menu Bar, and forcing visibility once a minute
would undo that. The fork sets `isVisible` only when the item is created, and recreates the item
only when its `button` is nil (`ensureStatusItemExists()` in `App.swift`).

---

## 2. Custom auto-off duration

**Request:** enter any timer length instead of only 1h or 2h.

**Design (in `App.swift`)**
- The segments are `Off | 1h | 2h | Custom`. Custom shows an inline row: hours field + stepper, minutes field + stepper.
- The row is hidden otherwise. `layoutTimerCard(showCustom:)` grows the timer card by
  `customRowHeight` (30 pt), moves the cards below it down, and resizes the popover. Every view
  has an absolute frame in a flipped root view, so this is just a vertical shift. A
  `customRowShown` guard stops it from shifting twice.
- **Changes apply right away** (stepper click, or Enter, Tab or click-away in a field; the field uses `sendsActionOnEndEditing`). There's no Set button. If keep-awake is on, the countdown restarts with the new length.
- Every input is reduced to **one total in minutes**, clamped to 1…1440 (24 h), then split back
  into hours and minutes. That gives three useful properties:
  - The minutes stepper runs from -5 to 60, with those two values as markers, so stepping past either end carries into the hours (0h 55 + 5 → 1h 00; 1h 00 − 5 → 0h 55).
  - Typing 90 in the minutes field gives 1h 30.
  - Text that isn't a number, and negative numbers, revert to the previous value.
- The last custom **length** is stored in `UserDefaults` (`customAutoOffMinutes`). The timer
  itself is never stored or re-armed: on launch the segment is always Off, which keeps upstream's
  "nothing survives a quit or reboot" rule.

---

## 3. Findings from live testing (and the fixes)

The app was tested with the real `pmset` grant, driving the popover through the macOS
Accessibility API (see section 7).

| # | Finding | Fix |
|---|---|---|
| F1 | With the 4th segment ("Custom"), the segmented control covered the "Auto-off timer" label, which showed as "Auto-off tim" | The label now has its own row; the segments are full width with `.fillEqually` (the same approach as upstream PR #6) |
| F2 | Typing `-5` in minutes was read as "subtract 5" (1h 00 → 0h 55) | Negative input is now rejected and reverts |
| F3 | **After the app was deleted, `SleepDisabled` stayed `1` and the sudoers grant stayed installed**, so the Mac never slept with the lid closed and no app was running to undo it | See section 4 |
| F4 | Homebrew still listed upstream's `sleepless` 1.2.7 as installed after the app was deleted by hand. Because both casks use the token `sleepless`, `brew install` of the fork tried to "upgrade" the missing app and failed | Documented: `brew uninstall --cask aboudjem/tap/sleepless` clears the stale record; `brew untap aboudjem/tap` removes the name clash (README → Install) |
| F5 | On macOS 27, a quarantined download could stall before app startup, with no menu-bar icon and ineffective or absent **Open Anyway**; `grant.sh` could be blocked before printing anything | Removing quarantine from the verified app restored launch. App Management permission was needed for the terminal host to make that change. See section 8. |

**Test matrix: all passed** (macOS 26, Apple Silicon, on AC power)
- **Steppers:** +5 / −5 minutes, hours ±1, carry into and borrow from hours, hours floor at 0, both limits hold at 24h.
- **Typing:** Enter and Tab commit; 30h → 24h; 0h 0m → 1 min; letters and negatives revert; 90 min → 1h 30.
- **Segments:** Custom shows the row (popover 486 → 516 pt); Off, 1h and 2h hide it; repeated switching doesn't shift twice; 1h and 2h count down from 1:00:00 and 2:00:00.
- **While keep-awake is off:** editing the length saves it and starts no countdown; turning keep-awake on starts the countdown at the custom length.
- **Expiry:** 1-minute timer set at 11:39:52 turned keep-awake off at 11:40:51. Switch, segment, row and popover size all reset.
- **Relaunch:** starts off with the segment on Off; the custom length is remembered.
- **Icon:** the slot stays 24×24 at the same x in off and on states; neighbouring icons don't move.
- **External change:** turning `pmset` on from outside the app shows as on when the popover opens.
- **Restoring sleep on quit:** an AppleEvent quit, `killall` (SIGTERM), and Homebrew uninstall with the app running and with it not running all left `SleepDisabled` at 0. Quitting while already off is a no-op.

**Not tested**
- Battery-only behaviour: the battery floor, Low Power Mode auto-off and the "armed" icon with the dot. The Mac was on AC power. The armed icon uses the same drawing code as the other two icons, which were checked.
- The first-run grant setup (the grant was already installed).
- Clicking outside the popover to close it (code unchanged).
- The Quit **button** itself: the screen locked during that run. It calls the same `NSApp.terminate` as the AppleEvent quit that was tested.

---

## 4. Restoring sleep when the app is removed (F3)

**Root cause**
- Upstream's `quit()` only calls `NSApp.terminate`; nothing reset `disablesleep`.
- Upstream's cask `uninstall` stanza only quits the app.
- `disablesleep` is a kernel flag, so it outlives the process.

Quitting or deleting the app while it was on therefore left the Mac unable to sleep until a reboot.

**Why the fix isn't a "delete hook":** a `.app` dragged to the Trash can't run code, and macOS
has no uninstall callback. The only alternative would be a background daemon watching the app's
path, which goes against the project's "no daemon" principle. Instead, the fix goes at the steps
that always happen **before** a removal.

1. **Quit resets.** `applicationWillTerminate` calls `setDisableSleep(false)` if
   `readSleepDisabled()` is on. This is synchronous and uses the existing `sudo -n` call with the
   exact granted arguments, so it never prompts. It covers the Quit button, logout and shutdown,
   AppleEvent quit (what `brew uninstall` and Finder send), and Activity Monitor → Quit.
2. **Signals reset.** SIGTERM, SIGINT and SIGHUP normally end an AppKit app without calling
   `applicationWillTerminate`. `installTerminationSignalHandlers()` ignores their default action
   and sends them through a `DispatchSource` to `NSApp.terminate`, so `kill` and `killall` reset too.
   SIGKILL and crashes can't be caught; a reboot still resets the flag.
3. **The Homebrew cask resets** (`Casks/sleepless.rb` in [jxz345/homebrew-tap](https://github.com/jxz345/homebrew-tap)):
   - `uninstall quit:` (triggers 1), then a `script:` backstop for a stale state with the app
     not running: `/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0`, `must_succeed: false`.
   - **Why not `script: { …, sudo: true }`:** Homebrew runs that as `sudo -E <env> -- cmd`
     (`Library/Homebrew/system_command.rb`, `sudo_prefix`). The NOPASSWD rule has no `SETENV`
     tag, so that form needs a password. Calling `sudo -n` directly matches the grant exactly,
     and fails silently if the grant is already gone.
   - **Why the grant is removed only by `zap`:** every `uninstall` directive except `signal` also
     runs on `brew upgrade` (`cask/artifact/uninstall.rb`). Removing the grant there would force a
     re-grant after every upgrade. `zap delete:` runs `rm` with sudo, which asks for a password —
     fine for an explicit `--zap`.

Tested: see the matrix above. The grant was confirmed to survive a plain `brew uninstall`.

---

## 5. Versioning and naming

- **Scheme:** `<upstream base>-jxz.<n>`, e.g. `1.2.7-jxz.1`.
  - It never collides with a future upstream version: upstream's own `1.3.0` stays distinct from this fork's work.
  - It records which upstream release the fork is built on.
  - The next fork release on the same base is `-jxz.2`. After merging upstream 1.3.0 it becomes `1.3.0-jxz.1`.
- `Info.plist` `CFBundleShortVersionString` and `CFBundleVersion` both hold the full string.
  That's fine for an ad-hoc-signed app outside the App Store (no Sparkle, no App Store checks).
- **Unchanged on purpose:**
  - the bundle ID `com.aboudjem.Sleepless`
  - the sudoers file name
  - the cask token `sleepless`.

  The fork is a drop-in replacement: preferences, the login item and the grant carry over. The
  downside is that it can't be installed alongside upstream (same `/Applications/Sleepless.app`),
  which the README and the cask caveats say.
- Release asset: `Sleepless-<version>.zip` plus `SHA256SUMS`. The tag is `v<version>`.

---

## 6. Releasing the fork

The existing `.github/workflows/release.yml` works unchanged on the fork:
- it triggers on `v*`
- it uses `github.repository` for the attestation
- it pulls the release notes from the matching `## [<version>]` CHANGELOG heading. The awk
  pattern was checked against `1.2.7-jxz.1`.

1. Update `Info.plist` (both keys) and add a `## [<version>] - <date>` entry to `CHANGELOG.md`.
2. Merge to `main` and push. CI (`ci.yml`) builds as a smoke test.
3. `git tag v<version> && git push origin v<version>`. The Release workflow builds on
   `macos-latest`, then zips, checksums, attests (SLSA, Sigstore) and publishes.
4. Update the tap:
   - Take the `sha256` from the release's `SHA256SUMS`.
   - Set `version` and `sha256` in `Casks/sleepless.rb` in `jxz345/homebrew-tap`, then commit and push.

   The cask lives **only** in the tap repo. Its `sha256` can only be known after CI has built the
   zip from a tagged commit, so a copy in this repo would always carry a placeholder (or need a
   follow-up commit) and could never be correct in the commit it describes.

   The tap was forked from `Aboudjem/homebrew-tap`, so it uses upstream's layout. Users install with `brew install --cask jxz345/tap/sleepless`.
5. Check:
   - `brew audit --cask --strict jxz345/tap/sleepless`
   - a fresh `brew install --cask jxz345/tap/sleepless`
   - `gh attestation verify Sleepless-<version>.zip -R jxz345/Sleepless`.

**Testing a cask locally before publishing.** Put the cask in a throwaway git repo with
`url "file:///…/Sleepless-<version>.zip"`, then `brew tap <name>/test <path>`, then
`brew install --cask <name>/test/sleepless`, then `brew untap` it afterwards.

**Syncing upstream**
```sh
git fetch upstream
git merge upstream/main          # resolve conflicts; App.swift is the hot spot
# set the version to <new upstream base>-jxz.1, add a CHANGELOG entry, release as above
```
Watch for upstream changes to: `makeCupGlyph` and the status-item setup (section 1), the
timer card layout in `makeContentController` (section 2), and `quit`/termination (section 4).

---

## 7. Re-running the UI tests (Accessibility scripting)

The popover is an `NSPopover` and can be reached through System Events as
`pop over 1 of menu bar item 1 of menu bar 1 of process "Sleepless"`. The terminal running the
script needs Accessibility permission, and **the screen must be unlocked**: with the screen
locked, clicks are ignored and `screencapture` fails with "could not create image from rect".

```sh
P='pop over 1 of menu bar item 1 of menu bar 1'
ax() { osascript -e "tell application \"System Events\" to tell process \"Sleepless\" to $1"; }
ax "click menu bar item 1 of menu bar 1"                       # open the popover
ax "click radio button 4 of radio group 1 of $P"               # Custom
ax "perform action \"AXIncrement\" of incrementor 2 of $P"     # minutes +5
ax "get value of text field 1 of $P"                           # hours
ax "get value of every static text of $P"                      # includes "Auto-off in h:mm:ss"
ax "click button 1 of $P"                                      # keep-awake switch
ax "click button 3 of $P"                                      # Quit
pmset -g | grep SleepDisabled                                  # ground truth
```
Hidden controls (the custom row when it isn't selected) drop out of the AX tree, so their
indexes change. Read static texts by content, not by index.

---

## 8. Installation recovery on macOS 27 (2026-10-07)

**Environment:** Apple Silicon, macOS 27.0 (build `26A428`), Sleepless `1.2.7-jxz.1`.
The passwordless grant and user preferences already existed. `install.sh` remained paused;
the recovery used the installed app and its existing grant.

### Symptoms and evidence

Rebooting, uninstalling/reinstalling with Homebrew, and attempting **Open Anyway** did not
produce a working menu-bar app. A direct invocation of the bundled `grant.sh` produced no
output. The original installed bundle passed strict code-signature verification and its
files matched the cached release ZIP, whose SHA-256 matched the cask.

A sample of the original stalled process showed only `_dyld_start`, before application code
could create the UI. System logs explicitly recorded security-policy blocks for both the
app executable and `grant.sh`.

Two additional tests used a local build with the release workflow's compiler target and
packaging method. Manually added quarantine reproduced the launch block. Repackaging the
same executable without that synthetic metadata and downloading it through Safari also
reproduced it; the installed copy had genuine Safari quarantine metadata. LaunchServices
logged `launchInQuarantine == true` and that it was not starting the application, while
`syspolicyd` logged `waiting on another evaluation`. The reason a usable approval prompt
did not appear was not established.

### The recovery that worked

1. Verify the app against the expected ZIP and checksum, and check its signature with
   `codesign --verify --deep --strict --verbose=2 "/Applications/Sleepless.app"`.
   Code-signature integrity alone does not establish the publisher's identity; this app
   remains ad-hoc signed.
2. Quit the stalled Sleepless process. Normal sleep was confirmed first with `pmset -g`
   showing `SleepDisabled 0`; force termination was used only when normal termination did
   not clear the stalled process. If keep-awake is enabled, restore normal sleep before a
   force quit with `sudo /usr/bin/pmset -a disablesleep 0`.
3. Remove only the quarantine attribute from the verified app, check its signature again,
   and launch it:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Sleepless.app"
   codesign --verify --deep --strict --verbose=2 "/Applications/Sleepless.app"
   open "/Applications/Sleepless.app"
   ```

The first attribute-removal attempt failed with **Operation not permitted**, even outside
the agent's filesystem sandbox. The macOS logs identified a separate permission issue:
TCC denied `kTCCServiceSystemPolicyAppBundles` to **Visual Studio Code**, the host of the
agent session. Enabling Visual Studio Code in **System Settings → Privacy & Security →
App Management** allowed the same command to succeed. For a separate Terminal window,
check the permission for Terminal instead. This permission concerns modifying another
app's bundle; it is separate from Sleepless's scoped `pmset` sudo grant.

After removal, quarantine was absent throughout the bundle, the code signature was still
valid, and the menu-bar item and popover worked. No application source, sudoers rule, or
system-wide Gatekeeper setting was changed for this recovery. The temporary Safari test
download server was stopped afterward.

### Recovery validation before republication

- The existing grant worked with cached authentication ignored:
  `sudo -k -n /usr/bin/pmset -a disablesleep 0` succeeded.
- Switching keep-awake on through the UI produced `SleepDisabled 1`; switching off produced `0`.
- Quitting through an AppleEvent while keep-awake was on restored `SleepDisabled 0`.
- Relaunch produced a responsive menu-bar item and popover with keep-awake off.
- The app was left running with normal sleep enabled. First-run grant installation and
  clean-machine Gatekeeper behavior were not part of this recovery test.

### Applying the recovery to Homebrew

The fork's cask installs the app at the same path, so the app-only recovery can be used
after a normal install when the same launch block occurs:

```sh
brew install --cask jxz345/tap/sleepless
```

Follow the verification, quit, quarantine-removal, and relaunch steps above. The cask does
not remove quarantine automatically. Check again if reinstalling or upgrading brings back
the block. Homebrew deprecated `--no-quarantine`; the documented recovery uses the explicit
app-scoped command instead ([Homebrew 5.0 announcement](https://brew.sh/2025/11/12/homebrew-5.0.0/)).

The existing grant was reused in our recovery. If it is missing, launch the app and enable
keep-awake to use its native one-time authorization flow. The manual fallback is:

```sh
/bin/bash "/Applications/Sleepless.app/Contents/Resources/grant.sh"
```

This replacement publication keeps the `v1.2.7-jxz.1` tag name and version while replacing
the release assets and their checksum. An end-to-end Homebrew retest must force-fetch the
replacement ZIP after updating the tap, so it cannot accidentally reuse the old download:

```sh
brew fetch --force --cask jxz345/tap/sleepless
```

For a fresh app installation on this same Mac, quit Sleepless, uninstall with
`brew uninstall --cask jxz345/tap/sleepless` (without `--zap`), then fetch and install the
replacement. Preserve the existing preferences and grant, verify the downloaded checksum,
and distinguish the normal first-launch result from any subsequent manual recovery.
