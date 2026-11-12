#Requires -Version 5.1
<#
    Watch-FileSync.ps1  -  常驻监听：插入指定移动硬盘时自动同步

    本脚本通常由 Serve-Console.ps1 拉起（隐藏窗口），也可以单独运行调试。

    用法：
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Watch-FileSync.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Watch-FileSync.ps1 -Once    # 只检查一次
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Watch-FileSync.ps1 -Headless # 不建桌面窗口

    两个通道：
      1. 桌面迷你条（SyncUI.ps1，WPF）—— 浏览器没开的时候也能看到进度、收到托盘通知
      2. _ipc\status.json —— 本地 Web 控制台读这个文件显示状态
    网页上的按钮 → Web 服务写 _ipc\cmd\*.json → 本脚本在主循环里消费。

    识别规则：
      只有 hardware.json 里绑定的那块盘才会触发同步。
      插入 U 盘、其他移动硬盘、手机、相机等一律忽略，不会有任何提示或磁盘操作。
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$NoWindow,
    [switch]$Headless,
    [int]$PollSeconds = 5
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

. (Join-Path $here 'SyncUI.ps1')
. (Join-Path $here 'SyncCore.ps1')

# ---------- 轻量检测：目的地是否在线 ----------
# 多任务版：不再只认 hardware.json 里那一块盘，而是看所有「硬盘目的地」的序列号

# 当前机器上全部在线序列号（磁盘 + 物理盘 + 卷）
function Get-AllSerials {
    $set = @{}
    foreach ($d in (Get-Disk -ErrorAction SilentlyContinue)) {
        $s = ([string]$d.SerialNumber).Trim().ToUpper(); if ($s) { $set[$s] = $true }
    }
    foreach ($p in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $s = ([string]$p.SerialNumber).Trim().ToUpper(); if ($s) { $set[$s] = $true }
    }
    foreach ($v in (Get-Volume -ErrorAction SilentlyContinue)) {
        if (-not $v.DriveLetter) { continue }
        $s = ([string]$v.SerialNumber).Trim().ToUpper(); if ($s) { $set[$s] = $true }
    }
    return $set
}

# 所有「硬盘目的地」的序列号 → PairId 映射
function Get-DestSerialMap {
    param($Pairs)
    $map = @{}
    foreach ($p in $Pairs) {
        if ($p.DestKind -ne 'disk' -or -not $p.Serials) { continue }
        foreach ($k in @('Disk', 'Phys', 'Volume')) {
            $prop = $p.Serials.PSObject.Properties[$k]
            if ($prop) {
                $v = ([string]$prop.Value).Trim().ToUpper()
                if ($v -and -not $map.ContainsKey($v)) { $map[$v] = $p.PairId }
            }
        }
    }
    return $map
}

Write-Host ''
Write-Host '========== FileSync 监听 ==========' -ForegroundColor Cyan

$script:Cfg           = $null
$script:ForceSync     = $false
$script:QuitRequested = $false
$script:Paused        = $false
$script:LastTickLog   = Get-Date

try { $script:Cfg = Get-SyncConfig } catch { Write-Host ('配置读取失败：' + $_.Exception.Message) -ForegroundColor Red; exit 1 }

$script:Interval = $PollSeconds
if ($script:Cfg.Options -and $script:Cfg.Options.WatchPollSeconds) { $script:Interval = [int]$script:Cfg.Options.WatchPollSeconds }
if ($script:Interval -lt 1) { $script:Interval = 5 }

# ---------- 界面 ----------
# 优先级：-Headless（服务模式，只写状态文件） > -NoWindow > 配置开关
$uiOn = -not $NoWindow -and -not $Headless
if ($uiOn -and $script:Cfg.Options -and $script:Cfg.Options.ShowProgressWindow -eq $false) { $uiOn = $false }

function Update-FooterText {
    if ($script:Paused) { return '监听已暂停 · 网页里可以恢复' }
    return ('监听中 · 每 {0} 秒检查一次' -f $script:Interval)
}

