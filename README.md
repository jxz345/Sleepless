<!-- Language switcher. Keep this row identical across every README.<lang>.md. -->
<p align="center">
  <b>English</b> &nbsp;·&nbsp;
  <a href="README.zh-CN.md">简体中文</a> &nbsp;·&nbsp;
  <a href="README.es.md">Español</a> &nbsp;·&nbsp;
  <a href="README.ja.md">日本語</a> &nbsp;·&nbsp;
  <a href="README.fr.md">Français</a> &nbsp;·&nbsp;
  <a href="README.de.md">Deutsch</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/hero-dark.gif">
    <source media="(prefers-color-scheme: light)" srcset="assets/hero-light.gif">
    <img alt="Sleepless: keep your Mac awake with the lid closed" src="assets/hero-light.gif" width="780">
  </picture>
</p>

<p align="center">
  <b>Keep your MacBook awake with the lid closed, on battery, with no external display.</b><br>
  <sub>One menu-bar switch, with an auto-off timer and a battery-floor cutoff so you never drain it flat.</sub>
</p>

<p align="center">
  <a href="https://github.com/jxz345/Sleepless/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/jxz345/Sleepless/ci.yml?branch=main&label=CI&logo=githubactions&logoColor=white&style=flat-square&color=8B5CF6"></a>
  <a href="https://github.com/jxz345/Sleepless/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/jxz345/Sleepless?include_prereleases&sort=semver&label=release&logo=apple&logoColor=white&style=flat-square&color=8B5CF6"></a>
  <a href="https://github.com/jxz345/Sleepless/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/jxz345/Sleepless/total?label=downloads&style=flat-square&color=6366F1"></a>
  <a href="https://github.com/Aboudjem/Sleepless/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/Aboudjem/Sleepless?style=flat-square&color=6366F1"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-D946EF?style=flat-square"></a>
  <img alt="Platform: macOS 26, Apple Silicon" src="https://img.shields.io/badge/macOS%2026-Apple%20Silicon-8B5CF6?style=flat-square&logo=apple&logoColor=white">
</p>
<p align="center">
  <img alt="Build provenance: attested (SLSA)" src="https://img.shields.io/badge/build%20provenance-attested-8B5CF6?style=flat-square&logo=githubactions&logoColor=white">
  <img alt="Checksums: SHA-256" src="https://img.shields.io/badge/checksums-SHA--256-6366F1?style=flat-square">
  <img alt="Telemetry: none" src="https://img.shields.io/badge/telemetry-none-D946EF?style=flat-square">
  <a href="https://github.com/jxz345/homebrew-tap"><img alt="Install: Homebrew cask" src="https://img.shields.io/badge/homebrew-cask-8B5CF6?style=flat-square&logo=homebrew&logoColor=white"></a>
</p>

<p align="center">
  <img alt="Sleepless demo: flip the switch, set an auto-off timer, drag the battery-floor slider" src="assets/demo.gif" width="760">
</p>

> [!NOTE]
> A closed lid sleeps your Mac, and `caffeinate` apps (KeepingYouAwake and friends) can't change that, by design. Sleepless flips the one setting that can, `pmset disablesleep`, with safety nets so it is safe to forget.

