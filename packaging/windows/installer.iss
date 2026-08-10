#define MyAppName "Ozon Profit Agent"
#define MyAppVersion "0.6.0"
#define MyAppExeName "ozon_profit_flutter.exe"

[Setup]
AppId={{E75D57B3-12BE-47E8-A3C9-06C484BDF848}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\OzonProfitAgent
DefaultGroupName={#MyAppName}
OutputBaseFilename=OzonProfitAgent-Setup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no

[InstallDelete]
Type: filesandordirs; Name: "{app}\backend"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs
Source: "..\..\..\packaged_backend\*"; DestDir: "{app}\backend"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'), '/C taskkill /F /IM ozon_profit_flutter.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := '';
end;
