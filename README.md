# GPD MicroPC 2 Middle-Button Scroll

Enables middle-button scrolling on Linux. Hold the middle mouse button and move your finger on the touchpad to scroll.

## The Problem

The MicroPC 2 exposes the middle button and touchpad as separate input devices. This breaks built-in scroll functionality. This daemon bridges them.

## Install

```bash
./setup-middle-scroll.sh
```

The installer guides you through preferences and handles everything.

**Requirements:** Linux with systemd, Python 3, `python-evdev`

**Tested on:** Arch Linux + KDE Plasma (Wayland)

The installer auto-installs `python-evdev` via pacman. For other distros, install it first:
```bash
# Fedora
sudo dnf install python3-evdev

# Ubuntu/Debian
sudo apt install python3-evdev

# pip
pip install evdev
```

## Usage

- **Hold middle button + move up/down** → Vertical scroll
- **Hold middle button + move left/right** → Horizontal scroll
- **Tap middle button** → Normal middle-click

## Commands

```bash
./setup-middle-scroll.sh --status       # Check status
./setup-middle-scroll.sh --reconfigure  # Change settings
./setup-middle-scroll.sh --remove       # Uninstall
```

## Logs

```bash
journalctl --user -u gpd-scroll -f
```

## License

MIT
