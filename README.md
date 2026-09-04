# KWin Native Snap Assistant

A small Plasma 6 KWin script that completes a half-screen snap. After a window
is quick-tiled to the left or right, it offers the other windows for the empty
half of the screen. 

Keyboard quick-tiling opens KWin's window switcher (native) and here we expect you've moved the window with the Meta + rigth / left arrow and you're still holding the Meta key. 

Pointer quick-tiling opens
a custom visual picker after a short delay that you can access with your mouse - so this one contradicts the naming `native` a little, but I just couldn't make it work in other way. 

## Install

Run these commands from the directory that contains this repository:

```bash
kpackagetool6 --type=KWin/Script --install KWin-native-snap-assistant
```

Enable **Snap Assist** in **System Settings → Window Management → KWin
Scripts** after installing it.

To update an existing installation:

```bash
kpackagetool6 --type=KWin/Script --upgrade KWin-native-snap-assistant
```

To remove it:

```bash
kpackagetool6 --type=KWin/Script --remove snap-assist
```

The equivalent short options are `-i`, `-u`, and `-r`.

Actually after installation it is available also in Plasma setting GUI among other KWin scripts.

## Reload during development

KWin exposes script lifecycle methods over D-Bus:

```bash
qdbus6 org.kde.KWin /Scripting unloadScript snap-assist
qdbus6 org.kde.KWin /Scripting start
```

Check that `unloadScript` returns `true` before starting scripts again. KWin can
retain a compiled QML component even after a D-Bus unload/reload. If the source
line numbers or log messages still match an older version, disable and re-enable
the script in System Settings. Logging out and back in is the reliable fallback.

## Logs and troubleshooting

Follow the QML and KWin scripting journal categories with:

```bash
journalctl --user -f QT_CATEGORY=qml QT_CATEGORY=kwin_scripting
```

To show only this script's messages:

```bash
journalctl --user -f QT_CATEGORY=qml | grep --line-buffered 'snap-assist:'
```

Useful event sequence for a pointer snap:

```text
snap-assist: move started ...
snap-assist: move finished ...
snap-assist: start left pointer ...
snap-assist: picker left ...
```

If `picker` is logged but no overlay appears, first make sure KWin is not running
a cached copy by comparing the reported QML source line with the installed file
under `~/.local/share/kwin/scripts/snap-assist/`.

## Implementation notes

- `tileChanged` is the primary snap notification.
- Some pointer snaps do not deliver that signal at a useful time, so
  `frameGeometryChanged` provides a pointer-only fallback with a 120 ms debounce.
- Geometry changes from ordinary applications and keyboard tiling do not arm the
  fallback.
- The picker waits 200 ms after a pointer snap so KWin can finish the operation.

## Personal notes
Shame on me, it was developed with AI tools. But at least it works. I think it is still something as in my knowledge the community couldn't provide a functional version since Plasma 6 was out and the old beloved [script](https://github.com/emvaized/kde-snap-assist) is not compatible with it. Also as I see, the Plasma Desktop project rarely focus on such UX related things, so we can cook what we have. 

This code and the functionality can be improved and any kind of contribution is welcome!

## API references

- [KWin scripting](https://develop.kde.org/docs/plasma/kwin/)
- [Qt Quick `Window`](https://doc.qt.io/qt-6/qml-qtquick-window.html)
- [Qt QML `Connections`](https://doc.qt.io/qt-6/qml-qtqml-connections.html)
- [Qt QML `Instantiator`](https://doc.qt.io/qt-6/qml-qtqml-models-instantiator.html)
- [Qt QML `Timer`](https://doc.qt.io/qt-6/qml-qtqml-timer.html)

## Validate changes

```bash
qmllint contents/ui/main.qml
git diff --check
```
