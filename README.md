# Desktop Please

**Show Desktop that works from full-screen apps.**

macOS's Show Desktop shortcut does nothing while you're in a full-screen app,
because a full-screen app lives in its own Space with no desktop behind it.
Desktop Please fixes that. Press your usual Show Desktop shortcut anywhere: on a
normal desktop it works as always, and from a full-screen app it takes you to
your desktop and shows it.

## Install

Download the zip from [Releases](../../releases), unzip it, and drag
**Desktop Please** to Applications. Open it once. It has no window or menu bar
icon: it runs in the background and opens itself at login.

macOS then asks for **Accessibility** permission (System Settings → Privacy &
Security → Accessibility). That's needed to leave full-screen apps; see
[How it works](#how-it-works). Without it, Show Desktop still works on normal
desktops. If it still can't leave full-screen apps after you allow it, quit and
reopen Desktop Please.

To build it yourself, run `./build.sh`. You'll need Xcode or the Command Line
Tools.

## Use

Press your Show Desktop shortcut. You set it where you always have: System
Settings → Keyboard → Keyboard Shortcuts → Mission Control → Show Desktop.
It's F11 by default, which is fn-F11 on most Mac laptops.

- **On a normal desktop** it's the usual Show Desktop: windows slide aside, and
  pressing again brings them back.
- **In a full-screen app** it switches to Desktop 1 and shows the desktop there.

While System Settings is open, Desktop Please steps aside and Show Desktop works
like stock macOS. It takes over again, with any shortcut you changed, when
System Settings closes.

## Quit or remove

Open Desktop Please again while it's running to get a Quit button. Quitting
gives Show Desktop back to macOS exactly as it was. It still opens at login
unless you turn that off in System Settings → General → Login Items.

To remove it, quit it and move it to the Trash, or run `./build.sh uninstall`
if you built it yourself.

## How it works

It's one Swift file, so you can read all of it before granting Accessibility.

- **Your shortcut.** A system shortcut is always caught before any app's, so
  while Desktop Please runs it switches the system's Show Desktop off and
  listens for the same keys itself (`RegisterEventHotKey`). The change is live
  only: nothing is saved, and quitting or the next login undoes it. It steps
  aside while System Settings is open, because the Keyboard pane there can save
  that temporary change as your real setting.
- **Which Space you're on** comes from SkyLight's `CGSGetActiveSpace` and
  `CGSCopyManagedDisplaySpaces`, where type 4 means full screen.
- **Leaving a full-screen app** presses macOS's own "Switch to Desktop 1"
  shortcut for you. That's the one step that needs Accessibility. If you have
  no shortcut for it, Desktop Please borrows an unused one (⌃⌥⇧⌘1) while it
  runs. Activating an app on the desktop would need no permission, but macOS
  14 and later ignore activation requests from background apps.
- **Show Desktop itself** is
  `CoreDockSendNotification("com.apple.showdesktop.awake")`, the same request
  the Dock gets from the real shortcut.

Those are private APIs, so Desktop Please can't be on the Mac App Store, and a
macOS update could break it.

## Limitations

- Tested on macOS 27 with a single display. Multiple displays haven't been tried.
- From a full-screen app it always goes to Desktop 1.
- If it's force-quit, your Show Desktop shortcut does nothing until you open
  Desktop Please again or log out and back in.
- Needs macOS 14 or later.

## Troubleshooting

Everything it does is logged:

    /usr/bin/log show --last 10m --predicate 'subsystem == "com.adammackey.desktopplease"'

The full path matters: in zsh, a bare `log` is a builtin.

## Support

Desktop Please is free. If it saves you a few swipes a day, you can
[buy me a coffee](https://buymeacoffee.com/adammackey).

## License

MIT. See [LICENSE](LICENSE).