function Publish-BindInfo {
    # 多任务版：Bound = 至少存在一个目的地；BindName = 目的地标签串
    $pairs = Get-SyncPairs -Config $script:Cfg
    $labels = @($pairs | ForEach-Object { $_.DestLabel })
    $bound = ($labels.Count -gt 0)
    Set-UIRuntime -Key 'Bound'    -Value $bound
    Set-UIRuntime -Key 'BindName' -Value ($labels -join '、')
    Set-UIRuntime -Key 'Interval' -Value $script:Interval
    return $bound
}

function Initialize-WatchUI {
    Set-UIStatus -Connected $false -Footer (Update-FooterText)
    if (-not $uiOn) { return }

    # 监听模式：窗口常驻，叉掉只隐藏。这样不会出现"关了就重建"的鬼打墙
    $script:PersistentUI = $true
    if ($script:Cfg.Options -and $script:Cfg.Options.MiniBarMode) {
        Set-MiniBarMode ([string]$script:Cfg.Options.MiniBarMode)
    }

    if (-not (Test-UIAlive)) { [void](New-ProgressWindow -Title '监听中' -Compact) }
    if (-not $script:UIState.Syncing) {
        Update-ProgressUI -Title '监听中' -Detail '插上硬盘后会自动同步' -Hint '' -Percent 0 -State 'Idle'
    }
}

function Set-PausedState {
    param([bool]$Value)
    $script:Paused = $Value
    if ($Value) {
        Write-Log '界面：暂停了自动同步（插盘不再自动触发）' -Level INFO
    } else {
        Write-Log '界面：已恢复自动同步' -Level OK
    }
    Set-UIStatus -Footer (Update-FooterText)
    if ($Value) {
        Update-ProgressUI -Title '已暂停' -Detail '插盘不再自动同步' -Hint '在网页控制台里可以恢复' -Percent 0 -State 'Idle'
    } else {
        Update-ProgressUI -Title '监听中' -Detail '插上硬盘后会自动同步' -Hint '' -Percent 0 -State 'Idle'
    }
    Set-UIRuntime -Key 'Paused' -Value $Value
}

# 网页服务端口：由 Serve-Console.ps1 启动时写进 console.json，两边共用
$script:Port = 7788
try {
    $cp = Join-Path $here 'console.json'
    if (Test-Path -LiteralPath $cp) {
        $cj = (Get-Content -LiteralPath $cp -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($cj.Port) { $script:Port = [int]$cj.Port }
    }
} catch { }

function Test-ConsoleAlive {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $script:Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(300)
        $conn = $c.Connected
        $c.Close()
        return ($ok -and $conn)
    } catch { return $false }
}

# 网页控制台没起来时顺手把它拉起来，用户点「网页」不用先开服务
function Open-WebConsole {
    if (-not (Test-ConsoleAlive)) {
        try {
            $serve = Join-Path $here 'Serve-Console.ps1'
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $serve + '"'), '-NoBrowser'
            )
            for ($i = 0; $i -lt 40; $i++) {
                Start-Sleep -Milliseconds 250
                if (Test-ConsoleAlive) { break }
            }
        } catch { }
    }
    try { Start-Process ('http://127.0.0.1:{0}/' -f $script:Port) } catch { }
}

function Open-LogFolder {
    try {
        $d = Join-Path $here ([string]$script:Cfg.LogDir)
        if (-not (Test-Path -LiteralPath $d)) { $d = $here }
        Start-Process explorer.exe -ArgumentList ('"' + $d + '"')
    } catch { }
}

function Open-FolderPath {
    param([string]$Path)
    try { if ($Path -and (Test-Path -LiteralPath $Path)) { Start-Process explorer.exe -ArgumentList ('"' + $Path + '"') } } catch { }
}

function Get-FirstSourcePath {
    try {
        $pairs = Get-SyncPairs -Config $script:Cfg
        if ($pairs.Count -gt 0) { return $pairs[0].Source }
    } catch { }
    return ''
}

