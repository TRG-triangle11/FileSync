#Requires -Version 5.1
<#
    SyncUI.ps1  -  FileSync 控制台（WPF）

    两种形态共用同一个窗口：
      · 控制台  448 宽，从上到下：状态头 → 主状态 → 四格信息 → 问题清单 → 操作按钮 → 状态栏
      · 迷你条  372x58，一行状态 + 一条底部进度线，贴屏幕右下角

    设计取舍（都是踩过的坑）：
      1. 不用 WinForms。上一版的模糊来自 Form.Opacity=0.98 —— 半透明会强制走分层窗口，
         系统必须关掉 ClearType 才能做逐像素混合，文字退化成灰度抗锯齿；再叠加 GDI+
         画 8.5pt 小字，就糊了。现在窗口不透明、文字走 WPF 排版栈。
      2. 圆角靠自绘（Border.CornerRadius），不依赖 DWM。DWM 圆角只有固定的 8px，
         且无边框窗口拿不到规格外的半径。
      3. 所有位置都取整（UseLayoutRounding + 整数 DIP），避免半像素造成的糊边。
      4. 信息只出现一次：原因在清单里，个数在标题里，建议只有一句，不做层层复述。

    对外接口与旧版保持一致，SyncCore / Watch 不用改调用；另外新增
    Set-UIStatus / Set-UISyncing / Get-UIAction / Test-UICancelRequested。

    无交互桌面 / 建窗失败时自动降级为控制台输出。
#>

# ═══════════════════════════════════════════════════════════════
# 模块状态
# ═══════════════════════════════════════════════════════════════
$script:UI          = $null
$script:UIBuilt     = $false
$script:UIReady     = $false
$script:UIMode      = 'Console'          # Console | Mini
$script:Notifications = New-Object System.Collections.ArrayList
$script:NoticeKeys  = @{}
$script:UIActions   = New-Object System.Collections.Queue
$script:CancelRequested = $false
$script:UIClosing   = $false
$script:UIDead      = $false
$script:LastConsolePct  = -1
$script:OnExpand    = $null              # 展开时的回调（让调用方补数据）

# 迷你条的存在感：auto = 有事才出现（默认），always = 常驻，never = 只在托盘
$script:MiniBarMode   = 'auto'
$script:UIDismissed   = $false           # 用户点了叉：本轮不再自动冒出来
$script:HideAt        = $null            # 完成后再停几秒就收起来
$script:PersistentUI  = $false           # 监听模式：窗口常驻，关闭只隐藏不销毁
$script:Themed        = $false
$script:LastThemeCheck = $null

$script:UIState = @{
    Mode       = 'Idle'      # Idle | Work | Done | Warn | Error
    Percent    = 0
    Title      = '待命中'
    Detail     = ''
    Meta       = ''
    HintLine   = ''
    Connected  = $null       # $null 未检测 / $true / $false
    DiskLetter = ''
    DiskName   = ''
    Files      = '—'
    Size       = '—'
    LastSync   = '—'
    Pending    = '—'
    Footer     = ''
    Advice     = ''
    Syncing    = $false
}

# ── 状态落盘（供本地 Web 控制台读取）──────────────────────────────
$script:IPCDir        = Join-Path $PSScriptRoot '_ipc'
$script:StatusFile    = Join-Path $script:IPCDir 'status.json'
$script:CmdDir        = Join-Path $script:IPCDir 'cmd'
$script:LastStatusSig = ''
$script:UIRuntime     = @{
    Bound      = $false
    BindName   = ''
    BindSize   = ''
    Interval   = 5
    WatchPid   = $PID
    StartedAt  = (Get-Date).ToString('s')
    LastSyncAt = ''
    Paused     = $false
    Activity   = @()          # 最近若干条日志行，给网页「活动」区
}

# ═══════════════════════════════════════════════════════════════
# 配色：明暗两套，跟随系统设置
# ═══════════════════════════════════════════════════════════════
# 系统主题存在 HKCU，读一次几微秒，取 2 秒节流轮询就够 ——
# 用户切深色模式，窗口在两秒内自己跟着变，不用重启。
$script:Palette = @{
    Light = @{
        BgRoot    = '#FBFBFD'
        Card      = '#F4F5F8'
        Soft      = '#F0F2F6'
        Line      = '#E3E6EC'
        LineSoft  = '#EAEDF3'
        Txt1      = '#14171C'
        Txt2      = '#5A616D'
        Txt3      = '#9198A4'
        Accent    = '#2C64E3'
        AccentH   = '#1F4FBF'
        AccentP   = '#1A42A0'
        AccentFg  = '#FFFFFF'
        Ok        = '#0F9152'
        OkBg      = '#E7F6ED'
        Warn      = '#B4700A'
        WarnBg    = '#FDF5E7'
        WarnLine  = '#F3E3C4'
        WarnTxt   = '#8A7A5E'
        Err       = '#C93A38'
        ErrBg     = '#FDECEC'
        ErrLine   = '#F3D2D1'
        ErrTxt    = '#9A6A69'
        Idle      = '#9AA1AD'
        Hover     = '#EDEFF3'
        Press     = '#E2E5EB'
        TrackBg   = '#EAEDF3'
        RingTrack = '#DDE1E9'
        IconSt    = '#5A616D'
        MenuHover = '#E4EDFC'
        Danger    = '#D8443F'
        DangerH   = '#BE3531'
        DangerP   = '#A32C29'
    }
    Dark = @{
        BgRoot    = '#202124'
        Card      = '#2A2B2F'
        Soft      = '#26272B'
        Line      = '#3A3C42'
        LineSoft  = '#33353A'
        Txt1      = '#F2F3F5'
        Txt2      = '#B3B7BE'
        Txt3      = '#878C95'
        Accent    = '#5B95FF'
        AccentH   = '#7AAAFF'
        AccentP   = '#4A82E8'
        AccentFg  = '#FFFFFF'
        Ok        = '#43C98A'
        OkBg      = '#1B3327'
        Warn      = '#E2A73C'
        WarnBg    = '#332A17'
        WarnLine  = '#4A3C1E'
        WarnTxt   = '#B79A6A'
        Err       = '#FF7A75'
        ErrBg     = '#3A211F'
        ErrLine   = '#54302D'
        ErrTxt    = '#C39693'
        Idle      = '#71767F'
        Hover     = '#313337'
        Press     = '#3B3D42'
        TrackBg   = '#3A3C42'
        RingTrack = '#3F4147'
        IconSt    = '#B3B7BE'
        MenuHover = '#313D55'
        Danger    = '#E05A55'
        DangerH   = '#F0716C'
        DangerP   = '#C84B46'
    }
}

$script:ThemeName = 'Light'
$script:C = $script:Palette.Light

<#
    Get-SystemTheme
    AppsUseLightTheme = 0 表示应用用深色。读不到就按浅色走。
#>
function Get-SystemTheme {
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
                -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        if ([int]$v -eq 0) { return 'Dark' }
        return 'Light'
    } catch { return 'Light' }
}

# ═══════════════════════════════════════════════════════════════
# 初始化：加载程序集 / 声明 DPI
# ═══════════════════════════════════════════════════════════════
function Initialize-SyncUI {
    if ($script:UIReady) { return $true }

    # DPI 声明必须早于任何窗口创建。失败说明宿主已声明过，属正常。
    try {
        Add-Type -Namespace DiskSyncNative -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
'@ -ErrorAction Stop
    } catch { }
    if ([DiskSyncNative.Native]) {
        # -4 = PER_MONITOR_AWARE_V2，不行退 -2 = SYSTEM_AWARE
        $ok = $false
        try { $ok = [DiskSyncNative.Native]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
        if (-not $ok) {
            try { [void][DiskSyncNative.Native]::SetProcessDpiAwarenessContext([IntPtr](-2)) } catch { }
        }
    }

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore    -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase         -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing      -ErrorAction Stop
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        if (-not ([System.Windows.Window])) { return $false }
    } catch {
        return $false
    }
    $script:UIReady = $true
    return $true
}

