; AnyPS5 Desktop installer (Inno Setup 6).
;
; Built by build-installer.ps1, which passes the version and the Flutter release folder:
;     ISCC.exe /DAppVersion=0.1.13 /DSourceDir=..\..\build\windows\x64\runner\Release AnyPS5-Desktop.iss
;
; Installs for the current user by default (%LOCALAPPDATA%\Programs\AnyPS5 Desktop, no
; administrator rights); the first page offers an install for all users instead.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\installer"
#endif

#define AppName "AnyPS5 Desktop"
#define AppExe "anyps5_desktop.exe"

[Setup]
; The AppId identifies the installation for upgrades and the uninstaller: never change it.
AppId={{6A1F3C2E-5B7D-4E8A-9C41-2D0B7F5E9A13}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Utku Halis
AppPublisherURL=https://github.com/AnyTogether/AnyLauncher-Port
AppSupportURL=https://github.com/AnyTogether/AnyLauncher-Port/issues
AppUpdatesURL=https://github.com/AnyTogether/AnyLauncher-Port/releases
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
LicenseFile=..\..\LICENSE
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
OutputDir={#OutputDir}
OutputBaseFilename=AnyPS5-Desktop-Setup-{#AppVersion}-x64
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; A running launcher holds its files open: it is closed (Restart Manager, then the code
; below) before files are replaced or removed.
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Files of an older version that the new one no longer ships.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
; The launcher's own update (Restart Now, or Later at the next launch) runs this installer with
; /VERYSILENT /relaunch=1: the launcher opens again on the new version.
Filename: "{app}\{#AppExe}"; Flags: nowait runasoriginaluser; Check: WizardSilent and RelaunchAsked

[Code]
// Ends a running launcher: asked to close first, then ended if it is still there.
procedure CloseLauncher();
var
  Code: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM {#AppExe}', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Sleep(1500);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#AppExe}', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

// The launcher asked to be opened again after a silent update.
function RelaunchAsked(): Boolean;
begin
  Result := ExpandConstant('{param:relaunch|0}') = '1';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  CloseLauncher();
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  CloseLauncher();
  Result := True;
end;
