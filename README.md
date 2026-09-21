# Desktop Please

**Show Desktop that works from full-screen apps.**

macOS's Show Desktop shortcut does nothing while you're in a full-screen app,
because a full-screen app lives in its own Space with no desktop behind it.
Desktop Please fixes that. Press your usual Show Desktop shortcut anywhere: on a
normal desktop it works as always, and from a full-screen app it takes you to
your desktop and shows it.

## Install

A notarized download is coming to [Releases](../../releases). For now, build
it (you'll need Xcode or the Command Line Tools):

    git clone https://github.com/AdamMackey/desktop-please.git
    cd desktop-please
    ./build.sh

That installs **Desktop Please** to Applications and opens it. It has no window
or menu bar icon: it runs in the background and opens itself at login.

macOS then asks for **Accessibility** permission (System Settings → Privacy &
Security → Accessibility). That's needed to catch your shortcut and to leave
full-screen apps; see [How it works](#how-it-works). It starts working as soon
as you allow it. Until then, Show Desktop simply works the way macOS always has.

## Use

Press your Show Desktop shortcut. You set it where you always have: System
Settings → Keyboard → Keyboard Shortcuts → Mission Control → Show Desktop.
It's F11 by default, which is fn-F11 on most Mac laptops.

- **On a normal desktop** it's the usual Show Desktop: windows slide aside, and
  pressing again brings them back.
- **In a full-screen app** it switches to Desktop 1 and shows the desktop there.

## Quit or remove

Open Desktop Please again while it's running to get a Quit button. It still
opens at login unless you turn that off in System Settings → General → Login
Items. Quitting changes nothing about Show Desktop, because Desktop Please never
touches that setting.

To remove it, quit it and move it to the Trash, or run `./build.sh uninstall`
if you built it yourself.

## How it works

It's one Swift file, so you can read all of it before granting Accessibility.

- **Your shortcut.** Desktop Please never changes your Show Desktop setting.
  It watches key presses with an event tap at the HID level, the one place an
  app can see a key that's also a system shortcut, and checks each press only
  to see whether it's Show Desktop. Nothing is recorded or sent anywhere.
  Outside full screen it lets the key through to macOS; in a full-screen app it
  catches it.
- **Which Space you're on** comes from SkyLight's `CGSGetActiveSpace` and
  `CGSCopyManagedDisplaySpaces`, where type 4 means full screen.
- **Leaving a full-screen app** presses macOS's own "Switch to Desktop 1"
  shortcut for you. If you have no shortcut for it, Desktop Please borrows an
  unused one (⌃⌥⇧⌘1) for the half-second the switch takes, then puts it back.
  Activating an app on the desktop would need no permission, but macOS 14 and
  later ignore activation requests from background apps.
- **Show Desktop itself** is
  `CoreDockSendNotification("com.apple.showdesktop.awake")`, the same request
  the Dock gets from the real shortcut.

Catching keys and pressing Switch to Desktop 1 are what need Accessibility.
The Space and Dock calls are private APIs, so Desktop Please can't be on the
Mac App Store, and a macOS update could break it.

## Limitations

- Tested on macOS 27 with a single display. Multiple displays haven't been tried.
- From a full-screen app it always goes to Desktop 1.
- It can't see keys while macOS hides them from other apps: in password fields,
  and in Terminal when Secure Keyboard Entry is on. Show Desktop then works the
  way macOS always has.
- Needs macOS 14 or later.

## Troubleshooting

If it doesn't respond after you allow Accessibility, quit it and open it again.
Everything it does is logged:

    /usr/bin/log show --last 10m --predicate 'subsystem == "com.adammackey.desktopplease"'

The full path matters: in zsh, a bare `log` is a builtin.

## Support

Desktop Please is free. If it saves you a few swipes a day, you can
[buy me a coffee](https://buymeacoffee.com/adammackey).

## License

MIT. See [LICENSE](LICENSE).
