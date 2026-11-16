<#
Factory usage drawer: a slim Factory logo tab that slides out on hover, sized to
fit its text. Drag it in either state: grab the tab within ~220 ms of pointing at
it and it moves while staying collapsed; dwell longer and it opens, then drag the
open card. The right-edge/top anchor is saved to
%LOCALAPPDATA%\factory-usage-overlay.pos.json. The badge is a plain accent square
unless a 256px factory-logo.png sits next to this script (the repo ships without
one, since that artwork is Factory's, not ours).

The window is never click-through, because a grabbable thing has to receive mouse
input. The collapsed tab therefore covers the ~28 DIP strip it sits on; move it
out of the way when it lands on something you need.

  factory-usage.ps1 -Show              start (no-op if already running)
  factory-usage.ps1 -Hide              stop it
  factory-usage.ps1 -Status            running PID, autostart, sampler path
  factory-usage.ps1 -Install           start at every sign-in, no console window
  factory-usage.ps1 -Uninstall         remove that sign-in task and stop it
  factory-usage.ps1 -Login             one-time Factory sign-in for the sampler
  factory-usage.ps1 -IntervalSeconds 300
  factory-usage.ps1 -PeekSeconds 3     stay open N seconds on launch, then tuck in

-Install drops factory-usage-launch.vbs into the current user's Startup folder
and starts it now. wscript runs powershell with window style 0, so a sign-in
starts the overlay with no console flashing up and nothing to click. It is
idempotent because -Show exits when the pid file names a live process.
-Uninstall deletes that file and stops the overlay.

The 5-hour / weekly / monthly percentages and the extra-usage balance come from
factory-usage-limits.mjs, which loads app.factory.ai/settings/usage in a headless
Chrome that keeps its own profile in %LOCALAPPDATA%\factory-usage-browser.
Nothing on screen is needed - no tab, no window, no focus. It is an ordinary
browser loading an ordinary page and reading the rendered DOM: no Factory API and
no credential file. Run -Login once to sign in inside that profile; the cookie
persists and every later sample is silent. Until then the rows read "--" and the
stamp reads "login once".

Data source is Factory's own per-session credit totals, read from
~/.factory/sessions/**/*.settings.json (tokenUsage.factoryCredits). No API, no
credentials, nothing leaves the machine. codeburn was dropped because it prices
Factory-routed models from a public table that has no Factory prices, folds
Codex usage into the same total, and reports $0 for sessions it labels
"droid-mixed".

A failed sample keeps the last real percentages on the card with their age
("02:31 +12m"), cached in %LOCALAPPDATA%\factory-usage-overlay.limits.json so a
restart keeps them too; after an hour without a fresh read the rows fall back to
"--".

shortcut: credits are bucketed by settings.json mtime, so a session that spans
midnight or a month boundary is counted whole against its last write. Per-turn
credit records are not written to the session logs.
#>
param(
  [switch]$Show,
  [switch]$Hide,
  [switch]$Status,
  [switch]$Install,
  [switch]$Uninstall,
  [switch]$Login,
  [int]$IntervalSeconds = 300,
  [int]$PeekSeconds = 3,
  [string]$StateFile = "$env:LOCALAPPDATA\factory-usage-overlay.pid",
  [switch]$Render
)

$ErrorActionPreference = 'Stop'

# the Startup folder runs this at sign-in; it needs no admin rights and puts no
# shortcut on the desktop
$launcher = Join-Path ([Environment]::GetFolderPath('Startup')) 'factory-usage-launch.vbs'

# The percentages come from factory-usage-limits.mjs, which drives its own headless
# Chrome, so nothing has to be open, visible, or focused on screen.
$limitsJs = Join-Path $PSScriptRoot 'factory-usage-limits.mjs'
# Every sample launches a headless Chrome, so this is a path list, not a guess:
# explicit override, machine install, PATH, then a per-user npm/nvm install.
$nodeExe = $null
foreach ($candidate in @(
    $env:FACTORY_USAGE_NODE,
    'C:\Program Files\nodejs\node.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
  )) {
  if ($candidate -and (Test-Path $candidate)) { $nodeExe = $candidate; break }
}
if (-not $nodeExe) {
  $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($nodeCmd) { $nodeExe = $nodeCmd.Path }
}

function Get-OverlayPid {
  if (-not (Test-Path $StateFile)) { return $null }
  $procId = (Get-Content $StateFile -Raw).Trim()
  if (-not $procId) { return $null }
  if (Get-Process -Id $procId -ErrorAction SilentlyContinue) { return [int]$procId }
  Remove-Item $StateFile -ErrorAction SilentlyContinue
  return $null
}

if ($Hide) {
  $existing = Get-OverlayPid
  if ($existing) {
    Stop-Process -Id $existing -Force
    Remove-Item $StateFile -ErrorAction SilentlyContinue
    "stopped: $existing"
  } else {
    'not running'
  }
  return
}
if ($Status) {
  $p = Get-OverlayPid
  if ($p) { "running: $p" } else { 'not running' }
  if (Test-Path $launcher) { "autostart: installed ($launcher)" } else { 'autostart: not installed' }
  if (Test-Path $limitsJs) { "sampler: $limitsJs" } else { 'sampler: MISSING factory-usage-limits.mjs' }
  if ($nodeExe) { "node: $nodeExe" } else { 'node: MISSING (limits will not update)' }
  $limFile = "$env:LOCALAPPDATA\factory-usage-overlay.limits.json"
  if (Test-Path $limFile) {
    try {
      $c = Get-Content $limFile -Raw | ConvertFrom-Json
      $age = [int]((Get-Date) - [datetime]$c.at).TotalMinutes
      "last sample: $($c.limits.fiveHour)% / $($c.limits.weekly)% / $($c.limits.monthly)% ({0}m ago)" -f $age
    } catch { 'last sample: unreadable cache' }
  } else { 'last sample: none (run -Login once)' }
  return
}

# One-time sign-in: headful Chrome on the sampler's own profile. The window closes
# itself as soon as the usage numbers appear, and the cookie stays in that profile.
if ($Login) {
  if (-not $limitsJs) { Write-Error 'cannot locate factory-usage-limits.mjs next to this script'; return }
  if (-not (Test-Path $limitsJs)) { Write-Error "missing $limitsJs"; return }
  if (-not $nodeExe) {
    Write-Error 'node.exe not found: install Node 22+ or set FACTORY_USAGE_NODE to its full path'
    return
  }
  'SIGN IN: Chrome will open on the Factory usage page. Log in there; the window'
  'closes by itself once the numbers load. Nothing else is needed afterwards.'
  Start-Process -FilePath $nodeExe -ArgumentList ('"{0}" --login' -f $limitsJs) -WindowStyle Hidden | Out-Null
  return
}

if ($Uninstall) {
  if (Test-Path $launcher) { Remove-Item $launcher -Force; "autostart removed: $launcher" }
  else { 'autostart: not installed' }
  $existing = Get-OverlayPid
  if ($existing) {
    Stop-Process -Id $existing -Force
    Remove-Item $StateFile -ErrorAction SilentlyContinue
    "stopped: $existing"
  } else { 'not running' }
  return
}

if ($Install) {
  # wscript runs powershell with window style 0, so sign-in starts the overlay
  # with no console flashing up.
  $vbs = @"
' Starts the Factory usage overlay with no console window.
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$PSCommandPath"" -Show", 0, False
"@
  Set-Content -Path $launcher -Value $vbs -Encoding ASCII
  "autostart installed: $launcher"
  $existing = Get-OverlayPid
  if ($existing) { "already running: $existing"; return }
  Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $launcher)
  Start-Sleep -Seconds 4
  $p = Get-OverlayPid
  if ($p) { "started: $p" } else { 'started: no pid yet, check -Status' }
  return
}

