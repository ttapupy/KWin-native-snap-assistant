# --- ABANDONED ---

# KWin Native Snap Assistant

```bash
kpackagetool6 --type=KWin/Script --install .
```

Or from the parent directory:

```bash
kpackagetool6 --type=KWin/Script --install KWin-native-snap-assistant
```

Enable **Snap Assist** in **System Settings → Window Management → KWin Scripts**.

### Upgrade an existing installation

```bash
kpackagetool6 --type=KWin/Script --upgrade .
```

### Remove

```bash
kpackagetool6 --type=KWin/Script --remove snap-assist
```

---

## ⚙️ Configuration

Settings can be customized in `contents/config/config.json`:

```json
{
    "skipPickerOnKeyboardSnap": false,
    "closePickerOnClickOutside": true,
    "suppressPickerWhenAllFilled": true,
    "enableMultiZoneChaining": true,
    "autoSelectSingleCandidate": false,
    "showNumberShortcuts": true,
    "showWindowIcons": true,
    "showCloseButtonOnHover": true,
    "animationSpeedMs": 220
}
```

| Option | Default | Description |
|---|---|---|
| `skipPickerOnKeyboardSnap` | `false` | When `false`, snapping via keyboard (`Meta + Left/Right/Up/Down`) invokes Snap Assist just like mouse snapping. Set to `true` for silent keyboard tiling. |
| `closePickerOnClickOutside` | `true` | Clicking anywhere outside candidate cards (desktop, panel, snapped window) dismisses assist. |
| `suppressPickerWhenAllFilled` | `true` | When all layout zones on the screen are occupied by tiled windows, Snap Assist suppresses itself. |
| `enableMultiZoneChaining` | `true` | When multiple zones are empty (e.g. 4 quarters), sequentially prompts for each empty zone. |
| `autoSelectSingleCandidate` | `false` | When only 1 candidate window is available, automatically snaps it without waiting for input. |
| `showNumberShortcuts` | `true` | Overlays `1`, `2`, `3` badges on cards for fast number-key selection. |
| `showWindowIcons` | `true` | Displays application icons in candidate cards. |
| `showCloseButtonOnHover` | `true` | Displays a close button on card hover to close unwanted windows. |
| `animationSpeedMs` | `220` | Duration of entrance and zone-transition animations in milliseconds. |

---

## 🛠️ Development & Reloading

To reload the script via D-Bus after modifying code:

```bash
qdbus6 org.kde.KWin /Scripting unloadScript snap-assist
qdbus6 org.kde.KWin /Scripting start
```

### Live Logs

To inspect Snap Assist events:

```bash
journalctl --user -f QT_CATEGORY=qml QT_CATEGORY=kwin_scripting | grep --line-buffered 'snap-assist:'
```

### Code Validation

```bash
qmllint contents/ui/main.qml
git diff --check
```

---

## 📜 License

GPL-3.0-or-later.
