<#
============================================================================
  屏幕OCR助手（极简版）—— 只保留一个功能：
    全局热键 Alt + R  ->  框选屏幕区域  ->  Windows 内置 OCR 识别
    ->  文字自动复制到剪贴板  ->  托盘气泡提示（无大弹窗、无任何询问）
----------------------------------------------------------------------------
  依赖：Windows 10/11 + 系统自带 powershell.exe（Windows PowerShell 5.1）。
  隐私：识别在本机完成，无网络上传。
  参数：-CheckOcr / -SelfTest / -SmokeTest / -GuiSmoke / -InstallSelf / -UninstallSelf
============================================================================
#>
[CmdletBinding()]
param(
    [switch]$CheckOcr,
    [switch]$SelfTest,
    [switch]$SmokeTest,
    [switch]$GuiSmoke,
    [switch]$OverlayTest,
    [switch]$InstallSelf,
    [switch]$UninstallSelf
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------- 配置 ----------
$script:AppName      = '屏幕OCR助手'
$script:AutoStartKey = 'ImgOcrAssistant'

# 热键：Alt + R（MOD_ALT=1；R 键码 0x52）。想改就改这里：
$script:MOD_ALT      = 1
$script:HK_MODS      = $script:MOD_ALT
$script:HK_ID_REGION = 1
$script:HK_VK_REGION = 0x52

# ---------- 运行时状态 ----------
$script:Busy      = $false
$script:Notify    = $null
$script:HotkeyWin = $null
$script:IconKeep  = $null
$script:OcrEngine = $null

# =====================================================================
#  原生桥接 C#（热键窗口 + 屏幕框选 + DPI）
# =====================================================================
$script:NativeCs = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ImgOcrNative
{
    public sealed class HotKeyEventArgs : EventArgs
    {
        public readonly int Id;
        public HotKeyEventArgs(int id) { Id = id; }
    }

    public static class Dpi
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();
        public static void MakeAware()
        {
            try { SetProcessDPIAware(); } catch { }
        }
    }

    public sealed class HotkeyWindow : NativeWindow
    {
        private const int WM_HOTKEY = 0x0312;
        public event EventHandler<HotKeyEventArgs> HotKeyPressed;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        public HotkeyWindow()
        {
            CreateParams cp = new CreateParams();
            cp.Parent = new IntPtr(-3);   // HWND_MESSAGE：不可见消息窗口
            CreateHandle(cp);
        }

        public bool RegisterHotkey(int id, uint modifiers, uint virtualKey)
        {
            try { return RegisterHotKey(this.Handle, id, modifiers, virtualKey); }
            catch { return false; }
        }

        public void UnregisterHotkey(int id)
        {
            try { UnregisterHotKey(this.Handle, id); } catch { }
        }

        public void Shutdown()
        {
            try { DestroyHandle(); } catch { }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY)
            {
                int id = unchecked((int)(long)m.WParam);
                EventHandler<HotKeyEventArgs> handler = HotKeyPressed;
                if (handler != null) handler(this, new HotKeyEventArgs(id));
                return;
            }
            base.WndProc(ref m);
        }
    }

    public static class ScreenCapture
    {
        public static Bitmap SelectRegion()
        {
            RegionForm f = new RegionForm();
            try
            {
                f.ShowDialog();
                if (!f.Cancelled && f.Selection.Width >= 4 && f.Selection.Height >= 4)
                {
                    System.Threading.Thread.Sleep(150);
                    Application.DoEvents();
                    return Capture(f.Selection);
                }
                return null;
            }
            finally
            {
                f.Dispose();
            }
        }

        private static Bitmap Capture(Rectangle rect)
        {
            Bitmap bmp = new Bitmap(rect.Width, rect.Height, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.CopyFromScreen(rect.Left, rect.Top, 0, 0, rect.Size, CopyPixelOperation.SourceCopy);
            }
            return bmp;
        }

        private sealed class RegionForm : Form
        {
            private const int MinSize = 4;
            public bool Cancelled { get; set; }
            public Rectangle Selection { get; set; }
            private bool _dragging;
            private Point _start;
            private Rectangle _cur;

            public RegionForm()
            {
                Cancelled = true;
                SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
                this.Bounds = SystemInformation.VirtualScreen;
                this.FormBorderStyle = FormBorderStyle.None;
                this.StartPosition = FormStartPosition.Manual;
                this.TopMost = true;
                this.ShowInTaskbar = false;
                this.BackColor = Color.Black;
                this.Opacity = 0.30;
                this.Cursor = Cursors.Cross;
                this.KeyPreview = true;
                this.MouseDown += new MouseEventHandler(OnDown);
                this.MouseMove += new MouseEventHandler(OnMove);
                this.MouseUp += new MouseEventHandler(OnUp);
                this.KeyDown += new KeyEventHandler(OnKey);
                this.Paint += new PaintEventHandler(OnPaintForm);
            }

            private void OnDown(object sender, MouseEventArgs e)
            {
                if (e.Button == MouseButtons.Left)
                {
                    _dragging = true;
                    _start = Cursor.Position;
                    _cur = new Rectangle(_start.X, _start.Y, 0, 0);
                    Invalidate();
                }
            }

            private void OnMove(object sender, MouseEventArgs e)
            {
                if (!_dragging) return;
                Rectangle r = FromPoints(_start, Cursor.Position);
                if (r != _cur)
                {
                    _cur = r;
                    Invalidate();
                }
            }

            private void OnUp(object sender, MouseEventArgs e)
            {
                if (!_dragging) return;
                _dragging = false;
                if (_cur.Width >= MinSize && _cur.Height >= MinSize)
                {
                    Selection = _cur;
                    Cancelled = false;
                }
                this.Close();
            }

            private void OnKey(object sender, KeyEventArgs e)
            {
                if (e.KeyCode == Keys.Escape) this.Close();
            }

            private static Rectangle FromPoints(Point a, Point b)
            {
                int x = Math.Min(a.X, b.X);
                int y = Math.Min(a.Y, b.Y);
                int w = Math.Abs(a.X - b.X);
                int h = Math.Abs(a.Y - b.Y);
                return new Rectangle(x, y, w, h);
            }

            private void OnPaintForm(object sender, PaintEventArgs e)
            {
                if (_cur.Width > 0 && _cur.Height > 0)
                {
                    Rectangle c = this.RectangleToClient(_cur);
                    using (SolidBrush sb = new SolidBrush(Color.FromArgb(70, 255, 255, 255)))
                    {
                        e.Graphics.FillRectangle(sb, c);
                    }
                    using (Pen pen = new Pen(Color.Red, 2f))
                    {
                        e.Graphics.DrawRectangle(pen, c.X, c.Y, c.Width, c.Height);
                    }
                }
            }
        }
    }
}
'@

