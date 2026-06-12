# Spotify Account Switcher v1.0.0
#
# Saves and restores Spotify desktop accounts by swapping the auth blob in the prefs file
# and the per-user data folder under AppData\Roaming\Spotify\Users.
#
# USAGE
#   GUI (default):
#     .\spotify-account-switcher.ps1
#
#   Switch by label (case-insensitive, no GUI):
#     .\spotify-account-switcher.ps1 -user Aiko
#
#   Switch by list position (1-based, no GUI):
#     .\spotify-account-switcher.ps1 -userid 2

param(
    [string]$user   = "",
    [int]   $userid = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ── Paths ─────────────────────────────────────────────────────────────────────
$SpotifyDir = Join-Path $env:APPDATA "Spotify"
$PrefsFile  = Join-Path $SpotifyDir  "prefs"
$UsersDir   = Join-Path $SpotifyDir  "Users"
$StoreDir   = Join-Path $SpotifyDir  "AccountProfiles"

# ── Prefs helpers ─────────────────────────────────────────────────────────────
function Read-Prefs {
    $map = [ordered]@{}
    if (-not (Test-Path $PrefsFile)) { return $map }
    foreach ($line in Get-Content $PrefsFile) {
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { continue }
        $map[$line.Substring(0,$idx).Trim()] = $line.Substring($idx+1).Trim()
    }
    return $map
}

function Write-Prefs($map) {
    Set-Content -Path $PrefsFile -Value ($map.Keys | ForEach-Object { "$_=$($map[$_])" }) -Encoding UTF8
}

function Get-CurrentUsername {
    foreach ($line in Get-Content $PrefsFile -ErrorAction SilentlyContinue) {
        if ($line -match '^autologin\.username=(.+)$') { return $Matches[1].Trim('"') }
    }
    return ""
}

# ── Spotify process ───────────────────────────────────────────────────────────
function Stop-Spotify {
    $p = Get-Process -Name "Spotify" -ErrorAction SilentlyContinue
    if ($p) { $p | Stop-Process -Force; Start-Sleep -Milliseconds 900 }
}

function Start-Spotify { Start-Process (Join-Path $SpotifyDir "Spotify.exe") }

function Test-SpotifyRunning { return $null -ne (Get-Process -Name "Spotify" -ErrorAction SilentlyContinue) }

# ── Profile storage ───────────────────────────────────────────────────────────
$AUTH_KEYS = @("autologin.username","autologin.canonical_username","autologin.blob","autologin.saved_credentials")

function Ensure-Dir($path) { if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null } }

function Get-SavedProfiles {
    Ensure-Dir $StoreDir
    return @(Get-ChildItem $StoreDir -Directory |
             Where-Object { Test-Path (Join-Path $_.FullName "meta.json") } |
             Sort-Object Name)
}

function Read-Meta($dir) { return Get-Content (Join-Path $dir "meta.json") -Raw | ConvertFrom-Json }

function Save-AuthToProfile($label) {
    $prefs    = Read-Prefs
    $username = $(if ($prefs.Contains("autologin.username")) { $prefs["autologin.username"] } else { "" }).Trim('"')
    if (-not $username) { return $null }

    $safeName   = ($label -replace '[\\/:*?"<>|]', '_')
    $profileDir = Join-Path $StoreDir $safeName

    $existing = Get-SavedProfiles | Where-Object { (Read-Meta $_.FullName).label -ieq $label } | Select-Object -First 1
    if ($existing) { Remove-Item $existing.FullName -Recurse -Force }

    Ensure-Dir $profileDir

    $authMap = @{}
    foreach ($k in $AUTH_KEYS) {
        if ($prefs.Contains($k)) { $authMap[$k] = $prefs[$k] }
    }
    $authMap | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $profileDir "auth.json") -Encoding UTF8

    $userFolder = Join-Path $UsersDir ($username + "-user")
    if (Test-Path $userFolder) { Copy-Item $userFolder (Join-Path $profileDir "userdata") -Recurse }

    @{ label = $label; username = $username; savedAt = (Get-Date -Format "o") } |
        ConvertTo-Json | Set-Content (Join-Path $profileDir "meta.json") -Encoding UTF8

    return $username
}

