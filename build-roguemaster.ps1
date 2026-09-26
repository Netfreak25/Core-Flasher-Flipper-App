[CmdletBinding()]
param(
    [string]$ProjectRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Get-Location).Path
}

$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$DistributionDir = Join-Path $ProjectRoot 'dist'
$DistributionFile = Join-Path $DistributionDir 'core_flasher_distribution.fap'

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Arguments
    )

    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit code $LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
}

function Invoke-PythonSslProbe {
    param(
        [Parameter(Mandatory)]
        [string]$PythonLauncher
    )

    $Psi = New-Object System.Diagnostics.ProcessStartInfo
    $Psi.FileName = $PythonLauncher
    $Psi.Arguments = '-c "import ssl; ssl.create_default_context(); print(''SSL_OK'')"'
    $Psi.UseShellExecute = $false
    $Psi.RedirectStandardOutput = $true
    $Psi.RedirectStandardError = $true
    $Psi.CreateNoWindow = $true

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $Psi

    if (-not $Process.Start()) {
        throw 'Could not start the Python SSL probe.'
    }

    $StdOut = $Process.StandardOutput.ReadToEnd()
    $StdErr = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()

    return [PSCustomObject]@{
        ExitCode = $Process.ExitCode
        StdOut   = $StdOut.Trim()
        StdErr   = $StdErr.Trim()
    }
}

function Find-UfbtExecutable {
    param(
        [Parameter(Mandatory)]
        [string]$PythonLauncher
    )

    $UfbtCommand = Get-Command ufbt.exe -ErrorAction SilentlyContinue
    if ($UfbtCommand) {
        return $UfbtCommand.Source
    }

    $ScriptsDir = (& $PythonLauncher -c "import sysconfig; print(sysconfig.get_path('scripts'))").Trim()
    $Candidate = Join-Path $ScriptsDir 'ufbt.exe'

    if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
        return $Candidate
    }

    $UserBase = (& $PythonLauncher -m site --user-base).Trim()
    $UserCandidate = Join-Path $UserBase 'Scripts\ufbt.exe'

    if (Test-Path -LiteralPath $UserCandidate -PathType Leaf) {
        return $UserCandidate
    }

    throw "uFBT was installed, but ufbt.exe was not found."
}

function Find-SingleApplicationFam {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $FamFiles = @(
        Get-ChildItem -LiteralPath $Root -Filter 'application.fam' -File -Recurse -ErrorAction Stop |
            Where-Object {
                $_.FullName -notmatch '[\\/]\.git[\\/]' -and
                $_.FullName -notmatch '[\\/]\.ufbt-[^\\/]+[\\/]' -and
                $_.FullName -notmatch '[\\/]\.python-ssl-workaround[\\/]' -and
                $_.FullName -notmatch '[\\/]dist(?:-[^\\/]+)?[\\/]'
            }
    )

    if ($FamFiles.Count -eq 0) {
        throw "No application.fam found under '$Root'."
    }

    if ($FamFiles.Count -gt 1) {
        Write-Host 'Multiple application.fam files found:' -ForegroundColor Yellow
        $FamFiles | ForEach-Object { Write-Host "  $($_.FullName)" }
        throw 'Build stopped to avoid building the wrong application.'
    }

    return $FamFiles[0]
}

function Get-AppIdFromManifest {
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath
    )

    $Text = Get-Content -LiteralPath $ManifestPath -Raw
    $Match = [regex]::Match(
        $Text,
        '(?m)^\s*appid\s*=\s*["'']([^"'']+)["'']\s*,?'
    )

    if (-not $Match.Success) {
        throw "Could not read appid from '$ManifestPath'."
    }

    return $Match.Groups[1].Value
}