if ($Show) {
  $existing = Get-OverlayPid
  if ($existing) { "already running: $existing"; return }
  $argList = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
    '-Render', '-IntervalSeconds', $IntervalSeconds, '-PeekSeconds', $PeekSeconds
  )
  $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
  Set-Content -Path $StateFile -Value $p.Id -NoNewline
  "started: $($p.Id)"
  return
}
if (-not $Render) { Write-Error 'nothing to do: pass -Show, -Hide, or -Status'; return }

# --- render ---

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Web.Extensions
Add-Type -ReferencedAssemblies 'System.Web.Extensions' @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

public class UsageWin32 {
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X; public int Y; }

  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int n);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);

  static long Num(Dictionary<string, object> d, string key) {
    object v;
    if (!d.TryGetValue(key, out v) || v == null) return 0;
    try { return Convert.ToInt64(v); } catch { return 0; }
  }

  // Sums Factory's own billed credits for today and the current month.
  public static Task<string> ScanCreditsAsync(string sessionsRoot) {
    return Task.Run(() => {
      // Fresh install / no history yet: say so instead of surfacing an exception.
      if (!Directory.Exists(sessionsRoot)) return "{\"missing\":true}";
      var today = DateTime.Today;
      var monthStart = new DateTime(today.Year, today.Month, 1);
      long tCr = 0, mCr = 0;
      var ser = new JavaScriptSerializer();
      ser.MaxJsonLength = int.MaxValue;
      foreach (var f in Directory.EnumerateFiles(sessionsRoot, "*.json", SearchOption.AllDirectories)) {
        if (!f.EndsWith(".settings.json", StringComparison.OrdinalIgnoreCase)) continue;
        DateTime mtime;
        try { mtime = File.GetLastWriteTime(f); } catch { continue; }
        if (mtime < monthStart) continue;
        Dictionary<string, object> o;
        try { o = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(f)); } catch { continue; }
        if (o == null) continue;
        object raw;
        var u = o.TryGetValue("inclusiveTokenUsage", out raw) ? raw as Dictionary<string, object> : null;
        if (u == null) u = o.TryGetValue("tokenUsage", out raw) ? raw as Dictionary<string, object> : null;
        if (u == null) continue;
        long cr = Num(u, "factoryCredits");
        mCr += cr;
        if (mtime >= today) tCr += cr;
      }
      return "{\"todayCredits\":" + tCr + ",\"monthCredits\":" + mCr + "}";
    });
  }

  // Runs factory-usage-limits.mjs, which reads Factory's own usage page in a
  // headless Chrome that keeps its own profile. No Factory API and no credential
  // file: it is an ordinary browser loading an ordinary page, and the numbers come
  // out of the rendered DOM. The script prints one JSON line.
  public static Task<string> ScanLimitsAsync(string nodeExe, string script, int timeoutMs) {
    return Task.Run(() => {
      System.Diagnostics.Process p = null;
      try {
        var psi = new System.Diagnostics.ProcessStartInfo();
        psi.FileName = nodeExe;
        psi.Arguments = "\"" + script + "\"";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.WorkingDirectory = Path.GetDirectoryName(script);
        p = System.Diagnostics.Process.Start(psi);
        var outTask = p.StandardOutput.ReadToEndAsync();
        p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(timeoutMs)) {
          try { p.Kill(); } catch { }
          return "{\"ok\":false,\"reason\":\"timeout\"}";
        }
        var text = outTask.Result ?? "";
        foreach (var line in text.Split('\n')) {
          var t = line.Trim();
          if (t.StartsWith("{") && t.EndsWith("}")) return t;
        }
        return "{\"ok\":false,\"reason\":\"no_output\"}";
      } catch (Exception e) {
        return "{\"ok\":false,\"reason\":\"spawn_" + e.GetType().Name + "\"}";
      } finally {
        if (p != null) { try { p.Dispose(); } catch { } }
      }
    });
  }
}
'@

