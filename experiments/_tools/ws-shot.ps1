# Open a pcap in Wireshark, resize the window, save a screenshot (PNG), close it.
#   ws-shot.ps1 -Pcap x.pcap -Out x.png [-Filter "tcp"] [-Go 12] [-W 1600] [-H 900]
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
  [int]$H = 900
)
Add-Type @"
using System; using System.Runtime.InteropServices;
public class WsU {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  public struct RECT { public int L, T, R, B; }
}
"@
Add-Type -AssemblyName System.Drawing
$ws = "C:\Program Files\Wireshark\Wireshark.exe"
# Install the chapter profile (columns, layout, checksum validation) every run so it stays in sync.
$prof = Join-Path $env:APPDATA "Wireshark\profiles\lab-chapters"
New-Item -ItemType Directory -Force $prof | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot "wireshark-profile\*") $prof
$Pcap = (Resolve-Path $Pcap).Path
function Q($s) { '"' + ($s -replace '"', '\"') + '"' }
$a = @('-C', 'lab-chapters', '-r', (Q $Pcap))
if ($Filter) { $a += @('-Y', (Q $Filter)) }
if ($Go -gt 0) { $a += @('-g', "$Go") }
$p = Start-Process $ws -ArgumentList ($a -join ' ') -PassThru
$name = [IO.Path]::GetFileName($Pcap)
for ($i = 0; $i -lt 80; $i++) {
  Start-Sleep -Milliseconds 500; $p.Refresh()
  if ($p.MainWindowTitle -like "*$name*") { break }
}
Start-Sleep 2
$h = $p.MainWindowHandle
[WsU]::SetWindowPos($h, [IntPtr]::Zero, 10, 10, $W, $H, 0x40) | Out-Null
Start-Sleep 2
$r = New-Object WsU+RECT
[WsU]::GetWindowRect($h, [ref]$r) | Out-Null
$bmp = New-Object Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
$g = [Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc(); [WsU]::PrintWindow($h, $dc, 2) | Out-Null; $g.ReleaseHdc($dc)
New-Item -ItemType Directory -Force (Split-Path -Parent $Out) | Out-Null
$bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
Stop-Process -Id $p.Id -Force
Write-Output "saved $Out ($($bmp.Width)x$($bmp.Height))"
