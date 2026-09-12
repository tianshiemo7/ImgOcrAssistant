<#
============================================================================
  屏幕OCR助手
    全局热键 Alt + R      ->  框选屏幕区域 -> 识别 -> 文字自动复制到剪贴板
    全局热键 Alt + R + S  ->  打开设置窗口（选择识别引擎 / 填 API Key / 改提示词）
----------------------------------------------------------------------------
  识别引擎（在设置窗口里切换，默认【本地】）：
    本地：Windows 10/11 内置 OCR，离线、免费、不上传，默认引擎。
    DeepSeek：把截图发到 DeepSeek 多模态接口（openai 兼容 /chat/completions），
              识别复杂排版 / 小字更准。需要自己填 API Key。
----------------------------------------------------------------------------
  依赖：Windows 10/11 + 系统自带 powershell.exe（Windows PowerShell 5.1）。
  配置：%APPDATA%\ImgOcrAssistant\config.json （可用环境变量 IMGO_CFG 改路径）
  参数：-CheckOcr / -SelfTest / -SmokeTest / -GuiSmoke / -OverlayTest
        -Settings / -ShowConfig / -ApiSelfTest / -ChordTest / -ChordTestLive
        -InstallSelf / -UninstallSelf
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
    [switch]$UninstallSelf,
    [switch]$Settings,
    [switch]$ShowConfig,
    [switch]$ApiSelfTest,
    [switch]$ChordTest,
    [switch]$ChordTestLive
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------- 配置 ----------
$script:AppName      = '屏幕OCR助手'
$script:AutoStartKey = 'ImgOcrAssistant'

# 热键：Alt + R 是“引导键”，单独按下 = 识别；再按 S = 设置（详见 KeyChord）
$script:MOD_ALT      = 1
$script:HK_MODS      = $script:MOD_ALT
$script:HK_ID_REGION = 1
$script:HK_VK_REGION = 0x52

# ---------- 运行时状态 ----------
$script:Busy        = $false
$script:Notify      = $null
$script:HotkeyWin   = $null
$script:Chord       = $null
$script:IconKeep    = $null
$script:OcrEngine   = $null
$script:Config      = $null
$script:UiFont      = $null
$script:UiScale     = 0
$script:Dlg         = $null
$script:DlgForm     = $null
$script:DlgTesting  = $false
$script:ApiJob      = $null
$script:ApiTimer    = $null
$script:CfgWatch    = $null
$script:CfgStamp    = $null

# =====================================================================
#  配置：默认值 / 读写
# =====================================================================
function Get-DefaultPrompt {
    return @'
你是 OCR 文字提取工具：从图片中提取全部可见文字。
必须严格遵守以下规则：
1. 只输出提取到的文字本身，不要任何解释、说明、前言、总结、寒暄或“以下是”之类的话。
2. 不要使用 Markdown 格式：不要出现 #、*、**、`、```、>、[]( )、| 表格等标记。
3. 严格保留原文的换行与段落结构：该换行就换行，不要把多行合并成一行，也不要自行拆分。
4. 不要翻译、不要改写、不要纠错、不要补全、不要增删标点；保持原文语言、大小写与数字。
5. 按原文阅读顺序输出（多栏排版按栏依次输出）。
6. 辨认不清的字用「□」占位。
7. 如果图片里没有任何文字，只输出：（无文字）
'@
}

function New-DefaultConfig {
    return [ordered]@{
        version  = 1
        engine   = 'local'          # local | deepseek
        prompt   = (Get-DefaultPrompt)
        deepseek = [ordered]@{
            apiKey      = ''
            baseUrl     = 'https://api.deepseek.com'
            model       = 'deepseek-flash'
            detail      = 'original'   # original | high | low | auto
            maxSide     = 1920         # 上传前把图片最长边压到该像素数，0 = 不压缩
            temperature = 0
            timeoutSec  = 60
        }
    }
}

function Get-ConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($env:IMGO_CFG)) { return $env:IMGO_CFG }
    $dir = Join-Path $env:APPDATA 'ImgOcrAssistant'
    return (Join-Path $dir 'config.json')
}

function Import-Config {
    $cfg = New-DefaultConfig
    $path = Get-ConfigPath
    if (Test-Path -LiteralPath $path) {
        try {
            $j = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($j.engine) { $cfg['engine'] = [string]$j.engine }
            if ($j.prompt) { $cfg['prompt'] = [string]$j.prompt }
            if ($null -ne $j.deepseek) {
                foreach ($k in @('apiKey', 'baseUrl', 'model', 'detail')) {
                    $v = $j.deepseek.$k
                    if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { $cfg['deepseek'][$k] = [string]$v }
                }
                foreach ($k in @('maxSide', 'temperature', 'timeoutSec')) {
                    $v = $j.deepseek.$k
                    if ($null -ne $v) { $cfg['deepseek'][$k] = $v }
                }
            }
        }
        catch { Write-Warning ('配置文件读取失败，改用默认配置：' + $_.Exception.Message) }
    }
    if ([string]::IsNullOrWhiteSpace([string]$cfg['prompt'])) { $cfg['prompt'] = Get-DefaultPrompt }
    if ($cfg['engine'] -ne 'deepseek') { $cfg['engine'] = 'local' }
    return $cfg
}

function Export-Config {
    param($Config)
    $path = Get-ConfigPath
    $dir = Split-Path -Parent $path
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = $Config | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    $script:CfgStamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc
    return $path
}

# 引擎判定：deepseek 需要 API Key，否则退回本地
function Resolve-Engine {
    if ($script:Config['engine'] -ne 'deepseek') { return 'local' }
    if ([string]::IsNullOrWhiteSpace([string]$script:Config['deepseek']['apiKey'])) { return 'local-noauth' }
    return 'deepseek'
}

# =====================================================================
#  原生桥接 C#（热键窗口 + Alt+R(+S) 引导键 + 屏幕框选 + DPI）
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

    /// <summary>
    /// “引导键”热键：按住 Alt，按 R，再按 S -> 设置；按住 Alt，按 R，松开 Alt -> 识别。
    /// 用低级键盘钩子实现，因为 RegisterHotKey 无法表达三键组合。
    /// </summary>
    public sealed class KeyChord : IDisposable
    {
        private const int WH_KEYBOARD_LL = 13;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WM_KEYUP = 0x0101;
        private const int WM_SYSKEYUP = 0x0105;

        private const int VK_MENU = 0x12;
        private const int VK_LMENU = 0xA4;
        private const int VK_RMENU = 0xA5;
        private const int VK_R = 0x52;
        private const int VK_S = 0x53;

        private const uint LLKHF_INJECTED = 0x00000010;
        private const uint KEYEVENTF_KEYUP = 0x0002;

        [StructLayout(LayoutKind.Sequential)]
        private struct KBDLLHOOKSTRUCT
        {
            public uint vkCode;
            public uint scanCode;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);
        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);
        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
        [DllImport("kernel32.dll")]
        private static extern uint GetTickCount();

        public event EventHandler OcrRequested;
        public event EventHandler SettingsRequested;

        /// <summary>引导键最长存活时间：超过则丢弃，避免漏掉 Alt 抬起后一直“待命”。</summary>
        public int ArmedTimeoutMs = 8000;

        private IntPtr _hook = IntPtr.Zero;
        private LowLevelKeyboardProc _proc;
        private bool _altDown;
        private bool _armed;
        private uint _armedTick;

        public bool IsInstalled { get { return _hook != IntPtr.Zero; } }

        public bool Install()
        {
            if (_hook != IntPtr.Zero) return true;
            try
            {
                _proc = new LowLevelKeyboardProc(HookProc);
                IntPtr hMod = GetModuleHandle(null);
                _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, hMod, 0);
                return _hook != IntPtr.Zero;
            }
            catch { return false; }
        }

        public void Uninstall()
        {
            if (_hook != IntPtr.Zero)
            {
                try { UnhookWindowsHookEx(_hook); } catch { }
                _hook = IntPtr.Zero;
            }
            _proc = null;
            _armed = false;
            _altDown = false;
        }

        public void Dispose() { Uninstall(); }

        private static bool IsAltKey(int vk) { return vk == VK_MENU || vk == VK_LMENU || vk == VK_RMENU; }

        private static bool AltDownNow()
        {
            return (GetAsyncKeyState(VK_MENU) & 0x8000) != 0
                || (GetAsyncKeyState(VK_LMENU) & 0x8000) != 0
                || (GetAsyncKeyState(VK_RMENU) & 0x8000) != 0;
        }

        private IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
        {
            try
            {
                if (nCode >= 0)
                {
                    int msg = wParam.ToInt32();
                    KBDLLHOOKSTRUCT data = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                    int vk = (int)data.vkCode;
                    if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) OnKeyDown(vk);
                    else if (msg == WM_KEYUP || msg == WM_SYSKEYUP) OnKeyUp(vk);
                }
            }
            catch { }
            return CallNextHookEx(_hook, nCode, wParam, lParam);
        }

        private void OnKeyDown(int vk)
        {
            if (_armed && (GetTickCount() - _armedTick) > (uint)ArmedTimeoutMs) { _armed = false; }

            if (IsAltKey(vk)) { _altDown = true; return; }

            if (vk == VK_R && (_altDown || AltDownNow()))
            {
                _armed = true;
                _armedTick = GetTickCount();
                return;
            }

            if (vk == VK_S && _armed)
            {
                _armed = false;
                Raise(SettingsRequested);
                return;
            }

            // 引导键之后按了别的键：这不再是 Alt+R(+S)，直接放弃，避免误触发识别
            if (_armed) { _armed = false; }
        }

        private void OnKeyUp(int vk)
        {
            if (IsAltKey(vk))
            {
                _altDown = false;
                if (_armed)
                {
                    _armed = false;
                    Raise(OcrRequested);
                }
                return;
            }
        }

        private void Raise(EventHandler handler)
        {
            if (handler == null) return;
            try { handler(this, EventArgs.Empty); }
            catch { }
        }

        // ---------------- 自检辅助（不走真实键盘） ----------------
        public bool ArmedForTest { get { return _armed; } }

        public void SimulateKey(int vk, bool isDown)
        {
            if (isDown) OnKeyDown(vk); else OnKeyUp(vk);
        }

        public static void SendKey(int vk, bool isDown)
        {
            keybd_event((byte)vk, 0, isDown ? 0u : KEYEVENTF_KEYUP, UIntPtr.Zero);
        }

        public static int VkAlt { get { return VK_MENU; } }
        public static int VkR { get { return VK_R; } }
        public static int VkS { get { return VK_S; } }
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
#  本地 OCR（Windows.Media.Ocr）
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

