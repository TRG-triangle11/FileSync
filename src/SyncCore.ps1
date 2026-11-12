#Requires -Version 5.1
<#
    SyncCore.ps1  -  FileSync 核心函数库
    由 Sync-Now.ps1 / Watch-FileSync.ps1 通过 dot-source 引入，不单独运行。
#>

$script:RootDir    = $PSScriptRoot
$script:ConfigPath = Join-Path $script:RootDir 'config.json'
$script:HwPath     = Join-Path $script:RootDir 'hardware.json'
$script:StatePath  = Join-Path $script:RootDir 'state.json'
$script:SyncMutex  = $null

# ============================================================
# 日志
# ============================================================
function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$LogFile
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'OK'    { Write-Host $line -ForegroundColor Green }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line -ForegroundColor Gray }
    }
    if ($LogFile) {
        try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
    # 网页控制台的「活动」区跟着日志走，不用再单独维护一套
    if (Get-Command Push-UIActivity -ErrorAction SilentlyContinue) {
        try { Push-UIActivity -Level $Level -Msg $Message } catch { }
    }
}

# ============================================================
# 配置读写
# ============================================================
function Get-SyncConfig {
    param([string]$Path = $script:ConfigPath)
    if (-not (Test-Path -LiteralPath $Path)) { throw "config.json 不存在：$Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not $raw) { throw "config.json 内容为空：$Path" }
    $cfg = $raw | ConvertFrom-Json

    if (-not $cfg.Options) { $cfg | Add-Member -NotePropertyName Options -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not $cfg.LogDir)  { $cfg | Add-Member -NotePropertyName LogDir  -NotePropertyValue 'logs' -Force }

    # ---- v2 多任务模型 ----
    # Tasks[]: { Name, Source, Dests[] }
    # Dests[]: { Kind='disk', Label, Sub, Serials{Disk,Phys,Volume} } 或 { Kind='folder', Path }
    # 旧版（单源单目标）配置自动迁移：源 → 任务 0，绑定的硬盘 → 目的地 0
    if (-not ($cfg.PSObject.Properties.Name -contains 'Tasks') -or -not $cfg.Tasks) {
        $dests = @()
        if ($cfg.SourcePath -and $cfg.TargetFolderName) {
            $hw = $null
            try { $hw = Get-HardwareInfo } catch { }
            if (Test-HardwareBound $hw) {
                $dests = @([pscustomobject]@{
                    Kind    = 'disk'
                    Label   = [string]$hw.BoundDisplayName
                    Sub     = [string]$cfg.TargetFolderName
                    Serials = [pscustomobject]@{
                        Disk   = [string]$hw.DiskSerialNumber
                        Phys   = [string]$hw.PhysicalDiskSerialNumber
                        Volume = [string]$hw.VolumeSerialNumber
                    }
                })
            }
        }
        $t = [pscustomobject]@{
            Name   = $(if ($cfg.SourcePath) { (Split-Path -Parent $cfg.SourcePath) + ' 备份' } else { '新任务' })
            Source = [string]$cfg.SourcePath
            Dests  = $dests
        }
        if (-not ($cfg.PSObject.Properties.Name -contains 'Tasks')) {
            $cfg | Add-Member -NotePropertyName Tasks -NotePropertyValue @($t) -Force
        } else {
            $cfg.Tasks = @($t)
        }
    }

    # 规整每个任务
    $norm = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($t in @($cfg.Tasks)) {
        $i++
        if (-not ($t.PSObject.Properties.Name -contains 'Name') -or -not [string]$t.Name) {
            $t | Add-Member -NotePropertyName Name -NotePropertyValue ('任务 ' + $i) -Force
        }
        if (-not ($t.PSObject.Properties.Name -contains 'Dests') -or -not $t.Dests) {
            $t | Add-Member -NotePropertyName Dests -NotePropertyValue @() -Force
        }
        foreach ($d in @($t.Dests)) {
            if (-not ($d.PSObject.Properties.Name -contains 'Kind')) {
                $d | Add-Member -NotePropertyName Kind -NotePropertyValue 'disk' -Force
            }
        }
        [void]$norm.Add($t)
    }
    $cfg.Tasks = $norm.ToArray()

    if (-not ($cfg.Options.PSObject.Properties.Name -contains 'FolderSyncMinutes')) {
        $cfg.Options | Add-Member -NotePropertyName FolderSyncMinutes -NotePropertyValue 0 -Force
    }
    return $cfg
}

<#
    Get-SyncPairs
    把 v2 配置摊平成「源 → 目的地」配对清单。每个配对是一次独立的同步：
      · disk 目的地：按序列号三要素找盘，TargetRoot = 卷根
      · folder 目的地：本地任意文件夹（可以是另一块本地盘），TargetRoot = 其所在盘根
    PairId 用于状态文件名（每个配对有自己的基线，互不干扰）。
#>
function Get-SyncPairs {
    param($Config)

    $pairs = New-Object System.Collections.ArrayList
    $ti = 0
    foreach ($t in @($Config.Tasks)) {
        $di = 0
        foreach ($d in @($t.Dests)) {
            $id = 't{0}d{1}' -f $ti, $di
            if ([string]$d.Kind -eq 'folder') {
                $p = [string]$d.Path
                if ($p -and $p.Length -ge 3 -and $p.Substring(1, 1) -eq ':') {
                    $root = ('{0}:\' -f $p.Substring(0, 1).ToUpper())
                    $sub  = $p.TrimEnd('\').Substring(3).Trim('\')
                    if ($sub) {
                        [void]$pairs.Add([pscustomobject]@{
                            PairId = $id; TaskIndex = $ti; DestIndex = $di
                            TaskName = [string]$t.Name; Source = [string]$t.Source
                            DestKind = 'folder'; FixedTargetRoot = $root; Sub = $sub
                            Serials = $null; DestLabel = $p
                        })
                    }
                }
            } else {
                $label = [string]$d.Label
                if (-not $label) { $label = '移动硬盘' }
                [void]$pairs.Add([pscustomobject]@{
                    PairId = $id; TaskIndex = $ti; DestIndex = $di
                    TaskName = [string]$t.Name; Source = [string]$t.Source
                    DestKind = 'disk'; FixedTargetRoot = ''; Sub = [string]$d.Sub
                    Serials = $d.Serials; DestLabel = $label
                })
            }
            $di++
        }
        $ti++
    }
    return ,$pairs.ToArray()
}

# 每个配对独立的状态文件（保存各自上次成功同步的源文件数基线）
function Set-PairStatePath {
    param($Pair)
    $dir = Join-Path $script:RootDir '_ipc\state'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:StatePath = Join-Path $dir ($Pair.PairId + '.json')
}

# 目的地是否可用：硬盘目的地按序列号三要素找盘；文件夹目的地看路径存在
function Test-DestAvailable {
    param($Pair)
    if ($Pair.DestKind -eq 'folder') {
        return (Test-Path -LiteralPath ([string]$Pair.FixedTargetRoot))
    }
    $s = $Pair.Serials
    if (-not $s) { return $false }
    $wantDisk   = ([string]$s.Disk).Trim().ToUpper()
    $wantPhys   = ([string]$s.Phys).Trim().ToUpper()
    $wantVolume = ([string]$s.Volume).Trim().ToUpper()
    if (-not $wantDisk -and -not $wantPhys -and -not $wantVolume) { return $false }

    if ($wantDisk) {
        foreach ($d in (Get-Disk -ErrorAction SilentlyContinue)) {
            $v = ([string]$d.SerialNumber).Trim().ToUpper()
            if ($v -and $v -eq $wantDisk) { return $true }
        }
    }
    if ($wantPhys) {
        foreach ($p in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            $v = ([string]$p.SerialNumber).Trim().ToUpper()
            if ($v -and $v -eq $wantPhys) { return $true }
        }
    }
    if ($wantVolume) {
        foreach ($v in (Get-Volume -ErrorAction SilentlyContinue)) {
            if (-not $v.DriveLetter) { continue }
            $sv = ([string]$v.SerialNumber).Trim().ToUpper()
            if ($sv -and $sv -eq $wantVolume) { return $true }
        }
    }
    return $false
}

function Get-HardwareInfo {
    param([string]$Path = $script:HwPath)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not $raw) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Test-HardwareBound {
    param($Hardware)
    if (-not $Hardware) { return $false }
    if ($Hardware.DiskSerialNumber)         { return $true }
    if ($Hardware.PhysicalDiskSerialNumber) { return $true }
    if ($Hardware.VolumeSerialNumber)       { return $true }
    return $false
}

# ============================================================
# 磁盘 / 卷枚举
# ============================================================
function Get-VolumeList {
    $out = New-Object System.Collections.ArrayList
    foreach ($v in (Get-Volume -ErrorAction SilentlyContinue)) {
        if (-not $v.DriveLetter) { continue }
        if ([string]$v.DriveType -eq 'CD-ROM') { continue }

        $entry = [pscustomobject]@{
            Letter       = ([string]$v.DriveLetter).ToUpper()
            Label        = [string]$v.FileSystemLabel
            FileSystem   = [string]$v.FileSystem
            DriveType    = [string]$v.DriveType
            SizeBytes    = [long]$v.Size
            FreeBytes    = [long]$v.SizeRemaining
            VolumeSerial = ([string]$v.SerialNumber).ToUpper()
            DiskNumber   = $null
            DiskSerial   = $null
            PhysSerial   = $null
            BusType      = ''
            DiskFriendly = ''
        }

        try {
            $part = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction Stop | Select-Object -First 1
            if ($part) {
                $entry.DiskNumber = $part.DiskNumber
                try {
                    $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
                    if ($disk) {
                        $entry.DiskSerial   = ([string]$disk.SerialNumber).Trim().ToUpper()
                        $entry.BusType      = [string]$disk.BusType
                        $entry.DiskFriendly = [string]$disk.FriendlyName
                    }
                } catch { }
                try {
                    $pd = Get-PhysicalDisk -DeviceNumber $part.DiskNumber -ErrorAction Stop | Select-Object -First 1
                    if ($pd) { $entry.PhysSerial = ([string]$pd.SerialNumber).Trim().ToUpper() }
                } catch { }
            }
        } catch { }

        [void]$out.Add($entry)
    }
    return @($out)
}

<#
    Resolve-TargetDrive
    按 hardware.json 里记录的标识定位移动硬盘。优先级：
      1. 磁盘硬件序列号 (Get-Disk.SerialNumber)
      2. 物理磁盘序列号 (Get-PhysicalDisk.SerialNumber)
      3. 卷序列号 (Get-Volume.SerialNumber)
    盘符永不写死，每次动态解析。
#>
function Resolve-TargetDrive {
    param($Config, $Hardware = $null)

    # Hardware 覆盖：多目标模式下每个目的地带自己的序列号三要素；
    # 不传则回退到 hardware.json（单绑定兼容）
    $hw = if ($Hardware) { $Hardware } else { Get-HardwareInfo }
    if (-not (Test-HardwareBound $hw)) {
        return [pscustomobject]@{
            Ok      = $false
            Code    = 'UNBOUND'
            Message = '该目的地没有绑定硬盘序列号（在设置里编辑任务，为它选择一块硬盘）'
            Volume  = $null
        }
    }

    $wantDisk   = ([string]$hw.DiskSerialNumber).Trim().ToUpper()
    $wantPhys   = ([string]$hw.PhysicalDiskSerialNumber).Trim().ToUpper()
    $wantVolume = ([string]$hw.VolumeSerialNumber).Trim().ToUpper()

    $hits = New-Object System.Collections.ArrayList
    foreach ($v in (Get-VolumeList)) {
        $hit = $false
        if ($wantDisk   -and $v.DiskSerial -and $v.DiskSerial -eq $wantDisk)   { $hit = $true }
        if (-not $hit -and $wantPhys -and $v.PhysSerial -and $v.PhysSerial -eq $wantPhys) { $hit = $true }
        if (-not $hit -and $wantVolume -and $v.VolumeSerial -and $v.VolumeSerial -eq $wantVolume) { $hit = $true }
        if ($hit) { [void]$hits.Add($v) }
    }

    if ($hits.Count -eq 0) {
        return [pscustomobject]@{
            Ok      = $false
            Code    = 'NOTFOUND'
            Message = '目标移动硬盘未插入（未找到序列号匹配的磁盘）'
            Volume  = $null
        }
    }

    # 同一块物理盘可能有多个分区。优先选已经存在目标文件夹的那个，
    # 其次选容量最大的，避免在多分区硬盘上选错卷。
    $chosen = $hits[0]
    if ($hits.Count -gt 1) {
        $folderName = [string]$Config.TargetFolderName
        $withFolder = @()
        foreach ($h in $hits) {
            $probe = Join-Path ('{0}:\' -f $h.Letter) $folderName
            if (Test-Path -LiteralPath $probe) { $withFolder += $h }
        }
        if ($withFolder.Count -gt 0) {
            $chosen = $withFolder[0]
        } else {
            $chosen = @($hits | Sort-Object -Property SizeBytes -Descending)[0]
        }
    }

    return [pscustomobject]@{
        Ok      = $true
        Code    = 'OK'
        Message = "已识别目标硬盘 $($chosen.Letter):"
        Volume  = $chosen
    }
}

# ============================================================
# 同步前置校验（三道安全闸）
# ============================================================
function Test-SyncEnvironment {
    param($Config, $Volume, [string]$FixedTargetRoot = '')

    $src = [string]$Config.SourcePath

    # 闸一：源目录必须存在、可读、非空
    if (-not (Test-Path -LiteralPath $src -PathType Container)) {
        return [pscustomobject]@{ Ok = $false; Message = "源文件夹不存在：$src"; TargetPath = $null; TargetRoot = $null }
    }
    $probe = @(Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue)
    if ($probe.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Message = "源文件夹为空，已中止（防止清空备份目标上的内容）：$src"; TargetPath = $null; TargetRoot = $null }
    }

    # 目标根：folder 目的地直接给盘根；disk 目的地由卷推出
    if ($FixedTargetRoot) {
        $root = $FixedTargetRoot
    } else {
        $root = ('{0}:\' -f $Volume.Letter)
    }
    if (-not (Test-Path -LiteralPath $root)) {
        return [pscustomobject]@{ Ok = $false; Message = "目标磁盘不可访问：$root"; TargetPath = $null; TargetRoot = $null }
    }

    # 闸二：目标必须是子目录，禁止盘根
    $targetPath = Join-Path $root ([string]$Config.TargetFolderName)
    $norm = $targetPath.TrimEnd('\')
    if ($norm.Length -le 3) {
        return [pscustomobject]@{ Ok = $false; Message = "目标路径不能是磁盘根目录：$targetPath"; TargetPath = $null; TargetRoot = $null }
    }

    # 闸二补充：目标子路径允许多级（如 "备份\工作资料"），但不允许 .. 逃出目标根，
    # 也不允许绝对路径 —— /MIR 的 PURGE 会按这个位置执行删除，不能落到意料之外。
    $tf = [string]$Config.TargetFolderName
    if ($tf -match '^\s*[A-Za-z]:' -or $tf -match '(^|[\\/])\.\.($|[\\/])' -or $tf.Trim() -eq '') {
        return [pscustomobject]@{
            Ok = $false
            Message = "目标子路径不合法（不能是绝对路径、不能含 ..）：$tf"
            TargetPath = $null; TargetRoot = $null
        }
    }
    try {
        $full = [IO.Path]::GetFullPath($targetPath).TrimEnd('\')
        $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
        if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Ok = $false
                Message = "目标路径逃出了目标根目录：$targetPath"
                TargetPath = $null; TargetRoot = $null
            }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = "目标路径无法解析：$targetPath"; TargetPath = $null; TargetRoot = $null }
    }

    # 闸二补充：备份目录不能与目标目录同名，也不能落在目标目录内部。
    # 否则备份会被 /MIR 当成"目标端多余内容"删掉，备份等于没做。
    $bf = [string]$Config.Options.BackupFolderName
    if ($bf) {
        if ($bf -match '[\\/]' -or $bf -match '^\s*\.\.') {
            return [pscustomobject]@{
                Ok = $false
                Message = "BackupFolderName 必须是磁盘根目录下的单层文件夹名（不能含 \ 或 /）：$bf"
                TargetPath = $null; TargetRoot = $null
            }
        }
        if ($bf.Trim().ToLowerInvariant() -eq $tf.Trim().ToLowerInvariant()) {
            return [pscustomobject]@{
                Ok = $false
                Message = "BackupFolderName 与 TargetFolderName 不能同名（$bf），否则备份内容会被同步删除"
                TargetPath = $null; TargetRoot = $null
            }
        }
    }

    return [pscustomobject]@{ Ok = $true; Message = ''; TargetPath = $targetPath; TargetRoot = $root }
}

# ============================================================
# 目录比对
# ============================================================
function Test-ExcludedRelPath {
    param(
        [string]$Rel,
        [string[]]$ExcludeDirs,
        [string]$Name,
        [string[]]$ExcludeFiles
    )
    if ($ExcludeDirs -and $ExcludeDirs.Count -gt 0) {
        $parts = $Rel.Split('\')
        $limit = $parts.Length
        if ($Name) { $limit = $parts.Length - 1 }
        for ($i = 0; $i -lt $limit; $i++) {
            foreach ($ed in $ExcludeDirs) {
                if ($parts[$i] -eq $ed) { return $true }
            }
        }
    }
    if ($Name -and $ExcludeFiles -and $ExcludeFiles.Count -gt 0) {
        foreach ($xf in $ExcludeFiles) {
            if ($Name -like $xf) { return $true }
        }
    }
    return $false
}

<#
    Get-FileMap
    遍历目录，返回文件清单、目录清单、枚举错误数。

    错误计数是安全关键：若源端有读不到的目录（权限、占用、路径过长），
    其下文件会被误判成"目标端多余的文件"而遭到删除。调用方必须检查 Errors。
#>
function Get-FileMap {
    param(
        [string]$Root,
        [string[]]$ExcludeDirs,
        [string[]]$ExcludeFiles
    )
    $map  = @{}
    $dirs = New-Object System.Collections.ArrayList
    $errs = New-Object System.Collections.ArrayList

    if (-not (Test-Path -LiteralPath $Root)) {
        return [pscustomobject]@{ Map = $map; Dirs = @(); Errors = 0; ErrorSample = @(); Exists = $false }
    }

    $rootLen = $Root.TrimEnd('\').Length + 1
    $enumErr = $null

    foreach ($d in (Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force -ErrorAction SilentlyContinue -ErrorVariable +enumErr)) {
        $rel = $d.FullName.Substring($rootLen)
        if (Test-ExcludedRelPath -Rel $rel -ExcludeDirs $ExcludeDirs -Name '') { continue }
        [void]$dirs.Add($rel)
    }

    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable +enumErr)) {
        $rel = $f.FullName.Substring($rootLen)
        if (Test-ExcludedRelPath -Rel $rel -ExcludeDirs $ExcludeDirs -Name $f.Name -ExcludeFiles $ExcludeFiles) { continue }
        $map[$rel] = [pscustomobject]@{
            Size  = [long]$f.Length
            Ticks = [long]$f.LastWriteTimeUtc.Ticks
        }
    }

    if ($enumErr) {
        foreach ($e in @($enumErr)) {
            if ($e -and $e.Exception) { [void]$errs.Add($e.Exception.Message) }
        }
    }

    return [pscustomobject]@{
        Map         = $map
        Dirs        = @($dirs)
        Errors      = $errs.Count
        ErrorSample = @($errs | Select-Object -First 5)
        Exists      = $true
    }
}

<#
    Get-MoveDetectOption
    读取 Options.MoveDetect 下的子项，缺失或为 null 时回落到默认值。
    配置整节缺失也不报错，保证旧配置文件能用。
#>
function Get-MoveDetectOption {
    param($Options, [string]$Name, $Default)
    if ($null -eq $Options) { return $Default }
    $md = $Options.MoveDetect
    if ($null -eq $md) { return $Default }
    $v = $md.$Name
    if ($null -eq $v) { return $Default }
    return $v
}

<#
    Get-SampleHash
    移动配对的中速校验：在文件内均匀取 $Points 个点，每点读 $BlockKB，
    首点对齐文件开头、末点对齐文件末尾，全部内容拼成一条 SHA256。
    返回 Hash 带模式前缀：S: 表示采样，F: 表示实际读全文（小文件自动转全文）。
    前缀保证两种模式的哈希值永不相等——采样结果绝不会被当成完整校验结果使用。

    相比原来的"头 64KB + 尾 64KB"，多点采样能识破"头尾相同、中间不同"的伪同文件。
#>
function Get-SampleHash {
    param(
        [string]$Path,
        [long]$Size,
        [int]$Points = 8,
        [int]$BlockKB = 64
    )
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $realSize = [long]$fs.Length
        if ($Size -le 0) { $Size = $realSize }
        if ($Points -lt 2)    { $Points = 2 }
        $block = [int]$BlockKB * 1024
        if ($block -lt 4096) { $block = 4096 }

        # 采样总量覆盖全文时，直接读全文，等价于完整哈希
        if (([long]$Points * $block) -ge $realSize) {
            $hAll = [System.BitConverter]::ToString((Get-Sha256Instance).ComputeHash($fs)) -replace '-', ''
            return [pscustomobject]@{ Hash = ('F:' + $hAll); Full = $true }
        }

        $buf = New-Object byte[] $block
        $sb  = New-Object System.Text.StringBuilder
        [void]$sb.Append($realSize)
        $seen = @{}

        for ($i = 0; $i -lt $Points; $i++) {
            $pos = [long]([Math]::Floor(([double]($realSize - $block)) * $i / ($Points - 1)))
            if ($pos -lt 0) { $pos = 0 }
            if ($seen.ContainsKey($pos)) { continue }
            $seen[$pos] = $true

            [void]$fs.Seek($pos, [System.IO.SeekOrigin]::Begin)
            $n = $fs.Read($buf, 0, $block)
            if ($n -le 0) { continue }

            [void]$sb.Append('|').Append($pos).Append(':')
            [void]$sb.Append([System.BitConverter]::ToString($buf, 0, $n))
        }

        $sha = Get-Sha256Instance
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        $h = [System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', ''
        return [pscustomobject]@{ Hash = ('S:' + $h); Full = $false }
    } catch {
        return $null
    } finally {
        if ($fs) { $fs.Close() }
    }
}

<#
    Get-FullHash
    完整 SHA256：分块流式读取，内存占用固定 2MB，不受文件大小影响。
    每读满 $ProgressStepMB 更新一次进度窗口，让 16GB 文件的校验过程可见。
    读取用 FileShare.ReadWrite，不会阻塞其他程序对该文件的读取。
#>
function Get-FullHash {
    param(
        [string]$Path,
        [string]$Note = '',
        [int]$ProgressStepMB = 256
    )
    $fs  = $null
    try {
        $sha = Get-Sha256Instance

        # 小文件整块读入比较。ReadAllBytes + ComputeHash 实测比流式快约 3 倍，
        # 而这里每次调用都要开一次文件句柄，句柄开销本身超过哈希几十 KB 的成本。
        $len = -1
        try { $len = (New-Object System.IO.FileInfo $Path).Length } catch { $len = -1 }
        if ($len -ge 0 -and $len -le 1048576) {
            $buf = [System.IO.File]::ReadAllBytes($Path)
            return [System.BitConverter]::ToString($sha.ComputeHash($buf)) -replace '-', ''
        }

        $fs  = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $total = [long]$fs.Length

        $bufSize = 1048576
        $inBuf   = New-Object byte[] $bufSize
        $outBuf  = New-Object byte[] $bufSize
        $read    = [long]0
        $step    = [long]$ProgressStepMB * 1MB
        if ($step -le 0) { $step = 268435456 }
        $next    = $step

        while ($true) {
            $n = $fs.Read($inBuf, 0, $bufSize)
            if ($n -le 0) { break }
            [void]$sha.TransformBlock($inBuf, 0, $n, $outBuf, 0)
            $read += $n
            if ($Note -and $read -ge $next -and $total -gt 0) {
                $next = $read + $step
                Update-ProgressUI -Detail (("{0}  完整校验 {1}%  ({2:N0} / {3:N0} MB)" -f $Note, [int](($read * 100) / $total), ($read / 1MB), ($total / 1MB))) -State 'Work'
            }
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return [System.BitConverter]::ToString($sha.Hash) -replace '-', ''
    } catch {
        return $null
    } finally {
        if ($fs)  { $fs.Close() }
    }
}

<#
    Compare-SyncTree
    差异判定规则（与 robocopy 保持一致）：
      - 目标不存在 -> 复制
      - 大小不同   -> 复制
      - 源时间比目标新超过 2 秒 -> 复制（2 秒容差用于兼容 exFAT / FAT32 时间精度）
      - 目标有、源没有 -> 删除
    同时返回：源端缺失的空目录、源端枚举错误数
#>
function Compare-SyncTree {
    param(
        [string]$Source,
        [string]$Target,
        [string[]]$ExcludeDirs,
        [string[]]$ExcludeFiles
    )

    $srcInfo = Get-FileMap -Root $Source -ExcludeDirs $ExcludeDirs -ExcludeFiles $ExcludeFiles
    $dstInfo = Get-FileMap -Root $Target -ExcludeDirs $ExcludeDirs -ExcludeFiles $ExcludeFiles
    $srcMap  = $srcInfo.Map
    $dstMap  = $dstInfo.Map

    $copyItems = New-Object System.Collections.ArrayList
    $copyBytes = [long]0
    $tolerance = [long]20000000   # 2 秒 = 2000万 ticks

    foreach ($k in @($srcMap.Keys)) {
        $s = $srcMap[$k]
        $need = $false
        if (-not $dstMap.ContainsKey($k)) {
            $need = $true
        } else {
            $d = $dstMap[$k]
            if ($s.Size -ne $d.Size -or ($s.Ticks - $d.Ticks) -gt $tolerance) { $need = $true }
        }
        if ($need) {
            [void]$copyItems.Add([pscustomobject]@{ Rel = $k; Size = $s.Size; Ticks = $s.Ticks })
            $copyBytes += $s.Size
        }
    }

    $deleteItems = New-Object System.Collections.ArrayList
    $deleteBytes = [long]0
    foreach ($k in @($dstMap.Keys)) {
        if (-not $srcMap.ContainsKey($k)) {
            [void]$deleteItems.Add([pscustomobject]@{ Rel = $k; Size = $dstMap[$k].Size; Ticks = $dstMap[$k].Ticks })
            $deleteBytes += $dstMap[$k].Size
        }
    }

    $missingDirs = New-Object System.Collections.ArrayList
    $dstDirSet = @{}
    foreach ($d in @($dstInfo.Dirs)) { $dstDirSet[$d] = $true }
    foreach ($d in @($srcInfo.Dirs)) {
        if (-not $dstDirSet.ContainsKey($d)) { [void]$missingDirs.Add($d) }
    }

    return [pscustomobject]@{
        SourceCount       = $srcMap.Count
        TargetCount       = $dstMap.Count
        SourceDirs        = @($srcInfo.Dirs).Count
        SrcMap            = $srcMap
        DstMap            = $dstMap
        CopyItems         = @($copyItems)
        ToCopy            = @($copyItems | ForEach-Object { $_.Rel })
        CopyBytes         = $copyBytes
        DeleteItems       = @($deleteItems)
        ToDelete          = @($deleteItems | ForEach-Object { $_.Rel })
        DeleteBytes       = $deleteBytes
        MissingDirs       = @($missingDirs)
        SourceErrors      = $srcInfo.Errors
        SourceErrorSample = $srcInfo.ErrorSample
        TargetErrors      = $dstInfo.Errors
    }
}

<#
    Get-ParentRel
    取相对路径的父目录，纯字符串操作。

    不用 Split-Path -Parent 是为了性能：cmdlet 调用每次约 0.5 ms，
    目录级识别要对每个文件遍历每一级祖先，累计上千次，实测能差出 3 秒以上。
#>
function Get-ParentRel {
    param([string]$Path)
    if (-not $Path) { return '' }
    $i = $Path.LastIndexOf('\')
    if ($i -lt 0) { return '' }
    return $Path.Substring(0, $i)
}

<#
    Get-Sha256Instance
    复用一个 SHA256 实例。

    ComputeHash / TransformFinalBlock 每次调用内部都会重置状态，单线程下可安全复用。
    目录级校验会连续哈希上千个小文件，每次 Create + Dispose 的累计开销很可观。
#>
function Get-Sha256Instance {
    if ($null -eq $script:DSSha256) {
        $script:DSSha256 = [System.Security.Cryptography.SHA256]::Create()
    }
    return $script:DSSha256
}

<#
    Get-DirFileCounts
    统计每个目录（含其所有子目录）下的文件总数。
    用来判断"目标端某目录是否整体消失"：该目录下全部文件都在待删清单里，才算整体消失。

    这里把父目录解析内联成 LastIndexOf，不调用 Get-ParentRel：
    PowerShell 函数调用本身约 0.5 ms，上千次累计能到 1.3 秒，换来的可读性不值得。
#>
function Get-DirFileCounts {
    param($Map)
    $counts = @{}
    if ($null -eq $Map) { return $counts }
    foreach ($k in $Map.Keys) {
        $i = $k.LastIndexOf('\')
        while ($i -ge 0) {
            $d = $k.Substring(0, $i)
            if ($counts.ContainsKey($d)) { $counts[$d] = $counts[$d] + 1 }
            else { $counts[$d] = 1 }
            $i = $d.LastIndexOf('\')
        }
    }
    return $counts
}

<#
    Get-DirSignature
    为"某个目录下整棵子树的文件清单"生成结构签名。
    签名的输入只有两项：相对该目录的子路径、文件大小。按子路径排序后拼接再取 SHA256。

    不含修改时间——时间单独逐文件比对，因为时间要按容差判断，无法进签名。
#>
function Get-DirSignature {
    param($Items)
    $sb = New-Object System.Text.StringBuilder
    foreach ($it in @($Items | Sort-Object -Property Sub)) {
        [void]$sb.Append(([string]$it.Sub).ToLowerInvariant()).Append('|').Append($it.Size).Append(';')
    }
    $sha = Get-Sha256Instance
    $b = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    return ([System.BitConverter]::ToString($sha.ComputeHash($b)) -replace '-', '')
}

<#
    Test-DirContentMatch
    目录级校验用：逐文件核对两端内容是否一致，全部一致才返回 $true。

    整个目录在一次函数调用内校验完，不逐文件回头调 Get-FullHash。
    原因：PowerShell 函数调用本身约 0.5–1 ms，600 个文件就是 1200 次调用、1 秒以上，
    比 SHA256 计算本身还贵。≤4 MB 的文件直接整块读入比较（实测比流式快约 3 倍），
    更大的走流式，避免一次占掉几百 MB 内存。
#>
function Test-DirContentMatch {
    param(
        $Items,
        [string]$SourcePrefix,
        [string]$TargetPrefix,
        [string]$FromDir,
        [long]$InlineLimit = 4194304
    )
    $sha = Get-Sha256Instance
    $fromPrefix = ''
    if ($FromDir) { $fromPrefix = $FromDir + '\' }

    foreach ($it in $Items) {
        $a = $SourcePrefix + [string]$it.Rel
        $b = $TargetPrefix + $fromPrefix + [string]$it.Sub
        try {
            $la = (New-Object System.IO.FileInfo $a).Length
            $lb = (New-Object System.IO.FileInfo $b).Length
            if ($la -ne $lb) { return $false }

            if ($la -le $InlineLimit) {
                $ba = [System.IO.File]::ReadAllBytes($a)
                $bb = [System.IO.File]::ReadAllBytes($b)
                $ha = [System.BitConverter]::ToString($sha.ComputeHash($ba))
                $hb = [System.BitConverter]::ToString($sha.ComputeHash($bb))
                if ($ha -ne $hb) { return $false }
            } else {
                $fa = Get-FullHash -Path $a
                $fb = Get-FullHash -Path $b
                if (-not $fa -or -not $fb -or $fa -ne $fb) { return $false }
            }
        } catch {
            return $false
        }
    }
    return $true
}

<#
    Find-MovedDirs
    目录级移动识别：整个子目录被搬到新位置（重新分类），内部文件一个都没变。

    为什么要单独做这一层：文件级配对按"大小分组 + 逐对哈希"搜索，1000 个文件重排目录会产生
    1000 次配对、每个都要读内容算哈希。50 GB 的目录整体搬走，光校验就要读 100 GB，比重新复制还慢。
    目录级识别用结构签名一次算完，命中后直接生成确定性的重命名清单，零搜索、零内容读取。

    命中条件（同时满足）：
      1. 目标端目录 D 整体消失 —— D 下全部文件都在待删清单里
      2. 源端目录 S 整体新增 —— S 下全部文件都在待复制清单里
      3. S 与 D 的结构签名相同 —— 子树内每个文件的相对路径与大小完全一一对应
      4. 对应文件的修改时间相差 ≤ 2 秒
      5. 文件数 ≥ MinDirFiles（默认 2，单个文件交给文件级配对）

    校验等级：DirMoveVerify=auto 时，子树总字节 ≤ FullMaxMB 才做完整哈希，否则只做结构校验。
    结构校验的约束已经很强——整棵子树的文件名、层级、大小、时间全部一一对应，且两端目录整体
    消失与新增同时成立，正常使用中只有"同一批文件被整目录搬走"能同时满足。超过阈值的超大目录
    若做完整哈希要读两倍数据，反而比重新复制更慢。

    父目录优先匹配：若 A 整体搬到 B、A 下还有 A\x 也整体搬，先匹配 A 可以一次覆盖全部，
    子目录的候选因文件已被占用会自动跳过。
#>
function Find-MovedDirs {
    param(
        $CopyItems,
        $DeleteItems,
        $SourceMap,
        $TargetMap,
        [string]$SourceRoot,
        [string]$TargetRoot,
        $Options = $null
    )

    $tolerance = [long]20000000
    $minFiles  = [int](Get-MoveDetectOption    $Options 'MinDirFiles'    2)
    $verify    = [string](Get-MoveDetectOption $Options 'DirMoveVerify'  'auto')
    $fullMaxMB = [long](Get-MoveDetectOption   $Options 'FullMaxMB'      2048)
    if ($minFiles -lt 1) { $minFiles = 2 }
    $hashLimit = [long]0
    if ($fullMaxMB -gt 0) { $hashLimit = $fullMaxMB * 1MB }

    if (@($CopyItems).Count -eq 0 -or @($DeleteItems).Count -eq 0) {
        return [pscustomobject]@{
            Pairs = @(); RestCopy = @($CopyItems); RestDelete = @($DeleteItems); DirCount = 0
        }
    }

    # 校验强度按"本次目录级移动涉及的总字节"判断，不按单个目录判断。
    # 否则把一个 68 GB 的大目录拆成若干 1 GB 的小目录时，每个都会各自达标去做完整哈希，
    # 合计要读 136 GB，比重新复制一遍还慢。
    $allBytes = [long]0
    foreach ($ci in @($CopyItems)) { $allBytes += $ci.Size }
    $wantHashAll = ($verify -eq 'always') -or (($verify -eq 'auto') -and $hashLimit -gt 0 -and $allBytes -le $hashLimit)

    # 按"目录含整棵子树"聚合：同一个文件会归属到它的每一级祖先目录
    # 父目录解析内联，避免每层一次函数调用
    $delByDir = @{}
    foreach ($di in @($DeleteItems)) {
        $rel = [string]$di.Rel
        $i = $rel.LastIndexOf('\')
        while ($i -ge 0) {
            $d = $rel.Substring(0, $i)
            if (-not $delByDir.ContainsKey($d)) { $delByDir[$d] = New-Object System.Collections.ArrayList }
            [void]$delByDir[$d].Add([pscustomobject]@{
                Sub = $rel.Substring($i + 1); Size = $di.Size; Ticks = $di.Ticks; Rel = $rel
            })
            $i = $d.LastIndexOf('\')
        }
    }
    $copyByDir = @{}
    foreach ($ci in @($CopyItems)) {
        $rel = [string]$ci.Rel
        $i = $rel.LastIndexOf('\')
        while ($i -ge 0) {
            $d = $rel.Substring(0, $i)
            if (-not $copyByDir.ContainsKey($d)) { $copyByDir[$d] = New-Object System.Collections.ArrayList }
            [void]$copyByDir[$d].Add([pscustomobject]@{
                Sub = $rel.Substring($i + 1); Size = $ci.Size; Ticks = $ci.Ticks; Rel = $rel
            })
            $i = $d.LastIndexOf('\')
        }
    }

    $srcPrefix = $SourceRoot.TrimEnd('\') + '\'
    $tgtPrefix = $TargetRoot.TrimEnd('\') + '\'
    $srcCounts = Get-DirFileCounts -Map $SourceMap
    $dstCounts = Get-DirFileCounts -Map $TargetMap

    # 目标端"整体消失"的目录，按签名建索引
    $delSig = @{}
    foreach ($d in @($delByDir.Keys)) {
        if (-not $dstCounts.ContainsKey($d)) { continue }
        if ([int]$dstCounts[$d] -ne @($delByDir[$d]).Count) { continue }
        $sig = Get-DirSignature -Items $delByDir[$d]
        if (-not $delSig.ContainsKey($sig)) { $delSig[$sig] = New-Object System.Collections.ArrayList }
        [void]$delSig[$sig].Add($d)
    }

    # 源端"整体新增"的目录，作为候选
    $cands = New-Object System.Collections.ArrayList
    foreach ($d in @($copyByDir.Keys)) {
        $items = @($copyByDir[$d])
        if ($items.Count -lt $minFiles) { continue }
        if (-not $srcCounts.ContainsKey($d)) { continue }
        if ([int]$srcCounts[$d] -ne $items.Count) { continue }
        $sig = Get-DirSignature -Items $items
        if (-not $delSig.ContainsKey($sig)) { continue }
        $bytes = [long]0
        foreach ($it in $items) { $bytes += $it.Size }
        [void]$cands.Add([pscustomobject]@{
            ToRel = $d
            Sig   = $sig
            Count = $items.Count
            Bytes = $bytes
            Depth = @($d.Split('\')).Count
        })
    }

    # 父目录优先（层级浅的先匹配），同层级按文件数从多到少
    $cands = @($cands | Sort-Object -Property Count -Descending | Sort-Object -Property Depth)

    $pairs     = New-Object System.Collections.ArrayList
    $usedDelD  = @{}
    $usedCopy  = @{}
    $usedDel   = @{}
    $dirCount  = 0
    $hashRuns  = 0

    foreach ($c in $cands) {
        $items = @($copyByDir[$c.ToRel])

        $busy = $false
        foreach ($it in $items) { if ($usedCopy.ContainsKey($it.Rel)) { $busy = $true; break } }
        if ($busy) { continue }

        $picked = $null
        foreach ($d in @($delSig[$c.Sig])) {
            if ($usedDelD.ContainsKey($d)) { continue }
            $ditems = @($delByDir[$d])

            $b2 = $false
            foreach ($it in $ditems) { if ($usedDel.ContainsKey($it.Rel)) { $b2 = $true; break } }
            if ($b2) { continue }

            # 逐文件核对修改时间容差
            $m = @{}
            foreach ($it in $ditems) { $m[[string]$it.Sub.ToLowerInvariant()] = $it }
            $ok = $true
            foreach ($it in $items) {
                $k = [string]$it.Sub.ToLowerInvariant()
                if (-not $m.ContainsKey($k)) { $ok = $false; break }
                if ([Math]::Abs([long]$m[$k].Ticks - [long]$it.Ticks) -gt $tolerance) { $ok = $false; break }
            }
            if (-not $ok) { continue }

            $picked = $d
            break
        }
        if (-not $picked) { continue }

        # 校验等级
        $level = 'STRUCT'
        if ($wantHashAll) {
            $hashRuns++
            Update-ProgressUI -Detail (("目录校验 {0} / {1}：{2}" -f $hashRuns, $c.Count, $c.ToRel)) -State 'Work'
            if (-not (Test-DirContentMatch -Items $items -SourcePrefix $srcPrefix -TargetPrefix $tgtPrefix -FromDir $picked)) { continue }
            $level = 'FULL'
        }

        $usedDelD[$picked] = $true
        $dirCount++
        foreach ($it in $items) {
            $usedCopy[$it.Rel] = $true
            [void]$pairs.Add([pscustomobject]@{
                FromRel = ($picked + '\' + $it.Sub)
                ToRel   = $it.Rel
                FromDir = $picked
                ToDir   = $c.ToRel
                Size    = $it.Size
                Verify  = $level
                IsDir   = $true
            })
        }
        foreach ($it in @($delByDir[$picked])) { $usedDel[$it.Rel] = $true }
    }

    $restCopy = New-Object System.Collections.ArrayList
    foreach ($ci in @($CopyItems)) { if (-not $usedCopy.ContainsKey($ci.Rel)) { [void]$restCopy.Add($ci) } }
    $restDel = New-Object System.Collections.ArrayList
    foreach ($di in @($DeleteItems)) { if (-not $usedDel.ContainsKey($di.Rel)) { [void]$restDel.Add($di) } }

    if ($dirCount -gt 0 -and -not $wantHashAll -and $verify -eq 'auto') {
        Write-Log ("目录级校验：本次涉及 {0:N2} GB，超过 FullMaxMB={1}，改用结构签名校验（不读文件内容）" -f ($allBytes / 1GB), $fullMaxMB) -Level INFO
    }

    return [pscustomobject]@{
        Pairs      = @($pairs)
        RestCopy   = @($restCopy)
        RestDelete = @($restDel)
        DirCount   = $dirCount
    }
}

<#
    Find-MovedPairs
    识别"同一文件被移动或所在目录被改名"的情况。
    命中后直接在目标端做重命名，而不是重新传输整份文件——对 16GB 这类大文件意义很大。

    判定分四层，全部通过才算同一文件：
      L1 大小完全相同（先按大小分组，只在这个组内配对）
      L2 修改时间相差 ≤ 2 秒
      L3 多点采样哈希一致（8 点 × 64KB，首尾对齐；小文件自动转全文）
      L4 完整 SHA256 一致（受 HashMode / FullMaxMB 控制）

    L3 的作用是压掉绝大多数误判、且代价极低；L4 才是最终定论。
    采样哈希带 S:/F: 前缀，两种模式的摘要永不可能相等，
    因此采样结果绝不会被误当成完整校验结果。

    为什么必须做内容校验：配对成功后目标端是"重命名"，源端文件不再进入复制队列。
    若把 A 误判成 B，硬盘上的 B 就是错的内容，而且因为大小时间都近似，下次同步也查不出来。
    这是唯一会静默损坏数据的地方，所以校验强度按最严处理。

    安全兜底：同一大小档位的候选对超过 MaxPairCandidates（默认 64）时跳过配对，
    改为常规"复制 + 删除"，宁可慢也不冒批量误判的风险。
#>
function Find-MovedPairs {
    param(
        $CopyItems,
        $DeleteItems,
        [string]$SourceRoot,
        [string]$TargetRoot,
        $Options = $null
    )

    $tolerance = [long]20000000
    $mode      = [string](Get-MoveDetectOption $Options 'HashMode'            'full')
    $fullMaxMB = [long](Get-MoveDetectOption   $Options 'FullMaxMB'           2048)
    $points    = [int](Get-MoveDetectOption    $Options 'SamplePoints'        8)
    $blockKB   = [int](Get-MoveDetectOption    $Options 'SampleBlockKB'       64)
    $maxCand   = [int](Get-MoveDetectOption    $Options 'MaxPairCandidates'   64)

    if ($mode -ne 'full' -and $mode -ne 'sampled' -and $mode -ne 'off') { $mode = 'full' }
    if ($points  -lt 2)  { $points  = 8 }
    if ($blockKB -lt 4)  { $blockKB = 64 }
    if ($maxCand -lt 1)  { $maxCand = 64 }

    $fullLimit = [long]0
    if ($fullMaxMB -gt 0) { $fullLimit = $fullMaxMB * 1MB }

    $pairs    = New-Object System.Collections.ArrayList
    $restCopy = New-Object System.Collections.ArrayList
    $usedDel  = @{}
    $cache    = @{}
    $skipped  = 0

    $delBySize = @{}
    foreach ($di in @($DeleteItems)) {
        $key = [string]$di.Size
        if (-not $delBySize.ContainsKey($key)) { $delBySize[$key] = New-Object System.Collections.ArrayList }
        [void]$delBySize[$key].Add($di)
    }

    $total = @($CopyItems).Count
    $idx   = 0

    foreach ($ci in @($CopyItems)) {
        $idx++
        $key     = [string]$ci.Size
        $matched = $false

        if ($delBySize.ContainsKey($key)) {
            # 只保留"未被占用"且"修改时间在容差内"的候选
            $cands = @($delBySize[$key] | Where-Object {
                (-not $usedDel.ContainsKey($_.Rel)) -and
                ([Math]::Abs([long]$_.Ticks - [long]$ci.Ticks) -le $tolerance)
            })

            if ($cands.Count -gt $maxCand) {
                # 病态场景：同大小文件太多，放弃配对，走常规复制
                $skipped++
                Write-Log ("同大小候选 {0} 个，超过上限 {1}，跳过移动识别并改为复制：{2}" -f $cands.Count, $maxCand, $ci.Rel) -Level WARN
            } else {
                foreach ($di in $cands) {
                    if ($usedDel.ContainsKey($di.Rel)) { continue }

                    $srcFull = Join-Path $SourceRoot $ci.Rel
                    $dstFull = Join-Path $TargetRoot $di.Rel

                    # ---- 关闭内容校验：只信大小 + 时间（不推荐） ----
                    if ($mode -eq 'off') {
                        $usedDel[$di.Rel] = $true
                        [void]$pairs.Add([pscustomobject]@{ FromRel = $di.Rel; ToRel = $ci.Rel; Size = $ci.Size; Verify = 'NONE' })
                        $matched = $true
                        break
                    }

                    # ---- L3：多点采样哈希 ----
                    $s1 = Get-SampleHash -Path $srcFull -Size $ci.Size -Points $points -BlockKB $blockKB
                    $s2 = Get-SampleHash -Path $dstFull -Size $di.Size -Points $points -BlockKB $blockKB
                    if (-not $s1 -or -not $s2) { continue }
                    if ($s1.Hash -ne $s2.Hash) { continue }

                    $verify = 'SAMPLE'
                    if ($s1.Full -and $s2.Full) { $verify = 'FULL' }

                    # ---- L4：完整 SHA256 ----
                    if ($mode -eq 'full' -and $verify -ne 'FULL') {
                        if ($fullLimit -gt 0 -and $ci.Size -gt $fullLimit) {
                            Write-Log ("文件 {0:N0} MB 超过 FullMaxMB={1}，保留采样校验结果：{2}" -f ($ci.Size / 1MB), $fullMaxMB, $ci.Rel) -Level INFO
                        } else {
                            $note = ("移动校验 {0}/{1}" -f $idx, $total)
                            $f1 = $null
                            if ($cache.ContainsKey($srcFull)) { $f1 = $cache[$srcFull] }
                            else { $f1 = Get-FullHash -Path $srcFull -Note $note; if ($f1) { $cache[$srcFull] = $f1 } }

                            $f2 = $null
                            if ($cache.ContainsKey($dstFull)) { $f2 = $cache[$dstFull] }
                            else { $f2 = Get-FullHash -Path $dstFull -Note $note; if ($f2) { $cache[$dstFull] = $f2 } }

                            if (-not $f1 -or -not $f2) { continue }
                            if ($f1 -ne $f2) { continue }
                            $verify = 'FULL'
                        }
                    }

                    $usedDel[$di.Rel] = $true
                    [void]$pairs.Add([pscustomobject]@{ FromRel = $di.Rel; ToRel = $ci.Rel; Size = $ci.Size; Verify = $verify })
                    $matched = $true
                    break
                }
            }
        }
        if (-not $matched) { [void]$restCopy.Add($ci) }
    }

    $restDel = New-Object System.Collections.ArrayList
    foreach ($di in @($DeleteItems)) {
        if (-not $usedDel.ContainsKey($di.Rel)) { [void]$restDel.Add($di) }
    }

    return [pscustomobject]@{
        Pairs      = @($pairs)
        RestCopy   = @($restCopy)
        RestDelete = @($restDel)
        Mode       = $mode
        Skipped    = $skipped
    }
}

# ============================================================
# 删除项备份
# ============================================================
function Backup-DeletedItems {
    param(
        [string]$TargetRoot,
        [string[]]$RelativePaths,
        [string]$BackupRoot,
        [string]$LogFile
    )
    $moved = 0
    $failed = 0
    $total = @($RelativePaths).Count
    $i = 0

    foreach ($rel in $RelativePaths) {
        $i++
        if ($i % 25 -eq 0 -or $i -eq 1) {
            Update-ProgressUI -Detail ("正在备份将被删除的文件  {0} / {1}" -f $i, $total) -State 'Work'
        }
        $srcFull = Join-Path $TargetRoot $rel
        $dstFull = Join-Path $BackupRoot $rel
        try {
            $dstDir = Split-Path -Parent $dstFull
            if (-not (Test-Path -LiteralPath $dstDir)) {
                New-Item -ItemType Directory -Path $dstDir -Force -ErrorAction Stop | Out-Null
            }
            Move-Item -LiteralPath $srcFull -Destination $dstFull -Force -ErrorAction Stop
            $moved++
        } catch {
            $failed++
            Write-Log -Message ("备份失败 {0} : {1}" -f $rel, $_.Exception.Message) -Level WARN -LogFile $LogFile
        }
    }
    return [pscustomobject]@{ Moved = $moved; Failed = $failed }
}

# ============================================================
# robocopy 调用
# ============================================================
function Get-RobocopyPath {
    $p = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return 'robocopy.exe'
}

function Start-RobocopyProcess {
    param(
        $Config,
        [string]$Source,
        [string]$Target,
        [string]$LogFile
    )
    $opt = $Config.Options
    $exe = Get-RobocopyPath

    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force -ErrorAction Stop | Out-Null
    }

    $a = New-Object System.Collections.ArrayList
    [void]$a.Add(('"{0}"' -f $Source))
    [void]$a.Add(('"{0}"' -f $Target))
    [void]$a.Add('/MIR')
    [void]$a.Add(('/R:{0}' -f $(if ($opt.RetryCount)   { $opt.RetryCount }   else { 3 })))
    [void]$a.Add(('/W:{0}' -f $(if ($opt.RetryWaitSec) { $opt.RetryWaitSec } else { 2 })))
    [void]$a.Add(('/MT:{0}' -f $(if ($opt.Threads)     { $opt.Threads }     else { 8 })))
    [void]$a.Add('/NP')    # 不打印百分比
    [void]$a.Add('/NFL')   # 不列文件名
    [void]$a.Add('/NDL')   # 不列目录名
    [void]$a.Add('/NJH')   # 不打印作业头

    $exDirs = @($opt.ExcludeDirs | Where-Object { $_ })
    if ($exDirs.Count -gt 0) {
        [void]$a.Add('/XD')
        foreach ($d in $exDirs) { [void]$a.Add(('"{0}"' -f $d)) }
    }
    $exFiles = @($opt.ExcludeFiles | Where-Object { $_ })
    if ($exFiles.Count -gt 0) {
        [void]$a.Add('/XF')
        foreach ($f in $exFiles) { [void]$a.Add(('"{0}"' -f $f)) }
    }

    [void]$a.Add(('/LOG:"{0}"' -f $LogFile))

    $proc = Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden -PassThru
    return $proc
}

function Get-RobocopySummary {
    param([string]$LogFile)
    $summary = [pscustomobject]@{
        Dirs        = ''
        Files       = ''
        Bytes       = ''
        Failed      = ''
        Extra       = ''
        CopiedCount = -1      # -1 表示解析不到，调用方自行回退
        FailedCount = -1
        Raw         = ''
    }
    if (-not (Test-Path -LiteralPath $LogFile)) { return $summary }
    try {
        $txt = Get-Content -LiteralPath $LogFile -Raw -Encoding Default -ErrorAction Stop
    } catch {
        return $summary
    }
    $summary.Raw = $txt

    # 摘要块形如：       总数    复制    跳过   不匹配    失败    其他
    #              文件:  120      8       0       0       0       0
    # 第 2 列就是本次真正复制成功的文件数，比"待复制数 - 失败数"可靠：
    # 待复制清单是比对阶段算的，robocopy 实际可能多复制（如时间戳微调）或少复制。
    if ($txt -match '(?m)^\s*(?:文件|Files)\s*[:：]\s*(\d[\d,]*)\s+(\d[\d,]*)') {
        $summary.CopiedCount = [int](($Matches[2]) -replace ',', '')
    }
    if ($txt -match '(?m)^\s*(?:文件|Files)\s*[:：]\s*\d[\d,]*\s+\d[\d,]*\s+\d[\d,]*\s+\d[\d,]*\s+(\d[\d,]*)') {
        $summary.FailedCount = [int](($Matches[1]) -replace ',', '')
    }

    $mLines = [regex]::Matches($txt, '(?m)^\s*(目录|文件|字节|Dirs|Files|Bytes)\s*[:：]\s*([0-9,\.\s]+.*)$')
    foreach ($m in $mLines) {
        $key = $m.Groups[1].Value
        $val = ($m.Groups[2].Value -replace '\s+', ' ').Trim()
        switch -Regex ($key) {
            '目录|Dirs'  { if (-not $summary.Dirs)  { $summary.Dirs  = $val } }
            '文件|Files' { if (-not $summary.Files) { $summary.Files = $val } }
            '字节|Bytes' { if (-not $summary.Bytes) { $summary.Bytes = $val } }
        }
    }
    if ($txt -match '(失败|Failed)\s*[:：]\s*(\d+)') { $summary.Failed = $Matches[2] }
    if ($txt -match '(额外|Extras)\s*[:：]\s*(\d+)') { $summary.Extra  = $Matches[2] }
    return $summary
}

<#
    Get-RobocopyFailedFiles
    从 robocopy 日志里提取失败的文件清单。

    典型失败行（中文 / 英文两种）：
      2026/11/10 22:56:49 错误 32 (0x00000020) 正在复制文件 C:\a\b.docx
      2026/11/10 22:56:49 ERROR 32 (0x00000020) Copying File C:\a\b.docx

    最常见的成因是文件正被 Word / Excel / 播放器占用（错误 32 共享冲突），
    其次是权限不足（错误 5）和路径过长（错误 3 / 206）。
    这类失败必须告诉用户具体是哪些文件，否则他只会看到"同步失败"四个字，
    却不知道硬盘上少了什么。
#>
<#
    ConvertFrom-RobocopyErrorLine
    把 robocopy 日志里的一行错误解析成 { Rel, Code, Reason }。

    抽成独立函数是为了让「同步进行中」的实时轮询与「同步结束」的收尾解析
    共用同一套规则 —— 两处各写一份正则，迟早会出现"实时提示 1 个、结束报 3 个"的矛盾。
#>
function ConvertFrom-RobocopyErrorLine {
    param([string]$Line, [string]$Source)

    if (-not $Line) { return $null }
    $pattern = '^\s*\d{4}[/\-]\d{2}[/\-]\d{2}\s+\d{2}:\d{2}:\d{2}\s+(?:错误|ERROR)\s+(\d+)\s+\(0x[0-9A-Fa-f]+\)\s+(?:正在复制文件|正在复制目录|Copying File|Copying Directory|访问源目录|Accessing Source|创建目录|Creating Directory)\s+(.+?)\s*$'
    $m = [regex]::Match($Line, $pattern)
    if (-not $m.Success) { return $null }

    $code = [int]$m.Groups[1].Value
    $full = $m.Groups[2].Value.Trim().Trim('"')

    $rel = $full
    if ($Source -and $full.StartsWith($Source, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($Source.Length).TrimStart('\')
    }
    $why = switch ($code) {
        32   { '文件被占用' }
        33   { '文件被锁定' }
        5    { '权限不足' }
        3    { '路径过长' }
        206  { '路径过长' }
        19   { '介质写保护' }
        112  { '磁盘空间不足' }
        123  { '文件名无效' }
        1392 { '文件已损坏' }
        53   { '路径不存在' }
        64   { '硬盘已断开' }
        default { "错误码 $code" }
    }
    return [pscustomobject]@{ Rel = $rel; Full = $full; Code = $code; Reason = $why }
}

# ------------------------------------------------------------
# robocopy 日志实时尾随
# ------------------------------------------------------------
<#
    同步进行中就要能发现问题。

    原来的做法是等 robocopy 退出后再解析日志，用户在整个 68 GB 的复制过程中
    看到的只有进度条，被占用、权限不足这些问题要等最后才冒出来。实测一次
    robocopy 处理上千个文件时，某个文件在前 5 秒就因共享冲突失败了，但提示
    要到二十分钟后才出现。

    这里按字节偏移增量读取日志尾部：
      · 用 FileShare.ReadWrite 打开，不与 robocopy 争抢写入
      · 只消费到最后一个换行符为止，半个中文字符不会被截断（下次再读）
      · 偏移量记在 State 里，同一次同步跨多次轮询复用
#>
function New-LogTailState {
    return [pscustomobject]@{ Pos = [long]0 }
}

function Read-LogTailLines {
    param([string]$Path, $State)

    if (-not $State) { return @() }
    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $fs = $null
    try {
        $fs = [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        $len = $fs.Length
        if ($len -le $State.Pos) { return @() }

        [void]$fs.Seek($State.Pos, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ([int]($len - $State.Pos))
        $read = $fs.Read($buf, 0, $buf.Length)
        if ($read -le 0) { return @() }

        $enc = [System.Text.Encoding]::Default
        $txt = $enc.GetString($buf, 0, $read)
        $idx = $txt.LastIndexOf("`n")
        if ($idx -lt 0) { return @() }          # 还没有完整行，等下一次

        $consumed = $txt.Substring(0, $idx + 1)
        $State.Pos += $enc.GetByteCount($consumed)
        return @($consumed -split "`r?`n" | Where-Object { $_.Trim() })
    }
    catch {
        return @()
    }
    finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Get-RobocopyFailedFiles {
    param([string]$LogFile, [string]$Source)

    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $LogFile)) { return @() }
    try {
        $txt = Get-Content -LiteralPath $LogFile -Raw -Encoding Default -ErrorAction Stop
    } catch {
        return @()
    }
    if (-not $txt) { return @() }

    $seen = @{}
    foreach ($line in ($txt -split "`r?`n")) {
        $ff = ConvertFrom-RobocopyErrorLine -Line $line -Source $Source
        if (-not $ff) { continue }
        if ($seen.ContainsKey($ff.Full)) { continue }
        $seen[$ff.Full] = $true
        [void]$out.Add($ff)
    }
    return @($out)
}

# ============================================================
# 写缓存刷新（需要管理员权限，失败则忽略）
# ============================================================
function Sync-VolumeCache {
    param([string]$Letter, [string]$LogFile)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log -Message '当前非管理员权限，跳过写缓存刷新（请使用任务栏「安全删除硬件」后再拔盘）' -Level WARN -LogFile $LogFile
        return $false
    }
    try {
        Write-VolumeCache -DriveLetter $Letter -ErrorAction Stop
        Write-Log -Message '写缓存已刷新到磁盘' -Level OK -LogFile $LogFile
        return $true
    } catch {
        Write-Log -Message ("写缓存刷新失败：{0}" -f $_.Exception.Message) -Level WARN -LogFile $LogFile
        return $false
    }
}

# ============================================================
# 上次同步状态（变更幅度保护的基线）
# ============================================================
function Get-SyncState {
    $p = $script:StatePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        if (-not $raw) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Save-SyncState {
    param($SourceCount, $SourceBytes, $TargetLetter, $SourcePath)
    try {
        $obj = [pscustomobject]@{
            LastSuccessAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            SourcePath    = [string]$SourcePath
            SourceCount   = [int]$SourceCount
            SourceBytes   = [long]$SourceBytes
            TargetLetter  = [string]$TargetLetter
        }
        $json = $obj | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($script:StatePath, $json, (New-Object System.Text.UTF8Encoding($true)))
    } catch {
        Write-Log ('状态文件写入失败（不影响同步）：' + $_.Exception.Message) -Level WARN
    }
}

<#
    Test-SyncVolumeGuard
    变更幅度保护。回答一个具体问题：
    "如果这次同步真的执行了，硬盘上会不会一次性少掉一大片东西？"

    两个判据，任一命中即拦下：
      1. 源端文件数比上次成功同步时少了超过 MaxShrinkPercent
         —— 典型成因：误删子目录、盘符错乱指向了别的盘、E 盘文件被整体移走
      2. 本次待删除数占总数的比例超过 MaxDeletePercent
         —— 典型成因：在 E 盘大范围删除后插盘

    只在小规模目录上不生效（MinFilesForCheck），避免几十个文件的小目录天天误报。
    确认无误时可以加 -Force 越过本检查。
#>
function Test-SyncVolumeGuard {
    param($Config, $SourceCount, $CopyCount, $DeleteCount, $TargetCount, [switch]$Force)

    $g = $Config.Options.SafetyGuard
    if ($Force) {
        return [pscustomobject]@{ Ok = $true; Code = 'FORCED'; Message = '' }
    }
    if (-not $g -or $g.Enabled -eq $false) {
        return [pscustomobject]@{ Ok = $true; Code = 'DISABLED'; Message = '' }
    }

    $maxDelete = if ($g.MaxDeletePercent) { [double]$g.MaxDeletePercent } else { 20 }
    $maxShrink = if ($g.MaxShrinkPercent) { [double]$g.MaxShrinkPercent } else { 20 }
    $minFiles  = if ($g.MinFilesForCheck) { [int]$g.MinFilesForCheck } else { 50 }

    $total = [int]$SourceCount + [int]$DeleteCount
    if ($total -lt $minFiles) {
        return [pscustomobject]@{ Ok = $true; Code = 'TOOSMALL'; Message = '' }
    }

    # 判据 1：源端文件数骤降
    # 基线只在"同一个源目录"下才有意义：如果用户改过 config.json 的 SourcePath，
    # 拿旧目录的文件数去比新目录必然误判，直接忽略基线。
    $st = Get-SyncState
    $sameSource = $false
    if ($st -and $st.SourcePath -and $Config.SourcePath) {
        $sameSource = ([string]$st.SourcePath).TrimEnd('\') -eq ([string]$Config.SourcePath).TrimEnd('\')
    }
    if ($st -and $sameSource -and [int]$st.SourceCount -ge $minFiles) {
        $prev = [int]$st.SourceCount
        $drop = 0.0
        if ($prev -gt 0) { $drop = 100.0 * ($prev - [int]$SourceCount) / $prev }
        if ($drop -gt $maxShrink) {
            $msg = ("源文件夹文件数从上次的 {0} 个降到现在 {1} 个（少了 {2:N0}%），疑似被大范围删除或目录指向错误。已中止，硬盘未做任何改动。" -f $prev, [int]$SourceCount, $drop)
            return [pscustomobject]@{ Ok = $false; Code = 'SHRINK'; Message = $msg }
        }
    }

    # 判据 2：本次删除比例过高
    if ($total -gt 0) {
        $pct = 100.0 * [int]$DeleteCount / $total
        if ($DeleteCount -gt 0 -and $pct -gt $maxDelete) {
            $msg = ("本次要删除硬盘上的 {0} 个文件，占总数 {1} 个的 {2:N0}%，超过安全阈值 {3:N0}%。已中止，硬盘未做任何改动。" -f $DeleteCount, $total, $pct, $maxDelete)
            return [pscustomobject]@{ Ok = $false; Code = 'BIGDELETE'; Message = $msg }
        }
    }

    return [pscustomobject]@{ Ok = $true; Code = 'OK'; Message = '' }
}

# ============================================================
# 保留策略：备份目录与日志不能无限膨胀
# ============================================================
function Invoke-RetentionCleanup {
    param($Config, [string]$TargetRoot, [string]$LogFile)

    $rt = $Config.Options.Retention
    if (-not $rt) { return }

    # --- 备份目录：按天 + 按总量，从最老的开始删 ---
    $keepDays = if ($rt.BackupKeepDays) { [int]$rt.BackupKeepDays } else { 30 }
    $maxGB    = if ($rt.BackupMaxGB)   { [double]$rt.BackupMaxGB } else { 20 }
    $bRootName = [string]$Config.Options.BackupFolderName
    if ($TargetRoot -and $bRootName) {
        $bRoot = Join-Path $TargetRoot $bRootName
        if (Test-Path -LiteralPath $bRoot) {
            $dirs = @(Get-ChildItem -LiteralPath $bRoot -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)
            $deadline = (Get-Date).AddDays(-$keepDays)
            $removedDirs = 0
            $removedBytes = [long]0

            # 先按天数
            $alive = New-Object System.Collections.ArrayList
            foreach ($d in $dirs) {
                $isOld = $false
                $stampText = $d.Name
                if ($stampText -match '^(\d{8})-(\d{6})') {
                    try {
                        $dt = [datetime]::ParseExact(($Matches[1] + $Matches[2]), 'yyyyMMddHHmmss', $null)
                        if ($dt -lt $deadline) { $isOld = $true }
                    } catch { }
                } else {
                    if ($d.LastWriteTime -lt $deadline) { $isOld = $true }
                }
                if ($isOld) {
                    $sz = [long]((Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
                    try {
                        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop
                        $removedDirs++; $removedBytes += $sz
                        continue
                    } catch { }
                }
                [void]$alive.Add([pscustomobject]@{ Dir = $d; Bytes = [long]((Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) })
            }

            # 再按总量，从最老的开始
            $cap = [long]($maxGB * 1GB)
            if ($cap -gt 0) {
                $sum = [long]0
                foreach ($a in $alive) { $sum += $a.Bytes }
                foreach ($a in $alive) {
                    if ($sum -le $cap) { break }
                    try {
                        Remove-Item -LiteralPath $a.Dir.FullName -Recurse -Force -ErrorAction Stop
                        $sum -= $a.Bytes
                        $removedDirs++; $removedBytes += $a.Bytes
                    } catch { }
                }
            }

            if ($removedDirs -gt 0) {
                Write-Log ("清理旧备份：{0} 个批次、{1:N2} GB（保留 {2} 天 / 上限 {3} GB）" -f $removedDirs, ($removedBytes/1GB), $keepDays, $maxGB) -LogFile $LogFile
            }
        }
    }

    # --- 日志：只留最近 N 个 ---
    $keepLogs = if ($rt.LogKeepCount) { [int]$rt.LogKeepCount } else { 60 }
    if ($keepLogs -gt 0) {
        $logDir = Join-Path $script:RootDir ([string]$Config.LogDir)
        if (Test-Path -LiteralPath $logDir) {
            $logs = @(Get-ChildItem -LiteralPath $logDir -File -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($logs.Count -gt $keepLogs) {
                $n = 0
                foreach ($l in ($logs | Select-Object -Skip $keepLogs)) {
                    try { Remove-Item -LiteralPath $l.FullName -Force -ErrorAction Stop; $n++ } catch { }
                }
                if ($n -gt 0) { Write-Log ("清理旧日志 {0} 个（保留最近 {1} 个）" -f $n, $keepLogs) -LogFile $LogFile }
            }
        }
    }
}

# ============================================================
# 主流程
# ============================================================
function Invoke-SyncTaskInternal {
    param(
        $Config = $null,
        [switch]$DryRun,
        [switch]$NoWindow,
        [switch]$Auto,
        [switch]$Force,
        $Hardware = $null,
        [string]$FixedTargetRoot = ''
    )

    if (-not $Config) { $Config = Get-SyncConfig }
    $opt = $Config.Options

    # 日志准备
    $logDir = Join-Path $script:RootDir ([string]$Config.LogDir)
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile = Join-Path $logDir ("sync-{0}.log" -f $stamp)
    $rcLog   = Join-Path $logDir ("robocopy-{0}.log" -f $stamp)

    $result = [pscustomobject]@{
        Ok          = $false
        Code        = ''
        Message     = ''
        Copied      = 0
        CopyBytes   = [long]0
        Deleted     = 0
        SourceCount = 0
        SourceBytes = [long]0
        TargetRoot  = ''
        FailFiles   = @()
        Elapsed     = [TimeSpan]::Zero
        LogFile     = $logFile
        RcLog       = $rcLog
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $showWindow = (-not $NoWindow) -and ($opt.ShowProgressWindow -ne $false)

    Write-Log "===== 同步任务开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====" -LogFile $logFile
    Write-Log ("源：{0}" -f $Config.SourcePath) -LogFile $logFile

    # ---- 步骤 1：识别目标盘 ----
    if ($showWindow) { [void](New-ProgressWindow -Title '正在准备同步' -Compact:$Auto) }
    Clear-UINotice          # 每次同步从干净的通知列表开始

    # folder 目的地：目标根直接给定，跳过找盘（虚拟卷带盘符+剩余空间，供空间检查用）
    if ($FixedTargetRoot) {
        Update-ProgressUI -Title '正在准备同步' -Detail ('目的地：' + $FixedTargetRoot) -Hint '' -Percent 2 -State 'Work'
        Write-Log ("目标：本地文件夹目的地（{0}）" -f $FixedTargetRoot) -LogFile $logFile
        $vol = [pscustomobject]@{ Letter = $FixedTargetRoot.Substring(0, 1); Label = ''; FreeBytes = [long]0 }
        try {
            $vn = Get-Volume -DriveLetter $vol.Letter -ErrorAction Stop
            if ($vn) {
                $vol | Add-Member -NotePropertyName FreeBytes -NotePropertyValue ([long]$vn.SizeRemaining) -Force
                $vol.Label = [string]$vn.FileSystemLabel
            }
        } catch { }
        Set-UIStatus -Connected $true
    } else {
        Update-ProgressUI -Title '正在识别移动硬盘' -Detail '按硬件序列号校验…' -Hint '请勿拔出硬盘' -Percent 2 -State 'Work'

        $disk = Resolve-TargetDrive -Config $Config -Hardware $Hardware
        if (-not $disk.Ok) {
            Write-Log $disk.Message -Level ERROR -LogFile $logFile
            [void](Add-UINotice -Level 'Error' -Reason '硬盘未就绪' -Target $disk.Message -Advice '未对目标做任何改动。插好目的地硬盘后重新运行即可')
            Update-ProgressUI -Title '同步未开始' -Detail $disk.Message -Hint '未对目标做任何改动' -Percent 0 -State 'Error'
            Close-ProgressWindow -DelaySeconds $(if ($Auto) { 8 } else { 12 })
            $result.Code = $disk.Code
            $result.Message = $disk.Message
            return $result
        }
        Write-Log $disk.Message -Level OK -LogFile $logFile
        $vol = $disk.Volume
        Set-UIStatus -Connected $true -DiskLetter ([string]$vol.Letter) -DiskName ([string]$vol.Label)
    }

    # ---- 步骤 2：环境校验 ----
    Update-ProgressUI -Title '正在校验同步条件' -Detail '检查源目录与目标路径…' -Percent 5 -State 'Work'
    $envCheck = Test-SyncEnvironment -Config $Config -Volume $vol -FixedTargetRoot $FixedTargetRoot
    if (-not $envCheck.Ok) {
        Write-Log $envCheck.Message -Level ERROR -LogFile $logFile
        [void](Add-UINotice -Level 'Error' -Reason '环境校验未通过' -Target $envCheck.Message -Advice '这是保护机制，目标未做任何改动，按提示处理后可重试')
        Update-ProgressUI -Title '同步已中止' -Detail $envCheck.Message -Hint '这是保护机制，请检查后重试' -Percent 0 -State 'Error'
        Close-ProgressWindow -DelaySeconds 15
        $result.Code = 'ENVCHECK'
        $result.Message = $envCheck.Message
        return $result
    }
    $targetPath = $envCheck.TargetPath
    $targetRoot = $envCheck.TargetRoot
    Write-Log ("目标：{0}" -f $targetPath) -LogFile $logFile

    # 目标文件夹不存在、但历史上有成功同步记录：多半是目标上的文件夹被删掉或改了名。
    # 这种情况会触发全量复制，大目录要很久，得先让用户知道。
    if (-not (Test-Path -LiteralPath $targetPath)) {
        $st0 = Get-SyncState
        if ($st0 -and [int]$st0.SourceCount -gt 0) {
            Write-Log ('目标文件夹不存在（「{0}」可能被删除或改名），本次将全量复制' -f $Config.TargetFolderName) -Level WARN -LogFile $logFile
        } else {
            Write-Log '目标文件夹不存在，这是首次同步，将完整复制' -LogFile $logFile
        }
    }

    # ---- 步骤 3：比对 ----
    Update-ProgressUI -Title '正在比对文件差异' -Detail '扫描源目录与目标目录…' -Percent 10 -State 'Work'
    $exDirs  = @($opt.ExcludeDirs  | Where-Object { $_ })
    $exFiles = @($opt.ExcludeFiles | Where-Object { $_ })

    $cmp = Compare-SyncTree -Source $Config.SourcePath -Target $targetPath -ExcludeDirs $exDirs -ExcludeFiles $exFiles

    # 安全闸：源端枚举出错必须中止，否则读不到的目录会被判成"目标端多余"而遭删除
    if ($cmp.SourceErrors -gt 0) {
        $msg = ("源目录有 {0} 处无法读取（权限 / 占用 / 路径过长），继续同步可能误删硬盘上的文件，已中止" -f $cmp.SourceErrors)
        Write-Log $msg -Level ERROR -LogFile $logFile
        $i = 0
        foreach ($s in @($cmp.SourceErrorSample)) {
            $i++
            Write-Log ('    ' + $s) -Level WARN -LogFile $logFile
            [void](Add-UINotice -Level 'Error' -Reason '源文件读不到' -Target $s -Key ('SE' + $i))
        }
        if ($cmp.SourceErrors -gt @($cmp.SourceErrorSample).Count) {
            [void](Add-UINotice -Level 'Error' -Reason '源文件读不到' -Target ('另有 {0} 处，见 logs 目录' -f ($cmp.SourceErrors - @($cmp.SourceErrorSample).Count)) -Key 'SE_MORE')
        }
        Update-ProgressUI -Title '同步已中止' -Detail $msg -Hint '请查看日志中的具体路径' -Percent 0 -State 'Error'
        Close-ProgressWindow -DelaySeconds 20
        $result.Code = 'SRCERR'; $result.Message = $msg
        return $result
    }
    if ($cmp.TargetErrors -gt 0) {
        Write-Log ("目标端有 {0} 处无法读取，可能触发多余复制" -f $cmp.TargetErrors) -Level WARN -LogFile $logFile
        [void](Add-UINotice -Level 'Warn' -Reason '硬盘端读不到' -Target ("{0} 处（可能是坏道或接触不良），可能触发多余的重复复制" -f $cmp.TargetErrors))
    }

    $copyItems = @($cmp.CopyItems)
    $delItems  = @($cmp.DeleteItems)
    $copyBytes = [long]$cmp.CopyBytes
    $delBytes  = [long]$cmp.DeleteBytes

    Write-Log ("比对完成：源 {0} 个文件，目标 {1} 个文件" -f $cmp.SourceCount, $cmp.TargetCount) -LogFile $logFile
    $result.SourceCount = [int]$cmp.SourceCount
    $result.TargetRoot  = [string]$targetRoot
    $srcBytesSum = [long]0
    foreach ($k in @($cmp.SrcMap.Keys)) { $srcBytesSum += [long]$cmp.SrcMap[$k].Size }
    $result.SourceBytes = $srcBytesSum
    Write-Log ("待复制 {0} 个（{1:N2} GB），待删除 {2} 个（{3:N2} GB），缺失目录 {4} 个" -f $copyItems.Count, ($copyBytes/1GB), $delItems.Count, ($delBytes/1GB), @($cmp.MissingDirs).Count) -LogFile $logFile
    Set-UIStatus -Files ('{0} 个' -f $cmp.SourceCount) -Size ('{0:N1} GB' -f ($srcBytesSum/1GB))

    # ---- 步骤 3.5：识别移动 ----
    # 先目录级（整棵子树重新分类），再文件级（零散移动、目录拆分），最后统一收尾。
    $movedPairs    = @()
    $dirMovedCount = 0
    if ($opt.EnableMoveOptimization -ne $false -and $copyItems.Count -gt 0 -and $delItems.Count -gt 0) {

        # --- 3.5a 目录级：整棵子树搬迁，一次结构签名匹配完成 ---
        Update-ProgressUI -Title '正在识别目录移动' -Detail '比对目录结构签名…' -Percent 12 -State 'Work'
        $dm = Find-MovedDirs -CopyItems $copyItems -DeleteItems $delItems -SourceMap $cmp.SrcMap -TargetMap $cmp.DstMap -SourceRoot $Config.SourcePath -TargetRoot $targetPath -Options $opt
        $dirPairs = @($dm.Pairs)
        if ($dirPairs.Count -gt 0) {
            $dirMovedCount = $dm.DirCount
            $copyItems  = @($dm.RestCopy)
            $delItems   = @($dm.RestDelete)
            $movedPairs = @($dirPairs)
            $dmBytes  = [long](($dirPairs | Measure-Object -Property Size -Sum).Sum)
            $dmFull   = @($dirPairs | Where-Object { $_.Verify -eq 'FULL' }).Count
            $dmStruct = @($dirPairs | Where-Object { $_.Verify -eq 'STRUCT' }).Count
            Write-Log ("目录级移动：{0} 个目录、{1} 个文件、{2:N2} GB 将整段重命名，不产生传输" -f $dm.DirCount, $dirPairs.Count, ($dmBytes/1GB)) -Level OK -LogFile $logFile
            Write-Log ("  目录级校验：完整哈希 {0} 个文件，结构签名 {1} 个文件" -f $dmFull, $dmStruct) -LogFile $logFile
        }

        # --- 3.5b 文件级：处理目录拆分、零散移动、目录内部分文件同时改动的情况 ---
        Update-ProgressUI -Title '正在识别文件移动' -Detail '比对大小、时间与内容哈希…' -Percent 13 -State 'Work'
        $mv = Find-MovedPairs -CopyItems $copyItems -DeleteItems $delItems -SourceRoot $Config.SourcePath -TargetRoot $targetPath -Options $opt
        $filePairs = @($mv.Pairs)
        if ($filePairs.Count -gt 0) {
            $copyItems  = @($mv.RestCopy)
            $delItems   = @($mv.RestDelete)
            $movedPairs = @($movedPairs) + @($filePairs)
            $fpBytes = [long](($filePairs | Measure-Object -Property Size -Sum).Sum)
            $nFull = @($filePairs | Where-Object { $_.Verify -eq 'FULL' }).Count
            $nSamp = @($filePairs | Where-Object { $_.Verify -eq 'SAMPLE' }).Count
            $nNone = @($filePairs | Where-Object { $_.Verify -eq 'NONE' }).Count
            Write-Log ("文件级移动：{0} 个文件（{1:N2} GB），将在硬盘上直接重命名" -f $filePairs.Count, ($fpBytes/1GB)) -Level OK -LogFile $logFile
            Write-Log ("  文件级校验：完整哈希 {0} 个，采样哈希 {1} 个，未校验 {2} 个（模式 {3}）" -f $nFull, $nSamp, $nNone, $mv.Mode) -LogFile $logFile
            if ($nNone -gt 0) {
                Write-Log '  存在未做内容校验的移动配对，HashMode 为 off，建议改回 full' -Level WARN -LogFile $logFile
            }
            if ($nSamp -gt 0) {
                Write-Log ("  其中 {0} 个因超过 FullMaxMB 仅做多点采样校验" -f $nSamp) -Level INFO -LogFile $logFile
            }
            if ($mv.Skipped -gt 0) {
                Write-Log ("  {0} 个文件因同大小候选过多跳过配对，已改为常规复制" -f $mv.Skipped) -Level WARN -LogFile $logFile
            }
        }

        # --- 3.5c 收尾：重算待传体积 ---
        if ($movedPairs.Count -gt 0) {
            $copyBytes = [long](($copyItems | Measure-Object -Property Size -Sum).Sum)
            if (-not $copyBytes) { $copyBytes = [long]0 }
            $delBytes = [long](($delItems | Measure-Object -Property Size -Sum).Sum)
            if (-not $delBytes) { $delBytes = [long]0 }
            $mvBytes = [long](($movedPairs | Measure-Object -Property Size -Sum).Sum)
            Write-Log ("移动识别合计：{0} 个文件（{1:N2} GB）只需重命名，其中 {2} 个目录为整体搬迁" -f $movedPairs.Count, ($mvBytes/1GB), $dirMovedCount) -Level OK -LogFile $logFile
        }
    }

    $copyCount = $copyItems.Count
    $delCount  = $delItems.Count

    # ---- 步骤 3.7：变更幅度保护 ----
    # 放在移动识别之后：目录整体搬迁已经从这里移除了，剩下的是"真删除"，
    # 这样才不会把正常的目录重排误判成大规模删除。
    $guard = Test-SyncVolumeGuard -Config $Config -SourceCount $cmp.SourceCount -CopyCount $copyCount -DeleteCount $delCount -TargetCount $cmp.TargetCount -Force:$Force
    if (-not $guard.Ok) {
        if ($DryRun) {
            # 预演本身不改动任何东西，拦下它只会让用户看不到结果。
            # 这里只提示，让用户提前知道真跑时会被挡住。
            Write-Log ('[预演] 变更幅度异常：' + $guard.Message) -Level WARN -LogFile $logFile
            Write-Host ('  ⚠ ' + $guard.Message) -ForegroundColor Yellow
            Write-Host '  真跑时这道保护会中止同步，确认无误需加 -Force。' -ForegroundColor Yellow
        } else {
            Write-Log $guard.Message -Level ERROR -LogFile $logFile
            Write-Log '  如果你确认这是自己主动删除的，用 Run-Sync.cmd -Force 确认执行' -Level WARN -LogFile $logFile
            [void](Add-UINotice -Level 'Error' -Reason '变更幅度异常' -Target $guard.Message -Advice '这是保护机制，不是故障。确认是自己主动删除的，用 Run-Sync.cmd -Force 跳过本检查')
            Update-ProgressUI -Title '已中止：变更幅度异常' -Detail $guard.Message -Hint '硬盘未做任何改动' -Percent 0 -State 'Error'
            Close-ProgressWindow -DelaySeconds $(if ($Auto) { 30 } else { 12 })
            Write-Host ''
            Write-Host ('  ' + $guard.Message) -ForegroundColor Red
            Write-Host '  这是保护机制，不是错误。确认无误后用 Run-Sync.cmd -Force 执行。' -ForegroundColor Yellow
            $result.Code = $guard.Code
            $result.Message = $guard.Message
            $result.Elapsed = $sw.Elapsed
            return $result
        }
    }

    # 空间检查
    $reserve = [long]($(if ($opt.FreeSpaceReserveGB) { $opt.FreeSpaceReserveGB } else { 2 })) * 1GB
    $need = [long]($copyBytes * 1.02) + $reserve
    $free = [long]$vol.FreeBytes
    if ($copyBytes -gt 0 -and $free -lt $need) {
        # 空间不够时先清理过期备份再试一次。
        # 不这么做会形成死锁：备份把盘塞满 → 同步失败 → 失败就不清理备份 → 永远失败。
        Write-Log ("空间不足（需要 {0:N1} GB，可用 {1:N1} GB），先清理过期备份…" -f ($need/1GB), ($free/1GB)) -Level WARN -LogFile $logFile
        Update-ProgressUI -Title '空间不足，正在清理旧备份' -Detail '按保留策略删除过期备份…' -Percent 16 -State 'Work'
        Invoke-RetentionCleanup -Config $Config -TargetRoot $targetRoot -LogFile $logFile
        $vn2 = Get-Volume -DriveLetter $vol.Letter -ErrorAction SilentlyContinue
        if ($vn2) { $free = [long]$vn2.SizeRemaining }
    }

    if ($copyBytes -gt 0 -and $free -lt $need) {
        $msg = ("目标磁盘空间不足：需要约 {0:N1} GB，可用 {1:N1} GB" -f ($need/1GB), ($free/1GB))
        Write-Log $msg -Level ERROR -LogFile $logFile
        [void](Add-UINotice -Level 'Error' -Reason '磁盘空间不足' -Target $msg -Advice '清理硬盘上的旧文件后重试；备份区已按保留策略清理过一次，仍不够')
        Update-ProgressUI -Title '空间不足' -Detail $msg -Hint '请清理硬盘后再试' -Percent 0 -State 'Error'
        Close-ProgressWindow -DelaySeconds 15
        $result.Code = 'NOSPACE'; $result.Message = $msg
        return $result
    }

    # ---- 预演模式 ----
    if ($DryRun) {
        $detail = ("待复制 {0} 个 / {1:N2} GB   待删除 {2} 个 / {3:N2} GB" -f $copyCount, ($copyBytes/1GB), $delCount, ($delBytes/1GB))
        if ($movedPairs.Count -gt 0) {
            $detail += ("   移动 {0} 个" -f $movedPairs.Count)
            if ($dirMovedCount -gt 0) { $detail += ("（含 {0} 个目录整体搬迁）" -f $dirMovedCount) }
        }
        if (@($cmp.MissingDirs).Count -gt 0) { $detail += ("   新建目录 {0} 个" -f @($cmp.MissingDirs).Count) }
        Write-Log ('[预演] ' + $detail) -Level OK -LogFile $logFile

        if ($movedPairs.Count -gt 0) {
            Write-Host '  以下内容判定为移动/改名（只需重命名，不重传）：' -ForegroundColor Cyan

            # 目录整体搬迁按目录对聚合显示，避免同一目录刷出几十行
            $dirMap   = [ordered]@{}
            $fileOnly = New-Object System.Collections.ArrayList
            foreach ($p in $movedPairs) {
                if ($p.IsDir) {
                    $key = [string]$p.FromDir + '|' + [string]$p.ToDir
                    if ($dirMap.Contains($key)) { $dirMap[$key] = [int]$dirMap[$key] + 1 }
                    else { $dirMap[$key] = [int]1 }
                } else {
                    [void]$fileOnly.Add($p)
                }
            }

            $shown = 0
            foreach ($k in @($dirMap.Keys)) {
                if ($shown -ge 8) { break }
                $seg = $k.Split('|')
                Write-Host ("    [目录] {0}  ->  {1}     （{2} 个文件）" -f $seg[0], $seg[1], $dirMap[$k]) -ForegroundColor DarkCyan
                $shown++
            }
            $remain = 10 - $shown
            if ($remain -gt 0) {
                foreach ($p in @($fileOnly | Select-Object -First $remain)) {
                    Write-Host ("    {0}  ->  {1}" -f $p.FromRel, $p.ToRel) -ForegroundColor DarkCyan
                    $shown++
                }
            }
            if ($movedPairs.Count -gt $shown) { Write-Host ("    … 另有 {0} 个文件" -f ($movedPairs.Count - $shown)) -ForegroundColor DarkCyan }
        }
        if ($delCount -gt 0) {
            Write-Host '  以下文件将被删除（会先备份）：' -ForegroundColor DarkYellow
            foreach ($p in @($delItems | Select-Object -First 20)) {
                Write-Host ('    ' + $p.Rel) -ForegroundColor DarkYellow
            }
            if ($delCount -gt 20) { Write-Host ("    … 另有 {0} 个" -f ($delCount - 20)) -ForegroundColor DarkYellow }
        }

        Update-ProgressUI -Title '预演完成（未做任何改动）' -Detail $detail -Hint '确认无误后去掉 -DryRun 再运行' -Percent 100 -State 'Done'
        Close-ProgressWindow -DelaySeconds $(if ($Auto) { 10 } else { 1 })
        $result.Ok = $true; $result.Code = 'DRYRUN'; $result.Message = $detail
        $result.Copied = $copyCount
        $result.CopyBytes = $copyBytes
        $result.Deleted = $delCount
        $result.Elapsed = $sw.Elapsed
        return $result
    }

    # 无差异直接结束
    if ($copyCount -eq 0 -and $delCount -eq 0 -and $movedPairs.Count -eq 0 -and @($cmp.MissingDirs).Count -eq 0) {
        Write-Log '两端已完全一致，无需同步' -Level OK -LogFile $logFile
        Update-ProgressUI -Title '已是最新' -Detail ("{0} 个文件，两端完全一致" -f $cmp.SourceCount) -Hint '可以安全拔出硬盘' -Percent 100 -State 'Done'
        Close-ProgressWindow -DelaySeconds $(if ($Auto) { 6 } else { 8 })
        $result.Ok = $true; $result.Code = 'UPTODATE'; $result.Message = '两端已一致'
        $result.Elapsed = $sw.Elapsed
        return $result
    }

    # ---- 步骤 3.6：执行移动（在磁盘上直接重命名） ----
    $mvOk = 0
    $mvFailed = @()
    if ($movedPairs.Count -gt 0) {
        Update-ProgressUI -Title '正在处理文件移动' -Detail ("共 {0} 个" -f $movedPairs.Count) -Percent 14 -State 'Work'
        $mi = 0
        foreach ($pair in $movedPairs) {
            $mi++
            if ($mi % 20 -eq 0) { Update-ProgressUI -Detail ("正在重命名 {0} / {1}" -f $mi, $movedPairs.Count) -State 'Work' }
            $fromFull = Join-Path $targetPath $pair.FromRel
            $toFull   = Join-Path $targetPath $pair.ToRel
            try {
                $toDir = Split-Path -Parent $toFull
                if (-not (Test-Path -LiteralPath $toDir)) {
                    New-Item -ItemType Directory -Path $toDir -Force -ErrorAction Stop | Out-Null
                }
                Move-Item -LiteralPath $fromFull -Destination $toFull -Force -ErrorAction Stop
                # 时间戳对齐源端，消除 2 秒容差残留，保证下次比对判定为一致
                try {
                    $srcRef = Join-Path $Config.SourcePath $pair.ToRel
                    [System.IO.File]::SetLastWriteTimeUtc($toFull, [System.IO.File]::GetLastWriteTimeUtc($srcRef))
                } catch { }
                $mvOk++
            } catch {
                $mvFailed += $pair
                Write-Log ("移动失败 {0} -> {1} : {2}" -f $pair.FromRel, $pair.ToRel, $_.Exception.Message) -Level WARN -LogFile $logFile
            }
        }
        Write-Log ("移动处理完成：成功 {0} 个，失败 {1} 个" -f $mvOk, @($mvFailed).Count) -LogFile $logFile
        if (@($mvFailed).Count -gt 0) {
            $sample = (@($mvFailed) | Select-Object -First 2 | ForEach-Object { $_.FromRel }) -join '、'
            [void](Add-UINotice -Level 'Warn' -Reason '重命名失败' -Target ("{0} 个（如 {1}），已改为常规复制，不影响内容" -f @($mvFailed).Count, $sample) -Advice '硬盘上这些文件会重新传输一次，最终内容一致')
        }

        # 回退保护：移动失败的文件，旧位置保留进待删清单，新路径重新进待复制清单，绝不丢文件
        if (@($mvFailed).Count -gt 0) {
            $delItems  = @($delItems)  + @($mvFailed | ForEach-Object { [pscustomobject]@{ Rel = $_.FromRel; Size = $_.Size; Ticks = 0 } })
            $copyItems = @($copyItems) + @($mvFailed | ForEach-Object { [pscustomobject]@{ Rel = $_.ToRel;   Size = $_.Size; Ticks = 0 } })
            $copyCount = $copyItems.Count
            $delCount  = $delItems.Count
        }
    }

    # ---- 步骤 4：备份删除项 ----
    $backupInfo = $null
    if ($delCount -gt 0 -and $opt.SafetyBackupDeleted -ne $false) {
        $bRoot = Join-Path $targetRoot ([string]$opt.BackupFolderName)
        $bDir  = Join-Path $bRoot ((Get-Date -Format 'yyyyMMdd-HHmmss'))
        $bDir  = Join-Path $bDir ([string]$Config.TargetFolderName)
        Write-Log ("发现 {0} 个多余文件，先备份到 {1}" -f $delCount, $bDir) -Level INFO -LogFile $logFile
        Update-ProgressUI -Title '正在备份将被删除的文件' -Detail ("共 {0} 个" -f $delCount) -Percent 15 -State 'Work'
        $delRels = @($delItems | ForEach-Object { $_.Rel })
        $backupInfo = Backup-DeletedItems -TargetRoot $targetPath -RelativePaths $delRels -BackupRoot $bDir -LogFile $logFile
        Write-Log ("已备份 {0} 个，失败 {1} 个" -f $backupInfo.Moved, $backupInfo.Failed) -LogFile $logFile
        if ([int]$backupInfo.Failed -gt 0) {
            [void](Add-UINotice -Level 'Warn' -Reason '备份失败' -Target ("{0} 个多余文件没能移进备份区，可能被占用" -f $backupInfo.Failed) -Advice '它们仍留在硬盘上，不会被删除；下次同步会重试')
        }
    }

    # ---- 步骤 5：执行同步 ----
    Update-ProgressUI -Title '正在同步到移动硬盘' -Detail '启动 robocopy…' -Hint '同步进行中，请勿拔出硬盘' -Percent 20 -State 'Work'
    $freeBefore = [long](Get-Volume -DriveLetter $vol.Letter -ErrorAction SilentlyContinue).SizeRemaining
    if (-not $freeBefore) { $freeBefore = $free }

    $proc = Start-RobocopyProcess -Config $Config -Source $Config.SourcePath -Target $targetPath -LogFile $rcLog
    Write-Log ("robocopy 已启动，PID {0}" -f $proc.Id) -LogFile $logFile

    $totalBytes = [long]$copyBytes
    $lastTick = Get-Date
    $lastDone = [long]0
    $speed    = 0.0
    $monoPct  = 20
    $lastUi   = Get-Date
    $lastFree = [long]$freeBefore

    # 实时监视：日志尾随（发现被占用/权限不足）+ 卷消失检测（硬盘中途被拔）
    $tailState  = New-LogTailState
    $lastTail   = Get-Date
    $volMiss    = 0
    $diskWarned = $false
    $cancelled  = $false

    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 700
        $proc.Refresh()
        if ($proc.HasExited) { break }

        # ---- 界面上点了「停止同步」 ----
        if (Test-UICancelRequested) {
            $cancelled = $true
            Write-Log '收到「停止同步」指令，正在结束 robocopy…' -Level WARN -LogFile $logFile
            try { $proc.Kill() } catch { }
            break
        }

        $now = Get-Date
        $vn = Get-Volume -DriveLetter $vol.Letter -ErrorAction SilentlyContinue
        if ($vn) {
            $lastFree = [long]$vn.SizeRemaining
            $volMiss  = 0
        } else {
            # 单次读不到卷可能只是瞬时抖动，连续 3 次（约 2 秒）才认定断开
            $volMiss++
            if ($volMiss -ge 3 -and -not $diskWarned) {
                $diskWarned = $true
                Set-UIStatus -Connected $false
                Write-Log '同步中无法读取目标卷：疑似硬盘被拔出或接触不良' -Level ERROR -LogFile $logFile
                [void](Add-UINotice -Level 'Error' -Reason '硬盘已断开' -Target '同步中无法读取目标卷，可能被拔出或接触不良' -Advice '已写入的文件可能不完整。重新插好硬盘后再同步一次即可补齐')
                Update-ProgressUI -Title '同步中断' -Detail '硬盘已断开' -Hint '已写入的文件可能不完整' -State 'Error'
            }
        }

        $freeNow = $lastFree
        $done = [long]($freeBefore - $freeNow)
        if ($done -lt 0) { $done = 0 }
        if ($totalBytes -gt 0 -and $done -gt $totalBytes) { $done = $totalBytes }

        $dt = ($now - $lastTick).TotalSeconds
        if ($dt -ge 1.0) {
            $deltaSpeed = ($done - $lastDone) / $dt
            if ($deltaSpeed -lt 0) { $deltaSpeed = 0 }
            $speed = if ($speed -le 0) { $deltaSpeed } else { ($speed * 0.6) + ($deltaSpeed * 0.4) }
            $lastTick = $now
            $lastDone = $done
        }

        # ---- 每 2 秒读一次 robocopy 日志的新增部分 ----
        if (($now - $lastTail).TotalSeconds -ge 2) {
            $lastTail = $now
            foreach ($ln in (Read-LogTailLines -Path $rcLog -State $tailState)) {
                $ff = ConvertFrom-RobocopyErrorLine -Line $ln -Source $Config.SourcePath
                if (-not $ff) { continue }
                if (Add-UINotice -Level 'Warn' -Reason $ff.Reason -Target $ff.Rel -Key ('ROBO|' + $ff.Full)) {
                    Write-Log ("实时检测到无法复制：{0}（{1}）" -f $ff.Rel, $ff.Reason) -Level WARN -LogFile $logFile
                }
            }
        }

        if ($totalBytes -gt 0) {
            $pct = 20 + [int](78.0 * ([double]$done / [double]$totalBytes))
        } else {
            $pct = 60
        }
        if ($pct -lt $monoPct) { $pct = $monoPct }
        $monoPct = $pct

        if (($now - $lastUi).TotalMilliseconds -ge 500) {
            $lastUi = $now
            # 主行只放体量，速度/ETA 放到下面那行小字 —— 挤成一行会很长
            $detail = '{0:N2} GB / {1:N2} GB' -f ($done/1GB), ($totalBytes/1GB)
            $meta   = '{0:N0} MB/s' -f ($speed/1MB)
            if ($speed -gt 0 -and $totalBytes -gt $done) {
                $eta = ($totalBytes - $done) / $speed
                if ($eta -lt 86400) {
                    $meta += ' · 剩余约 {0}' -f ([TimeSpan]::FromSeconds([int]$eta)).ToString('hh\:mm\:ss')
                }
            }
            Update-ProgressUI -Title '正在同步' -Detail $detail -Percent $pct -State 'Work'
            Set-UIMeta $meta
        }
    }

    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    Write-Log ("robocopy 退出码 {0}" -f $exitCode) -LogFile $logFile

    # ---- 步骤 6：结果判定 ----
    Start-Sleep -Milliseconds 400   # 等 robocopy 把日志尾部刷完
    $summary = Get-RobocopySummary -LogFile $rcLog
    if ($summary.Raw) {
        Add-Content -LiteralPath $logFile -Value "`r`n--- robocopy 原始输出 ---`r`n$($summary.Raw)" -Encoding UTF8
    }

    # ---- 步骤 6.4：先落盘 ----
    # 不论 robocopy 成功与否，只要动过盘就必须把写缓存刷进闪存。
    # 原来"退出码 ≥8 就直接 return"会跳过这一步：用户看到红色失败提示后拔盘，
    # 而已经写进去的那些文件可能还停在系统缓存里，比同步失败本身危险得多。
    Update-ProgressUI -Title '正在落盘' -Detail '刷新写缓存…' -Percent ([Math]::Min($monoPct + 2, 98)) -State 'Work'
    [void](Sync-VolumeCache -Letter $vol.Letter -LogFile $logFile)

    # ---- 用户中途点了「停止同步」 ----
    if ($cancelled) {
        $msg = '已按你的操作停止同步，已写入的文件保留在硬盘上'
        Write-Log $msg -Level WARN -LogFile $logFile
        [void](Add-UINotice -Level 'Warn' -Reason '同步已停止' -Target '你点了「停止同步」，剩下的文件没有复制' -Advice '再点「立即同步」会从断点接着做，已完成的文件不会重传')
        Update-ProgressUI -Title '已停止' -Detail '已写入的文件保留在硬盘上' -Hint '再次同步会从断点继续' -Percent 0 -State 'Warn'
        if (-not (Test-UIAlive)) {
            [void](Show-Toast -Title 'FileSync · 已停止' -Text $msg -Level 'Warn' -Seconds 6)
        }
        Close-ProgressWindow -DelaySeconds $(if ($Auto) { 10 } else { 12 })
        $result.Code = 'CANCELLED'
        $result.Message = $msg
        $result.Elapsed = $sw.Elapsed
        return $result
    }

    # ---- 步骤 6.5：退出码分级 ----
    # 16 及以上：致命错误，基本没复制成功任何东西
    # 8~15    ：部分文件失败（最常见是 Word/Excel 正开着造成共享冲突），其余已同步
    # 0~7     ：全部正常，是成功码
    $isFatal   = ($exitCode -ge 16)
    $failFiles = @()
    if ($exitCode -ge 8 -and -not $isFatal) {
        $failFiles = @(Get-RobocopyFailedFiles -LogFile $rcLog -Source $Config.SourcePath)
    }

    if ($isFatal) {
        $msg = "robocopy 执行失败（退出码 $exitCode），未完成任何复制，详见日志"
        Write-Log $msg -Level ERROR -LogFile $logFile
        if ($exitCode -eq 16 -and $diskWarned) { $msg = '同步中断：硬盘已断开或无法写入' }
        [void](Add-UINotice -Level 'Error' -Reason '复制失败' -Target $msg -Advice '硬盘上的内容可能只更新了一部分。重新插好硬盘后再同步一次即可补齐')
        Update-ProgressUI -Title '同步失败' -Detail $msg -Hint '请重新插好硬盘后再试' -Percent 0 -State 'Error'
        if (-not (Test-UIAlive)) {
            [void](Show-Toast -Title 'FileSync · 同步失败' -Text $msg -Level 'Error' -Seconds 8)
        }
        Close-ProgressWindow -DelaySeconds 25
        $result.Code = 'ROBOFAIL'; $result.Message = $msg
        $result.Elapsed = $sw.Elapsed
        return $result
    }

    if ($exitCode -ge 8) {
        Write-Log ("robocopy 退出码 {0}：有 {1} 处无法复制，其余已同步" -f $exitCode, [Math]::Max(1, $failFiles.Count)) -Level WARN -LogFile $logFile
        if ($failFiles.Count -gt 0) {
            foreach ($ff in ($failFiles | Select-Object -First 20)) {
                Write-Log ("    未能复制：{0}    （{1}）" -f $ff.Rel, $ff.Reason) -Level WARN -LogFile $logFile
            }
            if ($failFiles.Count -gt 20) {
                Write-Log ("    … 另有 {0} 个" -f ($failFiles.Count - 20)) -Level WARN -LogFile $logFile
            }
            # 落进通知清单。实时轮询已经加过的不再重复（同一个 Key）。
            foreach ($ff in $failFiles) {
                [void](Add-UINotice -Level 'Warn' -Reason $ff.Reason -Target $ff.Rel -Key ('ROBO|' + $ff.Full) -Advice '这些文件正被其他程序打开，关闭它们后重新插一次硬盘即可补上')
            }
        } else {
            Write-Log '    日志中未能解析出具体文件，请查看 robocopy 日志' -Level WARN -LogFile $logFile
            [void](Add-UINotice -Level 'Warn' -Reason '有文件未复制' -Target '日志里没能解析出具体文件，详见 logs 目录' -Advice '打开 robocopy 日志搜索「错误」可定位具体文件')
        }
    }

    # ---- 步骤 6.6：补建源端存在但目标端缺失的目录（含空目录） ----
    $missingDirs = @($cmp.MissingDirs)
    $dirsCreated = 0
    if ($missingDirs.Count -gt 0) {
        foreach ($d in $missingDirs) {
            $full = Join-Path $targetPath $d
            if (-not (Test-Path -LiteralPath $full)) {
                try {
                    New-Item -ItemType Directory -Path $full -Force -ErrorAction Stop | Out-Null
                    $dirsCreated++
                } catch {
                    Write-Log ("建目录失败 {0} : {1}" -f $d, $_.Exception.Message) -Level WARN -LogFile $logFile
                }
            }
        }
        Write-Log ("补建目录 {0} 个" -f $dirsCreated) -LogFile $logFile
        if ($dirsCreated -lt $missingDirs.Count) {
            [void](Add-UINotice -Level 'Warn' -Reason '建目录失败' -Target ("{0} 个空目录没能建出来" -f ($missingDirs.Count - $dirsCreated)) -Advice '不影响文件内容，但硬盘上会缺这几个空文件夹')
        }
        # 建目录也是写操作，同样要落盘
        if ($dirsCreated -gt 0) { [void](Sync-VolumeCache -Letter $vol.Letter -LogFile $logFile) }
    }

    # ---- 步骤 7：结果报告 ----
    $sw.Stop()
    $elapsedSec = [int]$sw.Elapsed.TotalSeconds
    $elapsedText = ([TimeSpan]::FromSeconds($elapsedSec)).ToString('mm\:ss')

    # 以 robocopy 摘要里的"复制"列作为实际复制数。
    # 用待复制数会在部分失败时虚报（待复制 3 个、实际只成功 2 个），
    # 用户会以为都同步好了。
    $realCopied = $copyCount
    if ($summary.CopiedCount -ge 0) { $realCopied = $summary.CopiedCount }
    if (-not $realCopied -or $realCopied -lt 0) { $realCopied = 0 }

    $detailDone = '复制 {0} 个文件 · {1:N2} GB · 用时 {2}' -f $realCopied, ($copyBytes/1GB), $elapsedText
    if ($mvOk -gt 0) { $detailDone += (" · 移动 {0} 个" -f $mvOk) }
    if ($delCount -gt 0) {
        $detailDone += (" · 删除 {0} 个" -f $delCount)
    }

    $hintDone = '可以安全拔出硬盘'
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { $hintDone = '请先「安全删除硬件」再拔盘' }

    $result.Copied = $realCopied
    $result.CopyBytes = $copyBytes
    $result.Deleted = $delCount
    $result.Elapsed = $sw.Elapsed
    $result.FailFiles = $failFiles

    # 有文件没复制成功：报"部分完成"而不是"成功"，并把原因摆到用户眼前
    # 注意 $exitCode -ge 8 但解析不出具体文件时（日志格式变化）也必须报部分完成，
    # 否则会把"有失败"谎报成"全部成功"，用户下次插盘才发现少了东西。
    if ($failFiles.Count -gt 0 -or $exitCode -ge 8) {
        if ($failFiles.Count -gt 0) {
            $names = ($failFiles | Select-Object -First 3 | ForEach-Object { $_.Rel }) -join '、'
            $detailPart = ("{0} 个文件未能复制" -f $failFiles.Count)
            # 这里只说"原因类别"，具体文件清单由窗口下方的通知列表展示，
            # 两边都写文件名会重复，还容易互相挤位。
            $reasons = @($failFiles | ForEach-Object { $_.Reason } | Select-Object -Unique)
            if ($reasons.Count -eq 1 -and $reasons[0] -eq '文件被占用') {
                $hintPart = '这些文件正被程序打开，关闭后重新插入硬盘即可补上'
            } else {
                $hintPart = '其余文件已同步，缺失的列在下方'
            }
        } else {
            $names = '详见 robocopy 日志'
            $detailPart = '有文件未能复制'
            $hintPart = '其余文件已同步，缺失的列在下方'
        }
        Write-Log ('同步部分完成：' + $detailDone) -Level WARN -LogFile $logFile
        Write-Log ("  {0}：{1}" -f $detailPart, $names) -Level WARN -LogFile $logFile
        # 进度条走琥珀色而不是红色：数据确实同步了绝大部分，红色会让人以为整次同步作废。
        # 标题不再带"3 个文件未能复制"——下面的问题卡片已经写了，重复两遍是噪音。
        Update-ProgressUI -Title '部分完成' -Detail $detailDone -Hint $hintPart -Percent 100 -State 'Warn'
        Set-UIStatus -LastSync '刚刚' -Connected $true
        if (-not (Test-UIAlive)) {
            [void](Show-Toast -Title ('FileSync · 部分完成：' + $detailPart) -Text (("其余已同步。" + $hintPart)) -Level 'Warn' -Seconds 8)
        }
        Close-ProgressWindow -DelaySeconds $(if ($Auto) { 30 } else { 20 })
        $result.Ok = $true
        $result.Code = 'PARTIAL'
        $result.Message = ($detailDone + ' · ' + $detailPart)
        return $result
    }

    Write-Log ('同步完成：' + $detailDone) -Level OK -LogFile $logFile
    Set-UIStatus -LastSync '刚刚' -Connected $true
    # 同步成功但过程中有非致命提醒（例如写缓存刷新失败），标题要体现出来
    $nc = Get-UINoticeCount
    if ($nc -gt 0) {
        Update-ProgressUI -Title ('同步完成 · 有 {0} 条提醒' -f $nc) -Detail $detailDone -Hint '提醒不影响本次结果，详见下方' -Percent 100 -State 'Done'
    } else {
        Update-ProgressUI -Title '同步完成' -Detail $detailDone -Hint $hintDone -Percent 100 -State 'Done'
    }
    Close-ProgressWindow -DelaySeconds $(if ($Auto) { 25 } else { 8 })

    $result.Ok = $true
    $result.Code = 'SUCCESS'
    $result.Message = $detailDone
    return $result
}

<#
    Copy-TwoWaySnapshot
    把一个将要被删/被覆盖的文件按原目录结构存进 _SyncHistory\<时间戳>\。
    返回快照目录（第一次调用时创建），调用方要接住作为 Cur 传回来。
#>
function Copy-TwoWaySnapshot {
    param(
        [string]$HistRoot,
        [string]$Stamp,
        [string]$Cur,
        [string]$File,
        [string]$Rel
    )
    $dir = $Cur
    if (-not $dir) {
        $dir = Join-Path $HistRoot $Stamp
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $dst = Join-Path $dir $Rel
    $dstDir = Split-Path -Parent $dst
    if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) {
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    }
    $try = 0
    while ($true) {
        try { Copy-Item -LiteralPath $File -Destination $dst -Force -ErrorAction Stop; break }
        catch { $try++; if ($try -ge 3) { break }; Start-Sleep -Milliseconds 200 }
    }
    return $dir
}

<#
    Read-TwoWayManifest
    读基线清单（rel → @{s=大小; t=UTC ticks}）。没有/损坏返回空表（不传播删除）。
#>
function Read-TwoWayManifest {
    param([string]$ManifestPath)
    $manifest = @{}
    if (Test-Path -LiteralPath $ManifestPath) {
        try {
            $mj = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $mj.PSObject.Properties) {
                $manifest[[string]$p.Name] = @{ s = [long]$p.Value.s; t = [long]$p.Value.t }
            }
        } catch { $manifest = @{} }
    }
    return $manifest
}

<#
    Invoke-TwoWayHistory
    双向同步的删除识别与版本历史阶段：
      1. 读上次基线清单
      2. 扫描两端现状
      3. "清单里有、这次只剩一边、现存一边没改过" → 判定为另一边删除 → 快照 + 传播删除
         "现存一边改过了" → 修改优先于删除，保留（robocopy 会把改动拷回去）
      4. 两端都在但内容不同的文件，旧的那份将被覆盖 → 先快照
    返回 MapL / MapD（处理后的两端文件表）、DelOnDisk / DelOnLocal / KeepModified。
#>
function Invoke-TwoWayHistory {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$HistRoot,
        [string]$ManifestPath,
        [string[]]$ExDirs,
        [string[]]$ExFiles,
        [string]$LogFile
    )

    $manifest = Read-TwoWayManifest -ManifestPath $ManifestPath
    if ($manifest.Count -gt 0) {
        Write-Log ("基线清单：{0} 个文件（上次同步成功时）" -f $manifest.Count) -LogFile $LogFile
    } else {
        Write-Log '没有基线清单（首次双向同步），本次只做合并、不传播删除' -LogFile $LogFile
    }

    Update-ProgressUI -Title '正在扫描两端文件' -Detail '对照基线识别删除…' -Percent 6 -State 'Work'
    $mapL = (Get-FileMap -Root $SourcePath -ExcludeDirs $ExDirs -ExcludeFiles $ExFiles).Map
    $mapD = (Get-FileMap -Root $TargetPath  -ExcludeDirs $ExDirs -ExcludeFiles $ExFiles).Map

    $delOnDisk    = New-Object System.Collections.ArrayList   # 本地删了 → 删硬盘那份
    $delOnLocal   = New-Object System.Collections.ArrayList   # 硬盘删了 → 删本地那份
    $keepModified = 0
    $snapDir   = $null
    $stampHist = Get-Date -Format 'yyyyMMdd-HHmmss'

    foreach ($rel in @($manifest.Keys)) {
        $inL = $mapL.ContainsKey($rel)
        $inD = $mapD.ContainsKey($rel)
        if ($inL -and $inD) { continue }
        if (-not $inL -and -not $inD) { continue }   # 两边都删了：新清单自然不含它

        $m = $manifest[$rel]
        if (-not $inL) {
            # 本地没了，硬盘还有 → 本地删的？（除非硬盘上的版本改过）
            $d = $mapD[$rel]
            if ($d.Size -eq $m.s -and $d.Ticks -eq $m.t) {
                $snapDir = Copy-TwoWaySnapshot -HistRoot $HistRoot -Stamp $stampHist -Cur $snapDir -File (Join-Path $TargetPath $rel) -Rel $rel
                try {
                    Remove-Item -LiteralPath (Join-Path $TargetPath $rel) -Force -ErrorAction Stop
                    $mapD.Remove($rel)
                    [void]$delOnDisk.Add($rel)
                } catch {
                    [void](Add-UINotice -Level 'Warn' -Reason '删除传播失败（硬盘侧）' -Target $rel -Advice '文件可能被占用，下次同步会再试')
                }
            } else {
                $keepModified++   # 硬盘上的版本后来被改过：修改优先，待会拷回本地
            }
        } else {
            # 硬盘没了，本地还有 → 硬盘删的？（除非本地上的版本改过）
            $l = $mapL[$rel]
            if ($l.Size -eq $m.s -and $l.Ticks -eq $m.t) {
                $snapDir = Copy-TwoWaySnapshot -HistRoot $HistRoot -Stamp $stampHist -Cur $snapDir -File (Join-Path $SourcePath $rel) -Rel $rel
                try {
                    Remove-Item -LiteralPath (Join-Path $SourcePath $rel) -Force -ErrorAction Stop
                    $mapL.Remove($rel)
                    [void]$delOnLocal.Add($rel)
                } catch {
                    [void](Add-UINotice -Level 'Warn' -Reason '删除传播失败（本地侧）' -Target $rel -Advice '文件可能被占用，下次同步会再试')
                }
            } else {
                $keepModified++
            }
        }
    }

    # 覆盖快照：两端都在但内容不同的文件，旧的那份会被 robocopy 覆盖，先存历史
    foreach ($rel in @($mapL.Keys)) {
        if (-not $mapD.ContainsKey($rel)) { continue }
        $l = $mapL[$rel]; $d = $mapD[$rel]
        if ($l.Size -eq $d.Size -and $l.Ticks -eq $d.Ticks) { continue }
        if ($d.Ticks -lt $l.Ticks) {
            $snapDir = Copy-TwoWaySnapshot -HistRoot $HistRoot -Stamp $stampHist -Cur $snapDir -File (Join-Path $TargetPath $rel) -Rel $rel
        } elseif ($l.Ticks -lt $d.Ticks) {
            $snapDir = Copy-TwoWaySnapshot -HistRoot $HistRoot -Stamp $stampHist -Cur $snapDir -File (Join-Path $SourcePath $rel) -Rel $rel
        } else {
            # 时间相同、大小不同：分不出新旧，robocopy 会以本地为准，快照硬盘那份
            $snapDir = Copy-TwoWaySnapshot -HistRoot $HistRoot -Stamp $stampHist -Cur $snapDir -File (Join-Path $TargetPath $rel) -Rel $rel
        }
    }

    if ($delOnDisk.Count -gt 0 -or $delOnLocal.Count -gt 0 -or $keepModified -gt 0 -or $snapDir) {
        Write-Log ("删除传播：硬盘侧 {0} 个、本地侧 {1} 个；{2} 个文件因另一端改过而保留；历史快照已记录" -f $delOnDisk.Count, $delOnLocal.Count, $keepModified) -LogFile $LogFile
    }

    return [pscustomobject]@{
        MapL         = $mapL
        MapD         = $mapD
        DelOnDisk    = $delOnDisk
        DelOnLocal   = $delOnLocal
        KeepModified = $keepModified
        SnapDir      = $snapDir
    }
}

<#
    Save-TwoWayManifest
    重新扫描两端，把当前状态写成基线清单（下次同步的删除识别依据）。
#>
function ConvertTo-JsonText {
    param([string]$S)
    if ($null -eq $S) { return '""' }
    return '"' + $S.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t') + '"'
}

function Save-TwoWayManifest {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$ManifestPath,
        [string[]]$ExDirs,
        [string[]]$ExFiles
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ManifestPath) | Out-Null
    $finalL = (Get-FileMap -Root $SourcePath -ExcludeDirs $ExDirs -ExcludeFiles $ExFiles).Map
    $finalD = (Get-FileMap -Root $TargetPath  -ExcludeDirs $ExDirs -ExcludeFiles $ExFiles).Map
    $sbM = New-Object System.Text.StringBuilder
    [void]$sbM.Append('{')
    $first = $true
    foreach ($k in @($finalL.Keys)) {
        $v = $finalL[$k]
        if (-not $first) { [void]$sbM.Append(',') }
        $first = $false
        [void]$sbM.Append((ConvertTo-JsonText $k)).Append(':{').Append('"s":').Append([long]$v.Size).Append(',"t":').Append([long]$v.Ticks).Append('}')
    }
    foreach ($k in @($finalD.Keys)) {
        if ($finalL.ContainsKey($k)) { continue }
        $v = $finalD[$k]
        if (-not $first) { [void]$sbM.Append(',') }
        $first = $false
        [void]$sbM.Append((ConvertTo-JsonText $k)).Append(':{').Append('"s":').Append([long]$v.Size).Append(',"t":').Append([long]$v.Ticks).Append('}')
    }
    [void]$sbM.Append('}')
    [System.IO.File]::WriteAllText($ManifestPath, $sbM.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    $unionSeen = @{}
    foreach ($k in @($finalL.Keys)) { $unionSeen[$k] = $true }
    foreach ($k in @($finalD.Keys)) { $unionSeen[$k] = $true }
    return $unionSeen.Count
}

<#
    Prune-TwoWayHistory
    快照只保留最近 Keep 份（默认 5，Time Machine 式）。
#>
function Prune-TwoWayHistory {
    param([string]$HistRoot, [int]$Keep = 5)
    if (-not (Test-Path -LiteralPath $HistRoot)) { return 0 }
    $old = @(Get-ChildItem -LiteralPath $HistRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending)
    $i = 0
    foreach ($s in $old) {
        $i++
        if ($i -gt $Keep) { Remove-Item -LiteralPath $s.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $old.Count
}

<#
    Invoke-TwoWaySync
    双向同步：本地 ↔ 硬盘，两趟 robocopy（/E /XO，不带 /MIR /PURGE）
    + 基线清单驱动的删除传播 + Time Machine 式版本历史。

    规则：
      · 一边新增的文件 → 拷到另一边
      · 两边都改 → 谁的时间新保留谁的，旧版本先存进历史快照
      · 一边删除 → 传播删除到另一边，被删的文件先存进历史快照
        （判定依据：上次同步成功时写的基线清单；若现存一边在清单之后改过，
         修改优先于删除——不删，把改动拷回去）
      · 历史快照存在磁盘根目录 _SyncHistory\<时间戳>\，保留最近 5 份，
        网页「硬盘」页可以浏览并一键恢复到两边
#>
function Invoke-TwoWaySync {
    param(
        $Config = $null,
        [switch]$NoWindow,
        [switch]$Auto,
        [switch]$Force,
        $Hardware = $null,
        [string]$FixedTargetRoot = ''
    )

    if (-not $Config) { $Config = Get-SyncConfig }
    $opt = $Config.Options

    $logDir = Join-Path $script:RootDir ([string]$Config.LogDir)
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile = Join-Path $logDir ("sync-{0}.log" -f $stamp)
    $rcLogA  = Join-Path $logDir ("robocopy-{0}.log" -f $stamp)
    $rcLogB  = Join-Path $logDir ("robocopy-toLocal-{0}.log" -f $stamp)

    $result = [pscustomobject]@{
        Ok          = $false
        Code        = ''
        Message     = ''
        Copied      = 0
        CopyBytes   = [long]0
        Deleted     = 0
        SourceCount = 0
        SourceBytes = [long]0
        TargetRoot  = ''
        FailFiles   = @()
        Elapsed     = [TimeSpan]::Zero
        LogFile     = $logFile
        RcLog       = $rcLogA
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $showWindow = (-not $NoWindow) -and ($opt.ShowProgressWindow -ne $false)

    Write-Log "===== 双向同步任务开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====" -LogFile $logFile
    Write-Log ("源：{0}   （双向模式：两边互相补齐，删除不传播）" -f $Config.SourcePath) -LogFile $logFile

    if ($showWindow) { [void](New-ProgressWindow -Title '正在准备同步（双向）' -Compact:$Auto) }
    Clear-UINotice

    if ($FixedTargetRoot) {
        Update-ProgressUI -Title '正在准备同步（双向）' -Detail ('目的地：' + $FixedTargetRoot) -Hint '' -Percent 2 -State 'Work'
        Write-Log ("目标：本地文件夹目的地（{0}）" -f $FixedTargetRoot) -LogFile $logFile
        $vol = [pscustomobject]@{ Letter = $FixedTargetRoot.Substring(0, 1); Label = ''; FreeBytes = [long]0 }
        try {
            $vn = Get-Volume -DriveLetter $vol.Letter -ErrorAction Stop
            if ($vn) {
                $vol | Add-Member -NotePropertyName FreeBytes -NotePropertyValue ([long]$vn.SizeRemaining) -Force
                $vol.Label = [string]$vn.FileSystemLabel
            }
        } catch { }
        Set-UIStatus -Connected $true
    } else {
        Update-ProgressUI -Title '正在识别移动硬盘' -Detail '按硬件序列号校验…' -Hint '请勿拔出硬盘' -Percent 2 -State 'Work'

        $disk = Resolve-TargetDrive -Config $Config -Hardware $Hardware
        if (-not $disk.Ok) {
            Write-Log $disk.Message -Level ERROR -LogFile $logFile
            [void](Add-UINotice -Level 'Error' -Reason '硬盘未就绪' -Target $disk.Message -Advice '未对目标做任何改动。插好目的地硬盘后重新运行即可')
            Update-ProgressUI -Title '同步未开始' -Detail $disk.Message -Hint '未对目标做任何改动' -Percent 0 -State 'Error'
            Close-ProgressWindow -DelaySeconds $(if ($Auto) { 8 } else { 12 })
            $result.Code = $disk.Code
            $result.Message = $disk.Message
            return $result
        }
        Write-Log $disk.Message -Level OK -LogFile $logFile
        $vol = $disk.Volume
        Set-UIStatus -Connected $true -DiskLetter ([string]$vol.Letter) -DiskName ([string]$vol.Label)
    }

    Update-ProgressUI -Title '正在校验同步条件' -Detail '检查源目录与目标路径…' -Percent 5 -State 'Work'
    $envCheck = Test-SyncEnvironment -Config $Config -Volume $vol -FixedTargetRoot $FixedTargetRoot
    if (-not $envCheck.Ok) {
        Write-Log $envCheck.Message -Level ERROR -LogFile $logFile
        [void](Add-UINotice -Level 'Error' -Reason '环境校验未通过' -Target $envCheck.Message -Advice '这是保护机制，硬盘未做任何改动，按提示处理后可重试')
        Update-ProgressUI -Title '同步已中止' -Detail $envCheck.Message -Hint '这是保护机制，请检查后重试' -Percent 0 -State 'Error'
        Close-ProgressWindow -DelaySeconds 15
        $result.Code = 'ENVCHECK'
        $result.Message = $envCheck.Message
        return $result
    }
    $targetPath = $envCheck.TargetPath
    $targetRoot = $envCheck.TargetRoot
    Write-Log ("目标：{0}" -f $targetPath) -LogFile $logFile

    # ---- 版本历史 + 基线清单（Time Machine 式删除保护）----
    # 历史：磁盘根目录的 _SyncHistory\<时间戳>\ —— 在两端同步范围之外，不会被拷也不会被删
    # 清单：manifest.json 记录上次同步成功时两边的全部文件（相对路径 → 大小 + 修改时间）
    # 有了清单才能分辨"一边删了文件"（传播删除 + 先进历史）和"一边新增了文件"（正常拷贝）
    # 历史/清单位置：盘目的地放卷根（同步范围之外）；文件夹目的地放目标文件夹内
    #（名字 _SyncHistory 已在排除清单里，不会被拷、不会被删）
    if ($FixedTargetRoot) {
        $histRoot     = Join-Path $targetPath '_SyncHistory'
    } else {
        $histRoot     = Join-Path $targetRoot '_SyncHistory'
    }
    $manifestPath = Join-Path $histRoot 'manifest.json'
    $exDirs  = @($opt.ExcludeDirs | Where-Object { $_ }) + @([string]$opt.BackupFolderName) + @('_SyncHistory')
    $exFiles = @($opt.ExcludeFiles | Where-Object { $_ })
    $exe = Get-RobocopyPath

    $hist = Invoke-TwoWayHistory -SourcePath $Config.SourcePath -TargetPath $targetPath `
        -HistRoot $histRoot -ManifestPath $manifestPath -ExDirs $exDirs -ExFiles $exFiles `
        -LogFile $logFile
    $mapL         = $hist.MapL
    $mapD         = $hist.MapD
    $delOnDisk    = $hist.DelOnDisk
    $delOnLocal   = $hist.DelOnLocal
    $keepModified = $hist.KeepModified

    function New-TwoWayArgs {
        param([string]$Src, [string]$Dst, [string]$Log)
        $a = New-Object System.Collections.ArrayList
        [void]$a.Add(('"{0}"' -f $Src))
        [void]$a.Add(('"{0}"' -f $Dst))
        # 关键三件套：/E 只补齐不删除；/XO 跳过"目标端更新"的文件（新者保留）；
        # 不带 /MIR /PURGE —— 绝不删除另一端的内容
        [void]$a.Add('/E')
        [void]$a.Add('/XO')
        [void]$a.Add(('/R:{0}' -f $(if ($opt.RetryCount)   { $opt.RetryCount }   else { 3 })))
        [void]$a.Add(('/W:{0}' -f $(if ($opt.RetryWaitSec) { $opt.RetryWaitSec } else { 2 })))
        [void]$a.Add(('/MT:{0}' -f $(if ($opt.Threads)     { $opt.Threads }     else { 8 })))
        [void]$a.Add('/NP'); [void]$a.Add('/NFL'); [void]$a.Add('/NDL'); [void]$a.Add('/NJH')
        [void]$a.Add('/XD')
        foreach ($d in $exDirs)  { [void]$a.Add(('"{0}"' -f $d)) }
        [void]$a.Add('/XF')
        foreach ($f in $exFiles) { [void]$a.Add(('"{0}"' -f $f)) }
        [void]$a.Add(('/LOG:"{0}"' -f $Log))
        return $a
    }

    function Wait-TwoWayPass {
        param($Proc, [string]$PhaseTitle, [string]$PhaseDetail, [int]$PctFrom, [int]$PctTo)
        $t0 = Get-Date
        while (-not $Proc.HasExited) {
            $secs = ((Get-Date) - $t0).TotalSeconds
            $pct = [Math]::Min($PctTo, [int]($PctFrom + ($PctTo - $PctFrom) * (1 - [Math]::Exp(-$secs / 60))))
            Update-ProgressUI -Title $PhaseTitle -Detail $PhaseDetail -Hint '请勿拔出硬盘' -Percent $pct -State 'Work'
            Invoke-UIPump
            Start-Sleep -Milliseconds 250
        }
    }

    # ---- 第一趟：本地 → 硬盘 ----
    Update-ProgressUI -Title '双向同步 · 本地 → 硬盘' -Detail '把本地新增和改动的文件补到硬盘…' -Percent 10 -State 'Work'
    $argsA = New-TwoWayArgs -Src $Config.SourcePath -Dst $targetPath -Log $rcLogA
    $procA = $null
    try { $procA = Start-Process -FilePath $exe -ArgumentList $argsA -WindowStyle Hidden -PassThru } catch {
        $msg = ('robocopy 启动失败：' + $_.Exception.Message)
        Write-Log $msg -Level ERROR -LogFile $logFile
        Update-ProgressUI -Title '同步失败' -Detail $msg -Hint '' -Percent 0 -State 'Error'
        Close-ProgressWindow -DelaySeconds 12
        $result.Code = 'STARTFAIL'; $result.Message = $msg
        return $result
    }
    Wait-TwoWayPass -Proc $procA -PhaseTitle '双向同步 · 本地 → 硬盘' -PhaseDetail '正在复制…' -PctFrom 12 -PctTo 45
    $codeA = $procA.ExitCode
    $sumA  = Get-RobocopySummary -LogFile $rcLogA
    $aCopied = [Math]::Max(0, [int]$sumA.CopiedCount)
    $aFailed = [Math]::Max(0, [int]$sumA.FailedCount)
    Write-Log ("本地 → 硬盘：robocopy 退出码 {0}，复制 {1} 个，失败 {2} 个" -f $codeA, $aCopied, $aFailed) -LogFile $logFile
    if ($codeA -ge 8) {
        [void](Add-UINotice -Level 'Error' -Reason '本地 → 硬盘有失败' -Target ("{0} 个文件复制失败，详见日志" -f $aFailed) -Advice '常见原因：文件被占用、路径过长。日志里有完整清单')
    }

    # ---- 第二趟：硬盘 → 本地 ----
    Update-ProgressUI -Title '双向同步 · 硬盘 → 本地' -Detail '把硬盘上新增和改动的文件补回本地…' -Percent 55 -State 'Work'
    $argsB = New-TwoWayArgs -Src $targetPath -Dst $Config.SourcePath -Log $rcLogB
    $procB = Start-Process -FilePath $exe -ArgumentList $argsB -WindowStyle Hidden -PassThru
    Wait-TwoWayPass -Proc $procB -PhaseTitle '双向同步 · 硬盘 → 本地' -PhaseDetail '正在复制…' -PctFrom 55 -PctTo 88
    $codeB = $procB.ExitCode
    $sumB  = Get-RobocopySummary -LogFile $rcLogB
    $bCopied = [Math]::Max(0, [int]$sumB.CopiedCount)
    $bFailed = [Math]::Max(0, [int]$sumB.FailedCount)
    Write-Log ("硬盘 → 本地：robocopy 退出码 {0}，复制 {1} 个，失败 {2} 个" -f $codeB, $bCopied, $bFailed) -LogFile $logFile
    if ($codeB -ge 8) {
        [void](Add-UINotice -Level 'Error' -Reason '硬盘 → 本地有失败' -Target ("{0} 个文件复制失败，详见日志" -f $bFailed) -Advice '常见原因：本地文件被占用。日志里有完整清单')
    }

    # ---- 重新扫描两端，写回基线清单（下次同步的删除识别依据）----
    Update-ProgressUI -Title '正在记录同步基线' -Detail '为下次删除识别写清单…' -Percent 92 -State 'Work'
    try {
        $mc = Save-TwoWayManifest -SourcePath $Config.SourcePath -TargetPath $targetPath `
            -ManifestPath $manifestPath -ExDirs $exDirs -ExFiles $exFiles
        Write-Log ("基线清单已更新：{0} 个文件" -f $mc) -LogFile $logFile
    } catch {
        Write-Log ('写基线清单失败（下次同步将不传播删除）：' + $_.Exception.Message) -Level WARN -LogFile $logFile
    }

    # ---- 快照只保留最近 5 份（Time Machine 式）----
    try { [void](Prune-TwoWayHistory -HistRoot $histRoot -Keep 5) } catch { }

    Set-UIStatus -LastSync '刚刚' -Connected $true

    $totalCopied = $aCopied + $bCopied
    $totalFailed = $aFailed + $bFailed
    $totalDel = $delOnDisk.Count + $delOnLocal.Count
    $detail = ("双向同步完成：本地→硬盘 {0} 个，硬盘→本地 {1} 个" -f $aCopied, $bCopied)
    if ($totalDel -gt 0) { $detail += ("，删除已同步 {0} 个" -f $totalDel) }
    if ($keepModified -gt 0) { $detail += ("，{0} 个因另一端改过而保留" -f $keepModified) }
    if ($totalFailed -gt 0) { $detail += ("，失败 {0} 个" -f $totalFailed) }
    Write-Log ('双向同步完成：' + $detail) -Level $(if ($totalFailed -gt 0) { 'WARN' } else { 'OK' }) -LogFile $logFile

    if ($totalCopied -eq 0 -and $totalFailed -eq 0 -and $totalDel -eq 0) {
        Update-ProgressUI -Title '已是最新' -Detail '两端没有需要互相补齐的文件' -Hint '可以安全拔出硬盘' -Percent 100 -State 'Done'
        Close-ProgressWindow -DelaySeconds $(if ($Auto) { 6 } else { 8 })
        $result.Ok = $true; $result.Code = 'UPTODATE'; $result.Message = '两端已一致'
        $result.Elapsed = $sw.Elapsed
        return $result
    }

    if ($totalFailed -gt 0) {
        Update-ProgressUI -Title '双向同步 · 部分完成' -Detail $detail -Hint '失败明细见通知与日志' -Percent 100 -State 'Done'
        Close-ProgressWindow -DelaySeconds $(if ($Auto) { 30 } else { 20 })
        $result.Ok = $true; $result.Code = 'PARTIAL'; $result.Message = $detail
        $result.Copied = $totalCopied
        $result.Elapsed = $sw.Elapsed
        return $result
    }

    Update-ProgressUI -Title '双向同步完成' -Detail $detail -Hint '两边的新文件都已互相补齐' -Percent 100 -State 'Done'
    Close-ProgressWindow -DelaySeconds $(if ($Auto) { 25 } else { 8 })
    $result.Ok = $true; $result.Code = 'SUCCESS'; $result.Message = $detail
    $result.Copied = $totalCopied
    $result.Elapsed = $sw.Elapsed
    return $result
}

<#
    Invoke-SyncTask
    对外入口。除了执行同步，还负责三件"跨进程"的事：

      1. 单实例互斥。同时跑两个同步会互相破坏：一个正在把文件挪进备份区，
         另一个的 robocopy /MIR 会把它当成"目标端缺失"再拷回来，
         最坏情况是两边同时对同一批文件做重命名和删除。用一个系统级
         命名 Mutex 把并发挡住，第二个进场的直接返回 ALREADYBUSY。

      2. 成功后记录基线（state.json），供下次的变更幅度保护比较。

      3. 清理过期备份与日志，防止硬盘被历史备份慢慢吃满。
#>
function Invoke-SyncTask {
    param(
        $Config = $null,
        [switch]$DryRun,
        [switch]$NoWindow,
        [switch]$Auto,
        [switch]$Force
    )

    # 用 Global 前缀：远程桌面和本地会话可以同时登录同一账户，
    # Local\ 只在各自会话内有效，两个会话会同时跑同步。Global 创建失败就退回 Local。
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Global\FileSync_Sync_Invoke_v1')
    } catch {
        try { $mutex = New-Object System.Threading.Mutex($false, 'Local\FileSync_Sync_Invoke_v1') } catch { $mutex = $null }
    }

    if (-not $mutex) {
        # 连 Mutex 都建不出来（极端受限环境），直接执行，不阻塞主流程
        return Invoke-SyncTaskInternal -Config $Config -DryRun:$DryRun -NoWindow:$NoWindow -Auto:$Auto -Force:$Force
    }

    $got = $false
    try {
        $got = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # 上一个进程异常退出没释放锁。锁已经归我们了，继续。
        $got = $true
    }

    if (-not $got) {
        $script:SyncMutex = $null
        try { $mutex.Dispose() } catch { }
        $busyMsg = '已有另一个同步任务正在运行，本次已跳过（避免两个进程同时改动硬盘）'
        Write-Log $busyMsg -Level WARN
        return [pscustomobject]@{
            Ok = $false; Code = 'ALREADYBUSY'; Message = $busyMsg
            Copied = 0; CopyBytes = [long]0; Deleted = 0
            Elapsed = [TimeSpan]::Zero; LogFile = ''; RcLog = ''; FailFiles = @()
        }
    }

    $script:SyncMutex = $mutex
    try {
        # 同步方向分派：镜像（本地→硬盘，/MIR）或双向（两边互相补齐）
        $cfg0 = $Config
        if (-not $cfg0) { try { $cfg0 = Get-SyncConfig } catch { $cfg0 = $null } }
        $twoWay = $false
        if ($cfg0 -and $cfg0.Options -and $cfg0.Options.PSObject.Properties.Name -contains 'SyncMode') {
            $twoWay = ([string]$cfg0.Options.SyncMode -eq 'twoway')
        }

        if ($twoWay) {
            if ($DryRun) {
                Write-Log '双向同步模式暂不支持 -DryRun 预演，按正式执行处理' -Level WARN
            }
            $r = Invoke-TwoWaySync -Config $cfg0 -NoWindow:$NoWindow -Auto:$Auto -Force:$Force `
                -Hardware $(if ($cfg0.PSObject.Properties.Name -contains 'Hardware') { $cfg0.Hardware } else { $null }) `
                -FixedTargetRoot $(if ($cfg0.PSObject.Properties.Name -contains 'FixedTargetRoot') { [string]$cfg0.FixedTargetRoot } else { '' })
        } else {
            $r = Invoke-SyncTaskInternal -Config $Config -DryRun:$DryRun -NoWindow:$NoWindow -Auto:$Auto -Force:$Force `
                -Hardware $(if ($cfg0.PSObject.Properties.Name -contains 'Hardware') { $cfg0.Hardware } else { $null }) `
                -FixedTargetRoot $(if ($cfg0.PSObject.Properties.Name -contains 'FixedTargetRoot') { [string]$cfg0.FixedTargetRoot } else { '' })
        }

        # 预演和失败都不更新基线：基线代表"硬盘上真实确认过的状态"
        if (-not $DryRun -and $r -and $r.Ok) {
            $cfgNow = $Config
            if (-not $cfgNow) { try { $cfgNow = Get-SyncConfig } catch { $cfgNow = $null } }
            if ($cfgNow) {
                $st = Get-SyncState
                # 只在文件数是真值时写，避免 0 覆盖掉有效基线
                if ($r.Code -ne 'ALREADYBUSY') {
                    if ($r.PSObject.Properties['SourceCount'] -and $r.SourceCount) {
                        Save-SyncState -SourceCount $r.SourceCount -SourceBytes $r.SourceBytes -TargetLetter $r.TargetLetter -SourcePath $cfgNow.SourcePath
                    }
                }
                # 保留清理只在真正同步成功后做，失败时不碰硬盘
                if ($r.Code -eq 'SUCCESS' -or $r.Code -eq 'PARTIAL') {
                    $targetRootForCleanup = $null
                    if ($r.PSObject.Properties['TargetRoot']) { $targetRootForCleanup = $r.TargetRoot }
                    Invoke-RetentionCleanup -Config $cfgNow -TargetRoot $targetRootForCleanup -LogFile $r.LogFile
                }
            }
        }
        return $r
    }
    catch {
        # 未预料的异常：以前这里会直接把异常抛给调用方，进度窗没人关，
        # 变成一块点不掉的残影贴在右下角（点掉后下次同步也不会再出现提示）。
        $em = $_.Exception.Message
        Write-Log ('同步过程出现未预料的异常：' + $em) -Level ERROR
        Write-Log $_.ScriptStackTrace -Level ERROR
        [void](Add-UINotice -Level 'Error' -Reason '程序异常' -Target $em -Advice '同步可能只完成了一部分，重新运行一次即可继续补齐')
        if (Test-UIAlive) {
            Update-ProgressUI -Title '同步异常中断' -Detail $em -Hint '重新运行一次即可继续' -Percent 0 -State 'Error'
            Close-ProgressWindow -DelaySeconds 20
        } else {
            [void](Show-Toast -Title 'FileSync · 同步异常中断' -Text $em -Level 'Error' -Seconds 8)
        }
        return [pscustomobject]@{
            Ok = $false; Code = 'EXCEPTION'; Message = $em
            Copied = 0; CopyBytes = [long]0; Deleted = 0
            SourceCount = 0; SourceBytes = [long]0; TargetRoot = ''
            Elapsed = [TimeSpan]::Zero; LogFile = ''; RcLog = ''; FailFiles = @()
        }
    }
    finally {
        try { [void]$mutex.ReleaseMutex() } catch { }
        try { $mutex.Dispose() } catch { }
        $script:SyncMutex = $null
    }
}

# ============================================================
# 多任务编排：一次跑完所有可用的「源 → 目的地」配对
# ============================================================

<#
    Invoke-FileSyncRun
    v2 编排器。把 config.Tasks 摊平成配对，逐对执行：
      · disk 目的地：序列号匹配的硬盘插着才跑；-ArrivedSerial 指定时只跑刚插入的那块
      · folder 目的地：路径所在盘存在就跑（-OnlyFolder 只跑文件夹目的地，定时用）
    每对配对有自己的状态文件（_ipc\state\<PairId>.json），互不干扰。
#>
function Invoke-FileSyncRun {
    param(
        $Config = $null,
        [switch]$Auto,
        [switch]$NoWindow,
        [switch]$Force,
        [string]$ArrivedSerial = '',      # 插盘触发时：刚插入盘的任一序列号
        [switch]$OnlyFolder,              # 定时触发：只跑文件夹目的地
        [string[]]$OnlyPairs = @()        # 指定只跑这些 PairId（空 = 不限）
    )

    if (-not $Config) { $Config = Get-SyncConfig }
    $pairs = Get-SyncPairs -Config $Config

    $agg = [pscustomobject]@{
        Ok = $true; Code = ''; Message = ''
        Ran = 0; Skipped = 0; Copied = 0; Deleted = 0; Failed = 0
        Results = @()
    }
    if ($pairs.Count -eq 0) {
        $agg.Code = 'NOTASKS'
        $agg.Message = '还没有配置同步任务：到「设置 → 同步任务」里添加源目录和目的地'
        [void](Add-UINotice -Level 'Warn' -Reason '没有可同步的任务' -Target '到「设置 → 同步任务」里添加源目录和目的地' -Advice '添加后插盘或点「立即同步」即可')
        return $agg
    }

    $defaultStatePath = $script:StatePath
    $msgs = New-Object System.Collections.ArrayList

    foreach ($p in $pairs) {
        if ($OnlyPairs.Count -gt 0 -and $OnlyPairs -notcontains $p.PairId) { continue }

        # 可用性筛选
        if ($p.DestKind -eq 'disk') {
            if (-not (Test-DestAvailable -Pair $p)) {
                Write-Log ("跳过[{0}] {1} → {2}：目的地硬盘未插入" -f $p.TaskName, $p.Source, $p.DestLabel) -Level INFO
                $agg.Skipped++
                continue
            }
            # 插盘触发：只跑刚插入的那块盘的配对
            if ($ArrivedSerial) {
                $s = $p.Serials
                $hit = $false
                if ($s) {
                    foreach ($k in @('Disk', 'Phys', 'Volume')) {
                        $v = ([string]$s.PSObject.Properties[$k].Value).Trim().ToUpper()
                        if ($v -and $v -eq $ArrivedSerial) { $hit = $true; break }
                    }
                }
                if (-not $hit) { $agg.Skipped++; continue }
            }
        } elseif ($OnlyFolder -eq $false -and $ArrivedSerial) {
            # 插盘触发不跑文件夹目的地（它们由定时/手动负责）
            $agg.Skipped++; continue
        }

        # 组装该配对的合成配置
        $sc = $Config.PSObject.Copy()
        $sc | Add-Member -NotePropertyName SourcePath      -NotePropertyValue $p.Source -Force
        $sc | Add-Member -NotePropertyName TargetFolderName -NotePropertyValue $p.Sub -Force
        $sc | Add-Member -NotePropertyName Hardware        -NotePropertyValue $p.Serials -Force
        $sc | Add-Member -NotePropertyName FixedTargetRoot -NotePropertyValue $p.FixedTargetRoot -Force
        $sc | Add-Member -NotePropertyName TaskName        -NotePropertyValue $p.TaskName -Force

        Set-PairStatePath -Pair $p
        Write-Log ("===== [{0}] {1} → {2} =====" -f $p.TaskName, $p.Source, $p.DestLabel) -Level INFO

        try {
            $r = Invoke-SyncTask -Config $sc -Auto:$Auto -NoWindow:$NoWindow -Force:$Force
        } catch {
            $r = [pscustomobject]@{ Ok = $false; Code = 'EXCEPTION'; Message = $_.Exception.Message }
        }

        $agg.Results += [pscustomobject]@{
            PairId = $p.PairId; TaskName = $p.TaskName; DestLabel = $p.DestLabel
            Ok = [bool]$r.Ok; Code = [string]$r.Code; Message = [string]$r.Message
            Copied = $(if ($r.PSObject.Properties['Copied']) { [int]$r.Copied } else { 0 })
        }
        if ($r.Code -eq 'ALREADYBUSY') { $msgs.Add(('[{0}] 已有同步在跑，跳过' -f $p.TaskName)) | Out-Null; continue }

        if ($r.Ok -or $r.Code -eq 'PARTIAL') {
            $agg.Ran++
            $agg.Copied  += $(if ($r.PSObject.Properties['Copied'])  { [int]$r.Copied }  else { 0 })
            $agg.Deleted += $(if ($r.PSObject.Properties['Deleted']) { [int]$r.Deleted } else { 0 })
            $msgs.Add(('[{0} → {1}] {2}' -f $p.TaskName, $p.DestLabel, $r.Message)) | Out-Null
            if ($r.Code -eq 'PARTIAL') { $agg.Failed++ }
        } else {
            $agg.Failed++
            $msgs.Add(('[{0} → {1}] 失败：{2}' -f $p.TaskName, $p.DestLabel, $r.Message)) | Out-Null
        }
    }

    $script:StatePath = $defaultStatePath

    if ($agg.Ran -eq 0 -and $agg.Failed -eq 0 -and $agg.Skipped -gt 0) {
        $agg.Code = 'NOTHINGTODO'
        $agg.Message = '目的地都不在线，没有可执行的配对'
    } elseif ($agg.Failed -gt 0) {
        $agg.Code = 'PARTIAL'
        $agg.Ok = $false
        $agg.Message = ($msgs -join '；')
    } elseif ($agg.Ran -gt 0) {
        $agg.Code = 'SUCCESS'
        $agg.Message = ('完成 {0} 个配对：复制 {1} 个文件' -f $agg.Ran, $agg.Copied) + $(if ($msgs.Count) { '；' + ($msgs -join '；') })
    } else {
        $agg.Code = 'UPTODATE'
        $agg.Message = '两端已一致，无需复制'
    }
    return $agg
}
