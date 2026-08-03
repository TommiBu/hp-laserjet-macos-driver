#!/bin/sh
#
# Install a LaunchDaemon that auto-uploads firmware when an HP LaserJet
# P100x is connected via USB.
#
# Usage: sudo ./install-hotplug.sh [MODEL]
#
#   MODEL is one of: P1005 P1006 P1007 P1008 P1505
#   If omitted, the script detects the connected printer over USB and
#   falls back to P1007.
#

set -e

FIRMWARE_DIR="/usr/local/share/foo2xqx/firmware"

# ── Model table ─────────────────────────────────────────────────────────────
# See install.sh for the source of these values (foo2zjs/hplj10xx.conf and
# foo2zjs/osx-hotplug/osx-hplj-hotplug.m). Vendor is 0x03f0 = 1008 decimal.
model_info() {
    case "$1" in
        P1005) USB_PID_DEC=15639; FW_BASE=sihpP1005 ;;   # 0x3d17
        P1006) USB_PID_DEC=15895; FW_BASE=sihpP1006 ;;   # 0x3e17
        P1007) USB_PID_DEC=18455; FW_BASE=sihpP1005 ;;   # 0x4817
        P1008) USB_PID_DEC=18711; FW_BASE=sihpP1006 ;;   # 0x4917
        P1505) USB_PID_DEC=16151; FW_BASE=sihpP1505 ;;   # 0x3f17
        *) return 1 ;;
    esac
    return 0
}

detect_model() {
    lpinfo -v 2>/dev/null \
        | grep -io 'P1[05][0-9][0-9]' \
        | tr '[:lower:]' '[:upper:]' \
        | head -1
}

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo."
    exit 1
fi

MODEL="$1"
if [ -z "$MODEL" ]; then
    MODEL=$(detect_model)
    if [ -n "$MODEL" ]; then
        echo "Detected printer: HP LaserJet $MODEL"
    else
        MODEL=P1007
        echo "No printer detected on USB, defaulting to $MODEL."
    fi
fi
MODEL=$(echo "$MODEL" | tr '[:lower:]' '[:upper:]')

if ! model_info "$MODEL"; then
    echo "ERROR: Unknown model '$MODEL'."
    echo "  Supported: P1005 P1006 P1007 P1008 P1505"
    exit 1
fi

FIRMWARE="$FIRMWARE_DIR/$FW_BASE.dl"
QUEUE="HP_LaserJet_$MODEL"
PLIST_NAME="com.foo2xqx.firmware-upload-$MODEL"
PLIST_PATH="/Library/LaunchDaemons/$PLIST_NAME.plist"
SCRIPT_PATH="/usr/local/bin/hp-$MODEL-firmware-upload"

if [ ! -f "$FIRMWARE" ]; then
    echo "ERROR: Firmware not found at $FIRMWARE"
    echo "Run install.sh $MODEL first."
    exit 1
fi

# Remove the pre-model-aware daemon, if this machine has one. It was hardcoded
# to the P1007 and would otherwise keep running alongside the new one.
LEGACY_PLIST="/Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist"
if [ -f "$LEGACY_PLIST" ]; then
    echo "Removing legacy P1007-only daemon..."
    launchctl unload "$LEGACY_PLIST" 2>/dev/null || true
    rm -f "$LEGACY_PLIST" /usr/local/bin/hp-p1007-firmware-upload
fi

# Create the firmware upload script
cat > "$SCRIPT_PATH" << SCRIPT
#!/bin/sh
#
# Upload firmware to the HP LaserJet $MODEL when it appears on USB.
# Called by launchd via IOKit USB device matching.
#
LOG="/tmp/hp-$MODEL-firmware.log"
FIRMWARE="$FIRMWARE"
QUEUE="$QUEUE"
STAMP="/tmp/hp-$MODEL-firmware.stamp"

# Debounce: skip if firmware was uploaded in the last 120 seconds.
# launchd re-triggers every ~10s since a shell script cannot consume
# the XPC event stream. 120s is plenty - firmware is once per power cycle.
if [ -f "\$STAMP" ]; then
    last=\$(stat -f %m "\$STAMP" 2>/dev/null || echo 0)
    now=\$(date +%s)
    elapsed=\$(( now - last ))
    if [ "\$elapsed" -lt 120 ]; then
        exit 0
    fi
fi

echo "\$(date): HP LaserJet $MODEL USB connect detected, uploading firmware..." >> "\$LOG"

# Wait briefly for the USB device to be fully ready
sleep 2

if command -v lp >/dev/null 2>&1; then
    lp -d "\$QUEUE" -oraw "\$FIRMWARE" >> "\$LOG" 2>&1
    echo "\$(date): Firmware upload complete (exit code: \$?)" >> "\$LOG"
    touch "\$STAMP"
else
    echo "\$(date): ERROR: lp command not found" >> "\$LOG"
fi
SCRIPT

chmod 755 "$SCRIPT_PATH"

# Create the LaunchDaemon plist.
# IOKit matching triggers on the exact USB device (vendor 0x03f0 = 1008).
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPT_PATH</string>
    </array>
    <key>LaunchEvents</key>
    <dict>
        <key>com.apple.iokit.matching</key>
        <dict>
            <key>com.foo2xqx.hp-$MODEL-usb</key>
            <dict>
                <key>IOProviderClass</key>
                <string>IOUSBDevice</string>
                <key>idVendor</key>
                <integer>1008</integer>
                <key>idProduct</key>
                <integer>$USB_PID_DEC</integer>
                <key>IOMatchLaunchStream</key>
                <true/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
EOF

chmod 644 "$PLIST_PATH"

# (Re)load the daemon - unload first in case a previous version is loaded
launchctl unload "$PLIST_PATH" 2>/dev/null || true
if ! launchctl load "$PLIST_PATH" 2>&1; then
    echo "WARNING: Failed to load LaunchDaemon. You may need to reboot or load it manually:"
    echo "  sudo launchctl load $PLIST_PATH"
fi

echo "Firmware auto-upload daemon installed for the $MODEL."
echo "  Script: $SCRIPT_PATH"
echo "  Daemon: $PLIST_PATH"
echo ""
echo "The firmware will be uploaded when the printer is detected."
echo "You can also manually upload at any time with:"
echo "  lp -oraw $FIRMWARE"