$TAB_W       = 28.0
$ANIM_MS     = 220.0
$UNHOVER_MS  = 180.0
$HOVER_DWELL_MS = 220.0   # grabbing the tab faster than this drags it without opening

$sessionsRoot = Join-Path $env:USERPROFILE '.factory\sessions'

function Format-Credits([double]$n) {
  if ($n -ge 1e9) { return ('{0:N2}B cr' -f ($n / 1e9)) }
  if ($n -ge 1e6) { return ('{0:N2}M cr' -f ($n / 1e6)) }
  if ($n -ge 1e4) { return ('{0:N0}K cr' -f ($n / 1e3)) }
  return ('{0:N0} cr' -f $n)
}

function New-Brush([string]$hex) {
  return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
}

$orangeBrush = New-Brush '#FF8C00'
$bgBrush     = New-Brush '#F016161A'
$mutedBrush  = New-Brush '#9CA3AF'
$subBrush    = New-Brush '#71717A'
$redBrush    = New-Brush '#F87171'
$whiteBrush  = [System.Windows.Media.Brushes]::White
$segoe       = New-Object System.Windows.Media.FontFamily('Segoe UI')

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnLastWindowClose'

$win = New-Object System.Windows.Window
$win.WindowStyle = 'None'
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.ResizeMode = 'NoResize'
$win.ShowActivated = $false
$win.SizeToContent = 'WidthAndHeight'
$win.WindowStartupLocation = 'Manual'

$root = New-Object System.Windows.Controls.Grid
$root.Background = [System.Windows.Media.Brushes]::Transparent
$root.ClipToBounds = $true

$tx = New-Object System.Windows.Media.TranslateTransform
$card = New-Object System.Windows.Controls.Border
$card.CornerRadius = New-Object System.Windows.CornerRadius(10, 0, 0, 10)
$card.Background = $bgBrush
$card.BorderBrush = $orangeBrush
$card.BorderThickness = New-Object System.Windows.Thickness(1.5, 1.5, 0, 1.5)
$card.RenderTransform = $tx

$layout = New-Object System.Windows.Controls.Grid
$cTab = New-Object System.Windows.Controls.ColumnDefinition; $cTab.Width = New-Object System.Windows.GridLength($TAB_W)
$cBody = New-Object System.Windows.Controls.ColumnDefinition; $cBody.Width = [System.Windows.GridLength]::Auto
[void]$layout.ColumnDefinitions.Add($cTab)
[void]$layout.ColumnDefinitions.Add($cBody)