function Enable-PythonSslWorkaroundIfNeeded {
    param(
        [Parameter(Mandatory)]
        [string]$PythonLauncher,

        [Parameter(Mandatory)]
        [string]$Root
    )

    $Probe = Invoke-PythonSslProbe -PythonLauncher $PythonLauncher

    if ($Probe.ExitCode -eq 0) {
        Write-Host 'Python SSL: OK'
        return
    }

    Write-Host 'Python SSL: FAILED' -ForegroundColor Yellow

    if ($Probe.StdErr) {
        Write-Host 'Original Python error:' -ForegroundColor Yellow
        Write-Host $Probe.StdErr -ForegroundColor DarkYellow
    }

    Write-Host ''
    Write-Host 'Enabling local Windows certificate-store workaround ...' -ForegroundColor Yellow

    $WorkaroundDir = Join-Path $Root '.python-ssl-workaround'
    New-Item -ItemType Directory -Force -Path $WorkaroundDir | Out-Null

    $SiteCustomize = @'
import ssl

if hasattr(ssl, "enum_certificates") and hasattr(ssl.SSLContext, "_load_windows_store_certs"):
    def _safe_load_windows_store_certs(self, storename, purpose):
        try:
            certificates = ssl.enum_certificates(storename)
        except PermissionError:
            return

        for cert, encoding, trust in certificates:
            if encoding != "x509_asn":
                continue

            if not (trust is True or purpose.oid in trust):
                continue

            try:
                pem = ssl.DER_cert_to_PEM_cert(cert)
                self.load_verify_locations(cadata=pem)
            except (ssl.SSLError, ValueError):
                continue

    ssl.SSLContext._load_windows_store_certs = _safe_load_windows_store_certs
'@

    Set-Content `
        -LiteralPath (Join-Path $WorkaroundDir 'sitecustomize.py') `
        -Value $SiteCustomize `
        -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($env:PYTHONPATH)) {
        $env:PYTHONPATH = $WorkaroundDir
    }
    else {
        $env:PYTHONPATH = "$WorkaroundDir;$($env:PYTHONPATH)"
    }

    $ProbeAfter = Invoke-PythonSslProbe -PythonLauncher $PythonLauncher

    if ($ProbeAfter.ExitCode -ne 0) {
        $Details = if ($ProbeAfter.StdErr) {
            $ProbeAfter.StdErr
        }
        else {
            'Python produced no stderr output.'
        }

        throw "Python SSL still fails with the local workaround.`r`n$Details"
    }

    Write-Host 'Python SSL: OK after local workaround' -ForegroundColor Green
}

function Publish-DistributionFap {
    param(
        [Parameter(Mandatory)]
        [string]$SourceFap
    )

    if (-not (Test-Path -LiteralPath $SourceFap -PathType Leaf)) {
        throw "Source FAP not found: $SourceFap"
    }

    $SourceInfo = Get-Item -LiteralPath $SourceFap

    if ($SourceInfo.Length -le 0) {
        throw "Source FAP is empty: $SourceFap"
    }

    New-Item -ItemType Directory -Force -Path $DistributionDir | Out-Null

    if (Test-Path -LiteralPath $DistributionFile) {
        Remove-Item -LiteralPath $DistributionFile -Force
    }

    Copy-Item -LiteralPath $SourceFap -Destination $DistributionFile -Force

    $FinalInfo = Get-Item -LiteralPath $DistributionFile

    if ($FinalInfo.Length -ne $SourceInfo.Length) {
        throw 'Distribution FAP verification failed.'
    }

    return $FinalInfo
}

$RepoUrl = 'https://github.com/RogueMaster/flipperzero-firmware-wPlugins.git'
$Branch = '420'
$FirmwareRoot = Join-Path $env:LOCALAPPDATA 'FlipperBuild\RogueMaster\flipperzero-firmware-wPlugins'
$StagedAppName = '_external_core_flasher'
$StagedAppRelative = "applications_user/$StagedAppName"
$KnownOldStageNames = @(
    '_external_app_build',
    '_external_core_flasher'
)
$ExitCode = 0

function Find-ManifestsByAppId {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$AppId
    )

    $Matches = @()

    $Manifests = @(
        Get-ChildItem -LiteralPath $Root -Filter 'application.fam' -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
    )

    foreach ($Manifest in $Manifests) {
        try {
            $ManifestAppId = Get-AppIdFromManifest -ManifestPath $Manifest.FullName
        }
        catch {
            continue
        }

        if ($ManifestAppId -eq $AppId) {
            $Matches += $Manifest
        }
    }

    return @($Matches)
}

try {
    Write-Host '=== Flipper Zero App Build: RogueMaster ==='
    Write-Host "Project:       $ProjectRoot"
    Write-Host "Firmware-Repo: $FirmwareRoot"
    Write-Host "Branch:        $Branch"
    Write-Host "Distribution:  $DistributionFile"
    Write-Host ''

    $Git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $Git) {
        throw 'git.exe was not found.'
    }

    Write-Host '[1/10] Finding application.fam ...'

    $FamFile = Find-SingleApplicationFam -Root $ProjectRoot
    $AppDir = $FamFile.Directory.FullName
    $AppId = Get-AppIdFromManifest -ManifestPath $FamFile.FullName

    Write-Host "App directory: $AppDir"
    Write-Host "App-ID:          $AppId"
    Write-Host ''

    Write-Host '[2/10] Preparing/updating RogueMaster branch 420 ...'

    $FirmwareParent = Split-Path -Parent $FirmwareRoot
    New-Item -ItemType Directory -Force -Path $FirmwareParent | Out-Null

    if (-not (Test-Path -LiteralPath (Join-Path $FirmwareRoot '.git') -PathType Container)) {
        if (Test-Path -LiteralPath $FirmwareRoot) {
            throw "FirmwareRoot exists but is not a Git repository: $FirmwareRoot"
        }

        Invoke-NativeChecked `
            $Git.Source `
            clone `
            --branch $Branch `
            --single-branch `
            --depth 1 `
            --recursive `
            --shallow-submodules `
            --jobs 8 `
            $RepoUrl `
            $FirmwareRoot
    }
    else {
        Push-Location $FirmwareRoot
        try {
            Invoke-NativeChecked $Git.Source remote set-url origin $RepoUrl
            Invoke-NativeChecked $Git.Source fetch origin $Branch --depth 1
            Invoke-NativeChecked $Git.Source checkout -B $Branch FETCH_HEAD
            Invoke-NativeChecked $Git.Source reset --hard FETCH_HEAD
            Invoke-NativeChecked $Git.Source submodule sync --recursive
            Invoke-NativeChecked $Git.Source submodule update --init --recursive --depth 1 --jobs 8
        }
        finally {
            Pop-Location
        }
    }

    Push-Location $FirmwareRoot
    try {
        $Commit = (& $Git.Source rev-parse --short HEAD).Trim()
        $CurrentBranch = (& $Git.Source branch --show-current).Trim()
    }
    finally {
        Pop-Location
    }

    if ($CurrentBranch -ne $Branch) {
        throw "Wrong RogueMaster branch: '$CurrentBranch' instead of '$Branch'."
    }

    Write-Host "RogueMaster Branch: $CurrentBranch"
    Write-Host "RogueMaster Commit: $Commit"
    Write-Host ''

    Write-Host '[3/10] Cleaning old staging directories ...'

    $ApplicationsUser = Join-Path $FirmwareRoot 'applications_user'
    New-Item -ItemType Directory -Force -Path $ApplicationsUser | Out-Null

    foreach ($StageName in $KnownOldStageNames) {
        $OldStage = Join-Path $ApplicationsUser $StageName

        if (Test-Path -LiteralPath $OldStage) {
            Write-Host "Removing: $OldStage"
            Remove-Item -LiteralPath $OldStage -Recurse -Force
        }
    }

    Write-Host ''
    Write-Host '[4/10] Checking for duplicate appids ...'

    $Existing = @(Find-ManifestsByAppId -Root $FirmwareRoot -AppId $AppId)

    if ($Existing.Count -gt 0) {
        Write-Host "RogueMaster already contains manifests with appid '$AppId':" -ForegroundColor Yellow
        $Existing | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor Yellow }
        throw "appid '$AppId' already exists in the RogueMaster tree."
    }

    Write-Host "No existing appid '$AppId' found."
    Write-Host ''

    Write-Host '[5/10] Copying the app into applications_user ...'

    $StagedAppDir = Join-Path $ApplicationsUser $StagedAppName
    New-Item -ItemType Directory -Force -Path $StagedAppDir | Out-Null

    $RoboCopy = Get-Command robocopy.exe -ErrorAction SilentlyContinue
    if (-not $RoboCopy) {
        throw 'robocopy.exe was not found.'
    }

    & $RoboCopy.Source `
        $AppDir `
        $StagedAppDir `
        /E `
        /R:2 `
        /W:1 `
        /NFL `
        /NDL `
        /NJH `
        /NJS `
        /NP `
        /XD `
        '.git' `
        '.ufbt-unleashed' `
        '.ufbt-momentum' `
        '.ufbt-roguemaster' `
        '.python-ssl-workaround' `
        'dist' `
        'dist-roguemaster' `
        'build'

    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed (exit code $LASTEXITCODE)."
    }

    Write-Host "Staging: $StagedAppDir"
    Write-Host ''

    Write-Host '[6/10] Verifying appid after staging ...'

    $PostStage = @(Find-ManifestsByAppId -Root $FirmwareRoot -AppId $AppId)

    if ($PostStage.Count -ne 1) {
        $PostStage | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor Yellow }
        throw "Expected exactly one manifest with appid '$AppId'; found: $($PostStage.Count)."
    }

    Write-Host "Exactly one manifest with appid '$AppId' found."
    Write-Host ''

    Write-Host '[7/10] Checking RogueMaster FBT ...'

    $Fbt = Join-Path $FirmwareRoot 'fbt.cmd'
    if (-not (Test-Path -LiteralPath $Fbt -PathType Leaf)) {
        throw "fbt.cmd was not found: $Fbt"
    }

    Write-Host "FBT: $Fbt"
    Write-Host ''

    Write-Host '[8/10] Compiling the app with RogueMaster APPSRC ...'

    Push-Location $FirmwareRoot
    try {
        Invoke-NativeChecked `
            $Fbt `
            build `
            "APPSRC=$StagedAppRelative"
    }
    finally {
        Pop-Location
    }

    Write-Host ''
    Write-Host '[9/10] Finding the native FAP ...'

    $BuildRoot = Join-Path $FirmwareRoot 'build'

    $Candidates = @(
        Get-ChildItem -LiteralPath $BuildRoot -Filter "$AppId.fap" -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    )

    if ($Candidates.Count -eq 0) {
        throw "No '$AppId.fap' found under '$BuildRoot'."
    }

    $BuiltFap = $Candidates[0]

    if ($BuiltFap.Length -le 0) {
        throw "Generated FAP is empty: $($BuiltFap.FullName)"
    }

    Write-Host "Native FAP: $($BuiltFap.FullName)"
    Write-Host "Size:      $($BuiltFap.Length) Bytes"
    Write-Host ''

    Write-Host '[10/10] Copying the distribution FAP ...'

    $FinalInfo = Publish-DistributionFap -SourceFap $BuiltFap.FullName

    Write-Host ''
    Write-Host '=== BUILD SUCCEEDED ===' -ForegroundColor Green
    Write-Host "RogueMaster Branch: $CurrentBranch"
    Write-Host "RogueMaster Commit: $Commit"
    Write-Host "FAP:                $($FinalInfo.FullName)"
    Write-Host "Size:              $($FinalInfo.Length) Bytes"
}
catch {
    $ExitCode = 1
    Write-Host ''
    Write-Host '=== BUILD FAILED ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
}

exit $ExitCode
