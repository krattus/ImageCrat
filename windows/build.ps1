<#
.SYNOPSIS
  Builds ImageCrat Preview for Windows: release builds for x64 and arm64, a self-contained folder per architecture
  (Swift and MSVC runtime DLLs next to the executables), checks, Inno Setup installers and portable zips.

.DESCRIPTION
  Run from a checkout on Windows with Swift 6.3.x, Visual Studio 2022 Build Tools (C++ for x64 and arm64, Windows SDK)
  and Inno Setup 6. One Swift toolchain cross-compiles both architectures: its Windows SDK ships the x86_64, aarch64
  and i686 libraries, and the matching runtime DLLs are taken from the toolchain's merge modules
  (Redistributables\<version>\rtl.<arch>.msm), so an Arm64 machine builds x64 and vice versa.

  Outputs (dist\windows):
    ImageCratPreview-Setup-x64.exe, ImageCratPreview-Setup-arm64.exe
    ImageCratPreview-<version>-x64-portable.zip, ImageCratPreview-<version>-arm64-portable.zip
    dependencies-<arch>.txt (dumpbin /dependents of every shipped binary), selfcheck-<arch>.txt, SHA256SUMS.txt

  Checks per architecture: every DLL dependency is either shipped or part of Windows (nothing may come from the
  toolchain), then `imagecrat-cli selfcheck` and a GUI smoke test run with PATH reduced to the Windows folders.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File windows\build.ps1
  powershell -ExecutionPolicy Bypass -File windows\build.ps1 -Arch arm64 -SkipInstaller
