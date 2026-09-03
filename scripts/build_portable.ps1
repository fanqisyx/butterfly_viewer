# Build the Windows portable distribution for Butterfly Viewer.
# All generated files, caches, and temporary files stay below the repository root.
#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath

# PyInstaller's Qt dependency scanner can lose non-ASCII characters when it
# launches helper processes on Windows. Re-enter the same physical repository
# through a temporary ASCII-only SUBST drive; no files leave the repository.
if ($RepoRoot -match '[^\x00-\x7F]' -and $env:BUTTERFLY_BUILD_SUBST_ACTIVE -ne '1') {
    $UsedDriveNames = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpperInvariant() })
    $SubstDriveName = $null
    foreach ($Candidate in [char[]]'ZYXWVUTSRQP') {
        if ($UsedDriveNames -notcontains [string]$Candidate) {
            $SubstDriveName = [string]$Candidate
            break
        }
    }
    if ($null -eq $SubstDriveName) {
        throw 'No free drive letter is available for the non-ASCII-path build workaround.'
    }

    $SubstDrive = $SubstDriveName + ':'
    $PreviousSubstGuard = $env:BUTTERFLY_BUILD_SUBST_ACTIVE
    try {
        & subst.exe $SubstDrive $RepoRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to map $RepoRoot to temporary drive $SubstDrive."
        }
        $env:BUTTERFLY_BUILD_SUBST_ACTIVE = '1'
        $MappedScript = Join-Path ($SubstDrive + '\') 'scripts\build_portable.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MappedScript
        $NestedExitCode = $LASTEXITCODE
    }
    finally {
        $env:BUTTERFLY_BUILD_SUBST_ACTIVE = $PreviousSubstGuard
        & subst.exe $SubstDrive /D | Out-Null
    }
    exit $NestedExitCode
}

$ExpectedVersion = '1.1.0.2'
$VersionSource = Join-Path $RepoRoot 'butterfly_viewer\butterfly_viewer.py'
$RequirementsFile = Join-Path $RepoRoot 'requirements-build.txt'
$EntryPoint = Join-Path $RepoRoot 'butterfly_viewer\butterfly_viewer.py'
$IconPath = Join-Path $RepoRoot 'butterfly_viewer\icons\icon.ico'
$ReadmePath = Join-Path $RepoRoot 'README.md'
$LicensePath = Join-Path $RepoRoot 'LICENSE.txt'

$VenvPath = Join-Path $RepoRoot '.venv-build'
$VenvPython = Join-Path $VenvPath 'Scripts\python.exe'
$PyInstallerExe = Join-Path $VenvPath 'Scripts\pyinstaller.exe'
$CacheRoot = Join-Path $RepoRoot '.build-cache'
$PipCache = Join-Path $CacheRoot 'pip'
$TempRoot = Join-Path $CacheRoot 'tmp'
$PyInstallerConfig = Join-Path $CacheRoot 'pyinstaller'

# These are dedicated directories owned by this script. A marker is required
# before cleanup so an unrelated directory can never be recursively removed.
$BuildStaging = Join-Path $RepoRoot 'build\portable-staging'
$DistStaging = Join-Path $RepoRoot 'dist\portable-staging'
$StagingMarker = '.butterfly-viewer-portable-staging'
$ReleaseRoot = Join-Path $RepoRoot 'release'

function Assert-PathUnderRepository {
    param([Parameter(Mandatory)][string]$Path)

    $RootWithSeparator = ([IO.Path]::GetFullPath($RepoRoot)).TrimEnd('\') + '\'
    $FullPath = [IO.Path]::GetFullPath($Path)
    if (-not $FullPath.StartsWith($RootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the repository root: $Path"
    }
}

function Initialize-OwnedStaging {
    param([Parameter(Mandatory)][string]$Path)

    Assert-PathUnderRepository -Path $Path
    if (Test-Path -LiteralPath $Path) {
        $MarkerPath = Join-Path $Path $StagingMarker
        if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
            throw "Refusing to remove unmarked staging directory: $Path"
        }
        Remove-Item -LiteralPath $Path -Recurse -Force
    }

    [IO.Directory]::CreateDirectory($Path) | Out-Null
    Set-Content -LiteralPath (Join-Path $Path $StagingMarker) -Value 'Owned by scripts/build_portable.ps1' -Encoding ASCII
}

function Remove-OwnedStaging {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $MarkerPath = Join-Path $Path $StagingMarker
    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
        throw "Refusing to remove unmarked staging directory: $Path"
    }
    Assert-PathUnderRepository -Path $Path
    Remove-Item -LiteralPath $Path -Recurse -Force
}

