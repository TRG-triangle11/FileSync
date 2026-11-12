#Requires -Version 5.1
<#
    打包-安装包.ps1  -  把 FileSync 打成 Win64 安装程序（Inno Setup）

    用法：
      powershell -File 打包-安装包.ps1              # 用 version.txt 里的版本号
      powershell -File 打包-安装包.ps1 -Version 1.0.1   # 指定版本号

    产出：dist\FileSync-Setup-64bit-v<版本>.exe
      · 可选安装目录（默认 %LOCALAPPDATA%\Programs\FileSync，用户级、不需要管理员）
      · 升级：直接运行新版本安装包，装到同一个目录即覆盖更新，用户配置不受影响
      · 升级：向导会显示当前安装目录（置灰不可改），并提示要换目录需先卸载重装
      · 卸载：控制面板 / 设置里正常卸载，弹窗可选是否保留用户数据（默认保留）
      · 用户数据（config.json / hardware.json / logs / _ipc）不进安装包；卸载时可勾选保留或清除
#>
$ErrorActionPreference = 'Stop'
$root    = $PSScriptRoot                                  # installer\：iss / tools / version / dist 都在这里
$appDir  = Join-Path (Split-Path -Parent $root) 'src'     # src\：程序本体
$readme  = Join-Path (Split-Path -Parent $root) 'README.md'

# 0) 版本号
if (-not $Version) {
    $Version = (Get-Content -LiteralPath (Join-Path $root 'version.txt') -Raw).Trim()
}
if (-not $Version -match '^\d+\.\d+\.\d+$') {
    Write-Host ('  [错误] 版本号不合法：' + $Version + '（应为 1.2.3 格式）') -ForegroundColor Red
    exit 1
}

# 1) 暂存打包内容 —— 只放程序本体，用户数据不进包
$stage = Join-Path $root 'build\pkg'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$appFiles = @(
    'Serve-Console.ps1', 'Sync-Now.ps1', 'SyncCore.ps1', 'SyncUI.ps1', 'Watch-FileSync.ps1',
    '启动控制台.cmd', '启动-后台.vbs',
    'FileSync.ico'
)
foreach ($f in $appFiles) {
    $src = Join-Path $appDir $f
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Host ('  [错误] 缺少文件：' + $f) -ForegroundColor Red
        exit 1
    }
    Copy-Item -LiteralPath $src $stage -Force
}
if (-not (Test-Path -LiteralPath $readme)) {
    Write-Host '  [错误] 缺少文件：README.md' -ForegroundColor Red
    exit 1
}
Copy-Item -LiteralPath $readme $stage -Force
Copy-Item -LiteralPath (Join-Path $appDir 'console') (Join-Path $stage 'console') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $root 'config.default.json') $stage -Force

# 2) 「停掉 FileSync 进程」的指令，编码成 -EncodedCommand 传给安装/卸载流程
#    （写成 base64 是为了避开 Inno Pascal 字符串里引号转义的坑）
$stopLines = @(
    'Get-CimInstance Win32_Process -Filter "Name like ''powershell%''" |',
    'Where-Object { $_.CommandLine -and $_.CommandLine -match ''(DiskSync|FileSync)\\(Serve-Console|Watch-(DiskSync|FileSync)|Sync-Now)\.ps1'' -and $_.CommandLine -notmatch ''NonInteractive'' } |',
    'ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }'
)
$stopPs = $stopLines -join ' '
$stopB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($stopPs))

# 3) iss 需要 UTF-8 BOM（Inno 的 Unicode 模式靠 BOM 识别编码）
$issPath = Join-Path $root 'FileSync.iss'
$issBytes = [System.IO.File]::ReadAllBytes($issPath)
if (-not ($issBytes.Length -ge 3 -and $issBytes[0] -eq 239 -and $issBytes[1] -eq 187 -and $issBytes[2] -eq 191)) {
    $issText = [System.Text.Encoding]::UTF8.GetString($issBytes)
    [System.IO.File]::WriteAllText($issPath, $issText, (New-Object System.Text.UTF8Encoding($true)))
}

# 4) 编译安装包
$iscc = Join-Path $root 'tools\InnoSetup\ISCC.exe'
if (-not (Test-Path -LiteralPath $iscc)) {
    Write-Host '  [错误] 找不到 tools\InnoSetup\ISCC.exe（Inno Setup 便携版）。' -ForegroundColor Red
    Write-Host '  下载 innosetup-*.exe 后执行：' -ForegroundColor Gray
    Write-Host ('    innosetup.exe /VERYSILENT /PORTABLE=1 /DIR="' + (Join-Path $root 'tools\InnoSetup') + '"') -ForegroundColor Gray
    exit 1
}
New-Item -ItemType Directory -Force -Path (Join-Path $root 'dist') | Out-Null
& $iscc "/DAppVer=$Version" "/DStopB64=$stopB64" "/DRoot=$root" $issPath
if ($LASTEXITCODE -ne 0) {
    Write-Host '  [错误] ISCC 编译失败。' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host ('  安装包已生成：dist\FileSync-Setup-64bit-v' + $Version + '.exe') -ForegroundColor Green
Write-Host '  · 可选安装目录（默认 %LOCALAPPDATA%\Programs\FileSync，用户级免管理员）' -ForegroundColor Gray
Write-Host '  · 升级 = 显示并锁定原安装目录，附「换目录需先卸载」提示' -ForegroundColor Gray
Write-Host '  · 卸载 = 系统控制面板正常卸载，可选保留用户数据（默认保留）' -ForegroundColor Gray