function Compile-NativeBridge {
    try {
        Add-Type -TypeDefinition $script:NativeCs -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop | Out-Null
    }
    catch { throw ('原生桥接编译失败：' + $_.Exception.Message) }
}

# =====================================================================
#  OCR（Windows.Media.Ocr）
# =====================================================================
function Initialize-OcrEnvironment {
    try { Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop | Out-Null } catch { return $false }
    $typeList = @(
        'Windows.Storage.StorageFile, Windows.Storage',
        'Windows.Storage.FileAccessMode, Windows.Storage',
        'Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams',
        'Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics',
        'Windows.Graphics.Imaging.BitmapPixelFormat, Windows.Graphics',
        'Windows.Graphics.Imaging.BitmapAlphaMode, Windows.Graphics',
        'Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics',
        'Windows.Media.Ocr.OcrEngine, Windows.Foundation',
        'Windows.Media.Ocr.OcrResult, Windows.Foundation'
    )
    foreach ($t in $typeList) {
        try { [void][Type]::GetType($t + ', ContentType=WindowsRuntime', $true) } catch { return $false }
    }
    try { $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() } catch { $script:OcrEngine = $null }
    return ($null -ne $script:OcrEngine)
}

function Wait-WinRtTask {
    param([object]$WinRtTask, [type]$ResultType)
    $extType = [System.WindowsRuntimeSystemExtensions]
    $m = $extType.GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and
        ($_.GetParameters().Count -eq 1) -and
        ($_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1')
    } | Select-Object -First 1
    if ($null -eq $m) { throw '找不到 WinRT AsTask 适配方法' }
    $task = $m.MakeGenericMethod($ResultType).Invoke($null, @($WinRtTask))
    if ($null -eq $task) { throw 'WinRT 异步任务转换失败' }
    if (-not $task.Wait(-1)) {
        if ($null -ne $task.Exception) { throw $task.Exception }
        throw 'OCR 异步任务未完成'
    }
    return $task.Result
}

