#define AppName "NeonAmp"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppPublisher "NeonAmp"
#define AppExeName "neonamp.exe"

[Setup]
AppId={{B8D8A4D1-6ED3-4E9B-BE08-NEONAMP0001}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\NeonAmp
DefaultGroupName=NeonAmp
OutputDir=..\release
OutputBaseFilename=NeonAmp-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\{#AppExeName}
WizardStyle=modern

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autodesktop}\NeonAmp"; Filename: "{app}\{#AppExeName}"
Name: "{group}\NeonAmp"; Filename: "{app}\{#AppExeName}"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch NeonAmp"; Flags: nowait postinstall skipifsilent
