#Requires -Version 5.1
<#
    Sync-Now.ps1  -  手动执行一次同步

    用法：
      右键「使用 PowerShell 运行」，或命令行：
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Sync-Now.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Sync-Now.ps1 -DryRun

    参数：
      -DryRun    只比对不执行，报告将复制/删除的数量与体积（强烈建议首次先跑这个）
      -NoWindow  不弹进度窗口，改为控制台输出
      -Force     越过"变更幅度保护"。当你确实主动删除了大量文件、被保护机制拦下时使用
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoWindow,
    [switch]$Force
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

. (Join-Path $here 'SyncUI.ps1')
. (Join-Path $here 'SyncCore.ps1')

$exitCode = 0
try {
    $cfg = Get-SyncConfig
    if ($DryRun) {
        Write-Host ''
        Write-Host '>>> 预演模式：只比对，不修改任何文件' -ForegroundColor Cyan
        Write-Host ''
    }
    $r = Invoke-FileSyncRun -Config $cfg -NoWindow:$NoWindow -Force:$Force
    if (-not $r.Ok) { $exitCode = 1 }
    Write-Host ''
    Write-Host $r.Message
    foreach ($res in @($r.Results)) {
        if (-not $res.Ok) { Write-Host ('  [失败] {0} → {1}：{2}' -f $res.TaskName, $res.DestLabel, $res.Message) -ForegroundColor Yellow }
    }
    $lastLog = Get-ChildItem -LiteralPath (Join-Path $here 'logs') -Filter 'sync-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($lastLog) { Write-Host ('日志：' + $lastLog.FullName) -ForegroundColor DarkGray }
}
catch {
    Write-Host ('执行出错：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    $exitCode = 2
}

exit $exitCode
