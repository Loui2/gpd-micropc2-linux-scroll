#!/bin/bash
#
# GPD MicroPC 2 Middle-Button Scroll Installer
# ============================================
#
# Author: Loui2 (https://github.com/Loui2)
# License: MIT
# Version: 1.2.0
#
# COMPATIBILITY:
#   - OS: Arch Linux (uses pacman for dependencies)
#   - Desktop: Any (tested on KDE Plasma Wayland)
#   - Hardware: GPD MicroPC 2 (G1688-08)
#
# DESCRIPTION:
#   This script enables middle-button scrolling on the GPD MicroPC 2.
#   Hold the middle mouse button and move your finger on the touchpad to scroll.
#
# USAGE:
#   ./setup-middle-scroll.sh              # Interactive install
#   ./setup-middle-scroll.sh --help, -h   # Show help
#   ./setup-middle-scroll.sh --status, -s # Show current status
#   ./setup-middle-scroll.sh --remove, -r # Uninstall
#   ./setup-middle-scroll.sh --reconfigure
#

set -e

# Check not running as root
if [[ $EUID -eq 0 ]]; then
    echo >&2 "Error: Do not run this script as root."
    echo >&2 "Run as your normal user - sudo will be requested when needed."
    exit 1
fi

VERSION="1.2.0"
DAEMON_PATH="$HOME/.local/bin/gpd-scroll-daemon.py"
CONFIG_DIR="$HOME/.config/gpd-scroll"
CONFIG_PATH="$CONFIG_DIR/config"
SERVICE_PATH="$HOME/.config/systemd/user/gpd-scroll.service"
UDEV_RULE_PATH="/etc/udev/rules.d/99-gpd-scroll.rules"

# Default preferences
SCROLL_DIRECTION="natural"
HORIZONTAL_SCROLL="true"
SENSITIVITY="medium"
DEAD_ZONE="default"
POINTER_LOCK="true"
MIDDLE_BUTTON="smart"
EDGE_SCROLL_ENABLED="false"
EDGE_SCROLL_ZONE="medium"
EDGE_SCROLL_DWELL="300"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# DEBUG REPORT FUNCTION
# ============================================================================

# print_debug_report()
#
# Collects and displays comprehensive debugging information for troubleshooting.
# Called by error handlers when installation or service start fails.
#
# Outputs:
#   - System info (OS, kernel, desktop environment)
#   - Permission status (input group, uinput module/device, udev rules)
#   - Input device list (first 30 for readability)
#   - ALPS device details (if any)
#   - Recent service logs (last 30 lines, with home paths sanitized)
#
# Note: Home directory paths are sanitized to /home/USER for privacy.
print_debug_report() {
    echo ""
    echo "================================================================"
    echo "DEBUG REPORT - Copy everything below when reporting issues"
    echo "================================================================"
    echo ""
    echo "=== System Info ==="
    echo "Script version: $VERSION"
    echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    echo "Kernel: $(uname -r)"
    echo "Arch: $(uname -m)"
    echo "Desktop: ${XDG_CURRENT_DESKTOP:-unknown} (${XDG_SESSION_TYPE:-unknown})"
    echo ""
    echo "=== Permissions ==="
    echo "In input group: $(groups | grep -q '\binput\b' && echo 'YES' || echo 'NO')"
    echo "uinput module loaded: $(lsmod | grep -q uinput && echo 'YES' || echo 'NO')"
    echo "uinput device permissions: $(stat -c '%a %G' /dev/uinput 2>/dev/null || echo 'not found')"
    echo "Udev rule exists: $(test -f /etc/udev/rules.d/99-gpd-scroll.rules && echo 'YES' || echo 'NO')"
    echo ""
    echo "=== Input Devices (first 30) ==="
    cat /proc/bus/input/devices 2>/dev/null | grep -E "^N: Name=" | sed 's/^N: Name=//' | head -30
    echo "(Full list: cat /proc/bus/input/devices)"
    echo ""
    echo "=== ALPS Devices ==="
    cat /proc/bus/input/devices 2>/dev/null | grep -A 4 -i alps || echo "No ALPS devices found"
    echo ""
    echo "=== Service Logs (last 30 lines) ==="
    journalctl --user -u gpd-scroll -n 30 --no-pager 2>/dev/null | sed "s|/home/[^/]*|/home/USER|g" || echo "No logs available"
    echo ""
    echo "================================================================"
    echo "END DEBUG REPORT"
    echo "================================================================"
}

# ============================================================================
# EMBEDDED FILES
# ============================================================================