# Left handle: the badge, always visible when the card is tucked away. A 256px
# factory-logo.png next to this script replaces the plain accent square; the repo
# ships without it because that artwork is not ours to redistribute.
$badge = New-Object System.Windows.Controls.Border
$badge.Width = 20; $badge.Height = 20
$badge.CornerRadius = New-Object System.Windows.CornerRadius(6)
$badge.Background = $orangeBrush
$badge.HorizontalAlignment = 'Center'
$badge.VerticalAlignment = 'Center'
$logoPath = Join-Path (Split-Path -Parent $PSCommandPath) 'factory-logo.png'
if (Test-Path $logoPath) {
  try {
    $logoBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $logoBitmap.BeginInit()
    $logoBitmap.UriSource = New-Object System.Uri($logoPath)
    $logoBitmap.CacheOption = 'OnLoad'
    $logoBitmap.DecodePixelWidth = 36
    $logoBitmap.EndInit()
    $logoBitmap.Freeze()
    $badgeImage = New-Object System.Windows.Controls.Image
    $badgeImage.Source = $logoBitmap
    $badgeImage.Stretch = 'Uniform'
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($badgeImage, [System.Windows.Media.BitmapScalingMode]::HighQuality)
    $badge.Background = [System.Windows.Media.Brushes]::Transparent
    $badge.CornerRadius = New-Object System.Windows.CornerRadius(0)
    $badge.Child = $badgeImage
  } catch { }
}
[System.Windows.Controls.Grid]::SetColumn($badge, 0)
[void]$layout.Children.Add($badge)

# Right content: auto-sized grid so numbers line up and the card hugs the text.
$body = New-Object System.Windows.Controls.StackPanel
$body.Margin = New-Object System.Windows.Thickness(2, 10, 16, 10)
$body.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($body, 1)

$hdr = New-Object System.Windows.Controls.DockPanel
$hdr.LastChildFill = $false
$hdr.Margin = New-Object System.Windows.Thickness(0, 0, 0, 5)
$title = New-Object System.Windows.Controls.TextBlock
$title.Text = 'FACTORY USAGE'
$title.Foreground = $orangeBrush
$title.FontFamily = $segoe
$title.FontSize = 9.5
$title.FontWeight = 'SemiBold'
[System.Windows.Controls.DockPanel]::SetDock($title, 'Left')
$stamp = New-Object System.Windows.Controls.TextBlock
$stamp.Text = 'loading...'
$stamp.Foreground = $subBrush
$stamp.FontFamily = $segoe
$stamp.FontSize = 9.5
$stamp.Margin = New-Object System.Windows.Thickness(16, 0, 0, 0)
[System.Windows.Controls.DockPanel]::SetDock($stamp, 'Right')
[void]$hdr.Children.Add($title)
[void]$hdr.Children.Add($stamp)
[void]$body.Children.Add($hdr)

$metrics = New-Object System.Windows.Controls.Grid
for ($i = 0; $i -lt 4; $i++) {
  $col = New-Object System.Windows.Controls.ColumnDefinition
  $col.Width = [System.Windows.GridLength]::Auto
  [void]$metrics.ColumnDefinitions.Add($col)
}
for ($r = 0; $r -lt 3; $r++) {
  $row = New-Object System.Windows.Controls.RowDefinition
  $row.Height = [System.Windows.GridLength]::Auto
  [void]$metrics.RowDefinitions.Add($row)
}

function Add-Cell([int]$r, [int]$c, [string]$text, $brush, [string]$weight, [System.Windows.Thickness]$margin) {
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $text
  $tb.Foreground = $brush
  $tb.FontFamily = $segoe
  $tb.FontSize = 12
  $tb.FontWeight = $weight
  $tb.Margin = $margin
  [System.Windows.Controls.Grid]::SetRow($tb, $r)
  [System.Windows.Controls.Grid]::SetColumn($tb, $c)
  [void]$metrics.Children.Add($tb)
  return $tb
}

[void](Add-Cell 0 0 '5-hour' $mutedBrush 'Normal' (New-Object System.Windows.Thickness(0, 0, 6, 3)))
$fiveHour = Add-Cell 0 1 '--' $whiteBrush 'SemiBold' (New-Object System.Windows.Thickness(0, 0, 18, 3))
[void](Add-Cell 0 2 'Today' $mutedBrush 'Normal' (New-Object System.Windows.Thickness(0, 0, 10, 3)))
$todayCredits = Add-Cell 0 3 '--' $whiteBrush 'SemiBold' (New-Object System.Windows.Thickness(0, 0, 0, 3))
$todayCredits.TextAlignment = 'Right'

[void](Add-Cell 1 0 'Weekly' $mutedBrush 'Normal' (New-Object System.Windows.Thickness(0, 0, 6, 3)))
$weekly = Add-Cell 1 1 '--' $whiteBrush 'SemiBold' (New-Object System.Windows.Thickness(0, 0, 18, 3))
[void](Add-Cell 1 2 'Month' $mutedBrush 'Normal' (New-Object System.Windows.Thickness(0, 0, 10, 3)))
$monthCredits = Add-Cell 1 3 '--' $whiteBrush 'SemiBold' (New-Object System.Windows.Thickness(0, 0, 0, 3))
$monthCredits.TextAlignment = 'Right'

