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

$MomentumIndex = 'https://up.momentum-fw.dev/firmware/directory.json'
$UfbtHome = Join-Path $ProjectRoot '.ufbt-momentum'
$PreviousUfbtHome = $env:UFBT_HOME
$PreviousPythonPath = $env:PYTHONPATH
$ExitCode = 0

try {
    Write-Host '=== Flipper Zero App Build: Momentum ==='
    Write-Host "Project:      $ProjectRoot"
    Write-Host "uFBT Home:    $UfbtHome"
    Write-Host "Distribution: $DistributionFile"
    Write-Host ''

    $Py = Get-Command py.exe -ErrorAction SilentlyContinue
    if (-not $Py) {
        throw 'Python Launcher (py.exe) was not found.'
    }

    Write-Host '[1/8] Checking Python SSL ...'
    Enable-PythonSslWorkaroundIfNeeded -PythonLauncher $Py.Source -Root $ProjectRoot

    Write-Host ''
    Write-Host '[2/8] Installing/updating uFBT ...'
    Invoke-NativeChecked $Py.Source -m pip install --upgrade ufbt

    $UfbtExe = Find-UfbtExecutable -PythonLauncher $Py.Source
    Write-Host "uFBT: $UfbtExe"
    Write-Host ''

    $env:UFBT_HOME = $UfbtHome

    Write-Host '[3/8] Loading the latest Momentum release SDK ...'
    Invoke-NativeChecked $UfbtExe update "--index-url=$MomentumIndex" --channel=release

    Write-Host ''
    Write-Host '[4/8] Checking SDK status ...'
    Invoke-NativeChecked $UfbtExe status

    Write-Host ''
    Write-Host '[5/8] Finding application.fam ...'

    $FamFile = Find-SingleApplicationFam -Root $ProjectRoot
    $AppDir = $FamFile.Directory.FullName
    $AppId = Get-AppIdFromManifest -ManifestPath $FamFile.FullName

    Write-Host "App directory: $AppDir"
    Write-Host "App-ID:          $AppId"

    Write-Host ''
    Write-Host '[6/8] Compiling the application ...'

    Push-Location $AppDir
    try {
        Invoke-NativeChecked $UfbtExe
    }
    finally {
        Pop-Location
    }

    Write-Host ''
    Write-Host '[7/8] Finding the native FAP ...'

    $NativeDistDir = Join-Path $AppDir 'dist'

    if (-not (Test-Path -LiteralPath $NativeDistDir -PathType Container)) {
        throw "uFBT output directory is missing: $NativeDistDir"
    }

    $ExactFap = Join-Path $NativeDistDir "$AppId.fap"

    if (Test-Path -LiteralPath $ExactFap -PathType Leaf) {
        $BuiltFap = Get-Item -LiteralPath $ExactFap
    }
    else {
        $Candidates = @(
            Get-ChildItem -LiteralPath $NativeDistDir -Filter '*.fap' -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -ne $DistributionFile } |
                Sort-Object LastWriteTime -Descending
        )

        if ($Candidates.Count -eq 0) {
            throw "No generated .fap found under '$NativeDistDir'."
        }

        $BuiltFap = $Candidates[0]
    }

    Write-Host "Native FAP: $($BuiltFap.FullName)"
    Write-Host "Size:      $($BuiltFap.Length) Bytes"

    Write-Host ''
    Write-Host '[8/8] Copying the distribution FAP ...'

    $FinalInfo = Publish-DistributionFap -SourceFap $BuiltFap.FullName

    Write-Host ''
    Write-Host '=== BUILD SUCCEEDED ===' -ForegroundColor Green
    Write-Host "Momentum: $($FinalInfo.FullName)"
    Write-Host "Size:  $($FinalInfo.Length) Bytes"
}
catch {
    $ExitCode = 1
    Write-Host ''
    Write-Host '=== BUILD FAILED ===' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
}
finally {
    if ($null -eq $PreviousUfbtHome) {
        Remove-Item Env:UFBT_HOME -ErrorAction SilentlyContinue
    }
    else {
        $env:UFBT_HOME = $PreviousUfbtHome
    }

    if ($null -eq $PreviousPythonPath) {
        Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
    }
    else {
        $env:PYTHONPATH = $PreviousPythonPath
    }
}

exit $ExitCode