install_daemon() {
    mkdir -p "$HOME/.local/bin"
    cat > "$DAEMON_PATH" << 'DAEMON_EOF'
#!/usr/bin/env python3
"""
GPD MicroPC 2 Middle-Button Scroll Daemon
==========================================
Author: Loui2 (https://github.com/Loui2)
License: MIT
Version: 1.2.0

This daemon enables middle-button scrolling on the GPD MicroPC 2 by bridging
the separate mouse and touchpad evdev devices.

Hold the middle mouse button and move your finger on the touchpad to scroll.
"""

import os
import sys
import signal
import select
import time
import traceback
import evdev
from evdev import ecodes, UInput

# Global references for cleanup
mouse_dev = None
touchpad_dev = None
ui_device = None

# State variables
middle_held = False
finger_down = False
touchpad_grabbed = False
mouse_grabbed = False
scroll_movement_detected = False
last_x = None
last_y = None
accum_x = 0.0
accum_y = 0.0

# Edge scroll state
edge_bounds = None
edge_enter_time = None
edge_scroll_active = False
last_edge_scroll_time = 0
current_edges = None
edge_last_x = None
edge_last_y = None


def log(msg):
    """Print log message with prefix."""
    print(f"[GPD-Scroll] {msg}", flush=True)


def load_config():
    """Load configuration from file."""
    config_path = os.path.expanduser("~/.config/gpd-scroll/config")
    # Defaults if config missing or invalid
    config = {
        'direction': 'natural',
        'horizontal': True,
        'sensitivity': 15,
        'dead_zone': 5,
        'pointer_lock': True,
        'middle_button': 'smart',
        'edge_scroll_enabled': False,
        'edge_scroll_zone': 0.25,
        'edge_scroll_dwell': 300
    }
    sensitivity_map = {'low': 30, 'medium': 15, 'high': 8}
    dead_zone_map = {'none': 0, 'low': 2, 'default': 5, 'high': 10}
    edge_zone_map = {'small': 0.20, 'medium': 0.25, 'large': 0.30}

    if os.path.exists(config_path):
        try:
            with open(config_path) as f:
                for line in f:
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        key, value = key.strip(), value.strip()
                        if key == 'SCROLL_DIRECTION':
                            config['direction'] = value.lower()
                        elif key == 'HORIZONTAL_SCROLL':
                            config['horizontal'] = value.lower() == 'true'
                        elif key == 'SENSITIVITY':
                            config['sensitivity'] = sensitivity_map.get(value.lower(), 15)
                        elif key == 'DEAD_ZONE':
                            config['dead_zone'] = dead_zone_map.get(value.lower(), 5)
                        elif key == 'POINTER_LOCK':
                            config['pointer_lock'] = value.lower() == 'true'
                        elif key == 'MIDDLE_BUTTON':
                            if value.lower() in ['smart', 'block', 'native']:
                                config['middle_button'] = value.lower()
                        elif key == 'EDGE_SCROLL_ENABLED':
                            config['edge_scroll_enabled'] = value.lower() == 'true'
                        elif key == 'EDGE_SCROLL_ZONE':
                            config['edge_scroll_zone'] = edge_zone_map.get(value.lower(), 0.25)
                        elif key == 'EDGE_SCROLL_DWELL':
                            try:
                                dwell = int(value)
                                if 100 <= dwell <= 1000:
                                    config['edge_scroll_dwell'] = dwell
                            except ValueError:
                                pass
        except Exception as e:
            log(f"Warning: Could not read config: {e}")

    # Validate loaded values
    if config['sensitivity'] <= 0:
        log(f"Warning: Invalid sensitivity {config['sensitivity']}, using default 15")
        config['sensitivity'] = 15

    if config['direction'] not in ['natural', 'traditional']:
        log(f"Warning: Invalid direction '{config['direction']}', using 'natural'")
        config['direction'] = 'natural'

    if config['dead_zone'] < 0 or config['dead_zone'] > 50:
        log(f"Warning: Invalid dead_zone {config['dead_zone']}, using default 5")
        config['dead_zone'] = 5

    if config['middle_button'] not in ['smart', 'block', 'native']:
        log(f"Warning: Invalid middle_button '{config['middle_button']}', using 'smart'")
        config['middle_button'] = 'smart'

    return config


def find_alps_devices():
    """Find GPD MicroPC 2 ALPS devices with flexible matching."""
    mouse = None
    touchpad = None
    found_devices = []
    permission_errors = 0

    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
            name_upper = dev.name.upper()
            found_devices.append(f"{path}: {dev.name}")

            # Flexible matching: ALPS + vendor ID pattern
            if "ALPS" in name_upper and "36B6" in name_upper:
                if "MOUSE" in name_upper and mouse is None:
                    mouse = dev
                elif ("TOUCHPAD" in name_upper or "PAD" in name_upper) and touchpad is None:
                    touchpad = dev
                else:
                    dev.close()
            else:
                dev.close()
        except PermissionError:
            permission_errors += 1
            log(f"Warning: Permission denied for {path}")
        except OSError as e:
            log(f"Warning: Could not access {path}: {e}")

    # Detailed debug output if detection fails
    if not mouse or not touchpad:
        log("")
        log("=== Device Detection Debug ===")
        log(f"Permission errors: {permission_errors}")
        log(f"Devices accessible: {len(found_devices)}")
        if permission_errors > 0 and len(found_devices) == 0:
            log("")
            log("FIX: Permission denied for ALL devices - ensure you're in 'input' group:")
            log("  1. Run: sudo usermod -aG input $USER")
            log("  2. LOG OUT and back in (required)")
        elif permission_errors > 0:
            log("")
            log(f"WARNING: Permission denied for {permission_errors} device(s)")
            log("Some devices may not be accessible. Consider adding to 'input' group:")
            log("  1. Run: sudo usermod -aG input $USER")
            log("  2. LOG OUT and back in (required)")
        log("")
        log("Devices found:")
        if found_devices:
            for d in found_devices:
                log(f"  {d}")
        else:
            log("  (none - all had permission errors)")
        log("")
        log("Looking for: 'ALPS' + '36B6' in device name")
        log("If your device has a different name format, please report it.")

    return mouse, touchpad


def get_touchpad_bounds(touchpad_dev, edge_percent):
    """Get touchpad boundaries for edge scroll zones.

    Returns dict with x_min, x_max, y_min, y_max and edge thresholds,
    or None on error (edge scroll silently disabled).
    """
    try:
        caps = touchpad_dev.capabilities(absinfo=True)
        x_info = None
        y_info = None

        for item in caps.get(ecodes.EV_ABS, []):
            code, absinfo = item
            if code == ecodes.ABS_X:
                x_info = absinfo
            elif code == ecodes.ABS_Y:
                y_info = absinfo

        if not x_info or not y_info:
            log("Warning: Could not get touchpad ABS_X/ABS_Y info")
            return None

        x_range = x_info.max - x_info.min
        y_range = y_info.max - y_info.min

        bounds = {
            'x_min': x_info.min,
            'x_max': x_info.max,
            'y_min': y_info.min,
            'y_max': y_info.max,
            'left_edge': x_info.min + int(x_range * edge_percent),
            'right_edge': x_info.max - int(x_range * edge_percent),
            'top_edge': y_info.min + int(y_range * edge_percent),
            'bottom_edge': y_info.max - int(y_range * edge_percent)
        }

        log(f"Touchpad bounds: X={x_info.min}-{x_info.max}, Y={y_info.min}-{y_info.max}")
        log(f"Edge zones ({int(edge_percent*100)}%): left<{bounds['left_edge']}, right>{bounds['right_edge']}, top<{bounds['top_edge']}, bottom>{bounds['bottom_edge']}")

        return bounds
    except Exception as e:
        log(f"Warning: Could not get touchpad bounds: {e}")
        return None


def create_virtual_device():
    """Create virtual input device for scroll and click events."""
    capabilities = {
        ecodes.EV_REL: [
            ecodes.REL_WHEEL,
            ecodes.REL_WHEEL_HI_RES,
            ecodes.REL_HWHEEL,
            ecodes.REL_HWHEEL_HI_RES,
        ],
        ecodes.EV_KEY: [
            ecodes.BTN_MIDDLE,
        ]
    }
    return UInput(capabilities, name="GPD-Scroll Virtual Device")


def emit_scroll(ui, v_ticks, h_ticks, config):
    """Emit scroll events with correct direction handling."""
    if v_ticks != 0:
        # Apply direction: natural keeps sign, traditional inverts
        if config['direction'] == 'traditional':
            v_ticks = -v_ticks

        ui.write(ecodes.EV_REL, ecodes.REL_WHEEL, v_ticks)
        ui.write(ecodes.EV_REL, ecodes.REL_WHEEL_HI_RES, v_ticks * 120)

    if h_ticks != 0 and config['horizontal']:
        # Apply direction: natural keeps sign, traditional inverts
        if config['direction'] == 'traditional':
            h_ticks = -h_ticks

        ui.write(ecodes.EV_REL, ecodes.REL_HWHEEL, h_ticks)
        ui.write(ecodes.EV_REL, ecodes.REL_HWHEEL_HI_RES, h_ticks * 120)

    if v_ticks != 0 or (h_ticks != 0 and config['horizontal']):
        ui.syn()


def detect_edge_zone(x, y, bounds):
    """Returns list of edges finger is in, or None if in center."""
    if not bounds:
        return None
    edges = []
    if x <= bounds['left_edge']:
        edges.append('left')
    elif x >= bounds['right_edge']:
        edges.append('right')
    if y <= bounds['top_edge']:
        edges.append('top')
    elif y >= bounds['bottom_edge']:
        edges.append('bottom')
    return edges if edges else None


def calc_depth(pos, edge_start, edge_end):
    """Calculate how deep into edge zone (0.0 to 1.0)."""
    edge_size = abs(edge_end - edge_start)
    if edge_size == 0:
        return 0.0
    if edge_start < edge_end:
        depth = (pos - edge_start) / edge_size
    else:
        depth = (edge_start - pos) / edge_size
    return max(0.0, min(1.0, depth))


def calc_ticks(depth, config):
    """Calculate scroll ticks based on depth and sensitivity.

    Returns 1-3 ticks based on:
    - Base rate from sensitivity (higher sens = more ticks)
    - Depth multiplier (deeper = faster, 1x to 2x)
    """
    sensitivity = config['sensitivity']
    if sensitivity <= 0:
        sensitivity = 15  # Fallback to default
    base = 15 / sensitivity
    multiplier = 1.0 + depth
    ticks = int(base * multiplier)
    return max(1, min(3, ticks))


def reset_scroll_state():
    """Reset scroll tracking state."""
    global last_x, last_y, accum_x, accum_y
    last_x = None
    last_y = None
    accum_x = 0.0
    accum_y = 0.0


def reset_edge_state():
    """Reset edge scroll state."""
    global edge_enter_time, edge_scroll_active, current_edges
    global edge_last_x, edge_last_y
    edge_enter_time = None
    edge_scroll_active = False
    current_edges = None
    edge_last_x = None
    edge_last_y = None


def handle_edge_scroll(ui, x, y, config, bounds):
    """Handle edge scrolling logic.

    Returns True if edge scroll handled this event, False otherwise.
    """
    global edge_enter_time, edge_scroll_active, last_edge_scroll_time
    global current_edges, edge_last_x, edge_last_y

    # Detect which edges finger is in
    edges = detect_edge_zone(x, y, bounds)

    # Not in any edge - reset state
    if edges is None:
        reset_edge_state()
        return False

    # Just entered edge - start dwell timer
    if current_edges is None:
        edge_enter_time = time.time()
        current_edges = edges
        edge_scroll_active = False
        edge_last_x = x
        edge_last_y = y
        return False

    # Check if edges changed (e.g., top -> left) - reset dwell timer
    if set(current_edges) != set(edges):
        edge_enter_time = time.time()
        current_edges = edges
        edge_scroll_active = False
        edge_last_x = x
        edge_last_y = y
        return False

    # Still in dwell period - check for movement reset
    if not edge_scroll_active:
        movement = abs(x - edge_last_x) + abs(y - edge_last_y)
        if movement > 50:
            edge_enter_time = time.time()
            edge_last_x = x
            edge_last_y = y
            return False  # Don't proceed after reset

    # Check dwell time
    elapsed_ms = (time.time() - edge_enter_time) * 1000
    if elapsed_ms < config['edge_scroll_dwell']:
        return False

    # Dwell complete - activate scrolling
    if not edge_scroll_active:
        # First activation - reset normal scroll accumulators
        global accum_x, accum_y
        accum_x = 0.0
        accum_y = 0.0
    edge_scroll_active = True
    current_edges = edges

    # Rate limit to 20Hz
    now = time.time()
    if (now - last_edge_scroll_time) < 0.05:
        return True
    last_edge_scroll_time = now

    # Calculate scroll ticks
    v_ticks = 0
    h_ticks = 0

    if 'top' in edges:
        depth = calc_depth(y, bounds['top_edge'], bounds['y_min'])
        v_ticks = -calc_ticks(depth, config)
    elif 'bottom' in edges:
        depth = calc_depth(y, bounds['bottom_edge'], bounds['y_max'])
        v_ticks = calc_ticks(depth, config)

    if 'left' in edges and config['horizontal']:
        depth = calc_depth(x, bounds['left_edge'], bounds['x_min'])
        h_ticks = -calc_ticks(depth, config)
    elif 'right' in edges and config['horizontal']:
        depth = calc_depth(x, bounds['right_edge'], bounds['x_max'])
        h_ticks = calc_ticks(depth, config)

    # Emit scroll (emit_scroll handles direction inversion)
    if v_ticks != 0 or h_ticks != 0:
        emit_scroll(ui, v_ticks, h_ticks, config)

    return True


def shutdown(signum, frame):
    """Clean shutdown handler."""
    log("Shutting down...")

    # Ungrab touchpad
    if touchpad_dev:
        try:
            touchpad_dev.ungrab()
            log("Released touchpad grab")
        except OSError as e:
            log(f"Warning: Could not release touchpad grab: {e}")
        except AttributeError:
            pass  # Device doesn't have ungrab method
        try:
            touchpad_dev.close()
        except (OSError, AttributeError):
            pass

    # Ungrab mouse
    if mouse_dev:
        try:
            mouse_dev.ungrab()
            log("Released mouse grab")
        except OSError as e:
            log(f"Warning: Could not release mouse grab: {e}")
        except AttributeError:
            pass  # Device doesn't have ungrab method
        try:
            mouse_dev.close()
        except (OSError, AttributeError):
            pass

    if ui_device:
        try:
            ui_device.close()
        except (OSError, AttributeError):
            pass

    sys.exit(0)


def main():
    global mouse_dev, touchpad_dev, ui_device, edge_bounds
    global middle_held, finger_down, touchpad_grabbed, mouse_grabbed, scroll_movement_detected, last_x, last_y, accum_x, accum_y

    log("Starting daemon v1.2.0...")

    # Set up signal handlers
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # Load configuration
    config = load_config()
    h_status = "true" if config['horizontal'] else "false"
    log(f"Config: direction={config['direction']}, horizontal={h_status}, sensitivity={config['sensitivity']}")
    log(f"Config: dead_zone={config['dead_zone']}, pointer_lock={config['pointer_lock']}, middle_button={config['middle_button']}")
    log(f"Config: edge_scroll={config['edge_scroll_enabled']}, zone={config['edge_scroll_zone']}, dwell={config['edge_scroll_dwell']}ms")

    # Find ALPS devices
    mouse_dev, touchpad_dev = find_alps_devices()

    if not mouse_dev:
        log("ERROR: Could not find ALPS Mouse device")
        if touchpad_dev:
            touchpad_dev.close()
        sys.exit(1)

    if not touchpad_dev:
        log("ERROR: Could not find ALPS Touchpad device")
        if mouse_dev:
            mouse_dev.close()
        sys.exit(1)

    log(f"Found Mouse: {mouse_dev.path} ({mouse_dev.name})")
    log(f"Found Touchpad: {touchpad_dev.path} ({touchpad_dev.name})")

    # Initialize edge scroll bounds if enabled
    edge_bounds = None
    if config.get('edge_scroll_enabled', False):
        edge_bounds = get_touchpad_bounds(touchpad_dev, config['edge_scroll_zone'])
        if edge_bounds:
            log(f"Edge scroll enabled: dwell={config['edge_scroll_dwell']}ms")
        else:
            log("Warning: Edge scroll enabled but could not get touchpad bounds")

    # Create virtual scroll device
    try:
        ui_device = create_virtual_device()
        log("Created virtual scroll device")
    except Exception as e:
        log(f"ERROR: Could not create virtual device: {e}")
        log("")
        log("=== uinput Debug ===")
        log(f"uinput exists: {os.path.exists('/dev/uinput')}")
        log(f"uinput readable: {os.access('/dev/uinput', os.R_OK)}")
        log(f"uinput writable: {os.access('/dev/uinput', os.W_OK)}")
        log("")
        log("FIX: Try these commands:")
        log("  1. sudo modprobe uinput")
        log("  2. sudo udevadm control --reload-rules && sudo udevadm trigger")
        log("  3. Ensure user is in 'input' group, then log out/in")
        sys.exit(1)

    log("Ready. Hold middle button + move touchpad to scroll.")

    # Grab mouse at startup if not native mode (to intercept middle-click)
    if config['middle_button'] != 'native':
        try:
            mouse_dev.grab()
            mouse_grabbed = True
            log(f"Mouse grabbed for {config['middle_button']} mode")
        except OSError as e:
            log(f"Warning: Could not grab mouse: {e}")
            log("Middle-button interception may not work correctly")

    # Build device dict for select()
    devices = {
        mouse_dev.fd: mouse_dev,
        touchpad_dev.fd: touchpad_dev
    }

    # Pending position values (touchpad sends X and Y in separate events)
    pending_x = None
    pending_y = None

    try:
        while True:
            r, _, _ = select.select(devices.keys(), [], [], 0.1)

            for fd in r:
                dev = devices[fd]
                is_mouse = "Mouse" in dev.name

                for event in dev.read():
                    # Skip sync events
                    if event.type == ecodes.EV_SYN:
                        # Process any pending position on sync
                        if middle_held and (pending_x is not None or pending_y is not None):
                            new_x = pending_x if pending_x is not None else last_x
                            new_y = pending_y if pending_y is not None else last_y

                            if new_x is not None and new_y is not None:
                                # Check edge scroll first (if enabled and bounds available)
                                edge_handled = False
                                if config.get('edge_scroll_enabled') and edge_bounds:
                                    edge_handled = handle_edge_scroll(ui_device, new_x, new_y, config, edge_bounds)
                                    if edge_handled:
                                        scroll_movement_detected = True

                                # Normal scroll (skip if edge scroll is active)
                                if not edge_handled and last_x is not None and last_y is not None:
                                    delta_x = new_x - last_x
                                    delta_y = new_y - last_y

                                    # Dead zone: ignore tiny movements (configurable)
                                    dead_zone = config['dead_zone']
                                    if dead_zone == 0 or abs(delta_x) >= dead_zone or abs(delta_y) >= dead_zone:
                                        accum_x += delta_x
                                        accum_y += delta_y
                                        scroll_movement_detected = True  # Track that user moved while holding

                                        sensitivity = config['sensitivity']

                                        # Emit vertical scroll
                                        if abs(accum_y) >= sensitivity:
                                            scroll_ticks = int(accum_y / sensitivity)
                                            emit_scroll(ui_device, scroll_ticks, 0, config)
                                            accum_y -= scroll_ticks * sensitivity

                                        # Emit horizontal scroll
                                        if abs(accum_x) >= sensitivity and config['horizontal']:
                                            h_scroll_ticks = int(accum_x / sensitivity)
                                            emit_scroll(ui_device, 0, h_scroll_ticks, config)
                                            accum_x -= h_scroll_ticks * sensitivity

                                last_x = new_x
                                last_y = new_y

                            pending_x = None
                            pending_y = None
                        continue

                    # Key/Button events
                    if event.type == ecodes.EV_KEY:
                        # Middle button from mouse device
                        if is_mouse and event.code == ecodes.BTN_MIDDLE:
                            if event.value == 1:  # Press
                                middle_held = True
                                scroll_movement_detected = False  # Reset movement tracking

                                # Grab touchpad if pointer lock enabled
                                if config['pointer_lock'] and not touchpad_grabbed:
                                    try:
                                        touchpad_dev.grab()
                                        touchpad_grabbed = True
                                    except OSError as e:
                                        log(f"Warning: Could not grab touchpad: {e}")
                            elif event.value == 0:  # Release
                                middle_held = False

                                # Handle middle-click based on config
                                if config['middle_button'] == 'smart' and not scroll_movement_detected:
                                    # User tapped without moving - inject synthetic middle-click
                                    try:
                                        ui_device.write(ecodes.EV_KEY, ecodes.BTN_MIDDLE, 1)
                                        ui_device.syn()
                                        ui_device.write(ecodes.EV_KEY, ecodes.BTN_MIDDLE, 0)
                                        ui_device.syn()
                                    except OSError as e:
                                        log(f"Warning: Could not inject middle-click: {e}")
                                # 'block' mode: don't inject anything
                                # 'native' mode: mouse wasn't grabbed, so click already went through

                                reset_scroll_state()
                                reset_edge_state()
                                scroll_movement_detected = False

                                # Ungrab touchpad
                                if config['pointer_lock'] and touchpad_grabbed:
                                    try:
                                        touchpad_dev.ungrab()
                                        touchpad_grabbed = False
                                    except OSError as e:
                                        log(f"Warning: Failed to ungrab touchpad: {e}")

                        # Finger touch from touchpad device
                        elif not is_mouse and event.code == ecodes.BTN_TOUCH:
                            if event.value == 1:  # Finger down
                                finger_down = True
                            elif event.value == 0:  # Finger up
                                finger_down = False
                                if middle_held:
                                    reset_scroll_state()
                                    reset_edge_state()

                    # Absolute position events (touchpad)
                    elif event.type == ecodes.EV_ABS and not is_mouse:
                        if event.code == ecodes.ABS_X:
                            pending_x = event.value
                        elif event.code == ecodes.ABS_Y:
                            pending_y = event.value

    except KeyboardInterrupt:
        shutdown(None, None)
    except Exception as e:
        log(f"ERROR: Unexpected error: {e}")
        log("")
        log("=== Debug Info ===")
        log(f"Exception type: {type(e).__name__}")
        log(f"Traceback: {traceback.format_exc()}")
        log("")
        log("Please report this error at:")
        log("  https://github.com/Loui2/gpd-micropc2-linux-scroll/issues")
        shutdown(None, None)


if __name__ == "__main__":
    main()
DAEMON_EOF
    chmod +x "$DAEMON_PATH"
}