> [!IMPORTANT]
> **This is a fork** of [Aboudjem/Sleepless](https://github.com/Aboudjem/Sleepless), released as `<upstream version>-jxz.<n>` (currently **1.2.7-jxz.1**) so it never collides with upstream releases. The translated READMEs describe upstream. Background, findings and design decisions: **[UPDATE_NOTES.md](UPDATE_NOTES.md)**.
>
> **What's different in this fork**
> - **Custom auto-off timer:** choose **Off · 1h · 2h · 8h · Custom**, and set any length from 1 minute to 24 hours with an hours + minutes row.
> - **Quitting or uninstalling restores normal sleep.** Upstream left `disablesleep` on when the app was quit or deleted, so the Mac would not sleep until a reboot. Now the Quit button, logout, `kill`/`killall`, and `brew uninstall` all turn it off.
> - **Steadier menu-bar icon:** it keeps the same width in every state and recovers if macOS drops it (upstream PRs [#1](https://github.com/Aboudjem/Sleepless/pull/1) and [#5](https://github.com/Aboudjem/Sleepless/pull/5)).

## Install

```sh
brew install --cask jxz345/tap/sleepless
open "/Applications/Sleepless.app"
```

The app is ad-hoc signed, not notarized. If macOS blocks it, try **System Settings → Privacy & Security → Open Anyway** and confirm **Open**. If that option is absent or ineffective, use the [launch recovery](#if-launch-hangs-or-open-anyway-does-nothing) below.

Once the cup appears in the menu bar, turn on keep-awake. If the passwordless grant is missing, the app offers one-time setup through a macOS authentication sheet. The manual fallback is:

```sh
/bin/bash "/Applications/Sleepless.app/Contents/Resources/grant.sh"
```

> [!NOTE]
> **Coming from upstream's cask?** Both casks install `/Applications/Sleepless.app` under the same name, so remove the upstream one first. Untapping it also stops `brew` asking you to fully qualify `sleepless`:
> ```sh
> brew uninstall --cask aboudjem/tap/sleepless   # also clears a stale record if you deleted the app by hand
> brew untap aboudjem/tap
> ```
> Your battery-floor setting and the passwordless grant carry over, because the fork keeps the same bundle ID and grant.

| Other ways | |
|---|---|
| **Download** | Grab the [latest release](https://github.com/jxz345/Sleepless/releases/latest) (`Sleepless-<version>-jxz.<n>.zip`), unzip to `/Applications`, and follow the same launch and recovery steps above. |
| **Build from source** | `git clone https://github.com/jxz345/Sleepless.git && cd Sleepless && ./install.sh` (requires the Command Line Tools; builds locally, installs the grant, and adds a login item). |

Then click the cup in the menu bar, flip the switch, and close the lid.

### If launch hangs or Open Anyway does nothing

On the tested macOS 27.0 machine, downloaded copies could appear in Activity Monitor without a menu-bar icon, and **Open Anyway** could be ineffective or absent. The bundled `grant.sh` could also be blocked before printing anything. Removing quarantine from the verified app resolved the launch block. See [UPDATE_NOTES.md](UPDATE_NOTES.md#8-installation-recovery-on-macos-27-2026-10-07) for the evidence and test results.

First quit Sleepless. If it is unresponsive, use Activity Monitor → Force Quit; if keep-awake was enabled, restore normal sleep first with `sudo /usr/bin/pmset -a disablesleep 0`. After verifying the download against its release checksum or attestation (see [How it works](#how-it-works)), run:

```sh
codesign --verify --deep --strict --verbose=2 "/Applications/Sleepless.app"
xattr -dr com.apple.quarantine "/Applications/Sleepless.app"
open "/Applications/Sleepless.app"
```

This explicitly removes the download-quarantine check for this app only. If `xattr` reports **Operation not permitted**, check **System Settings → Privacy & Security → App Management** for the app hosting the command: Terminal, or Visual Studio Code for its integrated terminal/agent. Allow that host to modify apps, then retry.

The same recovery applies after Homebrew installs to `/Applications/Sleepless.app`. The cask keeps normal quarantine behavior; check again if a reinstall or upgrade brings back the launch block. This recovery reuses any existing sudo grant. A Mac without the grant still needs the one-time setup above.

### Uninstall

| How you installed | Remove it with |
|---|---|
| **Any installation** | Click **Uninstall…** in the app, then confirm. Terminal opens to restore normal sleep and remove the app, login item, permission grant, and preferences. Authenticate once there; later privileged cleanup steps do not prompt again. For a Homebrew installation, it also clears the matching Homebrew receipt. |
| **Homebrew** | `brew uninstall --cask jxz345/tap/sleepless` quits the app and verifies normal sleep before removing it. It stops if sleep cannot be restored. Add `--zap` for the grant and preference cleanup. Plain uninstall preserves setup because its hooks also run during upgrades. |
| **Download / source** | `/bin/bash ./uninstall.sh` from a clone, or `/bin/bash "/Applications/Sleepless.app/Contents/Resources/uninstall.sh"`. This performs the same complete cleanup as the button. Use `--app "/path/to/Sleepless.app"` for another location. |
| **Drag to Trash** | Safe as long as the app quits first, because quitting restores normal sleep. The grant stays; remove it with `sudo rm /etc/sudoers.d/sleepless-disablesleep`. |

If Sleepless was force-killed or crashed while on, a reboot resets it, or run `sudo pmset -a disablesleep 0`.

Restoring sleep clears Sleepless's `disablesleep` override; your existing macOS power preferences continue to apply. Cancelled authentication or a failed sleep check stops the complete uninstaller before it deletes anything. Terminal displays any later cleanup failure so you can retry.

## Features

| | | |
|---|---|---|
| ☕ | **One switch** | Click the menu-bar cup, flip the toggle. |
| ⏲️ | **Auto-off timer** | 1h, 2h, 8h, or any custom length up to 24h, with a live countdown, then off. |
| 🔋 | **Battery floor** | Auto-off at 5–50% on battery (default 15%). |
| 🪫 | **Low Power Mode** | Steps aside when LPM is on, on battery. |
| 🖥️ | **No dongle** | Lid closed, on battery. No monitor, no HDMI plug. |
| 🚀 | **Launch at login** | Optional, off by default, always starts idle. |
| 🪶 | **Tiny + native** | One AppKit file. No Dock icon, daemon, or kext. |

**Menu-bar glyph:** empty cup = off · full cup = awake · full cup + dot = awake on battery (auto-off live).

## Sleepless vs the alternatives

| | **Sleepless** | Amphetamine | KeepingYouAwake | `caffeinate` |
|---|:---:|:---:|:---:|:---:|
| Awake, lid closed, no monitor | ✅ ¹ | ⚠️ ² | ❌ ³ | ❌ |
| On battery | ✅ | ✅ | ✅ lid open | ⚠️ ⁴ |
| Auto-off timer | ✅ | ✅ | ✅ | ❌ |
| Auto-off on low battery | ✅ | ✅ | ✅ | ❌ |
| Open source | ✅ MIT | ❌ App Store | ✅ MIT | Apple |
| Cost | Free | Free | Free | Free |

<sub>As of 2026-06. ¹ Uses `pmset disablesleep` and reads the flag back; behavior is hardware/macOS-version dependent. ² Documents closed-display mode but is widely reported to fail on Apple Silicon on power-source changes ([AE #28](https://github.com/x74353/Amphetamine-Enhancer/issues/28)); the app is closed source. ³ Can't do lid-closed by design, it wraps `caffeinate` ([#66](https://github.com/newmarcel/KeepingYouAwake/issues/66)). ⁴ `caffeinate -i` runs on battery; `-s` is AC-only.</sub>

## Use it to

- 🤖 Finish overnight jobs lid-closed: agent runs, builds, renders, ML training.
- 📡 Share a hotspot from your bag.
- ⬇️ Leave big downloads, uploads, or backups running.
- 🖥️ Keep a local server or SSH session reachable.

> [!TIP]
> Set a battery floor you trust (say 20%) plus a timer, and you can walk away without babysitting the battery.

## How it works

Sleepless toggles `pmset disablesleep` (the kernel's `SleepDisabled` flag), reads it back so the menu bar never lies, and reverts it at your battery floor, in Low Power Mode, when the timer ends, when you quit the app, or on reboot. A GUI app can't type a password, so the installer adds a scoped sudoers rule for **exactly two commands**:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

- **Can't be widened.** sudoers matches arguments literally, no wildcards.
- **Nothing to hijack.** No daemon, no helper script, no shell. It calls `/usr/bin/pmset` directly.
- **Always reversible.** Reboot, quitting the app, the floor, the timer, `brew uninstall`, or `./uninstall.sh` (which proves the grant is gone).

Verify a download, no Apple account needed:

```sh
shasum -a 256 -c SHA256SUMS
gh attestation verify Sleepless-*.zip -R jxz345/Sleepless
```

Full threat model, the App Store verdict, and the audit guide: [SECURITY.md](SECURITY.md) · [docs/AUDIT.md](docs/AUDIT.md).

## FAQ

<details>
<summary><b>Does <code>pmset disablesleep</code> still work on Apple Silicon (M1/M2/M3)?</b></summary>

Yes. `pmset -a disablesleep 1` sets the kernel's `SleepDisabled` flag on Apple Silicon, confirmed firsthand on macOS 26.3, which keeps the Mac awake with the lid closed on battery. Verify with `pmset -g | grep SleepDisabled` (it should read `1`). Claims that it "stopped working" usually describe `caffeinate` or caffeinate-based apps, a different mechanism.
</details>

<details>
<summary><b>Why does my Mac sleep on lid close even with Amphetamine or KeepingYouAwake?</b></summary>

Those use macOS power assertions, which stop the idle timer but can't override the hardware lid-close trigger. KeepingYouAwake wraps `caffeinate`, which can't do lid-closed ([#66](https://github.com/newmarcel/KeepingYouAwake/issues/66)). `pmset disablesleep`, which Sleepless uses, can.
</details>

<details>
<summary><b>Is it safe? Will it overheat or drain the battery?</b></summary>

It is safe for light unattended work (downloads, syncs, a hotspot). Heavy sustained load with the lid fully shut reduces airflow, so use judgement. The battery floor, Low Power Mode auto-off, and the timer all stop it before it drains the Mac.
</details>

<details>
<summary><b>Does it need sudo, a kernel extension, or a daemon?</b></summary>

One tightly scoped `sudo` grant (two exact `pmset` commands) so a GUI app can flip the setting without a prompt. No kernel extension, no daemon. The whole app is a single AppKit file.
</details>

<details>
<summary><b>How do I stop it or remove it?</b></summary>

Flip the switch off, quit the app, or let the timer or battery floor do it, and normal sleep returns. A reboot also resets it. To remove it, see [Uninstall](#uninstall).
</details>

<details>
<summary><b>Why isn't it notarized?</b></summary>

It is a personal open-source tool with no paid Apple Developer ID, so it is ad-hoc signed. Local source builds normally avoid download quarantine. For prebuilt apps, follow the [installation and launch recovery steps](#install). The notarization steps are documented in [docs/AUDIT.md](docs/AUDIT.md).
</details>

## Contributing

Issues and PRs welcome, especially translations and reports from other hardware. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Sleepless stays deliberately small.

## License

[MIT](LICENSE) © 2026 Adam Boudjemaa.

<p align="center">
  <sub>If Sleepless saved you a trip to Terminal, a ⭐ helps other people find it.</sub>
</p>