[void](Add-Cell 2 0 'Monthly' $mutedBrush 'Normal' (New-Object System.Windows.Thickness(0, 0, 6, 0)))
$monthly = Add-Cell 2 1 '--' $whiteBrush 'SemiBold' (New-Object System.Windows.Thickness(0, 0, 18, 0))
[void](Add-Cell 2 2 'Extra' $mutedBrush 'Normal' (New-Object System.Windows.Thickness(0, 0, 10, 0)))
$extra = Add-Cell 2 3 '--' $whiteBrush 'SemiBold' (New-Object System.Windows.Thickness(0, 0, 0, 0))
$extra.TextAlignment = 'Right'

[void]$body.Children.Add($metrics)
[void]$layout.Children.Add($body)
$card.Child = $layout
[void]$root.Children.Add($card)
$win.Content = $root

# --- geometry & smooth slide state ---

$script:collapsedX = 0.0
$script:targetOpen = ($PeekSeconds -gt 0)
$script:peekUntil  = if ($PeekSeconds -gt 0) { (Get-Date).AddSeconds([Math]::Max(6, $PeekSeconds)) } else { [datetime]::MinValue }
$script:firstFetch = $true

# Last good reading, so a failed sample (or a restart) shows dated numbers instead
# of blanking the card.
$script:lastLimits   = $null
$script:lastLimitsAt = $null
$limFile = Join-Path $env:LOCALAPPDATA 'factory-usage-overlay.limits.json'
if (Test-Path $limFile) {
  try {
    $sv = Get-Content $limFile -Raw | ConvertFrom-Json
    $script:lastLimits   = $sv.limits
    $script:lastLimitsAt = [datetime]$sv.at
    # a cached -1 is a UIA-era leftover, not a reading
    if ($script:lastLimits -and [int]$script:lastLimits.fiveHour -lt 0) {
      $script:lastLimits = $null
      $script:lastLimitsAt = $null
    }
  } catch { }
}
$script:lastHover  = [datetime]::MinValue
$script:hoverSince = $null
$script:animFrom   = 0.0
$script:animTo     = 0.0
$script:animDurMs  = $ANIM_MS
$script:animWatch  = [System.Diagnostics.Stopwatch]::New()
$script:winReady   = $false
$script:dpiScale   = 1.0
$script:drag       = $null
$script:docked     = $null

# Saved right-edge/top anchor; dragging the open card rewrites this file.
$posFile = Join-Path $env:LOCALAPPDATA 'factory-usage-overlay.pos.json'
$script:anchorRight = $null
$script:anchorTop   = $null
if (Test-Path $posFile) {
  try {
    $saved = Get-Content $posFile -Raw | ConvertFrom-Json
    $script:anchorRight = [double]$saved.right
    $script:anchorTop   = [double]$saved.top
  } catch { $script:anchorRight = $null; $script:anchorTop = $null }
}

# Flat right edge only while docked to the work-area edge; rounded when floated.
function Sync-Corners {
  $wa = [System.Windows.SystemParameters]::WorkArea
  $docked = ([Math]::Abs(($win.Left + $win.ActualWidth) - $wa.Right) -lt 1.5)
  if ($script:docked -eq $docked) { return }
  $script:docked = $docked
  if ($docked) {
    $card.CornerRadius    = New-Object System.Windows.CornerRadius(10, 0, 0, 10)
    $card.BorderThickness = New-Object System.Windows.Thickness(1.5, 1.5, 0, 1.5)
  } else {
    $card.CornerRadius    = New-Object System.Windows.CornerRadius(10)
    $card.BorderThickness = New-Object System.Windows.Thickness(1.5)
  }
}

$animTimer = New-Object System.Windows.Threading.DispatcherTimer
$animTimer.Interval = [TimeSpan]::FromMilliseconds(15)
$animTimer.Add_Tick({
  $ms = $script:animWatch.Elapsed.TotalMilliseconds
  $t = if ($script:animDurMs -le 1.0) { 1.0 } else { [Math]::Min(1.0, $ms / $script:animDurMs) }
  $ease = 1.0 - [Math]::Pow(1.0 - $t, 3)
  $tx.X = $script:animFrom + ($script:animTo - $script:animFrom) * $ease
  if ($t -ge 1.0) {
    $tx.X = $script:animTo
    $animTimer.Stop()
  }
})