# 清洗 OCR 文本：只合并“同一行内”的中文之间的多余空格，绝不跨越换行
function Format-OcrText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $cjk = '\u2E80-\u9FFF\uF900-\uFAFF\uFF00-\uFFEF'
    $t1 = [regex]::Replace($Text, '(?<=[' + $cjk + '])[^\S\r\n]+(?=[' + $cjk + '])', '')
    $t2 = [regex]::Replace($t1, '[^\S\r\n]*([\u3000-\u303F\uFF01-\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF65])[^\S\r\n]*', '$1')
    $t3 = [regex]::Replace($t2, '\r\n|\r', "`n")
    $t3 = [regex]::Replace($t3, '[ \t]+(?=\n)', '')
    $t3 = [regex]::Replace($t3, '\n{3,}', "`n`n")
    return $t3.Trim()
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
    param([System.Drawing.Image]$Image, [string]$Path, [int]$MaxSide = 0)
    $srcW = $Image.Width; $srcH = $Image.Height
    $scale = 1.0
    if ($MaxSide -gt 0) {
        $longest = [Math]::Max($srcW, $srcH)
        if ($longest -gt $MaxSide) { $scale = [double]$MaxSide / [double]$longest }
    }
    $outW = [int][Math]::Max(1, [Math]::Round($srcW * $scale))
    $outH = [int][Math]::Max(1, [Math]::Round($srcH * $scale))
    $temp = $null
    $target = $Image
    if ($scale -ne 1.0 -or $Image -isnot [System.Drawing.Bitmap]) {
        $temp = New-Object System.Drawing.Bitmap($outW, $outH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($temp)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.DrawImage($Image, (New-Object System.Drawing.Rectangle(0, 0, $outW, $outH)))
        } finally { $g.Dispose() }
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
#  DeepSeek 多模态接口（OpenAI 兼容 /chat/completions + image_url）
#  说明：这段脚本块是「自包含」的，既能直接同步调用，也能丢进 Start-Job 后台跑。
# =====================================================================
$script:DsVisionCall = {
    param(
        [string]$ImagePath,
        [string]$ApiKey,
        [string]$BaseUrl,
        [string]$Model,
        [string]$Prompt,
        [string]$Detail,
        [double]$Temperature,
        [int]$TimeoutSec
    )
    $res = @{ Ok = $false; Text = ''; Error = ''; ElapsedMs = 0; Model = $Model; Uri = ''; Status = 0 }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    try { [Net.ServicePointManager]::Expect100Continue = $false } catch { }
    try {
        if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw 'API Key 为空：请按 Alt+R+S 打开设置填入 API Key。' }
        if (-not (Test-Path -LiteralPath $ImagePath)) { throw ('找不到待识别图片：' + $ImagePath) }

        $base = $BaseUrl
        if ([string]::IsNullOrWhiteSpace($base)) { $base = 'https://api.deepseek.com' }
        $base = $base.Trim().TrimEnd('/')
        if ($base -match '/chat/completions$') { $uri = $base } else { $uri = $base + '/chat/completions' }
        $res.Uri = $uri

        $model = $Model
        if ([string]::IsNullOrWhiteSpace($model)) { $model = 'deepseek-flash' }
        $detail = $Detail
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'original' }
        $sys = $Prompt
        if ([string]::IsNullOrWhiteSpace($sys)) { $sys = '提取图片中的全部文字，只输出文字本身，不要使用 Markdown，保留原有换行。' }
        if ($TimeoutSec -le 0) { $TimeoutSec = 60 }

        $b64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ImagePath))
        $payload = [ordered]@{
            model       = $model
            messages    = @(
                [ordered]@{ role = 'system'; content = $sys },
                [ordered]@{ role = 'user'; content = @(
                        [ordered]@{ type = 'text'; text = '请提取这张图片中的全部文字。' },
                        [ordered]@{ type = 'image_url'; image_url = [ordered]@{ url = ('data:image/png;base64,' + $b64); detail = $detail } }
                    )
                }
            )
            temperature = $Temperature
            stream      = $false
        }
        $json = $payload | ConvertTo-Json -Depth 12 -Compress
        $body = [System.Text.Encoding]::UTF8.GetBytes($json)

        # 直接用 HttpWebRequest：PowerShell 5.1 的 Invoke-RestMethod 在响应头没带 charset
        # 时会把 UTF-8 正文按 Latin-1 解码，中文会变乱码；这里自己读字节并强制 UTF-8。
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 0
        $respText = ''
        try {
            $req = [System.Net.HttpWebRequest]::Create($uri)
            $req.Method = 'POST'
            $req.ContentType = 'application/json; charset=utf-8'
            $req.Accept = 'application/json'
            $req.UserAgent = 'ImgOcrAssistant/2.0'
            $req.Headers.Add('Authorization', 'Bearer ' + $ApiKey)
            $req.Timeout = $TimeoutSec * 1000
            $req.ReadWriteTimeout = $TimeoutSec * 1000
            try { $req.ServicePoint.Expect100Continue = $false } catch { }
            $rs = $req.GetRequestStream()
            try { $rs.Write($body, 0, $body.Length) } finally { $rs.Close() }
            $resp = $req.GetResponse()
            try {
                $status = [int]$resp.StatusCode
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                try { $respText = $sr.ReadToEnd() } finally { $sr.Close() }
            } finally { $resp.Close() }
        }
        catch [System.Net.WebException] {
            $we = $_.Exception
            if ($null -ne $we.Response) {
                try {
                    $status = [int]$we.Response.StatusCode
                    $sr = New-Object System.IO.StreamReader($we.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
                    try { $respText = $sr.ReadToEnd() } finally { $sr.Close() }
                } catch { }
                try { $we.Response.Close() } catch { }
            }
            if ([string]::IsNullOrWhiteSpace($respText)) { throw }
        }
        $sw.Stop()
        $res.ElapsedMs = [int]$sw.ElapsedMilliseconds
        $res.Status = $status

        if ($status -lt 200 -or $status -ge 300) { throw ('接口返回 HTTP ' + $status + '：' + $respText) }
        if ([string]::IsNullOrWhiteSpace($respText)) { throw ('接口返回空响应（HTTP ' + $status + '）。') }
        $jsonObj = $respText | ConvertFrom-Json

        $content = ''
        try {
            $c = $jsonObj.choices[0].message.content
            if ($c -is [string]) { $content = $c }
            elseif ($null -ne $c) { foreach ($blk in $c) { if ($null -ne $blk.text) { $content += [string]$blk.text } } }
        } catch { }
        if ([string]::IsNullOrWhiteSpace($content)) {
            throw ('接口返回内容为空。原始响应：' + $respText)
        }
        $res.Text = $content
        $res.Ok = $true
    }
    catch {
        $msg = $_.Exception.Message
        try { if ($null -ne $_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $msg + ' | ' + [string]$_.ErrorDetails.Message } } catch { }
        $res.Error = $msg
    }
    return $res
}

