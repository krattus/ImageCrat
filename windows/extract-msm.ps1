# Extracts the files of an MSI merge module (.msm) into a folder, using their real file names.
# Used to take the x64 Swift runtime DLLs out of the toolchain's rtl.amd64.msm when cross-compiling from Arm64.
param([Parameter(Mandatory)][string]$Msm, [Parameter(Mandatory)][string]$OutDir)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$tmp = Join-Path $env:TEMP ("msm-" + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Msm, 0))
# The cabinet is stored in the _Streams table as "MergeModule.CABinet"; MsiDb (Windows SDK) writes it out byte-exact.
$msidb = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x86\MsiDb.exe" | Sort-Object FullName | Select-Object -Last 1
if (-not $msidb) { throw 'MsiDb.exe (Windows SDK) not found' }
Push-Location $tmp; try { & $msidb.FullName -d (Resolve-Path $Msm).Path -x MergeModule.CABinet | Out-Null } finally { Pop-Location }  # writes into the current directory
$cab = Join-Path $tmp 'MergeModule.CABinet'
if (-not (Test-Path $cab)) { throw "no cabinet stream in $Msm" }
$x = Join-Path $tmp 'x'; New-Item -ItemType Directory $x | Out-Null
& expand.exe -F:* $cab $x | Out-Null
$view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT ``File``, ``FileName`` FROM ``File``"))
$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
while ($rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)) {
    $key = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1)
    $fn = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 2)
    if ($fn -match '\|') { $fn = $fn.Split('|')[1] }
    $src = Join-Path $x $key
    if (Test-Path $src) { Copy-Item $src (Join-Path $OutDir $fn) -Force }
}
Remove-Item -Recurse -Force $tmp