function Set-DrawerOpen([bool]$open, [bool]$instant = $false) {
  $dest = if ($open) { 0.0 } else { $script:collapsedX }
  if ($instant) {
    $animTimer.Stop()
    $tx.X = $dest
    $script:animTo = $dest
    return
  }
  if ([Math]::Abs($script:animTo - $dest) -lt 0.5 -and $animTimer.IsEnabled) { return }
  if ([Math]::Abs($tx.X - $dest) -lt 0.5) { $tx.X = $dest; $script:animTo = $dest; return }
  $span = [Math]::Max(1.0, $script:collapsedX)
  $script:animFrom = $tx.X
  $script:animTo = $dest
  $script:animDurMs = [Math]::Max(80.0, $ANIM_MS * ([Math]::Abs($dest - $tx.X) / $span))
  $script:animWatch.Restart()
  $animTimer.Start()
}

function Sync-WindowPlacement {
  if ($win.ActualWidth -le 0) { return }
  $wa = [System.Windows.SystemParameters]::WorkArea
  # Anchor is the card's right edge, so expanding always grows leftward. Clamp it so a
  # stale or out-of-range saved position can never park the tab past the work area.
  $right = if ($null -ne $script:anchorRight) { $script:anchorRight } else { $wa.Right }
  $right = [Math]::Max([Math]::Min($right, $wa.Right), $wa.Left + $TAB_W)
  $win.Left = [double][Math]::Max($wa.Left, $right - $win.ActualWidth)
  if ($null -ne $script:anchorTop) {
    $win.Top = [double][Math]::Min([Math]::Max($wa.Top, $script:anchorTop), $wa.Bottom - 40)
  } else {
    $win.Top = [double][Math]::Round($wa.Top + ($wa.Height - $win.ActualHeight) * 0.28)
  }
  $script:collapsedX = [Math]::Max(0.0, $win.ActualWidth - $TAB_W)
  Sync-Corners
  if (-not $script:targetOpen -and -not $animTimer.IsEnabled) {
    $tx.X = $script:collapsedX
    $script:animTo = $script:collapsedX
  }
}

$win.Add_SizeChanged({ Sync-WindowPlacement })

# Drag the card while it is open; the collapsed tab stays click-through so it can
# never sit on top of a button or scrollbar.
$card.Add_MouseLeftButtonDown({
  $pt = New-Object UsageWin32+POINT
  if (-not [UsageWin32]::GetCursorPos([ref]$pt)) { return }
  $script:drag = @{ px = $pt.X; py = $pt.Y; left = $win.Left; top = $win.Top; moved = $false }
})

# --- hover polling via real DPI-converted screen cursor ---

