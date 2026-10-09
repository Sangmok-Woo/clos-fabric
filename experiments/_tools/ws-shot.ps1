# Open a pcap in Wireshark, resize the window, save a screenshot (PNG), close it.
#   ws-shot.ps1 -Pcap x.pcap -Out x.png [-Filter "tcp"] [-Go 12] [-W 1600] [-H 900] [-Col "AS path=bgp.update.path_attribute.as_path_segment"]
# -Crop N keeps only the top N pixels of the window (packet list without the details pane).
# -Col adds custom columns (Title=field, repeatable) before Info, in a separate profile (lab-chapters-cols).
# -Go selects a packet so the details pane shows it (top-level rows only; for the full tree use
# tshark -V, see detail.sh). No keystrokes are sent: Windows may refuse to focus the window and
# the keys would land in whatever else is in front.
# Uses the lab-chapters profile (wireshark-profile/): default columns, list over details, no bytes pane.
param(
  [Parameter(Mandatory)][string]$Pcap,
  [Parameter(Mandatory)][string]$Out,
  [string]$Filter = "",
  [int]$Go = 0,
  [int]$W = 1600,
  [int]$H = 900,
  [string[]]$Col = @(),
  [int]$Crop = 0
)
Add-Type @"
using System; using System.Runtime.InteropServices;
public class WsU {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  public struct RECT { public int L, T, R, B; }
}
"@
Add-Type -AssemblyName System.Drawing
$ws = "C:\Program Files\Wireshark\Wireshark.exe"
# Install the chapter profile (columns, layout, checksum validation) every run so it stays in sync.
$prof = Join-Path $env:APPDATA "Wireshark\profiles\lab-chapters"
New-Item -ItemType Directory -Force $prof | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot "wireshark-profile\*") $prof
$profName = 'lab-chapters'
# powershell -File passes "a=x,b=y" as one string: split it back into columns
$Col = @($Col | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($Col.Count -gt 0) {
  $profName = 'lab-chapters-cols'
  $p2 = Join-Path $env:APPDATA "Wireshark\profiles\$profName"
  New-Item -ItemType Directory -Force $p2 | Out-Null
  Copy-Item -Force (Join-Path $PSScriptRoot "wireshark-profile\*") $p2
  $extra = ($Col | ForEach-Object { $t, $f = $_ -split '=', 2; "`t`"$t`", `"%Cus:$f`"," }) -join "`n"
  $pref = (Get-Content (Join-Path $p2 'preferences') -Raw) -replace '(	"Info", "%i")', ($extra.Replace('$', '$$') + "`n" + '$1')
  [IO.File]::WriteAllText((Join-Path $p2 'preferences'), $pref)
}
$Pcap = (Resolve-Path $Pcap).Path
function Q($s) { '"' + ($s -replace '"', '\"') + '"' }
$a = @('-C', $profName, '-r', (Q $Pcap))
if ($Filter) { $a += @('-Y', (Q $Filter)) }
if ($Go -gt 0) { $a += @('-g', "$Go") }
$p = Start-Process $ws -ArgumentList ($a -join ' ') -PassThru
$name = [IO.Path]::GetFileName($Pcap)
for ($i = 0; $i -lt 80; $i++) {
  Start-Sleep -Milliseconds 500; $p.Refresh()
  if ($p.MainWindowTitle -like "*$name*") { break }
}
Start-Sleep 2
$r = New-Object WsU+RECT
# Wireshark can open minimized or still be swapping its splash for the main window (rect ~160x28):
# restore without taking focus, resize, and retry until the window really has our size
for ($k = 0; $k -lt 10; $k++) {
  $p.Refresh(); $hwnd = $p.MainWindowHandle   # not $h: PowerShell names are case-insensitive and $H is the height
  [WsU]::ShowWindow($hwnd, 4) | Out-Null   # SW_SHOWNOACTIVATE
  [WsU]::SetWindowPos($hwnd, [IntPtr]::Zero, 10, 10, $W, $H, 0x40) | Out-Null
  Start-Sleep 2
  [WsU]::GetWindowRect($hwnd, [ref]$r) | Out-Null
  if (($r.R - $r.L) -gt 400) { break }
}
$bmp = New-Object Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
$g = [Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc(); [WsU]::PrintWindow($hwnd, $dc, 2) | Out-Null; $g.ReleaseHdc($dc)
# -Crop keeps only the top N pixels (packet list only, when the details pane is not needed)
if ($Crop -gt 0 -and $bmp.Height -gt $Crop) {
  $cut = $bmp.Clone((New-Object Drawing.Rectangle 0, 0, $bmp.Width, $Crop), $bmp.PixelFormat)
  $bmp.Dispose(); $bmp = $cut
}
New-Item -ItemType Directory -Force (Split-Path -Parent $Out) | Out-Null
$bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
Stop-Process -Id $p.Id -Force
Write-Output "saved $Out ($($bmp.Width)x$($bmp.Height))"
