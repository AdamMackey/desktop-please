// Desktop Please: Show Desktop that works from full-screen apps.
//
// macOS's Show Desktop does nothing inside a full-screen app, because a
// full-screen app lives in its own Space with no desktop behind it. This app
// watches for your Show Desktop shortcut, whatever it's set to in System
// Settings. Outside full screen it lets macOS handle the key as usual. In a
// full-screen Space it catches the key, switches to Desktop 1, then shows the
// desktop there.
//
// It never changes the Show Desktop setting. An earlier version switched the
// system's copy off while running, and System Settings' Keyboard pane saved
// that "off" as the user's real setting. So the key is caught with an event tap
// at the HID level instead, which sees and can swallow keys that are also
// system shortcuts (tested).
//
// It relies on private API, so it can't go on the Mac App Store:
//   - SkyLight (CGS*) to see which Space is showing, to read the Show Desktop
//     shortcut, and to borrow a shortcut for "Switch to Desktop 1" for the
//     half-second a switch takes, when that has none.
//   - CoreDockSendNotification to ask the Dock for Show Desktop directly.
// Catching keys and pressing "Switch to Desktop 1" both need Accessibility
// permission. Activating an app on the desktop would need no permission, but
// macOS ignores activation requests from background apps (tested: activate()
// returns true and the Space never moves).

import AppKit
import ApplicationServices
import ServiceManagement
import os

let bundleID = Bundle.main.bundleIdentifier ?? "com.adammackey.desktopplease"
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Desktop Please"
let logger = Logger(subsystem: bundleID, category: "app")

// `build.sh uninstall` runs the app with this to remove its login item.
if CommandLine.arguments.contains("--unregister") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

// MARK: - Private API

let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let appServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)