install_service() {
    local python_path
    python_path=$(command -v python3)

    mkdir -p "$HOME/.config/systemd/user"
    cat > "$SERVICE_PATH" << SERVICE_EOF
[Unit]
Description=GPD MicroPC 2 Middle-Button Scroll Daemon
After=graphical-session.target

[Service]
Type=exec
ExecStart=${python_path} %h/.local/bin/gpd-scroll-daemon.py
Restart=on-failure
RestartSec=10
StartLimitBurst=3
StartLimitIntervalSec=60
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
SERVICE_EOF
}

install_udev_rule() {
    echo "# GPD MicroPC 2 Scroll Daemon - uinput permissions" | sudo tee "$UDEV_RULE_PATH" > /dev/null
    echo "# Allows users in 'input' group to create virtual input devices" | sudo tee -a "$UDEV_RULE_PATH" > /dev/null
    echo 'KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input"' | sudo tee -a "$UDEV_RULE_PATH" > /dev/null
    sudo udevadm control --reload-rules
    sudo udevadm trigger
}

write_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_PATH" << EOF
# GPD MicroPC 2 Scroll Configuration
# ====================================
#
# After editing, restart the service:
#   systemctl --user restart gpd-scroll
#
# View logs:
#   journalctl --user -u gpd-scroll -f
#
# ====================================

