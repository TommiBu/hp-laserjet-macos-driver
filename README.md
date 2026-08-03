# HP LaserJet P100x — ARM64 macOS Driver

A native Apple Silicon driver for the HP LaserJet P1005 and P1007 on macOS. The P1006, P1008 and P1505 are wired up too and only need a PPD (see [Other Printers](#other-printers)).

The driver is a single 85KB binary (`rastertoxqx`) that converts CUPS raster data to the printer's native XQX format using JBIG compression. It links only against system libraries and runs inside the CUPS sandbox without issues. No Ghostscript, no Homebrew dependencies.

```
PDF → cgpdftoraster (macOS built-in) → rastertoxqx → XQX → printer
```

macOS already knows how to render PDFs into raster through CoreGraphics via its built-in `cgpdftoraster` filter. `rastertoxqx` takes that raster output and wraps it in the XQX/ZjStream protocol the printer expects.

## Installation

You need macOS on Apple Silicon and Xcode Command Line Tools (`xcode-select --install`).

```bash
# Install the driver — compiles rastertoxqx, installs the filter, PPD, and firmware
sudo ./install.sh

# Set up automatic firmware upload when the printer is plugged in
sudo ./install-hotplug.sh
```

Both scripts detect the connected printer over USB. If nothing is plugged in, or you want to install for a printer you will connect later, pass the model explicitly:

```bash
sudo ./install.sh P1005
sudo ./install-hotplug.sh P1005
```

After that, go to System Settings > Printers & Scanners, add the printer, and select "HP LaserJet P1005 rastertoxqx" (or your model) as the driver. Print a test page with `lp -d HP_LaserJet_P1005 testpage.pdf`.

## Firmware

These printers have no persistent firmware — they need a ~223KB blob uploaded over USB every time they power on. If you ran `install-hotplug.sh`, this happens automatically when you plug the printer in. Otherwise you can do it manually:

```bash
lp -oraw /usr/local/share/foo2xqx/firmware/sihpP1005.dl
```

Several models share a blob. The mapping below comes from foo2zjs (`foo2zjs/hplj10xx.conf` and `foo2zjs/osx-hotplug/osx-hplj-hotplug.m`) and is what `install.sh` uses:

| Model | USB product ID | Firmware |
|-------|----------------|----------|
| P1005 | 0x3d17 | `sihpP1005.dl` |
| P1006 | 0x3e17 | `sihpP1006.dl` |
| P1007 | 0x4817 | `sihpP1005.dl` |
| P1008 | 0x4917 | `sihpP1006.dl` |
| P1505 | 0x3f17 | `sihpP1505.dl` |

Wait for the printer light to flash orange (~5 seconds) before printing.

## Troubleshooting

Check the CUPS error log with `tail -f /var/log/cups/error_log`.

If the printer isn't responding, it probably needs firmware uploaded — it won't accept print jobs without it.

If you get a "filter failed" error, check that the filter is installed at `/usr/libexec/cups/filter/rastertoxqx`. If it's missing, re-run `sudo ./install.sh`.

If the output is light or outlined, make sure the PPD resolution is 1200x600dpi (the default). These printers need Bpp=2 for correct rendering — 600x600dpi produces faint output.

After a macOS update, recompile and reinstall with `sudo ./install.sh`.

## Background

The XQX protocol and JBIG compression code comes from the [foo2zjs](http://foo2zjs.rkkda.com/) project by Rick Richardson, and the JBIG-KIT library by Markus Kuhn. Both are GPL v2+.

This driver replaced an earlier approach that used Ghostscript for PDF-to-raster rendering. That worked, but CUPS runs filters in a sandbox that blocks Homebrew libraries, so Ghostscript had to be bundled with all ~15 of its dylibs rewritten to use `@loader_path/`. The resulting package was ~35MB and broke on every `brew upgrade ghostscript`. Using macOS's built-in `cgpdftoraster` eliminated all of that.

## Other Printers

`rastertoxqx` contains no model-specific code, and `install.sh` knows the USB
product ID and firmware blob for the whole XQX family. Adding a model is
therefore only a matter of supplying a PPD.

| Model | Status |
|-------|--------|
| P1005 | Tested — macOS 26 Tahoe, MacBook Air M4 |
| P1007 | Tested — original target of this repo |
| P1006 | Wired up, needs a PPD |
| P1008 | Wired up, needs a PPD |
| P1505 | Wired up, needs a PPD |

To add one of the remaining models, copy `HP-LaserJet_P1005.ppd`, replace the
model name in `*ModelName`, `*NickName`, `*ShortNickName`, `*Product` and
`*1284DeviceID`, and open a pull request. `install.sh` will pick it up
automatically.

The LaserJet 1018, 1020, and 1022 use a related protocol (ZjStream) that needs a separate filter binary, but the structure is almost identical to `rastertoxqx` and the work is scoped out.

Beyond HP, the same porting pattern could support printers from Dell, Xerox, Samsung, and Konica Minolta that the foo2zjs project already handles on Linux.

### How to help

If you have a P1006, P1008 or P1505 and a Mac with Apple Silicon, adding the
PPD is a small change and the instructions are above — pull requests welcome.

If you would rather not build anything, [open an issue](https://github.com/faradayfury/hp-laserjet-macos-driver/issues/new)
with your printer model and macOS version, and say whether printing worked.
Confirmations from real hardware are what move models from "wired up" to
"tested".