#>
param(
    [ValidateSet('x64', 'arm64')][string[]]$Arch = @('x64', 'arm64'),
    [switch]$SkipInstaller,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
# imagecrat-cli writes UTF-8 (×, —, layer names); read native output that way
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$Win = Join-Path $Root 'windows'
$Build = Join-Path $Win 'build'
$Dist = Join-Path $Root 'dist\windows'
New-Item -ItemType Directory -Force $Build, $Dist, (Join-Path $Build 'res') | Out-Null

function Step($m) { Write-Host "==> $m" }
function Fail($m) { Write-Host "ERROR: $m"; exit 1 }
function WriteText($path, $text) { [IO.File]::WriteAllText($path, $text) }   # UTF-8 without BOM
# Native programs write progress to stderr; with 'Stop' Windows PowerShell 5.1 would turn that into an error.
function Run([scriptblock]$Block) { $ErrorActionPreference = 'Continue'; & $Block }
function Crlf($text) { ($text -replace "`r`n", "`n") -replace "`n", "`r`n" }

# ---- version and build stamp -------------------------------------------------------------------------------------
$info = Get-Content -Raw 'Sources\ImageCratWinSupport\BuildInfo.swift'
if ($info -notmatch 'static let version = "([0-9.]+)"') { Fail 'version not found in BuildInfo.swift' }
$Version = $Matches[1]
$v = @($Version.Split('.') + @('0', '0', '0'))[0..3]
$Version4 = $v -join '.'
$VersionComma = $v -join ','
$BuildDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
WriteText (Join-Path $Root 'Sources\ImageCratWinSupport\BuildStamp.swift') "// Written by windows/build.ps1.`nenum BuildStamp {`n    static let date: String? = `"$BuildDate`"`n}`n"
Step "ImageCrat Preview $Version, build $BuildDate"

# ---- tools -------------------------------------------------------------------------------------------------------
$HostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$VS = & $vswhere -latest -products * -property installationPath
if (-not $VS) { Fail 'Visual Studio Build Tools not found' }
$Msvc = (Get-ChildItem "$VS\VC\Tools\MSVC" -Directory | Sort-Object Name | Select-Object -Last 1).FullName
$Dumpbin = "$Msvc\bin\Host$HostArch\$HostArch\dumpbin.exe"
if (-not (Test-Path $Dumpbin)) { Fail "dumpbin not found: $Dumpbin" }
$Redist = (Get-ChildItem "$VS\VC\Redist\MSVC" -Directory | Where-Object { $_.Name -match '^\d' } | Sort-Object Name | Select-Object -Last 1).FullName
$Rc = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.*\$HostArch\rc.exe", "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.*\x86\rc.exe" -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
if (-not $Rc) { Fail 'rc.exe (Windows SDK) not found' }
$SwiftRoot = "$env:LOCALAPPDATA\Programs\Swift"
$SwiftVer = (Get-ChildItem "$SwiftRoot\Redistributables" -Directory | Sort-Object Name | Select-Object -Last 1).Name
$ISCC = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $SkipInstaller -and -not $ISCC) { Fail 'Inno Setup 6 (ISCC.exe) not found; install it or pass -SkipInstaller' }
Run { & swift --version 2>&1 } | Select-Object -First 1 | ForEach-Object { Step "$_ (runtime $SwiftVer), MSVC $(Split-Path -Leaf $Msvc), host $HostArch" }

# ---- Windows resources: icon, manifest, version information --------------------------------------------------------
Step 'Compiling resources'
$template = Get-Content -Raw "$Win\resources.rc.in"
$resources = @(
    @{ Name = 'ImageCratPreview'; Exe = 'ImageCratPreview.exe'; Description = 'ImageCrat Preview (technical preview)'; Manifest = 'ImageCratPreview.manifest' },
    @{ Name = 'ImageCratCLI'; Exe = 'imagecrat-cli.exe'; Description = 'ImageCrat command-line tool'; Manifest = 'ImageCratCLI.manifest' }
)
foreach ($r in $resources) {
    $man = (Get-Content -Raw "$Win\$($r.Manifest)").Replace('@VERSION4@', $Version4)
    $manPath = Join-Path $Build "res\$($r.Manifest)"
    WriteText $manPath $man
    $rcText = $template.Replace('@ICON@', ("$Win\ImageCrat.ico" -replace '\\', '\\')).Replace('@MANIFEST@', ($manPath -replace '\\', '\\')).
        Replace('@NAME@', $r.Name).Replace('@EXE@', $r.Exe).Replace('@DESCRIPTION@', $r.Description).
        Replace('@VERSIONCOMMA@', $VersionComma).Replace('@VERSION@', $Version)
    $rcPath = Join-Path $Build "res\$($r.Name).rc"
    WriteText $rcPath $rcText
    Run { & $Rc.FullName /nologo /fo (Join-Path $Build "res\$($r.Name).res") $rcPath }
    if ($LASTEXITCODE) { Fail "rc.exe failed for $($r.Name)" }
}

# ---- unit tests (native architecture) ------------------------------------------------------------------------------
if (-not $SkipTests) {
    Step 'Unit tests (swift test)'
    $out = Run { & swift test 2>&1 }
    $out | Select-String -Pattern 'error:|failed \(|Executed \d+ tests' | Select-Object -Last 6 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE) { Fail 'swift test failed' }
}

# ---- helpers ---------------------------------------------------------------------------------------------------------
function Get-Dependencies($file) {
    $lines = Run { & $Dumpbin /nologo /dependents $file }
    $deps = @()
    $inList = $false
    foreach ($l in $lines) {
        if ($l -match 'has the following (delay load )?dependencies') { $inList = $true; continue }
        if ($inList -and $l -match '^\s+(\S+\.(dll|DLL))\s*$') { $deps += $Matches[1]; continue }
        if ($inList -and $l -match '^\s*Summary') { $inList = $false }
    }
    return $deps
}

function Is-WindowsDll($name) {
    $n = $name.ToLower()
    if ($n.StartsWith('api-ms-win-') -or $n.StartsWith('ext-ms-win-')) { return $true }
    return Test-Path (Join-Path "$env:SystemRoot\System32" $name)
}

$Triples = @{ x64 = 'x86_64-unknown-windows-msvc'; arm64 = 'aarch64-unknown-windows-msvc' }
$MsmArch = @{ x64 = 'amd64'; arm64 = 'arm64' }
$CleanPath = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem"
$readme = Get-Content -Raw "$Win\README-dist.txt"
$licence = Get-Content -Raw (Join-Path $Root 'LICENSE')
$summary = @()

foreach ($a in $Arch) {
    $t = $Triples[$a]
    Step "Building $a ($t, release)"
    Run { & swift build -c release --triple $t --product ImageCratPreview -Xlinker (Join-Path $Build 'res\ImageCratPreview.res') 2>&1 }
    if ($LASTEXITCODE) { Fail "build of ImageCratPreview ($a) failed" }
    Run { & swift build -c release --triple $t --product imagecrat-cli -Xlinker (Join-Path $Build 'res\ImageCratCLI.res') 2>&1 }
    if ($LASTEXITCODE) { Fail "build of imagecrat-cli ($a) failed" }
    $bin = Join-Path $Root ".build\$t\release"

    # runtime DLLs: Swift (from the toolchain's merge module) and MSVC (from the Build Tools' redistributable folder)
    $pool = Join-Path $Build "runtime-$a"
    if (-not (Test-Path "$pool\swiftCore.dll")) {
        Step "Extracting the $a Swift runtime from rtl.$($MsmArch[$a]).msm"
        & "$Win\extract-msm.ps1" -Msm "$SwiftRoot\Redistributables\$SwiftVer\rtl.$($MsmArch[$a]).msm" -OutDir $pool
        if (-not (Test-Path "$pool\swiftCore.dll")) { Fail "runtime extraction failed for $a" }
    }
    $crt = Get-ChildItem "$Redist\$a" -Directory -Filter 'Microsoft.VC*.CRT' | Select-Object -First 1
    if (-not $crt) { Fail "MSVC runtime for $a not found under $Redist" }
    $candidates = @{}
    Get-ChildItem $pool -Filter *.dll | ForEach-Object { $candidates[$_.Name.ToLower()] = $_.FullName }
    Get-ChildItem $crt.FullName -Filter *.dll | ForEach-Object { $candidates[$_.Name.ToLower()] = $_.FullName }

    # stage: executables + the DLLs they need (transitively), found with dumpbin
    $stage = Join-Path $Build "stage-$a"
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $stage | Out-Null
    Copy-Item "$bin\ImageCratPreview.exe", "$bin\imagecrat-cli.exe" $stage
    Copy-Item "$Win\ImageCrat.ico" $stage
    WriteText (Join-Path $stage 'README.txt') (Crlf ($readme.Replace('@VERSION@', $Version).Replace('@ARCH@', $a).Replace('@BUILDDATE@', $BuildDate)))
    WriteText (Join-Path $stage 'LICENSE.txt') (Crlf $licence)
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue((Join-Path $stage 'ImageCratPreview.exe'))
    $queue.Enqueue((Join-Path $stage 'imagecrat-cli.exe'))
    $seen = @{}
    $report = @("Dependencies of the $a build (dumpbin /dependents), $BuildDate", '')
    while ($queue.Count -gt 0) {
        $f = $queue.Dequeue()
        $deps = Get-Dependencies $f
        $report += (Split-Path -Leaf $f) + ':'
        foreach ($d in $deps) {
            $k = $d.ToLower()
            $where = if ($candidates.ContainsKey($k)) { 'bundled' } elseif (Is-WindowsDll $d) { 'Windows' } else { 'MISSING' }
            $report += "    $d  ($where)"
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            if ($where -eq 'bundled') {
                Copy-Item $candidates[$k] $stage
                $queue.Enqueue((Join-Path $stage (Split-Path -Leaf $candidates[$k])))
            } elseif ($where -eq 'MISSING') {
                Fail "$f needs $d, which is neither shipped nor part of Windows"
            }
        }
    }
    # nothing may point into the toolchain or the Build Tools
    $toolchain = Get-ChildItem $stage -Include *.exe, *.dll -Recurse | Where-Object { (Select-String -Path $_.FullName -Pattern 'Programs\\Swift\\(Toolchains|Runtimes)' -SimpleMatch:$false -Quiet) }
    $report += ''
    $report += "Files that mention the toolchain folders: $(if ($toolchain) { ($toolchain | ForEach-Object Name) -join ', ' } else { 'none' })"
    WriteText (Join-Path $Dist "dependencies-$a.txt") (Crlf ($report -join "`n"))
    $files = Get-ChildItem $stage
    Step ("Staged {0} files, {1:N1} MB: {2}" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB), (($files | Where-Object Extension -eq '.dll' | ForEach-Object Name) -join ' '))

    # checks with PATH reduced to Windows' own folders, so nothing can come from the toolchain
    if (-not $SkipTests) {
        Step "Self-check ($a, clean PATH)"
        $env:IC_STAGE = $stage
        $out = Run { & cmd /c "set `"PATH=$CleanPath`" && `"%IC_STAGE%\imagecrat-cli.exe`" selfcheck 2>nul" }
        $code = $LASTEXITCODE
        WriteText (Join-Path $Dist "selfcheck-$a.txt") (Crlf ($out -join "`n"))
        $out | Select-Object -First 4 | ForEach-Object { Write-Host "    $_" }
        if ($code -ne 0) { Fail "self-check failed for $a (exit $code)" }
        Step "GUI smoke test ($a)"
        $sample = Join-Path $Build "smoke-$a.psd"
        Run { & cmd /c "set `"PATH=$CleanPath`" && `"%IC_STAGE%\imagecrat-cli.exe`" make-samples `"$Build\samples-$a`" >nul" }
        Copy-Item "$Build\samples-$a\Synthetic layered 8-bit.psd" $sample -Force
        $png = Join-Path $Build "smoke-$a.png"
        Remove-Item $png -ErrorAction SilentlyContinue
        # `start /wait` waits for the GUI program and passes its exit code on
        Run { & cmd /c "set `"PATH=$CleanPath`" && start `"`" /wait `"%IC_STAGE%\ImageCratPreview.exe`" --snapshot `"$png`" `"$sample`" --select 0" }
        $code = $LASTEXITCODE
        if ($code -ne 0 -or -not (Test-Path $png)) { Fail "GUI smoke test failed for $a (exit $code)" }
        Copy-Item $png (Join-Path $Dist "smoke-$a.png") -Force
    }

    # portable zip
    $zip = Join-Path $Dist "ImageCratPreview-$Version-$a-portable.zip"
    Remove-Item $zip -ErrorAction SilentlyContinue
    $zipDir = Join-Path $Build "zip-$a\ImageCrat Preview $Version ($a)"
    Remove-Item -Recurse -Force (Join-Path $Build "zip-$a") -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $zipDir | Out-Null
    Copy-Item "$stage\*" $zipDir
    Compress-Archive -Path $zipDir -DestinationPath $zip -CompressionLevel Optimal
    Step "Portable zip: $zip"

    # installer
    if (-not $SkipInstaller) {
        Step "Installer ($a)"
        Run { & $ISCC /Q "/DArch=$a" "/DAppVersion=$Version" "/DSourceDir=$stage" "/DOutputDir=$Dist" "$Win\ImageCratPreview.iss" 2>&1 }
        if ($LASTEXITCODE) { Fail "Inno Setup failed for $a" }
    }
    $summary += $a
}

# checksums
$sums = Get-ChildItem $Dist -File | Where-Object { $_.Extension -in '.exe', '.zip' } | ForEach-Object { "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name }
WriteText (Join-Path $Dist 'SHA256SUMS.txt') (($sums -join "`n") + "`n")
Step "Done ($($summary -join ', ')):"
Get-ChildItem $Dist -File | ForEach-Object { Write-Host ("    {0,-50} {1,10:N0} bytes" -f $_.Name, $_.Length) }