# ═══════════════════════════════════════════════════════════════
# 布局（XAML）
# ═══════════════════════════════════════════════════════════════
$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FileSync" WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="False" Background="{DynamicResource BgRoot}"
        ShowInTaskbar="False" Topmost="True" WindowStartupLocation="Manual"
        ShowActivated="False" SizeToContent="Height"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType"
        FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="12">

  <Window.Resources>
    <!-- 全部走 DynamicResource：切主题时换掉字典里的值，界面自动跟着变 -->
    <SolidColorBrush x:Key="BgRoot"    Color="#FBFBFD"/>
    <SolidColorBrush x:Key="Card"      Color="#F4F5F8"/>
    <SolidColorBrush x:Key="Soft"      Color="#F0F2F6"/>
    <SolidColorBrush x:Key="Line"      Color="#E3E6EC"/>
    <SolidColorBrush x:Key="LineSoft"  Color="#EAEDF3"/>
    <SolidColorBrush x:Key="Txt1"      Color="#14171C"/>
    <SolidColorBrush x:Key="Txt2"      Color="#5A616D"/>
    <SolidColorBrush x:Key="Txt3"      Color="#9198A4"/>
    <SolidColorBrush x:Key="Accent"    Color="#2C64E3"/>
    <SolidColorBrush x:Key="AccentH"   Color="#1F4FBF"/>
    <SolidColorBrush x:Key="AccentP"   Color="#1A42A0"/>
    <SolidColorBrush x:Key="AccentFg"  Color="#FFFFFF"/>
    <SolidColorBrush x:Key="Ok"        Color="#0F9152"/>
    <SolidColorBrush x:Key="OkBg"      Color="#E7F6ED"/>
    <SolidColorBrush x:Key="Warn"      Color="#B4700A"/>
    <SolidColorBrush x:Key="WarnBg"    Color="#FDF5E7"/>
    <SolidColorBrush x:Key="WarnLine"  Color="#F3E3C4"/>
    <SolidColorBrush x:Key="WarnTxt"   Color="#8A7A5E"/>
    <SolidColorBrush x:Key="Err"       Color="#C93A38"/>
    <SolidColorBrush x:Key="ErrBg"     Color="#FDECEC"/>
    <SolidColorBrush x:Key="ErrLine"   Color="#F3D2D1"/>
    <SolidColorBrush x:Key="ErrTxt"    Color="#9A6A69"/>
    <SolidColorBrush x:Key="Idle"      Color="#9AA1AD"/>
    <SolidColorBrush x:Key="Hover"     Color="#EDEFF3"/>
    <SolidColorBrush x:Key="Press"     Color="#E2E5EB"/>
    <SolidColorBrush x:Key="TrackBg"   Color="#EAEDF3"/>
    <SolidColorBrush x:Key="RingTrack" Color="#DDE1E9"/>
    <SolidColorBrush x:Key="IconSt"    Color="#5A616D"/>
    <SolidColorBrush x:Key="Danger"    Color="#D8443F"/>
    <SolidColorBrush x:Key="DangerH"   Color="#BE3531"/>
    <SolidColorBrush x:Key="DangerP"   Color="#A32C29"/>

    <!-- 图标按钮 -->
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Width" Value="28"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource Press}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 主按钮 -->
    <Style x:Key="BtnPrimary" TargetType="Button">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentFg}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{DynamicResource Accent}" CornerRadius="7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource AccentH}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource AccentP}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 危险按钮（同步中变成"停止"） -->
    <Style x:Key="BtnDanger" TargetType="Button">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{DynamicResource Danger}" CornerRadius="7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource DangerH}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource DangerP}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 次按钮 -->
    <Style x:Key="BtnSoft" TargetType="Button">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Foreground" Value="{DynamicResource Txt2}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{DynamicResource Soft}" CornerRadius="7"
                    BorderBrush="{DynamicResource Line}" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource Press}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Shell" Background="{DynamicResource BgRoot}" CornerRadius="8"
          BorderBrush="{DynamicResource Line}" BorderThickness="1" Width="448">
    <Grid>
      <!-- ═══════════ 控制台 ═══════════ -->
      <Grid x:Name="ConsoleView">
        <Grid.RowDefinitions>
          <RowDefinition Height="50"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="30"/>
        </Grid.RowDefinitions>

        <!-- 状态头 -->
        <Grid Grid.Row="0" Margin="18,0,12,0">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Border x:Name="Dot" Width="8" Height="8" CornerRadius="4" Background="{DynamicResource Idle}"/>
            <TextBlock Text="FileSync" FontSize="13" FontWeight="SemiBold"
                       Foreground="{DynamicResource Txt1}" Margin="9,0,0,0" VerticalAlignment="Center"/>
            <Border x:Name="Pill" CornerRadius="9" Background="{DynamicResource Soft}" Padding="7,2,7,3" Margin="9,0,0,0"
                    VerticalAlignment="Center">
              <TextBlock x:Name="PillText" Text="检测中" FontSize="10.5" Foreground="{DynamicResource Txt3}"/>
            </Border>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <Button x:Name="BtnCollapse" Style="{StaticResource IconBtn}" ToolTip="隐藏到托盘">
              <Path Data="M3,7 L8,12 L13,7" Stroke="{DynamicResource IconSt}" StrokeThickness="1.5"
                    StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
            </Button>
            <Button x:Name="BtnClose" Style="{StaticResource IconBtn}" Margin="2,0,0,0" ToolTip="隐藏到托盘">
              <Path Data="M4,4 L12,12 M12,4 L4,12" Stroke="{DynamicResource IconSt}" StrokeThickness="1.4"
                    StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
            </Button>
          </StackPanel>
        </Grid>

        <!-- 主状态 -->
        <StackPanel Grid.Row="1" Margin="18,4,18,0">
          <Grid>
            <TextBlock x:Name="HeroTitle" Text="待命中" FontSize="19" FontWeight="SemiBold"
                       Foreground="{DynamicResource Txt1}" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="HeroPct" Text="" FontSize="19" FontWeight="SemiBold"
                       Foreground="{DynamicResource Accent}" HorizontalAlignment="Right" Margin="8,0,0,0"/>
          </Grid>
          <TextBlock x:Name="HeroDetail" Text="" FontSize="12.5" Foreground="{DynamicResource Txt2}"
                     Margin="0,5,0,0" TextTrimming="CharacterEllipsis"/>
          <Border x:Name="Track" Height="6" CornerRadius="3" Background="{DynamicResource TrackBg}" Margin="0,11,0,0">
            <Border x:Name="Fill" Height="6" CornerRadius="3" Background="{DynamicResource Accent}"
                    HorizontalAlignment="Left" Width="0"/>
          </Border>
          <TextBlock x:Name="HeroMeta" Text="" FontSize="11" Foreground="{DynamicResource Txt3}"
                     Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>

        <!-- 四格信息 -->
        <Border Grid.Row="2" Margin="18,14,18,0" CornerRadius="8" Background="{DynamicResource Card}"
                Padding="14,11,14,11">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,10,0">
              <TextBlock Text="硬盘" FontSize="10.5" Foreground="{DynamicResource Txt3}"/>
              <TextBlock x:Name="V_Disk" Text="—" FontSize="12.5" Foreground="{DynamicResource Txt1}"
                         Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,0,0,0">
              <TextBlock Text="文件" FontSize="10.5" Foreground="{DynamicResource Txt3}"/>
              <TextBlock x:Name="V_Files" Text="—" FontSize="12.5" Foreground="{DynamicResource Txt1}"
                         Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,9,10,0">
              <TextBlock Text="上次同步" FontSize="10.5" Foreground="{DynamicResource Txt3}"/>
              <TextBlock x:Name="V_Last" Text="—" FontSize="12.5" Foreground="{DynamicResource Txt1}"
                         Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <StackPanel Grid.Row="1" Grid.Column="1" Margin="0,9,0,0">
              <TextBlock Text="待处理" FontSize="10.5" Foreground="{DynamicResource Txt3}"/>
              <TextBlock x:Name="V_Pending" Text="无" FontSize="12.5" Foreground="{DynamicResource Txt1}"
                         Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Grid>
        </Border>

        <!-- 问题清单（有才显示） -->
        <Border x:Name="IssueCard" Grid.Row="3" Margin="18,12,18,0" CornerRadius="8"
                Background="{DynamicResource WarnBg}" BorderBrush="{DynamicResource WarnLine}" BorderThickness="1"
                Padding="13,11,13,12" Visibility="Collapsed">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Path x:Name="IssueIcon" Data="M8,2.2 L14.6,13.4 L1.4,13.4 Z" Stroke="{DynamicResource Warn}"
                    StrokeThickness="1.4" StrokeLineJoin="Round" VerticalAlignment="Center"/>
              <TextBlock x:Name="IssueHead" Text="" FontSize="12.5" FontWeight="SemiBold"
                         Foreground="{DynamicResource Warn}" Margin="7,0,0,0" VerticalAlignment="Center"
                         TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <ScrollViewer x:Name="IssueScroll" MaxHeight="108" VerticalScrollBarVisibility="Auto"
                          Margin="0,7,0,0" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="IssueItems"/>
            </ScrollViewer>
            <TextBlock x:Name="IssueAdvice" Text="" FontSize="11" Foreground="{DynamicResource WarnTxt}"
                       Margin="0,7,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
          </StackPanel>
        </Border>

        <!-- 操作 -->
        <Grid Grid.Row="4" Margin="18,14,18,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="BtnSync" Grid.Column="0" Style="{StaticResource BtnPrimary}"
                  Content="立即同步" Width="96"/>
          <Button x:Name="BtnLogs" Grid.Column="2" Style="{StaticResource BtnSoft}"
                  Content="日志" Width="64" Margin="8,0,0,0"/>
          <Button x:Name="BtnBind" Grid.Column="3" Style="{StaticResource BtnSoft}"
                  Content="网页" Width="64" Margin="8,0,0,0" ToolTip="打开本地网页控制台"/>
        </Grid>

        <!-- 状态栏 -->
        <Border x:Name="FootBar" Grid.Row="5" Background="{DynamicResource Soft}" CornerRadius="0,0,7,7" Margin="0,14,0,0"
                Padding="18,0,16,0">
          <Grid>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <Border x:Name="FootDot" Width="6" Height="6" CornerRadius="3" Background="{DynamicResource Idle}"/>
              <TextBlock x:Name="FootText" Text="未在监听" FontSize="10.5"
                         Foreground="{DynamicResource Txt3}" Margin="7,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <TextBlock x:Name="FootTime" Text="" FontSize="10.5" Foreground="{DynamicResource Txt3}"
                       HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
        </Border>
      </Grid>

      <!-- ═══════════ 迷你条 252x44 ═══════════ -->
      <Grid x:Name="MiniView" Visibility="Collapsed" Height="44" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <!-- 环形进度：26 的框放 23.5 的圈，留出线宽，不被裁掉 -->
        <Grid Grid.Column="0" Width="26" Height="26" Margin="13,0,0,0" VerticalAlignment="Center">
          <Ellipse x:Name="RingTrack" Width="23.5" Height="23.5"
                   Stroke="{DynamicResource RingTrack}" StrokeThickness="2.5"/>
          <Ellipse x:Name="RingValue" Width="23.5" Height="23.5"
                   Stroke="{DynamicResource Accent}" StrokeThickness="2.5"
                   StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                   RenderTransformOrigin="0.5,0.5">
            <Ellipse.RenderTransform>
              <RotateTransform Angle="-90"/>
            </Ellipse.RenderTransform>
          </Ellipse>
        </Grid>

        <Grid x:Name="MiniText" Grid.Column="1" Margin="9,0,6,0" VerticalAlignment="Center">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="MiniTitle" Grid.Column="0" Text="待命中" FontSize="12.5" FontWeight="SemiBold"
                     Foreground="{DynamicResource Txt1}" VerticalAlignment="Center"/>
          <TextBlock x:Name="MiniPct" Grid.Column="1" Text="" FontSize="12.5" FontWeight="SemiBold"
                     Foreground="{DynamicResource Accent}" Margin="5,0,0,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="MiniMeta" Grid.Column="2" Text="" FontSize="10.5"
                     Foreground="{DynamicResource Txt3}" Margin="7,0,0,0" VerticalAlignment="Center"
                     TextTrimming="CharacterEllipsis"/>
          <Border x:Name="MiniBadge" Grid.Column="3" CornerRadius="6" Background="{DynamicResource WarnBg}"
                  Padding="5,1,5,2" Margin="6,0,0,0" Visibility="Collapsed" VerticalAlignment="Center">
            <TextBlock x:Name="MiniBadgeText" Text="" FontSize="9.5" FontWeight="SemiBold"
                       Foreground="{DynamicResource Warn}"/>
          </Border>
        </Grid>

        <Button x:Name="BtnMiniClose" Grid.Column="2" Style="{StaticResource IconBtn}" Width="24" Height="24"
                Margin="0,0,7,0" Opacity="0.4" VerticalAlignment="Center" ToolTip="隐藏（同步照常进行）">
          <Path Data="M4,4 L12,12 M12,4 L4,12" Stroke="{DynamicResource IconSt}" StrokeThickness="1.4"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        </Button>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

# ═══════════════════════════════════════════════════════════════
# 工具
# ═══════════════════════════════════════════════════════════════
$script:BrushCache = @{}

