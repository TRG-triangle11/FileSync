#Requires -Version 5.1
<#
    Serve-Console.ps1  -  本地网页控制台的服务端

    一个只监听 127.0.0.1 的极简 HTTP 服务：
      · 把 console\ 目录下的页面发给浏览器
      · 把 _ipc\status.json（同步引擎写的）转给页面
      · 把页面上的点击变成 _ipc\cmd\*.json，交给监听进程执行
      · 顺带把监听进程拉起来并看着它（崩了重启）

    为什么不用真实时推送：
      同步引擎是单线程循环，边拷 68 GB 边维持 WebSocket 只会互相拖死。
      状态写成 2 KB 的 JSON，页面 400 ms 轮询一次，本机延迟 1~3 ms，引擎零负担。

    用法：
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Serve-Console.ps1
      ... -Port 7790        指定端口
      ... -NoBrowser        不自动开浏览器
      ... -NoWatch          只开网页，不管监听进程
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NoBrowser,
    [switch]$NoWatch,
    [switch]$Quiet,
    # 演示模式：硬盘状态和绑定信息用固定样例，不读真实磁盘、不写任何文件。
    # 只用于截图和给人看效果，正常使用不要加这个参数。
    [switch]$Demo
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

. (Join-Path $here 'SyncCore.ps1')

$script:RootDir    = $here
$script:WebDir     = Join-Path $here 'console'
$script:IPCDir     = Join-Path $here '_ipc'
$script:CmdDir     = Join-Path $script:IPCDir 'cmd'
$script:StatusPath = Join-Path $script:IPCDir 'status.json'
$script:ConsoleCfg = Join-Path $here 'console.json'
$script:WatchScript= Join-Path $here 'Watch-FileSync.ps1'

$script:StartedAt     = Get-Date
$script:Running       = $true
$script:WatchProc     = $null
$script:WatchRestarts = 0
$script:LastGood      = $null
$script:DiskCache     = $null
$script:DiskCacheAt   = [datetime]::MinValue
$script:DisksCache    = $null
$script:DisksCacheAt  = [datetime]::MinValue
$script:Ver           = '2.0'

function Write-Serve {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Msg
    if (-not $Quiet) {
        switch ($Level) {
            'OK'    { Write-Host $line -ForegroundColor Green }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'ERROR' { Write-Host $line -ForegroundColor Red }
            default { Write-Host $line -ForegroundColor DarkGray }
        }
    }
    try {
        $logDir = Join-Path $here 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
        Add-Content -LiteralPath (Join-Path $logDir 'console.log') -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

# ═══════════════════════════════════════════════════════════════
# JSON 转义（手写，避免 ConvertTo-Json 把中文转成 \uXXXX）
# ═══════════════════════════════════════════════════════════════
$script:EscapeMap = @{ '"' = '\"'; '\' = '\\'; "`b" = '\b'; "`f" = '\f'; "`n" = '\n'; "`r" = '\r'; "`t" = '\t' }

function ConvertTo-JsonStr {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 'null' }
    $s = [string]$Value
    if ($s.Length -eq 0) { return '""' }
    $sb = New-Object System.Text.StringBuilder ($s.Length + 8)
    foreach ($ch in $s.ToCharArray()) {
        $k = [string]$ch
        if ($script:EscapeMap.ContainsKey($k)) { [void]$sb.Append($script:EscapeMap[$k]) }
        elseif ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
        else { [void]$sb.Append($ch) }
    }
    return '"' + $sb.ToString() + '"'
}

function ConvertTo-JsonBool {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value) { return 'true' } else { return 'false' }
}

# ═══════════════════════════════════════════════════════════════
# 端口
# ═══════════════════════════════════════════════════════════════
function Get-SavedPort {
    try {
        if (Test-Path -LiteralPath $script:ConsoleCfg) {
            $o = (Get-Content -LiteralPath $script:ConsoleCfg -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($o.Port) { return [int]$o.Port }
        }
    } catch { }
    return 7788
}

function Test-PortFree {
    param([int]$P)
    $l = $null
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $P)
        $l.Start()
        return $true
    } catch { return $false }
    finally { if ($l) { try { $l.Stop() } catch { } } }
}

function Test-ExistingInstance {
    param([int]$P)
    try {
        $req = [System.Net.WebRequest]::Create("http://127.0.0.1:$P/api/ping")
        $req.Timeout = 800
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $txt = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        return ($txt -match '(DiskSync|FileSync)')
    } catch { return $false }
}

function Save-Port {
    param([int]$P)
    try {
        $json = "{`n  `"Port`": $P,`n  `"UpdatedAt`": $(ConvertTo-JsonStr ((Get-Date).ToString('s')))`n}`n"
        [System.IO.File]::WriteAllText($script:ConsoleCfg, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ═══════════════════════════════════════════════════════════════
# 监听进程
# ═══════════════════════════════════════════════════════════════
function Test-WatchRunning {
    if ($script:WatchProc) {
        try { if (-not $script:WatchProc.HasExited) { return $true } } catch { }
    }
    # 也许已经有别的实例在跑（比如手动启动的），看状态文件的心跳
    $st = Read-StatusFile
    if (-not $st) { return $false }
    try {
        $ts = [datetime]::Parse([string]$st.ts)
        if (((Get-Date) - $ts).TotalSeconds -lt 25) {
            $p = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -match 'powershell|pwsh') { return $true }
        }
    } catch { }
    return $false
}

# 监听是不是「主动退出」的（托盘菜单点退出时会留下关机标记）。
# 这种退出不能被 watchdog 当成崩溃去复活，否则托盘会多出一个新图标。
function Test-RecentShutdown {
    param([int]$WithinSeconds = 60)
    try {
        $p = Join-Path $here '_ipc\shutdown.json'
        if (-not (Test-Path -LiteralPath $p)) { return $false }
        $o = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $ts = [datetime]::Parse([string]$o.ts)
        return (((Get-Date) - $ts).TotalSeconds -lt $WithinSeconds)
    } catch { return $false }
}

function Clear-ShutdownFlag {
    try {
        $p = Join-Path $here '_ipc\shutdown.json'
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    } catch { }
}

function Start-WatchProcess {
    if ($NoWatch) { return }
    if (Test-WatchRunning) { Write-Serve '监听进程已在运行' 'INFO'; return }
    if (-not (Test-Path -LiteralPath $script:WatchScript)) {
        Write-Serve ('找不到 ' + $script:WatchScript) 'ERROR'
        return
    }
    try {
        Clear-ShutdownFlag       # 刚才那次主动退出的记号作废，本次是全新启动
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:WatchScript + '"'), '-PollSeconds', '5')
        $script:WatchProc = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList $argList
        Write-Serve ('已启动监听进程 (PID {0})' -f $script:WatchProc.Id) 'OK'
    } catch {
        Write-Serve ('启动监听进程失败：' + $_.Exception.Message) 'ERROR'
    }
}

function Stop-WatchProcess {
    if ($script:WatchProc) {
        try { if (-not $script:WatchProc.HasExited) { $script:WatchProc.Kill() } } catch { }
    }
    # 兜底：监听不是本进程拉起来的（比如服务重启过），按状态文件里的心跳 PID 找到它停掉，
    # 不然托盘和迷你条会变成无主孤儿一直挂着。
    try {
        $st = Read-StatusFile
        if ($st -and $st.pid) {
            $p = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -match 'powershell|pwsh' -and $p.Id -ne $PID) { $p.Kill() }
        }
    } catch { }
}

# ═══════════════════════════════════════════════════════════════
# 读状态 / 写指令
# ═══════════════════════════════════════════════════════════════
function Read-StatusFile {
    try {
        if (Test-Path -LiteralPath $script:StatusPath) {
            $txt = [System.IO.File]::ReadAllText($script:StatusPath, [System.Text.Encoding]::UTF8)
            if ($txt -and $txt.TrimStart().StartsWith('{')) {
                $o = $txt | ConvertFrom-Json
                if ($o) { $script:LastGood = $o; return $o }
            }
        }
    } catch { }
    return $script:LastGood
}