# =====================================================================
#  后台任务：调用接口时不让消息循环卡住（热键钩子才不会丢）
# =====================================================================
function Start-ApiJob {
    param(
        [string]$ImagePath,
        [string]$TempFile,
        [int]$HardTimeoutSec,
        [scriptblock]$OnDone
    )
    if ($null -ne $script:ApiJob) { return $false }
    $cfg = $script:Config['deepseek']
    if ($HardTimeoutSec -le 0) { $HardTimeoutSec = 90 }
    try {
        $job = Start-Job -ScriptBlock $script:DsVisionCall -ArgumentList `
            $ImagePath, ([string]$cfg['apiKey']), ([string]$cfg['baseUrl']), ([string]$cfg['model']), `
            ([string]$script:Config['prompt']), ([string]$cfg['detail']), ([double]$cfg['temperature']), ([int]$cfg['timeoutSec'])
    }
    catch { return $false }
    $script:ApiJob = @{ Job = $job; TempFile = $TempFile; OnDone = $OnDone; Start = (Get-Date); Hard = $HardTimeoutSec }
    if ($null -eq $script:ApiTimer) {
        $script:ApiTimer = New-Object System.Windows.Forms.Timer
        $script:ApiTimer.Interval = 200
        $script:ApiTimer.add_Tick({ Update-ApiJob })
    }
    $script:ApiTimer.Start()
    return $true
}

function Update-ApiJob {
    $a = $script:ApiJob
    if ($null -eq $a) { try { $script:ApiTimer.Stop() } catch { } ; return }
    $job = $a['Job']
    $finished = $true
    $timedOut = $false
    try {
        if ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
            $finished = $false
            if (((Get-Date) - $a['Start']).TotalSeconds -gt $a['Hard']) { $finished = $true; $timedOut = $true }
        }
    } catch { $finished = $true }

    if (-not $finished) { return }
    try { $script:ApiTimer.Stop() } catch { }

    $res = $null
    if ($timedOut) {
        try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { }
        $res = @{ Ok = $false; Text = ''; Error = ('请求超时（超过 ' + $a['Hard'] + ' 秒）'); ElapsedMs = 0 }
    } else {
        try {
            foreach ($o in @(Receive-Job -Job $job -ErrorAction SilentlyContinue)) {
                if ($o -is [System.Collections.IDictionary]) { $res = $o }
            }
        } catch { }
        if ($null -eq $res) {
            $err = ''
            try { $err = (($job.ChildJobs[0].JobStateInfo.Reason | Out-String).Trim()) } catch { }
            $res = @{ Ok = $false; Text = ''; Error = ('后台任务没有返回结果。' + $err); ElapsedMs = 0 }
        }
    }
    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
    if (-not [string]::IsNullOrEmpty($a['TempFile'])) {
        try { if (Test-Path -LiteralPath $a['TempFile']) { Remove-Item -LiteralPath $a['TempFile'] -Force -ErrorAction SilentlyContinue } } catch { }
    }
    $cb = $a['OnDone']
    $script:ApiJob = $null
    if ($null -ne $cb) { try { & $cb $res } catch { } }
}

# 生成一张带文字的测试图，用于「接口是否真的能识图」的自检
function New-TestImagePng {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('imgocr_probe_' + [guid]::NewGuid().ToString('N') + '.png')
    $bmp = New-Object System.Drawing.Bitmap(560, 140)
    # 固定 96 DPI：进程 DPI-aware 时 Bitmap 会继承显示器 DPI（200% 屏上 34pt 文字会渲染到 788px 宽），
    # 结果文字被裁掉，模型只能读到前几个字符。
    try { $bmp.SetResolution(96, 96) } catch { }
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::White)
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $font = New-Object System.Drawing.Font('Arial', 34, [System.Drawing.FontStyle]::Bold)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
        try { $g.DrawString('OCR TEST 12345', $font, $brush, 18, 20) } finally { $font.Dispose(); $brush.Dispose() }
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $g.Dispose(); $bmp.Dispose() }
    return $path
}

function Start-ConfigProbe {
    param([scriptblock]$OnDone)
    $img = New-TestImagePng
    $hard = [int]$script:Config['deepseek']['timeoutSec'] + 30
    $ok = Start-ApiJob -ImagePath $img -TempFile $img -HardTimeoutSec $hard -OnDone $OnDone
    if (-not $ok) { try { Remove-Item -LiteralPath $img -Force -ErrorAction SilentlyContinue } catch { } }
    return $ok
}

# =====================================================================
#  托盘 / 提示 / 结果投递
# =====================================================================
function Get-UiFont {
    if ($null -ne $script:UiFont) { return $script:UiFont }
    try { $script:UiFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9) }
    catch { $script:UiFont = [System.Drawing.SystemFonts]::MessageBoxFont }
    return $script:UiFont
}

# 界面缩放系数 = 显示器 DPI / 96。
# 字体是按“点”算的，会自动跟着 DPI 放大，但控件的像素坐标不会 —— 所以在 200% 缩放的
# 屏幕上，写死 96 DPI 坐标的窗口会把每一行文字都截断。这里把所有坐标/尺寸统一乘上系数。
function Get-UiScale {
    if ($script:UiScale -gt 0) { return $script:UiScale }
    $dpi = 96.0
    try {
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        try { $dpi = [double]$g.DpiX } finally { $g.Dispose() }
    } catch { }
    if ($dpi -le 0) { $dpi = 96.0 }
    $s = $dpi / 96.0
    # 兜底：屏幕太矮时不让窗口高过屏幕（否则底部按钮点不到）
    try {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $maxS = ($wa.Height - 40) / 640.0
        if ($maxS -lt 1.0) { $maxS = 1.0 }
        if ($s -gt $maxS) { $s = $maxS }
    } catch { }
    $script:UiScale = $s
    return $s
}

function New-ScaledPoint {
    param([double]$X, [double]$Y)
    $s = Get-UiScale
    return (New-Object System.Drawing.Point([int][Math]::Round($X * $s), [int][Math]::Round($Y * $s)))
}

function New-ScaledSize {
    param([double]$W, [double]$H)
    $s = Get-UiScale
    return (New-Object System.Drawing.Size([int][Math]::Round($W * $s), [int][Math]::Round($H * $s)))
}

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
    if ([string]::IsNullOrWhiteSpace($Text)) { $Text = ' ' }
    if ($Text.Length -gt 250) { $Text = $Text.Substring(0, 250) + '...' }
    try {
        $script:Notify.BalloonTipTitle = $Title
        $script:Notify.BalloonTipText  = $Text
        $script:Notify.BalloonTipIcon  = $Icon
        $script:Notify.ShowBalloonTip(4000)
    } catch { }
}

function Update-TrayText {
    param([string]$Override)
    if ($null -eq $script:Notify) { return }
    $text = $Override
    if ([string]::IsNullOrWhiteSpace($text)) {
        switch (Resolve-Engine) {
            'deepseek'     { $label = 'DeepSeek' }
            'local-noauth' { $label = '本地·未配置Key' }
            default        { $label = '本地' }
        }
        $text = '屏幕OCR助手［' + $label + '］Alt+R 识别 · Alt+R+S 设置'
    }
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    try { $script:Notify.Text = $text } catch { }
}

