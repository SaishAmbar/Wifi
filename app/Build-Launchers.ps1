# One-time setup (run by Setup.cmd):
#   1. draws the two icons (app\icons\*.ico),
#   2. builds RVCE-Connect.exe and RVCE-Stop.exe next to the app folder from Launcher.cs, using the C# compiler
#      that ships with Windows (.NET Framework), with those icons,
#   3. creates "RVCE Connect" and "RVCE Disconnect" shortcuts on the desktop (skip with -NoShortcuts).
# Re-run it after moving the folder or editing Launcher.cs.
param([switch] $NoShortcuts)
$ErrorActionPreference = 'Stop'
$app  = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $app

if ($root -match '\\OneDrive') {
    Write-Host "[!]  This folder is inside OneDrive: $root" -ForegroundColor Yellow
    Write-Host "     It works, but OneDrive may make the files 'online-only', and they can't be downloaded while the"
    Write-Host "     Wi-Fi portal is blocking the internet. Consider moving the folder (e.g. to C:\Users\<you>\RVCE-Connect)"
    Write-Host "     and running Setup.cmd again, or right-click it > 'Always keep on this device'."
}

# Files downloaded from GitHub are marked as coming from the internet; clear that mark for this folder only.
Get-ChildItem -LiteralPath $root -Recurse -File | Unblock-File

# ---------------------------------------------------------------- icons
Add-Type -AssemblyName System.Drawing

# Round Wi-Fi badge; $slash adds a "disconnected" bar. Saved as a multi-size .ico (PNG entries).
function New-RvceIcon([string]$path, [Drawing.Color]$color, [bool]$slash) {
    $pngs = New-Object System.Collections.Generic.List[byte[]]
    $sizes = @(16, 24, 32, 48, 64, 256)
    foreach ($s in $sizes) {
        $bmp = New-Object Drawing.Bitmap $s, $s
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([Drawing.Color]::Transparent)
        $bg = New-Object Drawing.SolidBrush $color
        $g.FillEllipse($bg, [single]0.5, [single]0.5, [single]($s - 1), [single]($s - 1))
        $pen = New-Object Drawing.Pen ([Drawing.Color]::White), ([single][Math]::Max(1.4, $s * 0.085))
        $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round; $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $cx = $s / 2.0; $cy = $s * 0.68
        foreach ($k in 0.34, 0.23, 0.12) {
            $r = $s * $k
            $g.DrawArc($pen, [single]($cx - $r), [single]($cy - $r), [single](2 * $r), [single](2 * $r), [single]225, [single]90)
        }
        $d = [Math]::Max(2.0, $s * 0.11)
        $g.FillEllipse([Drawing.Brushes]::White, [single]($cx - $d / 2), [single]($cy - $d / 2), [single]$d, [single]$d)
        if ($slash) {
            $sp = New-Object Drawing.Pen ([Drawing.Color]::White), ([single][Math]::Max(1.6, $s * 0.1))
            $sp.StartCap = [Drawing.Drawing2D.LineCap]::Round; $sp.EndCap = [Drawing.Drawing2D.LineCap]::Round
            $g.DrawLine($sp, [single]($s * 0.27), [single]($s * 0.27), [single]($s * 0.73), [single]($s * 0.73))
            $sp.Dispose()
        }
        $pen.Dispose(); $bg.Dispose(); $g.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $pngs.Add($ms.ToArray()); $ms.Dispose(); $bmp.Dispose()
    }
    $fs = [IO.File]::Create($path)
    $bw = New-Object IO.BinaryWriter $fs
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $dim = $sizes[$i]; if ($dim -ge 256) { $dim = 0 }
            $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
            $bw.Write([uint16]1); $bw.Write([uint16]32)
            $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
            $offset += $pngs[$i].Length
        }
        foreach ($p in $pngs) { $bw.Write($p) }
    } finally { $bw.Close() }
}

$iconDir = Join-Path $app 'icons'
New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
$connectIco = Join-Path $iconDir 'connect.ico'
$stopIco    = Join-Path $iconDir 'disconnect.ico'
New-RvceIcon $connectIco ([Drawing.Color]::FromArgb(46, 160, 67)) $false
New-RvceIcon $stopIco    ([Drawing.Color]::FromArgb(207, 34, 46)) $true

# ---------------------------------------------------------------- launchers
$src = Get-Content -LiteralPath (Join-Path $app 'Launcher.cs') -Raw
$connect = Join-Path $root 'RVCE-Connect.exe'
$stop    = Join-Path $root 'RVCE-Stop.exe'

function Build-Launcher([string]$out, [string]$icon) {
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    $cp = New-Object System.CodeDom.Compiler.CompilerParameters
    $cp.GenerateExecutable = $true
    $cp.OutputAssembly = $out
    [void]$cp.ReferencedAssemblies.Add('System.dll')
    [void]$cp.ReferencedAssemblies.Add('System.Windows.Forms.dll')
    $cp.CompilerOptions = '/target:winexe /win32icon:"' + $icon + '"'
    $result = (New-Object Microsoft.CSharp.CSharpCodeProvider).CompileAssemblyFromSource($cp, $src)
    if ($result.Errors.HasErrors) { throw ('Build failed: ' + (($result.Errors | ForEach-Object { $_.ToString() }) -join '; ')) }
}
Build-Launcher $connect $connectIco
Build-Launcher $stop    $stopIco
Write-Host "[OK] Built RVCE-Connect.exe and RVCE-Stop.exe in $root" -ForegroundColor Green

# ---------------------------------------------------------------- desktop shortcuts
if (-not $NoShortcuts) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $sh = New-Object -ComObject WScript.Shell
    foreach ($s in @(
        @{ Name = 'RVCE Connect';    Target = $connect; Icon = $connectIco; Desc = 'Sign in to the RVCE Wi-Fi and start the watcher' },
        @{ Name = 'RVCE Disconnect'; Target = $stop;    Icon = $stopIco;    Desc = 'Stop the watcher and sign out of the RVCE Wi-Fi' })) {
        $lnk = $sh.CreateShortcut((Join-Path $desktop ($s.Name + '.lnk')))
        $lnk.TargetPath = $s.Target
        $lnk.WorkingDirectory = $root
        $lnk.IconLocation = $s.Icon + ',0'
        $lnk.Description = $s.Desc
        $lnk.Save()
    }
    Write-Host "[OK] Desktop shortcuts: 'RVCE Connect' and 'RVCE Disconnect' ($desktop)" -ForegroundColor Green
}
