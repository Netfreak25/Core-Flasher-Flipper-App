# Core Flasher Flipper App - multi-firmware build package

Includes the complete application source, the updated `application.fam`, and
portable Windows build scripts for Unleashed, Momentum and RogueMaster.

## Start

```powershell
.\build-unleashed.cmd
.\build-momentum.cmd
.\build-roguemaster.cmd
```

Run the command for the firmware installed on your Flipper. The CMD wrappers
start PowerShell with `-ExecutionPolicy Bypass` for that process only.

## Shared output filename

Each build copies its completed FAP to:

```text
.\dist\core_flasher_distribution.fap
```

The most recent build overwrites this file. The shared filename does not make
the binary compatible with every firmware. Native toolchain outputs are retained.

## Separate build environments

- Unleashed: `.\.ufbt-unleashed`, latest release SDK.
- Momentum: `.\.ufbt-momentum`, latest release SDK.
- RogueMaster: `%LOCALAPPDATA%\FlipperBuild\RogueMaster\flipperzero-firmware-wPlugins`, branch `420`.

SDKs, toolchains and generated artifacts are not included in the source archive.
The RogueMaster directory is a dedicated build checkout: the script resets it
to the fetched branch and recreates its external-app staging directories.

## Manifest compatibility

`fap_exclude_libs` was removed from `application.fam` because Momentum mntm-012
does not support that manifest parameter.

## Windows/Python SSL

The uFBT scripts check Python SSL initialization and, if required, apply a local
Windows certificate-store workaround for the build process. The Windows
certificate store is not modified, and TLS verification stays enabled.

## Validation

Release preparation runs the three firmware builds and records APPCHK results
in the release notes. Hardware validation remains separate and pending.