function Publish-OcrText {
    param([string]$Text, [string]$Suffix = '')
    if ([string]::IsNullOrWhiteSpace($Text)) {
        Show-NotifyBalloon '未识别到文字' '所选区域没有可识别的文字，或文字太小 / 太模糊。' 'Warning'
        return $false
    }
    $copied = $false
    try { [System.Windows.Forms.Clipboard]::SetText($Text); $copied = $true } catch { }
    $sn = ($Text -replace '\s+', ' ').Trim()
    if ($sn.Length -gt 26) { $sn = $sn.Substring(0, 26) + '...' }
    $title = $(if ($copied) { '已复制' } else { '识别完成（剪贴板写入失败）' })
    Show-NotifyBalloon $title ('识别文字已复制到剪贴板' + $Suffix + '：' + $sn) $(if ($copied) { 'Info' } else { 'Warning' })
    return $copied
}

# 框选 -> 识别 -> 复制
function Invoke-RegionOcr {
    if ($script:Busy) {
        Show-NotifyBalloon '正在识别中' '上一次识别还没结束，请稍候再按 Alt+R。' 'Info'
        return
    }
    $script:Busy = $true
    $handedOff = $false
    $bmp = $null
    try {
        $bmp = [ImgOcrNative.ScreenCapture]::SelectRegion()
        if ($null -eq $bmp) { return }

        $engine = Resolve-Engine
        if ($engine -eq 'local-noauth') {
            Show-NotifyBalloon '未配置 API Key' '当前引擎是 DeepSeek 但还没有 API Key，已回退为本地识别。按 Alt+R+S 可填入 Key。' 'Warning'
            $engine = 'local'
        }

        if ($engine -eq 'deepseek') {
            $png = Join-Path ([System.IO.Path]::GetTempPath()) ('imgocr_ds_' + [guid]::NewGuid().ToString('N') + '.png')
            Save-ImageToPngFile -Image $bmp -Path $png -MaxSide ([int]$script:Config['deepseek']['maxSide'])
            $bmp.Dispose(); $bmp = $null
            Update-TrayText -Override '屏幕OCR助手：正在用 DeepSeek 识别…'
            Show-NotifyBalloon '正在识别' '已把截图发送到 DeepSeek 接口，请稍候…' 'Info'
            $handedOff = Start-ApiJob -ImagePath $png -TempFile $png `
                -HardTimeoutSec ([int]$script:Config['deepseek']['timeoutSec'] + 30) `
                -OnDone { param($r) Complete-ApiOcr -Result $r }
            if (-not $handedOff) {
                try { Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue } catch { }
                Show-NotifyBalloon '无法启动识别任务' '后台任务占用中（可能正在测试接口），请稍后再试。' 'Warning'
            }
            return
        }

        $text = ''
        try { $text = Invoke-OcrImage -Image $bmp } catch { Show-NotifyBalloon '本地识别出错' $_.Exception.Message 'Error'; return }
        [void](Publish-OcrText -Text $text -Suffix '（本地）')
    }
    catch { Show-NotifyBalloon '识别出错' $_.Exception.Message 'Error' }
    finally {
        if ($null -ne $bmp) { $bmp.Dispose() }
        if (-not $handedOff) { $script:Busy = $false; Update-TrayText }
    }
}

function Complete-ApiOcr {
    param($Result)
    try {
        if ($null -eq $Result) { Show-NotifyBalloon 'DeepSeek 识别失败' '后台任务异常结束。' 'Error'; return }
        if (-not $Result['Ok']) {
            Show-NotifyBalloon 'DeepSeek 识别失败' ([string]$Result['Error']) 'Error'
            return
        }
        $text = Format-OcrText -Text ([string]$Result['Text'])
        $ms = [int]$Result['ElapsedMs']
        $suffix = '（DeepSeek'
        if ($ms -gt 0) { $suffix = $suffix + ' ' + [Math]::Round($ms / 1000.0, 1) + 's' }
        $suffix = $suffix + '）'
        [void](Publish-OcrText -Text $text -Suffix $suffix)
    }
    finally {
        $script:Busy = $false
        Update-TrayText
    }
}

# =====================================================================
#  设置窗口（Alt+R+S）
# =====================================================================
function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 0, [switch]$Bold)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = (New-ScaledPoint $X $Y)
    if ($W -gt 0) { $l.Size = (New-ScaledSize $W 20) } else { $l.AutoSize = $true }
    if ($Bold) { $l.Font = New-Object System.Drawing.Font((Get-UiFont).FontFamily, 9.5, [System.Drawing.FontStyle]::Bold) }
    return $l
}

function Update-SettingsUi {
    $d = $script:Dlg
    if ($null -eq $d) { return }
    $api = $d['rbApi'].Checked
    foreach ($k in @('txtBase', 'txtModel', 'cboDetail', 'txtKey', 'chkShow', 'numMaxSide', 'numTimeout', 'lnkKey')) {
        if ($null -ne $d[$k]) { $d[$k].Enabled = $api }
    }
    $d['txtPrompt'].Enabled = $api
    $d['btnResetPrompt'].Enabled = $api
    $d['btnTest'].Enabled = ($api -and -not $script:DlgTesting)
    if ($api) {
        $d['lblEngineHint'].Text = 'DeepSeek 引擎：截图会通过所填接口上传识别（需联网 + API Key）。'
    } else {
        $d['lblEngineHint'].Text = '本地引擎：用 Windows 内置 OCR，全程离线、不联网、不花额度。'
    }
}

function Set-SettingsStatus {
    param([string]$Text)
    $d = $script:Dlg
    if ($null -eq $d) { return }
    try { $d['lblStatus'].Text = $Text } catch { }
    try { $d['lblStatus'].Refresh() } catch { }
}

