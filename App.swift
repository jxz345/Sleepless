// App.swift. Sleepless: a standalone menu-bar toggle that keeps the Mac running
// with the lid closed (on battery, no external display) via `pmset disablesleep`.
//
// Mechanism (verified live on this machine; disablesleep is UNDOCUMENTED in
// pmset(1) but real. It sets IORegistry "SleepDisabled" = Yes and disables
// idle + Apple-menu + lid-close clamshell sleep):
//   ON : sudo pmset -a disablesleep 1
//   OFF: sudo pmset -a disablesleep 0
//   READ (no root): pmset -g | grep -i SleepDisabled  (value 1 = ON; 0/absent = OFF)
// The OFF/ON commands run passwordless via a tightly-scoped /etc/sudoers.d drop-in.
// disablesleep is runtime-only and resets to 0 on reboot, and that reset is a
// deliberate safety feature; the app does NOT auto re-arm. Quitting the app (Quit,
// logout, SIGTERM/SIGINT/SIGHUP) also restores normal sleep when the scoped grant is
// available, except for an auto-off timer handed to the optional background service
// (Feature 4). The uninstall flows independently verify sleep before removing the app.
//
// UI: clicking the menu-bar coffee cup opens a small native popover with an NSSwitch
// toggle (the System-Settings control), a state caption, an auto-off timer, the
// battery-floor slider, the background-service card (which also covers opening at login),
// and Uninstall. Right-clicking the cup offers Quit. The menu-bar glyph also shows state at a glance.
//
// The coffee-cup metaphor is literal: an EMPTY cup means the Mac sleeps normally, a
// FULL cup means it is being kept awake (caffeinated), and a full cup with a small
// dot means it is awake on battery with the auto-off safety net live.
//
// Fail-safe features layer on top. Only the opt-in Feature 4 adds a daemon; without it,
// "reboot resets it" still holds:
//   1. Auto-off timer (three presets, default 1h / 2h / 8h, each adjustable 1–24h via right-click;
//      or custom up to 24h) with its end time — flips sleep back on when it ends. The end
//      date is saved to a small file so it can be resumed or handed to Feature 4.
//   2. Opens at login (SMAppService.mainApp) — part of Feature 4, off until the service is
//      installed. The app launches reading the TRUE system state; the only thing it ever
//      re-applies is an auto-off timer the service was carrying across a restart.
//   3. Low-Power-Mode auto-off — on battery, if Low Power Mode is on, Sleepless
//      turns itself off. Same shape as the battery floor, evaluated on the same tick.
//   4. Background service (opt-in, a root LaunchDaemon installed from the popover): at
//      logout, restart, or Quit it carries a running timer (keep-awake, battery floor, end).
//      Without a timer it does nothing. Start / Stop / Restart in the popover; Stop turns
//      everything off.
// Energy Mode follows the state: High Power while awake, Automatic when off. Set only on state
// changes, so manual changes in between stay.
//
// Build (mirrors Nexus.app): Command Line Tools `swiftc`, NO Xcode project.
//   swiftc -O -parse-as-library -target arm64-apple-macos26.0 -framework AppKit \
//          -framework ServiceManagement
//   File MUST be named App.swift and compiled -parse-as-library so the
//   @main enum + @MainActor static main() entry is Swift-6 isolation-safe.
import AppKit
import ServiceManagement

// MARK: - Tunables
private let pollInterval: TimeInterval = 60
// Battery-floor config (user-adjustable via the popover slider; persisted in UserDefaults).
private let floorKey = "batteryFloorPercent"
private let floorDefault = 15
private let floorMin = 5
private let floorMax = 50
// Custom auto-off length (minutes; the last chosen length is persisted, never an armed timer).
private let customKey = "customAutoOffMinutes"
private let customDefault = 90
private let customMin = 1
private let customMax = 24 * 60
// Auto-off presets (whole hours; right-click the timer control to change them).
private let presetKey = "autoOffPresetHours"
private let presetDefaults = [1, 2, 8]
private let presetMin = 1
private let presetMax = 24
// Optional background service (a root LaunchDaemon, installed from the popover) that carries an
// auto-off timer across logout and restart. The app hands it the timer through a small file.
private let serviceLabel = "com.aboudjem.Sleepless.timer"
private let servicePlist = "/Library/LaunchDaemons/\(serviceLabel).plist"
private let timerStateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Sleepless/timer")
// Written when the user removes the service in the popover, so `brew upgrade` (whose postflight
// installs the service) respects that choice. Deleted when the user installs it again.
private let serviceOptOutURL = timerStateURL.deletingLastPathComponent().appendingPathComponent("service-off")

// MARK: - Menu-bar coffee glyph (native SF Symbols, MONOCHROME template — state by SHAPE)
// macOS convention: a menu-bar extra is a template image (no colour) so it adapts to light/dark
// bars and inverts on highlight. State is read from the SILHOUETTE, not colour. The old
// empty-vs-filled cups looked near-identical at 16 px, so we switch the silhouette dramatically
// with steam (a hot cup = awake):
//   OFF   (sleeps normally)        = cup.and.saucer            cup resting on its saucer, NO steam (cold/asleep)
//   ON    (kept awake, on power)   = cup.and.heat.waves.fill   hot cup with rising steam (awake)
//   ARMED (kept awake, on battery) = cup.and.heat.waves.fill + a small dot (awake, safety net live)
// The no-steam → steam change reads instantly even at 16 px; the armed dot is the only extra
// mark. All template (monochrome) — SF Symbols only, no hand-drawn paths.
enum SleepGlyph {
    case off
    case on
    case armed
}

private func makeCupGlyph(_ glyph: SleepGlyph) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular).applying(.init(scale: .medium))
    let name = (glyph == .off) ? "cup.and.saucer" : "cup.and.heat.waves.fill"
    func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "Sleepless")?
            .withSymbolConfiguration(cfg)
    }
    let base = symbol(name) ?? symbol("cup.and.saucer.fill") ?? NSImage()

    let symbolSize = base.size
    guard symbolSize.width > 0, symbolSize.height > 0 else {
        base.isTemplate = true
        return base
    }
    // Render every state centred in the same canvas (the union of both cup symbols) so the
    // menu-bar slot never changes width when the icon swaps. A status item that resizes on
    // every toggle shifts its neighbours and, on macOS 26, is prone to being hidden.
    // (Upstream PRs #1 and #5.)
    let canvasSize = ["cup.and.saucer", "cup.and.heat.waves.fill"]
        .compactMap { symbol($0)?.size }
        .reduce(symbolSize) { size, candidate in
            NSSize(width: max(size.width, candidate.width), height: max(size.height, candidate.height))
        }

    let composed = NSImage(size: canvasSize)
    composed.lockFocus()
    base.draw(in: NSRect(x: (canvasSize.width - symbolSize.width) / 2,
                         y: (canvasSize.height - symbolSize.height) / 2,
                         width: symbolSize.width,
                         height: symbolSize.height))
    if glyph == .armed {
        // ARMED: full steaming cup + a small filled dot top-right (the "auto-off safety net is live"
        // mark). Drawn in template black so it tints + inverts with the menu bar exactly like the cup.
        let d = max(symbolSize.height * 0.26, 4)
        let dot = NSBezierPath(ovalIn: NSRect(x: canvasSize.width - d, y: canvasSize.height - d, width: d, height: d))
        NSColor.black.setFill()
        dot.fill()
    }
    composed.unlockFocus()
    composed.alignmentRect = NSRect(origin: .zero, size: canvasSize)
    composed.isTemplate = true
    return composed
}

// Flipped container so popover content lays out top-down with simple frames.
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