# SCROLL_DIRECTION
# ----------------
# Controls scroll direction when moving finger
# Options:
#   natural     - Content follows finger (like macOS/mobile)
#   traditional - Scroll bar follows finger (like Windows)
SCROLL_DIRECTION=$SCROLL_DIRECTION

# HORIZONTAL_SCROLL
# -----------------
# Enable left/right scrolling
# Options: true, false
HORIZONTAL_SCROLL=$HORIZONTAL_SCROLL

# SENSITIVITY
# -----------
# Touchpad movement needed per scroll tick
# Options:
#   low    - Slowest, most precise (30px per tick)
#   medium - Balanced, recommended (15px per tick)
#   high   - Fastest scrolling (8px per tick)
SENSITIVITY=$SENSITIVITY

# DEAD_ZONE
# ---------
# Minimum movement to register (filters jitter)
# Options:
#   none    - No filtering, most responsive (0px)
#   low     - Minimal filtering (2px)
#   default - Recommended balance (5px)
#   high    - Strong filtering (10px)
DEAD_ZONE=$DEAD_ZONE

# POINTER_LOCK
# ------------
# Freeze mouse pointer while scrolling
# Prevents accidentally moving focus to other windows
# Options: true, false
POINTER_LOCK=$POINTER_LOCK

# MIDDLE_BUTTON
# -------------
# Behavior when tapping middle button (without scrolling)
# Options:
#   smart  - Tap = normal click, Hold+move = scroll only
#   block  - Disable middle-click entirely
#   native - No interception (may click while scrolling)
MIDDLE_BUTTON=$MIDDLE_BUTTON