function ConvertTo-Brush {
    param([string]$Hex)
    if (-not $Hex) { return $null }
    if ($script:BrushCache.ContainsKey($Hex)) { return $script:BrushCache[$Hex] }
    try {
        $c = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
        $b = New-Object System.Windows.Media.SolidColorBrush -ArgumentList ([System.Windows.Media.Color]$c)
        $b.Freeze()
        $script:BrushCache[$Hex] = $b
        return $b
    } catch { return $null }
}

<#
    Apply-Theme
    把字典里的画刷整体换掉。XAML 里全部用 DynamicResource 引用这些键，
    换值即换肤，不用重建窗口，也不会闪。
#>
function Apply-Theme {
    param([switch]$Force, [string]$Name)
    if (-not $script:UI) { return }
    $name = if ($Name) { $Name } else { Get-SystemTheme }
    if (-not $Force -and $script:Themed -and $name -eq $script:ThemeName) { return }

    $script:ThemeName = $name
    $script:C = if ($name -eq 'Dark') { $script:Palette.Dark } else { $script:Palette.Light }

    try {
        $res = $script:UI.Window.Resources
        foreach ($k in $script:C.Keys) {
            try {
                if (-not $res.Contains($k)) { continue }
                $col = [System.Windows.Media.ColorConverter]::ConvertFromString($script:C[$k])
                $old = $res[$k]

                # 被 ControlTemplate 引用过的画刷会被 WPF 冻结（模板之间共享），
                # 冻结的改不了颜色，只能整个换掉。ActiveX 那套 DynamicResource
                # 会在字典变化后自己重新取值，所以换掉即生效。
                if ($old -and -not $old.IsFrozen) {
                    $old.Color = $col
                } else {
                    $nb = New-Object System.Windows.Media.SolidColorBrush -ArgumentList ([System.Windows.Media.Color]$col)
                    # 一定要取 BaseObject：直接塞 PowerShell 包过的对象，
                    # WPF 那边会报"无法转换为 Brush"
                    $res.Remove($k)
                    $res.Add($k, $nb.PSObject.BaseObject)
                }
            } catch { }
        }
        $script:Themed = $true
        # 问题清单的行是代码建的 TextBlock，画刷写死在实例上，换肤不会自己更新
        $script:LastNoticeSig = ''
        Update-UISurface
        Update-TrayMenuTheme          # 托盘菜单也跟着换肤
    } catch {
        $script:ThemeError = $_.Exception.Message
    }
}

<#
    Set-WindowRounded
    Win11 让 DWM 自己把窗口切成圆角。透明窗口也能画圆角，但透明窗口
    必然丢掉 ClearType（这正是之前字发虚的原因），所以这里选不透明 + 系统圆角。
    Win10 会返回参数错误，忽略即可。
#>
function Set-WindowRounded {
    if (-not $script:UI) { return }
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:UI.Window).Handle
        if ($h -eq [IntPtr]::Zero) { return }
        $v = 2   # DWMWCP_ROUND
        [void][DiskSyncNative.Native]::DwmSetWindowAttribute($h, 33, [ref]$v, 4)
    } catch { }
}

<#
    Set-RingValue
    用虚线画弧：把周长折算成"线宽的倍数"，一段实线一段空白，
    圆环就只露出该有的那一截。比算 ArcSegment 便宜，也不会有接缝。
#>
function Set-RingValue {
    param($El, [double]$Percent)
    if (-not $El) { return }
    $p = [Math]::Max(0.0, [Math]::Min(1.0, $Percent / 100.0))
    $dc = New-Object System.Windows.Media.DoubleCollection
    if ($p -le 0.001) {
        $El.Visibility = 'Collapsed'
    } else {
        $El.Visibility = 'Visible'
        $units = [Math]::PI * $El.Width / $El.StrokeThickness
        [void]$dc.Add([Math]::Max(0.0001, $units * $p))
        [void]$dc.Add([Math]::Max(0.0001, $units * (1.0 - $p)))
    }
    $El.StrokeDashArray = $dc
}

<#
    显示 / 隐藏
    用户点叉就真的收起来，别过 5 秒又自己冒出来 ——
    之前监听循环里无条件重建窗口，就是这个毛病。
#>
function Set-BarVisible {
    param([bool]$Show, [switch]$Force)
    if (-not $script:UI) { return }
    if (-not $Show -and $script:UIDismissed -and -not $Force) { return }
    try {
        $w = $script:UI.Window
        if ($Show) {
            if (-not $w.IsVisible) {
                $w.Show()
                Set-WindowRounded
                Set-WindowCornerBottom
            }
        } else {
            if ($w.IsVisible) { $w.Hide() }
        }
    } catch { }
}

function Set-MiniBarMode {
    param([string]$Mode)
    if (@('auto', 'always', 'never') -contains $Mode) { $script:MiniBarMode = $Mode }
}

# 叉号 / 收起：本轮不再自动冒出来。同步照常，托盘图标和网页随时能看
function Hide-Bar {
    $script:UIDismissed = $true
    $script:HideAt = $null
    if ($script:UIMode -ne 'Mini') { Set-UIMode -Mode 'Mini' -Quiet }
    Set-BarVisible $false -Force
}

# 用户主动叫回来（托盘菜单 / 网页按钮），把"别再出现"解掉
function Show-Bar {
    param([switch]$Console)
    $script:UIDismissed = $false
    if (-not (Test-UIAlive)) { [void](New-ProgressWindow -Title '监听中' -Compact); return }
    Set-UIMode -Mode $(if ($Console) { 'Console' } else { 'Mini' }) -Quiet
    Set-BarVisible $true -Force
}

# 迷你条该不该在屏幕上：dismissed 优先，其次是配置的三种模式
function Update-BarVisibility {
    if (-not $script:UI) { return }
    if ($script:UIMode -ne 'Mini') { Set-BarVisible $true; return }   # 控制台是用户自己点开的，不自动收
    if ($script:UIDismissed) { Set-BarVisible $false; return }
    switch ($script:MiniBarMode) {
        'never'  { Set-BarVisible $false; return }
        'always' { Set-BarVisible $true;  return }
        default {
            $want = $script:UIState.Syncing -or
                    $script:UIState.Mode -eq 'Warn' -or
                    $script:UIState.Mode -eq 'Error' -or
                    $script:Notifications.Count -gt 0 -or
                    ($null -ne $script:HideAt)
            Set-BarVisible $want
        }
    }
}

<#
    Invoke-UIPump
    WPF 版的 DoEvents。同步跑在主线程上，只有主动把 Dispatcher 队列跑空，
    窗口才会重绘、按钮才会响应。代价是同步循环里必须周期性调用 —— 现有代码
    在 robocopy 等待循环里每 500ms 调一次 Update-ProgressUI，够了。
    顺带在这里做两件小事：主题轮询（2 秒）与自动收起（定时）。
#>
function Invoke-UIPump {
    if (-not $script:UI) { return }
    try {
        $d = $script:UI.Window.Dispatcher
        if ($d -and -not $d.HasShutdownStarted) {
            $d.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [System.Action]{}) | Out-Null
        }

        $now = Get-Date
        if (-not $script:LastThemeCheck -or ($now - $script:LastThemeCheck).TotalMilliseconds -ge 2000) {
            $script:LastThemeCheck = $now
            Apply-Theme
        }
        if ($script:HideAt -and $now -ge $script:HideAt) {
            $script:HideAt = $null
            Update-BarVisibility
        }
    } catch { }
}

# ═══════════════════════════════════════════════════════════════
# 建窗
# ═══════════════════════════════════════════════════════════════
function Test-UIAlive {
    if (-not $script:UI) { return $false }
    if ($script:UIDead) { $script:UI = $null; return $false }
    return $true
}

function New-ProgressWindow {
    param(
        [string]$Title = 'FileSync',
        [switch]$Compact,
        [switch]$NoTray
    )

    if (-not (Initialize-SyncUI)) { return $false }

    if ($script:UI) {
        # 已经开着就复用，不改用户当前选的形态（用户刚展开控制台，插盘不该把它收回迷你条）
        return $true
    }

    try {
        $script:UIDead    = $false
        $script:UIClosing = $false
        $w = [System.Windows.Markup.XamlReader]::Parse($script:Xaml)
        $n = @{}
        foreach ($name in @(
            'RootHost','Shell','ConsoleView','MiniView',
            'Dot','Pill','PillText','BtnCollapse','BtnClose',
            'HeroTitle','HeroPct','HeroDetail','Track','Fill','HeroMeta',
            'V_Disk','V_Files','V_Last','V_Pending',
            'IssueCard','IssueHead','IssueIcon','IssueScroll','IssueItems','IssueAdvice',
            'BtnSync','BtnLogs','BtnBind',
            'FootDot','FootText','FootTime','FootBar',
            'RingTrack','RingValue','MiniTitle','MiniPct','MiniMeta','MiniText',
            'MiniBadge','MiniBadgeText','BtnMiniClose')) {
            $n[$name] = $w.FindName($name)
        }

        $script:UI = [pscustomobject]@{
            Window   = $w
            Ctl      = $n
            Res      = @{
                Primary = $w.Resources['BtnPrimary']
                Danger  = $w.Resources['BtnDanger']
                Soft    = $w.Resources['BtnSoft']
                Icon    = $w.Resources['IconBtn']
            }
            Tray     = $null
            TrayIcon = $null
            LastH    = 0
        }

        # ---- 事件 ----
        # 每个回调都套 try/catch：PowerShell 的事件脚本块一旦抛错，
        # 错误处理本身会再触发一次错误处理，直接 StackOverflow 把进程带走
        # （实测：Close() 时崩溃，事件日志里签名停在 CheckActionPreference）。
        $n.BtnCollapse.Add_Click({ try { Hide-Bar } catch { } })
        $n.BtnClose.Add_Click({    try { Hide-Bar } catch { } })
        $n.BtnMiniClose.Add_Click({ try { Hide-Bar } catch { } })
        $n.BtnSync.Add_Click({
            try {
                if ($script:UIState.Syncing) { $script:CancelRequested = $true; [void]$script:UIActions.Enqueue('stop') }
                else { [void]$script:UIActions.Enqueue('sync') }
            } catch { }
        })
        $n.BtnLogs.Add_Click({ try { [void]$script:UIActions.Enqueue('logs') } catch { } })
        $n.BtnBind.Add_Click({ try { [void]$script:UIActions.Enqueue('web') } catch { } })

        # 迷你条整条可点：点一下展开成控制台。叉号是独立的按钮，不会误触。
        foreach ($el in @($n.MiniText, $n.RingTrack, $n.RingValue, $n.MiniTitle)) {
            if ($el) { $el.Add_MouseLeftButtonUp({ try { Set-UIMode -Mode 'Console' } catch { } }) }
        }

        # 悬停才让叉号变清楚，平时淡着不抢眼
        $n.MiniView.Add_MouseEnter({ try { $script:UI.Ctl.BtnMiniClose.Opacity = 1 } catch { } })
        $n.MiniView.Add_MouseLeave({ try { $script:UI.Ctl.BtnMiniClose.Opacity = 0.4 } catch { } })

        $w.Add_Closing({
            try {
                if ($script:UI -and $script:UI.Tray) {
                    $script:UI.Tray.Visible = $false
                    $script:UI.Tray.Dispose()
                    $script:UI.Tray = $null
                }
                $script:TrayMenu = $null
            } catch { }
        })
        $w.Add_Closed({ try { $script:UIDead = $true } catch { } })

        if (-not $NoTray) { Initialize-UITray }

        # 内容长高/变矮时窗口跟着变，底边必须钉住 —— 否则会往上飘或往下掉
        $w.Add_SizeChanged({ try { Set-WindowCornerBottom } catch { } })

        $script:UIBuilt = $true
        Set-UIMode -Mode $(if ($Compact) { 'Mini' } else { 'Console' }) -Quiet
        Apply-Theme -Force              # 先上色再显示，深色模式下不会闪一下白底
        Update-UISurface

        if ($Compact) {
            # 待命时干脆不出现，只在同步中 / 有异常 / 完成后几秒内露头
            Update-BarVisibility
        } else {
            $w.Show()
            Set-WindowRounded
            Set-WindowCornerBottom
        }
        Invoke-UIPump
        return $true
    }
    catch {
        $script:UI = $null
        Write-Host ('[提示] 无法创建界面，改用控制台输出：' + $_.Exception.Message) -ForegroundColor DarkYellow
        return $false
    }
}

