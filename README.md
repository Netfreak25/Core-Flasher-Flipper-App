# Core Flasher for Flipper Zero

A standalone **FlipTDI mod** that turns Flipper Zero into an FT232H-compatible
WebUSB/MPSSE bridge using external hardware SPI. The browser controls the flash
protocol; the Flipper forwards chip select, transmit and receive operations.

This repository contains only the extracted Flipper application, its build
scripts, source assets and documentation.

## Features

- Hardware SPI, mode 0, 2 MHz, using the external Flipper SPI pins.
- FT232H-compatible USB identity `0403:6014` and MPSSE transport.
- Raw SPI TX/RX without a firmware flash-opcode whitelist or JEDEC write gate.
- Complete buffered MPSSE writes across USB packet boundaries.
- Existing 64-byte USB endpoints, 4 KiB buffering and pending-packet retry.
- USB reset/purge handling and restoration of the previous USB interface on exit.
- Standalone menus: **Start USB bridge**, **Test hardware SPI**, **Wiring**, **About**.
- Optional W25Q128FV JEDEC diagnostic (`EF 40 18`). The diagnostic does not gate
  raw bridge transactions.

The browser is responsible for chip compatibility, backups, erase/program
sequencing, user confirmation and final readback. The Flipper does not store a
backup or report that a complete flash operation was verified.

## Relationship to FlipTDI

This is an independent modification of **FlipTDI by SkorP**, as distributed in
[flipperdevices/flipperzero-good-faps](https://github.com/flipperdevices/flipperzero-good-faps/tree/efc32b71838d3d5e8d604c1ba7a4793916d5212f/flip_tdi).
It is not the original FlipTDI release or an official firmware project.

Compared with the upstream application, this mod focuses on MPSSE over native
hardware SPI, uses the Core Flasher pin mapping, adds the hardware-SPI diagnostic
and standalone Core Flasher interface, and retains pending USB input across
transient submission failures. Generic UART and timed GPIO bit-bang modes are
not initialized. It is not a general replacement for every FT232H mode.

This application runs independently. See
[NOTICE](NOTICE) and [provenance.json](third_party/flip_tdi/provenance.json) for
attribution and the pinned upstream revision.

## Installation

1. Download the **1.0.0 FAP for your installed firmware** from Releases.
2. Copy it to `/ext/apps/Tools/` on the SD card, using qFlipper or an SD reader.
3. Open **Apps -> Tools -> Core Flasher**.

The Unleashed, Momentum and RogueMaster FAPs are separate builds. Consult the
release notes for the exact firmware/API versions; they are not interchangeable.
The release includes `SHA256SUMS.txt` for integrity checks.

## Wiring

| Flipper pin | Signal |
|---|---|
| 2 | MOSI / DI |
| 3 | MISO / DO |
| 4 | CS |
| 5 | SCK / CLK |
| 8 | GND |
| 9 | 3.3 V |

Use 3.3 V. The application does not enable a 5 V supply.

## Using the bridge

1. Connect the target using the wiring above.
2. Optionally select **Test hardware SPI** for the W25Q128FV diagnostic.
3. Select **Start USB bridge** and connect the Flipper to the computer.
4. Open a compatible WebUSB/MPSSE client in Chrome via localhost or HTTPS.
5. Connect through the client's WebUSB device picker and perform the desired operation.
6. Disconnect the client and press **Back** to restore the previous USB interface.
   Back from the application menu exits the app.

## Building on Windows

Install Git and Python with the Windows `py.exe` launcher. From this directory,
run the wrapper for your firmware:

```powershell
.\build-unleashed.cmd
# or
.\build-momentum.cmd
# or
.\build-roguemaster.cmd
```

Unleashed and Momentum use uFBT with their respective latest release SDKs.
RogueMaster uses branch `420` in a dedicated firmware checkout. The wrappers
set PowerShell execution policy for their process only. Network access is needed
for SDK/toolchain downloads and updates.

All wrappers copy their result to `dist/core_flasher_distribution.fap`.
**The next build overwrites that filename**, so retain each result under its
firmware-specific name before building another target. A build does not upload
or install the FAP automatically.

See [BUILD_NOTES.md](BUILD_NOTES.md) for workspace locations and the Python SSL
workaround. To build manually in a compatible firmware checkout, copy this app
to `applications_user/core_flasher` and run `./fbt.cmd fap_core_flasher` from the
firmware root.

## Project layout

| Path | Contents |
|---|---|
| `application.fam` | Standalone FAP manifest, version 1.0.0 |
| `src/main.c` | Menu, diagnostic worker and application lifecycle |
| `src/fliptdi/` | Adapted FTDI, MPSSE, USB and hardware-SPI source |
| `assets/` | Application icon |
| `build-*.cmd`, `build-*.ps1` | Windows build wrappers and scripts |
| `third_party/flip_tdi/` | Upstream attribution and provenance |

SDKs, caches, private data, browser HTML, build logs and binaries are excluded
from the source repository. FAPs are attached to releases only.

## Verification status

Release notes record compiler/APPCHK results and the firmware/API of each build.
Hardware acceptance is separate from a successful build. Until WREN/WRDI,
program/erase, readback and disconnect behavior have been checked on physical
hardware, version 1.0.0 remains an **unverified build candidate**.

## License

Distributed under **GNU GPL version 3**; see [LICENSE](LICENSE). Adapted FlipTDI
code is credited to SkorP / Skorpionm. This project preserves its upstream
provenance and identifies local modifications in [NOTICE](NOTICE).