# EDGE_SCROLL_ENABLED
# -------------------
# Enable phone-style continuous edge scrolling
# When finger dwells at touchpad edge while middle button held,
# continuous scrolling begins based on depth into edge zone
# All four edges work: top/bottom=vertical, left/right=horizontal
# Options: true, false
EDGE_SCROLL_ENABLED=$EDGE_SCROLL_ENABLED

# EDGE_SCROLL_ZONE
# ----------------
# Size of edge zones as percentage of touchpad dimensions
# Larger zones are easier to hit but reduce center scroll area
# Options:
#   small  - 20% of touchpad (narrow edges)
#   medium - 25% of touchpad (balanced, recommended)
#   large  - 30% of touchpad (wide edges)
EDGE_SCROLL_ZONE=$EDGE_SCROLL_ZONE

# EDGE_SCROLL_DWELL
# -----------------
# Time in milliseconds finger must stay at edge before
# continuous scrolling activates (prevents accidental triggers)
# Options: 100-1000 (default: 300)
EDGE_SCROLL_DWELL=$EDGE_SCROLL_DWELL
EOF
}

# ============================================================================
# UI FUNCTIONS
# ============================================================================

show_banner() {
    echo ""
    echo "================================================================"
    echo "  GPD MicroPC 2 - Middle-Button Scroll Installer v$VERSION"
    echo "  Author: Loui2 | License: MIT"
    echo "================================================================"
    echo ""
}

show_help() {
    show_banner
    echo "USAGE:"
    echo "  ./setup-middle-scroll.sh                Interactive install"
    echo "  ./setup-middle-scroll.sh --help, -h     Show this help"
    echo "  ./setup-middle-scroll.sh --version, -v  Show version"
    echo "  ./setup-middle-scroll.sh --status, -s   Show current status"
    echo "  ./setup-middle-scroll.sh --remove, -r   Uninstall"
    echo "  ./setup-middle-scroll.sh --reconfigure  Change scroll settings"
    echo ""
    echo "WHAT THIS SCRIPT DOES:"
    echo "  This installs a background service that enables scroll functionality"
    echo "  using the middle mouse button + touchpad:"
    echo ""
    echo "  - Hold middle button + move finger UP/DOWN = Vertical scroll"
    echo "  - Hold middle button + move finger LEFT/RIGHT = Horizontal scroll"
    echo ""
    echo "HOW IT WORKS:"
    echo "  The GPD MicroPC 2 has a hardware quirk where the middle button and"
    echo "  touchpad are separate devices, preventing built-in scroll from working."
    echo "  This script installs a daemon that bridges the two devices."
    echo ""
    echo "COMPATIBILITY:"
    echo "  - OS: Arch Linux (uses pacman for python-evdev)"
    echo "  - Desktop: Any Linux desktop (tested: KDE Plasma Wayland)"
    echo "  - Other distros: May work if you manually install python-evdev"
    echo ""
}

show_version() {
    echo "GPD MicroPC 2 Middle-Button Scroll Installer v$VERSION"
}

show_status() {
    echo "GPD MicroPC 2 Scroll Daemon Status"
    echo "=================================="
    echo ""

    # Service status
    echo "Service:"
    if systemctl --user is-active gpd-scroll.service &>/dev/null; then
        echo -e "  ${GREEN}● gpd-scroll.service - active (running)${NC}"
        systemctl --user status gpd-scroll.service --no-pager 2>/dev/null | grep -E "Active:|Main PID:" | sed 's/^/  /'
    elif systemctl --user is-enabled gpd-scroll.service &>/dev/null; then
        echo -e "  ${YELLOW}○ gpd-scroll.service - inactive (not running)${NC}"
    else
        echo -e "  ${RED}○ gpd-scroll.service - not installed${NC}"
    fi
    echo ""

    # Config
    if [[ -f "$CONFIG_PATH" ]]; then
        echo "Configuration ($CONFIG_PATH):"
        cat "$CONFIG_PATH" | grep -v "^#" | grep -v "^$" | sed 's/^/  /'
    else
        echo "Configuration: Not found"
    fi
    echo ""

    # Dependencies
    echo "Dependencies:"
    if python3 -c "import evdev" 2>/dev/null; then
        echo -e "  ${GREEN}✓ python-evdev installed${NC}"
    else
        echo -e "  ${RED}✗ python-evdev NOT installed${NC}"
    fi
    echo ""

    # User permissions
    echo "Permissions:"
    if groups | grep -q "\binput\b"; then
        echo -e "  ${GREEN}✓ User in 'input' group${NC}"
    else
        echo -e "  ${YELLOW}! User NOT in 'input' group${NC}"
    fi
    echo ""

    # Recent logs
    echo "Recent logs:"
    journalctl --user -u gpd-scroll -n 5 --no-pager 2>/dev/null | sed 's/^/  /' || echo "  No logs available"
}

