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
; 升级安装也强制显示「选择目标位置」页（不隐藏），但把目录框置灰、并给出提示
DisableDirPage=no
UsePreviousAppDir=yes
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
var
  KeepUserData: Boolean;

{ ---------- 判断这次是不是「覆盖升级」 ---------- }
function IsUpgradeInstall(): Boolean;
var
  S: String;
  UninstKey: String;
begin
  Result := False;
  UninstKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{4C7A5E9B-8F2D-4A36-9C51-2B7E0D6F1A44}_is1';

  { Inno 自己记下的旧版本安装目录；首次安装时为空 }
  if WizardForm.PrevAppDir <> '' then
  begin
    Result := True;
    exit;
  end;

  { 兜底：万一旧版本记录没被 Inno 认出来，直接查卸载注册表 }
  if RegQueryStringValue(HKEY_CURRENT_USER, UninstKey, 'InstallLocation', S) and (S <> '') then
    Result := True;
  if (not Result) and
     RegQueryStringValue(HKEY_LOCAL_MACHINE, UninstKey, 'InstallLocation', S) and (S <> '') then
    Result := True;
end;

{ ---------- 升级安装：目录页可见但不可改，并加一行灰色小字 ---------- }
procedure InitializeWizard();
var
  Hint: TLabel;
begin
  if IsUpgradeInstall() then
  begin
    if WizardForm.PrevAppDir <> '' then
      WizardForm.DirEdit.Text := WizardForm.PrevAppDir;
    WizardForm.DirEdit.Enabled := False;
    WizardForm.DirBrowseButton.Enabled := False;
    { 系统默认的「想换目录请点浏览」在升级时会误导，改成说明文字 }
    WizardForm.SelectDirBrowseLabel.Caption := '检测到已安装版本，升级时沿用原目录、不可更改。';

    Hint := TLabel.Create(WizardForm);
    Hint.Parent := WizardForm.SelectDirPage;
    Hint.Left := WizardForm.DirEdit.Left;
    Hint.Top := WizardForm.DirEdit.Top + WizardForm.DirEdit.Height + ScaleY(14);
    Hint.Width := WizardForm.SelectDirPage.Width - Hint.Left - ScaleX(24);
    Hint.Height := ScaleY(40);
    Hint.AutoSize := False;
    Hint.WordWrap := True;
    Hint.Transparent := True;
    Hint.Font.Color := $00808080;
    Hint.Caption := '若要重新选择安装目录，请卸载原版本后重新安装。';
  end;
end;

{ ---------- 卸载：弹出可选勾的「保留用户数据」 ---------- }
function InitializeUninstall(): Boolean;
var
  Form: TSetupForm;
  Info: TLabel;
  Check: TNewCheckBox;
  BtnOK, BtnCancel: TNewButton;
begin
  Result := True;
  KeepUserData := True;              { 默认保留，最安全 }
  if UninstallSilent then exit;      { 静默卸载不弹窗，按「保留」处理 }

  Form := CreateCustomForm(440, 186, False, False);
  Form.Caption := '{#AppName} 卸载选项';

  Info := TLabel.Create(Form);
  Info.Parent := Form;
  Info.Left := ScaleX(18);
  Info.Top := ScaleY(18);
  Info.Width := Form.ClientWidth - ScaleX(36);
  Info.Height := ScaleY(58);
  Info.AutoSize := False;
  Info.WordWrap := True;
  Info.Caption := '卸载 {#AppName} 时，可以选择是否保留你的个人数据。' + #13#10 +
                  '个人数据包括：同步任务配置、已绑定的硬盘信息、运行日志与状态；' +
                  '保留后重新安装，设置可以接着用。';

  Check := TNewCheckBox.Create(Form);
  Check.Parent := Form;
  Check.Left := ScaleX(18);
  Check.Top := ScaleY(92);
  Check.Width := Form.ClientWidth - ScaleX(36);
  Check.Checked := True;
  Check.Caption := '保留用户数据（推荐，卸载后重装可继续用）';

  BtnOK := TNewButton.Create(Form);
  BtnOK.Parent := Form;
  BtnOK.Left := Form.ClientWidth - ScaleX(192);
  BtnOK.Top := ScaleY(138);
  BtnOK.Width := ScaleX(86);
  BtnOK.Height := ScaleY(30);
  BtnOK.Caption := '继续卸载';
  BtnOK.ModalResult := mrOK;

  BtnCancel := TNewButton.Create(Form);
  BtnCancel.Parent := Form;
  BtnCancel.Left := Form.ClientWidth - ScaleX(98);
  BtnCancel.Top := ScaleY(138);
  BtnCancel.Width := ScaleX(80);
  BtnCancel.Height := ScaleY(30);
  BtnCancel.Caption := '取消';
  BtnCancel.ModalResult := mrCancel;

  if Form.ShowModal() = mrOK then
  begin
    KeepUserData := Check.Checked;
    Result := True;
  end
  else
    Result := False;                { 用户点「取消」，整个卸载中止 }
  Form.Free();
end;

{ ---------- 不勾选保留时，卸载完成后把数据清干净 ---------- }
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  A: String;
begin
  if (CurUninstallStep = usPostUninstall) and (not KeepUserData) then
  begin
    A := ExpandConstant('{app}');
    DeleteFile(A + '\config.json');
    DeleteFile(A + '\hardware.json');
    DeleteFile(A + '\console.json');
    DeleteFile(A + '\state.json');
    DelTree(A + '\logs', True, True, True);
    DelTree(A + '\_ipc', True, True, True);
    DelTree(A + '\_SyncHistory', True, True, True);
  end;
end;

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
