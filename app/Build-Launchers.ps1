# One-time setup (run by Setup.cmd). Builds RVCE-Connect.exe and RVCE-Stop.exe next to the app folder
# from Launcher.cs, using the C# compiler that ships with Windows (.NET Framework).
# Re-run it after moving the folder or editing Launcher.cs.
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

$src = Get-Content -LiteralPath (Join-Path $app 'Launcher.cs') -Raw
$connect = Join-Path $root 'RVCE-Connect.exe'
$stop    = Join-Path $root 'RVCE-Stop.exe'
foreach ($f in $connect, $stop) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
Add-Type -TypeDefinition $src -Language CSharp -OutputAssembly $connect -OutputType WindowsApplication `
         -ReferencedAssemblies System.Windows.Forms
Copy-Item -LiteralPath $connect -Destination $stop
Write-Host "[OK] Built RVCE-Connect.exe and RVCE-Stop.exe in $root" -ForegroundColor Green
