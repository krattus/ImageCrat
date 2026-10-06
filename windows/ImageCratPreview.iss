; Inno Setup 6 script for ImageCrat Preview (technical preview for Windows).
; windows/build.ps1 compiles it once per architecture:
;   ISCC.exe /DArch=x64 /DAppVersion=0.1.0 /DSourceDir=<staged files> /DOutputDir=<dist> windows\ImageCratPreview.iss
; The staged folder holds the two executables, the Swift and MSVC runtime DLLs, the icon, LICENSE.txt and README.txt.

#ifndef Arch
  #define Arch "x64"
#endif
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "build\stage-" + Arch
#endif
#ifndef OutputDir
  #define OutputDir "..\dist\windows"
#endif

[Setup]
; one AppId for both architectures: installing one replaces the other
AppId={{6A0C8E54-2B7F-4D1E-9F3A-8C5B71D2E4A9}
AppName=ImageCrat Preview
AppVersion={#AppVersion}
AppVerName=ImageCrat Preview {#AppVersion} (technical preview, {#Arch})
AppPublisher=krattus
AppPublisherURL=https://github.com/krattus/ImageCrat
AppSupportURL=https://github.com/krattus/ImageCrat/issues
AppUpdatesURL=https://github.com/krattus/ImageCrat
AppCopyright=Copyright 2026 krattus
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName=ImageCrat Preview
VersionInfoDescription=ImageCrat Preview {#Arch} setup
DefaultDirName={autopf}\ImageCrat Preview
DefaultGroupName=ImageCrat Preview
DisableProgramGroupPage=yes
LicenseFile={#SourceDir}\LICENSE.txt
InfoAfterFile={#SourceDir}\README.txt
OutputDir={#OutputDir}
OutputBaseFilename=ImageCratPreview-Setup-{#Arch}
SetupIconFile=ImageCrat.ico
UninstallDisplayIcon={app}\ImageCratPreview.exe
UninstallDisplayName=ImageCrat Preview (technical preview)
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ChangesAssociations=yes
MinVersion=10.0.17763
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "assocpsd"; Description: "Offer ImageCrat Preview for .psd and .psb files (adds it to ""Open with""; your default app is not changed)"; GroupDescription: "File types:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\ImageCrat Preview"; Filename: "{app}\ImageCratPreview.exe"; Comment: "View Photoshop documents, PNGs and brush files"
Name: "{autoprograms}\ImageCrat command line"; Filename: "{cmd}"; Parameters: "/k imagecrat-cli.exe --help"; WorkingDir: "{app}"; Comment: "imagecrat-cli (selfcheck, info, composite, brushes)"
Name: "{autodesktop}\ImageCrat Preview"; Filename: "{app}\ImageCratPreview.exe"; Tasks: desktopicon

[Registry]
; opt-in "Open with" entries (task assocpsd): a ProgID plus OpenWithProgids; the user's default app stays as it is
Root: HKA; Subkey: "Software\Classes\ImageCrat.Preview.psd"; ValueType: string; ValueData: "Photoshop document"; Flags: uninsdeletekey; Tasks: assocpsd
Root: HKA; Subkey: "Software\Classes\ImageCrat.Preview.psd\DefaultIcon"; ValueType: string; ValueData: "{app}\ImageCratPreview.exe,0"; Tasks: assocpsd
Root: HKA; Subkey: "Software\Classes\ImageCrat.Preview.psd\shell\open\command"; ValueType: string; ValueData: """{app}\ImageCratPreview.exe"" ""%1"""; Tasks: assocpsd
Root: HKA; Subkey: "Software\Classes\.psd\OpenWithProgids"; ValueType: string; ValueName: "ImageCrat.Preview.psd"; ValueData: ""; Flags: uninsdeletevalue; Tasks: assocpsd
Root: HKA; Subkey: "Software\Classes\.psb\OpenWithProgids"; ValueType: string; ValueName: "ImageCrat.Preview.psd"; ValueData: ""; Flags: uninsdeletevalue; Tasks: assocpsd
Root: HKA; Subkey: "Software\Classes\Applications\ImageCratPreview.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "ImageCrat Preview"; Flags: uninsdeletekey; Tasks: assocpsd
Root: HKA; Subkey: "Software\Classes\Applications\ImageCratPreview.exe\SupportedTypes"; ValueType: string; ValueName: ".psd"; ValueData: ""; Tasks: assocpsd
Root: HKA; Subkey: "Software\Classes\Applications\ImageCratPreview.exe\SupportedTypes"; ValueType: string; ValueName: ".psb"; ValueData: ""; Tasks: assocpsd

[Run]
Filename: "{app}\ImageCratPreview.exe"; Description: "{cm:LaunchProgram,ImageCrat Preview}"; Flags: nowait postinstall skipifsilent