function Clear-AuthFromPrefs {
    $prefs = Read-Prefs
    foreach ($k in $AUTH_KEYS) { if ($prefs.Contains($k)) { $prefs.Remove($k) } }
    Write-Prefs $prefs
}

function Restore-Profile($profile, $meta) {
    $authJson = Get-Content (Join-Path $profile.FullName "auth.json") -Raw | ConvertFrom-Json

    $prefs = Read-Prefs
    foreach ($k in $AUTH_KEYS) {
        $prop = $authJson.PSObject.Properties[$k]
        if ($null -ne $prop) {
            $val = "$($prop.Value)"
            if ($val -ne '') {
                # Profiles saved before the fix have unquoted values; add quotes if missing
                if (-not $val.StartsWith('"')) { $val = '"' + $val + '"' }
                $prefs[$k] = $val
            } else {
                if ($prefs.Contains($k)) { $prefs.Remove($k) }
            }
        } elseif ($prefs.Contains($k)) { $prefs.Remove($k) }
    }
    Write-Prefs $prefs

    # Delete dbrts - Spotify's local session cache that overrides prefs on startup.
    $dbrts = Join-Path $env:LOCALAPPDATA "Spotify\dbrts"
    if (Test-Path $dbrts) { Remove-Item $dbrts -Force }

    # Delete the target user cache so Spotify starts fresh from the server.
    $targetFolder = Join-Path $UsersDir ($meta.username + "-user")
    if (Test-Path $targetFolder) { Remove-Item $targetFolder -Recurse -Force }
}

# ── CLI switch (no GUI) ───────────────────────────────────────────────────────
function Switch-ByProfile($profile, $meta) {
    Stop-Spotify
    Restore-Profile $profile $meta
    Start-Spotify
}

if ($user -ne "") {
    $m = Get-SavedProfiles | Where-Object { (Read-Meta $_.FullName).label -ieq $user } | Select-Object -First 1
    if (-not $m) { Write-Host "No saved profile with label '$user'." -ForegroundColor Red; exit 1 }
    Switch-ByProfile $m (Read-Meta $m.FullName); exit
}
if ($userid -gt 0) {
    $all = Get-SavedProfiles
    if ($userid -gt $all.Count) { Write-Host "No profile at position $userid." -ForegroundColor Red; exit 1 }
    Switch-ByProfile $all[$userid-1] (Read-Meta $all[$userid-1].FullName); exit
}

# ── WPF helpers (script-scope, so all vars accessible without capture) ────────
# These are defined BEFORE $window is created so they can be called from handlers.
# They reference $window/$statusText/$cardPanel which are set right after XamlReader.

function GUI-SetStatus($msg) { $script:statusText.Text = $msg }

function GUI-RebuildCards { Build-Cards }

function GUI-MakeDarkWindow($title, $w, $h) {
    $d = New-Object Windows.Window
    $d.Title                 = $title
    $d.Width                 = $w
    $d.Height                = $h
    $d.ResizeMode            = [Windows.ResizeMode]::NoResize
    $d.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $d.Owner                 = $script:window
    $d.Background            = [Windows.Media.BrushConverter]::new().ConvertFromString("#1A1A1A")
    return $d
}