/// Looks up a private function. If a macOS update removed it, quit with a log
/// line rather than crash on first use.
func privateFunction<T>(_ library: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T {
    guard let pointer = dlsym(library, name) else {
        logger.fault("\(name, privacy: .public) is missing on this macOS, so \(appName, privacy: .public) can't work")
        exit(0)
    }
    return unsafeBitCast(pointer, to: type)
}

let CGSMainConnectionID = privateFunction(skyLight, "CGSMainConnectionID",
    as: (@convention(c) () -> Int32).self)
let CGSGetActiveSpace = privateFunction(skyLight, "CGSGetActiveSpace",
    as: (@convention(c) (Int32) -> UInt64).self)
let CGSCopyManagedDisplaySpaces = privateFunction(skyLight, "CGSCopyManagedDisplaySpaces",
    as: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
let CGSGetSymbolicHotKeyValue = privateFunction(skyLight, "CGSGetSymbolicHotKeyValue",
    as: (@convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt64>) -> Int32).self)
let CGSSetSymbolicHotKeyValue = privateFunction(skyLight, "CGSSetSymbolicHotKeyValue",
    as: (@convention(c) (Int32, UInt16, UInt16, UInt64) -> Int32).self)
let CGSIsSymbolicHotKeyEnabled = privateFunction(skyLight, "CGSIsSymbolicHotKeyEnabled",
    as: (@convention(c) (Int32) -> Bool).self)
let CGSSetSymbolicHotKeyEnabled = privateFunction(skyLight, "CGSSetSymbolicHotKeyEnabled",
    as: (@convention(c) (Int32, Bool) -> Int32).self)
let CoreDockSendNotification = privateFunction(appServices, "CoreDockSendNotification",
    as: (@convention(c) (CFString, UnsafeMutableRawPointer?) -> Void).self)

let connection = CGSMainConnectionID()

// MARK: - Spaces and the Dock

let fullScreenSpaceType = 4  // "type" in CGSCopyManagedDisplaySpaces; 0 is a normal desktop

func activeSpaceIsFullScreen() -> Bool {
    let active = Int(CGSGetActiveSpace(connection))
    let displays = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
    for display in displays {
        for space in display["Spaces"] as? [[String: Any]] ?? [] where space["ManagedSpaceID"] as? Int == active {
            return space["type"] as? Int == fullScreenSpaceType
        }
    }
    return false
}

func toggleShowDesktop() {
    CoreDockSendNotification("com.apple.showdesktop.awake" as CFString, nil)
}

// MARK: - Login

/// Start at login. Only done once, so switching it off in System Settings sticks.
func registerLoginItemOnce() {
    let key = "RegisteredLoginItem"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    do {
        try SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: key)
        logger.notice("Added to Login Items")
    } catch {
        logger.error("Couldn't add to Login Items: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - System shortcuts

/// IDs in com.apple.symbolichotkeys.
let showDesktopID: Int32 = 36
let switchToDesktop1ID: Int32 = 118

/// A system shortcut as the WindowServer stores it. Modifiers use NSEvent's
/// bits, which CGEventFlags shares: ⇧ 1<<17, ⌃ 1<<18, ⌥ 1<<19, ⌘ 1<<20, fn 1<<23.
struct Shortcut: Equatable, CustomStringConvertible {
    var character: UInt16  // 65535 for keys that type nothing, like F11
    var keyCode: UInt16
    var modifiers: UInt64

    /// ⇧⌃⌥⌘ only. fn differs by keyboard (fn-F11 on a laptop, F11 on a full
    /// keyboard), so it's ignored when matching; F11 matched either way in testing.
    static let modifierMask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)

    static func live(_ id: Int32) -> Shortcut {
        var character: UInt16 = 0, keyCode: UInt16 = 0, modifiers: UInt64 = 0
        _ = CGSGetSymbolicHotKeyValue(id, &character, &keyCode, &modifiers)
        return Shortcut(character: character, keyCode: keyCode, modifiers: modifiers)
    }

    func matches(_ event: CGEvent) -> Bool {
        UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)) == keyCode
            && event.flags.rawValue & Shortcut.modifierMask == modifiers & Shortcut.modifierMask
    }

    /// "⌘D", "F11" and so on, for the log and the quit alert.
    var description: String {
        var text = ""
        if modifiers & (1 << 18) != 0 { text += "⌃" }
        if modifiers & (1 << 19) != 0 { text += "⌥" }
        if modifiers & (1 << 17) != 0 { text += "⇧" }
        if modifiers & (1 << 20) != 0 { text += "⌘" }
        if character != 65535, let scalar = Unicode.Scalar(character) {
            return text + String(Character(scalar)).uppercased()
        }
        return text + (Shortcut.keyNames[keyCode] ?? "key \(keyCode)")
    }

    /// Names for keys that type nothing, by virtual key code.
    static let keyNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]
}

/// The live Show Desktop shortcut, or nil when it's switched off. Cached for a
/// couple of seconds, because it's checked on every key press.
final class ShowDesktopShortcut {
    private var cached: Shortcut?
    private var checkedAt: TimeInterval = -.infinity

    var current: Shortcut? {
        let now = ProcessInfo.processInfo.systemUptime
        if now - checkedAt > 2 {
            cached = CGSIsSymbolicHotKeyEnabled(showDesktopID) ? Shortcut.live(showDesktopID) : nil
            checkedAt = now
        }
        return cached
    }
}

/// Presses "Switch to Desktop 1" for the user, so the Dock switches Spaces
/// exactly as if they had. If it has no shortcut, borrows keys nobody types
/// (⌃⌥⇧⌘1) just for the switch; handBack() puts it back afterwards.
final class DesktopOneSwitch {
    private let borrowed = Shortcut(character: 65535, keyCode: 18,
                                    modifiers: (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20))
    private var original: Shortcut?