function Get-SmallIconPx {
    <#
        托盘图标要用多少像素：150% 缩放是 24，200% 是 32。
        优先问系统（进程已声明 per-monitor aware 时它给的是真实值），
        拿不到就按注册表里的系统 DPI 折算 —— 不能用 16 硬扛，
        否则系统会把 16px 拉伸到 24px，糊得没法看。
    #>
    $px = 16
    try {
        $dpi = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction SilentlyContinue).AppliedDPI
        if ($dpi -and [int]$dpi -gt 96) { $px = [int][Math]::Round(16 * [int]$dpi / 96.0) }
    } catch { }
    try {
        $s = [System.Windows.Forms.SystemInformation]::SmallIconSize
        if ($s.Width -gt $px) { $px = [int]$s.Width }
    } catch { }
    if ($px -lt 16) { $px = 16 }
    if ($px -gt 64) { $px = 64 }
    return $px
}

<#
    托盘菜单的自绘渲染器（QQ NT 风格）。
    WinForms 原生菜单是白底灰字直角高亮，和整套界面不搭；这里用 C# 编一段
    ToolStripProfessionalRenderer：白卡大圆角、无图标、纯文字左对齐、
    悬停是内缩的浅灰圆角块、分隔线细淡 —— 文字由渲染器手工垂直居中，
    不走 WinForms 默认的基线排版（那正是图标列时代文字上移的病根）。
#>
$script:TrayMenuSrc = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class DiskSyncMenuColors
{
    public Color Back, Border, Text, Dim, Hover, HoverText, Accent, Err;
    public DiskSyncMenuColors() { }
}

public class DiskSyncMenuRenderer : ToolStripProfessionalRenderer
{
    public DiskSyncMenuColors P;
    int _w, _h;
    const int PadX   = 16;   // 文字距菜单左缘
    const int InsetX = 6;    // 悬停块左右内缩
    const int InsetY = 3;    // 悬停块上下内缩
    const int ItemRad = 6;   // 悬停块圆角
    const int MenuRad = 10;  // 菜单整体圆角

    public DiskSyncMenuRenderer(DiskSyncMenuColors p) { P = p; }

    static GraphicsPath Round(Rectangle r, int rad)
    {
        GraphicsPath gp = new GraphicsPath();
        int d = rad * 2;
        gp.AddArc(r.X, r.Y, d, d, 180, 90);
        gp.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        gp.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        gp.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        gp.CloseFigure();
        return gp;
    }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
    {
        using (SolidBrush b = new SolidBrush(P.Back))
            e.Graphics.FillRectangle(b, e.AffectedBounds);
    }

    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }

    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
    {
        ToolStrip ts = e.ToolStrip;
        if (ts.Width != _w || ts.Height != _h)
        {
            _w = ts.Width; _h = ts.Height;
            using (GraphicsPath gp = Round(new Rectangle(0, 0, ts.Width - 1, ts.Height - 1), MenuRad))
                ts.Region = new Region(gp);     // 整张菜单圆角
        }
        using (GraphicsPath gp = Round(new Rectangle(0, 0, ts.Width - 1, ts.Height - 1), MenuRad))
        using (Pen pen = new Pen(P.Border))
            e.Graphics.DrawPath(pen, gp);
    }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        ToolStripMenuItem mi = e.Item as ToolStripMenuItem;
        if (mi == null || !mi.Enabled || (!mi.Selected && !mi.Pressed)) return;
        Rectangle r = new Rectangle(InsetX, InsetY, e.Item.Width - InsetX * 2, e.Item.Height - InsetY * 2);
        using (GraphicsPath gp = Round(r, ItemRad))
        using (SolidBrush b = new SolidBrush(P.Hover))
            e.Graphics.FillPath(b, gp);
    }

    // 图标：固定 x + 垂直居中，和文字同一套坐标系，保证两者齐平
    protected override void OnRenderItemImage(ToolStripItemImageRenderEventArgs e)
    {
        Image img = e.Image;
        if (img == null) { base.OnRenderItemImage(e); return; }
        ToolStripMenuItem mi = e.Item as ToolStripMenuItem;
        int y = (e.Item.Height - img.Height) / 2;
        if (mi != null && !mi.Enabled)
        {
            // 禁用项图标淡到 35%
            System.Drawing.Imaging.ColorMatrix m = new System.Drawing.Imaging.ColorMatrix();
            m.Matrix33 = 0.35f;
            using (System.Drawing.Imaging.ImageAttributes ia = new System.Drawing.Imaging.ImageAttributes())
            {
                ia.SetColorMatrix(m);
                e.Graphics.DrawImage(img, new Rectangle(PadX, y, img.Width, img.Height),
                    0, 0, img.Width, img.Height, GraphicsUnit.Pixel, ia);
            }
            return;
        }
        e.Graphics.DrawImage(img, PadX, y);
    }

    // 文字自己画：起点让开图标位，按整行高度垂直居中，杜绝上移
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        ToolStripMenuItem mi = e.Item as ToolStripMenuItem;
        if (mi == null) { base.OnRenderItemText(e); return; }
        bool err = (mi.Tag as string) == "err";
        Color col = !mi.Enabled ? P.Dim
                  : (mi.Selected || mi.Pressed) ? (err ? P.Err : P.HoverText)
                  : (err ? P.Err : P.Text);
        int iconW = (mi.Image != null) ? mi.Image.Width + 10 : 0;
        Rectangle r = new Rectangle(PadX + iconW, 0, e.Item.Width - PadX - iconW - PadX, e.Item.Height);
        TextRenderer.DrawText(e.Graphics, e.Text,
            e.TextFont ?? mi.Font, r, col,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter |
            TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    {
        float y = e.Item.Height / 2f;
        using (Pen pen = new Pen(P.Border))
            e.Graphics.DrawLine(pen, PadX * 0.75f, y, e.Item.Width - PadX * 0.75f, y);
    }

    // ── 小图标工厂：24 逻辑坐标 → 任意像素，形状跟网页图标同一套 ──
    public static Bitmap Glyph(string kind, string hex, int px)
    {
        Color c = ColorTranslator.FromHtml(hex);
        Bitmap bmp = new Bitmap(px, px);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float s = px / 24f;
            using (Pen p = new Pen(c, 1.8f))
            using (SolidBrush br = new SolidBrush(c))
            {
                p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                p.LineJoin = LineJoin.Round;
                switch (kind)
                {
                    case "sync":
                        // 仿网页版 i-sync：两段圆弧 + 两个 L 形箭头角（不再是连体箭头）
                        g.DrawArc(p, 4.2f * s, 4.2f * s, 15.6f * s, 15.6f * s, 199f, 115f);
                        g.DrawArc(p, 4.2f * s, 4.2f * s, 15.6f * s, 15.6f * s, 19f, 116f);
                        // 右上箭头角：竖线向下 + 横线向左
                        g.DrawLine(p, 20.6f * s, 10.6f * s, 20.6f * s, 5.4f * s);
                        g.DrawLine(p, 20.6f * s, 5.4f * s, 15.4f * s, 5.4f * s);
                        // 左下箭头角：竖线向上 + 横线向右
                        g.DrawLine(p, 3.4f * s, 13.4f * s, 3.4f * s, 18.6f * s);
                        g.DrawLine(p, 3.4f * s, 18.6f * s, 8.6f * s, 18.6f * s);
                        break;
                    case "pause":
                        g.DrawLine(p, 9.3f * s, 6.8f * s, 9.3f * s, 17.2f * s);
                        g.DrawLine(p, 14.7f * s, 6.8f * s, 14.7f * s, 17.2f * s);
                        break;
                    case "play":
                        using (GraphicsPath gp = new GraphicsPath())
                        {
                            gp.AddPolygon(new PointF[] {
                                new PointF(9.2f * s, 6.3f * s),
                                new PointF(17.6f * s, 12f * s),
                                new PointF(9.2f * s, 17.7f * s) });
                            gp.CloseAllFigures();
                            p.Width = 1.4f;
                            g.FillPath(br, gp);
                            g.DrawPath(p, gp);      // 描一下让尖角圆润
                        }
                        break;
                    case "web":
                        // 地球（浏览器标志）：外圆 + 赤道线 + 竖向经线椭圆
                        g.DrawEllipse(p, 4.4f * s, 4.4f * s, 15.2f * s, 15.2f * s);
                        g.DrawLine(p, 4.4f * s, 12f * s, 19.6f * s, 12f * s);
                        g.DrawEllipse(p, 8.2f * s, 4.4f * s, 7.6f * s, 15.2f * s);
                        break;
                    case "logs":
                        using (GraphicsPath gp = RRect(5.2f * s, 3.6f * s, 13.6f * s, 16.8f * s, 2.2f * s))
                        {
                            g.DrawPath(p, gp);
                            g.DrawLine(p, 8.8f * s, 10.6f * s, 15.2f * s, 10.6f * s);
                            g.DrawLine(p, 8.8f * s, 14f * s, 13.2f * s, 14f * s);
                        }
                        break;
                    case "bar":
                        // 跑道形进度条：外框圆角胶囊，内部 60% 填充
                        using (GraphicsPath gp = RRect(3.5f * s, 8.2f * s, 17f * s, 7.6f * s, 3.8f * s))
                            g.DrawPath(p, gp);
                        using (GraphicsPath gp = RRect(3.5f * s, 8.2f * s, 10.2f * s, 7.6f * s, 3.8f * s))
                            g.FillPath(br, gp);
                        break;
                    case "power":
                        g.DrawArc(p, 5.2f * s, 5.2f * s, 13.6f * s, 13.6f * s, 300f, 300f);
                        g.DrawLine(p, 12f * s, 3.4f * s, 12f * s, 11f * s);
                        break;
                }
            }
        }
        return bmp;
    }

    static GraphicsPath RRect(float x, float y, float w, float h, float rad)
    {
        GraphicsPath gp = new GraphicsPath();
        float d = rad * 2;
        gp.AddArc(x, y, d, d, 180, 90);
        gp.AddArc(x + w - d, y, d, d, 270, 90);
        gp.AddArc(x + w - d, y + h - d, d, d, 0, 90);
        gp.AddArc(x, y + h - d, d, d, 90, 90);
        gp.CloseFigure();
        return gp;
    }
}
'@