$hoverTimer = New-Object System.Windows.Threading.DispatcherTimer
$hoverTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$hoverTimer.Add_Tick({
  if (-not $script:winReady -or $win.ActualWidth -le 0) { return }
  # A >5s gap in a 50ms timer means the machine slept or the thread was frozen,
  # which is exactly when a layered surface stops repainting.
  $now = Get-Date
  if ($script:lastTick -and ($now - $script:lastTick).TotalSeconds -gt 5) { Invoke-Revive }
  $script:lastTick = $now
  $pt = New-Object UsageWin32+POINT
  $gotPt = [UsageWin32]::GetCursorPos([ref]$pt)
  if ($script:drag) {
    if ($gotPt -and [System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
      $d = $script:drag
      $dx = ($pt.X - $d.px) / $script:dpiScale
      $dy = ($pt.Y - $d.py) / $script:dpiScale
      if (([Math]::Abs($dx) + [Math]::Abs($dy)) -gt 1.5) { $d.moved = $true }
      $wa = [System.Windows.SystemParameters]::WorkArea
      # Clamp the whole window, not the collapsed tab, or the tab can end up off-screen
      # to the right and the saved anchor inherits that bad position.
      $win.Left = [double][Math]::Max($wa.Left, [Math]::Min($d.left + $dx, $wa.Right - $win.ActualWidth))
      $win.Top  = [double][Math]::Max($wa.Top,  [Math]::Min($d.top + $dy, $wa.Bottom - 40))
      # Track the anchor live so a SizeChanged mid-drag cannot snap the card back.
      $script:anchorRight = $win.Left + $win.ActualWidth
      $script:anchorTop   = $win.Top
      Sync-Corners
      $script:lastHover = Get-Date
      return
    }
    if ($script:drag.moved) {
      try {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        [System.IO.File]::WriteAllText($posFile,
          '{"right":' + $script:anchorRight.ToString($inv) + ',"top":' + $script:anchorTop.ToString($inv) + '}')
      } catch { }
    }
    $script:drag = $null
  }
  $over = $false
  if ($gotPt) {
    try {
      $local = $win.PointFromScreen([System.Windows.Point]::new($pt.X, $pt.Y))
      # Hit-test only the visible part of the card so alpha=0 area stays click-through.
      $over = ($local.X -ge ($tx.X - 2) -and $local.X -le ($win.ActualWidth + 2) -and
               $local.Y -ge 0 -and $local.Y -le $win.ActualHeight)
    } catch { $over = $false }
  }
  if ($over) {
    if (-not $script:hoverSince) { $script:hoverSince = $now }
    $script:lastHover = $now
    $wantOpen = (($now - $script:hoverSince).TotalMilliseconds -ge $HOVER_DWELL_MS)
  } else {
    $script:hoverSince = $null
    $wantOpen = (($now - $script:lastHover).TotalMilliseconds -lt $UNHOVER_MS)
  }
  if ($now -lt $script:peekUntil) { $wantOpen = $true }
  if ($wantOpen -ne $script:targetOpen) {
    $script:targetOpen = $wantOpen
    Set-DrawerOpen $wantOpen $false
  }
})
$hoverTimer.Start()

# --- non-blocking scans: usage limits (headless Chrome) + credits (session files) ---

$script:fetchTask = $null
$script:limitTask = $null
$script:limitStart = Get-Date

function Start-UsageFetch {
  if (-not $script:fetchTask -or $script:fetchTask.IsCompleted) {
    $script:fetchTask = [UsageWin32]::ScanCreditsAsync($sessionsRoot)
  }
  # started off the UI thread; the poll timer below abandons a stuck run
  if (-not $script:limitTask -or $script:limitTask.IsCompleted) {
    $script:limitStart = Get-Date
    if (-not $nodeExe) {
      $script:limitTask = [System.Threading.Tasks.Task[string]]::FromResult('{"ok":false,"reason":"node_missing"}')
    } elseif (-not (Test-Path $limitsJs)) {
      $script:limitTask = [System.Threading.Tasks.Task[string]]::FromResult('{"ok":false,"reason":"sampler_missing"}')
    } else {
      $script:limitTask = [UsageWin32]::ScanLimitsAsync($nodeExe, $limitsJs, 45000)
    }
  }
}

# [int] matters: in argument mode PowerShell binds a bare -1 as the *string* "-1",
# and "-1" -lt 0 is a string comparison that is false, which printed "-1%".
function Set-LimitCell($cell, [int]$pct) {
  if ($pct -lt 0) { $cell.Text = '--'; $cell.Foreground = $subBrush; return }
  $cell.Text = ('{0}%' -f $pct)
  if ($pct -ge 100) { $cell.Foreground = $redBrush }
  elseif ($pct -ge 70) { $cell.Foreground = $orangeBrush }
  else { $cell.Foreground = $whiteBrush }
}

# Percentages stay on the card when the page is only backgrounded: the value is
# still the last real one, so show it with its age ("02:31 +12m") instead of "--".
function Show-Limits($l, $at) {
  Set-LimitCell $fiveHour $l.fiveHour
  Set-LimitCell $weekly $l.weekly
  Set-LimitCell $monthly $l.monthly
  if ($l.extra) { $extra.Text = '$' + $l.extra; $extra.Foreground = $whiteBrush }
  else { $extra.Text = '--'; $extra.Foreground = $subBrush }
  $age = ((Get-Date) - $at).TotalMinutes
  if ($age -lt 0.7) { $stamp.Text = $at.ToString('HH:mm') }
  else { $stamp.Text = ('{0} +{1}m' -f $at.ToString('HH:mm'), [Math]::Max(1, [int][Math]::Floor($age))) }
}

$pollFetch = New-Object System.Windows.Threading.DispatcherTimer
$pollFetch.Interval = [TimeSpan]::FromMilliseconds(150)
$pollFetch.Add_Tick({
  # A cold Chrome start plus a page render can legitimately take 30s, so the
  # abandon window must sit above the caller's own 45s timeout or a healthy
  # sample gets killed and the next one collides on the locked profile.
  if ($script:limitTask -and -not $script:limitTask.IsCompleted -and
      ((Get-Date) - $script:limitStart).TotalSeconds -gt 40) {
    $script:limitStart = Get-Date
    $script:limitTask = $null
    Start-UsageFetch
  }
  if ($script:fetchTask -and $script:fetchTask.IsCompleted) {
    $task = $script:fetchTask
    $script:fetchTask = $null
    try {
      $u = $task.Result | ConvertFrom-Json
      if ($u.missing) {
        $todayCredits.Text = '--'
        $monthCredits.Text = '--'
      } else {
        $todayCredits.Text = Format-Credits $u.todayCredits
        $monthCredits.Text = Format-Credits $u.monthCredits
      }
      if ($script:firstFetch) {
        $script:firstFetch = $false
        if ($PeekSeconds -gt 0) { $script:peekUntil = (Get-Date).AddSeconds($PeekSeconds) }
      }
    } catch {
      $todayCredits.Text = 'err'
      $monthCredits.Text = 'err'
    }
  }
  if ($script:limitTask -and $script:limitTask.IsCompleted) {
    $task = $script:limitTask
    $script:limitTask = $null
    try {
      $l = $task.Result | ConvertFrom-Json
      if ($l.ok) {
        $script:lastLimits   = $l
        $script:lastLimitsAt = Get-Date
        Show-Limits $l $script:lastLimitsAt
        try {
          @{ at = $script:lastLimitsAt.ToString('o')
             limits = @{ fiveHour = $l.fiveHour; weekly = $l.weekly; monthly = $l.monthly; extra = $l.extra } } |
            ConvertTo-Json -Compress | Set-Content -Path $limFile
        } catch { }
      } else {
        $age = if ($script:lastLimitsAt) { ((Get-Date) - $script:lastLimitsAt).TotalMinutes } else { 999 }
        $expired = -not ($script:lastLimits -and $age -lt 60)
        if (-not $expired) {
          Show-Limits $script:lastLimits $script:lastLimitsAt
          if ($l.reason -eq 'needs_login') { $stamp.Text = 'login once' }
          elseif ($l.reason -eq 'profile_in_use') { $stamp.Text = 'close sign-in' }
        } else {
          Set-LimitCell $fiveHour -1
          Set-LimitCell $weekly -1
          Set-LimitCell $monthly -1
          $extra.Text = '--'
          $extra.Foreground = $subBrush
          $stamp.Text = switch ($l.reason) {
            'needs_login'     { 'login once' }
            'profile_in_use'  { 'close sign-in' }
            'timeout'         { 'limits slow' }
            'node_missing'    { 'need node' }
            'sampler_missing' { 'no sampler' }
            'chrome_missing'  { 'need chrome' }
            'windows_only'    { 'windows only' }
            default           { 'no limits' }
          }
        }
        $retry = switch ($l.reason) {
          'timeout'         { 60 }
          'needs_login'     { 300 }
          'node_missing'    { 900 }
          'sampler_missing' { 900 }
          'chrome_missing'  { 900 }
          default           { 120 }
        }
        $script:nextFetchAt = (Get-Date).AddSeconds($retry)
      }
    } catch {
      $stamp.Text = 'limits err'
    }
  }
})
$pollFetch.Start()

# the gate lets a missed scan retry in 20s instead of waiting the full interval
$script:nextFetchAt = Get-Date
$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromSeconds(5)
$refreshTimer.Add_Tick({
  if ((Get-Date) -lt $script:nextFetchAt) { return }
  # 60s floor: each sample costs a Chrome cold start, so hammering it is not a
  # setting we want to honour.
  $script:nextFetchAt = (Get-Date).AddSeconds([Math]::Max(60, $IntervalSeconds))
  Start-UsageFetch
})
$refreshTimer.Start()

$win.Add_ContentRendered({
  $src = [System.Windows.PresentationSource]::FromVisual($win)
  if ($src) { $script:dpiScale = $src.CompositionTarget.TransformToDevice.M11 }
  Sync-WindowPlacement
  Set-DrawerOpen $script:targetOpen $true
  # A layered window can come up with a stale DWM surface: present, tool-window
  # style correct, sampling normally, but nothing painted. One opacity nudge
  # forces the compositor to rebuild it; at 1% it is not visible as a flicker.
  $win.Opacity = 0.99
  $win.Opacity = 1.0
  $script:winReady = $true
  Start-UsageFetch
})

# Modern Standby and display changes drop a layered window's DWM surface, and WPF
# never repaints it because nothing in the visual tree changed. Re-showing the
# window is the one thing that makes the compositor rebuild it.
function Revive-OverlayWindow {
  try {
    $win.Hide()
    $win.Show()
    $win.Topmost = $true
  } catch { }
}

# SystemEvents raises on its own thread, so hop back to the dispatcher.
function Invoke-Revive {
  try { [void]$win.Dispatcher.InvokeAsync([Action]{ Revive-OverlayWindow }) } catch { }
}

[Microsoft.Win32.SystemEvents]::add_PowerModeChanged([Microsoft.Win32.PowerModeChangedEventHandler]{
  param($sender, $e)
  if ($e.Mode -eq [Microsoft.Win32.PowerModes]::Resume) { Invoke-Revive }
})
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged([EventHandler]{
  param($sender, $e)
  Invoke-Revive
})

$win.Add_SourceInitialized({
  $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
  $GWL_EXSTYLE = -20
  $style = [UsageWin32]::GetWindowLong($hwnd, $GWL_EXSTYLE)
  # NOACTIVATE + TOOLWINDOW: receives mouse input without stealing focus and stays
  # out of Alt-Tab. Pixels the card does not cover are alpha 0, so the layered
  # window lets those clicks fall through on their own.
  [void][UsageWin32]::SetWindowLong($hwnd, $GWL_EXSTYLE, ($style -bor 0x00000080 -bor 0x08000000))
})

[void]$app.Run($win)
