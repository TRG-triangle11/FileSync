; FileSync 安装包脚本（Inno Setup 7）
; 由 打包-安装包.ps1 调用，版本号与停进程指令通过 /D 参数注入
#define AppName "FileSync"
#ifndef AppVer
#define AppVer "0.0.0"
#endif
#ifndef StopB64
#define StopB64 ""
#endif
#ifndef Root
#define Root ".."
#endif

[Setup]
AppId={{4C7A5E9B-8F2D-4A36-9C51-2B7E0D6F1A44}
AppName={#AppName}
AppVersion={#AppVer}
AppVerName={#AppName} v{#AppVer}
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
OutputDir={#Root}\dist
OutputBaseFilename=FileSync-Setup-64bit-v{#AppVer}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\FileSync.ico
CloseApplications=no

[Files]
Source: "{#Root}\build\pkg\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Languages]
Name: "chs"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式（FileSync）"; GroupDescription: "附加任务："
Name: "startmenuicon"; Description: "创建开始菜单快捷方式（FileSync）"; GroupDescription: "附加任务："

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\启动-后台.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\FileSync.ico"; Comment: "FileSync 多目标自动同步控制台"; Tasks: startmenuicon
Name: "{autodesktop}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\启动-后台.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\FileSync.ico"; Comment: "FileSync 多目标自动同步控制台"; Tasks: desktopicon

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\启动-后台.vbs"""; WorkingDir: "{app}"; Description: "启动 FileSync（后台运行，浏览器自动打开控制台）"; Flags: nowait postinstall skipifsilent
Filename: "{app}\README.md"; Description: "查看使用说明（README）"; Flags: postinstall shellexec skipifsilent unchecked

; 卸载时先把还在跑的服务和监听停掉（避免文件占用删不干净）
[UninstallRun]
Filename: "{sys}\cmd.exe"; Parameters: "/C powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand {#StopB64}"; Flags: runhidden waituntilterminated

; 开机自启的快捷方式不在安装包管理范围内，卸载时一并清掉
[UninstallDelete]
Type: files; Name: "{userstartup}\FileSync.lnk"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  R: Integer;
begin
  // 安装 / 升级前先停掉正在运行的 FileSync（服务 + 监听），避免文件占用
  Exec(ExpandConstant('{sys}\cmd.exe'),
    '/C powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand {#StopB64}',
    '', SW_HIDE, ewWaitUntilTerminated, R);
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  cfg: String;
begin
  if CurStep = ssPostInstall then
  begin
    // 只有首次安装才放默认配置；升级时保留用户改过的 config.json
    cfg := ExpandConstant('{app}\config.json');
    if not FileExists(cfg) then
      CopyFile(ExpandConstant('{app}\config.default.json'), cfg, False);
  end;
end;
