#!/bin/sh
#
# HP LaserJet P100x - Apple Silicon Native Driver Installer
#
# Installs an ARM64-native driver using the rastertoxqx CUPS raster filter.
# No Ghostscript dependency - uses macOS built-in cgpdftoraster for PDF
# rendering.
#
# Usage: sudo ./install.sh [MODEL]
#
#   MODEL is one of: P1005 P1006 P1007 P1008 P1505
#   If omitted, the script detects the connected printer over USB and
#   falls back to P1007.
#
# Examples:
#   sudo ./install.sh            # auto-detect
#   sudo ./install.sh P1005
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CUPS_FILTER_DIR="/usr/libexec/cups/filter"
FIRMWARE_DIR="/usr/local/share/foo2xqx/firmware"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
FOO2ZJS_DIR="$SCRIPT_DIR/foo2zjs"

# ── Model table ─────────────────────────────────────────────────────────────
#
# USB product IDs and firmware assignments are taken from foo2zjs
# (foo2zjs/hplj10xx.conf and foo2zjs/osx-hotplug/osx-hplj-hotplug.m).
# Vendor ID is 0x03f0 (HP) for all of them.
#
# Note that several models share a firmware blob: the P1007 uses the P1005
# firmware and the P1008 uses the P1006 firmware.
#
#   Model   USB PID   Firmware
#   P1005   0x3d17    sihpP1005
#   P1006   0x3e17    sihpP1006
#   P1007   0x4817    sihpP1005
#   P1008   0x4917    sihpP1006
#   P1505   0x3f17    sihpP1505
#
model_info() {
    case "$1" in
        P1005) USB_PID=0x3d17; FW_BASE=sihpP1005 ;;
        P1006) USB_PID=0x3e17; FW_BASE=sihpP1006 ;;
        P1007) USB_PID=0x4817; FW_BASE=sihpP1005 ;;
        P1008) USB_PID=0x4917; FW_BASE=sihpP1006 ;;
        P1505) USB_PID=0x3f17; FW_BASE=sihpP1505 ;;
        *) return 1 ;;
    esac
    return 0
}

# Detect a connected printer from the CUPS device list.
detect_model() {
    lpinfo -v 2>/dev/null \
        | grep -io 'P1[05][0-9][0-9]' \
        | tr '[:lower:]' '[:upper:]' \
        | head -1
}

# ── Preflight ───────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    echo "  sudo $0 $*"
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo "WARNING: This driver is built for Apple Silicon (arm64)."
    echo "  Detected architecture: $ARCH"
    echo ""
fi

MODEL="$1"
if [ -z "$MODEL" ]; then
    MODEL=$(detect_model)
    if [ -n "$MODEL" ]; then
        echo "Detected printer: HP LaserJet $MODEL"
    else
        MODEL=P1007
        echo "No printer detected on USB, defaulting to $MODEL."
        echo "  (Pass a model explicitly if that is wrong: sudo $0 P1005)"
    fi
fi

MODEL=$(echo "$MODEL" | tr '[:lower:]' '[:upper:]')

if ! model_info "$MODEL"; then
    echo "ERROR: Unknown model '$MODEL'."
    echo "  Supported: P1005 P1006 P1007 P1008 P1505"
    exit 1
fi

PPD_FILE="$SCRIPT_DIR/HP-LaserJet_$MODEL.ppd"
if [ ! -f "$PPD_FILE" ]; then
    echo "ERROR: No PPD for the $MODEL yet ($PPD_FILE is missing)."
    echo ""
    echo "  The filter itself is model-independent, so adding a model only"
    echo "  needs a PPD. Copy HP-LaserJet_P1005.ppd, replace the model name"
    echo "  in *ModelName, *NickName, *ShortNickName, *Product and"
    echo "  *1284DeviceID, and open a pull request."
    exit 1
fi

if [ ! -f "$FOO2ZJS_DIR/$FW_BASE.img" ]; then
    echo "ERROR: Firmware source $FOO2ZJS_DIR/$FW_BASE.img not found."
    exit 1
fi

echo "=== HP LaserJet $MODEL - ARM64 Native Driver Installer ==="
echo ""

# ── Step 1: Compile rastertoxqx (the CUPS raster filter) ────────────────────

echo "[1/5] Compiling rastertoxqx..."
cd "$SCRIPT_DIR"
clang -o rastertoxqx rastertoxqx.c foo2zjs/jbig.c foo2zjs/jbig_ar.c \
    -Ifoo2zjs -lcups -lcupsimage -Wall -O2
echo "  rastertoxqx: $(file -b rastertoxqx)"

# ── Step 2: Compile arm2hpdl and generate firmware ──────────────────────────

echo "[2/5] Preparing firmware..."
if [ ! -f "$FOO2ZJS_DIR/arm2hpdl" ] || [ "$(file -b "$FOO2ZJS_DIR/arm2hpdl" | grep -c arm64)" -eq 0 ]; then
    cd "$FOO2ZJS_DIR"
    clang -o arm2hpdl arm2hpdl.c -I. -Wall -O2
    cd "$SCRIPT_DIR"