prompt_preferences() {
    echo "┌─ SCROLL PREFERENCES ─────────────────────────────────────────┐"
    echo ""

    # 1. Scroll Direction
    echo "1. Scroll Direction"
    echo "   Controls which way content moves when you drag your finger:"
    echo "   - Natural: Drag down → content moves down (like a phone touchscreen)"
    echo "   - Traditional: Drag down → content moves up (like dragging a scrollbar)"
    echo ""
    echo "   Applies to both vertical and horizontal scrolling."
    echo ""
    read -p "   Choose [N]atural or [T]raditional (default: Natural): " dir_choice
    case "$dir_choice" in
        [Tt]*)
            SCROLL_DIRECTION="traditional"
            ;;
        *)
            SCROLL_DIRECTION="natural"
            ;;
    esac
    echo ""

    # 2. Horizontal Scrolling
    echo "2. Horizontal Scrolling"
    echo "   Allow left/right scrolling when moving finger horizontally."
    echo "   When disabled, horizontal finger movement is ignored entirely."
    echo ""
    read -p "   Enable horizontal scroll? [Y/n] (default: Yes): " h_choice
    case "$h_choice" in
        [Nn]*)
            HORIZONTAL_SCROLL="false"
            ;;
        *)
            HORIZONTAL_SCROLL="true"
            ;;
    esac
    echo ""

    # 3. Scroll Sensitivity
    echo "3. Scroll Sensitivity"
    echo "   Pixels of finger movement required to trigger one scroll tick:"
    echo "   - Low (30px): More finger movement per tick - precise, slower scrolling"
    echo "   - Medium (15px): Balanced movement per tick (recommended)"
    echo "   - High (8px): Less finger movement per tick - faster scrolling"
    echo ""
    echo "   Lower px value = faster scrolling. Higher px value = more control."
    echo ""
    read -p "   Choose [L]ow, [M]edium, or [H]igh (default: Medium): " sens_choice
    case "$sens_choice" in
        [Ll]*)
            SENSITIVITY="low"
            ;;
        [Hh]*)
            SENSITIVITY="high"
            ;;
        *)
            SENSITIVITY="medium"
            ;;
    esac
    echo ""

    # 4. Dead Zone
    echo "4. Dead Zone"
    echo "   Minimum movement required before scrolling registers."
    echo "   Filters out small unintentional movements (jitter/tremor)."
    echo "   - None (0px): All movement registers - most responsive"
    echo "   - Low (2px): Minimal filtering"
    echo "   - Default (5px): Filters typical touchpad noise"
    echo "   - High (10px): Strong filtering - good for shaky hands"
    echo ""
    read -p "   Choose [N]one, [L]ow, [D]efault, or [H]igh (default: Default): " dz_choice
    case "$dz_choice" in
        [Nn]*)
            DEAD_ZONE="none"
            ;;
        [Ll]*)
            DEAD_ZONE="low"
            ;;
        [Hh]*)
            DEAD_ZONE="high"
            ;;
        *)
            DEAD_ZONE="default"
            ;;
    esac
    echo ""

    # 5. Pointer Lock
    echo "5. Pointer Lock"
    echo "   Freeze mouse cursor position while scrolling."
    echo "   - Yes: Cursor stays still - prevents losing window focus or clicking accidentally"
    echo "   - No: Cursor moves with your finger while scrolling"
    echo ""
    read -p "   Lock pointer while scrolling? [Y/n] (default: Yes): " pl_choice
    case "$pl_choice" in
        [Nn]*)
            POINTER_LOCK="false"
            ;;
        *)
            POINTER_LOCK="true"
            ;;
    esac
    echo ""

    # 6. Middle Button Behavior
    echo "6. Middle Button Behavior"
    echo "   How to handle middle-click while the scroll daemon is running:"
    echo "   - Smart: Quick tap = middle-click, hold + move = scroll only"
    echo "   - Block: Disable middle-click entirely (scroll only)"
    echo "   - Native: Don't intercept - both middle-click and scroll may trigger"
    echo ""
    echo "   Smart mode detects if you moved your finger before releasing."
    echo ""
    read -p "   Choose [S]mart, [B]lock, or [N]ative (default: Smart): " mb_choice
    case "$mb_choice" in
        [Bb]*)
            MIDDLE_BUTTON="block"
            ;;
        [Nn]*)
            MIDDLE_BUTTON="native"
            ;;
        *)
            MIDDLE_BUTTON="smart"
            ;;
    esac
    echo ""

    # 7. Edge Scrolling
    echo "7. Edge Scrolling"
    echo "   Enable auto-scroll zones at touchpad edges."
    echo "   Hold your finger at an edge to scroll continuously:"
    echo "   - Top/bottom edges: vertical scroll (speed increases deeper into edge)"
    echo "   - Left/right edges: horizontal scroll (if horizontal enabled)"
    echo ""
    echo "   Requires brief pause (dwell) before activating to prevent accidental triggers."
    echo ""
    read -p "   Enable edge scrolling? [y/N] (default: No): " edge_choice
    case "$edge_choice" in
        [Yy]*)
            EDGE_SCROLL_ENABLED="true"

            # 7a. Zone size
            echo ""
            echo "   7a. Edge Zone Size"
            echo "       How much of the touchpad is designated as edge zones:"
            echo "       - Small (20%): Narrow edge strips - more center space for normal scroll"
            echo "       - Medium (25%): Balanced zone size"
            echo "       - Large (30%): Wider edges - easier to hit but less center space"
            echo ""
            read -p "       Choose [S]mall, [M]edium, or [L]arge (default: Medium): " zone_choice
            case "$zone_choice" in
                [Ss]*)
                    EDGE_SCROLL_ZONE="small"
                    ;;
                [Ll]*)
                    EDGE_SCROLL_ZONE="large"
                    ;;
                *)
                    EDGE_SCROLL_ZONE="medium"
                    ;;
            esac

            # 7b. Dwell time
            echo ""
            echo "   7b. Edge Dwell Time"
            echo "       How long finger must stay at edge before auto-scroll activates:"
            echo "       - Fast (200ms): Quick activation - more responsive"
            echo "       - Medium (300ms): Balanced timing"
            echo "       - Slow (500ms): Longer wait - prevents accidental triggers"
            echo ""
            echo "       Moving >50px during dwell resets the timer."
            echo ""
            read -p "       Choose [F]ast, [M]edium, or [S]low (default: Medium): " dwell_choice
            case "$dwell_choice" in
                [Ff]*|[Ll]*)  # Accept F(ast) or L(ow) for backward compatibility
                    EDGE_SCROLL_DWELL="200"
                    ;;
                [Ss]*|[Hh]*)  # Accept S(low) or H(igh) for backward compatibility
                    EDGE_SCROLL_DWELL="500"
                    ;;
                *)
                    EDGE_SCROLL_DWELL="300"
                    ;;
            esac
            ;;
        *)
            EDGE_SCROLL_ENABLED="false"
            ;;
    esac

    echo "└───────────────────────────────────────────────────────────────┘"
    echo ""
}

show_summary() {
    local h_display="Enabled"
    [[ "$HORIZONTAL_SCROLL" == "false" ]] && h_display="Disabled"
    local dir_display="${SCROLL_DIRECTION^}"

    # Add numeric values to sensitivity display
    local sens_display="${SENSITIVITY^}"
    case "$SENSITIVITY" in
        low) sens_display="Low (30px)" ;;
        medium) sens_display="Medium (15px)" ;;
        high) sens_display="High (8px)" ;;
    esac

    # Add numeric values to dead zone display
    local dz_display="${DEAD_ZONE^}"
    case "$DEAD_ZONE" in
        none) dz_display="None (0px)" ;;
        low) dz_display="Low (2px)" ;;
        default) dz_display="Default (5px)" ;;
        high) dz_display="High (10px)" ;;
    esac

    local pl_display="Enabled"
    [[ "$POINTER_LOCK" == "false" ]] && pl_display="Disabled"
    local mb_display="${MIDDLE_BUTTON^}"

    # Add numeric values to edge scroll display
    local edge_display="Disabled"
    if [[ "$EDGE_SCROLL_ENABLED" == "true" ]]; then
        local zone_pct="25%"  # Default fallback for invalid values
        case "$EDGE_SCROLL_ZONE" in
            small) zone_pct="20%" ;;
            medium) zone_pct="25%" ;;
            large) zone_pct="30%" ;;
        esac
        edge_display="Enabled (${zone_pct} zone, ${EDGE_SCROLL_DWELL}ms dwell)"
    fi

    echo "┌─ SUMMARY ────────────────────────────────────────────────────┐"
    echo "│ Direction:     $dir_display"
    echo "│ Horizontal:    $h_display"
    echo "│ Sensitivity:   $sens_display"
    echo "│ Dead Zone:     $dz_display"
    echo "│ Pointer Lock:  $pl_display"
    echo "│ Middle Button: $mb_display"
    echo "│ Edge Scroll:   $edge_display"
    echo "│"
    echo "│ Files to create:"
    echo "│   ~/.local/bin/gpd-scroll-daemon.py"
    echo "│   ~/.config/gpd-scroll/config"
    echo "│   ~/.config/systemd/user/gpd-scroll.service"
    echo "│   /etc/udev/rules.d/99-gpd-scroll.rules (requires sudo)"
    echo "└───────────────────────────────────────────────────────────────┘"
    echo ""
}

# ============================================================================
# MAIN OPERATIONS
# ============================================================================