<#
    New-TrayMenu
    菜单本体：自绘渲染器 + 图标。Initialize-UITray 调它，测试脚本也能单独调。
#>
function New-TrayMenu {
    if (-not ('DiskSyncMenuRenderer' -as [type])) {
        Add-Type -TypeDefinition $script:TrayMenuSrc `
            -ReferencedAssemblies System.Drawing, System.Windows.Forms
    }

    $px = Get-SmallIconPx
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.ShowCheckMargin = $false
    $menu.ImageScalingSize = New-Object System.Drawing.Size -ArgumentList $px, $px
    try { $menu.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5) } catch { }

    $script:TrayMenuColors = New-Object DiskSyncMenuColors
    Set-TrayMenuColors
    $menu.Renderer = New-Object DiskSyncMenuRenderer -ArgumentList $script:TrayMenuColors

    # QQ NT 排版 + 线性小图标：行高撑到 ~34px，图标与文字都由渲染器垂直居中
    function New-MenuItem {
        param([string]$Name, [string]$Text, [string]$GlyphKind, [string]$ColorKey)
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList $Text
        $mi.Name = $Name
        $mi.ImageScaling = [System.Windows.Forms.ToolStripItemImageScaling]::None
        try { $mi.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 8) } catch { }
        $mi.Image = [DiskSyncMenuRenderer]::Glyph($GlyphKind, $script:C[$ColorKey], $px)
        return $mi
    }

    [void]$menu.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@(
        (New-MenuItem 'Open'  '打开网页控制台' 'web'   'Accent'),
        (New-MenuItem 'Sync'  '立即同步'       'sync'  'Accent'),
        (New-MenuItem 'Pause' '暂停自动同步'   'pause' 'Txt2'),
        (New-Object System.Windows.Forms.ToolStripSeparator),
        (New-MenuItem 'Bar'  '显示进度条' 'bar'   'Txt2'),
        (New-MenuItem 'Logs' '打开日志'   'logs'  'Txt2'),
        (New-Object System.Windows.Forms.ToolStripSeparator),
        (New-MenuItem 'Exit' '退出'       'power' 'Err')
    ))
    $menu.Items['Exit'].Tag = 'err'

    $menu.Items['Open'].Add_Click({  try { [void]$script:UIActions.Enqueue('web') } catch { } })
    $menu.Items['Sync'].Add_Click({  try { [void]$script:UIActions.Enqueue('sync') } catch { } })
    $menu.Items['Pause'].Add_Click({ try { [void]$script:UIActions.Enqueue('togglepause') } catch { } })
    $menu.Items['Bar'].Add_Click({   try { Show-Bar } catch { } })
    $menu.Items['Logs'].Add_Click({  try { [void]$script:UIActions.Enqueue('logs') } catch { } })
    $menu.Items['Exit'].Add_Click({  try { [void]$script:UIActions.Enqueue('quit') } catch { } })

    # 暂停文案按运行时状态摆正
    if ($script:UIRuntime['Paused']) {
        $menu.Items['Pause'].Text = '恢复自动同步'
    }
    return $menu
}

function Initialize-UITray {
    if (-not $script:UI) { return }
    try {
        # 托盘、桌面快捷方式、网页 favicon 共用同一个 FileSync.ico。
        # 按系统小图标的实际像素尺寸取帧（150% 下是 24），交给系统拉伸一定会糊。
        $icoFile = Join-Path $PSScriptRoot 'FileSync.ico'
        if (Test-Path -LiteralPath $icoFile) {
            $px = Get-SmallIconPx
            $size = New-Object System.Drawing.Size -ArgumentList $px, $px
            $script:UI.TrayIcon = New-Object System.Drawing.Icon -ArgumentList $icoFile, $size
        }
        if (-not $script:UI.TrayIcon) {
            # 兜底：图标文件丢了也不能让托盘空着
            $bmp = New-Object System.Drawing.Bitmap 32, 32
            $g   = [System.Drawing.Graphics]::FromImage($bmp)
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.Clear([System.Drawing.Color]::Transparent)
            $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(44, 98, 226))
            $g.FillEllipse($bg, 1, 1, 30, 30)
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 3.2
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
            $g.DrawLine($pen, 9, 16, 14, 21)
            $g.DrawLine($pen, 14, 21, 23, 10)
            $g.Dispose()
            $script:UI.TrayIcon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
            $bmp.Dispose()
        }

        $tray = New-Object System.Windows.Forms.NotifyIcon
        $tray.Icon = $script:UI.TrayIcon
        $tray.Text = 'FileSync'
        $tray.Visible = $true

        # ── 菜单：见 New-TrayMenu（自绘渲染器 + 图标）──
        $menu = New-TrayMenu
        $script:TrayMenu = $menu
        $tray.ContextMenuStrip = $menu

        # 单击托盘 = 打开网页控制台。
        # 注意不能挂 Click：NotifyIcon 的 Click 不区分左右键，右键也会触发，
        # 导致右键菜单还没弹出来浏览器就先开了。改挂 MouseUp 并只认左键。
        # 双击的第二下用 600ms 去抖并入第一次，不会开两个标签页。
        $script:LastTrayClick = [DateTime]::MinValue
        $tray.Add_MouseUp({
            try {
                if ($_.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
                $now = [DateTime]::Now
                if (($now - $script:LastTrayClick).TotalMilliseconds -lt 600) { return }
                $script:LastTrayClick = $now
                [void]$script:UIActions.Enqueue('web')
            } catch { }
        })
        $script:UI.Tray = $tray
    } catch { }
}

<#
    Set-TrayMenuColors / Update-TrayMenuTheme
    菜单配色跟着 $script:C 走。Apply-Theme 换肤时会调 Update-TrayMenuTheme，
    把渲染器颜色和每个菜单项的小图标都按新主题重画。
#>
function Set-TrayMenuColors {
    if (-not $script:TrayMenuColors) { return }
    $c = $script:C
    $P = $script:TrayMenuColors
    $hx = { param($k) [System.Drawing.ColorTranslator]::FromHtml($c[$k]) }
    $P.Back      = & $hx 'Card'
    $P.Border    = & $hx 'Line'
    $P.Text      = & $hx 'Txt1'
    $P.Dim       = & $hx 'Txt3'
    # QQ NT 的悬停是中性浅灰/深灰，不是蓝调，所以用 Hover 而不是 MenuHover
    $P.Hover     = & $hx 'Hover'
    $P.HoverText = & $hx 'Txt1'
    $P.Accent    = & $hx 'Accent'
    $P.Err       = & $hx 'Err'
}

function Update-TrayMenuTheme {
    if (-not $script:TrayMenu) { return }
    try {
        Set-TrayMenuColors
        $px = Get-SmallIconPx
        $c = $script:C
        $g = { param($name, $kind, $key)
            $mi = $script:TrayMenu.Items[$name]
            if ($mi) { $mi.Image = [DiskSyncMenuRenderer]::Glyph($kind, $c[$key], $px) }
        }
        & $g 'Open'  'web'   'Accent'
        & $g 'Sync'  'sync'  'Accent'
        & $g 'Pause' $(if ($script:UIRuntime['Paused']) { 'play' } else { 'pause' }) 'Txt2'
        & $g 'Bar'   'bar'   'Txt2'
        & $g 'Logs'  'logs'  'Txt2'
        & $g 'Exit'  'power' 'Err'
    } catch { }
}

<#
    Update-TrayPauseItem
    暂停状态变化时（Set-UIRuntime 'Paused'）同步菜单文字和图标。
#>
function Update-TrayPauseItem {
    if (-not $script:TrayMenu) { return }
    try {
        $mi = $script:TrayMenu.Items['Pause']
        if (-not $mi) { return }
        $paused = $script:UIRuntime['Paused']
        $mi.Text = if ($paused) { '恢复自动同步' } else { '暂停自动同步' }
        $px = Get-SmallIconPx
        $mi.Image = [DiskSyncMenuRenderer]::Glyph(
            $(if ($paused) { 'play' } else { 'pause' }),
            $script:C['Txt2'], $px)
    } catch { }
}

# ═══════════════════════════════════════════════════════════════
# 形态切换与尺寸
# ═══════════════════════════════════════════════════════════════
function Set-UIMode {
    param(
        [ValidateSet('Console','Mini')][string]$Mode,
        [switch]$Quiet
    )
    if (-not $script:UI) { return }
    $script:UIMode = $Mode
    $c = $script:UI.Ctl
    $w = $script:UI.Window

    if ($Mode -eq 'Mini') {
        $c.ConsoleView.Visibility = 'Collapsed'
        $c.MiniView.Visibility    = 'Visible'
        $c.Shell.Width = 264
        $w.SizeToContent = [System.Windows.SizeToContent]::Manual
        $w.Width  = 264
        $w.Height = 46              # 内容 44 + 上下各 1px 边框
    } else {
        $c.MiniView.Visibility    = 'Collapsed'
        $c.ConsoleView.Visibility = 'Visible'
        $c.Shell.Width = 448
        $w.Width = 448
        # 高度交给 SizeToContent：内容增减时窗口自己伸缩，不用手算，
        # 也就不会出现"问题清单收起来了、窗口还留着一大块空白"。
        $w.SizeToContent = [System.Windows.SizeToContent]::Height
    }

    Set-WindowCornerBottom
    Update-UISurface
    if ($Mode -eq 'Console' -and -not $Quiet -and $script:OnExpand) {
        try { & $script:OnExpand } catch { }
    }
    Invoke-UIPump
}

<#
    Resize-UIShell
    留着这个名字给旧调用用。实际尺寸由 SizeToContent 负责，
    这里只把窗口重新贴回右下角 —— 长高之后底边不能跑掉。
#>
function Resize-UIShell {
    Set-WindowCornerBottom
}

function Set-WindowCornerBottom {
    if (-not $script:UI) { return }
    if ($script:UIClosing) { return }
    try {
        $w  = $script:UI.Window
        $wa = [System.Windows.SystemParameters]::WorkArea
        $cw = if ($w.ActualWidth  -gt 0) { $w.ActualWidth }  else { $w.Width }
        $ch = if ($w.ActualHeight -gt 0) { $w.ActualHeight } else { $w.Height }
        $w.Left = [Math]::Round($wa.Right  - $cw - 16)
        $w.Top  = [Math]::Round($wa.Bottom - $ch - 16)
    } catch { }
}

# ═══════════════════════════════════════════════════════════════
# 状态渲染（唯一出口 —— 所有 setter 都落到这里）
# ═══════════════════════════════════════════════════════════════
function Update-UISurface {
    if (-not $script:UI) { return }
    $c = $script:UI.Ctl
    $s = $script:UIState

    try {
        # ---- 配色 ----
        $accent = switch ($s.Mode) {
            'Work'  { $script:C.Accent }
            'Done'  { $script:C.Ok }
            'Warn'  { $script:C.Warn }
            'Error' { $script:C.Err }
            default { $script:C.Idle }
        }

        # ---- 顶部状态胶囊：只说硬盘连没连。同步进度由下面的大标题负责，
        #      两个都说"正在同步"就是纯重复 ----
        if ($s.Connected -eq $true) {
            $pillText = '已连接';   $pillFg = $script:C.Ok;     $pillBg = $script:C.OkBg
        } elseif ($s.Connected -eq $false) {
            $pillText = '未连接';   $pillFg = $script:C.Err;    $pillBg = $script:C.ErrBg
        } else {
            $pillText = '检测中';   $pillFg = $script:C.Txt3;   $pillBg = $script:C.Soft
        }
        $c.Pill.Background = ConvertTo-Brush $pillBg
        $c.PillText.Text       = $pillText
        $c.PillText.Foreground = ConvertTo-Brush $pillFg
        $c.Dot.Background      = ConvertTo-Brush $pillFg

        # ---- 主状态 ----
        $c.HeroTitle.Text      = $s.Title
        $c.HeroTitle.Foreground = ConvertTo-Brush $script:C.Txt1
        $c.HeroDetail.Text     = $s.Detail
        # 没有速度也没有提示时整行收掉：空 TextBlock 仍然会占一行的高度
        $metaTxt = if ($s.Meta) { $s.Meta } else { $s.HintLine }
        $c.HeroMeta.Text       = $metaTxt
        $c.HeroMeta.Visibility = if ($metaTxt) { 'Visible' } else { 'Collapsed' }

        # 百分比数字只在同步中显示（完成时写"100%"是废话），
        # 但进度条本身在完成/中断时也要画满 —— 否则会出现一条空槽。
        $showPctLabel = ($s.Mode -eq 'Work' -and $s.Percent -gt 0)
        $pctShown = switch ($s.Mode) {
            'Idle'  { 0 }
            'Done'  { 100 }
            default { $s.Percent }
        }
        $c.HeroPct.Text = if ($showPctLabel) { '{0}%' -f $s.Percent } else { '' }
        $c.HeroPct.Foreground = ConvertTo-Brush $accent

        $c.Fill.Background = ConvertTo-Brush $accent
        $c.Fill.Width = [Math]::Round(410 * $pctShown / 100.0, 0)
        # 空闲时不画进度槽：一条空槽在待命状态下只是噪音，还白占一行高度
        $c.Track.Visibility = if ($s.Mode -eq 'Idle') { 'Collapsed' } else { 'Visible' }
        $c.Track.Background = ConvertTo-Brush $script:C.TrackBg

        # ---- 四格 ----
        $diskTxt = if ($s.Connected -eq $true) {
            if ($s.DiskName) { '{0}: · {1}' -f $s.DiskLetter, $s.DiskName }
            elseif ($s.DiskLetter) { '{0}:  已连接' -f $s.DiskLetter }
            else { '已连接' }
        } elseif ($s.Connected -eq $false) { '未连接' } else { '检测中' }
        $c.V_Disk.Text = $diskTxt
        $c.V_Disk.Foreground = ConvertTo-Brush $(if ($s.Connected -eq $false) { $script:C.Err } else { $script:C.Txt1 })

        # 体积只在大标题里出现一次，这里只给个数
        $c.V_Files.Text = $s.Files
        $c.V_Last.Text = $s.LastSync

        $nc = $script:Notifications.Count
        $c.V_Pending.Text = if ($nc -gt 0) { '{0} 项' -f $nc } else { '无' }
        $c.V_Pending.Foreground = ConvertTo-Brush $(if ($nc -gt 0) { $script:C.Warn } else { $script:C.Txt1 })

        # ---- 问题清单 ----
        Update-NoticesUI

        # ---- 按钮 ----
        if ($s.Syncing) {
            $c.BtnSync.Content = '停止同步'
            $c.BtnSync.Style   = $script:UI.Res.Danger
        } else {
            $c.BtnSync.Content = '立即同步'
            $c.BtnSync.Style   = $script:UI.Res.Primary
        }

        # ---- 状态栏 ----
        $c.FootText.Text = if ($s.Footer) { $s.Footer } else { '未在监听' }
        $c.FootTime.Text = (Get-Date).ToString('HH:mm:ss')
        $c.FootDot.Background = ConvertTo-Brush $(if ($s.Footer -match '监听') { $script:C.Ok } else { $script:C.Idle })

        # ---- 迷你条 ----
        $c.RingValue.Stroke = ConvertTo-Brush $accent
        $c.RingTrack.Stroke = ConvertTo-Brush $script:C.RingTrack
        Set-RingValue $c.RingValue $pctShown

        $c.MiniTitle.Text     = $s.Title
        $c.MiniTitle.Foreground = ConvertTo-Brush $script:C.Txt1
        $c.MiniPct.Text       = if ($showPctLabel) { '{0}%' -f $s.Percent } else { '' }
        $c.MiniPct.Foreground = ConvertTo-Brush $accent
        # 一行只放最有用的那条：同步中给速度，完成给结论，异常给卡在哪
        $c.MiniMeta.Text      = if ($s.Meta) { $s.Meta } elseif ($s.HintLine) { $s.HintLine } elseif ($s.Detail) { $s.Detail } else { '' }
        $c.MiniMeta.Foreground = ConvertTo-Brush $script:C.Txt3

        if ($nc -gt 0) {
            $c.MiniBadge.Visibility = 'Visible'
            $c.MiniBadgeText.Text   = [string]$nc
            $hasErr = @($script:Notifications | Where-Object { $_.Level -eq 'Error' }).Count -gt 0
            $c.MiniBadge.Background = ConvertTo-Brush $(if ($hasErr) { $script:C.ErrBg } else { $script:C.WarnBg })
            $c.MiniBadgeText.Foreground = ConvertTo-Brush $(if ($hasErr) { $script:C.Err } else { $script:C.Warn })
        } else {
            $c.MiniBadge.Visibility = 'Collapsed'
        }

        if ($script:UIMode -eq 'Console') { Resize-UIShell }

        # 该在就在，该藏就藏 —— 状态一变就重新判一次，用户不用管
        Update-BarVisibility
    } catch { }
}

# ═══════════════════════════════════════════════════════════════
# 问题清单
# ═══════════════════════════════════════════════════════════════
function Update-NoticesUI {
    if (-not $script:UI) { return }
    $c = $script:UI.Ctl
    $list = $script:Notifications
    $n = $list.Count

    try {
        if ($n -eq 0) {
            $c.IssueCard.Visibility = 'Collapsed'
            $c.IssueItems.Children.Clear()
            return
        }

        $hasErr = @($list | Where-Object { $_.Level -eq 'Error' }).Count -gt 0
        $fg  = if ($hasErr) { $script:C.Err }  else { $script:C.Warn }
        $bg  = if ($hasErr) { $script:C.ErrBg } else { $script:C.WarnBg }
        $bd  = if ($hasErr) { $script:C.ErrLine }       else { $script:C.WarnLine }

        $c.IssueCard.Background    = ConvertTo-Brush $bg
        $c.IssueCard.BorderBrush   = ConvertTo-Brush $bd
        $c.IssueIcon.Stroke        = ConvertTo-Brush $fg
        $c.IssueHead.Foreground    = ConvertTo-Brush $fg
        $c.IssueAdvice.Foreground  = ConvertTo-Brush $(if ($hasErr) { $script:C.ErrTxt } else { $script:C.WarnTxt })

        # 标题给结论，正文只补细节，同一句话绝不写两遍：
        #   一条     → 标题 = 原因，正文 = 一句说明
        #   同类多条 → 标题 = "N 个X"，正文 = 各自路径
        #   混合     → 标题 = "N 个问题"，正文 = 原因 + 路径
        $reasons = @($list | ForEach-Object { $_.Reason } | Select-Object -Unique)
        $uniform = ($reasons.Count -eq 1)
        $single  = ($n -eq 1)

        if ($single)      { $c.IssueHead.Text = $reasons[0] }
        elseif ($uniform) { $c.IssueHead.Text = '{0} 个{1}' -f $n, $reasons[0] }
        else              { $c.IssueHead.Text = '{0} 个问题需要处理' -f $n }

        # 行重绘：条目没变就不重画，避免闪烁
        $sig = $c.IssueHead.Text + '#' + (($list | ForEach-Object { $_.Reason + '|' + $_.Target }) -join "`n")
        if ($sig -ne $script:LastNoticeSig) {
            $script:LastNoticeSig = $sig
            $c.IssueItems.Children.Clear()

            if ($single) {
                $desc = New-Object System.Windows.Controls.TextBlock
                $desc.Text = $list[0].Target
                $desc.FontSize = 11.5
                $desc.Foreground = ConvertTo-Brush $script:C.Txt2
                $desc.TextWrapping = 'Wrap'
                $desc.LineHeight = 17
                $c.IssueItems.Children.Add($desc) | Out-Null
            }
            else {
                $shown = 0
                foreach ($it in $list) {
                    if ($shown -ge 5) { break }
                    $shown++

                    if ($uniform) {
                        # 原因都写在标题里了，行里不必重复
                        $t = New-Object System.Windows.Controls.TextBlock
                        $t.Text = '·  ' + $it.Target
                        $t.FontSize = 11
                        $t.Foreground = ConvertTo-Brush $script:C.Txt2
                        $t.TextTrimming = 'CharacterEllipsis'
                        $t.Margin = New-Object System.Windows.Thickness(0, 1, 0, 1)
                        $c.IssueItems.Children.Add($t) | Out-Null
                    }
                    else {
                        $row = New-Object System.Windows.Controls.Grid
                        $row.Margin = New-Object System.Windows.Thickness(0, 1, 0, 1)
                        $col1 = New-Object System.Windows.Controls.ColumnDefinition
                        $col1.Width = New-Object System.Windows.GridLength(76)
                        $col2 = New-Object System.Windows.Controls.ColumnDefinition
                        $col2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
                        $row.ColumnDefinitions.Add($col1)
                        $row.ColumnDefinitions.Add($col2)

                        $t1 = New-Object System.Windows.Controls.TextBlock
                        $t1.Text = $it.Reason
                        $t1.FontSize = 11
                        $t1.Foreground = ConvertTo-Brush $fg
                        $t1.TextTrimming = 'CharacterEllipsis'
                        $t1.VerticalAlignment = 'Center'
                        [System.Windows.Controls.Grid]::SetColumn($t1, 0)
                        $row.Children.Add($t1) | Out-Null

                        $t2 = New-Object System.Windows.Controls.TextBlock
                        $t2.Text = $it.Target
                        $t2.FontSize = 11
                        $t2.Foreground = ConvertTo-Brush $script:C.Txt2
                        $t2.TextTrimming = 'CharacterEllipsis'
                        $t2.VerticalAlignment = 'Center'
                        [System.Windows.Controls.Grid]::SetColumn($t2, 1)
                        $row.Children.Add($t2) | Out-Null

                        $c.IssueItems.Children.Add($row) | Out-Null
                    }
                }

                if ($n -gt $shown) {
                    $tail = New-Object System.Windows.Controls.TextBlock
                    $tail.FontSize = 10.5
                    $tail.Margin = New-Object System.Windows.Thickness(0, 3, 0, 0)
                    $tail.Text = ('另有 {0} 项，完整清单见 logs 目录' -f ($n - $shown))
                    $tail.Foreground = ConvertTo-Brush $script:C.Txt3
                    $c.IssueItems.Children.Add($tail) | Out-Null
                }
            }
        }

        $adv = ''
        foreach ($it in $list) { if ($it.Advice) { $adv = $it.Advice; break } }
        if ($adv) {
            $c.IssueAdvice.Text = $adv
            $c.IssueAdvice.Visibility = 'Visible'
        } else {
            $c.IssueAdvice.Visibility = 'Collapsed'
        }
        $c.IssueCard.Visibility = 'Visible'
    } catch { }
}