    func press() {
        if !CGSIsSymbolicHotKeyEnabled(switchToDesktop1ID) {
            original = Shortcut.live(switchToDesktop1ID)
            _ = CGSSetSymbolicHotKeyValue(switchToDesktop1ID, borrowed.character, borrowed.keyCode, borrowed.modifiers)
            _ = CGSSetSymbolicHotKeyEnabled(switchToDesktop1ID, true)
        }
        let shortcut = Shortcut.live(switchToDesktop1ID)
        let source = CGEventSource(stateID: .privateState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: isDown)
            event?.flags = CGEventFlags(rawValue: shortcut.modifiers)
            event?.post(tap: .cghidEventTap)
        }
    }

    func handBack() {
        guard let original else { return }
        _ = CGSSetSymbolicHotKeyValue(switchToDesktop1ID, original.character, original.keyCode, original.modifiers)
        _ = CGSSetSymbolicHotKeyEnabled(switchToDesktop1ID, false)
        self.original = nil
    }
}

// MARK: - Catching Show Desktop

final class Controller {
    let showDesktop = ShowDesktopShortcut()
    let desktopOne = DesktopOneSwitch()
    /// True while waiting to arrive on Desktop 1.
    private var switching = false
    /// Tells a stale timeout from an earlier press apart from the current one.
    private var attempt = 0

    /// Called for every key press. Returns true to swallow it.
    func shouldCatch(_ event: CGEvent) -> Bool {
        guard let shortcut = showDesktop.current, shortcut.matches(event) else { return false }
        // Mid-switch, keep macOS from toggling Show Desktop underneath us.
        if switching { return true }
        // On a normal desktop, macOS's own Show Desktop is exactly right.
        guard activeSpaceIsFullScreen() else { return false }
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            // Return quickly: macOS switches off a tap that's slow to answer.
            DispatchQueue.main.async { self.leaveFullScreen() }
        }
        return true
    }

    private func leaveFullScreen() {
        guard !switching else { return }
        logger.notice("Show Desktop pressed in a full-screen Space, switching to Desktop 1")
        switching = true
        desktopOne.press()

        attempt += 1
        let thisAttempt = attempt
        let center = NSWorkspace.shared.notificationCenter
        var observer: NSObjectProtocol?
        let finish = { (arrived: Bool) in
            guard self.switching, self.attempt == thisAttempt else { return }
            self.switching = false
            if let observer { center.removeObserver(observer) }
            self.desktopOne.handBack()
            if arrived {
                logger.notice("On Desktop 1, showing the desktop")
                // Let the slide finish, or the Dock can start mid-animation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: toggleShowDesktop)
            } else {
                logger.error("Pressed Switch to Desktop 1 but the Space never changed")
            }
        }
        observer = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                      object: nil, queue: .main) { _ in finish(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(false) }
    }
}

/// Watches key presses with an event tap at the HID level, the one place an app
/// can see, and swallow, a key that is also a system shortcut. Needs Accessibility.
final class KeyWatcher {
    let controller: Controller
    private var tap: CFMachPort?

    init(controller: Controller) {
        self.controller = controller
    }

    /// Returns false while Accessibility isn't allowed yet.
    func start() -> Bool {
        guard tap == nil else { return true }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, watcher in
                Unmanaged<KeyWatcher>.fromOpaque(watcher!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it's ever too slow; switch it straight back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown where controller.shouldCatch(event):
            return nil
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()
    lazy var keyWatcher = KeyWatcher(controller: controller)
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerLoginItemOnce()
        if keyWatcher.start() {
            logWatching()
        } else {
            logger.notice("Waiting for Accessibility permission")
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            // Start as soon as it's allowed, without a relaunch.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self, self.keyWatcher.start() else { return }
                timer.invalidate()
                self.logWatching()
            }
        }

        // If it's quit mid-switch, put back a borrowed Switch to Desktop 1.
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func logWatching() {
        let keys = controller.showDesktop.current?.description ?? "nothing yet (Show Desktop has no shortcut)"
        logger.notice("Watching for Show Desktop: \(keys, privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.desktopOne.handBack()
    }

    /// There's no window or menu bar icon, so opening the app again while it
    /// runs is the way to reach Quit.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(appName) is running"
        let keys = controller.showDesktop.current.map { "Show Desktop (\($0))" } ?? "Show Desktop"
        alert.informativeText = "\(keys) works from full-screen apps while \(appName) runs. "
            + "It opens again at login unless you turn it off in System Settings → General → Login Items."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