function Show-SettingsWindow {
    if ($null -ne $script:DlgForm -and -not $script:DlgForm.IsDisposed) {
        try {
            if ($script:DlgForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
                $script:DlgForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            }
            $script:DlgForm.Show()
            $script:DlgForm.Activate()
            $script:DlgForm.BringToFront()
        } catch { }
        return
    }

    $cfg = $script:Config
    $ds = $cfg['deepseek']
    $d = @{}
    $font = Get-UiFont

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '屏幕OCR助手 · 设置'
    $form.ClientSize = (New-ScaledSize 624 640)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.Font = $font
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.TopMost = $true
    $d['Form'] = $form

    [void]$form.Controls.Add((New-Label '识别引擎（截图默认走本地，可切换为接口）' 16 12 560 -Bold))

    $rbLocal = New-Object System.Windows.Forms.RadioButton
    $rbLocal.Text = '本地识别（Windows 内置 OCR）— 离线、免费、不上传【默认】'
    $rbLocal.Location = (New-ScaledPoint 20 38)
    $rbLocal.AutoSize = $true
    $d['rbLocal'] = $rbLocal

    $rbApi = New-Object System.Windows.Forms.RadioButton
    $rbApi.Text = 'DeepSeek 接口识别 — 上传截图，复杂排版 / 小字更准（需 API Key）'
    $rbApi.Location = (New-ScaledPoint 20 62)
    $rbApi.AutoSize = $true
    $d['rbApi'] = $rbApi

    $lblEngineHint = New-Object System.Windows.Forms.Label
    $lblEngineHint.Location = (New-ScaledPoint 40 86)
    $lblEngineHint.AutoSize = $true
    $lblEngineHint.ForeColor = [System.Drawing.Color]::DimGray
    $d['lblEngineHint'] = $lblEngineHint

    [void]$form.Controls.Add($rbLocal)
    [void]$form.Controls.Add($rbApi)
    [void]$form.Controls.Add($lblEngineHint)

    # ---- DeepSeek 接口 ----
    $gbApi = New-Object System.Windows.Forms.GroupBox
    $gbApi.Text = 'DeepSeek 接口设置'
    $gbApi.Location = (New-ScaledPoint 12 110)
    $gbApi.Size = (New-ScaledSize 600 246)
    [void]$form.Controls.Add($gbApi)

    [void]$gbApi.Controls.Add((New-Label '接口地址' 14 30))
    $txtBase = New-Object System.Windows.Forms.TextBox
    $txtBase.Location = (New-ScaledPoint 130 27)
    $txtBase.Size = (New-ScaledSize 450 23)
    $txtBase.Text = [string]$ds['baseUrl']
    $d['txtBase'] = $txtBase
    [void]$gbApi.Controls.Add($txtBase)

    [void]$gbApi.Controls.Add((New-Label '模型' 14 60))
    $txtModel = New-Object System.Windows.Forms.TextBox
    $txtModel.Location = (New-ScaledPoint 130 57)
    $txtModel.Size = (New-ScaledSize 190 23)
    $txtModel.Text = [string]$ds['model']
    $d['txtModel'] = $txtModel
    [void]$gbApi.Controls.Add($txtModel)

    [void]$gbApi.Controls.Add((New-Label '图片细节' 336 60))
    $cboDetail = New-Object System.Windows.Forms.ComboBox
    $cboDetail.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cboDetail.Location = (New-ScaledPoint 405 57)
    $cboDetail.Size = (New-ScaledSize 175 23)
    [void]$cboDetail.Items.AddRange(@('original', 'high', 'low', 'auto'))
    $cboDetail.SelectedItem = [string]$ds['detail']
    if ($null -eq $cboDetail.SelectedItem) { $cboDetail.SelectedIndex = 0 }
    $d['cboDetail'] = $cboDetail
    [void]$gbApi.Controls.Add($cboDetail)

    [void]$gbApi.Controls.Add((New-Label 'API Key' 14 90))
    $txtKey = New-Object System.Windows.Forms.TextBox
    $txtKey.Location = (New-ScaledPoint 130 87)
    $txtKey.Size = (New-ScaledSize 310 23)
    $txtKey.Text = [string]$ds['apiKey']
    $txtKey.UseSystemPasswordChar = $true
    $d['txtKey'] = $txtKey
    [void]$gbApi.Controls.Add($txtKey)

    $chkShow = New-Object System.Windows.Forms.CheckBox
    $chkShow.Text = '显示'
    $chkShow.Location = (New-ScaledPoint 452 89)
    $chkShow.AutoSize = $true
    $d['chkShow'] = $chkShow
    [void]$gbApi.Controls.Add($chkShow)

    [void]$gbApi.Controls.Add((New-Label '图片最长边' 14 120))
    $numMaxSide = New-Object System.Windows.Forms.NumericUpDown
    $numMaxSide.Location = (New-ScaledPoint 130 117)
    $numMaxSide.Size = (New-ScaledSize 80 23)
    $numMaxSide.Minimum = 0
    $numMaxSide.Maximum = 8192
    $numMaxSide.Value = [decimal][Math]::Max(0, [Math]::Min(8192, [int]$ds['maxSide']))
    $d['numMaxSide'] = $numMaxSide
    [void]$gbApi.Controls.Add($numMaxSide)
    [void]$gbApi.Controls.Add((New-Label '像素（0 = 不压缩；超出会等比缩小后再上传）' 218 120))

    [void]$gbApi.Controls.Add((New-Label '超时' 14 150))
    $numTimeout = New-Object System.Windows.Forms.NumericUpDown
    $numTimeout.Location = (New-ScaledPoint 130 147)
    $numTimeout.Size = (New-ScaledSize 80 23)
    $numTimeout.Minimum = 5
    $numTimeout.Maximum = 300
    $numTimeout.Value = [decimal][Math]::Max(5, [Math]::Min(300, [int]$ds['timeoutSec']))
    $d['numTimeout'] = $numTimeout
    [void]$gbApi.Controls.Add($numTimeout)
    [void]$gbApi.Controls.Add((New-Label '秒（单次请求）' 218 150))

    $lnkKey = New-Object System.Windows.Forms.LinkLabel
    $lnkKey.Text = '→ 还没有 Key？点这里打开 DeepSeek 开放平台申请'
    $lnkKey.Location = (New-ScaledPoint 130 180)
    $lnkKey.AutoSize = $true
    $d['lnkKey'] = $lnkKey
    [void]$gbApi.Controls.Add($lnkKey)

    [void]$gbApi.Controls.Add((New-Label 'Key 只保存在本机配置文件里，不会发给除上面接口地址以外的任何地方。' 14 208))

    # ---- 提示词 ----
    $gbPrompt = New-Object System.Windows.Forms.GroupBox
    $gbPrompt.Text = '上下文提示词（写给模型的要求；仅接口引擎生效，可自行修改）'
    $gbPrompt.Location = (New-ScaledPoint 12 364)
    $gbPrompt.Size = (New-ScaledSize 600 186)
    [void]$form.Controls.Add($gbPrompt)

    $txtPrompt = New-Object System.Windows.Forms.TextBox
    $txtPrompt.Location = (New-ScaledPoint 14 22)
    $txtPrompt.Size = (New-ScaledSize 572 116)
    $txtPrompt.Multiline = $true
    $txtPrompt.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $txtPrompt.AcceptsReturn = $true
    $txtPrompt.WordWrap = $true
    $txtPrompt.Text = [string]$cfg['prompt']
    $d['txtPrompt'] = $txtPrompt
    [void]$gbPrompt.Controls.Add($txtPrompt)

    $btnResetPrompt = New-Object System.Windows.Forms.Button
    $btnResetPrompt.Text = '恢复默认提示词'
    $btnResetPrompt.Location = (New-ScaledPoint 14 146)
    $btnResetPrompt.Size = (New-ScaledSize 120 28)
    $d['btnResetPrompt'] = $btnResetPrompt
    [void]$gbPrompt.Controls.Add($btnResetPrompt)
    [void]$gbPrompt.Controls.Add((New-Label '默认要求：只输出文字、不用 Markdown、保留换行、不翻译不改写。' 146 152))

    # ---- 底部 ----
    # 状态栏独占一整行，否则识别结果会被挤在按钮旁边截断
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = (New-ScaledPoint 16 556)
    $lblStatus.Size = (New-ScaledSize 596 20)
    $lblStatus.AutoEllipsis = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $d['lblStatus'] = $lblStatus
    [void]$form.Controls.Add($lblStatus)

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = '测试接口'
    $btnTest.Location = (New-ScaledPoint 302 584)
    $btnTest.Size = (New-ScaledSize 100 32)
    $d['btnTest'] = $btnTest
    [void]$form.Controls.Add($btnTest)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = '保存并关闭'
    $btnSave.Location = (New-ScaledPoint 408 584)
    $btnSave.Size = (New-ScaledSize 110 32)
    $d['btnSave'] = $btnSave
    [void]$form.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = (New-ScaledPoint 524 584)
    $btnCancel.Size = (New-ScaledSize 88 32)
    $d['btnCancel'] = $btnCancel
    [void]$form.Controls.Add($btnCancel)

    # ---- 事件 ----
    $form.AcceptButton = $btnSave
    $form.CancelButton = $btnCancel

    $rbLocal.add_CheckedChanged({ Update-SettingsUi })
    $rbApi.add_CheckedChanged({ Update-SettingsUi })
    $chkShow.add_CheckedChanged({
        $d = $script:Dlg
        if ($null -ne $d) { $d['txtKey'].UseSystemPasswordChar = -not $d['chkShow'].Checked }
    })
    $lnkKey.add_LinkClicked({
        try { Start-Process 'https://platform.deepseek.com/api_keys' } catch { }
    })
    $btnResetPrompt.add_Click({
        $d = $script:Dlg
        if ($null -ne $d) { $d['txtPrompt'].Text = Get-DefaultPrompt }
    })
    $btnCancel.add_Click({ $script:DlgForm.Close() })

    $btnTest.add_Click({
        $d = $script:Dlg
        if ($null -eq $d) { return }
        $probeCfg = Read-SettingsForm -Silent
        if ($null -eq $probeCfg) { return }
        $savedKey = $script:Config['deepseek']['apiKey']
        $savedBase = $script:Config['deepseek']['baseUrl']
        $savedModel = $script:Config['deepseek']['model']
        $script:Config['deepseek']['apiKey'] = $probeCfg['deepseek']['apiKey']
        $script:Config['deepseek']['baseUrl'] = $probeCfg['deepseek']['baseUrl']
        $script:Config['deepseek']['model'] = $probeCfg['deepseek']['model']
        $script:DlgTesting = $true
        Set-SettingsStatus '正在调用接口（会用一张测试图真跑一次识别）…'
        Update-SettingsUi
        $started = Start-ConfigProbe -OnDone {
            param($r)
            $script:DlgTesting = $false
            $d2 = $script:Dlg
            if ($null -ne $d2 -and -not $d2['Form'].IsDisposed) {
                if ($null -ne $r -and $r['Ok']) {
                    $t = (([string]$r['Text']) -replace '\s+', ' ').Trim()
                    if ($t.Length -gt 48) { $t = $t.Substring(0, 48) + '...' }
                    Set-SettingsStatus ('接口可用（' + [int]$r['ElapsedMs'] + ' ms）识别到：' + $t)
                } else {
                    $msg = '接口调用失败'
                    if ($null -ne $r -and $r['Error']) { $msg = '失败：' + [string]$r['Error'] }
                    Set-SettingsStatus $msg
                }
                Update-SettingsUi
            }
        }
        if (-not $started) {
            $script:DlgTesting = $false
            Set-SettingsStatus '已有任务在跑，请稍后再试。'
            Update-SettingsUi
        }
        $script:Config['deepseek']['apiKey'] = $savedKey
        $script:Config['deepseek']['baseUrl'] = $savedBase
        $script:Config['deepseek']['model'] = $savedModel
    })

    $btnSave.add_Click({ [void](Save-SettingsForm) })

    $txtKey.add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            [void](Save-SettingsForm)
        }
    })

    $script:Dlg = $d
    $script:DlgForm = $form

    if ($cfg['engine'] -eq 'deepseek') { $rbApi.Checked = $true } else { $rbLocal.Checked = $true }
    Update-SettingsUi

    try { $form.Show() } catch { }
    try { $form.Activate(); $form.BringToFront() } catch { }
}