do_install() {
    # Track installation state for cleanup on failure
    local INSTALL_STARTED=false
    local INSTALL_COMPLETE=false

    cleanup_on_error() {
        local exit_code=$?
        if [[ "$INSTALL_STARTED" == "true" && "$INSTALL_COMPLETE" != "true" ]]; then
            echo ""
            echo -e "${YELLOW}Installation failed, cleaning up...${NC}"

            # Stop service if it was started
            systemctl --user stop gpd-scroll.service 2>/dev/null || true
            systemctl --user disable gpd-scroll.service 2>/dev/null || true

            # Remove files we created
            [[ -f "$DAEMON_PATH" ]] && rm -f "$DAEMON_PATH" && echo "  Removed: $DAEMON_PATH"
            [[ -f "$SERVICE_PATH" ]] && rm -f "$SERVICE_PATH" && echo "  Removed: $SERVICE_PATH"
            [[ -f "$CONFIG_PATH" ]] && rm -f "$CONFIG_PATH" && echo "  Removed: $CONFIG_PATH"
            [[ -d "$CONFIG_DIR" ]] && rmdir "$CONFIG_DIR" 2>/dev/null && echo "  Removed: $CONFIG_DIR"

            # Remove udev rule if it was created
            if [[ -f "$UDEV_RULE_PATH" ]]; then
                sudo rm -f "$UDEV_RULE_PATH" 2>/dev/null && echo "  Removed: $UDEV_RULE_PATH"
                sudo udevadm control --reload-rules 2>/dev/null || true
            fi

            systemctl --user daemon-reload 2>/dev/null || true
            echo ""
            echo "Cleanup complete. You can try running the installer again."
        fi
        exit $exit_code
    }
    trap cleanup_on_error EXIT ERR INT

    show_banner

    echo "WHAT THIS SCRIPT DOES:"
    echo "  This installs a background service that enables scroll functionality"
    echo "  using the middle mouse button + touchpad:"
    echo ""
    echo "  - Hold middle button + move finger UP/DOWN = Vertical scroll"
    echo "  - Hold middle button + move finger LEFT/RIGHT = Horizontal scroll"
    echo ""
    echo "HOW IT WORKS:"
    echo "  The GPD MicroPC 2 has a hardware quirk where the middle button and"
    echo "  touchpad are separate devices, preventing built-in scroll from working."
    echo "  This script installs a daemon that bridges the two devices."
    echo ""
    echo "COMPATIBILITY:"
    echo "  - OS: Arch Linux (uses pacman for python-evdev)"
    echo "  - Desktop: Any Linux desktop (tested: KDE Plasma Wayland)"
    echo "  - Other distros: May work if you manually install python-evdev"
    echo ""
    echo "FILES THAT WILL BE CREATED:"
    echo "  ~/.local/bin/gpd-scroll-daemon.py         (scroll daemon)"
    echo "  ~/.config/gpd-scroll/config               (your preferences)"
    echo "  ~/.config/systemd/user/gpd-scroll.service (auto-start service)"
    echo "  /etc/udev/rules.d/99-gpd-scroll.rules     (device permissions)"
    echo ""
    echo "================================================================"
    echo ""

    # Check for existing installation
    if systemctl --user is-active gpd-scroll.service &>/dev/null; then
        echo -e "${GREEN}GPD Scroll is already installed and running.${NC}"
        echo ""
        echo "Options:"
        echo "  --reconfigure  Change scroll settings"
        echo "  --remove       Uninstall completely"
        echo "  --status       View current status"
        exit 0
    fi

    # Hardware check
    echo -n "Checking hardware... "
    if grep -qE "G1688|GPD.*MicroPC" /sys/class/dmi/id/product_name 2>/dev/null; then
        echo -e "${GREEN}GPD MicroPC 2 detected ✓${NC}"
    else
        echo -e "${YELLOW}GPD MicroPC 2 not detected${NC}"
        echo ""
        echo "Warning: This script is designed for GPD MicroPC 2 (G1688-08)."
        read -p "Continue anyway? [y/N]: " answer
        if [[ ! "$answer" =~ ^[Yy] ]]; then
            exit 0
        fi
    fi

    # Check for Python 3
    echo -n "Checking Python 3... "
    if ! command -v python3 &>/dev/null; then
        echo -e "${RED}not found${NC}"
        echo ""
        echo "Python 3 is required but not installed."
        print_debug_report
        echo ""
        echo "=== Fix ==="
        echo "Install Python 3:"
        echo "  Arch:   sudo pacman -S python"
        echo "  Debian: sudo apt install python3"
        echo "  Fedora: sudo dnf install python3"
        exit 1
    fi
    echo -e "${GREEN}$(python3 --version)${NC}"

    # Dependency check
    echo -n "Checking python-evdev... "
    if python3 -c "import evdev" 2>/dev/null; then
        echo -e "${GREEN}python-evdev ✓${NC}"
    else
        echo -e "${RED}python-evdev not found${NC}"
        echo ""
        echo "This script requires 'python-evdev' to read input devices."
        read -p "Install python-evdev via pacman? [Y/n]: " answer
        if [[ "$answer" =~ ^[Nn] ]]; then
            echo ""
            echo "Manual installation options:"
            echo "  Arch Linux:  sudo pacman -S python-evdev"
            echo "  Fedora:      sudo dnf install python3-evdev"
            echo "  Ubuntu:      sudo apt install python3-evdev"
            echo "  pip:         pip install evdev"
            echo ""
            echo "After installing, run this script again."
            exit 0
        fi
        if ! sudo pacman -S --noconfirm python-evdev; then
            echo ""
            echo -e "${RED}Error: Failed to install python-evdev.${NC}"
            print_debug_report
            echo ""
            echo "=== Fix ==="
            echo "Install python-evdev manually:"
            echo "  Arch:   sudo pacman -S python-evdev"
            echo "  Debian: sudo apt install python3-evdev"
            echo "  Fedora: sudo dnf install python3-evdev"
            echo "  pip:    pip install evdev"
            exit 1
        fi
    fi

    # User group check
    echo -n "Checking user permissions... "
    if groups | grep -q "\binput\b"; then
        echo -e "${GREEN}User is in 'input' group ✓${NC}"
    else
        echo -e "${YELLOW}User is not in 'input' group${NC}"
        echo ""
        echo "Warning: You may need to add yourself to the 'input' group:"
        echo "  sudo usermod -aG input \$USER"
        echo "Then log out and back in."
        read -p "Continue anyway? [y/N]: " answer
        if [[ ! "$answer" =~ ^[Yy] ]]; then
            exit 0
        fi
    fi

    # Check/load uinput kernel module
    echo -n "Checking uinput kernel module... "
    if ! lsmod | grep -q "^uinput"; then
        echo -e "${YELLOW}not loaded${NC}"
        echo -n "  Loading uinput module... "
        if ! sudo modprobe uinput; then
            echo -e "${RED}failed${NC}"
            echo "Error: Could not load uinput module."
            print_debug_report
            echo ""
            echo "=== Fix ==="
            echo "Try: sudo modprobe uinput"
            echo "If that fails, uinput may need to be compiled into your kernel."
            exit 1
        fi
        echo -e "${GREEN}loaded${NC}"
    else
        echo -e "${GREEN}loaded${NC}"
    fi

    # Ensure uinput loads at boot
    if [[ ! -f /etc/modules-load.d/uinput.conf ]]; then
        echo -n "Configuring uinput to load at boot... "
        echo "uinput" | sudo tee /etc/modules-load.d/uinput.conf > /dev/null
        echo -e "${GREEN}done${NC}"
    fi

    echo ""

    # Preferences
    prompt_preferences

    # Summary and confirmation
    show_summary

    read -p "Proceed with installation? [Y/n]: " answer
    if [[ "$answer" =~ ^[Nn] ]]; then
        echo "Installation cancelled."
        exit 0
    fi

    echo ""
    echo "Installing..."
    echo ""

    # Step 1: Config directory
    echo -n "[1/6] Creating config directory... "
    mkdir -p "$CONFIG_DIR"
    INSTALL_STARTED=true
    echo -e "${GREEN}✓${NC}"

    # Step 2: Write config
    echo -n "[2/6] Writing configuration... "
    write_config
    echo -e "${GREEN}✓${NC}"

    # Step 3: Install daemon
    echo -n "[3/6] Installing scroll daemon... "
    install_daemon
    echo -e "${GREEN}✓${NC}"

    # Step 4: Udev rule
    echo -n "[4/6] Creating udev rule (sudo required)... "
    install_udev_rule
    echo -e "${GREEN}✓${NC}"

    # Step 5: Systemd service
    echo -n "[5/6] Installing systemd service... "
    install_service
    echo -e "${GREEN}✓${NC}"

    # Step 6: Start service
    echo -n "[6/6] Starting service... "
    systemctl --user daemon-reload
    systemctl --user enable gpd-scroll.service
    systemctl --user start gpd-scroll.service

    # Verify service started (wait up to 5 seconds)
    for i in {1..10}; do
        if systemctl --user is-active gpd-scroll.service &>/dev/null; then
            break
        fi
        sleep 0.5
    done
    if ! systemctl --user is-active gpd-scroll.service &>/dev/null; then
        echo -e "${RED}failed${NC}"
        echo ""
        echo "Service failed to start."
        print_debug_report
        echo ""
        echo "=== Common Fixes ==="
        echo "1. Add to input group: sudo usermod -aG input \$USER"
        echo "   Then LOG OUT and back in (required for group changes)"
        echo "2. Reload udev: sudo udevadm control --reload-rules && sudo udevadm trigger"
        echo "3. Report issue: https://github.com/Loui2/gpd-micropc2-linux-scroll/issues"
        exit 1
    fi
    echo -e "${GREEN}✓${NC}"

    # Mark installation complete and disable cleanup trap
    INSTALL_COMPLETE=true
    trap - EXIT ERR INT

    echo ""
    echo "================================================================"
    echo -e "${GREEN}✓ Installation complete!${NC}"
    echo ""
    echo "The scroll daemon is now running. Try it out:"
    echo "  - Hold the middle mouse button"
    echo "  - Move your finger on the touchpad to scroll"
    echo ""
    echo "USEFUL COMMANDS:"
    echo "  Check status:    $(basename "$0") --status"
    echo "  Change settings: $(basename "$0") --reconfigure"
    echo "  Uninstall:       $(basename "$0") --remove"
    echo "  View logs:       journalctl --user -u gpd-scroll -f"
    echo ""
    echo "ADVANCED:"
    echo "  Config file:     ~/.config/gpd-scroll/config"
    echo "                   Edit directly for custom values (e.g., SENSITIVITY=12)"
    echo "                   Then restart: systemctl --user restart gpd-scroll"
    echo "================================================================"
}