function Find-TargetFolderPath {
    # 打开第一个可访问的目的地（优先硬盘目的地，其次文件夹目的地）
    try {
        foreach ($p in (Get-SyncPairs -Config $script:Cfg)) {
            if ($p.DestKind -eq 'folder') {
                $d = Join-Path $p.FixedTargetRoot $p.Sub
                if (Test-Path -LiteralPath $d) { return $d }
            } else {
                foreach ($v in (Get-VolumeList)) {
                    $hit = $false
                    if ($p.Serials) {
                        foreach ($k in @('Disk', 'Phys', 'Volume')) {
                            $want = ([string]$p.Serials.PSObject.Properties[$k].Value).Trim().ToUpper()
                            if (-not $want) { continue }
                            $have = $(if ($k -eq 'Disk') { $v.DiskSerial } elseif ($k -eq 'Phys') { $v.PhysSerial } else { $v.VolumeSerial })
                            if ($have -and ([string]$have).Trim().ToUpper() -eq $want) { $hit = $true; break }
                        }
                    }
                    if ($hit) {
                        $d = Join-Path ($v.Letter + ':') $p.Sub
                        if (Test-Path -LiteralPath $d) { return $d }
                    }
                }
            }
        }
    } catch { }
    return ''
}

<#
    Invoke-Commands
    桌面迷你窗的按钮（UIActions 队列）和网页的按钮（_ipc\cmd\*.json）走同一套处理。
    所有动作都只改标记，真正干活留在主循环里 ——
    事件回调和循环里重入同步流程会死锁在同一个线程上。
#>
function Invoke-Commands {
    $names = New-Object System.Collections.ArrayList
    foreach ($a in (Get-UIAction)) { [void]$names.Add([string]$a) }
    foreach ($c in (Get-IPCCommand)) { if ($c.cmd) { [void]$names.Add([string]$c.cmd) } }

    foreach ($name in $names) {
        switch ($name) {
            'sync' {
                Write-Log '界面：点了「立即同步」' -Level INFO
                $script:ForceSync = $true
            }
            'stop' {
                Write-Log '界面：点了「停止同步」' -Level WARN
                $script:CancelRequested = $true
            }
            'pause' {
                Set-PausedState -Value $true
            }
            'resume' {
                Set-PausedState -Value $false
            }
            'togglepause' {
                Set-PausedState -Value (-not $script:Paused)
            }
            'syncnow' {
                # 忽略暂停与防抖，立刻同步
                $script:Paused = $false
                $script:ForceSync = $true
            }
            'web'        { Open-WebConsole }
            'showbar'    { if ($uiOn) { Show-Bar } }
            'showconsole'{ if ($uiOn) { Show-Bar -Console } }
            'logs'       { Open-LogFolder }
            'source'     { Open-FolderPath (Get-FirstSourcePath) }
            'target'     { Open-FolderPath (Find-TargetFolderPath) }
            'quit'       { $script:QuitRequested = $true }
            default      { Write-Log ('收到未知指令：' + $name) -Level WARN }
        }
    }
}

<#
    Wait-Tick
    等 N 秒，但这期间消息泵要跑、指令要收、心跳要发。
    收到 sync / quit 立刻返回 —— 不然网页上点了按钮要等 5 秒才有反应。
#>
function Wait-Tick {
    param([int]$Seconds)
    $end = (Get-Date).AddSeconds($Seconds)
    $lastBeat = Get-Date
    while ((Get-Date) -lt $end) {
        if ($uiOn) { Invoke-UIPump }
        try { Invoke-Commands } catch { }
        if ($script:ForceSync -or $script:QuitRequested) { return }
        if (((Get-Date) - $lastBeat).TotalMilliseconds -ge 900) {
            $lastBeat = Get-Date
            Save-UIStatus -MinIntervalMs 800
        }
        Start-Sleep -Milliseconds 180
    }
}

# 兼容旧名字
function Wait-Pump { param([int]$Seconds) Wait-Tick $Seconds }

Publish-BindInfo | Out-Null
Initialize-WatchUI
Save-UIStatus -Force