# 从窗体读取配置；-Silent 时不弹错误框，只返回 $null
function Read-SettingsForm {
    param([switch]$Silent)
    $d = $script:Dlg
    if ($null -eq $d) { return $null }
    $cfg = New-DefaultConfig
    if ($d['rbApi'].Checked) { $cfg['engine'] = 'deepseek' } else { $cfg['engine'] = 'local' }
    $cfg['prompt'] = [string]$d['txtPrompt'].Text
    if ([string]::IsNullOrWhiteSpace([string]$cfg['prompt'])) { throw '提示词不能为空（可点「恢复默认提示词」）。' }
    $cfg['deepseek']['apiKey'] = ([string]$d['txtKey'].Text).Trim()
    $cfg['deepseek']['baseUrl'] = ([string]$d['txtBase'].Text).Trim()
    $cfg['deepseek']['model'] = ([string]$d['txtModel'].Text).Trim()
    $cfg['deepseek']['detail'] = [string]$d['cboDetail'].SelectedItem
    $cfg['deepseek']['maxSide'] = [int]$d['numMaxSide'].Value
    $cfg['deepseek']['timeoutSec'] = [int]$d['numTimeout'].Value
    $cfg['deepseek']['temperature'] = [double]$script:Config['deepseek']['temperature']

    if ([string]::IsNullOrWhiteSpace([string]$cfg['deepseek']['baseUrl'])) { $cfg['deepseek']['baseUrl'] = 'https://api.deepseek.com' }
    if ([string]::IsNullOrWhiteSpace([string]$cfg['deepseek']['model'])) { $cfg['deepseek']['model'] = 'deepseek-flash' }
    if ($cfg['engine'] -eq 'deepseek' -and [string]::IsNullOrWhiteSpace([string]$cfg['deepseek']['apiKey'])) {
        if ($Silent) { return $null }
        [void][System.Windows.Forms.MessageBox]::Show('引擎选了 DeepSeek，但 API Key 还是空的。请填入 Key，或改回本地引擎。', '还差一步', 'OK', 'Warning')
        return $null
    }
    return $cfg
}

function Save-SettingsForm {
    $cfg = Read-SettingsForm
    if ($null -eq $cfg) { return $false }
    $script:Config = $cfg
    try {
        $path = Export-Config -Config $cfg
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show('保存配置失败：' + $_.Exception.Message, '出错了', 'OK', 'Error')
        return $false
    }
    Update-TrayText
    try { if ($null -ne $script:DlgForm -and -not $script:DlgForm.IsDisposed) { $script:DlgForm.Close() } } catch { }

    $engine = Resolve-Engine
    # 只有托盘在跑的时候才做「自动接入」测速（独立打开设置窗口时没有气泡可显示）
    if ($engine -eq 'deepseek' -and $null -ne $script:Notify) {
        # 输入 Key 后自动接入：后台真跑一次识别，结果用托盘气泡回报
        $started = Start-ConfigProbe -OnDone {
            param($r)
            if ($null -ne $r -and $r['Ok']) {
                Show-NotifyBalloon '已接入 DeepSeek' ('接口测试通过（' + [int]$r['ElapsedMs'] + ' ms），之后 Alt+R 就走接口识别。配置：' + $script:Config['deepseek']['baseUrl']) 'Info'
            } else {
                $msg = '未知错误'
                if ($null -ne $r -and $r['Error']) { $msg = [string]$r['Error'] }
                Show-NotifyBalloon 'DeepSeek 接入失败' ($msg + '　（Alt+R+S 可回去检查 Key / 接口地址）') 'Error'
            }
        }
        if ($started) {
            Show-NotifyBalloon '设置已保存' '已切到 DeepSeek 引擎，正在后台测试接口连接…' 'Info'
        } else {
            Show-NotifyBalloon '设置已保存' '已切到 DeepSeek 引擎（接口测试被其他任务占用，稍后 Alt+R 时会真正调用）。' 'Info'
        }
    } else {
        Show-NotifyBalloon '设置已保存' ('当前引擎：本地 OCR。配置文件：' + $path) 'Info'
    }
    return $true
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

# =====================================================================
#  程序生命周期
# =====================================================================
function Invoke-Exit {
    try { if ($null -ne $script:ApiTimer) { $script:ApiTimer.Stop() } } catch { }
    try { if ($null -ne $script:CfgWatch) { $script:CfgWatch.Stop() } } catch { }
    try { if ($null -ne $script:ApiJob) { Remove-Job -Job $script:ApiJob['Job'] -Force -ErrorAction SilentlyContinue } } catch { }
    try { if ($null -ne $script:Chord) { $script:Chord.Uninstall() } } catch { }
    try { if ($script:Notify) { $script:Notify.Visible = $false; $script:Notify.Dispose() } } catch { }
    try { if ($script:HotkeyWin) { $script:HotkeyWin.UnregisterHotkey($script:HK_ID_REGION); $script:HotkeyWin.Shutdown() } } catch { }
    try { [System.Windows.Forms.Application]::Exit() } catch { }
}

function Build-TrayUi {
    $script:Notify = New-Object System.Windows.Forms.NotifyIcon
    $script:Notify.Icon = New-TrayIcon
    $script:Notify.Visible = $true
    Update-TrayText
    $script:Notify.add_MouseDoubleClick({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-RegionOcr }
    })

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miRun = New-Object System.Windows.Forms.ToolStripMenuItem('框选屏幕区域识别文字（Alt+R）')
    $miRun.add_Click({ Invoke-RegionOcr })
    [void]$menu.Items.Add($miRun)
    $miSet = New-Object System.Windows.Forms.ToolStripMenuItem('设置…（Alt+R+S）')
    $miSet.add_Click({ Show-SettingsWindow })
    [void]$menu.Items.Add($miSet)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miOpenCfg = New-Object System.Windows.Forms.ToolStripMenuItem('打开配置文件所在文件夹')
    $miOpenCfg.add_Click({
        try {
            $p = Get-ConfigPath
            $dir = Split-Path -Parent $p
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Start-Process 'explorer.exe' ('/select,"' + $p + '"')
        } catch { }
    })
    [void]$menu.Items.Add($miOpenCfg)

    $miMode = New-Object System.Windows.Forms.ToolStripMenuItem('识别引擎：本地 OCR')
    $miMode.add_Click({
        if ($script:Config['engine'] -eq 'local') { $script:Config['engine'] = 'deepseek' } else { $script:Config['engine'] = 'local' }
        try { [void](Export-Config -Config $script:Config) } catch { }
        Update-TrayText
        Show-NotifyBalloon '已切换引擎' ('当前：' + $(if ($script:Config['engine'] -eq 'deepseek') { 'DeepSeek 接口' } else { '本地 OCR' })) 'Info'
    })
    [void]$menu.Items.Add($miMode)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miExit = New-Object System.Windows.Forms.ToolStripMenuItem('退出')
    $miExit.add_Click({ Invoke-Exit })
    [void]$menu.Items.Add($miExit)

    $menu.add_Opening({
        $miMode.Text = '识别引擎：' + $(if ($script:Config['engine'] -eq 'deepseek') { 'DeepSeek 接口' } else { '本地 OCR' })
    })
    $script:Notify.ContextMenuStrip = $menu
}

