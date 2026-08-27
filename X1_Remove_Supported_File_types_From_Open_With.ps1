# ============================================================
# Unregister-MPV.ps1
# Removes mpv system integration (App Paths, Open With, SupportedTypes, PATH)
# Matches register style: step-by-step, diagnostics, pause on finish/error
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

# Global trap: catch ANY unhandled error and pause visibly
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

Write-Host "`n🧹 Starting unregistration steps..." -ForegroundColor Cyan

# Step 1: Remove App Paths
Write-Host "→ Removing App Paths..." -ForegroundColor Yellow
$appPaths = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe"
Remove-Item -Path $appPaths -Recurse -Force -ErrorAction Ignore
Write-Host "[OK] App Paths removed (or already gone)" -ForegroundColor Green

# Step 2: Remove Open With + SupportedTypes
Write-Host "→ Removing Open With registration (including SupportedTypes)..." -ForegroundColor Yellow
$appKey = "HKLM:\SOFTWARE\Classes\Applications\mpv.exe"
Remove-Item -Path $appKey -Recurse -Force -ErrorAction Ignore
Write-Host "[OK] Open With registration removed (or already gone)" -ForegroundColor Green

# Step 3: Remove from PATH
Write-Host "→ Trying to remove from PATH..." -ForegroundColor Yellow
$envKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
try {
    $currentPath = (Get-ItemProperty -Path $envKey -Name Path -ErrorAction Stop).Path
    $mpvDirEscaped = [regex]::Escape($mpvDir)

    if ($currentPath -match $mpvDirEscaped) {
        $newPath = ($currentPath -split ';' | Where-Object { $_ -notmatch "^$mpvDirEscaped$" -and $_ -ne '' }) -join ';'
        Set-ItemProperty -Path $envKey -Name Path -Value $newPath -ErrorAction Stop
        Write-Host "[OK] Removed mpv directory from PATH" -ForegroundColor Green
    } else {
        Write-Host "ℹ️  Directory not found in PATH — no change needed" -ForegroundColor DarkGray
    }
}
catch {
    Write-Host "⚠️  PATH removal skipped: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "   (You can remove '$mpvDir' from PATH manually if needed)" -ForegroundColor DarkGray
}

# Summary & pause
Write-Host "`n=== Unregistration Complete ===" -ForegroundColor Cyan
Write-Host "mpv system integration removed:"
Write-Host "  • No longer appears in Win+R or Open With"
Write-Host "  • SupportedTypes and PATH entry cleaned (if present)"
Write-Host "Note: PATH changes visible only in new cmd/PowerShell or after logoff"

Write-Host "`nPress Enter to close..." -ForegroundColor White
$null = Read-Host