function Send-IPCCommand {
    param([string]$Cmd)
    try {
        if (-not (Test-Path -LiteralPath $script:CmdDir)) {
            [void](New-Item -ItemType Directory -Path $script:CmdDir -Force -ErrorAction Stop)
        }
        $name = '{0}-{1}.json' -f (Get-Date -Format 'yyyyMMddHHmmssfff'), (Get-Random -Minimum 1000 -Maximum 9999)
        $body = '{ "cmd": ' + (ConvertTo-JsonStr $Cmd) + ', "at": ' + (ConvertTo-JsonStr ((Get-Date).ToString('o'))) + ' }'
        [System.IO.File]::WriteAllText((Join-Path $script:CmdDir $name), $body, (New-Object System.Text.UTF8Encoding($false)))
        Write-Serve ('网页指令：' + $Cmd) 'INFO'
        return $true
    } catch {
        Write-Serve ('写指令失败：' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

# ═══════════════════════════════════════════════════════════════
# 磁盘信息
# ═══════════════════════════════════════════════════════════════
function Get-DiskSnapshot {
    param([switch]$Force)
    if ($Demo) {
        return @{ Present = $true; Letter = 'F'; Label = 'Elements 25A3'; TotalGB = 1863.0; FreeGB = 1794.3
                  Folder = 'F:\示例资料'; HasFolder = $true }
    }
    if (-not $Force -and $script:DiskCache -and ((Get-Date) - $script:DiskCacheAt).TotalSeconds -lt 4) {
        return $script:DiskCache
    }
    try {
        $cfg = Get-SyncConfig
        $r = Resolve-TargetDrive -Config $cfg
        if ($r.Ok) {
            $letter = [string]$r.Volume.Letter
            $v = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
            $folder = Join-Path ($letter + ':') ([string]$cfg.TargetFolderName)
            $exists = Test-Path -LiteralPath $folder
            $script:DiskCache = @{
                Present  = $true
                Letter   = $letter
                Label    = if ($v) { [string]$v.FileSystemLabel } else { '' }
                TotalGB  = if ($v) { [Math]::Round($v.Size / 1GB, 1) } else { 0 }
                FreeGB   = if ($v) { [Math]::Round($v.SizeRemaining / 1GB, 1) } else { 0 }
                Folder   = $folder
                HasFolder= $exists
            }
        } else {
            $script:DiskCache = @{ Present = $false; Letter = ''; Label = ''; TotalGB = 0; FreeGB = 0; Folder = ''; HasFolder = $false }
        }
    } catch {
        $script:DiskCache = @{ Present = $false; Letter = ''; Label = ''; TotalGB = 0; FreeGB = 0; Folder = ''; HasFolder = $false }
    }
    $script:DiskCacheAt = Get-Date
    return $script:DiskCache
}

function Get-BindableDisks {
    param([switch]$Force)
    if ($Demo) {
        return @(
            @{ Number = 1; Model = 'Elements 25A3'; Serial = 'WCC4N1234567'; PhysSerial = 'WCC4N1234567'
               BusType = 'USB'; SizeGB = 1863.0
               Volumes = @(@{ Letter = 'F'; Label = 'My Passport'; SizeGB = 1863.0; FreeGB = 1794.3; VolSerial = '9C3A-1F2B' }) },
            @{ Number = 2; Model = 'Generic Flash Disk'; Serial = 'AA04012700012345'; PhysSerial = ''
               BusType = 'USB'; SizeGB = 28.9
               Volumes = @(@{ Letter = 'G'; Label = 'U盘'; SizeGB = 28.9; FreeGB = 12.4; VolSerial = '1A2B-3C4D' }) }
        )
    }
    if (-not $Force -and $script:DisksCache -and ((Get-Date) - $script:DisksCacheAt).TotalSeconds -lt 10) {
        return $script:DisksCache
    }
    $out = New-Object System.Collections.ArrayList
    try {
        foreach ($d in (Get-Disk -ErrorAction Stop | Sort-Object Number)) {
            if ($d.IsBoot -or $d.IsSystem) { continue }
            if ($d.Size -lt 1GB) { continue }
            $vols = New-Object System.Collections.ArrayList
            try {
                foreach ($p in (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)) {
                    if (-not $p.DriveLetter) { continue }
                    $v = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue
                    $label = if ($v) { [string]$v.FileSystemLabel } else { '' }
                    [void]$vols.Add(@{
                        Letter  = [string]$p.DriveLetter
                        Label   = $label
                        SizeGB  = if ($v) { [Math]::Round($v.Size / 1GB, 1) } else { 0 }
                        FreeGB  = if ($v) { [Math]::Round($v.SizeRemaining / 1GB, 1) } else { 0 }
                        VolSerial = if ($v) { [string]$v.SerialNumber } else { '' }
                    })
                }
            } catch { }
            if ($vols.Count -eq 0) { continue }

            $physSerial = ''
            try {
                $pd = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq [string]$d.Number } | Select-Object -First 1
                if ($pd) { $physSerial = [string]$pd.SerialNumber }
            } catch { }

            [void]$out.Add(@{
                Number     = [int]$d.Number
                Model      = [string]$d.FriendlyName
                Serial     = [string]$d.SerialNumber
                PhysSerial = $physSerial
                BusType    = [string]$d.BusType
                SizeGB     = [Math]::Round($d.Size / 1GB, 1)
                Volumes    = @($vols)
            })
        }
    } catch { }
    $script:DisksCache = @($out)
    $script:DisksCacheAt = Get-Date
    return $script:DisksCache
}

function Save-HardwareBinding {
    param([int]$DiskNumber)

    $cfg = Get-SyncConfig
    $targetNames = @([string]$cfg.TargetFolderName)
    $all = @(Get-BindableDisks -Force)

    # 优先选已经存在目标文件夹的那块盘 —— 多分区硬盘上选错卷是最常见的坑
    $pick = $null; $pickVol = $null
    foreach ($d in $all) {
        if ($d.Number -ne $DiskNumber) { continue }
        $pick = $d
        foreach ($v in $d.Volumes) {
            $folder = Join-Path ($v.Letter + ':') ([string]$cfg.TargetFolderName)
            if (Test-Path -LiteralPath $folder) { $pickVol = $v; break }
        }
        if (-not $pickVol) { $pickVol = $d.Volumes[0] }
        break
    }
    if (-not $pick) { return @{ Ok = $false; Message = '找不到这块磁盘（可能刚被拔出）' } }
    if (-not $pickVol) { return @{ Ok = $false; Message = '这块磁盘上没有已分配盘符的分区' } }

    if (-not $pick.Serial -and -not $pick.PhysSerial -and -not $pickVol.VolSerial) {
        return @{ Ok = $false; Message = '这块磁盘读不到硬件序列号，无法绑定（换硬盘盒或换 USB 口再试）' }
    }

    $display = '{0} ({1}:) {2:N1} GB' -f $pick.Model, $pickVol.Letter, $pick.SizeGB
    $json = @"
{
  "DiskSerialNumber": "$(ConvertTo-JsonStr $pick.Serial.Trim())",
  "PhysicalDiskSerialNumber": "$(ConvertTo-JsonStr $pick.PhysSerial.Trim())",
  "VolumeSerialNumber": "$(ConvertTo-JsonStr $pickVol.VolSerial.Trim())",
  "VolumeLabel": "$(ConvertTo-JsonStr $pickVol.Label)",
  "DiskSizeBytes": $([long]([double]$pick.SizeGB * 1GB)),
  "BoundAt": "$(ConvertTo-JsonStr (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))",
  "BoundDisplayName": "$(ConvertTo-JsonStr $display)"
}
"@
    try {
        [System.IO.File]::WriteAllText((Join-Path $here 'hardware.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Serve ('已绑定：' + $display) 'OK'
        return @{ Ok = $true; Message = ('已绑定 ' + $display); Name = $display }
    } catch {
        return @{ Ok = $false; Message = ('写入 hardware.json 失败：' + $_.Exception.Message) }
    }
}

# ═══════════════════════════════════════════════════════════════
# 开机自启（用户级启动文件夹快捷方式，无需管理员）
# ═══════════════════════════════════════════════════════════════
function Get-AutoStartLnkPath {
    try { return (Join-Path ([Environment]::GetFolderPath('Startup')) 'FileSync.lnk') } catch { return $null }
}

function Test-AutoStartEnabled {
    $p = Get-AutoStartLnkPath
    if ($p -and (Test-Path -LiteralPath $p)) { return $true }
    return $false
}

function Enable-AutoStart {
    $p = Get-AutoStartLnkPath
    if (-not $p) { return @{ Ok = $false; Message = '拿不到「启动」文件夹路径' } }
    $vbs = Join-Path $here '启动-后台.vbs'
    if (-not (Test-Path -LiteralPath $vbs)) { return @{ Ok = $false; Message = '找不到 启动-后台.vbs（静默启动器）' } }
    try {
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($p)
        $sc.TargetPath       = 'wscript.exe'
        $sc.Arguments        = '"' + $vbs + '"'
        $sc.WorkingDirectory = $here
        $sc.WindowStyle      = 1
        $sc.Description      = 'FileSync 开机自启（后台静默，无窗口）'
        $ico = Join-Path $here 'FileSync.ico'
        if (Test-Path -LiteralPath $ico) { $sc.IconLocation = $ico + ',0' }
        $sc.Save()
        return @{ Ok = $true; Message = '已开启：开机进桌面后 FileSync 会静默自启' }
    } catch {
        return @{ Ok = $false; Message = $_.Exception.Message }
    }
}

function Disable-AutoStart {
    $p = Get-AutoStartLnkPath
    if ($p -and (Test-Path -LiteralPath $p)) {
        try { Remove-Item -LiteralPath $p -Force } catch { return @{ Ok = $false; Message = $_.Exception.Message } }
    }
    return @{ Ok = $true; Message = '已关闭开机自启' }
}

# ═══════════════════════════════════════════════════════════════
# 任务列表 JSON（含目的地在线状态与各自上次同步时间；5 秒缓存）
# ═══════════════════════════════════════════════════════════════
$script:TasksStateCache = $null
$script:TasksStateAt = [datetime]::MinValue

function Get-TasksStateJson {
    param($Cfg)

    if ($script:TasksStateCache -and ((Get-Date) - $script:TasksStateAt).TotalSeconds -lt 5) {
        return $script:TasksStateCache
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('[')
    try {
        $pairs = Get-SyncPairs -Config $Cfg
        $ti = 0
        $first = $true
        foreach ($t in @($Cfg.Tasks)) {
            if (-not $first) { [void]$sb.Append(',') }
            $first = $false
            [void]$sb.Append('{"name":').Append((ConvertTo-JsonStr ([string]$t.Name)))
            [void]$sb.Append(',"source":').Append((ConvertTo-JsonStr ([string]$t.Source)))
            [void]$sb.Append(',"dests":[')
            $di = 0
            $dFirst = $true
            foreach ($d in @($t.Dests)) {
                if (-not $dFirst) { [void]$sb.Append(',') }
                $dFirst = $false
                $pair = $null
                foreach ($p in $pairs) { if ($p.TaskIndex -eq $ti -and $p.DestIndex -eq $di) { $pair = $p; break } }

                $online = $false
                $lastSyncAt = ''; $lastCount = 0
                if ($pair) {
                    try { $online = [bool](Test-DestAvailable -Pair $pair) } catch { }
                    $stPath = Join-Path $here ('_ipc\state\' + $pair.PairId + '.json')
                    if (Test-Path -LiteralPath $stPath) {
                        try {
                            $st = (Get-Content -LiteralPath $stPath -Raw -Encoding UTF8) | ConvertFrom-Json
                            $lastSyncAt = [string]$st.LastSuccessAt
                            $lastCount = [int]$st.SourceCount
                        } catch { }
                    }
                }

                $kind = [string]$d.Kind
                if ($kind -eq 'folder') {
                    [void]$sb.Append('{"kind":"folder"')
                    [void]$sb.Append(',"label":').Append((ConvertTo-JsonStr ([string]$d.Path)))
                    [void]$sb.Append(',"path":').Append((ConvertTo-JsonStr ([string]$d.Path)))
                    [void]$sb.Append(',"sub":""')
                } else {
                    $lbl = [string]$d.Label
                    if (-not $lbl) { $lbl = '移动硬盘' }
                    $ser = ''
                    if ($d.Serials) { $ser = [string]$d.Serials.Disk }
                    [void]$sb.Append('{"kind":"disk"')
                    [void]$sb.Append(',"label":').Append((ConvertTo-JsonStr $lbl))
                    [void]$sb.Append(',"path":""')
                    [void]$sb.Append(',"sub":').Append((ConvertTo-JsonStr ([string]$d.Sub)))
                    [void]$sb.Append(',"serial":').Append((ConvertTo-JsonStr $ser))
                }
                [void]$sb.Append(',"online":').Append((ConvertTo-JsonBool $online))
                [void]$sb.Append(',"lastSyncAt":').Append((ConvertTo-JsonStr $lastSyncAt))
                [void]$sb.Append(',"lastCount":').Append($lastCount)
                [void]$sb.Append('}')
                $di++
            }
            [void]$sb.Append(']}')
            $ti++
        }
    } catch { }
    [void]$sb.Append(']')
    $script:TasksStateCache = $sb.ToString()
    $script:TasksStateAt = Get-Date
    return $script:TasksStateCache
}

# ═══════════════════════════════════════════════════════════════
# /api/state
# ═══════════════════════════════════════════════════════════════
function Get-StateJson {
    $st = Read-StatusFile
    $disk = Get-DiskSnapshot
    $sb = New-Object System.Text.StringBuilder 4096

    $cfg = $null
    try { $cfg = Get-SyncConfig } catch { }
    $hw = Get-HardwareInfo
    $bound = Test-HardwareBound $hw

    $watchAlive = Test-WatchRunning
    if ($Demo) { $watchAlive = $true }
    if ($Demo) { $bound = $true }

    [void]$sb.Append('{"server":{"ver":').Append((ConvertTo-JsonStr $script:Ver))
    [void]$sb.Append(',"port":').Append($script:Port)
    [void]$sb.Append(',"uptime":').Append([int]((Get-Date) - $script:StartedAt).TotalSeconds)
    [void]$sb.Append(',"watchAlive":').Append((ConvertTo-JsonBool $watchAlive))
    [void]$sb.Append(',"watchRestarts":').Append($script:WatchRestarts)
    [void]$sb.Append(',"autostart":').Append((ConvertTo-JsonBool (Test-AutoStartEnabled)))
    [void]$sb.Append(',"now":').Append((ConvertTo-JsonStr ((Get-Date).ToString('o'))))
    [void]$sb.Append('}')

    # ---- 同步状态（同步引擎写的那个文件）----
    [void]$sb.Append(',"sync":{')
    if ($st) {
        [void]$sb.Append('"mode":').Append((ConvertTo-JsonStr $st.mode))
        [void]$sb.Append(',"percent":').Append([int]$st.percent)
        [void]$sb.Append(',"title":').Append((ConvertTo-JsonStr $st.title))
        [void]$sb.Append(',"detail":').Append((ConvertTo-JsonStr $st.detail))
        [void]$sb.Append(',"meta":').Append((ConvertTo-JsonStr $st.meta))
        [void]$sb.Append(',"hint":').Append((ConvertTo-JsonStr $st.hint))
        [void]$sb.Append(',"advice":').Append((ConvertTo-JsonStr $st.advice))
        [void]$sb.Append(',"syncing":').Append((ConvertTo-JsonBool $st.syncing))
        [void]$sb.Append(',"connected":').Append((ConvertTo-JsonBool $st.connected))
        [void]$sb.Append(',"files":').Append((ConvertTo-JsonStr $st.files))
        [void]$sb.Append(',"size":').Append((ConvertTo-JsonStr $st.size))
        [void]$sb.Append(',"lastSync":').Append((ConvertTo-JsonStr $st.lastSync))
        [void]$sb.Append(',"lastSyncAt":').Append((ConvertTo-JsonStr $st.lastSyncAt))
        [void]$sb.Append(',"footer":').Append((ConvertTo-JsonStr $st.footer))
        [void]$sb.Append(',"paused":').Append((ConvertTo-JsonBool $st.paused))
        [void]$sb.Append(',"ts":').Append((ConvertTo-JsonStr $st.ts))

        [void]$sb.Append(',"issues":[')
        $i = 0
        foreach ($it in @($st.issues)) {
            if ($i -gt 0) { [void]$sb.Append(',') }
            [void]$sb.Append('{"level":').Append((ConvertTo-JsonStr $it.level))
            [void]$sb.Append(',"reason":').Append((ConvertTo-JsonStr $it.reason))
            [void]$sb.Append(',"target":').Append((ConvertTo-JsonStr $it.target))
            [void]$sb.Append(',"advice":').Append((ConvertTo-JsonStr $it.advice))
            [void]$sb.Append('}')
            $i++
        }
        [void]$sb.Append(']')

        [void]$sb.Append(',"activity":[')
        $j = 0
        foreach ($a in @($st.activity)) {
            if ($j -gt 0) { [void]$sb.Append(',') }
            [void]$sb.Append('{"t":').Append((ConvertTo-JsonStr $a.t))
            [void]$sb.Append(',"level":').Append((ConvertTo-JsonStr $a.level))
            [void]$sb.Append(',"msg":').Append((ConvertTo-JsonStr $a.msg))
            [void]$sb.Append('}')
            $j++
        }
        [void]$sb.Append(']')
    } else {
        [void]$sb.Append('"mode":"Idle","percent":0,"title":"尚未启动","detail":"监听进程还没写状态","meta":"","hint":"","advice":"","syncing":false,"connected":null,"files":"—","size":"—","lastSync":"—","lastSyncAt":"","footer":"","paused":false,"ts":"","issues":[],"activity":[]')
    }
    [void]$sb.Append('}')

    # ---- 配置摘要 ----
    [void]$sb.Append(',"config":{')
    if ($cfg) {
        $pairsAll = Get-SyncPairs -Config $cfg
        $firstSource = ''
        if ($pairsAll.Count -gt 0) { $firstSource = [string]$pairsAll[0].Source }
        [void]$sb.Append('"sourcePath":').Append((ConvertTo-JsonStr $firstSource))
        $firstSub = ''
        if ($pairsAll.Count -gt 0) { $firstSub = [string]$pairsAll[0].Sub }
        [void]$sb.Append(',"targetFolderName":').Append((ConvertTo-JsonStr $firstSub))
        [void]$sb.Append(',"logDir":').Append((ConvertTo-JsonStr $cfg.LogDir))
        [void]$sb.Append(',"excludeDirs":[')
        $k = 0
        foreach ($e in @($cfg.Options.ExcludeDirs)) { if ($k -gt 0) { [void]$sb.Append(',') }; [void]$sb.Append((ConvertTo-JsonStr $e)); $k++ }
        [void]$sb.Append('],"excludeFiles":[')
        $k = 0
        foreach ($e in @($cfg.Options.ExcludeFiles)) { if ($k -gt 0) { [void]$sb.Append(',') }; [void]$sb.Append((ConvertTo-JsonStr $e)); $k++ }
        [void]$sb.Append(']')
        [void]$sb.Append(',"threads":').Append([int]$cfg.Options.Threads)
        [void]$sb.Append(',"debounce":').Append([int]$cfg.Options.DebounceSeconds)
        $sm = 'mirror'
        if ($cfg.Options.PSObject.Properties.Name -contains 'SyncMode' -and $cfg.Options.SyncMode) { $sm = [string]$cfg.Options.SyncMode }
        [void]$sb.Append(',"syncMode":').Append((ConvertTo-JsonStr $sm))
        [void]$sb.Append(',"showWindow":').Append((ConvertTo-JsonBool ($cfg.Options.ShowProgressWindow -ne $false)))
        $mbm = 'auto'
        if ($cfg.Options.PSObject.Properties.Name -contains 'MiniBarMode' -and $cfg.Options.MiniBarMode) { $mbm = [string]$cfg.Options.MiniBarMode }
        [void]$sb.Append(',"miniBarMode":').Append((ConvertTo-JsonStr $mbm))
        [void]$sb.Append(',"moveHashMode":').Append((ConvertTo-JsonStr $cfg.Options.MoveDetect.HashMode))
        [void]$sb.Append(',"guardEnabled":').Append((ConvertTo-JsonBool ($cfg.Options.SafetyGuard.Enabled -ne $false)))
        [void]$sb.Append(',"guardMaxDelete":').Append([int]$cfg.Options.SafetyGuard.MaxDeletePercent)
        [void]$sb.Append(',"backupKeepDays":').Append([int]$cfg.Options.Retention.BackupKeepDays)
        [void]$sb.Append(',"backupMaxGB":').Append([int]$cfg.Options.Retention.BackupMaxGB)
        $fsm = 0
        if ($cfg.Options.PSObject.Properties.Name -contains 'FolderSyncMinutes') { $fsm = [int]$cfg.Options.FolderSyncMinutes }
        [void]$sb.Append(',"folderSyncMinutes":').Append($fsm)
        [void]$sb.Append(',"raw":').Append((ConvertTo-JsonStr ((Get-Content -LiteralPath (Join-Path $here 'config.json') -Raw -Encoding UTF8))))
        # ---- 任务列表（含目的地在线状态，5 秒缓存）----
        [void]$sb.Append(',"tasks":').Append((Get-TasksStateJson -Cfg $cfg))
    }
    [void]$sb.Append('}')

    # ---- 绑定 ----
    [void]$sb.Append(',"bind":{')
    [void]$sb.Append('"bound":').Append((ConvertTo-JsonBool $bound))
    if ($Demo) {
        [void]$sb.Append(',"name":').Append((ConvertTo-JsonStr 'Elements 25A3 (F:) 1863.0 GB'))
        [void]$sb.Append(',"serial":').Append((ConvertTo-JsonStr 'WCC4N1234567'))
        [void]$sb.Append(',"volumeSerial":').Append((ConvertTo-JsonStr '9C3A-1F2B'))
        [void]$sb.Append(',"boundAt":').Append((ConvertTo-JsonStr '2026-11-08 21:30:12'))
    } elseif ($hw) {
        [void]$sb.Append(',"name":').Append((ConvertTo-JsonStr $hw.BoundDisplayName))
        [void]$sb.Append(',"serial":').Append((ConvertTo-JsonStr $hw.DiskSerialNumber))
        [void]$sb.Append(',"volumeSerial":').Append((ConvertTo-JsonStr $hw.VolumeSerialNumber))
        [void]$sb.Append(',"boundAt":').Append((ConvertTo-JsonStr $hw.BoundAt))
    } else {
        [void]$sb.Append(',"name":"","serial":"","volumeSerial":"","boundAt":""')
    }
    [void]$sb.Append('}')

    # ---- 目标盘 ----
    [void]$sb.Append(',"disk":{"present":').Append((ConvertTo-JsonBool $disk.Present))
    [void]$sb.Append(',"letter":').Append((ConvertTo-JsonStr $disk.Letter))
    [void]$sb.Append(',"label":').Append((ConvertTo-JsonStr $disk.Label))
    [void]$sb.Append(',"totalGB":').Append($disk.TotalGB)
    [void]$sb.Append(',"freeGB":').Append($disk.FreeGB)
    [void]$sb.Append(',"folder":').Append((ConvertTo-JsonStr $disk.Folder))
    [void]$sb.Append(',"hasFolder":').Append((ConvertTo-JsonBool $disk.HasFolder))
    [void]$sb.Append('}')

    [void]$sb.Append('}')
    return $sb.ToString()
}

# ═══════════════════════════════════════════════════════════════
# HTTP
# ═══════════════════════════════════════════════════════════════
function Send-Response {
    param(
        $Context,
        [byte[]]$Bytes,
        [string]$ContentType = 'application/json; charset=utf-8',
        [int]$Code = 200,
        [string]$Cache = 'no-store, no-cache, must-revalidate'
    )
    $res = $Context.Response
    try {
        $res.StatusCode = $Code
        $res.ContentType = $ContentType
        $res.Headers['Cache-Control'] = $Cache
        $res.Headers['X-Content-Type-Options'] = 'nosniff'
        $res.Headers['X-Frame-Options'] = 'DENY'
        $res.ContentLength64 = $Bytes.Length
        $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
    } catch { }
    finally { try { $res.OutputStream.Close() } catch { } }
}

function Send-Text {
    param($Context, [string]$Text, [string]$ContentType = 'application/json; charset=utf-8', [int]$Code = 200)
    Send-Response -Context $Context -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Text)) -ContentType $ContentType -Code $Code
}

function Send-Json {
    param($Context, [string]$Json, [int]$Code = 200)
    Send-Text -Context $Context -Text $Json -ContentType 'application/json; charset=utf-8' -Code $Code
}

function Send-File {
    param($Context, [string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()
    $mime = switch ($ext) {
        '.html' { 'text/html; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.svg'  { 'image/svg+xml' }
        '.png'  { 'image/png' }
        '.ico'  { 'image/x-icon' }
        '.woff2'{ 'font/woff2' }
        default { 'application/octet-stream' }
    }
    # 字体和图标内容不变，给长缓存；样式/脚本/页面仍旧每次取最新
    $cache = 'no-store, no-cache, must-revalidate'
    if ($ext -eq '.woff2' -or $ext -eq '.svg' -or $ext -eq '.ico') {
        $cache = 'public, max-age=604800'
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        Send-Response -Context $Context -Bytes $bytes -ContentType $mime -Cache $cache
    } catch {
        Send-Text -Context $Context -Text '{"ok":false,"message":"文件读取失败"}' -Code 500
    }
}

function Get-RequestBody {
    param($Context)
    try {
        # 强制 UTF-8：客户端（浏览器 fetch / 脚本）发的 JSON 都是 UTF-8；
        # 依赖 ContentEncoding 时无 charset 的请求会落到系统默认编码（GBK）导致中文变乱码
        $sr = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
        $body = $sr.ReadToEnd()
        $sr.Close()
        return $body
    } catch { return '' }
}

$script:StaticRoutes = @{
    '/'         = 'index.html'
    '/index.html' = 'index.html'
    '/app.css'  = 'app.css'
    '/app.js'   = 'app.js'
    '/favicon.svg' = 'favicon.svg'
    '/favicon.ico' = 'favicon.ico'
    '/mark.svg' = 'mark.svg'
}

function Invoke-Api {
    param($Context, [string]$Path, [string]$Method)

    # ---- 健康检查 ----
    if ($Path -eq '/api/ping') {
        # 注意：参数模式下不加括号的 'a' + $b 不会拼接，'+' 会被绑到下一个位置参数上
        Send-Json $Context ('{"ok":true,"name":"FileSync","ver":"' + $script:Ver + '"}')
        return
    }

    # ---- 状态 ----
    if ($Path -eq '/api/state') {
        try { Send-Json $Context (Get-StateJson) }
        catch { Send-Json $Context ('{"ok":false,"message":' + (ConvertTo-JsonStr $_.Exception.Message) + '}') 500 }
        return
    }

    # ---- 磁盘列表 ----
    if ($Path -eq '/api/disks') {
        $list = @(Get-BindableDisks -Force)
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('{"ok":true,"disks":[')
        $i = 0
        foreach ($d in $list) {
            if ($i -gt 0) { [void]$sb.Append(',') }
            [void]$sb.Append('{"number":').Append($d.Number)
            [void]$sb.Append(',"model":').Append((ConvertTo-JsonStr $d.Model))
            [void]$sb.Append(',"serial":').Append((ConvertTo-JsonStr $d.Serial))
            [void]$sb.Append(',"busType":').Append((ConvertTo-JsonStr $d.BusType))
            [void]$sb.Append(',"sizeGB":').Append($d.SizeGB)
            [void]$sb.Append(',"volumes":[')
            $j = 0
            foreach ($v in $d.Volumes) {
                if ($j -gt 0) { [void]$sb.Append(',') }
                [void]$sb.Append('{"letter":').Append((ConvertTo-JsonStr $v.Letter))
                [void]$sb.Append(',"label":').Append((ConvertTo-JsonStr $v.Label))
                [void]$sb.Append(',"sizeGB":').Append($v.SizeGB)
                [void]$sb.Append(',"freeGB":').Append($v.FreeGB)
                [void]$sb.Append(',"volserial":').Append((ConvertTo-JsonStr $v.VolSerial))
                [void]$sb.Append('}')
                $j++
            }
            [void]$sb.Append(']}')
            $i++
        }
        [void]$sb.Append(']}')
        Send-Json $Context $sb.ToString()
        return
    }

    # ---- 绑定 ----
    if ($Path -eq '/api/bind' -and $Method -eq 'POST') {
        $body = Get-RequestBody $Context
        try {
            $o = $body | ConvertFrom-Json
            $n = [int]$o.diskNumber
        } catch { Send-Json $Context '{"ok":false,"message":"请求格式不对"}' 400; return }
        $r = Save-HardwareBinding -DiskNumber $n
        $resp = '{"ok":' + (ConvertTo-JsonBool $r.Ok) + ',"message":' + (ConvertTo-JsonStr $r.Message)
        if ($r.Ok) {
            # 返回序列号三要素：前端可以立刻把它加为某个任务的目的地
            try {
                $hw = Get-HardwareInfo
                if ($hw) {
                    $resp += ',"serials":{"disk":' + (ConvertTo-JsonStr ([string]$hw.DiskSerialNumber).Trim().ToUpper())
                    $resp += ',"phys":' + (ConvertTo-JsonStr ([string]$hw.PhysicalDiskSerialNumber).Trim().ToUpper())
                    $resp += ',"volume":' + (ConvertTo-JsonStr ([string]$hw.VolumeSerialNumber).Trim().ToUpper())
                    $resp += ',"label":' + (ConvertTo-JsonStr ([string]$hw.BoundDisplayName)) + '}'
                }
            } catch { }
        }
        $resp += '}'
        Send-Json $Context $resp
        if ($r.Ok) { Send-IPCCommand 'rescan' | Out-Null }
        return
    }

    # ---- 指令 ----
    if ($Path -eq '/api/cmd' -and $Method -eq 'POST') {
        $body = Get-RequestBody $Context
        try { $o = $body | ConvertFrom-Json; $cmd = [string]$o.cmd }
        catch { Send-Json $Context '{"ok":false,"message":"请求格式不对"}' 400; return }

        $allowed = @('sync', 'stop', 'pause', 'resume', 'togglepause', 'syncnow', 'showbar', 'showconsole', 'logs', 'source', 'target', 'quit')
        if ($allowed -notcontains $cmd) {
            Send-Json $Context ('{"ok":false,"message":' + (ConvertTo-JsonStr ('不认识的指令：' + $cmd)) + '}') 400
            return
        }

        if ($cmd -eq 'quit') {
            Send-Json $Context '{"ok":true}'
            $script:Running = $false
            return
        }

        # 监听没在跑的时候点「立即同步」，先把监听拉起来
        if (-not (Test-WatchRunning)) {
            Start-WatchProcess
            Start-Sleep -Milliseconds 900
        }

        $ok = Send-IPCCommand $cmd
        Send-Json $Context ('{"ok":' + (ConvertTo-JsonBool $ok) + '}')
        return
    }

    # ---- 日志列表 ----
    if ($Path -eq '/api/logs') {
        $cfg = $null
        try { $cfg = Get-SyncConfig } catch { }
        $dir = if ($cfg) { Join-Path $here ([string]$cfg.LogDir) } else { Join-Path $here 'logs' }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('{"ok":true,"dir":').Append((ConvertTo-JsonStr $dir)).Append(',"files":[')
        $i = 0
        if (Test-Path -LiteralPath $dir) {
            foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 80)) {
                if ($i -gt 0) { [void]$sb.Append(',') }
                [void]$sb.Append('{"name":').Append((ConvertTo-JsonStr $f.Name))
                [void]$sb.Append(',"size":').Append([long]$f.Length)
                [void]$sb.Append(',"mtime":').Append((ConvertTo-JsonStr $f.LastWriteTime.ToString('MM-dd HH:mm:ss')))
                [void]$sb.Append('}')
                $i++
            }
        }
        [void]$sb.Append(']}')
        Send-Json $Context $sb.ToString()
        return
    }

    # ---- 日志内容 ----
    if ($Path -eq '/api/log') {
        $cfg = $null
        try { $cfg = Get-SyncConfig } catch { }
        $dir = if ($cfg) { Join-Path $here ([string]$cfg.LogDir) } else { Join-Path $here 'logs' }
        $name = ''
        try { $name = [string]$Context.Request.QueryString['name'] } catch { }
        $name = [System.IO.Path]::GetFileName($name)      # 只取文件名，挡住 ..\ 穿越
        $tail = 400
        try { $t = $Context.Request.QueryString['tail']; if ($t) { $tail = [Math]::Max(20, [Math]::Min(3000, [int]$t)) } } catch { }

        if (-not $name -or -not $name.EndsWith('.log')) { Send-Json $Context '{"ok":false,"message":"文件名不合法"}' 400; return }
        $full = Join-Path $dir $name
        if (-not (Test-Path -LiteralPath $full)) { Send-Json $Context '{"ok":false,"message":"文件不存在"}' 404; return }

        try {
            $lines = @(Get-Content -LiteralPath $full -Tail $tail -Encoding UTF8 -ErrorAction Stop)
            $text = ($lines -join "`n")
            $info = Get-Item -LiteralPath $full
            Send-Json $Context ('{"ok":true,"name":' + (ConvertTo-JsonStr $name) +
                ',"size":' + [long]$info.Length +
                ',"mtime":' + (ConvertTo-JsonStr $info.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) +
                ',"text":' + (ConvertTo-JsonStr $text) + '}')
        } catch {
            Send-Json $Context ('{"ok":false,"message":' + (ConvertTo-JsonStr $_.Exception.Message) + '}') 500
        }
        return
    }

    # ---- 配置读取 ----
    if ($Path -eq '/api/config' -and $Method -eq 'GET') {
        try {
            $raw = Get-Content -LiteralPath (Join-Path $here 'config.json') -Raw -Encoding UTF8
            Send-Json $Context ('{"ok":true,"raw":' + (ConvertTo-JsonStr $raw) + '}')
        } catch {
            Send-Json $Context ('{"ok":false,"message":' + (ConvertTo-JsonStr $_.Exception.Message) + '}') 500
        }
        return
    }

    # ---- 配置保存 ----
    if ($Path -eq '/api/config' -and $Method -eq 'POST') {
        $body = Get-RequestBody $Context
        try { $incoming = $body | ConvertFrom-Json } catch { Send-Json $Context '{"ok":false,"message":"请求格式不对"}' 400; return }

        try {
            $path = Join-Path $here 'config.json'
            $cfg = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json

            # ---- v2 任务结构（任务编辑器的保存通道）----
            if ($incoming.PSObject.Properties.Name -contains 'tasks' -and $incoming.tasks) {
                $newTasks = @()
                $ti = 0
                foreach ($t in @($incoming.tasks)) {
                    $ti++
                    $src = ([string]$t.source).Trim().Replace('/', '\')
                    if (-not $src) { Send-Json $Context ('{"ok":false,"message":"任务 ' + $ti + ' 缺少源目录"}') 400; return }
                    if (-not (Test-Path -LiteralPath $src -PathType Container)) { Send-Json $Context ('{"ok":false,"message":"任务 ' + $ti + ' 的源目录不存在：' + $src + '"}') 400; return }

                    $name = ([string]$t.name).Trim()
                    if (-not $name) { $name = '任务 ' + $ti }

                    $dests = @()
                    foreach ($d in @($t.dests)) {
                        $kind = [string]$d.kind
                        if ($kind -eq 'folder') {
                            # 归一化：正斜杠 → 反斜杠（Windows 两种都认，UI/客户端可能传任意一种）
                            $p = ([string]$d.path).Trim().Replace('/', '\')
                            if ($p -notmatch '^[A-Za-z]:\\.+') { Send-Json $Context ('{"ok":false,"message":"文件夹目的地必须是绝对路径（如 D:\\备份）：' + $p + '"}') 400; return }
                            $full = [IO.Path]::GetFullPath($p).TrimEnd('\')
                            if ($full.Length -le 2) { Send-Json $Context '{"ok":false,"message":"文件夹目的地不能是盘根目录"}' 400; return }
                            $driveRoot = $full.Substring(0, 3)
                            $sub = $full.Substring(3).Trim('\')
                            $dests += [pscustomobject]@{ Kind = 'folder'; Path = $full }
                            $null = $driveRoot; $null = $sub
                        } else {
                            $s = $d.serials
                            $sd = ''; $sp = ''; $sv = ''
                            if ($s) {
                                if ($s.PSObject.Properties.Name -contains 'disk')   { $sd = ([string]$s.disk).Trim().ToUpper() }
                                if ($s.PSObject.Properties.Name -contains 'phys')   { $sp = ([string]$s.phys).Trim().ToUpper() }
                                if ($s.PSObject.Properties.Name -contains 'volume') { $sv = ([string]$s.volume).Trim().ToUpper() }
                            }
                            if (-not $sd -and -not $sp -and -not $sv) { Send-Json $Context ('{"ok":false,"message":"任务 ' + $ti + ' 有硬盘目的地缺少序列号（重新在设置里选择一次硬盘）"}') 400; return }
                            $sub = ([string]$d.sub).Trim('\').Replace('/', '\')
                            if ($sub -match '^\s*[A-Za-z]:' -or $sub -match '(^|[\\/])\.\.($|[\\/])' -or -not $sub) {
                                Send-Json $Context ('{"ok":false,"message":"任务 ' + $ti + ' 的备份文件夹名不合法（不能为空、不能是绝对路径或含 ..）"}') 400; return
                            }
                            $dests += [pscustomobject]@{
                                Kind    = 'disk'
                                Label   = ([string]$d.label).Trim()
                                Sub     = $sub
                                Serials = [pscustomobject]@{ Disk = $sd; Phys = $sp; Volume = $sv }
                            }
                        }
                    }
                    $newTasks += [pscustomobject]@{ Name = $name; Source = $src; Dests = $dests }
                }

                if ($cfg.PSObject.Properties.Name -contains 'Tasks') { $cfg.Tasks = $newTasks }
                else { $cfg | Add-Member -NotePropertyName Tasks -NotePropertyValue $newTasks -Force }

                # 同步 legacy 字段（task0 → SourcePath / TargetFolderName），老代码读到的一致
                if ($newTasks.Count -gt 0) {
                    $t0s = [string]$newTasks[0].Source
                    if ($cfg.PSObject.Properties.Name -contains 'SourcePath') { $cfg.SourcePath = $t0s }
                    else { $cfg | Add-Member -NotePropertyName SourcePath -NotePropertyValue $t0s -Force }
                    $d0 = @($newTasks[0].Dests)[0]
                    if ($d0 -and $d0.Kind -eq 'disk') {
                        $t0n = [string]$d0.Sub
                        if ($cfg.PSObject.Properties.Name -contains 'TargetFolderName') { $cfg.TargetFolderName = $t0n }
                        else { $cfg | Add-Member -NotePropertyName TargetFolderName -NotePropertyValue $t0n -Force }
                    }
                }
            }

            if ($incoming.PSObject.Properties.Name -contains 'sourcePath' -and $incoming.sourcePath) {
                $cfg.SourcePath = [string]$incoming.sourcePath
            }
            if ($incoming.PSObject.Properties.Name -contains 'targetFolderName' -and $incoming.targetFolderName) {
                $tn = [string]$incoming.targetFolderName
                if ($tn -match '[\\/]' -or $tn -match '\.\.') { Send-Json $Context '{"ok":false,"message":"目标文件夹名不能含斜杠或 .."}' 400; return }
                if ($tn -eq [string]$cfg.Options.BackupFolderName) { Send-Json $Context '{"ok":false,"message":"目标文件夹不能和备份文件夹同名"}' 400; return }
                $cfg.TargetFolderName = $tn
            }
            if ($incoming.PSObject.Properties.Name -contains 'debounce') {
                $cfg.Options.DebounceSeconds = [Math]::Max(0, [Math]::Min(3600, [int]$incoming.debounce))
            }
            if ($incoming.PSObject.Properties.Name -contains 'folderSyncMinutes') {
                $v = [Math]::Max(0, [Math]::Min(10080, [int]$incoming.folderSyncMinutes))
                if ($cfg.Options.PSObject.Properties.Name -contains 'FolderSyncMinutes') { $cfg.Options.FolderSyncMinutes = $v }
                else { $cfg.Options | Add-Member -NotePropertyName FolderSyncMinutes -NotePropertyValue $v -Force }
            }
            if ($incoming.PSObject.Properties.Name -contains 'threads') {
                $cfg.Options.Threads = [Math]::Max(1, [Math]::Min(64, [int]$incoming.threads))
            }
            if ($incoming.PSObject.Properties.Name -contains 'showWindow') {
                $cfg.Options.ShowProgressWindow = [bool]$incoming.showWindow
            }
            if ($incoming.PSObject.Properties.Name -contains 'miniBarMode') {
                $m = [string]$incoming.miniBarMode
                if (@('auto', 'always', 'never') -notcontains $m) { Send-Json $Context '{"ok":false,"message":"迷你条模式只能是 auto / always / never"}' 400; return }
                if ($cfg.Options.PSObject.Properties.Name -contains 'MiniBarMode') { $cfg.Options.MiniBarMode = $m }
                else { $cfg.Options | Add-Member -NotePropertyName MiniBarMode -NotePropertyValue $m -Force }
            }
            if ($incoming.PSObject.Properties.Name -contains 'syncMode') {
                $m = [string]$incoming.syncMode
                if (@('mirror', 'twoway') -notcontains $m) { Send-Json $Context '{"ok":false,"message":"同步方向只能是 mirror / twoway"}' 400; return }
                if ($cfg.Options.PSObject.Properties.Name -contains 'SyncMode') { $cfg.Options.SyncMode = $m }
                else { $cfg.Options | Add-Member -NotePropertyName SyncMode -NotePropertyValue $m -Force }
            }
            if ($incoming.PSObject.Properties.Name -contains 'guardEnabled') {
                $cfg.Options.SafetyGuard.Enabled = [bool]$incoming.guardEnabled
            }
            if ($incoming.PSObject.Properties.Name -contains 'guardMaxDelete') {
                $cfg.Options.SafetyGuard.MaxDeletePercent = [Math]::Max(1, [Math]::Min(100, [int]$incoming.guardMaxDelete))
            }
            if ($incoming.PSObject.Properties.Name -contains 'excludeDirs' -and $incoming.excludeDirs) {
                $cfg.Options.ExcludeDirs = @($incoming.excludeDirs | ForEach-Object { [string]$_ } | Where-Object { $_ })
            }
            if ($incoming.PSObject.Properties.Name -contains 'excludeFiles' -and $incoming.excludeFiles) {
                $cfg.Options.ExcludeFiles = @($incoming.excludeFiles | ForEach-Object { [string]$_ } | Where-Object { $_ })
            }

            $json = $cfg | ConvertTo-Json -Depth 12
            [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($true)))
            Write-Serve '配置已保存' 'OK'
            Send-Json $Context '{"ok":true,"message":"已保存"}'
        } catch {
            Send-Json $Context ('{"ok":false,"message":' + (ConvertTo-JsonStr $_.Exception.Message) + '}') 500
        }
        return
    }

    # ---- 打开文件夹 ----
    if ($Path -eq '/api/open' -and $Method -eq 'POST') {
        $body = Get-RequestBody $Context
        try { $o = $body | ConvertFrom-Json; $what = [string]$o.what } catch { Send-Json $Context '{"ok":false,"message":"请求格式不对"}' 400; return }
        $target = ''
        $cfg = $null
        try { $cfg = Get-SyncConfig } catch { }
        switch ($what) {
            'logs'   { $target = if ($cfg) { Join-Path $here ([string]$cfg.LogDir) } else { Join-Path $here 'logs' } }
            'source' {
                $target = ''
                try {
                    $ps = Get-SyncPairs -Config $cfg
                    if ($ps.Count -gt 0) { $target = [string]$ps[0].Source }
                } catch { }
                if (-not $target -and $cfg) { $target = [string]$cfg.SourcePath }
            }
            'target' { $target = (Get-DiskSnapshot).Folder }
            'root'   { $target = $here }
        }
        if ($target -and (Test-Path -LiteralPath $target)) {
            try { Start-Process explorer.exe -ArgumentList ('"' + $target + '"') } catch { }
            Send-Json $Context '{"ok":true}'
        } else {
            Send-Json $Context ('{"ok":false,"message":' + (ConvertTo-JsonStr '这个文件夹当前不存在（硬盘可能没插）') + '}')
        }
        return
    }

    # ---- 重启监听 ----
    if ($Path -eq '/api/watch/restart' -and $Method -eq 'POST') {
        Stop-WatchProcess
        Start-Sleep -Milliseconds 300
        Start-WatchProcess
        Send-Json $Context ('{"ok":true,"alive":' + (ConvertTo-JsonBool (Test-WatchRunning)) + '}')
        return
    }

    # ---- 开机自启 ----
    if ($Path -eq '/api/autostart') {
        if ($Method -eq 'POST') {
            $body = Get-RequestBody $Context
            try { $o = $body | ConvertFrom-Json; $want = [bool]$o.enabled } catch { Send-Json $Context '{"ok":false,"message":"请求格式不对"}' 400; return }
            $r = if ($want) { Enable-AutoStart } else { Disable-AutoStart }
            $now = Test-AutoStartEnabled
            Send-Json $Context ('{"ok":' + (ConvertTo-JsonBool $r.Ok) + ',"enabled":' + (ConvertTo-JsonBool $now) + ',"message":' + (ConvertTo-JsonStr $r.Message) + '}')
            return
        }
        Send-Json $Context ('{"ok":true,"enabled":' + (ConvertTo-JsonBool (Test-AutoStartEnabled)) + '}')
        return
    }

    # ---- 版本历史（双向同步的删除/覆盖保护快照，存在硬盘根目录 _SyncHistory）----
    if ($Path -eq '/api/history') {
        $diskSnap = Get-DiskSnapshot
        if (-not $diskSnap.Present -or -not $diskSnap.Folder) {
            Send-Json $Context '{"ok":true,"present":false,"snaps":[]}'
            return
        }
        $histRoot = Join-Path (Split-Path -Parent ([string]$diskSnap.Folder)) '_SyncHistory'
        if (-not (Test-Path -LiteralPath $histRoot)) {
            Send-Json $Context '{"ok":true,"present":true,"snaps":[]}'
            return
        }
        $parts = New-Object System.Collections.ArrayList
        $snaps = Get-ChildItem -LiteralPath $histRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending | Select-Object -First 5
        foreach ($s in $snaps) {
            $fs = @(Get-ChildItem -LiteralPath $s.FullName -Recurse -File -ErrorAction SilentlyContinue)
            $bytes = [long]0
            foreach ($f in $fs) { $bytes += $f.Length }
            [void]$parts.Add(('{"name":' + (ConvertTo-JsonStr $s.Name) + ',"files":' + $fs.Count + ',"bytes":' + $bytes + '}'))
        }
        Send-Json $Context ('{"ok":true,"present":true,"snaps":[' + ($parts -join ',') + ']}')
        return
    }

    if ($Path -eq '/api/history/files') {
        $snap = ''
        try { $snap = [string]$Context.Request.QueryString['snap'] } catch { }
        if ($snap -notmatch '^\d{8}-\d{6}$') { Send-Json $Context '{"ok":false,"message":"快照名不合法"}' 400; return }
        $diskSnap = Get-DiskSnapshot
        if (-not $diskSnap.Present -or -not $diskSnap.Folder) { Send-Json $Context '{"ok":false,"message":"硬盘不在"}' 400; return }
        $histRoot = Join-Path (Split-Path -Parent ([string]$diskSnap.Folder)) '_SyncHistory'
        $dir = Join-Path $histRoot $snap
        if (-not (Test-Path -LiteralPath $dir)) { Send-Json $Context '{"ok":false,"message":"快照不存在"}' 404; return }
        $parts = New-Object System.Collections.ArrayList
        $fs = @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 300)
        foreach ($f in $fs) {
            $rel = $f.FullName.Substring($dir.TrimEnd('\').Length + 1)
            [void]$parts.Add(('{"rel":' + (ConvertTo-JsonStr $rel) + ',"size":' + $f.Length + '}'))
        }
        Send-Json $Context ('{"ok":true,"snap":' + (ConvertTo-JsonStr $snap) + ',"total":' + @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue).Count + ',"files":[' + ($parts -join ',') + ']}')
        return
    }

    if ($Path -eq '/api/history/restore' -and $Method -eq 'POST') {
        $body = Get-RequestBody $Context
        try { $o = $body | ConvertFrom-Json; $snap = [string]$o.snap; $rel = [string]$o.rel } catch { Send-Json $Context '{"ok":false,"message":"请求格式不对"}' 400; return }
        if ($snap -notmatch '^\d{8}-\d{6}$') { Send-Json $Context '{"ok":false,"message":"快照名不合法"}' 400; return }
        if (-not $rel -or $rel -match '[\\/]\.\.([\\/]|$)' -or $rel -match '^\.\.' -or $rel -match '^[\\/]') { Send-Json $Context '{"ok":false,"message":"文件路径不合法"}' 400; return }
        $diskSnap = Get-DiskSnapshot
        if (-not $diskSnap.Present -or -not $diskSnap.Folder) { Send-Json $Context '{"ok":false,"message":"硬盘不在，无法恢复"}' 400; return }
        $cfg = $null
        try { $cfg = Get-SyncConfig } catch { }
        if (-not $cfg) { Send-Json $Context '{"ok":false,"message":"读不到配置"}' 500; return }
        $histRoot = Join-Path (Split-Path -Parent ([string]$diskSnap.Folder)) '_SyncHistory'
        $src = Join-Path (Join-Path $histRoot $snap) $rel
        if (-not (Test-Path -LiteralPath $src)) { Send-Json $Context '{"ok":false,"message":"快照里没有这个文件"}' 404; return }
        $fail = @()
        foreach ($rootDir in @([string]$diskSnap.Folder, [string]$cfg.SourcePath)) {
            $dst = Join-Path $rootDir $rel
            $dstDir = Split-Path -Parent $dst
            try {
                if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
                Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
            } catch { $fail += $rootDir }
        }
        if ($fail.Count -gt 0) {
            Send-Json $Context ('{"ok":false,"message":' + (ConvertTo-JsonStr ('恢复失败：' + ($fail -join '、'))) + '}')
            return
        }
        Write-Serve ('已从历史快照 ' + $snap + ' 恢复：' + $rel) 'OK'
        Send-Json $Context '{"ok":true,"message":"已恢复到本地和硬盘"}'
        return
    }

    Send-Json $Context '{"ok":false,"message":"接口不存在"}' 404
}

function Invoke-Request {
    param($Context)

    $req = $Context.Request
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod

    # 只认本机来源：挡掉 DNS rebinding（外站把域名解析到 127.0.0.1 来打本地服务）
    $hostHdr = [string]$req.Headers['Host']
    $hostName = ($hostHdr -split ':')[0]
    if ($hostName -ne '127.0.0.1' -and $hostName -ne 'localhost') {
        Send-Text $Context '{"ok":false,"message":"forbidden"}' 'application/json; charset=utf-8' 403
        return
    }

    # 写操作要求自定义头：跨站表单提交带不了这个头，挡掉 CSRF
    if ($method -eq 'POST') {
        if ([string]$req.Headers['X-DiskSync'] -ne '1') {
            Send-Text $Context '{"ok":false,"message":"missing X-DiskSync header"}' 'application/json; charset=utf-8' 403
            return
        }
    }

    if ($path -like '/api/*') {
        Invoke-Api -Context $Context -Path $path -Method $method
        return
    }

    # 静态资源
    if ($script:StaticRoutes.ContainsKey($path)) {
        $file = Join-Path $script:WebDir $script:StaticRoutes[$path]
        if (Test-Path -LiteralPath $file) { Send-File $Context $file; return }
    }

    # 其它静态文件（限定在 console 目录内）
    $rel = $path.TrimStart('/')
    if ($rel) {
        try { $rel = [System.Uri]::UnescapeDataString($rel) } catch { }
        $full = Join-Path $script:WebDir $rel
        try {
            $webFull = [System.IO.Path]::GetFullPath($script:WebDir + [System.IO.Path]::DirectorySeparatorChar)
            $fileFull = [System.IO.Path]::GetFullPath($full)
            if ($fileFull.StartsWith($webFull, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fileFull -PathType Leaf)) {
                Send-File $Context $fileFull
                return
            }
        } catch { }
    }

    # 前端是单页应用，路由都由前端处理
    $index = Join-Path $script:WebDir 'index.html'
    if (Test-Path -LiteralPath $index) { Send-File $Context $index; return }
    Send-Text $Context '{"ok":false,"message":"console 目录里没有 index.html"}' 'application/json; charset=utf-8' 500
}

# ═══════════════════════════════════════════════════════════════
# 启动
# ═══════════════════════════════════════════════════════════════
$suggest = if ($Port -gt 0) { $Port } else { Get-SavedPort }

# 已经在跑就直接把浏览器叫出来，不再起第二个
if (-not (Test-PortFree $suggest) -and (Test-ExistingInstance $suggest)) {
    $url = 'http://127.0.0.1:{0}/' -f $suggest
    Write-Serve ('控制台已在运行：' + $url) 'INFO'
    if (-not $NoBrowser) { try { Start-Process $url } catch { } }
    exit 0
}

$script:Port = 0
$candidates = @()
if ($Port -gt 0) { $candidates = @($Port) } else { $candidates = @($suggest) + (7788..7800) }
foreach ($p in ($candidates | Select-Object -Unique)) {
    if (Test-PortFree $p) { $script:Port = $p; break }
}
if ($script:Port -eq 0) {
    Write-Serve '没有可用端口（7788~7800 全被占用）' 'ERROR'
    exit 1
}
Save-Port $script:Port

if (-not (Test-Path -LiteralPath $script:WebDir)) {
    Write-Serve ('找不到网页目录：' + $script:WebDir) 'ERROR'
    exit 1
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add(("http://127.0.0.1:{0}/" -f $script:Port))
try {
    $listener.Start()
} catch {
    Write-Serve ('端口启动失败：' + $_.Exception.Message) 'ERROR'
    exit 1
}

$url = 'http://127.0.0.1:{0}/' -f $script:Port
Write-Serve ('控制台已启动：' + $url) 'OK'

Start-WatchProcess

if (-not $NoBrowser) {
    Start-Sleep -Milliseconds 400
    try { Start-Process $url } catch { Write-Serve ('打开浏览器失败，请手动访问 ' + $url) 'WARN' }
}

$lastWatchCheck = Get-Date

try {
    while ($script:Running -and $listener.IsListening) {
        $async = $null
        try { $async = $listener.BeginGetContext($null, $null) } catch { break }

        # 等请求，同时留出时间做后台检查
        while ($script:Running -and -not $async.AsyncWaitHandle.WaitOne(250)) {
            if (((Get-Date) - $lastWatchCheck).TotalSeconds -ge 6) {
                $lastWatchCheck = Get-Date
                if (-not (Test-WatchRunning) -and -not $NoWatch) {
                    if (Test-RecentShutdown) {
                        # 监听是主动退出的（托盘「退出」）：整个控制台一起停，
                        # 不许复活 —— 复活就会多出一个托盘图标。
                        Write-Serve '监听进程主动退出，控制台一并停止' 'INFO'
                        $script:Running = $false
                    } elseif ($script:WatchRestarts -lt 5) {
                        $script:WatchRestarts++
                        Write-Serve ('监听进程不见了，第 {0} 次重启' -f $script:WatchRestarts) 'WARN'
                        Start-WatchProcess
                    } else {
                        Write-Serve '监听进程连续多次退出，不再自动重启（网页里可以手动重启）' 'ERROR'
                    }
                }
            }
        }
        if (-not $script:Running) { break }
        if (-not $async.AsyncWaitHandle.WaitOne(0)) { continue }

        $ctx = $null
        try { $ctx = $listener.EndGetContext($async) } catch { continue }
        if (-not $ctx) { continue }

        try { Invoke-Request -Context $ctx }
        catch {
            Write-Serve ('请求处理异常：' + $_.Exception.Message) 'ERROR'
            try { Send-Text $ctx '{"ok":false,"message":"internal error"}' 'application/json; charset=utf-8' 500 } catch { }
        }
        try { $ctx.Response.Close() } catch { }
    }
}
finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    Stop-WatchProcess
    Write-Serve '控制台已停止' 'INFO'
}
