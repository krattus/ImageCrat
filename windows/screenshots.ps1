<#
.SYNOPSIS
  Renders ImageCrat Preview windows to PNG with the hidden --snapshot flag (for docs and visual checks in the build VM,
  which has no screen-capture tool). Without a desktop compositor (an SSH session) only the client area is captured:
  no title bar or menu bar.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File windows\screenshots.ps1 -Exe .build\debug\ImageCratPreview.exe -Samples C:\dev\samples -Psd C:\dev\psd -Out C:\dev\shots
#>
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Samples,   # folder written by `imagecrat-cli make-samples`
    [string]$Psd = '',                        # optional folder with real Photoshop files
    [Parameter(Mandatory)][string]$Out,
    [string]$Size = '1280x800'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $Out | Out-Null
function Quote($s) { if ($s -match '[\s"]') { '"' + ($s -replace '\\$', '\\') + '"' } else { $s } }
$shots = @(
    @{ Name = 'empty'; Args = @() },
    @{ Name = 'psd-synthetic'; Args = @("$Samples\Synthetic layered 8-bit.psd", '--select', '2') },
    @{ Name = 'brushes-abr'; Args = @("$Samples\Sample Brushes.abr") },
    @{ Name = 'brushes-brushset'; Args = @("$Samples\Sample Set.brushset") },
    @{ Name = 'png'; Args = @("$Samples\Bubbles (transparent).png") },
    @{ Name = 'about'; Args = @('--about') },
    @{ Name = 'selfcheck'; Args = @('--selfcheck') },
    @{ Name = 'error'; Args = @("$Samples\Not an image.txt") }
)
if ($Psd) {
    $shots += @{ Name = 'psd-everything'; Args = @("$Psd\ps_resave_08_everything.psd", '--select', '4') }
    $shots += @{ Name = 'psd-layer-preview'; Args = @("$Psd\ic_export_06_masks_blending_groups_resources.psd", '--select', '8', '--preview-layer', '8') }
    $shots += @{ Name = 'psd-16bit-zoom'; Args = @("$Psd\ic_export_09_sixteen_bit_shapes.psd", '--zoom', '300') }
    $shots += @{ Name = 'psb'; Args = @("$Psd\ps_resave_10_everything_large_document.psb") }
}
foreach ($s in $shots) {
    $png = Join-Path $Out "$($s.Name).png"
    $argList = (@('--snapshot', $png, '--size', $Size) + $s.Args | ForEach-Object { Quote $_ }) -join ' '
    $p = Start-Process -FilePath $Exe -ArgumentList $argList -Wait -PassThru -RedirectStandardError (Join-Path $Out "$($s.Name).err.txt")
    Write-Host ("{0,-20} exit {1}  {2}" -f $s.Name, $p.ExitCode, $(if (Test-Path $png) { (Get-Item $png).Length } else { 'no image' }))
}