function Start-ConfigWatcher {
    $script:CfgStamp = $null
    $path = Get-ConfigPath
    if (Test-Path -LiteralPath $path) { $script:CfgStamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc }
    $script:CfgWatch = New-Object System.Windows.Forms.Timer
    $script:CfgWatch.Interval = 2000
    $script:CfgWatch.add_Tick({
        try {
            $p = Get-ConfigPath
            if (-not (Test-Path -LiteralPath $p)) { return }
            $stamp = (Get-Item -LiteralPath $p).LastWriteTimeUtc
            if ($null -eq $script:CfgStamp -or $stamp -ne $script:CfgStamp) {
                $script:Config = Import-Config
                $script:CfgStamp = $stamp
                Update-TrayText
            }
        } catch { }
    })
    $script:CfgWatch.Start()
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
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }

    $engine = Resolve-Engine
    if ($engine -eq 'local') {
        $initOk = Initialize-OcrEnvironment
        if (-not $initOk) { Write-Warning '本地 OCR 初始化失败（缺少识别语言），可改用 DeepSeek 接口引擎。' }
    }

    $script:Busy = $false

    # 热键：Alt+R（识别）/ Alt+R 后按 S（设置）
    $script:Chord = New-Object ImgOcrNative.KeyChord
    $script:Chord.add_OcrRequested({ Invoke-RegionOcr })
    $script:Chord.add_SettingsRequested({ Show-SettingsWindow })
    $hookOk = $false
    try { $hookOk = $script:Chord.Install() } catch { $hookOk = $false }

    if ($hookOk) {
        Write-Output '热键已就绪：Alt+R 识别；按住 Alt 先按 R 再按 S 打开设置。'
    } else {
        Write-Warning '键盘钩子安装失败，已回退为 Alt+R 全局热键（设置请用托盘菜单）。'
        $script:HotkeyWin = New-Object ImgOcrNative.HotkeyWindow
        $ok = $script:HotkeyWin.RegisterHotkey($script:HK_ID_REGION, [uint32]$script:HK_MODS, [uint32]$script:HK_VK_REGION)
        if (-not $ok) { Write-Warning 'Alt+R 注册失败（可能被其他程序占用），仍可用托盘菜单触发。' }
        $script:HotkeyWin.add_HotKeyPressed({ param($s, $e) Invoke-RegionOcr })
    }

    Build-TrayUi
    Start-ConfigWatcher

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

# 只开设置窗口（供 -Settings / 独立调用）
function Start-SettingsOnly {
    [void][ImgOcrNative.Dpi]::MakeAware()
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
    Show-SettingsWindow
    if ($null -ne $script:DlgForm) {
        $script:DlgForm.add_FormClosed({ try { [System.Windows.Forms.Application]::Exit() } catch { } })
    }
    try { [System.Windows.Forms.Application]::Run() } catch { }
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
    $chord = New-Object ImgOcrNative.KeyChord
    $installed = $chord.Install()
    Write-Output ('SMOKE chord-install=' + $installed)
    if ($installed) { $chord.Uninstall() }
    Write-Output 'SMOKE-OK'
}

# 引导键状态机自检：不依赖真人按键
function Invoke-ChordTest {
    Write-Output 'CHORDTEST-START'
    $chord = New-Object ImgOcrNative.KeyChord
    $script:ChordOcrHits = 0
    $script:ChordSetHits = 0
    $chord.add_OcrRequested({ $script:ChordOcrHits++ })
    $chord.add_SettingsRequested({ $script:ChordSetHits++ })
    $alt = [ImgOcrNative.KeyChord]::VkAlt
    $r = [ImgOcrNative.KeyChord]::VkR
    $s = [ImgOcrNative.KeyChord]::VkS

    # 1) 按住 Alt -> R -> 松开 Alt   => 识别 1 次
    $chord.SimulateKey($alt, $true); $chord.SimulateKey($r, $true); $chord.SimulateKey($r, $false); $chord.SimulateKey($alt, $false)
    Write-Output ('CHORDTEST case1 ocr=' + $script:ChordOcrHits + ' set=' + $script:ChordSetHits + ' ' + $(if ($script:ChordOcrHits -eq 1 -and $script:ChordSetHits -eq 0) { 'OK' } else { 'FAIL' }))

    # 2) 按住 Alt -> R -> S -> 松开 => 只触发设置
    $script:ChordOcrHits = 0; $script:ChordSetHits = 0
    $chord.SimulateKey($alt, $true); $chord.SimulateKey($r, $true); $chord.SimulateKey($s, $true); $chord.SimulateKey($s, $false); $chord.SimulateKey($r, $false); $chord.SimulateKey($alt, $false)
    Write-Output ('CHORDTEST case2 ocr=' + $script:ChordOcrHits + ' set=' + $script:ChordSetHits + ' ' + $(if ($script:ChordOcrHits -eq 0 -and $script:ChordSetHits -eq 1) { 'OK' } else { 'FAIL' }))

    # 3) 按住 Alt -> R -> 其他键(X) -> 松开 => 都不触发
    $script:ChordOcrHits = 0; $script:ChordSetHits = 0
    $chord.SimulateKey($alt, $true); $chord.SimulateKey($r, $true); $chord.SimulateKey(0x58, $true); $chord.SimulateKey(0x58, $false); $chord.SimulateKey($alt, $false)
    Write-Output ('CHORDTEST case3 ocr=' + $script:ChordOcrHits + ' set=' + $script:ChordSetHits + ' ' + $(if ($script:ChordOcrHits -eq 0 -and $script:ChordSetHits -eq 0) { 'OK' } else { 'FAIL' }))

    # 4) 不按 Alt 直接按 R / S => 都不触发
    $script:ChordOcrHits = 0; $script:ChordSetHits = 0
    $chord.SimulateKey($r, $true); $chord.SimulateKey($r, $false); $chord.SimulateKey($s, $true); $chord.SimulateKey($s, $false)
    Write-Output ('CHORDTEST case4 ocr=' + $script:ChordOcrHits + ' set=' + $script:ChordSetHits + ' ' + $(if ($script:ChordOcrHits -eq 0 -and $script:ChordSetHits -eq 0) { 'OK' } else { 'FAIL' }))

    # 5) 连续两次 Alt+R => 识别 2 次
    $script:ChordOcrHits = 0; $script:ChordSetHits = 0
    $chord.SimulateKey($alt, $true); $chord.SimulateKey($r, $true); $chord.SimulateKey($r, $false); $chord.SimulateKey($alt, $false)
    $chord.SimulateKey($alt, $true); $chord.SimulateKey($r, $true); $chord.SimulateKey($r, $false); $chord.SimulateKey($alt, $false)
    Write-Output ('CHORDTEST case5 ocr=' + $script:ChordOcrHits + ' set=' + $script:ChordSetHits + ' ' + $(if ($script:ChordOcrHits -eq 2) { 'OK' } else { 'FAIL' }))

    Write-Output 'CHORDTEST-DONE'
}