foreach ($PathToCheck in @(
    $VersionSource, $RequirementsFile, $EntryPoint, $IconPath, $ReadmePath,
    $LicensePath, $VenvPath, $CacheRoot, $BuildStaging, $DistStaging,
    $ReleaseRoot
)) {
    Assert-PathUnderRepository -Path $PathToCheck
}

$PreviousEnvironment = @{}
foreach ($EnvironmentName in @('PIP_CACHE_DIR', 'TEMP', 'TMP', 'PYINSTALLER_CONFIG_DIR', 'PYTHONNOUSERSITE', 'PATH')) {
    $PreviousEnvironment[$EnvironmentName] = [Environment]::GetEnvironmentVariable($EnvironmentName, 'Process')
}

$BuildStagingInitialized = $false
$DistStagingInitialized = $false
$LocationPushed = $false

try {
    foreach ($RequiredPath in @($VersionSource, $RequirementsFile, $EntryPoint, $IconPath, $ReadmePath, $LicensePath)) {
        if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
            throw "Required file is missing: $RequiredPath"
        }
    }

    $VersionSourceText = Get-Content -LiteralPath $VersionSource -Raw -Encoding UTF8
    $VersionPattern = '(?m)^\s*VERSION\s*=\s*["''](?<version>[^"'']+)["'']\s*$'
    $VersionMatch = [Text.RegularExpressions.Regex]::Match($VersionSourceText, $VersionPattern)
    if (-not $VersionMatch.Success) {
        throw "Could not read VERSION from $VersionSource"
    }
    $Version = $VersionMatch.Groups['version'].Value
    if ($Version -ne $ExpectedVersion) {
        throw "Expected source VERSION $ExpectedVersion, found $Version"
    }

    [IO.Directory]::CreateDirectory($CacheRoot) | Out-Null
    [IO.Directory]::CreateDirectory($PipCache) | Out-Null
    [IO.Directory]::CreateDirectory($TempRoot) | Out-Null
    [IO.Directory]::CreateDirectory($PyInstallerConfig) | Out-Null
    $env:PIP_CACHE_DIR = $PipCache
    $env:TEMP = $TempRoot
    $env:TMP = $TempRoot
    $env:PYINSTALLER_CONFIG_DIR = $PyInstallerConfig
    $env:PYTHONNOUSERSITE = '1'

    if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
        $SystemPython = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($null -eq $SystemPython) {
            $SystemPython = Get-Command py.exe -ErrorAction SilentlyContinue
        }
        if ($null -eq $SystemPython) {
            throw 'Python 3 is required to create .venv-build.'
        }

        [IO.Directory]::CreateDirectory($VenvPath) | Out-Null
        if ($SystemPython.Name -ieq 'py.exe') {
            & $SystemPython.Source -3 -m venv $VenvPath
        }
        else {
            & $SystemPython.Source -m venv $VenvPath
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create the build environment (exit code $LASTEXITCODE)."
        }
    }

    if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
        throw "Build environment is missing its Python executable: $VenvPython"
    }

    & $VenvPython -m pip install --disable-pip-version-check --no-input --requirement $RequirementsFile
    if ($LASTEXITCODE -ne 0) {
        throw "Build dependency installation failed (exit code $LASTEXITCODE)."
    }
    if (-not (Test-Path -LiteralPath $PyInstallerExe -PathType Leaf)) {
        throw "PyInstaller executable was not installed: $PyInstallerExe"
    }

    # Avoid picking up unrelated tools and DLLs from the caller's PATH. In
    # particular, disable globally installed UPX and external runtime folders.
    $BasePythonRoot = (& $VenvPython -c 'import sys; print(sys.base_prefix)').Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($BasePythonRoot)) {
        throw 'Could not determine the base Python directory.'
    }
    $env:PATH = @(
        (Join-Path $VenvPath 'Scripts'),
        $BasePythonRoot,
        (Join-Path $BasePythonRoot 'Scripts'),
        (Join-Path $env:SystemRoot 'System32'),
        $env:SystemRoot
    ) -join ';'

    Initialize-OwnedStaging -Path $BuildStaging
    $BuildStagingInitialized = $true
    Initialize-OwnedStaging -Path $DistStaging
    $DistStagingInitialized = $true

    Push-Location -LiteralPath $RepoRoot
    $LocationPushed = $true
    $PyInstallerArguments = @(
        '--noconfirm', '--clean', '--noupx', '--onedir', '--windowed',
        '--name', 'butterfly_viewer',
        '--icon', $IconPath,
        '--distpath', $DistStaging,
        '--workpath', $BuildStaging,
        '--specpath', $BuildStaging,
        $EntryPoint
    )
    # Invoke as a module so a temporary SUBST path is preserved. The generated
    # pyinstaller.exe launcher embeds the original non-ASCII venv path.
    & $VenvPython -m PyInstaller @PyInstallerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "PyInstaller failed (exit code $LASTEXITCODE)."
    }

    $RuntimeDirectory = Join-Path $DistStaging 'butterfly_viewer'
    $RuntimeExecutable = Join-Path $RuntimeDirectory 'butterfly_viewer.exe'
    if (-not (Test-Path -LiteralPath $RuntimeExecutable -PathType Leaf)) {
        throw "PyInstaller output is missing: $RuntimeExecutable"
    }

    # A windowed PyInstaller process can remain alive while displaying its
    # unhandled-exception dialog. Require the actual application window so a
    # broken package cannot pass merely because its process still exists.
    $SmokeProcess = Start-Process -FilePath $RuntimeExecutable -PassThru
    try {
        $SmokeDeadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            Start-Sleep -Milliseconds 250
            $SmokeProcess.Refresh()
            if ($SmokeProcess.HasExited) {
                throw "Portable executable exited during startup (exit code $($SmokeProcess.ExitCode))."
            }
        } while ([string]::IsNullOrWhiteSpace($SmokeProcess.MainWindowTitle) -and [DateTime]::UtcNow -lt $SmokeDeadline)

        $SmokeProcess.Refresh()
        if ([string]::IsNullOrWhiteSpace($SmokeProcess.MainWindowTitle)) {
            throw 'Portable executable did not create a main window within 15 seconds.'
        }
        if ($SmokeProcess.MainWindowTitle -eq 'Unhandled exception in script') {
            throw 'Portable executable displayed an unhandled-exception dialog during startup.'
        }
        if ($SmokeProcess.MainWindowTitle -ne 'Butterfly Viewer') {
            throw "Portable executable created an unexpected window: $($SmokeProcess.MainWindowTitle)"
        }
        Write-Output "Startup smoke test passed: $($SmokeProcess.MainWindowTitle)"
    }
    finally {
        if (-not $SmokeProcess.HasExited) {
            Stop-Process -Id $SmokeProcess.Id -Force
            $SmokeProcess.WaitForExit()
        }
    }

    [IO.Directory]::CreateDirectory($ReleaseRoot) | Out-Null
    $ArchiveBaseName = "Butterfly_Viewer_v${Version}_Windows_Portable_zh-CN"
    $PackageStagingRoot = Join-Path $BuildStaging 'package'
    $PackageRoot = Join-Path $PackageStagingRoot $ArchiveBaseName
    [IO.Directory]::CreateDirectory($PackageRoot) | Out-Null
    Copy-Item -LiteralPath $RuntimeDirectory -Destination (Join-Path $PackageRoot 'butterfly_viewer') -Recurse
    Copy-Item -LiteralPath $ReadmePath -Destination (Join-Path $PackageRoot 'README.md')
    Copy-Item -LiteralPath $LicensePath -Destination (Join-Path $PackageRoot 'LICENSE.txt')

    $ZipPath = Join-Path $ReleaseRoot ($ArchiveBaseName + '.zip')
    Compress-Archive -LiteralPath $PackageRoot -DestinationPath $ZipPath -CompressionLevel Optimal -Force
    $Hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $HashPath = $ZipPath + '.sha256'
    Set-Content -LiteralPath $HashPath -Value ("$Hash  " + [IO.Path]::GetFileName($ZipPath)) -Encoding ASCII

    Write-Output "Created: $ZipPath"
    Write-Output "SHA-256: $HashPath"
}
finally {
    if ($LocationPushed) {
        Pop-Location
    }
    if ($DistStagingInitialized) {
        try { Remove-OwnedStaging -Path $DistStaging } catch { Write-Warning $_ }
    }
    if ($BuildStagingInitialized) {
        try { Remove-OwnedStaging -Path $BuildStaging } catch { Write-Warning $_ }
    }
    foreach ($EnvironmentName in $PreviousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($EnvironmentName, $PreviousEnvironment[$EnvironmentName], 'Process')
    }
}
