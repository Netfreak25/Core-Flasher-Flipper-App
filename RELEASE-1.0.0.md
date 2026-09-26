# Core Flasher for Flipper Zero 1.0.0

Initial standalone release of the Core Flasher FlipTDI mod.
This is an independent modification of FlipTDI by SkorP,
distributed under GPL-3.0 with upstream attribution and license text.

## Included changes

- Native external hardware SPI, mode 0, 2 MHz.
- Raw CS/TX/RX transport without a firmware flash-opcode whitelist.
- Complete MPSSE write buffering across USB packet boundaries.
- Retained pending USB payloads, reset/purge handling and USB restoration.
- Standalone menu, W25Q128FV JEDEC diagnostic and wiring information.
- English documentation and build-script messages.

The browser owns chip checks, backup requirements, erase/program sequencing and
readback verification.

## Downloads

| Asset | Build target | Embedded API |
|---|---|---|
| `core_flasher-1.0.0-unleashed.fap` | Unleashed unlshd-093 | 88.9 |
| `core_flasher-1.0.0-momentum.fap` | Momentum mntm-012 | 87.1 |
| `core_flasher-1.0.0-roguemaster.fap` | RogueMaster branch 420, commit 0ab8ae17 | 88.4 |

Download only the FAP matching your firmware. Copy it to `/ext/apps/Tools/`
and open Core Flasher. `SHA256SUMS.txt` contains the SHA-256 digest of each
FAP. Source archives are available from this tag.

## Verification

All three builds completed successfully with APPCHK. Embedded metadata was
independently checked for target f7, application version 1.0 and the APIs above.
Translated PowerShell scripts passed syntax parsing. No hardware flash tests
were performed as part of this release.

Version 1.0.0 is an **unverified build candidate** pending physical testing of
WREN/WRDI, erase/program, complete readback and USB disconnect behavior.
