; Bakushi one-click installer (Inno Setup 6).
; Build:  iscc tools\installer.iss   ->  dist\BakushiSetup.exe
; Bundles: the app, sidecar, starter kit, licenses, README, the HTDemucs
; model, and the official python.org installer + a post-install script.

#define MyAppName "Bakushi"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Bakushi contributors"
#define MyAppExeName "bakushi.exe"

[Setup]
AppId={{7B4E1A9C-3D6F-4A28-B5C7-9E1D0F2A8B36}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\Bakushi
DefaultGroupName=Bakushi
OutputDir=..\dist
OutputBaseFilename=BakushiSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
DisableWelcomePage=yes
LicenseFile=..\LICENSE
SetupLogging=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; \
    GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\bakushi.exe"; \
    DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\flutter_windows.dll"; \
    DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\bakushi_engine.dll"; \
    DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\dartjni.dll"; \
    DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\desktop_drop_plugin.dll"; \
    DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\file_selector_windows_plugin.dll"; \
    DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\native_assets.json"; \
    DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\data\*"; \
    DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs
Source: "..\sidecar\bakushi_sidecar.py"; DestDir: "{app}\sidecar"; \
    Flags: ignoreversion
Source: "..\sidecar\beat_analysis.py"; DestDir: "{app}\sidecar"; \
    Flags: ignoreversion
Source: "..\sidecar\drum_punch.py"; DestDir: "{app}\sidecar"; \
    Flags: ignoreversion
Source: "..\sidecar\requirements.txt"; DestDir: "{app}\sidecar"; \
    Flags: ignoreversion
Source: "..\assets\starter_kit\*.wav"; DestDir: "{app}\assets\starter_kit"; \
    Flags: ignoreversion
Source: "..\assets\licenses\*"; DestDir: "{app}\assets\licenses"; \
    Flags: ignoreversion
Source: "..\assets\models\htdemucs_fp16weights.onnx"; \
    DestDir: "{app}\assets\models"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\tools\redist\python-3.11.9-amd64.exe"; DestDir: "{app}\redist"; \
    Flags: ignoreversion
Source: "..\tools\redist\vc_redist.x64.exe"; DestDir: "{app}\redist"; \
    Flags: ignoreversion
Source: "..\tools\setup_postinstall.ps1"; DestDir: "{app}\tools"; \
    Flags: ignoreversion

[Icons]
Name: "{group}\Bakushi"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall Bakushi"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Bakushi"; Filename: "{app}\{#MyAppExeName}"; \
    Tasks: desktopicon

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Cmd: String;
  Params: String;
  ErrText: String;
begin
  if CurStep = ssPostInstall then begin
    // VC++ 2015-2022 x64 runtime FIRST. Silent; needs elevation, so a
    // non-zero exit on a per-user install is a WARNING (modern Windows
    // already ships the runtime) - it must never fail the install.
    if Exec(ExpandConstant('{app}') + '\redist\vc_redist.x64.exe', \
        '/install /quiet /norestart', '', SW_HIDE, \
        ewWaitUntilTerminated, ResultCode) then begin
      Log('vc_redist exit code: ' + IntToStr(ResultCode));
    end else begin
      Log('vc_redist could not be started.');
    end;
    // Python + pip + sidecar selftest + settings pre-write. A failure
    // here DOES fail the install with a clear message.
    Cmd := 'powershell.exe';
    Params := '-NoProfile -ExecutionPolicy Bypass -File "' + \
      ExpandConstant('{app}') + '\tools\setup_postinstall.ps1"' + \
      ' -AppDir "' + ExpandConstant('{app}') + '"';
    if not Exec(Cmd, Params, '', SW_HIDE, ewWaitUntilTerminated, \
        ResultCode) then begin
      MsgBox('Bakushi setup failed: the post-install step could not ' + \
        'be started.', mbError, MB_OK);
      Abort;
    end;
    if ResultCode <> 0 then begin
      ErrText := 'Bakushi setup failed: Python / sidecar setup failed ' + \
        '(code ' + IntToStr(ResultCode) + ').' + #13#10 + #13#10 + \
        'Run this manually for details:' + #13#10 + \
        '  powershell -ExecutionPolicy Bypass -File "' + \
        ExpandConstant('{app}') + '\tools\setup_postinstall.ps1" ' + \
        '-AppDir "' + ExpandConstant('{app}') + '"';
      MsgBox(ErrText, mbError, MB_OK);
      Abort;
    end;
  end;
end;