// Segmented control that reports a right-click (or Control-click) instead of selecting a segment.
private final class PresetSegmentedControl: NSSegmentedControl {
    var onSecondaryClick: (() -> Void)?
    override func rightMouseDown(with event: NSEvent) {
        if let f = onSecondaryClick { f() } else { super.rightMouseDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let f = onSecondaryClick { f() } else { super.mouseDown(with: event) }
    }
}

// Brand accent (2026 "Liquid Glass" redesign): indigo -> violet -> fuchsia. The
// violet mid-tone is the single accent the popover uses to communicate the
// privileged "awake" state, matching the app icon's gradient mid-stop. These are
// the only hard-coded colours; everything else stays on system semantic colours so
// the panel still reads as a first-party control.
private let brandAccent = NSColor(srgbRed: 139/255.0, green: 92/255.0, blue: 246/255.0, alpha: 1)   // #8B5CF6 violet
private let brandAccentSoft = NSColor(srgbRed: 167/255.0, green: 139/255.0, blue: 250/255.0, alpha: 1) // #A78BFA

// Frosted-glass popover backing: a flipped NSVisualEffectView so content still
// lays out top-down while the panel gets a translucent, blurred material that
// samples the desktop/windows behind it (system light/dark aware). On macOS 26 the
// .popover material renders as the system Liquid Glass automatically; we deliberately
// keep this native (no hand-rolled tint on the surface) so a sudo-touching panel
// stays visually first-party. Colour lives on the controls, never the surface.
private final class GlassView: NSVisualEffectView { override var isFlipped: Bool { true } }

// Inset grouping "card" (System Settings rhythm): a flipped, layer-backed container
// with a subtle, appearance-adaptive fill, a hairline border, and continuous-corner
// rounding. When `active`, the card carries a faint brand-violet wash + a violet
// hairline so the privileged "kept awake" state is unmistakable at a glance in the
// accent colour (Apple's "tint elements, not surfaces" model). Re-resolved on
// light/dark changes and on state changes via updateLayer.
private final class CardView: NSView {
    var active = false { didSet { if active != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if active {
            layer?.backgroundColor = brandAccent.withAlphaComponent(dark ? 0.18 : 0.10).cgColor
            layer?.borderColor = brandAccent.withAlphaComponent(dark ? 0.60 : 0.45).cgColor
            layer?.borderWidth = 1
        } else {
            layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.06)
                                           : NSColor.black.withAlphaComponent(0.045)).cgColor
            layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08)
                                       : NSColor.black.withAlphaComponent(0.06)).cgColor
            layer?.borderWidth = 1
        }
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let onGlyph = makeCupGlyph(.on)
    private let offGlyph = makeCupGlyph(.off)
    private let armedGlyph = makeCupGlyph(.armed)

    // Popover UI
    private let popover = NSPopover()
    private var toggleSwitch: NSSwitch!
    private var mainCard: CardView!         // group-1 card; gets the brand-violet wash when awake
    private var headerMark: NSImageView!    // header coffee mark; tints violet when awake
    private var captionLabel: NSTextField!
    private var floorValueLabel: NSTextField!
    private var floorSlider: NSSlider!
    private var autoOffControl: PresetSegmentedControl!
    private var countdownLabel: NSTextField!
    // Background-service card
    private var serviceSwitch: NSSwitch!
    private var serviceDot: NSTextField!
    private var serviceStatusLabel: NSTextField!
    private var serviceStart: NSButton!
    private var serviceStop: NSButton!
    private var serviceRestart: NSButton!
    private enum ServiceState { case notInstalled, stopped, running }
    private var serviceState = ServiceState.notInstalled
    private var sessionEnding = false        // logout / restart / shutdown in progress
    private var handOffToService = false     // Quit chosen while the service can carry the timer
    private var powerGrantPrompted = false   // the Energy Mode permission update is offered once per launch
    private var serviceOffered = false       // the background-service setup is offered once per launch
    private var clickMonitor: Any?
    private var batteryFloorPercent = floorDefault
    private var isOn = false
    private var userForcedOn = false   // user deliberately turned it on; honor over the Low Power Mode auto-off (the hard battery floor still wins)

    // Auto-off timer (in-memory; dies on quit, never survives a reboot)
    private var autoOffMinutes = 0           // 0 = none, a preset (presetHours * 60), or customMinutes
    private var customMinutes = customDefault
    private var presetHours = presetDefaults
    private var keepAwakeTimer: Timer?       // one-shot: flips sleep back on when it fires
    private var countdownTicker: Timer?      // 1 Hz label refresh, only while the popover is open
    private var timerEndDate: Date?

    // Custom-duration row (shown only while the "Custom" segment is selected)
    private var customRow: NSView!
    private var hoursField: NSTextField!
    private var minutesField: NSTextField!
    private var hoursStepper: NSStepper!
    private var minutesStepper: NSStepper!
    // Views below the timer card, shifted when the custom row shows/hides
    private var rootView: NSView!
    private var timerCard: CardView!
    private var belowTimerViews: [NSView] = []
    private var customRowShown = false
    // Preset editor (small transient popover opened by right-clicking the timer control)
    private let presetPopover = NSPopover()
    private var presetFields: [NSTextField] = []
    private var presetSteppers: [NSStepper] = []

    private let popoverWidth: CGFloat = 320
    private let popoverHeight: CGFloat = 512
    private let customRowHeight: CGFloat = 30

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        batteryFloorPercent = min(max((UserDefaults.standard.object(forKey: floorKey) as? Int) ?? floorDefault, floorMin), floorMax)
        customMinutes = min(max((UserDefaults.standard.object(forKey: customKey) as? Int) ?? customDefault, customMin), customMax)
        if let saved = UserDefaults.standard.array(forKey: presetKey) as? [Int], saved.count == presetDefaults.count {
            presetHours = saved.map { min(max($0, presetMin), presetMax) }
        }
        createStatusItem()
        popover.behavior = .applicationDefined   // app-managed dismissal (no transient close/reopen flicker)
        popover.animates = true
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)
        popover.contentViewController = makeContentController()

        let savedTimer = readTimerState()
        refreshServiceState()
        syncLoginItem()
        // A carried timer is one the user chose: honor it over the Low Power Mode auto-off in the
        // first refresh below (the battery floor still applies).
        if let saved = savedTimer, saved.end > Date() { userForcedOn = true }
        refresh()   // reflect TRUE system state on launch (never a stale assumption)
        resumeTimer(savedTimer)
        timer = Timer.scheduledTimer(timeInterval: pollInterval, target: self,
                                     selector: #selector(poll), userInfo: nil, repeats: true)
        installTerminationSignalHandlers()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(sessionWillEnd), name: NSWorkspace.willPowerOffNotification, object: nil)
        // The 60 s poll also checks; these catch an overdue timer the moment the user is back.
        ws.addObserver(self, selector: #selector(checkTimerExpiry), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(checkTimerExpiry), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(checkTimerExpiry), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func sessionWillEnd() { sessionEnding = true }

    // MARK: - Restore normal sleep on quit
    // A deleted .app can't run code, so the only reliable moment to undo disablesleep is when
    // the app quits (which Finder, `brew uninstall`, and logout all trigger first). sudo -n with
    // the exact granted argv: synchronous, never prompts. SIGKILL/crash can't be caught; a
    // reboot still resets it.
    // Exception: a running auto-off timer is handed to the background service at logout /
    // restart / shutdown, or when Quit was chosen with the service running. The service then
    // keeps the Mac awake until the timer ends.
    func applicationWillTerminate(_ notification: Notification) {
        refreshServiceState()
        let timerActive = (timerEndDate.map { $0 > Date() } ?? false) && isOn
        if timerActive, sessionEnding || handOffToService, serviceState == .running {
            writeTimerState()
            // Let the service pick the timer up now instead of within a minute. Not waited for:
            // kickstart can sit out launchd's respawn throttle, and quitting must stay instant.
            if handOffToService {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                p.arguments = ["-n", "/bin/launchctl", "kickstart", "-k", "system/\(serviceLabel)"]
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
            }
            return
        }
        removeTimerState()
        if readSleepDisabled() {
            setDisableSleep(false)
            setPowerMode(awake: false)
        }
    }

    // `kill`/`killall` (SIGTERM), Ctrl-C (SIGINT) and SIGHUP would otherwise end the process
    // without applicationWillTerminate. Route them through a normal terminate instead.
    private var signalSources: [DispatchSourceSignal] = []
    private func installTerminationSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)   // let the dispatch source, not the default action, handle it
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    // Create (or recreate) the menu-bar item: a fixed square slot with an autosave name so its
    // position is remembered. (Upstream PRs #1 and #5.)
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "Sleepless"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = offGlyph
            button.action = #selector(statusClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])   // right-click opens the Quit menu
        }
    }

    // macOS 26 can drop a status item's backing button; re-create it if so. Deliberately does NOT
    // force isVisible on every poll, which would undo the user hiding the icon in System Settings.
    private func ensureStatusItemExists() {
        guard statusItem == nil || statusItem.button == nil else { return }
        if let stale = statusItem { NSStatusBar.system.removeStatusItem(stale) }
        createStatusItem()
    }

    // MARK: - Popover content (native NSSwitch toggle, macOS-aligned)
    private func makeContentController() -> NSViewController {
        let W = popoverWidth, pad: CGFloat = 16
        let contentW = W - pad * 2
        let ci: CGFloat = 12                 // card inner padding
        let cw = contentW - ci * 2           // card inner content width

        // Standard system popover material: untinted, no forced emphasis, so it reads
        // as a first-party control (like the Wi-Fi / Sound / Battery popovers), not a
        // themed panel. NSPopover supplies its own corner, shadow, and arrow.
        let root = GlassView(frame: NSRect(x: 0, y: 0, width: W, height: popoverHeight))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState

        // Header: small coffee mark + "Sleepless" (quiet system glyph, not a branded logo).
        // The mark tints to the brand violet while the Mac is kept awake.
        let mark = NSImageView(frame: NSRect(x: pad, y: 14, width: 18, height: 18))
        let headerCup = makeCupGlyph(.on); headerCup.isTemplate = true
        mark.image = headerCup
        mark.contentTintColor = .labelColor
        root.addSubview(mark)
        headerMark = mark
        let title = makeLabel("Sleepless", font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor)
        title.frame = NSRect(x: pad + 24, y: 14, width: contentW - 24, height: 20)
        root.addSubview(title)

        // Grouped inset cards (System Settings rhythm) replace per-row hairline separators.
        func makeCard(_ rect: NSRect) -> CardView {
            let c = CardView(frame: rect)
            c.wantsLayer = true
            root.addSubview(c)
            return c
        }
        let swProto = NSSwitch().intrinsicContentSize
        let swW = swProto.width > 0 ? swProto.width : 38
        let swH = swProto.height > 0 ? swProto.height : 21

        // GROUP 1 — main switch + state caption
        let g1y: CGFloat = 46, g1h: CGFloat = 84
        let g1 = makeCard(NSRect(x: pad, y: g1y, width: contentW, height: g1h))
        mainCard = g1
        let rowLabel = makeLabel("Keep awake with lid closed", font: .systemFont(ofSize: 13), color: .labelColor)
        rowLabel.frame = NSRect(x: ci, y: ci, width: cw - swW - 8, height: 22)
        g1.addSubview(rowLabel)
        toggleSwitch = NSSwitch()
        toggleSwitch.target = self
        toggleSwitch.action = #selector(switchToggled(_:))
        toggleSwitch.frame = NSRect(x: contentW - ci - swW, y: ci + (22 - swH) / 2, width: swW, height: swH)
        g1.addSubview(toggleSwitch)
        captionLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        captionLabel.frame = NSRect(x: ci, y: ci + 30, width: cw, height: 32)
        captionLabel.usesSingleLineMode = false
        captionLabel.lineBreakMode = .byWordWrapping
        captionLabel.maximumNumberOfLines = 2
        captionLabel.cell?.wraps = true
        g1.addSubview(captionLabel)

        // GROUP 2 — auto-off timer (label + segmented [Off | preset ×3 | Custom] + optional
        // custom-duration row + countdown)
        let g2y = g1y + g1h + 12, g2h: CGFloat = 106
        let g2 = makeCard(NSRect(x: pad, y: g2y, width: contentW, height: g2h))
        timerCard = g2
        let timerLabel = makeLabel("Auto-off timer", font: .systemFont(ofSize: 13), color: .labelColor)
        timerLabel.frame = NSRect(x: ci, y: ci, width: cw, height: 22)   // label gets its own row
        g2.addSubview(timerLabel)
        autoOffControl = PresetSegmentedControl(labels: ["Off"] + presetHours.map { "\($0)h" } + ["Custom"],
                                                trackingMode: .selectOne,
                                                target: self, action: #selector(autoOffChanged(_:)))
        autoOffControl.toolTip = "Right-click to change the preset lengths."
        autoOffControl.onSecondaryClick = { [weak self] in self?.showPresetEditor() }
        autoOffControl.selectedSegment = 0
        autoOffControl.controlSize = .regular
        autoOffControl.segmentStyle = .automatic
        autoOffControl.segmentDistribution = .fillProportionally
        autoOffControl.frame = NSRect(x: ci, y: ci + 28, width: cw, height: 24)
        g2.addSubview(autoOffControl)
        // Custom duration: [ H ]⇅ h  [ MM ]⇅ m. Applies immediately; hidden unless "Custom".
        let row = FlippedView(frame: NSRect(x: ci, y: ci + 62, width: cw, height: 22))
        row.isHidden = true
        customRow = row
        func makeNumberField(x: CGFloat) -> NSTextField {
            numberField(in: row, x: x, action: #selector(customDurationChanged(_:)))
        }
        func makeStepper(x: CGFloat, min: Double, max: Double, increment: Double) -> NSStepper {
            stepper(in: row, x: x, min: min, max: max, increment: increment, action: #selector(customDurationChanged(_:)))
        }
        let unitFont = NSFont.systemFont(ofSize: 13)
        hoursField = makeNumberField(x: 0)
        hoursStepper = makeStepper(x: 42, min: 0, max: 24, increment: 1)
        let hLabel = makeLabel("h", font: unitFont, color: .secondaryLabelColor)
        hLabel.frame = NSRect(x: 60, y: 2, width: 16, height: 18)
        row.addSubview(hLabel)
        minutesField = makeNumberField(x: 82)
        // -5 / 60 are sentinels: stepping past either end carries into the hours.
        minutesStepper = makeStepper(x: 124, min: -5, max: 60, increment: 5)
        let mLabel = makeLabel("m", font: unitFont, color: .secondaryLabelColor)
        mLabel.frame = NSRect(x: 142, y: 2, width: 16, height: 18)
        row.addSubview(mLabel)
        g2.addSubview(row)
        renderCustomDuration()
        countdownLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        countdownLabel.frame = NSRect(x: ci, y: ci + 64, width: cw, height: 16)
        g2.addSubview(countdownLabel)

        // GROUP 3 — battery-floor (label + value + slider + min/max hints)
        let g3y = g2y + g2h + 12, g3h: CGFloat = 92
        let g3 = makeCard(NSRect(x: pad, y: g3y, width: contentW, height: g3h))
        let floorLabel = makeLabel("Auto-off at low battery", font: .systemFont(ofSize: 13), color: .labelColor)
        floorLabel.frame = NSRect(x: ci, y: ci, width: cw - 54, height: 18)
        g3.addSubview(floorLabel)
        floorValueLabel = makeLabel("\(batteryFloorPercent)%", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
        floorValueLabel.alignment = .right
        floorValueLabel.frame = NSRect(x: contentW - ci - 54, y: ci, width: 54, height: 18)
        g3.addSubview(floorValueLabel)
        floorSlider = NSSlider(value: Double(batteryFloorPercent), minValue: Double(floorMin), maxValue: Double(floorMax),
                               target: self, action: #selector(floorSliderChanged(_:)))
        floorSlider.isContinuous = true          // live update while dragging
        floorSlider.controlSize = .regular
        floorSlider.frame = NSRect(x: ci, y: ci + 26, width: cw, height: 20)
        g3.addSubview(floorSlider)
        let minHint = makeLabel("\(floorMin)%", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
        minHint.frame = NSRect(x: ci, y: ci + 50, width: 34, height: 13)
        g3.addSubview(minHint)
        let maxHint = makeLabel("\(floorMax)%", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
        maxHint.alignment = .right
        maxHint.frame = NSRect(x: contentW - ci - 34, y: ci + 50, width: 34, height: 13)
        g3.addSubview(maxHint)

        // GROUP 5 — optional background service: install/remove switch, status, Start/Stop/Restart
        let g5y = g3y + g3h + 12, g5h: CGFloat = 98
        let g5 = makeCard(NSRect(x: pad, y: g5y, width: contentW, height: g5h))
        let serviceLabelView = makeLabel("Background service", font: .systemFont(ofSize: 13), color: .labelColor)
        serviceLabelView.frame = NSRect(x: ci, y: ci, width: cw - swW - 8, height: 22)
        serviceLabelView.toolTip = "Opens Sleepless at login and keeps an auto-off timer running after logout and restart. Installing it needs administrator approval. While no one is logged in, the timer may end up to a minute late."
        g5.addSubview(serviceLabelView)
        serviceSwitch = NSSwitch()
        serviceSwitch.target = self
        serviceSwitch.action = #selector(serviceToggled(_:))
        serviceSwitch.toolTip = serviceLabelView.toolTip
        serviceSwitch.frame = NSRect(x: contentW - ci - swW, y: ci + (22 - swH) / 2, width: swW, height: swH)
        g5.addSubview(serviceSwitch)
        serviceDot = makeLabel("●", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
        serviceDot.frame = NSRect(x: ci, y: ci + 29, width: 12, height: 14)
        g5.addSubview(serviceDot)
        serviceStatusLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        serviceStatusLabel.frame = NSRect(x: ci + 14, y: ci + 28, width: cw - 14, height: 16)
        serviceStatusLabel.lineBreakMode = .byTruncatingTail
        g5.addSubview(serviceStatusLabel)
        func serviceButton(_ title: String, _ action: Selector, _ tip: String, x: CGFloat) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.toolTip = tip
            b.frame = NSRect(x: x, y: ci + 52, width: (cw - 12) / 3, height: 24)
            g5.addSubview(b)
            return b
        }
        let bw = (cw - 12) / 3 + 6
        serviceStart = serviceButton("Start", #selector(serviceStartClicked), "Start the background service.", x: ci)
        serviceStop = serviceButton("Stop", #selector(serviceStopClicked), "Turn off keep-awake, cancel the timer, and stop the background service (it stays stopped after a restart).", x: ci + bw)
        serviceRestart = serviceButton("Restart", #selector(serviceRestartClicked), "Restart the background service.", x: ci + bw * 2)

        // Footer — complete removal. Quit lives in the menu-bar cup's right-click menu, because
        // with the background service it no longer means "turn everything off" (that is Stop).
        let uninstall = NSButton(title: "Uninstall…", target: self, action: #selector(uninstall))
        uninstall.toolTip = "Restores normal sleep and removes Sleepless and its setup."
        uninstall.bezelStyle = .rounded
        uninstall.sizeToFit()
        let footerY = g5y + g5h + 12
        uninstall.frame.origin = NSPoint(x: pad, y: footerY)
        root.addSubview(uninstall)
        let quitHint = makeLabel("Right-click the cup to quit", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
        quitHint.alignment = .right
        quitHint.frame = NSRect(x: W / 2, y: footerY + (uninstall.frame.height - 14) / 2, width: W / 2 - pad, height: 14)
        root.addSubview(quitHint)
        rootView = root
        belowTimerViews = [g3, g5, uninstall, quitHint]

        let vc = NSViewController()
        vc.view = root
        return vc
    }

    // Number field + stepper shared by the custom-duration row and the preset editor.
    private func numberField(in parent: NSView, x: CGFloat, action: Selector) -> NSTextField {
        let f = NSTextField(frame: NSRect(x: x, y: 0, width: 40, height: 22))
        f.alignment = .right
        f.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        f.target = self
        f.action = action
        f.cell?.sendsActionOnEndEditing = true   // commit on Tab / click-away, not only Enter
        parent.addSubview(f)
        return f
    }

    private func stepper(in parent: NSView, x: CGFloat, min: Double, max: Double, increment: Double,
                         action: Selector) -> NSStepper {
        let s = NSStepper(frame: NSRect(x: x, y: 0, width: 15, height: 22))
        s.minValue = min; s.maxValue = max; s.increment = increment
        s.valueWraps = false
        s.target = self
        s.action = action
        parent.addSubview(s)
        return s
    }

    private func makeLabel(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font
        t.textColor = color
        t.isEditable = false
        t.isBordered = false
        t.drawsBackground = false
        return t
    }

    // MARK: - Click the menu-bar cup to open/close the popover
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showStatusMenu(); return }
        if popover.isShown { closePopover() } else { openPopover() }
    }

    private func showStatusMenu() {
        guard let button = statusItem.button else { return }
        if popover.isShown { closePopover() }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Quit Sleepless", action: #selector(quit), keyEquivalent: "q")
        item.target = self
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func openPopover() {
        refresh()                              // sync switch/caption to TRUE state before showing
        refreshServiceState()
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if keepAwakeTimer != nil { startCountdownTicker() }
        updateCountdownLabel()
        // Close when the user clicks anywhere outside the app (status bar, another app, desktop).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        commitPendingEdits()
        presetPopover.performClose(nil)
        popover.performClose(nil)
        countdownTicker?.invalidate(); countdownTicker = nil   // stop the 1 Hz label refresh (keep-awake timer keeps running)
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
    }

    @objc private func switchToggled(_ sender: NSSwitch) {
        commitPendingEdits()
        if performToggle(wantOn: sender.state == .on) {
            sender.state = .off   // setup needed / failed: reflect reality (performToggle notified)
        }
    }

    // Core keep-awake toggle, decoupled from the UI sender. Returns true ONLY when the user
    // must act (the passwordless grant is missing and setup did not complete) so the caller can
    // reflect OFF. The decision to prompt is made on the REAL sudo result (see setDisableSleep),
    // never by re-reading SleepDisabled: a successful sudo means the command ran, even if a
    // safety net (Low Power Mode / battery floor) legitimately turns sleep back on afterwards —
    // which must NOT be mistaken for "permission missing" and trigger a password prompt. This
    // unobservable, state-proxy decision is what made earlier releases re-prompt spuriously.
    @discardableResult
    private func performToggle(wantOn: Bool) -> Bool {
        var result = setDisableSleep(wantOn)
        // Only a genuinely MISSING grant warrants the one-time native-auth setup. A successful
        // sudo (.ok) — or any other failure — never re-prompts here.
        if wantOn, result == .grantMissing {
            if installGrantViaAuth() { result = setDisableSleep(true) }
            if result != .ok {
                notify("Couldn't keep awake. The permission isn't set up yet.")
                return true
            }
        }
        if result == .ok {
            // Energy Mode follows the state. An older grant lacks these commands: offer the
            // permission update once per launch, only from this user-initiated path.
            if setPowerMode(awake: wantOn) == .grantMissing, !powerGrantPrompted {
                powerGrantPrompted = true
                if installGrantViaAuth(upgrade: true) { setPowerMode(awake: wantOn) }
            }
            // The service isn't set up (e.g. `brew upgrade` removed it with the old version):
            // offer it once per launch, through the same native prompt.
            if wantOn, !serviceOffered, serviceWanted() {
                serviceOffered = true
                offerService()
            }
        }
        // A deliberate, successful turn-on wins over the Low Power Mode auto-off (hard floor still wins).
        userForcedOn = wantOn && result == .ok
        refresh()                              // applies UI + safety nets; switch reflects reality
        if isOn, autoOffMinutes > 0 { startKeepAwakeTimer(minutes: autoOffMinutes) }
        return false
    }

    // Install the one-time scoped grant via a SINGLE native macOS authorization (the
    // standard Touch ID / password sheet) — no Terminal. Runs the bundled, audited
    // grant.sh as root through osascript's "with administrator privileges"; grant.sh is
    // root-aware so it writes the sudoers drop-in directly with no inner sudo prompt.
    // Returns true once the passwordless grant is in place; after that the app never asks again.
    // The same single prompt also sets up the background service, unless it's installed or the
    // user opted out of it.
    @discardableResult
    private func installGrantViaAuth(upgrade: Bool = false) -> Bool {
        let withService = serviceWanted()
        let serviceNote = withService ? " It also sets up the background service, so Sleepless opens at login and an auto-off timer keeps running after logout and restart." : ""
        let intro = NSAlert()
        intro.alertStyle = .informational
        if upgrade {
            intro.messageText = "Update Sleepless's permission"
            intro.informativeText = "Sleepless now switches Energy Mode (High Power while it keeps your Mac awake, Automatic when it's off) and controls its background service. macOS will ask you to authenticate once to update the permission." + serviceNote
            intro.addButton(withTitle: "Update")
        } else {
            intro.messageText = "Enable keeping your Mac awake"
            intro.informativeText = "Sleepless flips a protected macOS setting (pmset disablesleep), so it needs your permission once. macOS will ask you to authenticate (Touch ID or your password). After that the switch works instantly, with no more prompts." + serviceNote
            intro.addButton(withTitle: "Enable")
        }
        intro.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard intro.runModal() == .alertFirstButtonReturn else { return false }
        let ok = runBundledScriptsAsAdmin(withService ? serviceInstallCommands() : [grantCommand()],
                                          failure: "Setup didn't complete. Try again, or run grant.sh from the app bundle.")
        if ok, withService { serviceInstalled() }
        return ok
    }

    // Grant refresh + service install, run together under one native authentication sheet.
    private func serviceInstallCommands() -> [String] {
        [grantCommand(), "/bin/bash \(shellQuote(resourcePath("daemon.sh"))) install \(shellQuote(NSUserName()))"]
    }

    private func serviceInstalled() {
        setServiceOptOut(false)
        refreshServiceState()
        syncLoginItem()
    }

    // Wanted unless installed or opted out (the popover's switch, or "Don't Ask Again").
    private func serviceWanted() -> Bool {
        refreshServiceState()
        return serviceState == .notInstalled && !FileManager.default.fileExists(atPath: serviceOptOutURL.path)
    }

    private func offerService() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Set up the background service?"
        alert.informativeText = "Sleepless will open at login, and an auto-off timer will keep running after you log out or restart. macOS will ask you to authenticate. You can change this later in the popover."
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if runBundledScriptsAsAdmin(serviceInstallCommands(), failure: "The background service could not be installed.") {
                serviceInstalled()
            }
        case .alertThirdButtonReturn:
            setServiceOptOut(true)
        default:
            break
        }
    }

    // Pass the REAL user: under the native auth sheet grant.sh runs as root with SUDO_USER
    // unset, so without this the grant would be written for "root" (useless).
    private func grantCommand() -> String {
        "SLEEPLESS_USER=\(shellQuote(NSUserName())) /bin/bash \(shellQuote(resourcePath("grant.sh"))) --yes"
    }

    private func resourcePath(_ name: String) -> String {
        (Bundle.main.resourcePath ?? "") + "/" + name
    }

    // Run bundled, audited scripts as root through ONE native macOS authentication sheet
    // (osascript "with administrator privileges"). Returns true when every command succeeded.
    private func runBundledScriptsAsAdmin(_ commands: [String], failure: String) -> Bool {
        let shellCmd = commands.joined(separator: " && ")
        // escape for an AppleScript string literal
        let escaped = shellCmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "do shell script \"\(escaped)\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", osa]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() }
        catch { notify("Couldn't start the administrator step."); return false }
        if proc.terminationStatus == 0 { return true }
        if proc.terminationStatus != 128 { notify(failure) }   // 128 = user cancelled the auth sheet
        return false
    }

    // MARK: - Background service (optional root LaunchDaemon; see daemon.sh / timerd.sh)
    // Status needs no root: `launchctl print` exits non-zero when the service isn't loaded.
    private func refreshServiceState() {
        if !FileManager.default.fileExists(atPath: servicePlist) {
            serviceState = .notInstalled
        } else {
            serviceState = runStatus("/bin/launchctl", ["print", "system/\(serviceLabel)"]) == 0 ? .running : .stopped
        }
        renderServiceCard()
    }

    private func renderServiceCard() {
        guard let label = serviceStatusLabel else { return }
        if serviceBusy {
            label.stringValue = "Working…"
            for b in [serviceStart, serviceStop, serviceRestart] { b?.isEnabled = false }
            serviceSwitch.isEnabled = false
            return
        }
        serviceSwitch.isEnabled = true
        let carriesTimer = isOn && (timerEndDate.map { $0 > Date() } ?? false)
        switch serviceState {
        case .notInstalled:
            label.stringValue = "Not installed · timers end at logout"
            serviceDot.textColor = .tertiaryLabelColor
        case .stopped:
            label.stringValue = "Stopped · timers end at logout"
            serviceDot.textColor = .systemOrange
        case .running:
            label.stringValue = carriesTimer
                ? "Running · keeps the timer to \(endTimeText(timerEndDate!))"
                : "Running · opens at login, keeps timers"
            serviceDot.textColor = .systemGreen
        }
        serviceSwitch.state = serviceState == .notInstalled ? .off : .on
        serviceStart.isEnabled = serviceState == .stopped
        serviceStop.isEnabled = serviceState == .running
        serviceRestart.isEnabled = serviceState == .running
    }

    // The service controls run their work on the next run-loop pass: they show alerts, block on
    // sudo, and disable themselves (Start/Stop), and doing that inside the click's own tracking
    // leaves AppKit's gesture recognizer stuck, after which the popover mishandles clicks.
    @objc private func serviceToggled(_ sender: NSSwitch) {
        perform(#selector(performServiceToggle), with: nil, afterDelay: 0)
    }

    @objc private func serviceStartClicked() { perform(#selector(performServiceStart), with: nil, afterDelay: 0) }
    @objc private func serviceStopClicked() { perform(#selector(performServiceStop), with: nil, afterDelay: 0) }
    @objc private func serviceRestartClicked() { perform(#selector(performServiceRestart), with: nil, afterDelay: 0) }

    @objc private func performServiceToggle() {
        commitPendingEdits()
        let install = serviceSwitch.state == .on
        let alert = NSAlert()
        alert.messageText = install ? "Install the background service?" : "Remove the background service?"
        alert.informativeText = install
            ? "Sleepless will open at login, and a small root service (com.aboudjem.Sleepless.timer) will keep an auto-off timer running after you log out or restart. It checks once a minute and at startup, still turns off at your battery floor, and does nothing without a timer. macOS will ask you to authenticate."
            : "Sleepless will no longer open at login, and timers will end at logout again. macOS will ask you to authenticate."
        alert.addButton(withTitle: install ? "Install" : "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            // Installing also refreshes the grant, which covers Start / Stop / Restart.
            let commands = install
                ? serviceInstallCommands()
                : ["/bin/bash \(shellQuote(resourcePath("daemon.sh"))) remove"]
            if runBundledScriptsAsAdmin(commands, failure: "The background service could not be \(install ? "installed" : "removed").") {
                setServiceOptOut(!install)
            }
        }
        refreshServiceState()
        syncLoginItem()
    }

    private func setServiceOptOut(_ optOut: Bool) {
        if optOut {
            try? FileManager.default.createDirectory(at: serviceOptOutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: serviceOptOutURL.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: serviceOptOutURL)
        }
    }

    @objc private func performServiceStart() {
        serviceCommand([["/bin/launchctl", "enable", "system/\(serviceLabel)"],
                        ["/bin/launchctl", "bootstrap", "system", servicePlist]])
    }

    // Stop turns everything off (keep-awake, timer, Energy Mode), then stops the service and
    // disables it so it stays stopped across restarts until Start.
    @objc private func performServiceStop() {
        commitPendingEdits()
        if readSleepDisabled() {
            setDisableSleep(false)
            setPowerMode(awake: false)
        }
        userForcedOn = false
        cancelKeepAwakeTimer()
        refresh()
        serviceCommand([["/bin/launchctl", "bootout", "system/\(serviceLabel)"],
                        ["/bin/launchctl", "disable", "system/\(serviceLabel)"]])
    }

    @objc private func performServiceRestart() {
        serviceCommand([["/bin/launchctl", "kickstart", "-k", "system/\(serviceLabel)"]])
    }

    // launchctl can block for up to launchd's 10 s respawn throttle (e.g. a Restart shortly after
    // the minute check), so the commands run off the main thread while the card shows "Working…".
    private var serviceBusy = false

    private func serviceCommand(_ commands: [[String]]) {
        guard !serviceBusy else { return }
        serviceBusy = true
        renderServiceCard()
        Task.detached {
            let missing = commands.map { AppDelegate.sudo($0) }.contains(.grantMissing)
            await MainActor.run { self.finishServiceCommand(commands, grantMissing: missing) }
        }
    }

    private func finishServiceCommand(_ commands: [[String]], grantMissing: Bool) {
        serviceBusy = false
        // An older grant doesn't cover these commands: update it once, then retry.
        if grantMissing, installGrantViaAuth(upgrade: true) {
            serviceCommand(commands)
            return
        }
        refreshServiceState()
    }

    private func runStatus(_ launchPath: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // A brief, subtle pulse on the menu-bar glyph whenever the state (and thus the cup
    // shape) changes, so the change is noticeable. Uses the AppKit animator proxy only: touching
    // NSStatusBarButton's CALayer is fragile on macOS 26 and has been seen to make status items
    // disappear. (Upstream PR #5.)
    private func pulseStatusItem() {
        guard let b = statusItem.button else { return }
        b.alphaValue = 0.3
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            b.animator().alphaValue = 1.0
        }
    }

    @objc private func poll() {
        refresh()
        checkTimerExpiry()
    }

    // MARK: - Auto-off timer (Feature 1)
    @objc private func autoOffChanged(_ sender: NSSegmentedControl) {
        commitPendingEdits()
        switch sender.selectedSegment {
        case 1...3: autoOffMinutes = presetHours[sender.selectedSegment - 1] * 60
        case 4: autoOffMinutes = customMinutes
        default: autoOffMinutes = 0
        }
        layoutTimerCard(showCustom: sender.selectedSegment == 4)
        if isOn, autoOffMinutes > 0 {
            startKeepAwakeTimer(minutes: autoOffMinutes)
        } else {
            cancelKeepAwakeTimer()
            updateCountdownLabel()
        }
    }

    private func startKeepAwakeTimer(minutes: Int) {
        guard minutes > 0 else { cancelKeepAwakeTimer(); updateCountdownLabel(); return }
        armTimer(until: Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    // The end date is the source of truth: the Timer is only a wake-up, and the expiry check
    // below compares against the date, so a late or missed Timer can't outlast the end time.
    private func armTimer(until end: Date) {
        cancelKeepAwakeTimer()
        guard isOn, end > Date() else { updateCountdownLabel(); return }
        timerEndDate = end
        keepAwakeTimer = Timer.scheduledTimer(timeInterval: end.timeIntervalSinceNow, target: self,
                                              selector: #selector(keepAwakeTimerFired), userInfo: nil, repeats: false)
        writeTimerState()
        if popover.isShown { startCountdownTicker() }
        updateCountdownLabel()
    }

    private func cancelKeepAwakeTimer() {
        keepAwakeTimer?.invalidate(); keepAwakeTimer = nil
        countdownTicker?.invalidate(); countdownTicker = nil
        if timerEndDate != nil { removeTimerState() }
        timerEndDate = nil
    }

    @objc private func checkTimerExpiry() {
        if isOn, let end = timerEndDate, Date() >= end { keepAwakeTimerFired() }
    }

    @objc private func keepAwakeTimerFired() {
        setDisableSleep(false)
        setPowerMode(awake: false)
        cancelKeepAwakeTimer()
        autoOffMinutes = 0
        autoOffControl?.selectedSegment = 0
        layoutTimerCard(showCustom: false)
        applyUI(on: readSleepDisabled())
        notify("Auto-off timer ended. Sleepless turned off.")
    }

    // End any in-progress text edit so its action (sendsActionOnEndEditing) commits the typed value
    // before a control reads customMinutes / presetHours. Switches and segmented controls don't take
    // first responder, so clicking them would otherwise leave the edit uncommitted.
    // Only visible windows: resigning a field editor in a closed popover's window raises an
    // AppKit exception, which would abort the calling action (e.g. the keep-awake switch).
    private func commitPendingEdits() {
        for w in [popover.contentViewController?.view.window, presetPopover.contentViewController?.view.window] {
            if let w, w.isVisible, w.firstResponder is NSTextView { w.makeFirstResponder(nil) }
        }
    }

    // The preset editor opens with its first field focused; commit that edit while the editor is
    // still on screen, so a closed editor never keeps a live field editor behind.
    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === presetPopover,
              let w = presetPopover.contentViewController?.view.window,
              w.firstResponder is NSTextView else { return }
        w.makeFirstResponder(nil)
    }

    // Custom duration edited (field commit or stepper click). Everything is reduced to a single
    // total in minutes, clamped to [customMin, customMax], then redistributed into h + m — so the
    // minutes stepper's -5 / 60 sentinels carry into the hours, and junk input reverts.
    @objc private func customDurationChanged(_ sender: Any) {
        var h = customMinutes / 60, m = customMinutes % 60
        if let s = sender as? NSStepper {
            if s === hoursStepper { h = s.integerValue } else { m = s.integerValue }
        } else if let f = sender as? NSTextField {
            let v = Int(f.stringValue.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil }
            if f === hoursField { h = v ?? h } else { m = v ?? m }
        }
        let total = min(max(h * 60 + m, customMin), customMax)
        renderCustomDuration(total)
        guard total != customMinutes else { return }
        customMinutes = total
        UserDefaults.standard.set(total, forKey: customKey)
        guard autoOffControl?.selectedSegment == 4 else { return }
        autoOffMinutes = total
        if isOn { startKeepAwakeTimer(minutes: total) }   // restart the countdown at the new length
    }

    private func renderCustomDuration(_ total: Int? = nil) {
        let t = total ?? customMinutes
        hoursField?.stringValue = "\(t / 60)"
        minutesField?.stringValue = String(format: "%02d", t % 60)
        hoursStepper?.integerValue = t / 60
        minutesStepper?.integerValue = t % 60
    }

    // MARK: Preset editor — [ H ]⇅ h ×3 in a small popover under the timer control. Applies immediately.
    private func showPresetEditor() {
        if presetPopover.isShown { presetPopover.performClose(nil); return }
        if presetFields.isEmpty {
            let pad: CGFloat = 12, slot: CGFloat = 84
            let root = FlippedView(frame: NSRect(x: 0, y: 0, width: pad * 2 + slot * 3 - 12, height: 22 + pad * 2))
            for i in presetHours.indices {
                let cell = FlippedView(frame: NSRect(x: pad + CGFloat(i) * slot, y: pad, width: slot - 12, height: 22))
                presetFields.append(numberField(in: cell, x: 0, action: #selector(presetChanged(_:))))
                presetSteppers.append(stepper(in: cell, x: 42, min: Double(presetMin), max: Double(presetMax),
                                              increment: 1, action: #selector(presetChanged(_:))))
                let h = makeLabel("h", font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
                h.frame = NSRect(x: 60, y: 2, width: 16, height: 18)
                cell.addSubview(h)
                root.addSubview(cell)
            }
            let vc = NSViewController()
            vc.view = root
            presetPopover.contentViewController = vc
            presetPopover.contentSize = root.frame.size
            presetPopover.behavior = .transient
            presetPopover.delegate = self
        }
        renderPresets()
        presetPopover.show(relativeTo: autoOffControl.bounds, of: autoOffControl, preferredEdge: .maxY)
    }

    // A preset edited (field commit or stepper click): whole hours, clamped to [presetMin, presetMax];
    // junk input reverts. If that preset is the active selection, the countdown restarts at the new length.
    @objc private func presetChanged(_ sender: Any) {
        var i = 0, h = 0
        if let s = sender as? NSStepper, let idx = presetSteppers.firstIndex(where: { $0 === s }) {
            i = idx; h = s.integerValue
        } else if let f = sender as? NSTextField, let idx = presetFields.firstIndex(where: { $0 === f }) {
            i = idx
            h = Int(f.stringValue.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil } ?? presetHours[idx]
        } else { return }
        h = min(max(h, presetMin), presetMax)
        let changed = h != presetHours[i]
        presetHours[i] = h
        renderPresets()
        guard changed else { return }
        UserDefaults.standard.set(presetHours, forKey: presetKey)
        guard autoOffControl?.selectedSegment == i + 1 else { return }
        autoOffMinutes = h * 60
        if isOn { startKeepAwakeTimer(minutes: autoOffMinutes) }
    }

    private func renderPresets() {
        for (i, h) in presetHours.enumerated() {
            autoOffControl?.setLabel("\(h)h", forSegment: i + 1)
            if i < presetFields.count {
                presetFields[i].stringValue = "\(h)"
                presetSteppers[i].integerValue = h
            }
        }
    }

    // Show/hide the custom row: grow/shrink the timer card, push the cards below it, and resize
    // the popover. Frames are absolute in a flipped root, so this is a plain vertical shift.
    private func layoutTimerCard(showCustom: Bool) {
        guard showCustom != customRowShown, let card = timerCard, let root = rootView else { return }
        customRowShown = showCustom
        let dy = showCustom ? customRowHeight : -customRowHeight
        customRow.isHidden = !showCustom
        card.frame.size.height += dy
        countdownLabel.frame.origin.y += dy
        for v in belowTimerViews { v.frame.origin.y += dy }
        root.frame.size.height += dy
        popover.contentSize = NSSize(width: popoverWidth, height: root.frame.height)
    }

    private func startCountdownTicker() {
        countdownTicker?.invalidate()
        countdownTicker = Timer.scheduledTimer(timeInterval: 1, target: self,
                                               selector: #selector(countdownTick), userInfo: nil, repeats: true)
    }

    @objc private func countdownTick() { updateCountdownLabel() }

    private func updateCountdownLabel() {
        guard let end = timerEndDate, isOn else { countdownLabel?.stringValue = ""; return }
        let remaining = Int(end.timeIntervalSinceNow.rounded())
        guard remaining > 0 else { countdownLabel?.stringValue = ""; return }
        let h = remaining / 3600, m = (remaining % 3600) / 60, s = remaining % 60
        let t = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        countdownLabel?.stringValue = "Auto-off in \(t) · ends \(endTimeText(end))"
        renderServiceCard()
    }

    // "14:30" today, "Tue 09:15" on another day (locale-aware).
    private let endTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()
    private let endDayTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEjmm"); return f
    }()
    private func endTimeText(_ end: Date) -> String {
        (Calendar.current.isDateInToday(end) ? endTimeFormatter : endDayTimeFormatter).string(from: end)
    }

    // MARK: - Timer hand-off file (read by the background service while the app isn't running)
    // end=<epoch seconds>, floor=<battery %>, segment=<selected timer segment>
    private func writeTimerState() {
        guard let end = timerEndDate else { return }
        let text = "end=\(Int(end.timeIntervalSince1970))\nfloor=\(batteryFloorPercent)\nsegment=\(autoOffControl?.selectedSegment ?? 0)\n"
        do {
            try FileManager.default.createDirectory(at: timerStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: timerStateURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Sleepless: could not save the timer: %@", error.localizedDescription)
        }
    }

    private func removeTimerState() {
        try? FileManager.default.removeItem(at: timerStateURL)
    }

    private func readTimerState() -> (end: Date, segment: Int)? {
        guard let text = try? String(contentsOf: timerStateURL, encoding: .utf8) else { return nil }
        var values: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let v = Int(kv[1]) { values[String(kv[0])] = v }
        }
        guard let end = values["end"] else { return nil }
        return (Date(timeIntervalSince1970: TimeInterval(end)), min(max(values["segment"] ?? 0, 0), 4))
    }

    // At launch: pick up a timer that the background service carried (or that survived a crash).
    private func resumeTimer(_ saved: (end: Date, segment: Int)?) {
        guard let saved else { return }
        if saved.end <= Date() {                              // overdue: finish it now
            if isOn {
                timerEndDate = saved.end
                keepAwakeTimerFired()
            } else {
                removeTimerState()
            }
            return
        }
        if !isOn {
            // The app deletes this file whenever it turns keep-awake off, so a future end with
            // keep-awake off means a restart reset disablesleep. With the service installed the
            // timer was meant to survive: if the app beat the service's first check after boot,
            // re-apply keep-awake here instead of dropping the timer. Without it, timers end at logout.
            guard serviceState != .notInstalled, setDisableSleep(true) == .ok else {
                userForcedOn = false
                removeTimerState()
                return
            }
            setPowerMode(awake: true)
            applyUI(on: readSleepDisabled())
            guard isOn else { removeTimerState(); return }
        }
        userForcedOn = true                                   // the user chose this timer
        autoOffControl?.selectedSegment = saved.segment
        switch saved.segment {
        case 1...3: autoOffMinutes = presetHours[saved.segment - 1] * 60
        case 4: autoOffMinutes = customMinutes
        default: autoOffMinutes = 0
        }
        layoutTimerCard(showCustom: saved.segment == 4)
        armTimer(until: saved.end)
    }

    // MARK: - Opens at login (Feature 2) — part of the background service; never re-enables sleep prevention
    // The login item follows the service's installation (not Start/Stop): installed means the app
    // opens at login, so it can resume a carried timer and show it. Synced at every launch, which
    // also retires a login item from older versions' separate "Launch at login" switch.
    private func syncLoginItem() {
        let want = serviceState != .notInstalled
        let status = SMAppService.mainApp.status
        do {
            if want, status != .enabled { try SMAppService.mainApp.register() }
            if !want, status != .notRegistered { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Sleepless: login item update failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Core state sync
    @objc private func refresh() {
        ensureStatusItemExists()
        let on = readSleepDisabled()
        applyUI(on: on)
        if on { enforceSafetyNets() }
    }

    private func applyUI(on: Bool) {
        isOn = on
        if !on { cancelKeepAwakeTimer() }   // going OFF clears any countdown/timer
        // ARMED = kept awake while actively discharging on battery, so the
        // auto-off safety net is live. Distinct menu-bar glyph (cup + dot).
        var armed = false
        if on {
            let (onBattery, discharging, _) = batteryStatus()
            armed = onBattery && discharging
        }
        if let button = statusItem.button {
            let newImage = on ? (armed ? armedGlyph : onGlyph) : offGlyph
            if button.image !== newImage {   // state (cup shape) changed -> swap + pulse
                button.image = newImage
                pulseStatusItem()
            }
            button.toolTip = on
                ? (armed
                    ? "Sleepless: on (battery). Auto-off at \(batteryFloorPercent)% or in Low Power Mode."
                    : "Sleepless: on. Stays awake with the lid closed.")
                : "Sleepless: off. Sleeps normally."
        }
        toggleSwitch?.state = on ? .on : .off
        // Brand-violet accent communicates the privileged "awake" state at a glance.
        mainCard?.active = on
        headerMark?.contentTintColor = on ? brandAccentSoft : .labelColor
        renderText()
        updateCountdownLabel()
    }

    // Update text labels only (no pmset subprocess; safe to call on every slider tick).
    private func renderText() {
        floorValueLabel?.stringValue = "\(batteryFloorPercent)%"
        captionLabel?.stringValue = isOn
            ? "Stays awake when the lid is closed. Turns off at \(batteryFloorPercent)% battery or in Low Power Mode."
            : "Sleeps normally when you close the lid."
    }

    @objc private func floorSliderChanged(_ sender: NSSlider) {
        let v = min(max(Int(sender.doubleValue.rounded()), floorMin), floorMax)
        if v != batteryFloorPercent {
            batteryFloorPercent = v
            UserDefaults.standard.set(v, forKey: floorKey)
            writeTimerState()   // the service enforces the same floor while the app isn't running
        }
        renderText()
    }

    // Result of the privileged keep-awake toggle, based on sudo's REAL exit status — not on a
    // second, independent state read. `.ok` = the command ran; `.grantMissing` = the passwordless
    // sudoers grant isn't installed (sudo -n refused), the one case that warrants setup; `.failed`
    // = any other error. Using sudo's own result (instead of re-reading SleepDisabled) is the fix:
    // a safety net flipping sleep back on must never look like "permission missing" and re-prompt.
    private enum ToggleResult: Equatable, Sendable { case ok, grantMissing, failed(String) }

    @discardableResult
    private func setDisableSleep(_ on: Bool) -> ToggleResult {
        runSudo(["/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
    }

    // Energy Mode follows Sleepless: High Power while kept awake, Automatic when off.
    // Macs without `powermode` just fail quietly (.failed).
    @discardableResult
    private func setPowerMode(awake: Bool) -> ToggleResult {
        runSudo(["/usr/bin/pmset", "-a", "powermode", awake ? "2" : "0"])
    }

    // sudo -n: never prompt (GUI app has no TTY). Each argument vector matches the NOPASSWD
    // sudoers grant exactly, so it runs without a password.
    @discardableResult
    private func runSudo(_ command: [String]) -> ToggleResult { Self.sudo(command) }

    // Thread-safe core of runSudo, also used by the background-service commands off the main thread.
    nonisolated private static func sudo(_ command: [String]) -> ToggleResult {
        let (exit, _, err) = runPrivileged(["-n"] + command)
        let result: ToggleResult
        if exit == 0 {
            result = .ok
        } else if err.range(of: "a password is required", options: .caseInsensitive) != nil
               || err.range(of: "not allowed", options: .caseInsensitive) != nil
               || err.range(of: "may not run", options: .caseInsensitive) != nil {
            result = .grantMissing   // grant absent/removed -> sudo -n refused to run passwordless
        } else {
            result = .failed(err.isEmpty ? "exit \(exit)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    // Run a privileged command via sudo, capturing exit status + stderr (which the generic
    // runCapture discards). stdin is /dev/null so a GUI process with no controlling TTY can
    // never block on a prompt. This is what lets the app KNOW whether its own toggle worked.
    nonisolated private static func runPrivileged(_ args: [String]) -> (exit: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() }
        catch {
            NSLog("Sleepless: failed to launch sudo: %@", error.localizedDescription)
            return (-1, "", "launch failed: \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    // MARK: - Battery + Low-Power-Mode safety nets (silent; no extra UI) — Feature 3
    private func enforceSafetyNets() {
        let (onBattery, discharging, percent) = batteryStatus()
        guard onBattery, discharging else { return }
        // Hard battery floor ALWAYS wins, even over a deliberate turn-on: never drain to empty.
        if percent <= batteryFloorPercent {
            setDisableSleep(false); userForcedOn = false
            setPowerMode(awake: false)
            applyUI(on: readSleepDisabled())
            notify("Battery low (\(percent)%). Sleepless turned off.")
            return
        }
        // Low Power Mode auto-off, UNLESS the user deliberately chose to keep awake this session.
        if ProcessInfo.processInfo.isLowPowerModeEnabled && !userForcedOn {
            setDisableSleep(false)
            setPowerMode(awake: false)
            applyUI(on: readSleepDisabled())
            notify("Low Power Mode on. Sleepless turned off.")
        }
    }

    // MARK: - Readers (no root needed)
    private func readSleepDisabled() -> Bool {
        let out = runCapture("/usr/bin/pmset", ["-g"])
        for line in out.split(whereSeparator: { $0 == "\n" }) {
            if line.range(of: "SleepDisabled", options: .caseInsensitive) != nil {
                let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if let last = toks.last { return last == "1" }
            }
        }
        return false   // line absent -> OFF
    }

    private func batteryStatus() -> (onBattery: Bool, discharging: Bool, percent: Int) {
        let out = runCapture("/usr/bin/pmset", ["-g", "batt"])
        let onBattery = out.contains("Battery Power")
        let discharging = out.range(of: "discharging", options: .caseInsensitive) != nil
        var percent = 100
        for tok in out.split(whereSeparator: { " \t\n;".contains($0) }) {
            if tok.hasSuffix("%"), let v = Int(tok.dropLast()) { percent = v; break }
        }
        return (onBattery, discharging, percent)
    }

    // MARK: - Notification (mirrors Nexus' osascript approach)
    private func notify(_ message: String) {
        let script = "display notification \"\(message)\" with title \"Sleepless\" sound name \"Tink\""
        _ = runCapture("/usr/bin/osascript", ["-e", script])
    }

    // MARK: - Process runner (explicit PATH/HOME; captures stdout)
    @discardableResult
    private func runCapture(_ launchPath: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() }
        catch { NSLog("Sleepless: failed to launch %@: %@", launchPath, error.localizedDescription); return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @objc private func uninstall() {
        closePopover()
        let alert = NSAlert()
        alert.messageText = "Uninstall Sleepless?"
        alert.informativeText = "Restore normal sleep and remove the app, the background service and login item, the permission grant, and preferences. Terminal will open to show progress and may ask for your administrator password."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Uninstall")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Sleepless-uninstall-" + UUID().uuidString, isDirectory: true)
        do {
            guard let source = Bundle.main.url(forResource: "uninstall", withExtension: "sh") else {
                throw NSError(domain: "Sleepless", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled uninstaller is missing."])
            }
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let script = staging.appendingPathComponent("uninstall.sh")
            try fm.copyItem(at: source, to: script)
            // Terminal owns the job so quitting/deleting this app cannot stop it. Both
            // shell arguments and the enclosing AppleScript string need separate quoting.
            let command = "/bin/bash \(shellQuote(script.path)) --app \(shellQuote(Bundle.main.bundlePath)) --yes; /bin/rm -f \(shellQuote(script.path)); /bin/rmdir \(shellQuote(staging.path))"
            let literal = command.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let scriptText = "tell application \"Terminal\"\nactivate\ndo script \"\(literal)\"\nend tell"
            var error: NSDictionary?
            guard let appleScript = NSAppleScript(source: scriptText) else {
                throw NSError(domain: "Sleepless", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not prepare the Terminal command."])
            }
            appleScript.executeAndReturnError(&error)
            if let error {
                throw NSError(domain: "Sleepless", code: 3, userInfo: [NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String ?? "Terminal did not accept the uninstall command."])
            }
            NSApp.terminate(nil)
        } catch {
            try? fm.removeItem(at: staging)
            let failure = NSAlert()
            failure.messageText = "Uninstall could not start"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Quit closes the menu-bar app. With a timer running and the service able to carry it, the
    // Mac stays awake until the timer ends; otherwise quitting restores normal sleep as before.
    @objc private func quit() {
        refreshServiceState()
        if isOn, let end = timerEndDate, end > Date(), serviceState == .running {
            let alert = NSAlert()
            alert.messageText = "Quit Sleepless?"
            alert.informativeText = "The background service keeps your Mac awake until the timer ends at \(endTimeText(end)). To turn everything off now, use Stop instead."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            handOffToService = true
        }
        NSApp.terminate(nil)
    }
}

@main
enum SleeplessApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst() == ["--unregister-login-item"] {
            do {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
                guard SMAppService.mainApp.status != .enabled else {
                    fputs("Sleepless: Launch at login is still enabled.\n", stderr)
                    exit(1)
                }
                print("Launch at login is disabled.")
                exit(0)
            } catch {
                fputs("Sleepless: could not disable Launch at login: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        objc_setAssociatedObject(app, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}

nonisolated(unsafe) private var delegateKey = 0
