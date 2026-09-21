// Desktop Please: Show Desktop that works from full-screen apps.
//
// macOS's Show Desktop does nothing inside a full-screen app, because a
// full-screen app lives in its own Space with no desktop behind it. This app
// takes over your Show Desktop shortcut, whatever it's set to in System
// Settings. On a normal desktop it toggles Show Desktop as usual; from a
// full-screen Space it switches to Desktop 1 first, then shows the desktop.
//
// It relies on private API, so it can't go on the Mac App Store:
//   - SkyLight (CGS*) to see which Space is showing and to adjust system
//     shortcuts. Those changes are live only: nothing is saved, and quitting
//     (or the next login) puts everything back.
//   - CoreDockSendNotification to ask the Dock for Show Desktop directly.
// Leaving a full-screen Space means pressing "Switch to Desktop 1" for you,
// which is why it needs Accessibility permission. Activating an app on the
// desktop would need no permission, but macOS ignores activation requests from
// background apps (tested: activate() returns true and the Space never moves).
//
// While System Settings is open the app steps aside entirely. Its Keyboard pane
// watches the live shortcuts and can save a switched-off Show Desktop as the
// user's real setting (seen once: ⌘D ended up saved as off).

import AppKit
import ApplicationServices
import Carbon.HIToolbox
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

// MARK: - Permissions, login and System Settings

/// Posting keystrokes needs Accessibility permission. CGPreflightPostEventAccess
/// stayed false in a running copy after the switch was turned on, until a
/// restart. AXIsProcessTrusted is the usual live check, so accept either.
func canPostEvents() -> Bool {
    AXIsProcessTrusted() || CGPreflightPostEventAccess()
}

func openAccessibilitySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
    }
}

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

let systemSettingsID = "com.apple.systempreferences"

func systemSettingsIsOpen() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: systemSettingsID).isEmpty
}

