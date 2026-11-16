; Windows installer for FreeNotes. Build it with: powershell -File tool\build_installer.ps1
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{8C2E5B7A-3F1D-4E6A-9B2C-5D7E8F9A0B1C}
AppName=FreeNotes
AppVersion={#AppVersion}
AppPublisher=FreeNotes
DefaultDirName={localappdata}\Programs\FreeNotes
DisableProgramGroupPage=yes
; Installs for the current user only: no admin rights needed
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=FreeNotes-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\freenotes.exe
UninstallDisplayName=FreeNotes
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\FreeNotes"; Filename: "{app}\freenotes.exe"
Name: "{autodesktop}\FreeNotes"; Filename: "{app}\freenotes.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\freenotes.exe"; Description: "{cm:LaunchProgram,FreeNotes}"; Flags: nowait postinstall skipifsilent

; Notes live in Documents\FreeNotes and are never touched by install or uninstall.
