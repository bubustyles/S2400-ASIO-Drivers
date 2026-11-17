# Fenster-Foto fuer das Handbuch
# Aufruf:  powershell -ExecutionPolicy Bypass -File fenster_foto.ps1 -Name zuspieler_stack
#          (-Bildschirm fotografiert den ganzen Hauptbildschirm, z.B. fuer Menues)
# Nach dem Start bleiben 5 Sekunden, um das gewuenschte Fenster anzuklicken
# (bzw. das Menue zu oeffnen). Dann wird das Fenster im Vordergrund als PNG
# in den Ordner img neben diesem Skript gespeichert.
param([Parameter(Mandatory = $true)][string]$Name, [switch]$Bildschirm, [int]$Warten = 5)
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class FF {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public struct RECT { public int L, T, R, B; }
}
"@
[FF]::SetProcessDPIAware() | Out-Null
$ziel = Join-Path $PSScriptRoot 'img'
New-Item -ItemType Directory -Force $ziel | Out-Null
$datei = Join-Path $ziel ($Name + '.png')
for ($i = $Warten; $i -gt 0; $i--) { Write-Host "Foto in $i ..."; Start-Sleep -Seconds 1 }
if ($Bildschirm) {
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [Drawing.Point]::Empty, $b.Size)
  $g.Dispose()
} else {
  $h = [FF]::GetForegroundWindow()
  $r = New-Object FF+RECT
  [FF]::GetWindowRect($h, [ref]$r) | Out-Null
  $bmp = New-Object Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $dc = $g.GetHdc()
  [FF]::PrintWindow($h, $dc, 2) | Out-Null
  $g.ReleaseHdc($dc)
  $g.Dispose()
}
$bmp.Save($datei, [Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "Gespeichert: $datei"