do_uninstall() {
    show_banner

    echo "This will remove:"
    echo "  - ~/.local/bin/gpd-scroll-daemon.py"
    echo "  - ~/.config/gpd-scroll/ (config directory)"
    echo "  - ~/.config/systemd/user/gpd-scroll.service"
    echo "  - /etc/udev/rules.d/99-gpd-scroll.rules"
    echo ""

    read -p "Are you sure you want to uninstall? [y/N]: " answer
    if [[ ! "$answer" =~ ^[Yy] ]]; then
        echo "Uninstall cancelled."
        exit 0
    fi

    echo ""
    echo "Uninstalling..."

    # Stop and disable service
    echo -n "[1/5] Stopping service... "
    systemctl --user stop gpd-scroll.service 2>/dev/null || true
    systemctl --user disable gpd-scroll.service 2>/dev/null || true
    echo -e "${GREEN}✓${NC}"

    # Remove daemon
    echo -n "[2/5] Removing daemon... "
    rm -f "$DAEMON_PATH"
    echo -e "${GREEN}✓${NC}"

    # Remove config
    echo -n "[3/5] Removing configuration... "
    rm -rf "$CONFIG_DIR"
    echo -e "${GREEN}✓${NC}"

    # Remove service file
    echo -n "[4/5] Removing service file... "
    rm -f "$SERVICE_PATH"
    systemctl --user daemon-reload
    echo -e "${GREEN}✓${NC}"

    # Remove udev rule
    echo -n "[5/5] Removing udev rule (sudo required)... "
    sudo rm -f "$UDEV_RULE_PATH"
    sudo udevadm control --reload-rules
    echo -e "${GREEN}✓${NC}"

    # Remove uinput boot config (optional - ask user)
    if [[ -f /etc/modules-load.d/uinput.conf ]]; then
        echo ""
        read -p "Remove uinput boot configuration? [y/N]: " remove_uinput
        if [[ "$remove_uinput" =~ ^[Yy] ]]; then
            sudo rm -f /etc/modules-load.d/uinput.conf
            echo "  Removed: /etc/modules-load.d/uinput.conf"
        fi
    fi

    echo ""
    echo -e "${GREEN}✓ Uninstall complete.${NC}"
}

do_reconfigure() {
    show_banner

    echo "Reconfiguring GPD Scroll..."
    echo ""

    # Check if installed
    if [[ ! -f "$SERVICE_PATH" ]]; then
        echo -e "${RED}Error: GPD Scroll is not installed.${NC}"
        echo "Run without arguments to install first."
        exit 1
    fi

    # Show current settings
    echo "Current Settings:"
    echo ""
    if [[ -f "$CONFIG_PATH" ]]; then
        local current_dir=$(grep '^SCROLL_DIRECTION=' "$CONFIG_PATH" 2>/dev/null | cut -d= -f2)
        local current_horiz=$(grep '^HORIZONTAL_SCROLL=' "$CONFIG_PATH" 2>/dev/null | cut -d= -f2)
        local current_sens=$(grep '^SENSITIVITY=' "$CONFIG_PATH" 2>/dev/null | cut -d= -f2)
        local current_dz=$(grep '^DEAD_ZONE=' "$CONFIG_PATH" 2>/dev/null | cut -d= -f2)
        local current_pl=$(grep '^POINTER_LOCK=' "$CONFIG_PATH" 2>/dev/null | cut -d= -f2)
        local current_mb=$(grep '^MIDDLE_BUTTON=' "$CONFIG_PATH" 2>/dev/null | cut -d= -f2)
        local current_edge=$(grep '^EDGE_SCROLL_ENABLED=' "$CONFIG_PATH" 2>/dev/null | cut -d= -f2)
        local current_edge_zone=$(grep '^EDGE_SCROLL_ZONE=' "$CONFIG_PATH" 2>/dev/null | cut -d= -f2)
        local current_edge_dwell=$(grep '^EDGE_SCROLL_DWELL=' "$CONFIG_PATH" 2>/dev/null | cut -d= -f2)

        echo "  Direction:     ${current_dir:-natural}"
        echo "  Horizontal:    ${current_horiz:-true}"
        echo "  Sensitivity:   ${current_sens:-medium}"
        echo "  Dead Zone:     ${current_dz:-default}"
        echo "  Pointer Lock:  ${current_pl:-true}"
        echo "  Middle Button: ${current_mb:-smart}"
        echo "  Edge Scroll:   ${current_edge:-false}"
        if [[ "${current_edge:-false}" == "true" ]]; then
            echo "    Zone:        ${current_edge_zone:-medium}"
            echo "    Dwell:       ${current_edge_dwell:-300}ms"
        fi
    else
        echo "  (No config file found - using defaults)"
    fi
    echo ""
    read -p "Change these settings? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn] ]] && { echo "Cancelled."; exit 0; }
    echo ""

    # Stop service
    systemctl --user stop gpd-scroll.service 2>/dev/null || true

    # Re-run preference prompts
    prompt_preferences

    # Write new config
    write_config

    # Re-extract daemon (in case script was updated with new features)
    install_daemon

    # Restart service
    systemctl --user start gpd-scroll.service

    echo ""
    echo -e "${GREEN}✓ Reconfiguration complete. Service restarted with new settings.${NC}"
}

# ============================================================================
# ENTRY POINT
# ============================================================================

case "${1:-}" in
    --help|-h)
        show_help
        ;;
    --version|-v)
        show_version
        ;;
    --status|-s)
        show_status
        ;;
    --remove|-r|--uninstall)
        do_uninstall
        ;;
    --reconfigure)
        do_reconfigure
        ;;
    "")
        do_install
        ;;
    *)
        echo "Unknown option: $1"
        echo "Run with --help for usage information."
        exit 1
        ;;
esac
