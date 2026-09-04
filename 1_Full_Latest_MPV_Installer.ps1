# ============================================================
# Portable mpv / ffmpeg / yt-dlp Installer & Updater
# Modernized style matching register/unregister scripts
# Works best with PowerShell 7; compatible with Windows PowerShell 3+
# ============================================================

#requires -Version 3
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Settings
# -----------------------------
$useragent = "mpv-win-updater"
$arch = "x86_64-v3"
$mpvChannel = "daily"   # or "weekly"

$fallback7z = Join-Path $PSScriptRoot "7z\7zr.exe"
$script:Downloaded7z = $false

$global:ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ghHeaders = @{
    "User-Agent" = $useragent
    "Accept"     = "application/vnd.github+json"
}

# -----------------------------
# Directory Setup
# -----------------------------
# No elevation here: this script only downloads/extracts into its own
# portable folder and writes marker files, which never requires admin.
$installDir = $PSScriptRoot
if (-not $installDir) {
    $installDir = Get-Location
    Write-Host "Warning: PSScriptRoot was empty, fell back to Get-Location" -ForegroundColor Yellow
}

Write-Host "`n=== Diagnostic Info ===" -ForegroundColor Cyan
Write-Host "Script location (PSScriptRoot) : $PSScriptRoot"
Write-Host "Current directory (Get-Location): $(Get-Location)"
Write-Host "Install/Extract directory       : $installDir"
Write-Host "Fallback 7zr path               : $fallback7z"

# -----------------------------
# Helpers
# -----------------------------
function Get-7z {
    $cmd = Get-Command 7z.exe -ErrorAction Ignore | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    try {
        $p = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip" -ErrorAction Stop
        if ($p.InstallLocation) {
            $exe = Join-Path $p.InstallLocation "7z.exe"
            if (Test-Path $exe) { return $exe }
        }
    } catch { }

    if (Test-Path $fallback7z) { return $fallback7z }
    return $null
}

function Check-7z {
    if (Get-7z) { return }
    $script:Downloaded7z = $true
    New-Item -ItemType Directory -Force (Split-Path $fallback7z -Parent) | Out-Null
    Write-Host "Downloading 7zr.exe (temporary)..." -ForegroundColor Green
    Invoke-WebRequest "https://www.7-zip.org/a/7zr.exe" -OutFile $fallback7z
}

function Cleanup-7z {
    if ($script:Downloaded7z) {
        Remove-Item -Force $fallback7z -ErrorAction Ignore
        Remove-Item -Force -Recurse (Split-Path $fallback7z -Parent) -ErrorAction Ignore
    }
}

function Download-File($url, $outFile) {
    $outPath = Join-Path $installDir $outFile
    Write-Host "Downloading → $outFile" -ForegroundColor Green
    Invoke-WebRequest $url -Headers $ghHeaders -OutFile $outPath
    return $outPath
}

function Extract-Archive($archivePath) {
    Check-7z
    $seven = Get-7z
    if (-not $seven) { throw "7z not available." }
    Write-Host "Extracting $archivePath ..." -ForegroundColor Green
    & $seven x -y "-o$installDir" $archivePath | Out-Null
}

# -----------------------------
# Cleanup junk files
# -----------------------------
function Cleanup-Extras {
    $junk = @("installer", "mpv-register.bat", "mpv-unregister.bat", "updater.bat")
    foreach ($item in $junk) {
        $path = Join-Path $installDir $item
        if (Test-Path $path) {
            Remove-Item -Force -Recurse $path -ErrorAction Ignore
            Write-Host "Removed leftover: $item" -ForegroundColor DarkGray
        }
    }
}

# -----------------------------
# GitHub / Release Helpers
# -----------------------------
function Get-Latest-Release-Asset($repoApiLatest, $nameRegex) {
    Write-Host "Fetching latest release from $repoApiLatest ..." -ForegroundColor Green
    try {
        $json = Invoke-RestMethod $repoApiLatest -Headers $ghHeaders
    }
    catch {
        Write-Host "RestMethod failed, falling back..." -ForegroundColor Yellow
        $raw = Invoke-WebRequest $repoApiLatest -Headers $ghHeaders -UseBasicParsing
        $json = $raw.Content | ConvertFrom-Json
    }

    $asset = $json.assets | Where-Object { $_.name -match $nameRegex } | Select-Object -First 1
    if (-not $asset) { throw "No matching asset found for regex: $nameRegex" }

    return $asset.name, $asset.browser_download_url
}

function Get-Latest-Mpv {
    $api = if ($mpvChannel -eq "daily") {
        "https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest"
    } else {
        "https://api.github.com/repos/zhongfly/mpv-winbuild/releases/latest"
    }
    Get-Latest-Release-Asset $api "^mpv-$arch-.*\.7z$"
}

