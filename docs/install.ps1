[CmdletBinding()]
param(
    [string]$Version = $(if ($env:SSH_COPY_ID_VERSION) { $env:SSH_COPY_ID_VERSION } else { "latest" }),
    [string]$InstallDir = $(if ($env:SSH_COPY_ID_INSTALL_DIR) { $env:SSH_COPY_ID_INSTALL_DIR } else { "" }),
    [ValidateSet("Auto", "User", "Machine")]
    [string]$Scope = $(if ($env:SSH_COPY_ID_SCOPE) { $env:SSH_COPY_ID_SCOPE } else { "Auto" }),
    [string]$PagesUrl = $(if ($env:SSH_COPY_ID_PAGES_URL) { $env:SSH_COPY_ID_PAGES_URL } else { "https://dasimmet.github.io/ssh-copy-id" }),
    [switch]$ModifyPath,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    Write-Output @"
ssh-copy-id installer for Windows

Usage:
  irm https://dasimmet.github.io/ssh-copy-id/install.ps1 | iex
  & ([scriptblock]::Create((irm https://dasimmet.github.io/ssh-copy-id/install.ps1))) [-Version <tag|latest|main>] [-Scope Auto|User|Machine] [-InstallDir <dir>] [-ModifyPath]

By default, installs into an existing writable directory already in PATH and
never modifies User or Machine PATH unless -ModifyPath is explicitly passed.

Environment overrides:
  SSH_COPY_ID_VERSION         Release tag, 'latest' (default; falls back to main build), or 'main'
  SSH_COPY_ID_SCOPE           Auto, User, or Machine (default: Auto)
  SSH_COPY_ID_INSTALL_DIR     Override destination directory
  SSH_COPY_ID_PAGES_URL       Override GitHub Pages base URL
"@
    return
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TargetTriple {
    $arch = $null
    try {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    } catch {
        $arch = $null
    }
    if (-not $arch) {
        if ($env:PROCESSOR_ARCHITEW6432) {
            $arch = $env:PROCESSOR_ARCHITEW6432
        } else {
            $arch = $env:PROCESSOR_ARCHITECTURE
        }
    }

    switch -Regex ($arch.ToUpperInvariant()) {
        "^(ARM64|AARCH64)$" { return "aarch64-windows" }
        "^(X64|AMD64|X86_64)$" { return "x86_64-windows" }
        "^(X86|I386|I686)$" { return "x86-windows" }
        default { throw "Unsupported Windows architecture: $arch" }
    }
}

function Test-DirWritable {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        return $false
    }
    $probe = Join-Path $Dir (".ssh-copy-id-write-test-" + [Guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::WriteAllText($probe, "")
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Test-IsIgnoredPathEntry {
    param([string]$Dir)
    if (-not $Dir -or -not [System.IO.Path]::IsPathRooted($Dir)) { return $true }
    $norm = $Dir.Trim().TrimEnd("\")
    if ($env:SystemRoot) {
        $sysRoot = $env:SystemRoot.TrimEnd("\")
        if ($norm.Equals($sysRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $norm.StartsWith($sysRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    if ($norm -like "*\node_modules\*") { return $true }
    if ($env:TEMP -and $norm.StartsWith($env:TEMP.TrimEnd("\"), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($env:TMP -and $norm.StartsWith($env:TMP.TrimEnd("\"), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($env:VIRTUAL_ENV -and $norm.StartsWith($env:VIRTUAL_ENV.TrimEnd("\"), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($env:CONDA_PREFIX -and $norm.StartsWith($env:CONDA_PREFIX.TrimEnd("\"), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

function Test-IsUserOwnedPath {
    param([string]$Dir)
    $norm = $Dir.TrimEnd("\")
    foreach ($root in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $HOME)) {
        if ($root) {
            $r = $root.TrimEnd("\")
            if ($norm.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or
                $norm.StartsWith($r + "\", [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Find-ExistingPathDir {
    param(
        [ValidateSet("Auto", "User", "Machine")][string]$TargetScope,
        [bool]$IsAdmin
    )

    $entries = ($env:Path -split ";") | ForEach-Object { $_.Trim().TrimEnd("\") } | Where-Object { $_ -ne "" }

    if ($TargetScope -eq "User" -or $TargetScope -eq "Auto") {
        $commonUserDirs = @()
        if ($env:LOCALAPPDATA) {
            $commonUserDirs += (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps")
            $commonUserDirs += (Join-Path $env:LOCALAPPDATA "Programs\bin")
        }
        $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
        if ($userHome) {
            $commonUserDirs += (Join-Path $userHome ".local\bin")
            $commonUserDirs += (Join-Path $userHome "bin")
            $commonUserDirs += (Join-Path $userHome "scoop\shims")
        }

        foreach ($preferred in $commonUserDirs) {
            $prefNorm = $preferred.TrimEnd("\")
            $inPath = $false
            foreach ($entry in $entries) {
                if ($entry.Equals($prefNorm, [StringComparison]::OrdinalIgnoreCase)) {
                    $inPath = $true
                    break
                }
            }
            if (-not $inPath) { continue }
            if (Test-DirWritable $prefNorm) { return $prefNorm }
            if (-not (Test-Path -LiteralPath $prefNorm) -and $userHome -and
                $prefNorm.StartsWith($userHome.TrimEnd("\") + "\", [StringComparison]::OrdinalIgnoreCase) -and
                -not $prefNorm.EndsWith("scoop\shims", [StringComparison]::OrdinalIgnoreCase)) {
                try {
                    New-Item -ItemType Directory -Force -Path $prefNorm | Out-Null
                    if (Test-DirWritable $prefNorm) { return $prefNorm }
                } catch {}
            }
        }

        foreach ($entry in $entries) {
            if (Test-IsIgnoredPathEntry $entry) { continue }
            if (-not (Test-IsUserOwnedPath $entry)) { continue }
            if (Test-DirWritable $entry) { return $entry }
        }
    }

    if ($TargetScope -eq "Machine" -or ($TargetScope -eq "Auto" -and $IsAdmin)) {
        foreach ($entry in $entries) {
            if (Test-IsIgnoredPathEntry $entry) { continue }
            if ($TargetScope -eq "Machine" -and (Test-IsUserOwnedPath $entry)) { continue }
            if (Test-DirWritable $entry) { return $entry }
        }
    }

    return $null
}

function Test-InCurrentPath {
    param([string]$Dir)
    $normalized = $Dir.TrimEnd("\")
    foreach ($entry in ($env:Path -split ";")) {
        if ($entry.Trim().TrimEnd("\").Equals($normalized, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Add-ToPath {
    param(
        [string]$Dir,
        [ValidateSet("User", "Machine")][string]$TargetScope
    )

    $normalized = $Dir.TrimEnd("\")
    $existing = [Environment]::GetEnvironmentVariable("Path", $TargetScope)
    $entries = @()
    if ($existing) {
        $entries = $existing -split ";" | Where-Object { $_.Trim() -ne "" }
    }

    $alreadyInScope = $false
    foreach ($entry in $entries) {
        if ($entry.Trim().TrimEnd("\").Equals($normalized, [StringComparison]::OrdinalIgnoreCase)) {
            $alreadyInScope = $true
            break
        }
    }

    if (-not $alreadyInScope) {
        $newPath = if ($entries.Count -gt 0) {
            ($entries -join ";") + ";" + $Dir
        } else {
            $Dir
        }
        [Environment]::SetEnvironmentVariable("Path", $newPath, $TargetScope)
        Write-Host "Added '$Dir' to $TargetScope PATH."
    } else {
        Write-Host "'$Dir' is already in $TargetScope PATH."
    }

    if (-not (Test-InCurrentPath $Dir)) {
        $env:Path = "$Dir;$env:Path"
    }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
} catch {}

$isAdmin = Test-IsAdmin
$effectiveScope = $Scope
if ($effectiveScope -eq "Auto") {
    $effectiveScope = if ($isAdmin) { "Machine" } else { "User" }
}
if ($Scope -eq "Machine" -and -not $isAdmin) {
    throw "System-wide installation (-Scope Machine) requires an Administrator PowerShell session. Run without -Scope Machine for a user-level install."
}

if (-not $InstallDir) {
    $foundInPath = Find-ExistingPathDir -TargetScope $Scope -IsAdmin $isAdmin
    if ($foundInPath) {
        $InstallDir = $foundInPath
    } elseif ($effectiveScope -eq "Machine") {
        $InstallDir = Join-Path $env:ProgramFiles "ssh-copy-id\bin"
    } else {
        $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME "AppData\Local" }
        $InstallDir = Join-Path $localAppData "Programs\ssh-copy-id\bin"
    }
}

$target = Get-TargetTriple
$archiveName = "ssh-copy-id-$target.zip"
$releaseBase = "https://github.com/dasimmet/ssh-copy-id/releases/latest/download"
$mainBase = ($PagesUrl.TrimEnd("/")) + "/builds/main"

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ssh-copy-id-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

try {
    $archivePath = Join-Path $tmpRoot $archiveName
    $checksumsPath = Join-Path $tmpRoot "checksums.txt"
    $extractDir = Join-Path $tmpRoot "extract"

    $activeBase = $null
    if ($Version -eq "main") {
        $activeBase = $mainBase
        Write-Host "Downloading $archiveName (latest main build)..."
        Invoke-WebRequest -Uri "$activeBase/$archiveName" -OutFile $archivePath -UseBasicParsing
    } elseif ($Version -eq "latest") {
        Write-Host "Downloading $archiveName (latest release)..."
        try {
            Invoke-WebRequest -Uri "$releaseBase/$archiveName" -OutFile $archivePath -UseBasicParsing
            $activeBase = $releaseBase
        } catch {
            Write-Host "No GitHub Release found; falling back to latest main build..."
            $activeBase = $mainBase
            Invoke-WebRequest -Uri "$activeBase/$archiveName" -OutFile $archivePath -UseBasicParsing
        }
    } else {
        $activeBase = "https://github.com/dasimmet/ssh-copy-id/releases/download/$Version"
        Write-Host "Downloading $archiveName ($Version)..."
        Invoke-WebRequest -Uri "$activeBase/$archiveName" -OutFile $archivePath -UseBasicParsing
    }

    $checksumsUrl = "$activeBase/checksums.txt"

    try {
        Invoke-WebRequest -Uri $checksumsUrl -OutFile $checksumsPath -UseBasicParsing
        $expectedLine = Get-Content -Path $checksumsPath | Where-Object {
            $_ -match ("^\s*([0-9a-fA-F]{64})\s+\*?" + [Regex]::Escape($archiveName) + "\s*$")
        } | Select-Object -First 1

        if ($expectedLine) {
            $expectedHash = ($expectedLine -split "\s+")[0].ToLowerInvariant()
            $actualHash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -ne $expectedHash) {
                throw "SHA256 verification failed for $archiveName (expected $expectedHash, got $actualHash)."
            }
            Write-Host "Verified SHA256 checksum."
        } else {
            Write-Warning "Checksum entry for $archiveName not found in checksums.txt; skipping verification."
        }
    } catch {
        if ($_.Exception.Message -like "SHA256 verification failed*") {
            throw
        }
        Write-Warning "Could not download checksums.txt; skipping verification."
    }

    Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force
    $exeSrc = Get-ChildItem -Path $extractDir -Filter "ssh-copy-id.exe" -Recurse | Select-Object -First 1
    if (-not $exeSrc) {
        throw "ssh-copy-id.exe not found inside $archiveName."
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $destExe = Join-Path $InstallDir "ssh-copy-id.exe"
    Copy-Item -Path $exeSrc.FullName -Destination $destExe -Force

    Write-Host "Installed ssh-copy-id to $destExe"
    & $destExe --version

    if (-not (Test-InCurrentPath $InstallDir)) {
        if ($ModifyPath) {
            Add-ToPath -Dir $InstallDir -TargetScope $effectiveScope
        } else {
            Write-Host ""
            Write-Host "Note: '$InstallDir' is not in PATH (PATH was not modified)."
            Write-Host "Add it to your PATH manually, or re-run with -ModifyPath."
        }
    }
} finally {
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
