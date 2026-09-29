# Core Flasher for Flipper Zero 1.0.1

SPI clock update for the standalone FlipTDI mod. The default remains **2 MHz**.

## Changes

- Settings offers a persistent 2 or 4 MHz default with Save and readback verification. Back discards unsaved changes.
- Complete MPSSE clock-divisor commands override the default. Both 12 MHz and 60 MHz MPSSE bases are supported.
- The bridge selects the fastest hardware rate not exceeding the client request and displays default, requested and applied rates.
- Clock changes during a transaction apply on the next SPI acquisition. Unsupported low rates stop the bridge with an explicit error.
- Session resets restore the default; RX/TX purges preserve clock selection.
- Raw SPI transport, buffered writes and pending USB retry behavior are retained.

Settings are stored in `/ext/apps_data/core_flasher/settings.conf`. Missing or invalid settings fall back to 2 MHz.

## Downloads

| Asset | Build target | API |
|---|---|---|
| `core_flasher-1.0.1-unleashed.fap` | Unleashed unlshd-093 | 88.9 |
| `core_flasher-1.0.1-momentum.fap` | Momentum mntm-012 | 87.1 |
| `core_flasher-1.0.1-roguemaster.fap` | RogueMaster branch 420, commit 0ab8ae17 | 88.4 |

Use the FAP matching your installed firmware and copy it to `/ext/apps/Tools/`.
SHA256SUMS.txt covers all three binaries. Source is available from this tag.

## Verification

Targeted host tests cover clock selection, fragmented divisor commands, chip-select deferral, reset/purge routing, settings save/readback failures, Back behavior and USB pending-packet retries. All three firmware builds pass APPCHK.

No physical hardware acceptance has been performed. This prerelease is an **unverified build candidate**.

## Attribution

Independent modification of FlipTDI by SkorP / Skorpionm, distributed under GPL-3.0. See LICENSE, NOTICE and the pinned upstream provenance in the source tree.
