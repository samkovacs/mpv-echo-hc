# ============================================================
# Register-MPV.ps1  (fixed version)
# ============================================================

# Auto-elevate
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host "Not running as admin → requesting elevation..." -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    )
    exit
}

Write-Host "Running elevated as admin." -ForegroundColor Green

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Global trap for any unhandled errors
trap {
    Write-Host "`n[CRASH] $($_.Exception.GetType().FullName): $($_.Exception.Message)" -ForegroundColor Red -BackgroundColor Black
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host "`nPress Enter to close..." -ForegroundColor White
    $null = Read-Host
    exit 1
}

$mpvDir = $PSScriptRoot
if (-not $mpvDir) {
    $mpvDir = Get-Location
    Write-Host "Warning: PSScriptRoot was empty, fell back to Get-Location" -ForegroundColor Yellow
}

$mpvExe = Join-Path $mpvDir "mpv.exe"

Write-Host "`n=== Diagnostic Info ===" -ForegroundColor Cyan
Write-Host "Script location (PSScriptRoot) : $PSScriptRoot"
Write-Host "Current directory (Get-Location): $(Get-Location)"
Write-Host "Resolved mpv directory          : $mpvDir"
Write-Host "Resolved mpv.exe path           : $mpvExe"
Write-Host "mpv.exe exists?                 : $(Test-Path $mpvExe)" -ForegroundColor $(if (Test-Path $mpvExe) {"Green"} else {"Red"})

if (-not (Test-Path $mpvExe)) {
    Write-Host "`n[X] ERROR: mpv.exe not found!" -ForegroundColor Red
    Write-Host "   Place this script in the same folder as mpv.exe"
    Write-Host "   Press Enter to exit..." -ForegroundColor White
    $null = Read-Host
    exit 1
}

Write-Host "`n🔧 Starting registration steps..." -ForegroundColor Cyan

# App Paths
Write-Host "→ Registering App Paths..." -ForegroundColor Yellow
$appPaths = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe"
New-Item -Path $appPaths -Force | Out-Null
Set-ItemProperty -Path $appPaths -Name "(Default)" -Value $mpvExe
Set-ItemProperty -Path $appPaths -Name "Path" -Value $mpvDir
Write-Host "[OK] App Paths done" -ForegroundColor Green

# Open With base
Write-Host "→ Registering Open With base..." -ForegroundColor Yellow
$appKey = "HKLM:\SOFTWARE\Classes\Applications\mpv.exe"
New-Item -Path $appKey -Force | Out-Null
Set-ItemProperty -Path $appKey -Name "FriendlyAppName" -Value "mpv media player"

$cmdKey = "$appKey\shell\open\command"
New-Item -Path $cmdKey -Force | Out-Null
Set-ItemProperty -Path $cmdKey -Name "(Default)" -Value "`"$mpvExe`" `"%1`""
Write-Host "[OK] Open With base done" -ForegroundColor Green

# SupportedTypes with **fixed** grouped output
Write-Host "→ Adding SupportedTypes..." -ForegroundColor Yellow
$supported = @(
    ".3g2",".3gp",".asf",".avi",".flv",".m2ts",".m4v",".mkv",".mov",
    ".mp4",".mpeg",".mpg",".mts",".ogm",".ogv",".rm",".rmvb",".ts",
    ".vob",".webm",".wmv",".mka",".mp3",".ogg",".opus",".wav",".wma"
)
$groupSize = 4

Set-ItemProperty -Path $appKey -Name "SupportedTypes" -Value $supported -Type MultiString -Force
Write-Host "[OK] SupportedTypes added ($($supported.Count) extensions)" -ForegroundColor Green
Write-Host "Extensions:" -ForegroundColor DarkGray

for ($i = 0; $i -lt $supported.Count; $i += $groupSize) {
    $end = [Math]::Min($i + $groupSize - 1, $supported.Count - 1)
    $group = $supported[$i..$end] -join ", "
    Write-Host "  $group" -ForegroundColor DarkGray
}

# PATH (protected)
Write-Host "→ Trying to update PATH..." -ForegroundColor Yellow
$envKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
try {
    $currentPath = (Get-ItemProperty -Path $envKey -Name Path -ErrorAction Stop).Path
    $mpvDirEscaped = [regex]::Escape($mpvDir)
    if ($currentPath -notmatch $mpvDirEscaped) {
        $newPath = "$currentPath;$mpvDir".TrimEnd(';')
        Set-ItemProperty -Path $envKey -Name Path -Value $newPath -ErrorAction Stop
        Write-Host "[OK] PATH updated" -ForegroundColor Green
    } else {
        Write-Host "ℹ️  Already in PATH" -ForegroundColor DarkGray
    }
}
catch {
    Write-Host "⚠️  PATH update skipped: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "`n=== Registration Complete ===" -ForegroundColor Cyan
Write-Host "mpv registered successfully (Win+R + improved Open With)"
Write-Host "Note: PATH changes need new cmd/PowerShell window or logoff"

Write-Host "`nPress Enter to close..." -ForegroundColor White
$null = Read-Host