function Format-OcrText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t1 = [regex]::Replace($Text, '(?<=[\u2E80-\u9FFF\uF900-\uFAFF\uFF00-\uFFEF])\s+(?=[\u2E80-\u9FFF\uF900-\uFAFF\uFF00-\uFFEF])', '')
    $t2 = [regex]::Replace($t1, '\s*([\u3000-\u303F\uFF01-\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF65])\s*', '$1')
    return $t2.Trim()
}

function Invoke-OcrFile {
    param([string]$Path)
    if ($null -eq $script:OcrEngine) { throw '系统 OCR 不可用：未找到可用的识别语言。' }
    $file  = Wait-WinRtTask ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    $stream = $null
    try {
        $stream  = Wait-WinRtTask ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Wait-WinRtTask ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $src     = Wait-WinRtTask ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $conv = $null
        try { $conv = [Windows.Graphics.Imaging.SoftwareBitmap]::Convert($src, [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied) }
        catch { $conv = $src }
        $res = Wait-WinRtTask ($script:OcrEngine.RecognizeAsync($conv)) ([Windows.Media.Ocr.OcrResult])
        $sb = New-Object System.Text.StringBuilder
        foreach ($line in $res.Lines) { [void]$sb.AppendLine($line.Text) }
        return (Format-OcrText -Text $sb.ToString())
    }
    finally { if ($null -ne $stream) { try { $stream.Dispose() } catch { } } }
}

function Save-ImageToPngFile {
    param([System.Drawing.Image]$Image, [string]$Path)
    $target = $Image
    $temp = $null
    if ($Image -isnot [System.Drawing.Bitmap]) {
        $temp = New-Object System.Drawing.Bitmap($Image.Width, $Image.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($temp)
        try { $g.DrawImage($Image, 0, 0, $Image.Width, $Image.Height) } finally { $g.Dispose() }
        $target = $temp
    }
    try { $target.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png) } finally { if ($temp) { $temp.Dispose() } }
}

function Invoke-OcrImage {
    param([System.Drawing.Image]$Image)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('imgocr_' + [guid]::NewGuid().ToString('N') + '.png')
    try {
        Save-ImageToPngFile -Image $Image -Path $tmp
        return (Invoke-OcrFile -Path $tmp)
    }
    finally { try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { } }
}

# =====================================================================
#  托盘 / 提示
# =====================================================================
function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap(32, 32, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 37, 99, 235))
        try { $g.FillEllipse($bgBrush, 1, 1, 30, 30) } finally { $bgBrush.Dispose() }
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 4)
        try {
            $g.DrawEllipse($pen, 7, 7, 12, 12)
            $g.DrawLine($pen, 17.5, 17.5, 25, 25)
        } finally { $pen.Dispose() }
    } finally { $g.Dispose() }
    $hicon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hicon)
    $script:IconKeep = @($bmp, $hicon)
    return $icon
}

function Show-NotifyBalloon {
    param([string]$Title, [string]$Text, [string]$Icon = 'Info')
    if ($null -eq $script:Notify -or -not $script:Notify.Visible) { return }
    try {
        $script:Notify.BalloonTipTitle = $Title
        $script:Notify.BalloonTipText  = $Text
        $script:Notify.BalloonTipIcon  = $Icon
        $script:Notify.ShowBalloonTip(4000)
    } catch { }
}

function Invoke-RegionOcr {
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        $bmp = [ImgOcrNative.ScreenCapture]::SelectRegion()
        if ($null -ne $bmp) {
            try {
                $text = ''
                try { $text = Invoke-OcrImage -Image $bmp } catch { }
                if ([string]::IsNullOrWhiteSpace($text)) {
                    Show-NotifyBalloon '未识别到文字' '所选区域没有可识别的文字，或文字太小 / 太模糊。' 'Warning'
                    return
                }
                try { [System.Windows.Forms.Clipboard]::SetText($text) } catch { }
                $sn = $text; if ($sn.Length -gt 26) { $sn = $sn.Substring(0, 26) + '...' }
                Show-NotifyBalloon '已复制' ('识别文字已复制到剪贴板：' + $sn) 'Info'
            }
            finally { $bmp.Dispose() }
        }
    }
    catch { Show-NotifyBalloon '识别出错' $_.Exception.Message 'Error' }
    finally { $script:Busy = $false }
}