function Get-Latest-FFmpeg {
    Get-Latest-Release-Asset "https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest" "^ffmpeg-$arch-.*\.7z$"
}

function Get-Latest-YtDlp-Version {
    Write-Host "Fetching yt-dlp latest version..." -ForegroundColor Green
    $xml = [xml](Invoke-WebRequest "https://github.com/yt-dlp/yt-dlp/releases.atom" -UseBasicParsing).Content
    $xml.feed.entry[0].link.href.Split("/")[-1]
}

function Get-Latest-Guessit-Version {
    Write-Host "Fetching guessit latest version..." -ForegroundColor Green
    $xml = [xml](Invoke-WebRequest "https://github.com/guessit-io/guessit/releases.atom" -UseBasicParsing).Content
    $xml.feed.entry[0].link.href.Split("/")[-1]
}

# -----------------------------
# Updaters
# -----------------------------
function Upgrade-Mpv {
    $remoteName, $url = Get-Latest-Mpv
    $marker = Join-Path $installDir ".mpv_last_archive.txt"

    if (Test-Path $marker) {
        $last = Get-Content $marker -ErrorAction Ignore | Select-Object -First 1
        if ($last -eq $remoteName) {
            Write-Host "mpv is already up to date." -ForegroundColor Green
            return
        }
    }

    $archivePath = Download-File $url $remoteName
    Extract-Archive $archivePath
    Cleanup-Extras
    Remove-Item $archivePath -Force -ErrorAction Ignore
    Set-Content $marker $remoteName -Encoding ASCII
    Write-Host "✔ mpv updated" -ForegroundColor Green
}

function Upgrade-FFmpeg {
    $remoteName, $url = Get-Latest-FFmpeg
    $marker = Join-Path $installDir ".ffmpeg_last_archive.txt"

    if (Test-Path $marker) {
        $last = Get-Content $marker -ErrorAction Ignore | Select-Object -First 1
        if ($last -eq $remoteName) {
            Write-Host "ffmpeg is already up to date." -ForegroundColor Green
            return
        }
    }

    $archivePath = Download-File $url $remoteName
    Extract-Archive $archivePath
    Cleanup-Extras
    Remove-Item $archivePath -Force -ErrorAction Ignore
    Set-Content $marker $remoteName -Encoding ASCII
    Write-Host "✔ ffmpeg updated" -ForegroundColor Green
}

function Upgrade-YtDlp {
    $ver = Get-Latest-YtDlp-Version
    $exe = Join-Path $installDir "yt-dlp.exe"

    if (Test-Path $exe) {
        try {
            $currentVer = & $exe --version
            if ($currentVer -eq $ver) {
                Write-Host "yt-dlp is already up to date ($ver)." -ForegroundColor Green
                return
            }
        } catch { }
    }

    Download-File "https://github.com/yt-dlp/yt-dlp/releases/download/$ver/yt-dlp.exe" "yt-dlp.exe" | Out-Null
    Write-Host "✔ yt-dlp updated to $ver" -ForegroundColor Green
}

function Upgrade-Guessit {
    # Required by portable_config/scripts/autochapters (mpv-auto-chapters).
    # Dropped in $installDir alongside mpv.exe/yt-dlp.exe so mpv's bare
    # "guessit" subprocess call finds it without any PATH registration --
    # Windows searches the calling exe's own directory before PATH.
    $ver = Get-Latest-Guessit-Version
    $marker = Join-Path $installDir ".guessit_last_version.txt"

    if (Test-Path $marker) {
        $last = Get-Content $marker -ErrorAction Ignore | Select-Object -First 1
        if ($last -eq $ver) {
            Write-Host "guessit is already up to date ($ver)." -ForegroundColor Green
            return
        }
    }

    Download-File "https://github.com/guessit-io/guessit/releases/download/$ver/guessit-windows.exe" "guessit.exe" | Out-Null
    Set-Content $marker $ver -Encoding ASCII
    Write-Host "✔ guessit updated to $ver" -ForegroundColor Green
}

# -----------------------------
# Main Execution
# -----------------------------
try {
    Write-Host "`nStarting mpv portable update/install..." -ForegroundColor Cyan
    Write-Host "Target folder: $installDir`n" -ForegroundColor DarkGray

    Upgrade-Mpv
    Upgrade-YtDlp
    Upgrade-Guessit
    Upgrade-FFmpeg

    Cleanup-7z

    Write-Host "`n=== All components updated successfully ===" -ForegroundColor Magenta
    Write-Host "mpv, ffmpeg, yt-dlp are now ready in: $installDir"
    Write-Host "You can now use the register script to make mpv easily launchable." -ForegroundColor White
}
catch {
    Cleanup-7z
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    exit 1
}

Write-Host "`nPress Enter to close this window..." -ForegroundColor White
$null = Read-Host