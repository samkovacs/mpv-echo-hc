# ============================================================
# Configuration Manager
# Toggle common mpv.conf / script-opts settings without hand-editing
# config files. No admin required -- reads and rewrites only the
# specific lines it changes, leaving every comment and every other
# setting in the file exactly where it was.
# Works best with PowerShell 7; compatible with Windows PowerShell 3+
# ============================================================

# WPF requires an STA thread. Most double-click/right-click "Run with
# PowerShell" launches are already STA, but this isn't guaranteed across
# PowerShell hosts/versions -- relaunch under -STA rather than assume.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
    $psExe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $psExe -ArgumentList @(
        "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    ) -Wait
    exit
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

trap {
    Write-Host "`n[CRASH] $($_.Exception.GetType().FullName): $($_.Exception.Message)" -ForegroundColor Red -BackgroundColor Black
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host "`nPress Enter to close..." -ForegroundColor White
    $null = Read-Host
    exit 1
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# -----------------------------
# Paths
# -----------------------------
$installDir = $PSScriptRoot
if (-not $installDir) {
    $installDir = Get-Location
    Write-Host "Warning: PSScriptRoot was empty, fell back to Get-Location" -ForegroundColor Yellow
}

Write-Host "`n=== Diagnostic Info ===" -ForegroundColor Cyan
Write-Host "Script location (PSScriptRoot) : $PSScriptRoot"
Write-Host "Current directory (Get-Location): $(Get-Location)"
Write-Host "Install directory                : $installDir"

$configRoot = Join-Path $installDir "portable_config"
$mpvConf    = Join-Path $configRoot "mpv.conf"
$optsDir    = Join-Path $configRoot "script-opts"

$vsrConf      = Join-Path $optsDir "vsr_autocrop.conf"
$hdrConf      = Join-Path $optsDir "hdr-mode.conf"
$chapterConf  = Join-Path $optsDir "chapterskip.conf"
$surroundConf = Join-Path $optsDir "prefer_surround_echostorm.conf"
$thumbConf    = Join-Path $optsDir "thumbfast.conf"
$reloadConf   = Join-Path $optsDir "reload.conf"
$ytdlConf     = Join-Path $optsDir "ytdlautoformat.conf"

foreach ($f in @($mpvConf, $vsrConf, $hdrConf, $chapterConf, $surroundConf, $thumbConf, $reloadConf, $ytdlConf)) {
    if (-not (Test-Path $f)) {
        [System.Windows.MessageBox]::Show("Missing config file:`n$f`n`nRun this from the mpv install root.", "Configuration Manager", "OK", "Error") | Out-Null
        exit 1
    }
}

# -----------------------------
# File read/write (line-level, no full-file rewrite)
# -----------------------------
# Keeps every comment and every setting we're not touching byte-for-byte
# -- only the specific lines a changed setting owns get replaced.
function Read-ConfigFile {
    param([string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path)
    $eol = "`n"
    if ($raw -match "`r`n") { $eol = "`r`n" }
    $trailingNewline = $raw.EndsWith($eol)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($raw -split "`r?`n")) { $lines.Add($line) }
    if ($trailingNewline -and $lines.Count -gt 0) { $lines.RemoveAt($lines.Count - 1) }
    return @{ Path = $Path; Lines = $lines; Eol = $eol; TrailingNewline = $trailingNewline }
}

function Write-ConfigFile {
    param($File)
    $content = [string]::Join($File.Eol, $File.Lines)
    if ($File.TrailingNewline) { $content += $File.Eol }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($File.Path, $content, $utf8NoBom)
}

# -----------------------------
# Setting definitions
# -----------------------------
# Kind:
#   Bool          -- plain "key=yes|no" line
#   CommentedBool -- a fixed line that's either present as-is (on) or
#                    prefixed with # (off), e.g. mpv.conf's opt-in fixes
#   Enum          -- "key=value" where value is one of a fixed list
#   Text          -- "key=value" where value is a free-form string
$settings = @(
    @{ Group = "Language"; Label = "Audio language priority"; File = $mpvConf; Kind = "Text"; Key = "alang"
       Tooltip = "Comma-separated language codes, in priority order (e.g. jpn,eng,und,auto). und = untagged tracks (common on HLS), auto = respect the container's DEFAULT= flag if nothing else matches. Mainly useful for prioritizing subbed/dubbed audio, e.g. anime." }
    @{ Group = "Language"; Label = "Subtitle language priority"; File = $mpvConf; Kind = "Text"; Key = "slang"
       Tooltip = "Comma-separated language codes, in priority order, for subtitle track auto-selection (e.g. eng,en)." }

    @{ Group = "Video"; Label = "Motion interpolation (smoothing)"; File = $mpvConf; Kind = "Bool"; Key = "interpolation"
       Tooltip = "Generates smoother motion by resampling existing frames to the display refresh rate. Off by default -- some GPU overhead." }
    @{ Group = "Video"; Label = "Debanding"; File = $mpvConf; Kind = "Bool"; Key = "deband"
       Tooltip = "Smooths out color-banding artifacts in gradients (skies, dark scenes). Off by default." }
    @{ Group = "Video"; Label = "Auto-crop black bars"; File = $vsrConf; Kind = "Bool"; Key = "auto_crop"
       Tooltip = "Detects and crops letterbox/pillarbox bars as part of the same evaluation that decides RTX VSR's scale factor. VSR upscaling still works with this off, just without cropping first." }
    @{ Group = "Video"; Label = "NVIDIA RTX Video HDR"; File = $vsrConf; Kind = "Bool"; Key = "nvidia_true_hdr"
       Tooltip = "Optional SDR->HDR enhancement (mpv 0.40+, requires RTX Video HDR enabled in the NVIDIA app). Only ever applies when the display is confirmed already in HDR mode -- otherwise a no-op." }
    @{ Group = "Video"; Label = "HDR display mode"; File = $hdrConf; Kind = "Enum"; Key = "hdr_mode"; Options = @("noth", "pass", "switch")
       Tooltip = "noth = do nothing. pass = pass HDR through when the display is already in HDR mode (no flicker risk). switch = auto-switch the display between HDR/SDR based on content (can flicker on some monitors)." }
    @{ Group = "Video"; Label = "Video sync"; File = $mpvConf; Kind = "Enum"; Key = "video-sync"; Options = @("display-resample", "audio")
       Tooltip = "display-resample resamples audio to match display refresh for smoother motion. Switch to audio for live/HLS streams -- display-resample can cause issues there." }

    @{ Group = "Audio"; Label = "Prefer surround audio track"; File = $surroundConf; Kind = "Bool"; Key = "enabled"
       Tooltip = "On file load, auto-selects whichever audio track reports the highest channel count -- but only among tracks matching mpv's own language selection, never overriding it just for more channels." }
    @{ Group = "Audio"; Label = "Fix audio cutting out on seek/skip (HDMI AVR workaround)"; File = $mpvConf; Kind = "CommentedBool"
       ActiveLine = "audio-stream-silence=yes"
       Tooltip = "Uncomment if your audio cuts out, drops, or goes silent right after seeking/unpausing/skipping tracks -- a known issue with older or budget HDMI A/V receivers/soundbars. mpv's manual calls this 'strongly discouraged' for general use, so it's opt-in." }
    @{ Group = "Audio"; Label = "Volume normalization (dynaudnorm)"; File = $mpvConf; Kind = "CommentedBool"
       ActiveLine = "af=lavfi=[dynaudnorm=f=150:g=15:p=0.95]"
       Tooltip = "Single-pass, live-stream-safe volume leveler -- useful for loud/quiet live streams. Unlike loudnorm it won't buffer the entire file before starting." }

    @{ Group = "Chapters"; Label = "Auto-skip OP/ED/preview chapters"; File = $chapterConf; Kind = "Bool"; Key = "enabled"
       Tooltip = "Automatically skips opening, ending, and next-episode preview chapters when present." }

    @{ Group = "Streaming"; Label = "Thumbnails on network streams"; File = $thumbConf; Kind = "Bool"; Key = "network"
       Tooltip = "Generates seekbar thumbnail previews for network/stream sources, not just local files." }
    @{ Group = "Streaming"; Label = "Stream cache size"; File = $mpvConf; Kind = "Text"; Key = "demuxer-max-bytes"
       Tooltip = "Maximum demuxer cache size (e.g. 50MiB). Larger absorbs longer stalls on HLS/live streams at the cost of more RAM; smaller reduces memory use but tolerates less network hiccup before stalling." }
    @{ Group = "Streaming"; Label = "Max stream quality cap"; File = $ytdlConf; Kind = "Enum"; Key = "quality"; Options = @("0", "240", "360", "480", "720", "1080", "1440", "2160", "4320")
       Tooltip = "Caps ytdl-format's requested quality for YouTube/Twitch/Kick at load time (0 = no cap/best available). Can still be bumped up/down mid-stream from the right-click Playback menu." }
    @{ Group = "Streaming"; Label = "Auto-reload on paused/stalled cache"; File = $reloadConf; Kind = "Bool"; Key = "paused_for_cache_timer_enabled"
       Tooltip = "If playback stays paused-for-cache past the configured timeout, reloads the stream from its last position." }
    @{ Group = "Streaming"; Label = "Auto-reload on stalled demuxer cache"; File = $reloadConf; Kind = "Bool"; Key = "demuxer_cache_timer_enabled"
       Tooltip = "If the demuxer cache stops receiving data for too long, treats it as stalled and reloads once the cache depletes." }
    @{ Group = "Streaming"; Label = "Reload stream at end-of-file"; File = $reloadConf; Kind = "Bool"; Key = "reload_eof_enabled"
       Tooltip = "For live streams: reloads at end-of-file to check for more content, instead of treating EOF as the actual end." }
)

# -----------------------------
# Line pattern / value helpers
# -----------------------------
function Get-DefPattern {
    param($Def)
    if ($Def.Kind -eq "Bool") { return "^$([regex]::Escape($Def.Key))=(yes|no)$" }
    if ($Def.Kind -eq "Enum") { return "^$([regex]::Escape($Def.Key))=(.+)$" }
    if ($Def.Kind -eq "Text") { return "^$([regex]::Escape($Def.Key))=(.*)$" }
    if ($Def.Kind -eq "CommentedBool") { return "^#?$([regex]::Escape($Def.ActiveLine))$" }
    throw "Unknown setting Kind: $($Def.Kind)"
}

function Find-DefLineIndex {
    param($Def, $Lines)
    $pattern = Get-DefPattern $Def
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        # Stop before any profile section ([WEB-DL], etc.). Every setting
        # this tool edits is a global default, never a profile-scoped
        # override -- mpv.conf's [WEB-DL] profile sets its own deband=yes,
        # for instance, and that must never be mistaken for the global
        # deband=no/yes line just because the key name matches.
        if ($Lines[$i] -match '^\s*\[.+\]\s*$') { break }
        if ([regex]::IsMatch($Lines[$i], $pattern)) { return $i }
    }
    return -1
}

function Get-DefValue {
    param($Def, $Lines, [int]$Index)
    if ($Index -lt 0) { return $null }
    $line = $Lines[$Index]
    if ($Def.Kind -eq "Bool") {
        $m = [regex]::Match($line, (Get-DefPattern $Def))
        return ($m.Groups[1].Value -eq "yes")
    }
    if ($Def.Kind -eq "Enum" -or $Def.Kind -eq "Text") {
        $m = [regex]::Match($line, (Get-DefPattern $Def))
        return $m.Groups[1].Value
    }
    if ($Def.Kind -eq "CommentedBool") {
        return (-not $line.TrimStart().StartsWith("#"))
    }
}

function Build-DefLine {
    param($Def, $Value)
    if ($Def.Kind -eq "Bool") {
        $v = "no"
        if ($Value) { $v = "yes" }
        return "$($Def.Key)=$v"
    }
    if ($Def.Kind -eq "Enum" -or $Def.Kind -eq "Text") {
        return "$($Def.Key)=$Value"
    }
    if ($Def.Kind -eq "CommentedBool") {
        if ($Value) { return $Def.ActiveLine }
        return "#$($Def.ActiveLine)"
    }
}

# -----------------------------
# Load current state
# -----------------------------
$fileCache = @{}
foreach ($def in $settings) {
    if (-not $fileCache.ContainsKey($def.File)) {
        $fileCache[$def.File] = Read-ConfigFile -Path $def.File
    }
}

foreach ($def in $settings) {
    $file = $fileCache[$def.File]
    $idx = Find-DefLineIndex -Def $def -Lines $file.Lines
    if ($idx -lt 0) {
        Write-Host "Warning: couldn't find a line for '$($def.Label)' in $($def.File) -- disabling this control." -ForegroundColor Yellow
        $def.Missing = $true
        $def.Initial = $null
    } else {
        $def.Missing = $false
        $def.Initial = Get-DefValue -Def $def -Lines $file.Lines -Index $idx
    }
}

# -----------------------------
# Build UI
# -----------------------------
$window = New-Object System.Windows.Window
$window.Title = "mpv Configuration Manager"
$window.Width = 560
$window.Height = 640
$window.WindowStartupLocation = "CenterScreen"
$window.ResizeMode = "CanResize"
$window.MinWidth = 440
$window.MinHeight = 400

$rootGrid = New-Object System.Windows.Controls.Grid
$row0 = New-Object System.Windows.Controls.RowDefinition; $row0.Height = "*"
$row1 = New-Object System.Windows.Controls.RowDefinition; $row1.Height = "Auto"
$rootGrid.RowDefinitions.Add($row0)
$rootGrid.RowDefinitions.Add($row1)

$scroll = New-Object System.Windows.Controls.ScrollViewer
$scroll.VerticalScrollBarVisibility = "Auto"
$scroll.Margin = "10,10,10,0"
[System.Windows.Controls.Grid]::SetRow($scroll, 0)

$outerStack = New-Object System.Windows.Controls.StackPanel
$scroll.Content = $outerStack

$groups = @()
foreach ($def in $settings) { if ($groups -notcontains $def.Group) { $groups += $def.Group } }

foreach ($groupName in $groups) {
    $groupBox = New-Object System.Windows.Controls.GroupBox
    $groupBox.Header = $groupName
    $groupBox.Margin = "0,0,0,10"
    $groupBox.Padding = "8"

    $groupStack = New-Object System.Windows.Controls.StackPanel
    $groupBox.Content = $groupStack

    foreach ($def in ($settings | Where-Object { $_.Group -eq $groupName })) {
        if ($def.Kind -eq "Enum") {
            $row = New-Object System.Windows.Controls.StackPanel
            $row.Orientation = "Horizontal"
            $row.Margin = "0,4,0,4"
            $row.ToolTip = $def.Tooltip

            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = $def.Label
            $label.VerticalAlignment = "Center"
            $label.Width = 260
            $row.Children.Add($label) | Out-Null

            $combo = New-Object System.Windows.Controls.ComboBox
            $combo.Width = 140
            foreach ($opt in $def.Options) { $combo.Items.Add($opt) | Out-Null }
            if (-not $def.Missing -and $def.Options -contains $def.Initial) {
                $combo.SelectedItem = $def.Initial
            } elseif ($combo.Items.Count -gt 0) {
                $combo.SelectedIndex = 0
            }
            $combo.IsEnabled = -not $def.Missing
            $row.Children.Add($combo) | Out-Null

            $def.Control = $combo
            $groupStack.Children.Add($row) | Out-Null
        } elseif ($def.Kind -eq "Text") {
            $row = New-Object System.Windows.Controls.StackPanel
            $row.Orientation = "Horizontal"
            $row.Margin = "0,4,0,4"
            $row.ToolTip = $def.Tooltip

            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = $def.Label
            $label.VerticalAlignment = "Center"
            $label.Width = 260
            $row.Children.Add($label) | Out-Null

            $textBox = New-Object System.Windows.Controls.TextBox
            $textBox.Width = 220
            if (-not $def.Missing) { $textBox.Text = [string]$def.Initial }
            $textBox.IsEnabled = -not $def.Missing
            $row.Children.Add($textBox) | Out-Null

            $def.Control = $textBox
            $groupStack.Children.Add($row) | Out-Null
        } else {
            $check = New-Object System.Windows.Controls.CheckBox
            $check.Content = $def.Label
            $check.Margin = "0,4,0,4"
            $check.ToolTip = $def.Tooltip
            if (-not $def.Missing) { $check.IsChecked = [bool]$def.Initial }
            $check.IsEnabled = -not $def.Missing
            $def.Control = $check
            $groupStack.Children.Add($check) | Out-Null
        }
    }

    $outerStack.Children.Add($groupBox) | Out-Null
}

$rootGrid.Children.Add($scroll) | Out-Null

$bottomPanel = New-Object System.Windows.Controls.StackPanel
$bottomPanel.Orientation = "Vertical"
$bottomPanel.Margin = "10"
[System.Windows.Controls.Grid]::SetRow($bottomPanel, 1)

$note = New-Object System.Windows.Controls.TextBlock
$note.Text = "Changes take effect the next time mpv starts."
$note.Foreground = "Gray"
$note.Margin = "0,0,0,8"
$bottomPanel.Children.Add($note) | Out-Null

$buttonRow = New-Object System.Windows.Controls.StackPanel
$buttonRow.Orientation = "Horizontal"
$buttonRow.HorizontalAlignment = "Right"

$cancelButton = New-Object System.Windows.Controls.Button
$cancelButton.Content = "Cancel"
$cancelButton.Width = 90
$cancelButton.Margin = "0,0,8,0"
$cancelButton.Add_Click({ $window.DialogResult = $false; $window.Close() })

$saveButton = New-Object System.Windows.Controls.Button
$saveButton.Content = "Save"
$saveButton.Width = 90
$saveButton.IsDefault = $true
$saveButton.Add_Click({ $window.DialogResult = $true; $window.Close() })

$buttonRow.Children.Add($cancelButton) | Out-Null
$buttonRow.Children.Add($saveButton) | Out-Null
$bottomPanel.Children.Add($buttonRow) | Out-Null

$rootGrid.Children.Add($bottomPanel) | Out-Null
$window.Content = $rootGrid

# -----------------------------
# Show, then apply changes on Save
# -----------------------------
$result = $window.ShowDialog()

if ($result -eq $true) {
    $touchedFiles = @{}
    $changedCount = 0

    foreach ($def in $settings) {
        if ($def.Missing) { continue }

        if ($def.Kind -eq "Enum") {
            $newValue = $def.Control.SelectedItem
        } elseif ($def.Kind -eq "Text") {
            $newValue = $def.Control.Text
        } else {
            $newValue = [bool]$def.Control.IsChecked
        }

        if ($newValue -eq $def.Initial) { continue }

        $file = $fileCache[$def.File]
        $idx = Find-DefLineIndex -Def $def -Lines $file.Lines
        if ($idx -lt 0) {
            Write-Host "Warning: '$($def.Label)' line disappeared before saving -- skipping." -ForegroundColor Yellow
            continue
        }

        $file.Lines[$idx] = Build-DefLine -Def $def -Value $newValue
        $touchedFiles[$def.File] = $true
        $changedCount++
    }

    foreach ($path in $touchedFiles.Keys) {
        Write-ConfigFile -File $fileCache[$path]
        Write-Host "Wrote $path" -ForegroundColor Green
    }

    if ($changedCount -gt 0) {
        [System.Windows.MessageBox]::Show("$changedCount setting(s) saved. Changes take effect next time mpv starts.", "Configuration Manager", "OK", "Information") | Out-Null
    }
} else {
    Write-Host "Cancelled -- no changes written." -ForegroundColor Yellow
}