function GUI-MakeLabelDialog($defaultText, $onSave) {
    $dlg = GUI-MakeDarkWindow "Label" 300 130
    $sp  = New-Object Windows.Controls.StackPanel; $sp.Margin = [Windows.Thickness]::new(16)
    $tb  = New-Object Windows.Controls.TextBox
    $tb.Background  = [Windows.Media.BrushConverter]::new().ConvertFromString("#2A2A2A")
    $tb.Foreground  = [Windows.Media.Brushes]::White
    $tb.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString("#1DB954")
    $tb.Padding     = [Windows.Thickness]::new(6,4,6,4)
    $tb.FontSize    = 13
    $tb.Margin      = [Windows.Thickness]::new(0,0,0,10)
    $tb.Text        = $defaultText
    $tb.SelectAll()
    $ok = New-Object Windows.Controls.Button
    $ok.Content         = "Save"
    $ok.Background      = [Windows.Media.BrushConverter]::new().ConvertFromString("#1DB954")
    $ok.Foreground      = [Windows.Media.Brushes]::Black
    $ok.FontWeight      = [Windows.FontWeights]::Bold
    $ok.Padding         = [Windows.Thickness]::new(0,6,0,6)
    $ok.BorderThickness = [Windows.Thickness]::new(0)
    $ok.Add_Click({ $lbl = $tb.Text.Trim(); if ($lbl) { & $onSave $lbl; $dlg.Close() } })
    $tb.Add_KeyDown({
        if ($_.Key -eq [Windows.Input.Key]::Return) { $ok.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
        if ($_.Key -eq [Windows.Input.Key]::Escape)  { $dlg.Close() }
    })
    $sp.Children.Add($tb) | Out-Null
    $sp.Children.Add($ok) | Out-Null
    $dlg.Content = $sp
    $dlg.ShowDialog() | Out-Null
}

function GUI-SwitchToProfile($profilePath, $meta) {
    $script:window.IsEnabled = $false
    $currentUser = Get-CurrentUsername
    $isRunning   = Test-SpotifyRunning

    if ($currentUser -ieq $meta.username) {
        if ($isRunning) {
            GUI-SetStatus "'$($meta.label)' is already the active account and Spotify is running."
        } else {
            GUI-SetStatus "Starting Spotify for '$($meta.label)'..."
            Start-Spotify
        }
        $script:window.IsEnabled = $true
        return
    }

    GUI-SetStatus "Switching to '$($meta.label)'..."
    $p = Get-SavedProfiles | Where-Object { $_.FullName -ieq $profilePath } | Select-Object -First 1
    if ($p) {
        if ($isRunning) { Stop-Spotify }
        Restore-Profile $p $meta
        Start-Spotify
        GUI-SetStatus "Switched to '$($meta.label)'. Spotify is starting."
    }
    $script:window.IsEnabled = $true
}

function GUI-RenameProfile($profilePath, $meta) {
    $dlg = GUI-MakeDarkWindow "Rename Profile" 320 140
    $sp  = New-Object Windows.Controls.StackPanel; $sp.Margin = [Windows.Thickness]::new(16)
    $tb  = New-Object Windows.Controls.TextBox
    $tb.Background  = [Windows.Media.BrushConverter]::new().ConvertFromString("#2A2A2A")
    $tb.Foreground  = [Windows.Media.Brushes]::White
    $tb.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString("#1DB954")
    $tb.Padding     = [Windows.Thickness]::new(6,4,6,4)
    $tb.FontSize    = 13
    $tb.Margin      = [Windows.Thickness]::new(0,0,0,10)
    $tb.Text        = $meta.label
    $tb.SelectAll()
    $ok = New-Object Windows.Controls.Button
    $ok.Content         = "Rename"
    $ok.Background      = [Windows.Media.BrushConverter]::new().ConvertFromString("#1DB954")
    $ok.Foreground      = [Windows.Media.Brushes]::Black
    $ok.FontWeight      = [Windows.FontWeights]::Bold
    $ok.Padding         = [Windows.Thickness]::new(0,6,0,6)
    $ok.BorderThickness = [Windows.Thickness]::new(0)
    $ok.Add_Click({
        $newLabel = $tb.Text.Trim()
        if (-not $newLabel) { return }
        $clash = Get-SavedProfiles | Where-Object {
            (Read-Meta $_.FullName).label -ieq $newLabel -and $_.FullName -ine $profilePath
        } | Select-Object -First 1
        if ($clash) { GUI-SetStatus "A profile named '$newLabel' already exists."; $dlg.Close(); return }
        $newSafe = ($newLabel -replace '[\\/:*?"<>|]', '_')
        $newDir  = Join-Path $StoreDir $newSafe
        $meta.label   = $newLabel
        $meta.savedAt = (Get-Date -Format "o")
        $meta | ConvertTo-Json | Set-Content (Join-Path $profilePath "meta.json") -Encoding UTF8
        Rename-Item $profilePath $newDir
        $dlg.Close()
        GUI-RebuildCards
        GUI-SetStatus "Renamed to '$newLabel'."
    })
    $tb.Add_KeyDown({
        if ($_.Key -eq [Windows.Input.Key]::Return) { $ok.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
        if ($_.Key -eq [Windows.Input.Key]::Escape)  { $dlg.Close() }
    })
    $sp.Children.Add($tb) | Out-Null
    $sp.Children.Add($ok) | Out-Null
    $dlg.Content = $sp
    $dlg.ShowDialog() | Out-Null
}

function GUI-DeleteProfile($profilePath, $meta) {
    $confirm = [Windows.MessageBox]::Show(
        "Delete '$($meta.label)'? This cannot be undone.",
        "Delete Profile",
        [Windows.MessageBoxButton]::YesNo,
        [Windows.MessageBoxImage]::Warning)
    if ($confirm -eq [Windows.MessageBoxResult]::Yes) {
        Remove-Item $profilePath -Recurse -Force
        GUI-RebuildCards
        GUI-SetStatus "Deleted '$($meta.label)'."
    }
}

function GUI-AddUser {
    $dlg = GUI-MakeDarkWindow "Add Account" 340 190
    $sp  = New-Object Windows.Controls.StackPanel; $sp.Margin = [Windows.Thickness]::new(16)

    $infoTb = New-Object Windows.Controls.TextBlock
    $infoTb.Text         = "What would you like to do?"
    $infoTb.Foreground   = [Windows.Media.Brushes]::White
    $infoTb.FontSize     = 13
    $infoTb.Margin       = [Windows.Thickness]::new(0,0,0,12)
    $infoTb.TextWrapping = [Windows.TextWrapping]::Wrap

    $makeBtn = {
        param($text, $bg, $fg)
        $b = New-Object Windows.Controls.Button
        $b.Content         = $text
        $b.Background      = [Windows.Media.BrushConverter]::new().ConvertFromString($bg)
        $b.Foreground      = $fg
        $b.FontSize        = 12
        $b.Padding         = [Windows.Thickness]::new(0,8,0,8)
        $b.Margin          = [Windows.Thickness]::new(0,0,0,8)
        $b.BorderThickness = [Windows.Thickness]::new(0)
        return $b
    }

    $saveBtn = & $makeBtn "Save current account" "#1DB954" ([Windows.Media.Brushes]::Black)
    $saveBtn.FontWeight = [Windows.FontWeights]::Bold
    $saveBtn.Add_Click({
        $dlg.Close()
        $username = Get-CurrentUsername
        if (-not $username) { GUI-SetStatus "No account currently logged in."; return }
        GUI-MakeLabelDialog $username {
            param($lbl)
            Stop-Spotify
            $saved = Save-AuthToProfile $lbl
            GUI-RebuildCards
            if ($saved) { GUI-SetStatus "Saved '$lbl' ($saved)." }
            else        { GUI-SetStatus "Nothing to save - no account found in prefs." }
        }
    })

    $newBtn = & $makeBtn "Prepare for a new login" "#282828" ([Windows.Media.Brushes]::White)
    $newBtn.Add_Click({
        $dlg.Close()
        $username = Get-CurrentUsername
        if ($username) {
            $alreadySaved = Get-SavedProfiles | Where-Object { (Read-Meta $_.FullName).username -ieq $username }
            if (-not $alreadySaved) {
                $ans = [Windows.MessageBox]::Show(
                    "Save current account ('$username') before clearing?",
                    "Save first?",
                    [Windows.MessageBoxButton]::YesNo,
                    [Windows.MessageBoxImage]::Question)
                if ($ans -eq [Windows.MessageBoxResult]::Yes) {
                    GUI-MakeLabelDialog $username {
                        param($lbl)
                        Stop-Spotify
                        Save-AuthToProfile $lbl | Out-Null
                    }
                }
            }
        }
        Stop-Spotify
        Clear-AuthFromPrefs
        GUI-RebuildCards
        GUI-SetStatus "Autologin cleared. Launching Spotify to the login screen..."
        Start-Spotify
    })

    $sp.Children.Add($infoTb)  | Out-Null
    $sp.Children.Add($saveBtn) | Out-Null
    $sp.Children.Add($newBtn)  | Out-Null
    $dlg.Content = $sp
    $dlg.ShowDialog() | Out-Null
}

function GUI-Troubleshoot {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("=== CURRENT PREFS ===")
    if (Test-Path $PrefsFile) {
        foreach ($line in Get-Content $PrefsFile) {
            if ($line -match "^autologin") {
                if ($line.Length -gt 120) { $lines.Add($line.Substring(0,120) + "...") }
                else { $lines.Add($line) }
            }
        }
    } else { $lines.Add("prefs file not found") }

    foreach ($p in Get-SavedProfiles) {
        $meta     = Read-Meta $p.FullName
        $authPath = Join-Path $p.FullName "auth.json"
        $lines.Add("")
        $lines.Add("=== PROFILE: $($meta.label) ($($meta.username)) ===")
        if (Test-Path $authPath) {
            $auth = Get-Content $authPath -Raw | ConvertFrom-Json
            foreach ($k in $AUTH_KEYS) {
                $val = $auth.$k
                if ($null -ne $val) {
                    $entry = "$k = $val"
                    $lines.Add($(if ($entry.Length -gt 120) { $entry.Substring(0,120) + "..." } else { $entry }))
                } else { $lines.Add("$k = (missing)") }
            }
        } else { $lines.Add("auth.json not found") }
    }

    $dlg = GUI-MakeDarkWindow "Troubleshoot" 640 480
    $dlg.SizeToContent = [Windows.SizeToContent]::Manual

    $grid = New-Object Windows.Controls.Grid
    $r0 = New-Object Windows.Controls.RowDefinition; $r0.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $r1 = New-Object Windows.Controls.RowDefinition; $r1.Height = [Windows.GridLength]::Auto
    $grid.RowDefinitions.Add($r0); $grid.RowDefinitions.Add($r1)

    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.Margin = [Windows.Thickness]::new(12,12,12,6)
    $scroll.VerticalScrollBarVisibility = [Windows.Controls.ScrollBarVisibility]::Auto
    [Windows.Controls.Grid]::SetRow($scroll, 0)

    $tb = New-Object Windows.Controls.TextBox
    $tb.Text            = $lines -join "`n"
    $tb.IsReadOnly      = $true
    $tb.Background      = [Windows.Media.BrushConverter]::new().ConvertFromString("#1A1A1A")
    $tb.Foreground      = [Windows.Media.Brushes]::White
    $tb.FontFamily      = [Windows.Media.FontFamily]::new("Consolas")
    $tb.FontSize        = 11
    $tb.BorderThickness = [Windows.Thickness]::new(0)
    $tb.TextWrapping    = [Windows.TextWrapping]::NoWrap
    $tb.AcceptsReturn   = $true
    $scroll.Content     = $tb

    $copyBtn = New-Object Windows.Controls.Button
    $copyBtn.Content         = "Copy to clipboard"
    $copyBtn.Margin          = [Windows.Thickness]::new(12,0,12,12)
    $copyBtn.Padding         = [Windows.Thickness]::new(0,6,0,6)
    $copyBtn.Background      = [Windows.Media.BrushConverter]::new().ConvertFromString("#1DB954")
    $copyBtn.Foreground      = [Windows.Media.Brushes]::Black
    $copyBtn.FontWeight      = [Windows.FontWeights]::Bold
    $copyBtn.BorderThickness = [Windows.Thickness]::new(0)
    $copyBtn.Add_Click({ [Windows.Clipboard]::SetText($tb.Text) })
    [Windows.Controls.Grid]::SetRow($copyBtn, 1)

    $grid.Children.Add($scroll)  | Out-Null
    $grid.Children.Add($copyBtn) | Out-Null
    $dlg.Content = $grid
    $dlg.ShowDialog() | Out-Null
}

# ── Startup shortcut ─────────────────────────────────────────────────────────
$StartupFolder  = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$StartupLnk     = Join-Path $StartupFolder "SpotifyAccountSwitcher.lnk"

function Test-StartupEnabled { return Test-Path $StartupLnk }

function Enable-Startup {
    $scriptPath = $PSCommandPath
    $psExe      = (Get-Command powershell.exe).Source
    $args       = "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$scriptPath`""
    $shell      = New-Object -ComObject WScript.Shell
    $lnk        = $shell.CreateShortcut($StartupLnk)
    $lnk.TargetPath       = $psExe
    $lnk.Arguments        = $args
    $lnk.WorkingDirectory = Split-Path $scriptPath
    $lnk.Description      = "Spotify Account Switcher"
    $lnk.Save()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
}

function Disable-Startup {
    if (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
}

# ── WPF XAML ──────────────────────────────────────────────────────────────────
[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Spotify Account Switcher"
    SizeToContent="WidthAndHeight"
    MinHeight="160" MinWidth="160" ResizeMode="NoResize"
    WindowStartupLocation="CenterScreen"
    Background="#111111" Foreground="#FFFFFF" FontFamily="Segoe UI">
    <Window.Resources>
        <Style x:Key="IconBtn" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Padding" Value="3"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#2A2A2A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <StackPanel Margin="16,16,16,20">
        <TextBlock Text="Accounts" FontSize="13" FontWeight="SemiBold"
                   Foreground="#B3B3B3" Margin="4,0,0,14"/>
        <StackPanel x:Name="CardPanel" Orientation="Horizontal"/>
        <Grid Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" VerticalAlignment="Center">
                <TextBlock x:Name="StatusText" FontSize="11" Foreground="#727272"
                           TextWrapping="Wrap"/>
                <CheckBox x:Name="StartupChk" Content="Run at startup"
                          Foreground="#727272" FontSize="11" Margin="0,6,0,0"
                          Cursor="Hand"/>
            </StackPanel>
            <Button x:Name="TroubleshootBtn" Content="Troubleshoot"
                    Grid.Column="1" VerticalAlignment="Bottom"
                    Background="#1A1A1A" Foreground="#727272"
                    BorderThickness="0" Padding="8,4" FontSize="11" Cursor="Hand"/>
        </Grid>
    </StackPanel>
</Window>
'@

$reader     = [System.Xml.XmlNodeReader]::new($xaml)
$window     = [Windows.Markup.XamlReader]::Load($reader)
$cardPanel  = $window.FindName("CardPanel")
$statusText = $window.FindName("StatusText")
$window.FindName("TroubleshootBtn").Add_Click({ GUI-Troubleshoot })

$startupChk = $window.FindName("StartupChk")
$startupChk.IsChecked = Test-StartupEnabled
$startupChk.Add_Checked({
    try {
        Enable-Startup
        GUI-SetStatus "Added to startup."
    } catch {
        GUI-SetStatus "Could not add to startup: $_"
        $script:startupChk.IsChecked = $false
    }
})
$startupChk.Add_Unchecked({
    try {
        Disable-Startup
        GUI-SetStatus "Removed from startup."
    } catch {
        GUI-SetStatus "Could not remove from startup: $_"
        $script:startupChk.IsChecked = $true
    }
})

# ── Avatar helpers ────────────────────────────────────────────────────────────
$AVATAR_COLORS = @("#1DB954","#E91429","#509BF5","#FF6437","#B49BC8","#C8F560","#F59B23","#56B4E9")

function Get-Initials($label) {
    $w = $label.Trim() -split '\s+'
    $i = ($w | Select-Object -First 2 | ForEach-Object { if ($_.Length -gt 0) { $_[0].ToString().ToUpper() } }) -join ''
    return $(if ($i) { $i } else { '?' })
}

# ── Build card grid ───────────────────────────────────────────────────────────
function Build-Cards {
    $cardPanel.Children.Clear()
    $profiles = Get-SavedProfiles
    $idx = 0

    foreach ($profile in $profiles) {
        $meta     = Read-Meta $profile.FullName
        $color    = $AVATAR_COLORS[$idx % $AVATAR_COLORS.Length]
        $profPath = $profile.FullName
        $profMeta = $meta

        $card = New-Object Windows.Controls.Border
        $card.Background   = [Windows.Media.BrushConverter]::new().ConvertFromString("#1A1A1A")
        $card.CornerRadius = [Windows.CornerRadius]::new(10)
        $card.Width        = 110
        $card.Height       = 110
        $card.Margin       = [Windows.Thickness]::new(8)
        $card.Cursor       = [Windows.Input.Cursors]::Hand
        $card.ToolTip      = "$($meta.label)`n$($meta.username)"
        $card.Add_MouseEnter({ $this.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#242424") })
        $card.Add_MouseLeave({ $this.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#1A1A1A") })

        # Click to switch - call script-level function, no closure capture needed
        $card.Tag = @{ path = $profPath; meta = $profMeta }
        $card.Add_MouseLeftButtonUp({
            param($s, $e)
            if ($e.Source -is [Windows.Controls.Button]) { return }
            GUI-SwitchToProfile $s.Tag.path $s.Tag.meta
        })

        $stack = New-Object Windows.Controls.Grid

        $avatar = New-Object Windows.Controls.Border
        $avatar.Width               = 44
        $avatar.Height              = 44
        $avatar.CornerRadius        = [Windows.CornerRadius]::new(22)
        $avatar.Background          = [Windows.Media.BrushConverter]::new().ConvertFromString($color)
        $avatar.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
        $avatar.VerticalAlignment   = [Windows.VerticalAlignment]::Top
        $avatar.Margin              = [Windows.Thickness]::new(0,14,0,0)
        $avatar.IsHitTestVisible    = $false

        $initTb = New-Object Windows.Controls.TextBlock
        $initTb.Text                = Get-Initials $meta.label
        $initTb.FontSize            = 16
        $initTb.FontWeight          = [Windows.FontWeights]::Bold
        $initTb.Foreground          = [Windows.Media.Brushes]::Black
        $initTb.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
        $initTb.VerticalAlignment   = [Windows.VerticalAlignment]::Center
        $initTb.IsHitTestVisible    = $false
        $avatar.Child = $initTb

        $labelTb = New-Object Windows.Controls.TextBlock
        $labelTb.Text               = $meta.label
        $labelTb.FontSize           = 12
        $labelTb.FontWeight         = [Windows.FontWeights]::SemiBold
        $labelTb.Foreground         = [Windows.Media.Brushes]::White
        $labelTb.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
        $labelTb.VerticalAlignment  = [Windows.VerticalAlignment]::Bottom
        $labelTb.Margin             = [Windows.Thickness]::new(4,0,4,28)
        $labelTb.TextTrimming       = [Windows.TextTrimming]::CharacterEllipsis
        $labelTb.IsHitTestVisible   = $false

        $btnRow = New-Object Windows.Controls.StackPanel
        $btnRow.Orientation         = [Windows.Controls.Orientation]::Horizontal
        $btnRow.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
        $btnRow.VerticalAlignment   = [Windows.VerticalAlignment]::Bottom
        $btnRow.Margin              = [Windows.Thickness]::new(0,0,0,6)

        $editBtn = New-Object Windows.Controls.Button
        $editBtn.Style     = $window.Resources["IconBtn"]
        $editBtn.Content   = [char]0x270E
        $editBtn.FontSize  = 13
        $editBtn.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#B3B3B3")
        $editBtn.ToolTip   = "Rename"
        $editBtn.Tag       = @{ path = $profPath; meta = $profMeta }
        $editBtn.Add_Click({
            param($s, $e)
            $e.Handled = $true
            GUI-RenameProfile $s.Tag.path $s.Tag.meta
        })

        $delBtn = New-Object Windows.Controls.Button
        $delBtn.Style      = $window.Resources["IconBtn"]
        $delBtn.Content    = [char]0x232B
        $delBtn.FontSize   = 13
        $delBtn.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#FF4C4C")
        $delBtn.ToolTip    = "Delete"
        $delBtn.Tag        = @{ path = $profPath; meta = $profMeta }
        $delBtn.Add_Click({
            param($s, $e)
            $e.Handled = $true
            GUI-DeleteProfile $s.Tag.path $s.Tag.meta
        })

        $btnRow.Children.Add($editBtn) | Out-Null
        $btnRow.Children.Add($delBtn)  | Out-Null
        $stack.Children.Add($avatar)   | Out-Null
        $stack.Children.Add($labelTb)  | Out-Null
        $stack.Children.Add($btnRow)   | Out-Null
        $card.Child = $stack
        $cardPanel.Children.Add($card) | Out-Null
        $idx++
    }

    # "+ Add user" card
    $addCard = New-Object Windows.Controls.Border
    $addCard.Background   = [Windows.Media.BrushConverter]::new().ConvertFromString("#1A1A1A")
    $addCard.CornerRadius = [Windows.CornerRadius]::new(10)
    $addCard.Width        = 110
    $addCard.Height       = 110
    $addCard.Margin       = [Windows.Thickness]::new(8)
    $addCard.Cursor       = [Windows.Input.Cursors]::Hand
    $addCard.Add_MouseEnter({ $this.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#242424") })
    $addCard.Add_MouseLeave({ $this.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#1A1A1A") })

    $addStack = New-Object Windows.Controls.StackPanel
    $addStack.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $addStack.VerticalAlignment   = [Windows.VerticalAlignment]::Center
    $addStack.IsHitTestVisible    = $false

    $plusTb = New-Object Windows.Controls.TextBlock
    $plusTb.Text                = "+"
    $plusTb.FontSize            = 32
    $plusTb.Foreground          = [Windows.Media.BrushConverter]::new().ConvertFromString("#1DB954")
    $plusTb.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $plusTb.IsHitTestVisible    = $false

    $addLabelTb = New-Object Windows.Controls.TextBlock
    $addLabelTb.Text                = "Add user"
    $addLabelTb.FontSize            = 11
    $addLabelTb.Foreground          = [Windows.Media.BrushConverter]::new().ConvertFromString("#B3B3B3")
    $addLabelTb.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $addLabelTb.Margin              = [Windows.Thickness]::new(0,4,0,0)
    $addLabelTb.IsHitTestVisible    = $false

    $addStack.Children.Add($plusTb)     | Out-Null
    $addStack.Children.Add($addLabelTb) | Out-Null
    $addCard.Child = $addStack
    $addCard.Add_MouseLeftButtonUp({ GUI-AddUser })

    $cardPanel.Children.Add($addCard) | Out-Null
}

Build-Cards
$window.ShowDialog() | Out-Null