function Build-TrayUi {
    $script:Notify = New-Object System.Windows.Forms.NotifyIcon
    $script:Notify.Icon = New-TrayIcon
    $script:Notify.Text = '屏幕OCR助手：按 Alt+R 框选识别并复制'
    $script:Notify.Visible = $true
    $script:Notify.add_MouseDoubleClick({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-RegionOcr }
    })

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miRun = New-Object System.Windows.Forms.ToolStripMenuItem('框选屏幕区域识别文字（Alt+R）')
    $miRun.add_Click({ Invoke-RegionOcr })
    [void]$menu.Items.Add($miRun)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miExit = New-Object System.Windows.Forms.ToolStripMenuItem('退出')
    $miExit.add_Click({ Invoke-Exit })
    [void]$menu.Items.Add($miExit)
    $script:Notify.ContextMenuStrip = $menu
}

# =====================================================================
#  开机自启（HKCU Run，沿用原键名，两个 .cmd 仍然可用）
# =====================================================================
function Get-AutoStartCommand {
    $exe = Join-Path $PSHOME 'powershell.exe'
    return ('"' + $exe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "' + $PSCommandPath + '"')
}

function Test-AutoStart {
    try {
        $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $script:AutoStartKey -ErrorAction Stop
        return ($null -ne $v -and ($v -like '*ImgOcrAssistant*'))
    } catch { return $false }
}

function Set-AutoStart {
    param([bool]$Enable)
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($Enable) {
        Set-ItemProperty -Path $runPath -Name $script:AutoStartKey -Value (Get-AutoStartCommand) -Type String
        Write-Output '已添加开机自启。'
    } else {
        Remove-ItemProperty -Path $runPath -Name $script:AutoStartKey -ErrorAction SilentlyContinue
        Write-Output '已移除开机自启。'
    }
}

function Invoke-Exit {
    try { if ($script:Notify) { $script:Notify.Visible = $false; $script:Notify.Dispose() } } catch { }
    try { if ($script:HotkeyWin) { $script:HotkeyWin.UnregisterHotkey($script:HK_ID_REGION); $script:HotkeyWin.Shutdown() } } catch { }
    try { [System.Windows.Forms.Application]::Exit() } catch { }
}

function Start-Assistant {
    param([switch]$GuiSmoke)

    # 单实例保护：已有实例则静默退出
    if (-not $GuiSmoke) {
        try {
            $cut = (Get-Date).AddSeconds(-2)
            $dup = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like '*ImgOcrAssistant.ps1*' -and $_.CommandLine -notlike '*-Command*' -and $_.ProcessId -ne $PID -and $_.CreationDate -lt $cut })
            if ($dup.Count -gt 0) { return }
        } catch { }
    }

    [void][ImgOcrNative.Dpi]::MakeAware()
    $initOk = Initialize-OcrEnvironment
    if (-not $initOk) {
        Write-Warning '系统 OCR 初始化失败（缺少识别语言）。'
    }

    $script:Busy = $false

    # 热键：Alt + R
    $script:HotkeyWin = New-Object ImgOcrNative.HotkeyWindow
    $ok = $script:HotkeyWin.RegisterHotkey($script:HK_ID_REGION, [uint32]$script:HK_MODS, [uint32]$script:HK_VK_REGION)
    if (-not $ok) { Write-Warning 'Alt+R 注册失败（可能被其他程序占用），仍可用托盘菜单触发。' }
    $script:HotkeyWin.add_HotKeyPressed({
        param($s, $e)
        Invoke-RegionOcr
    })

    Build-TrayUi

    # 冒烟：2.5 秒后自动退出
    if ($GuiSmoke) {
        $smokeTimer = New-Object System.Windows.Forms.Timer
        $smokeTimer.Interval = 2500
        $smokeTimer.add_Tick({ $smokeTimer.Stop(); Invoke-Exit })
        $smokeTimer.Start()
    }

    try { [System.Windows.Forms.Application]::Run() }
    catch { Write-Output ('GUISMOKE-CRASH ' + $_.Exception.ToString()) }
    Invoke-Exit
    if ($GuiSmoke) { Write-Output 'GUISMOKE-OK' }
}

