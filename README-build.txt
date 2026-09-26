Portable Flipper Zero Build Scripts v6
======================================

Run the wrapper matching the firmware installed on your Flipper:

    build-unleashed.cmd
    build-momentum.cmd
    build-roguemaster.cmd

All three scripts copy the completed FAP to:

    .\dist\core_flasher_distribution.fap

Each new build overwrites that distribution file. Install the binary built for
your firmware. The native artifacts produced by each toolchain are retained.

The wrappers use PowerShell ExecutionPolicy Bypass for the current process only.
See BUILD_NOTES.md for SDK selection, build directories and SSL handling.