fi
if [ ! -f "$FOO2ZJS_DIR/$FW_BASE.dl" ]; then
    cd "$FOO2ZJS_DIR"
    ./arm2hpdl "$FW_BASE.img" > "$FW_BASE.dl"
    cd "$SCRIPT_DIR"
fi
echo "  Firmware: $FW_BASE.dl ($(wc -c < "$FOO2ZJS_DIR/$FW_BASE.dl" | tr -d ' ') bytes)"

# ── Step 3: Install the rastertoxqx filter ──────────────────────────────────

echo "[3/5] Installing CUPS filter..."
mkdir -p "$CUPS_FILTER_DIR"
cp "$SCRIPT_DIR/rastertoxqx" "$CUPS_FILTER_DIR/rastertoxqx"
chmod 755 "$CUPS_FILTER_DIR/rastertoxqx"
echo "  Installed to $CUPS_FILTER_DIR/rastertoxqx"

# ── Step 4: Install firmware ────────────────────────────────────────────────

echo "[4/5] Installing firmware..."
mkdir -p "$FIRMWARE_DIR"
cp "$FOO2ZJS_DIR/$FW_BASE.dl" "$FIRMWARE_DIR/$FW_BASE.dl"
chmod 644 "$FIRMWARE_DIR/$FW_BASE.dl"
echo "  Installed to $FIRMWARE_DIR/"

# ── Step 5: Install PPD ─────────────────────────────────────────────────────

echo "[5/5] Installing PPD..."
mkdir -p "$PPD_DIR"
cp "$PPD_FILE" "$PPD_DIR/HP-LaserJet_$MODEL.ppd"
chmod 644 "$PPD_DIR/HP-LaserJet_$MODEL.ppd"
echo "  Installed to $PPD_DIR/"

# ── Clean up the old Ghostscript bundle, if present ─────────────────────────

if [ -f "$CUPS_FILTER_DIR/gs-bundled" ]; then
    echo ""
    echo "Cleaning up old Ghostscript bundle..."
    rm -f "$CUPS_FILTER_DIR/gs-bundled"
    rm -rf "$CUPS_FILTER_DIR/gs-res"
    rm -f "$CUPS_FILTER_DIR"/libjbig2dec*.dylib \
          "$CUPS_FILTER_DIR"/libtiff*.dylib \
          "$CUPS_FILTER_DIR"/libpng*.dylib \
          "$CUPS_FILTER_DIR"/libjpeg*.dylib \
          "$CUPS_FILTER_DIR"/liblcms2*.dylib \
          "$CUPS_FILTER_DIR"/libidn*.dylib \
          "$CUPS_FILTER_DIR"/libfontconfig*.dylib \
          "$CUPS_FILTER_DIR"/libfreetype*.dylib \
          "$CUPS_FILTER_DIR"/libopenjp2*.dylib \
          "$CUPS_FILTER_DIR"/libtesseract*.dylib \
          "$CUPS_FILTER_DIR"/libarchive*.dylib \
          "$CUPS_FILTER_DIR"/libleptonica*.dylib \
          "$CUPS_FILTER_DIR"/libwebp*.dylib \
          "$CUPS_FILTER_DIR"/libsharpyuv*.dylib \
          "$CUPS_FILTER_DIR"/libgif*.dylib \
          "$CUPS_FILTER_DIR"/libintl*.dylib \
          2>/dev/null
    echo "  Removed gs-bundled, dylibs, and gs-res/"
fi
if [ -f "$CUPS_FILTER_DIR/foomatic-rip" ]; then
    rm -f "$CUPS_FILTER_DIR/foomatic-rip"
    echo "  Removed old foomatic-rip"
fi

echo ""
echo "=== Installation complete! ==="
echo ""
echo "Next steps:"
echo ""
echo "1. PLUG IN your HP LaserJet $MODEL via USB"
echo ""
echo "2. UPLOAD FIRMWARE (required every time the printer powers on):"
echo "   lp -oraw $FIRMWARE_DIR/$FW_BASE.dl"
echo "   (The printer light should flash orange for ~5 seconds)"
echo ""
echo "3. ADD THE PRINTER via System Settings > Printers & Scanners"
echo "   - Click '+' to add a printer"
echo "   - Select 'HP LaserJet $MODEL' from USB"
echo "   - Choose 'HP LaserJet $MODEL rastertoxqx' as the driver"
echo ""
echo "   OR add via command line:"
echo "   lpadmin -p HP_LaserJet_$MODEL -E \\"
echo "     -v \"\$(lpinfo -v | awk '/$MODEL/ {print \$2}' | head -1)\" \\"
echo "     -P '$PPD_DIR/HP-LaserJet_$MODEL.ppd'"
echo ""
echo "4. PRINT A TEST PAGE:"
echo "   lp -d HP_LaserJet_$MODEL testpage.pdf"
echo ""
echo "Tip: To auto-upload firmware on printer connect, run:"
echo "   sudo $SCRIPT_DIR/install-hotplug.sh $MODEL"
echo ""