$script:LastNoticeSig = ''

function Add-UINotice {
    param(
        [ValidateSet('Error', 'Warn', 'Info', 'OK')][string]$Level = 'Warn',
        [string]$Reason = '',
        [string]$Target = '',
        [string]$Advice = '',
        [string]$Key = ''
    )

    if (-not $Reason) { $Reason = '异常' }
    if (-not $Key)    { $Key = ('{0}|{1}|{2}' -f $Level, $Reason, $Target) }
    if ($script:NoticeKeys.ContainsKey($Key)) { return $false }
    $script:NoticeKeys[$Key] = $true

    # 真出错的时候打扰是应该的：把"别再出现"解掉，让条子回来
    if ($Level -eq 'Error') {
        $script:UIDismissed = $false
        $script:HideAt = $null
    }

    [void]$script:Notifications.Add([pscustomobject]@{
        Level  = $Level
        Reason = $Reason
        Target = $Target
        Advice = $Advice
    })

    Save-UIStatus

    if (-not (Test-UIAlive)) {
        if ($script:Notifications.Count -le 40) {
            $line = '    [{0}] {1}' -f $(switch ($Level) { 'Error' { '错误' } 'Warn' { '警告' } 'OK' { '完成' } default { '提示' } }), $Reason
            if ($Target) { $line += '  ' + $Target }
            $col = switch ($Level) { 'Error' { 'Red' } 'Warn' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
            Write-Host $line -ForegroundColor $col
        } elseif ($script:Notifications.Count -eq 41) {
            Write-Host '    … 更多异常见日志' -ForegroundColor DarkGray
        }
        return $true
    }

    Update-UISurface
    Invoke-UIPump
    return $true
}

function Clear-UINotice {
    $script:Notifications.Clear()
    $script:NoticeKeys = @{}
    $script:LastNoticeSig = ''
    if (Test-UIAlive) { Update-UISurface }
    Save-UIStatus
}

function Get-UINoticeCount { return $script:Notifications.Count }
function Get-UINoticeList  { return @($script:Notifications) }

function Get-NoticeSummary {
    param([switch]$WithLevel)
    if ($script:Notifications.Count -eq 0) { return '' }
    $g = [ordered]@{}
    foreach ($x in $script:Notifications) {
        if ($g.Contains($x.Reason)) { $g[$x.Reason]++ } else { $g[$x.Reason] = 1 }
    }
    $parts = @($g.GetEnumerator() | ForEach-Object { '{0} 个{1}' -f $_.Value, $_.Key })
    return ($parts -join '、')
}

# ═══════════════════════════════════════════════════════════════
# 对外更新接口
# ═══════════════════════════════════════════════════════════════
function Set-UISyncing {
    param([bool]$Value)
    $script:UIState.Syncing = $Value
    if (Test-UIAlive) { Update-UISurface }
    Save-UIStatus
}

<#
    Set-UIStatus
    状态栏 / 四格数据的统一入口。传进来的键才覆盖，其余保持不变。
#>
function Set-UIStatus {
    param(
        [Nullable[bool]]$Connected,
        [string]$DiskLetter,
        [string]$DiskName,
        [string]$Files,
        [string]$Size,
        [string]$LastSync,
        [string]$Footer
    )
    if ($PSBoundParameters.ContainsKey('Connected'))  { $script:UIState.Connected  = $Connected }
    if ($PSBoundParameters.ContainsKey('DiskLetter')) { $script:UIState.DiskLetter = $DiskLetter }
    if ($PSBoundParameters.ContainsKey('DiskName'))   { $script:UIState.DiskName   = $DiskName }
    if ($PSBoundParameters.ContainsKey('Files'))      { $script:UIState.Files      = $Files }
    if ($PSBoundParameters.ContainsKey('Size'))       { $script:UIState.Size       = $Size }
    if ($PSBoundParameters.ContainsKey('LastSync'))   { $script:UIState.LastSync   = $LastSync }
    if ($PSBoundParameters.ContainsKey('Footer'))     { $script:UIState.Footer     = $Footer }
    if (Test-UIAlive) { Update-UISurface }
    Save-UIStatus
}

<#
    Update-ProgressUI
    与旧版签名一致：Title / Detail / Hint / Percent / State。
    Hint 不再单独占一行 —— 同步中有速度就不显示，没有速度时（完成/失败）才顶上来。
#>
function Update-ProgressUI {
    param(
        [string]$Title,
        [string]$Detail,
        [string]$Hint,
        [int]$Percent = -1,
        [ValidateSet('Work', 'Done', 'Error', 'Warn', 'Idle')][string]$State = 'Work'
    )

    if ($PSBoundParameters.ContainsKey('Title') -and $Title)   { $script:UIState.Title  = $Title }
    if ($PSBoundParameters.ContainsKey('Detail'))              { $script:UIState.Detail = $Detail }
    if ($PSBoundParameters.ContainsKey('Hint'))                { $script:UIState.HintLine = $Hint }
    if ($PSBoundParameters.ContainsKey('Percent')) {
        $p = [Math]::Max(0, [Math]::Min(100, $Percent))
        $script:UIState.Percent = $p
    }
    $prevMode = $script:UIState.Mode
    $script:UIState.Mode    = $State
    $script:UIState.Syncing = ($State -eq 'Work')
    if ($State -ne 'Work') { $script:UIState.Meta = '' }

    # 新的一轮同步开始 → 之前"别再出现"作废，用户这时候是想看的
    if ($State -eq 'Work' -and $prevMode -ne 'Work') {
        $script:UIDismissed = $false
        $script:HideAt = $null
    }
    # 完成后再停 6 秒就自己收起来；异常则常驻，等你处理
    if ($State -eq 'Done') {
        $script:HideAt = (Get-Date).AddSeconds(6)
    } elseif ($State -eq 'Error' -or $State -eq 'Warn') {
        $script:HideAt = $null
    }

    Save-UIStatus

    if (-not (Test-UIAlive)) {
        if ($PSBoundParameters.ContainsKey('Percent')) {
            if ($script:UIState.Percent -ge $script:LastConsolePct + 10 -or $script:UIState.Percent -ge 100 -or $State -ne 'Work') {
                $script:LastConsolePct = $script:UIState.Percent
                $line = '[{0,3}%] {1}' -f $script:UIState.Percent, $script:UIState.Title
                if ($Detail) { $line += '  ' + $Detail }
                switch ($State) {
                    'Done'  { Write-Host $line -ForegroundColor Green }
                    'Error' { Write-Host $line -ForegroundColor Red }
                    'Warn'  { Write-Host $line -ForegroundColor Yellow }
                    default { Write-Host $line -ForegroundColor DarkGray }
                }
            }
        }
        return
    }

    Update-UISurface
    Invoke-UIPump
}

# 同步循环里单独更新速度 / 剩余时间
function Set-UIMeta {
    param([string]$Text)
    $script:UIState.Meta = $Text
    if (Test-UIAlive) { Update-UISurface; Invoke-UIPump }
    Save-UIStatus -MinIntervalMs 400
}

# ═══════════════════════════════════════════════════════════════
# 控制指令（按钮 → 调用方）
# ═══════════════════════════════════════════════════════════════
function Get-UIAction {
    $out = @()
    while ($script:UIActions.Count -gt 0) { $out += $script:UIActions.Dequeue() }
    return $out
}

function Test-UICancelRequested {
    param([switch]$Clear)
    $v = $script:CancelRequested
    if ($Clear) { $script:CancelRequested = $false }
    return $v
}

function Clear-UICancelRequest { $script:CancelRequested = $false }

# ═══════════════════════════════════════════════════════════════
# 提示气泡
# ═══════════════════════════════════════════════════════════════
function Show-Toast {
    param(
        [string]$Title = 'FileSync',
        [string]$Text  = '',
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info',
        [int]$Seconds = 7
    )
    if (-not $Text) { return $false }

    # 有托盘就复用（否则每弹一次就多一个图标）
    if ($script:UI -and $script:UI.Tray) {
        try {
            $script:UI.Tray.BalloonTipTitle = $Title
            $script:UI.Tray.BalloonTipText  = $Text
            $script:UI.Tray.BalloonTipIcon  = switch ($Level) {
                'Warn'  { [System.Windows.Forms.ToolTipIcon]::Warning }
                'Error' { [System.Windows.Forms.ToolTipIcon]::Error }
                default { [System.Windows.Forms.ToolTipIcon]::Info }
            }
            $script:UI.Tray.ShowBalloonTip([Math]::Max(3000, $Seconds * 1000))
            $deadline = (Get-Date).AddSeconds([Math]::Min($Seconds, 3))
            while ((Get-Date) -lt $deadline) {
                Invoke-UIPump
                Start-Sleep -Milliseconds 80
            }
            return $true
        } catch { }
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $ni = New-Object System.Windows.Forms.NotifyIcon
        switch ($Level) {
            'Warn'  { $ni.Icon = [System.Drawing.SystemIcons]::Warning;     $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning }
            'Error' { $ni.Icon = [System.Drawing.SystemIcons]::Error;       $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error }
            default { $ni.Icon = [System.Drawing.SystemIcons]::Information; $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info }
        }
        $ni.Text = 'FileSync'
        $ni.Visible = $true
        $ni.BalloonTipTitle = $Title
        $ni.BalloonTipText  = $Text
        $ni.ShowBalloonTip([Math]::Max(3000, $Seconds * 1000))
        $deadline = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        $ni.Visible = $false
        $ni.Dispose()
        return $true
    } catch { return $false }
}

# ═══════════════════════════════════════════════════════════════
# 关闭
# ═══════════════════════════════════════════════════════════════
function Close-ProgressWindow {
    param([int]$DelaySeconds = 0, [switch]$KeepTray)

    if (-not (Test-UIAlive)) { $script:UI = $null; return }

    $script:UIClosing = $true
    if ($DelaySeconds -gt 0) {
        $deadline = (Get-Date).AddSeconds($DelaySeconds)
        while ((Get-Date) -lt $deadline) {
            if (-not $script:UI) { return }
            Invoke-UIPump
            Start-Sleep -Milliseconds 120
        }
    }

    if ($script:UI) {
        try {
            # 监听模式下窗口是常驻的：只收起来，不销毁。
            # 销毁再重建会让托盘图标闪一下，也容易出现"刚关掉又自己弹回来"。
            if ($script:PersistentUI) {
                $script:UIClosing = $false
                Hide-Bar
                return
            }
            if (-not $KeepTray -and $script:UI.Tray) {
                $script:UI.Tray.Visible = $false
                $script:UI.Tray.Dispose()
                $script:UI.Tray = $null
            }
            $script:UI.Window.Close()
        } catch { }
    }
    $script:UI = $null
    $script:UIBuilt = $false
    $script:UIClosing = $false
}

function Show-ConsoleWindow { Set-UIMode -Mode 'Console' }
function Show-MiniWindow    { Set-UIMode -Mode 'Mini' }

# ═══════════════════════════════════════════════════════════════
# 状态落盘 ── 本地 Web 控制台读的就是这个文件
# ═══════════════════════════════════════════════════════════════
<#
    为什么落盘而不是开个端口：
    同步引擎是个单线程同步循环，边拷文件边收 HTTP 请求很容易互相拖死。
    把状态写成一个小 JSON（1~3 KB），网页端轮询读，引擎零负担；
    Web 服务进程挂了、浏览器关了，迷你窗和托盘照旧工作。
#>

$script:EscapeMap = @{ '"' = '\"'; '\' = '\\'; "`b" = '\b'; "`f" = '\f'; "`n" = '\n'; "`r" = '\r'; "`t" = '\t' }

function ConvertTo-JsonStr {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 'null' }
    $s = [string]$Value
    if ($s.Length -eq 0) { return '""' }
    $sb = New-Object System.Text.StringBuilder ($s.Length + 8)
    foreach ($ch in $s.ToCharArray()) {
        $k = [string]$ch
        if ($script:EscapeMap.ContainsKey($k)) {
            [void]$sb.Append($script:EscapeMap[$k])
        } elseif ([int]$ch -lt 32) {
            [void]$sb.Append(('\u{0:x4}' -f [int]$ch))
        } else {
            [void]$sb.Append($ch)
        }
    }
    return '"' + $sb.ToString() + '"'
}

function Save-UIStatus {
    param([int]$MinIntervalMs = 0)

    try {
        $now = Get-Date
        if ($MinIntervalMs -gt 0 -and $script:LastStatusWrite) {
            if (($now - $script:LastStatusWrite).TotalMilliseconds -lt $MinIntervalMs) { return }
        }

        if (-not (Test-Path -LiteralPath $script:IPCDir)) {
            [void](New-Item -ItemType Directory -Path $script:IPCDir -Force -ErrorAction Stop)
        }

        $s  = $script:UIState
        $rt = $script:UIRuntime
        $sb = New-Object System.Text.StringBuilder 1024

        [void]$sb.Append('{')
        [void]$sb.Append('"ts":').Append((ConvertTo-JsonStr $now.ToString('o'))).Append(',')
        [void]$sb.Append('"session":').Append((ConvertTo-JsonStr $rt.StartedAt)).Append(',')
        [void]$sb.Append('"pid":').Append([int]$rt.WatchPid).Append(',')
        [void]$sb.Append('"mode":').Append((ConvertTo-JsonStr $s.Mode)).Append(',')
        [void]$sb.Append('"percent":').Append([int]$s.Percent).Append(',')
        [void]$sb.Append('"title":').Append((ConvertTo-JsonStr $s.Title)).Append(',')
        [void]$sb.Append('"detail":').Append((ConvertTo-JsonStr $s.Detail)).Append(',')
        [void]$sb.Append('"meta":').Append((ConvertTo-JsonStr $s.Meta)).Append(',')
        [void]$sb.Append('"hint":').Append((ConvertTo-JsonStr $s.HintLine)).Append(',')
        [void]$sb.Append('"advice":').Append((ConvertTo-JsonStr $s.Advice)).Append(',')
        [void]$sb.Append('"syncing":').Append($(if ($s.Syncing) { 'true' } else { 'false' })).Append(',')
        [void]$sb.Append('"paused":').Append($(if ($rt.Paused) { 'true' } else { 'false' })).Append(',')
        [void]$sb.Append('"connected":')
        if ($null -eq $s.Connected) { [void]$sb.Append('null') } elseif ($s.Connected) { [void]$sb.Append('true') } else { [void]$sb.Append('false') }
        [void]$sb.Append(',')
        [void]$sb.Append('"diskLetter":').Append((ConvertTo-JsonStr $s.DiskLetter)).Append(',')
        [void]$sb.Append('"diskName":').Append((ConvertTo-JsonStr $s.DiskName)).Append(',')
        [void]$sb.Append('"files":').Append((ConvertTo-JsonStr $s.Files)).Append(',')
        [void]$sb.Append('"size":').Append((ConvertTo-JsonStr $s.Size)).Append(',')
        [void]$sb.Append('"lastSync":').Append((ConvertTo-JsonStr $s.LastSync)).Append(',')
        [void]$sb.Append('"footer":').Append((ConvertTo-JsonStr $s.Footer)).Append(',')
        [void]$sb.Append('"bound":').Append($(if ($rt.Bound) { 'true' } else { 'false' })).Append(',')
        [void]$sb.Append('"bindName":').Append((ConvertTo-JsonStr $rt.BindName)).Append(',')
        [void]$sb.Append('"bindSize":').Append((ConvertTo-JsonStr $rt.BindSize)).Append(',')
        [void]$sb.Append('"interval":').Append([int]$rt.Interval).Append(',')
        [void]$sb.Append('"lastSyncAt":').Append((ConvertTo-JsonStr $rt.LastSyncAt)).Append(',')

        [void]$sb.Append('"issues":[')
        $n = 0
        foreach ($it in $script:Notifications) {
            if ($n -ge 60) { break }
            if ($n -gt 0) { [void]$sb.Append(',') }
            [void]$sb.Append('{"level":').Append((ConvertTo-JsonStr $it.Level))
            [void]$sb.Append(',"reason":').Append((ConvertTo-JsonStr $it.Reason))
            [void]$sb.Append(',"target":').Append((ConvertTo-JsonStr $it.Target))
            [void]$sb.Append(',"advice":').Append((ConvertTo-JsonStr $it.Advice))
            [void]$sb.Append('}')
            $n++
        }
        [void]$sb.Append(']')

        [void]$sb.Append(',"activity":[')
        $acts = @($rt.Activity)
        $start = [Math]::Max(0, $acts.Count - 40)
        for ($i = $start; $i -lt $acts.Count; $i++) {
            if ($i -gt $start) { [void]$sb.Append(',') }
            $a = $acts[$i]
            [void]$sb.Append('{"t":').Append((ConvertTo-JsonStr $a.T))
            [void]$sb.Append(',"level":').Append((ConvertTo-JsonStr $a.Level))
            [void]$sb.Append(',"msg":').Append((ConvertTo-JsonStr $a.Msg))
            [void]$sb.Append('}')
        }
        [void]$sb.Append(']}')

        $json = $sb.ToString()
        if (-not $script:LastStatusJson) { $script:LastStatusJson = '' }
        if ($json -eq $script:LastStatusJson) { return }

        $tmp = $script:StatusFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Copy($tmp, $script:StatusFile, $true)
        try { [System.IO.File]::Delete($tmp) } catch { }

        $script:LastStatusJson = $json
        $script:LastStatusWrite = $now
    } catch { }
}

<#
    Set-UIRuntime
    元信息（绑定、监听间隔、最近同步时间）与 UIState 分开，
    免得和迷你窗的四格数据互相覆盖。
#>
function Set-UIRuntime {
    param([string]$Key, $Value)
    $script:UIRuntime[$Key] = $Value
    if ($Key -eq 'Paused') {
        try { Update-TrayPauseItem } catch { }   # 菜单文字/图标跟着暂停状态走
    }
    Save-UIStatus
}

<#
    Push-UIActivity
    网页左下角「活动」区。只留最近 40 条，不落日志文件（日志另有 Write-Log）。
#>
function Push-UIActivity {
    param([string]$Level, [string]$Msg)
    if (-not $Msg) { return }
    $list = [System.Collections.ArrayList]@($script:UIRuntime.Activity)
    [void]$list.Add([pscustomobject]@{ T = (Get-Date).ToString('HH:mm:ss'); Level = $Level; Msg = $Msg })
    while ($list.Count -gt 40) { $list.RemoveAt(0) }
    $script:UIRuntime.Activity = @($list)
    Save-UIStatus -MinIntervalMs 600
}

<#
    Get-IPCCommand
    网页按钮 → Web 服务写文件 → 这里消费掉。
    文件名带时间戳前缀，保证先进先出。
#>
function Get-IPCCommand {
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $script:CmdDir)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $script:CmdDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $files) {
        try {
            $txt = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            if ($txt) {
                $o = $txt | ConvertFrom-Json
                if ($o -and $o.cmd) { [void]$out.Add($o) }
            }
        } catch { }
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } catch { }
    }
    return @($out)
}