func isSystemSettings(_ note: Notification) -> Bool {
    (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == systemSettingsID
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

    static func live(_ id: Int32) -> Shortcut {
        var character: UInt16 = 0, keyCode: UInt16 = 0, modifiers: UInt64 = 0
        _ = CGSGetSymbolicHotKeyValue(id, &character, &keyCode, &modifiers)
        return Shortcut(character: character, keyCode: keyCode, modifiers: modifiers)
    }

    /// The same modifiers in Carbon's bits, for RegisterEventHotKey. Carbon has
    /// no fn bit, and F11 still matches without it (tested).
    var carbonModifiers: UInt32 {
        var carbon = 0
        if modifiers & (1 << 17) != 0 { carbon |= shiftKey }
        if modifiers & (1 << 18) != 0 { carbon |= controlKey }
        if modifiers & (1 << 19) != 0 { carbon |= optionKey }
        if modifiers & (1 << 20) != 0 { carbon |= cmdKey }
        return UInt32(carbon)
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

/// The Show Desktop shortcut as saved in System Settings, or nil when it's
/// switched off there. Read from the saved preferences rather than the
/// WindowServer, because this app switches the live one off.
func savedShowDesktopShortcut() -> Shortcut? {
    _ = CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
    let saved = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
    guard let entry = saved?[String(showDesktopID)] as? [String: Any] else {
        // Never changed from macOS's default, F11.
        return Shortcut(character: 65535, keyCode: 103, modifiers: 1 << 23)
    }
    guard entry["enabled"] as? Bool == true,
          let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int],
          parameters.count == 3 else { return nil }
    return Shortcut(character: UInt16(truncatingIfNeeded: parameters[0]),
                    keyCode: UInt16(truncatingIfNeeded: parameters[1]),
                    modifiers: UInt64(truncatingIfNeeded: parameters[2]))
}

/// Owns the Show Desktop shortcut. A system shortcut is caught before any
/// app's, so while this runs the system's own Show Desktop is switched off
/// (live only) and the same keys are registered here instead.
final class ShowDesktopShortcut {
    private(set) var registered: Shortcut?
    private var hotKey: EventHotKeyRef?
    private var saidNoShortcut = false

    func takeOver() {
        guard let saved = savedShowDesktopShortcut() else {
            unregister()
            if !saidNoShortcut {
                logger.notice("Show Desktop has no shortcut in System Settings, so there's nothing to listen for")
                saidNoShortcut = true
            }
            return
        }
        saidNoShortcut = false
        if saved != registered {
            unregister()
            let status = RegisterEventHotKey(UInt32(saved.keyCode), saved.carbonModifiers,
                                             EventHotKeyID(signature: OSType(0x4450_4C5A), id: 1),  // "DPLZ"
                                             GetApplicationEventTarget(), 0, &hotKey)
            if status == noErr {
                registered = saved
                logger.notice("Listening for \(saved.description, privacy: .public), the Show Desktop shortcut")
            } else {
                logger.fault("Couldn't register \(saved.description, privacy: .public) (OSStatus \(status)), another app may own it")
            }
        }
        if CGSIsSymbolicHotKeyEnabled(showDesktopID) {
            _ = CGSSetSymbolicHotKeyEnabled(showDesktopID, false)
        }
    }

    /// Gives Show Desktop back to macOS, as saved in System Settings.
    func handBack() {
        unregister()
        if savedShowDesktopShortcut() != nil {
            _ = CGSSetSymbolicHotKeyEnabled(showDesktopID, true)
        }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registered = nil
    }
}

/// Presses "Switch to Desktop 1" for the user, so the Dock switches Spaces
/// exactly as if they had. Posting the keys needs Accessibility permission.
final class DesktopOneSwitch {
    /// Keys nobody types, borrowed when Switch to Desktop 1 has no shortcut.
    private let borrowed = Shortcut(character: 65535, keyCode: 18,
                                    modifiers: (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20))  // ⌃⌥⇧⌘1
    /// How Switch to Desktop 1 was before borrowing, to put back.
    private var original: (shortcut: Shortcut, enabled: Bool)?

    /// Makes sure Switch to Desktop 1 has a live shortcut, borrowing one if not.
    func prepare() {
        guard !CGSIsSymbolicHotKeyEnabled(switchToDesktop1ID) else { return }
        if original == nil { original = (Shortcut.live(switchToDesktop1ID), false) }
        _ = CGSSetSymbolicHotKeyValue(switchToDesktop1ID, borrowed.character, borrowed.keyCode, borrowed.modifiers)
        _ = CGSSetSymbolicHotKeyEnabled(switchToDesktop1ID, true)
        logger.notice("Switch to Desktop 1 had no shortcut, borrowing \(self.borrowed.description, privacy: .public) while running")
    }

    func press() {
        prepare()
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
        _ = CGSSetSymbolicHotKeyValue(switchToDesktop1ID, original.shortcut.character,
                                      original.shortcut.keyCode, original.shortcut.modifiers)
        _ = CGSSetSymbolicHotKeyEnabled(switchToDesktop1ID, original.enabled)
        self.original = nil
    }
}

// MARK: - Pressing Show Desktop

final class Controller {
    let shortcut = ShowDesktopShortcut()
    let desktopOne = DesktopOneSwitch()
    /// True while waiting to arrive on Desktop 1, so a second press in that
    /// half-second doesn't start another switch.
    private var switching = false
    /// Tells a stale timeout from an earlier press apart from the current one.
    private var attempt = 0

    func takeOver() {
        shortcut.takeOver()
        desktopOne.prepare()
    }

    /// Puts both system shortcuts back exactly as saved.
    func handBack() {
        shortcut.handBack()
        desktopOne.handBack()
    }

    func pressed() {
        guard !switching else { return }
        guard activeSpaceIsFullScreen() else {
            toggleShowDesktop()
            return
        }
        guard canPostEvents() else {
            logger.error("No Accessibility permission, so can't leave the full-screen Space")
            openAccessibilitySettings()
            return
        }
        logger.notice("Pressed in a full-screen Space, switching to Desktop 1")
        desktopOne.press()

        switching = true
        attempt += 1
        let thisAttempt = attempt
        let center = NSWorkspace.shared.notificationCenter
        var observer: NSObjectProtocol?
        let finish = { (arrived: Bool) in
            guard self.switching, self.attempt == thisAttempt else { return }
            self.switching = false
            if let observer { center.removeObserver(observer) }
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.notice("Accessibility \(AXIsProcessTrusted() ? "allowed" : "off", privacy: .public), PostEvent \(CGPreflightPostEventAccess() ? "allowed" : "off", privacy: .public)")
        // Ask now, so the prompt shows up at launch rather than on the first
        // press from a full-screen app.
        if !canPostEvents() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        registerLoginItemOnce()

        if systemSettingsIsOpen() {
            logger.notice("System Settings is open, leaving Show Desktop to macOS until it closes")
        } else {
            controller.takeOver()
        }

        // Step aside while System Settings runs (see the note at the top), and
        // take over again when it quits, which also picks up any shortcut
        // changed there.
        let workspace = NSWorkspace.shared.notificationCenter
        _ = workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                  object: nil, queue: .main) { [weak self] note in
            guard isSystemSettings(note) else { return }
            logger.notice("System Settings opened, handing Show Desktop back until it closes")
            self?.controller.handBack()
        }
        _ = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                  object: nil, queue: .main) { [weak self] note in
            guard isSystemSettings(note) else { return }
            logger.notice("System Settings closed, taking over Show Desktop again")
            self?.controller.takeOver()
        }
        _ = workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                  object: nil, queue: .main) { [weak self] _ in
            if !systemSettingsIsOpen() { self?.controller.takeOver() }
        }

        // Quitting from Activity Monitor, `kill` or build.sh should hand the
        // system shortcuts back too, not just Quit in the alert below.
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.handBack()
        logger.notice("Quitting, system shortcuts handed back")
    }

    /// There's no window or menu bar icon, so opening the app again while it
    /// runs is the way to reach Quit.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(appName) is running"
        let works = controller.shortcut.registered.map { "Your Show Desktop shortcut, \($0), works" } ?? "Show Desktop works"
        alert.informativeText = "\(works) from full-screen apps while \(appName) runs. Quitting hands it back to macOS. "
            + "\(appName) opens again at login unless you turn it off in System Settings → General → Login Items."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
var hotKeyPressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
    delegate.controller.pressed()
    return noErr
}, 1, &hotKeyPressed, nil, nil)
app.delegate = delegate
app.run()