if (-not $script:UIRuntime.Bound) {
    Write-Host '还没有配置任何目的地 —— 在网页「设置 → 同步任务」里添加源目录和目的地。' -ForegroundColor Yellow
}

$knownSerials = @{}          # 上一轮在线的序列号集合（用于识别"刚插入"）
$lastSyncAt = [datetime]::MinValue
$lastFolderRun = [datetime]::MinValue
$errStreak = 0

while ($true) {
    try {
        $script:Cfg = Get-SyncConfig
        $cfg = $script:Cfg

        # 网页里改了"进度条什么时候出现"，不用重启监听就生效
        if ($uiOn) {
            if ($cfg.Options -and $cfg.Options.MiniBarMode) { Set-MiniBarMode ([string]$cfg.Options.MiniBarMode) }
            Update-BarVisibility
        }

        # ---- 先响应网页点出来的指令 ----
        Invoke-Commands
        if ($script:QuitRequested) { break }

        # 窗口常驻，正常情况下不会消失；真被销毁了（比如脚本报错重来）才补建
        if ($uiOn -and -not (Test-UIAlive)) {
            [void](New-ProgressWindow -Title '监听中' -Compact)
            Set-UIStatus -Connected $false -Footer (Update-FooterText)
        }

        # ---- 目的地在线检测（多任务） ----
        $pairs = Get-SyncPairs -Config $cfg
        $nowSerials = Get-AllSerials
        $destMap = Get-DestSerialMap -Pairs $pairs

        $diskOnline = $false
        $arrivedSerial = ''
        foreach ($k in $destMap.Keys) {
            if ($nowSerials.ContainsKey($k)) {
                $diskOnline = $true
                if (-not $knownSerials.ContainsKey($k)) { $arrivedSerial = $k }
            }
        }
        $folderOnline = $false
        foreach ($p in $pairs) {
            if ($p.DestKind -eq 'folder' -and (Test-DestAvailable -Pair $p)) { $folderOnline = $true; break }
        }
        $present = ($pairs.Count -gt 0) -and ($diskOnline -or $folderOnline)

        Set-UIStatus -Connected $present -Footer (Update-FooterText)
        if ($uiOn -and -not $present -and -not $script:UIState.Syncing) {
            Update-ProgressUI -Title '监听中' -Detail $(if ($pairs.Count -eq 0) { '还没配置同步任务' } else { '等目的地就绪' }) -Hint '' -Percent 0 -State 'Idle'
        }
        Save-UIStatus -MinIntervalMs 500

        # 没配置任务：明确告诉用户卡在哪一步
        if ($script:ForceSync -and $pairs.Count -eq 0) {
            $script:ForceSync = $false
            Write-Log '网页：还没有配置任何同步任务' -Level WARN
            [void](Add-UINotice -Level 'Warn' -Reason '没有可同步的任务' `
                    -Target '到「设置 → 同步任务」里添加源目录和目的地' `
                    -Advice '添加后插盘或点「立即同步」即可' `
                    -Key ('NOTASKS|' + (Get-Date -Format 'yyyyMMdd')))
        }

        $force = $script:ForceSync
        $script:ForceSync = $false

        if ($script:Paused -and -not $force) {
            $knownSerials = $nowSerials
            if ($Once) { break }
            Wait-Tick $script:Interval
            continue
        }

        # ---- 触发判定 ----
        $doRun = $false
        $runReason = ''
        $runParams = @{}

        if ($arrivedSerial -and -not $paused) {
            $doRun = $true; $runReason = 'arrival'
            $runParams = @{ ArrivedSerial = $arrivedSerial }
            Write-Log ('检测到目的地硬盘插入：' + $arrivedSerial) -Level OK
            Wait-Tick 3          # 等卷挂载与盘符分配完成
        } elseif ($force) {
            $doRun = $true; $runReason = 'manual'
            Write-Log '执行手动同步' -Level INFO
        } elseif (($folderOnline -or $diskOnline) -and $cfg.Options.FolderSyncMinutes -gt 0) {
            $mins = [int]$cfg.Options.FolderSyncMinutes
            if (((Get-Date) - $lastFolderRun).TotalMinutes -ge $mins) {
                $doRun = $true; $runReason = 'timer'
                $runParams = @{ OnlyFolder = $true }
            }
        }

        if ($doRun) {
            # 防抖：硬盘接触不良反复掉线重连时避免每轮都全量比对；手动同步不走防抖
            $debounce = 60
            if ($cfg.Options -and $cfg.Options.DebounceSeconds) { $debounce = [int]$cfg.Options.DebounceSeconds }
            $sinceLast = ((Get-Date) - $lastSyncAt).TotalSeconds
            if ($runReason -ne 'manual' -and $lastSyncAt -ne [datetime]::MinValue -and $sinceLast -lt $debounce) {
                Write-Log ('距上次同步仅 {0:N0} 秒，低于防抖间隔 {1} 秒，本次跳过' -f $sinceLast, $debounce) -Level INFO
            } else {
                $r = Invoke-FileSyncRun -Config $cfg -Auto -NoWindow:(-not $uiOn) @runParams
                $lastSyncAt = Get-Date
                if ($runReason -eq 'timer') { $lastFolderRun = Get-Date }
                Set-UIRuntime -Key 'LastSyncAt' -Value ((Get-Date).ToString('o'))

                if ($r.Code -eq 'ALREADYBUSY') {
                    Write-Log '另一个同步任务正在运行，本次跳过' -Level INFO
                } elseif ($r.Code -eq 'NOTASKS') {
                    Write-Log '还没有配置同步任务' -Level WARN
                } elseif ($r.Code -eq 'NOTHINGTODO') {
                    Write-Log '目的地都不在线，没有可执行的配对' -Level WARN
                } elseif ($r.Code -eq 'CANCELLED') {
                    Write-Log '同步被你手动停止' -Level WARN
                } elseif ($r.Ok -or $r.Code -eq 'PARTIAL') {
                    Write-Log ('同步结束：' + $r.Message) -Level $(if ($r.Ok) { 'OK' } else { 'WARN' })
                } else {
                    Write-Log ('同步未完成：' + $r.Message) -Level WARN
                }

                # 同步流程会关窗；监听模式下把迷你条立回来
                if ($uiOn) {
                    Initialize-WatchUI
                    if ($r.Ok -or $r.Code -eq 'PARTIAL') {
                        Set-UIStatus -LastSync (Get-Date -Format 'HH:mm') -Connected $true
                    }
                }
                Set-UIStatus -Connected $present
            }
        }

        $knownSerials = $nowSerials
        $errStreak = 0
        if ($Once) { break }
    }
    catch {
        $errStreak++
        Write-Log ('监听循环异常（连续第 {0} 次）：{1}' -f $errStreak, $_.Exception.Message) -Level ERROR
        if ($Once) { break }
        # 连续出错时逐步拉长间隔，避免配置损坏这类持续性错误每 5 秒刷一次日志
        if ($errStreak -ge 3) {
            $backoff = [Math]::Min($script:Interval * $errStreak, 120)
            Write-Log ('等待 {0} 秒后重试' -f $backoff) -Level INFO
            Wait-Tick $backoff
            continue
        }
    }

    Wait-Tick $script:Interval
}

Write-Host ''
if ($script:QuitRequested) {
    # 主动退出要留个记号：否则服务端的 watchdog 以为监听崩了，几秒后又拉起一个，
    # 用户就会看到两个托盘图标。服务端见到这个新鲜标记就跟着一起停。
    try {
        $flagPath = Join-Path $PSScriptRoot '_ipc\shutdown.json'
        $flagJson = "{`n  `"ts`": `"" + (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') + "`",`n  `"pid`": $PID`n}`n"
        [System.IO.File]::WriteAllText($flagPath, $flagJson, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    Write-Log '收到退出指令，监听主动停止' -Level INFO
}
Write-Log '监听已退出' -Level INFO