# =====================================================================
#  冒烟 / 自检
# =====================================================================
function Invoke-SmokeTest {
    Write-Output 'SMOKE-START'
    [void][ImgOcrNative.Dpi]::MakeAware()
    $ok = Initialize-OcrEnvironment
    Write-Output ('SMOKE ocr-init=' + $ok)
    $icon = New-TrayIcon
    if ($null -eq $icon) { throw 'SMOKE-FAIL icon' }
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = $icon; $notify.Text = 'smoke'; $notify.Visible = $false
    $notify.Dispose(); $icon.Dispose()
    Write-Output 'SMOKE notify-ok'
    $win = New-Object ImgOcrNative.HotkeyWindow
    if ($null -eq $win) { throw 'SMOKE-FAIL hotkey-window' }
    $a = $win.RegisterHotkey(1, 1, 0x52)
    Write-Output ('SMOKE hotkey-altR=' + $a)
    $win.UnregisterHotkey(1); $win.Shutdown()
    Write-Output 'SMOKE-OK'
}

function Invoke-OcrSelfTest {
    $ok = Initialize-OcrEnvironment
    if (-not $ok) { Write-Output 'SELFTEST ocr-init=FAIL'; return }
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('imgocr_st_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir 'sample.png'
    $bmp = $null; $g = $null
    try {
        $bmp = New-Object System.Drawing.Bitmap(860, 200)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $font = $null
        foreach ($name in @('Microsoft YaHei', 'Microsoft YaHei UI', 'SimSun', 'Arial')) {
            try { $font = New-Object System.Drawing.Font($name, 40, [System.Drawing.FontStyle]::Bold); break } catch { }
        }
        if ($null -eq $font) { throw '无法创建测试字体' }
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
        try {
            $g.DrawString('Hello OCR 12345', $font, $brush, 20, 20)
            $g.DrawString('简体中文识别测试', $font, $brush, 20, 100)
        } finally { $font.Dispose(); $brush.Dispose() }
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { if ($g) { $g.Dispose() }; if ($bmp) { $bmp.Dispose() } }
    try {
        $text = Invoke-OcrFile -Path $path
        Write-Output 'SELFTEST text>>>'; Write-Output $text; Write-Output 'SELFTEST text<<<'
        $checks = @()
        if ($text -match 'OCR') { $checks += 'ascii-OK' } else { $checks += 'ascii-FAIL' }
        if ($text -match '识别') { $checks += 'cn-OK' } else { $checks += 'cn-FAIL' }
        Write-Output ('SELFTEST checks=' + ($checks -join ' '))
    } catch { Write-Output ('SELFTEST ocr-error=' + $_.Exception.Message) }
    finally { try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
    Write-Output 'SELFTEST-DONE'
}

# =====================================================================
#  主入口
# =====================================================================
try {
    if ($InstallSelf) { Set-AutoStart -Enable $true; return }
    if ($UninstallSelf) { Set-AutoStart -Enable $false; return }
    Compile-NativeBridge
    if ($CheckOcr) {
        $ok = Initialize-OcrEnvironment
        Write-Output ('ocr-engine=' + $(if ($ok) { 'available' } else { 'UNAVAILABLE' }))
        return
    }
    if ($SelfTest) { Invoke-OcrSelfTest; return }
    if ($OverlayTest) {
        [void][ImgOcrNative.Dpi]::MakeAware()
        $b = [ImgOcrNative.ScreenCapture]::SelectRegion()
        Write-Output ('OVERLAY-RESULT=' + $(if ($null -ne $b) { 'bitmap' } else { 'cancelled' }))
        return
    }
    if ($SmokeTest) { Invoke-SmokeTest; return }
    Start-Assistant -GuiSmoke:$GuiSmoke
}
catch {
    Write-Output ('FATAL ' + $_.Exception.ToString())
    throw
}