# 真实按键自检：装上钩子后用注入按键走一遍（需要交互式桌面）
function Invoke-ChordTestLive {
    Write-Output 'CHORDLIVE-START'
    $chord = New-Object ImgOcrNative.KeyChord
    $script:ChordOcrHits = 0
    $script:ChordSetHits = 0
    $chord.add_OcrRequested({ $script:ChordOcrHits++ })
    $chord.add_SettingsRequested({ $script:ChordSetHits++ })
    if (-not $chord.Install()) { Write-Output 'CHORDLIVE install=FAIL'; return }
    Write-Output 'CHORDLIVE install=OK'

    $alt = [ImgOcrNative.KeyChord]::VkAlt
    $r = [ImgOcrNative.KeyChord]::VkR
    $s = [ImgOcrNative.KeyChord]::VkS

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1500
    $script:LiveStep = 0
    $script:LiveLog = New-Object System.Collections.ArrayList
    # 注意：事件回调里 Write-Output 是丢掉的，所以结果先攒起来，等消息循环退出后再打印。
    $timer.add_Tick({
        if ($script:LiveStep -eq 0) {
            [ImgOcrNative.KeyChord]::SendKey($alt, $true)
            [ImgOcrNative.KeyChord]::SendKey($r, $true)
            Start-Sleep -Milliseconds 60
            [ImgOcrNative.KeyChord]::SendKey($r, $false)
            [ImgOcrNative.KeyChord]::SendKey($alt, $false)
            $script:LiveStep = 1
        } elseif ($script:LiveStep -eq 1) {
            [void]$script:LiveLog.Add('case1(Alt+R)      ocr=' + $script:ChordOcrHits + ' set=' + $script:ChordSetHits)
            [ImgOcrNative.KeyChord]::SendKey($alt, $true)
            [ImgOcrNative.KeyChord]::SendKey($r, $true)
            Start-Sleep -Milliseconds 60
            [ImgOcrNative.KeyChord]::SendKey($s, $true)
            [ImgOcrNative.KeyChord]::SendKey($s, $false)
            Start-Sleep -Milliseconds 60
            [ImgOcrNative.KeyChord]::SendKey($r, $false)
            [ImgOcrNative.KeyChord]::SendKey($alt, $false)
            $script:LiveStep = 2
        } else {
            [void]$script:LiveLog.Add('case2(Alt+R+S)    ocr=' + $script:ChordOcrHits + ' set=' + $script:ChordSetHits)
            $timer.Stop()
            $chord.Uninstall()
            [System.Windows.Forms.Application]::Exit()
        }
    })
    $timer.Start()
    [System.Windows.Forms.Application]::Run()
    foreach ($line in $script:LiveLog) { Write-Output ('CHORDLIVE ' + $line) }
    Write-Output 'CHORDLIVE-DONE'
}

function Invoke-OcrSelfTest {
    $ok = Initialize-OcrEnvironment
    if (-not $ok) { Write-Output 'SELFTEST ocr-init=FAIL'; return }
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('imgocr_st_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir 'sample.png'
    $bmp = $null; $g = $null
    try {
        $bmp = New-Object System.Drawing.Bitmap(900, 340)
        try { $bmp.SetResolution(96, 96) } catch { }
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
            $g.DrawString('简体中文识别测试', $font, $brush, 20, 110)
            $g.DrawString('保留换行第三行', $font, $brush, 20, 200)
        } finally { $font.Dispose(); $brush.Dispose() }
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { if ($g) { $g.Dispose() }; if ($bmp) { $bmp.Dispose() } }
    try {
        $text = Invoke-OcrFile -Path $path
        Write-Output 'SELFTEST text>>>'
        Write-Output $text
        Write-Output 'SELFTEST text<<<'
        $lines = @($text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $checks = @()
        if ($text -match 'OCR') { $checks += 'ascii-OK' } else { $checks += 'ascii-FAIL' }
        if ($text -match '识别') { $checks += 'cn-OK' } else { $checks += 'cn-FAIL' }
        if ($lines.Count -ge 3) { $checks += 'lines-OK(' + $lines.Count + ')' } else { $checks += 'lines-FAIL(' + $lines.Count + ')' }
        if ($text -notmatch '测试保留') { $checks += 'nomerge-OK' } else { $checks += 'nomerge-FAIL' }
        Write-Output ('SELFTEST checks=' + ($checks -join ' '))
    } catch { Write-Output ('SELFTEST ocr-error=' + $_.Exception.Message) }
    finally { try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
    Write-Output 'SELFTEST-DONE'
}

# 接口自检：用当前配置真跑一次「测试图 -> 接口 -> 文字」
function Invoke-ApiSelfTest {
    $cfg = $script:Config
    Write-Output ('APITEST engine=' + (Resolve-Engine))
    Write-Output ('APITEST baseUrl=' + [string]$cfg['deepseek']['baseUrl'])
    Write-Output ('APITEST model=' + [string]$cfg['deepseek']['model'])
    Write-Output ('APITEST key=' + $(if ([string]::IsNullOrWhiteSpace([string]$cfg['deepseek']['apiKey'])) { '<empty>' } else { '<set,len=' + ([string]$cfg['deepseek']['apiKey']).Length + '>' }))
    $img = New-TestImagePng
    # 故意走和 Alt+R 完全相同的后台任务链路（Start-Job + 定时器轮询 + 回调），
    # 这样这个自检就真的在验证生产路径，而不是另写一条捷径。
    $script:ApiTestResult = $null
    $hard = [int]$cfg['deepseek']['timeoutSec'] + 30
    $started = Start-ApiJob -ImagePath $img -TempFile $img -HardTimeoutSec $hard -OnDone {
        param($r)
        $script:ApiTestResult = $r
    }
    if (-not $started) {
        try { Remove-Item -LiteralPath $img -Force -ErrorAction SilentlyContinue } catch { }
        Write-Output 'APITEST error=无法启动后台任务'
        Write-Output 'APITEST-DONE'
        return
    }
    $deadline = (Get-Date).AddSeconds($hard + 15)
    while ($null -eq $script:ApiTestResult -and (Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    $r = $script:ApiTestResult
    if ($null -eq $r) {
        Write-Output 'APITEST error=后台任务没有回调（超时）'
    } else {
        Write-Output ('APITEST ok=' + $r['Ok'] + ' ms=' + $r['ElapsedMs'] + ' http=' + $r['Status'] + ' uri=' + $r['Uri'])
        if ($r['Ok']) {
            Write-Output 'APITEST text>>>'
            Write-Output ([string]$r['Text'])
            Write-Output 'APITEST text<<<'
        } else {
            Write-Output ('APITEST error=' + [string]$r['Error'])
        }
    }
    Write-Output 'APITEST-DONE'
}

function Show-CurrentConfig {
    $cfg = $script:Config
    $key = [string]$cfg['deepseek']['apiKey']
    $masked = '<empty>'
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        if ($key.Length -le 8) { $masked = '****' } else { $masked = $key.Substring(0, 4) + '****' + $key.Substring($key.Length - 4) }
    }
    Write-Output ('CONFIG path=' + (Get-ConfigPath))
    Write-Output ('CONFIG exists=' + (Test-Path -LiteralPath (Get-ConfigPath)))
    Write-Output ('CONFIG engine=' + $cfg['engine'] + ' resolved=' + (Resolve-Engine))
    Write-Output ('CONFIG baseUrl=' + $cfg['deepseek']['baseUrl'])
    Write-Output ('CONFIG model=' + $cfg['deepseek']['model'])
    Write-Output ('CONFIG detail=' + $cfg['deepseek']['detail'] + ' maxSide=' + $cfg['deepseek']['maxSide'] + ' timeout=' + $cfg['deepseek']['timeoutSec'])
    Write-Output ('CONFIG apiKey=' + $masked)
    Write-Output 'CONFIG prompt>>>'
    Write-Output ([string]$cfg['prompt'])
    Write-Output 'CONFIG prompt<<<'
}

# =====================================================================
#  主入口
# =====================================================================
try {
    if ($InstallSelf) { Set-AutoStart -Enable $true; return }
    if ($UninstallSelf) { Set-AutoStart -Enable $false; return }

    Compile-NativeBridge
    $script:Config = Import-Config

    if ($CheckOcr) {
        $ok = Initialize-OcrEnvironment
        Write-Output ('ocr-engine=' + $(if ($ok) { 'available' } else { 'UNAVAILABLE' }))
        Write-Output ('config-engine=' + (Resolve-Engine) + ' (' + $script:Config['engine'] + ')')
        return
    }
    if ($ShowConfig) { Show-CurrentConfig; return }
    if ($SelfTest) { Invoke-OcrSelfTest; return }
    if ($ApiSelfTest) { Invoke-ApiSelfTest; return }
    if ($ChordTest) { Invoke-ChordTest; return }
    if ($ChordTestLive) { Invoke-ChordTestLive; return }
    if ($OverlayTest) {
        [void][ImgOcrNative.Dpi]::MakeAware()
        $b = [ImgOcrNative.ScreenCapture]::SelectRegion()
        Write-Output ('OVERLAY-RESULT=' + $(if ($null -ne $b) { 'bitmap' } else { 'cancelled' }))
        return
    }
    if ($SmokeTest) { Invoke-SmokeTest; return }
    if ($Settings) { Start-SettingsOnly; return }
    Start-Assistant -GuiSmoke:$GuiSmoke
}
catch {
    Write-Output ('FATAL ' + $_.Exception.ToString())
    throw
}
