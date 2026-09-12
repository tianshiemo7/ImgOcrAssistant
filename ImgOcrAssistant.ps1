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
        -Settings / -ShowConfig / -ApiSelfTest / -ClipboardTest
        -ChordTest / -ChordTestLive
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
    [switch]$ClipboardTest,
    [switch]$ExitTest,
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
$script:ProviderCache   = $null
$script:DlgDraft        = $null
$script:DlgProviderIds  = @()
$script:DlgLoading      = $false
$script:DlgLoadedProvider = ''
$script:LastOcrText = $null
$script:ClipPending = $null
$script:ClipTimer   = $null
$script:ExitTimer   = $null
$script:MenuEngine  = $null
$script:MenuRecopy  = $null
$script:MenuExitItem = $null
$script:Dlg         = $null
$script:DlgForm     = $null
$script:DlgTesting  = $false
$script:ApiJob      = $null
$script:ApiTimer    = $null
$script:CfgWatch    = $null
$script:CfgStamp    = $null

# =====================================================================
#  识别引擎目录（扩展点 1/2）
#  ------------------------------------------------------------------
#  要接一个新模型/新服务，通常只要在下面的表里加一条：
#    id = [ordered]@{
#        kind      = 'remote'            # 'local' 或 'remote'
#        shape     = 'openai-vision'     # 请求格式，见 $script:RequestShapes（扩展点 2/2）
#        name      = '显示名'
#        desc      = '设置窗口里的一句话说明'
#        baseUrl   = 'https://...'       # 预设，用户可改
#        model     = '默认模型名'
#        models    = @('建议模型1','建议模型2')   # 只用于界面提示
#        keyUrl    = '申请 Key 的网址'    # 可空
#        keyRequired = $true             # 本地模型服务可以设 $false
#        supportsDetail = $true          # 是否认 image_url.detail 字段
#        note      = '注意事项'
#    }
#  shape 不用 openai-vision 的（比如 Anthropic / Gemini 原生格式），
#  在 $script:RequestShapes 里加一个同名脚本块即可，其余代码不用动。
# =====================================================================
function Get-ProviderCatalog {
    if ($null -ne $script:ProviderCache) { return $script:ProviderCache }
    $script:ProviderCache = [ordered]@{
        'local' = [ordered]@{
            id             = 'local'
            kind           = 'local'
            name           = '本地识别（Windows 内置 OCR）'
            desc           = '离线、免费、不上传；开箱默认'
            keyRequired    = $false
            supportsDetail = $false
        }
        'deepseek' = [ordered]@{
            id             = 'deepseek'
            kind           = 'remote'
            shape          = 'openai-vision'
            name           = 'DeepSeek'
            desc           = 'deepseek-flash 支持图片输入'
            baseUrl        = 'https://api.deepseek.com'
            model          = 'deepseek-flash'
            models         = @('deepseek-flash')
            keyUrl         = 'https://platform.deepseek.com/api_keys'
            keyRequired    = $true
            supportsDetail = $true
            note           = '官方接口，已实测'
        }
        'openai' = [ordered]@{
            id             = 'openai'
            kind           = 'remote'
            shape          = 'openai-vision'
            name           = 'OpenAI'
            desc           = 'gpt-4o / gpt-4o-mini 等视觉模型'
            baseUrl        = 'https://api.openai.com/v1'
            model          = 'gpt-4o-mini'
            models         = @('gpt-4o-mini', 'gpt-4o')
            keyUrl         = 'https://platform.openai.com/api-keys'
            keyRequired    = $true
            supportsDetail = $true
            note           = '地址/模型为预设值，未实测'
        }
        'dashscope' = [ordered]@{
            id             = 'dashscope'
            kind           = 'remote'
            shape          = 'openai-vision'
            name           = '阿里云百炼（通义千问 VL）'
            desc           = 'qwen-vl 系列，OpenAI 兼容模式'
            baseUrl        = 'https://dashscope.aliyuncs.com/compatible-mode/v1'
            model          = 'qwen-vl-max-latest'
            models         = @('qwen-vl-max-latest', 'qwen-vl-plus')
            keyUrl         = 'https://bailian.console.aliyun.com/'
            keyRequired    = $true
            supportsDetail = $false
            note           = '地址/模型为预设值，未实测'
        }
        'siliconflow' = [ordered]@{
            id             = 'siliconflow'
            kind           = 'remote'
            shape          = 'openai-vision'
            name           = '硅基流动 SiliconFlow'
            desc           = '上面托管了多种开源 VL 模型'
            baseUrl        = 'https://api.siliconflow.cn/v1'
            model          = 'Qwen/Qwen2.5-VL-72B-Instruct'
            models         = @('Qwen/Qwen2.5-VL-72B-Instruct', 'deepseek-ai/deepseek-vl2')
            keyUrl         = 'https://cloud.siliconflow.cn/account/ak'
            keyRequired    = $true
            supportsDetail = $false
            note           = '地址/模型为预设值，未实测'
        }
        'ollama' = [ordered]@{
            id             = 'ollama'
            kind           = 'remote'
            shape          = 'openai-vision'
            name           = 'Ollama（本机模型）'
            desc           = '本机跑视觉模型，数据不出内网'
            baseUrl        = 'http://127.0.0.1:11434/v1'
            model          = 'qwen2.5vl:7b'
            models         = @('qwen2.5vl:7b', 'llama3.2-vision')
            keyUrl         = 'https://ollama.com/search?c=vision'
            keyRequired    = $false
            supportsDetail = $false
            note           = '需要本机已装 Ollama 并 pull 了视觉模型'
        }
        'custom' = [ordered]@{
            id             = 'custom'
            kind           = 'remote'
            shape          = 'openai-vision'
            name           = '自定义（任意 OpenAI 兼容接口）'
            desc           = '自己填接口地址和模型名'
            baseUrl        = ''
            model          = ''
            models         = @()
            keyUrl         = ''
            keyRequired    = $true
            supportsDetail = $true
            note           = '填 /v1 结尾的地址即可，程序会自动补 /chat/completions'
        }
    }
    return $script:ProviderCache
}

function Get-Provider {
    param([string]$Id)
    $catalog = Get-ProviderCatalog
    if ([string]::IsNullOrWhiteSpace($Id) -or -not $catalog.Contains($Id)) { return $catalog['local'] }
    return $catalog[$Id]
}

function Test-ProviderId {
    param([string]$Id)
    return (Get-ProviderCatalog).Contains($Id)
}

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

# 每个 provider 自己一份设置，切换 provider 不会互相覆盖
function New-ProviderSettings {
    param([string]$Id)
    $p = Get-Provider -Id $Id
    return [ordered]@{
        apiKey  = ''
        baseUrl = [string]$p['baseUrl']
        model   = [string]$p['model']
        detail  = 'original'
    }
}

function New-DefaultConfig {
    $providers = [ordered]@{}
    foreach ($id in (Get-ProviderCatalog).Keys) {
        if ($id -eq 'local') { continue }
        $providers[$id] = (New-ProviderSettings -Id $id)
    }
    return [ordered]@{
        version   = 2
        engine    = 'local'          # 'local' 或 provider id
        prompt    = (Get-DefaultPrompt)
        maxSide     = 1920           # 上传前把图片最长边压到该像素数，0 = 不压缩
        temperature = 0
        timeoutSec  = 60
        providers = $providers
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

            # v2：providers 字典
            if ($null -ne $j.providers) {
                foreach ($id in @($cfg['providers'].Keys)) {
                    $src = $j.providers.$id
                    if ($null -eq $src) { continue }
                    foreach ($k in @('apiKey', 'baseUrl', 'model', 'detail')) {
                        $v = $src.$k
                        if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { $cfg['providers'][$id][$k] = [string]$v }
                    }
                }
            }

            # v1 兼容：老配置是 { engine = 'deepseek', deepseek = { apiKey/baseUrl/model/detail/maxSide/temperature/timeoutSec } }
            if ($null -ne $j.deepseek) {
                if ([string]$j.engine -eq 'deepseek' -or -not [string]::IsNullOrWhiteSpace([string]$j.deepseek.apiKey)) {
                    foreach ($k in @('apiKey', 'baseUrl', 'model', 'detail')) {
                        $v = $j.deepseek.$k
                        if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { $cfg['providers']['deepseek'][$k] = [string]$v }
                    }
                }
                foreach ($k in @('maxSide', 'temperature', 'timeoutSec')) {
                    $v = $j.deepseek.$k
                    if ($null -ne $v) { $cfg[$k] = $v }
                }
            }

            # v2 顶层同名项优先
            foreach ($k in @('maxSide', 'temperature', 'timeoutSec')) {
                $v = $j.$k
                if ($null -ne $v) { $cfg[$k] = $v }
            }
        }
        catch { Write-Warning ('配置文件读取失败，改用默认配置：' + $_.Exception.Message) }
    }
    if ([string]::IsNullOrWhiteSpace([string]$cfg['prompt'])) { $cfg['prompt'] = Get-DefaultPrompt }
    if (-not (Test-ProviderId -Id ([string]$cfg['engine']))) { $cfg['engine'] = 'local' }
    if ([string]$cfg['engine'] -eq 'local') { $cfg['engine'] = 'local' }
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
    # 配置写坏过一次（所有 provider 变成同一个），留个现场：谁写的、写进去的各 provider 模型是什么
    try {
        $shape = @()
        foreach ($id in $Config['providers'].Keys) {
            $shape += ($id + '=' + [string]$Config['providers'][$id]['model'] + '/' + $(if ([string]::IsNullOrWhiteSpace([string]$Config['providers'][$id]['apiKey'])) { '-' } else { 'K' }))
        }
        $stack = ((Get-PSCallStack) | Select-Object -Skip 1 -First 6 | ForEach-Object { $_.Command }) -join '<-'
        Write-DiagLog ('保存配置 engine=' + [string]$Config['engine'] + ' [' + ($shape -join ' ') + '] 调用栈: ' + $stack)
    } catch { }
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    $script:CfgStamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc
    return $path
}

# 当前生效的引擎：返回 provider 目录项 + 是否需要回退
function Resolve-Engine {
    $id = [string]$script:Config['engine']
    if (-not (Test-ProviderId -Id $id)) { $id = 'local' }
    $p = Get-Provider -Id $id
    $fallback = ''
    if ($p['kind'] -eq 'remote' -and [bool]$p['keyRequired']) {
        $key = [string]$script:Config['providers'][$id]['apiKey']
        if ([string]::IsNullOrWhiteSpace($key)) { $fallback = 'missing-key' }
    }
    return [ordered]@{
        Id       = $id
        Provider = $p
        Kind     = [string]$p['kind']
        Active   = $(if ($fallback) { 'local' } else { $id })
        Fallback = $fallback
    }
}

function Get-EngineLabel {
    param($Engine = $null)
    if ($null -eq $Engine) { $Engine = Resolve-Engine }
    if ([string]$Engine['Kind'] -eq 'local') { return '本地' }
    $name = [string]$Engine['Provider']['name']
    if ($Engine['Fallback'] -eq 'missing-key') { return $name + '·未配置Key' }
    return $name
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

    /// <summary>注入真实鼠标点击，供 -ExitTest 之类的自检走「用户真实操作」路径。</summary>
    public static class Mouse
    {
        private const uint LEFTDOWN = 0x0002;
        private const uint LEFTUP = 0x0004;

        [DllImport("user32.dll")]
        private static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")]
        private static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

        public static void ClickAt(int x, int y)
        {
            SetCursorPos(x, y);
            System.Threading.Thread.Sleep(80);
            mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
            System.Threading.Thread.Sleep(80);
            mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
        }
    }

    /// <summary>
    /// 直接操作 Win32 剪贴板（不走 OLE）。WinForms 的 Clipboard.SetText 在剪贴板被别的
    /// 程序占用、或 OLE 出问题时只会抛 ExternalException，这里作为兜底再写一次。
    /// </summary>
    public static class Clip
    {
        private const uint CF_TEXT = 1;
        private const uint CF_UNICODETEXT = 13;
        private const uint GMEM_MOVEABLE = 0x0002;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool OpenClipboard(IntPtr hWndNewOwner);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool CloseClipboard();
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool EmptyClipboard();
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr GetClipboardData(uint uFormat);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalLock(IntPtr hMem);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GlobalUnlock(IntPtr hMem);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GlobalFree(IntPtr hMem);

        /// <summary>写入文本。成功返回 null，失败返回错误说明（已重试）。</summary>
        public static string SetText(string text)
        {
            if (text == null) text = string.Empty;
            int lastError = 0;
            for (int attempt = 0; attempt < 10; attempt++)
            {
                if (OpenClipboard(IntPtr.Zero))
                {
                    try
                    {
                        if (!EmptyClipboard())
                        {
                            lastError = Marshal.GetLastWin32Error();
                            continue;
                        }
                        // 主格式：UTF-16
                        byte[] uni = System.Text.Encoding.Unicode.GetBytes(text + "\0");
                        if (!Put(CF_UNICODETEXT, uni))
                        {
                            lastError = Marshal.GetLastWin32Error();
                            continue;
                        }
                        // 老程序只认 ANSI，再放一份（失败不影响结果）
                        try
                        {
                            byte[] ansi = System.Text.Encoding.Default.GetBytes(text + "\0");
                            Put(CF_TEXT, ansi);
                        }
                        catch { }
                        return null;
                    }
                    finally { CloseClipboard(); }
                }
                lastError = Marshal.GetLastWin32Error();
                System.Threading.Thread.Sleep(150);
            }
            return "OpenClipboard/SetClipboardData failed (Win32 error " + lastError + ")";
        }

        /// <summary>读取文本，失败返回 null。</summary>
        public static string GetText()
        {
            for (int attempt = 0; attempt < 10; attempt++)
            {
                if (OpenClipboard(IntPtr.Zero))
                {
                    try
                    {
                        IntPtr h = GetClipboardData(CF_UNICODETEXT);
                        if (h == IntPtr.Zero) return null;
                        IntPtr p = GlobalLock(h);
                        if (p == IntPtr.Zero) return null;
                        try { return Marshal.PtrToStringUni(p); }
                        finally { GlobalUnlock(h); }
                    }
                    finally { CloseClipboard(); }
                }
                System.Threading.Thread.Sleep(150);
            }
            return null;
        }

        private static bool Put(uint format, byte[] bytes)
        {
            IntPtr h = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)bytes.Length);
            if (h == IntPtr.Zero) return false;
            IntPtr p = GlobalLock(h);
            if (p == IntPtr.Zero) { GlobalFree(h); return false; }
            Marshal.Copy(bytes, 0, p, bytes.Length);
            GlobalUnlock(h);
            if (SetClipboardData(format, h) == IntPtr.Zero) { GlobalFree(h); return false; }
            // 成功时内存所有权已经交给剪贴板，不能自己释放
            return true;
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

# 本地 OCR 环境是懒加载的：启动时用的是接口引擎、或者以后从接口切回本地、
# 又或者接口没配 Key 回退到本地 —— 这些情况下都得在使用前补初始化一次。
function Ensure-LocalOcr {
    if ($null -ne $script:OcrEngine) { return $true }
    return [bool](Initialize-OcrEnvironment)
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
#  远程识别
#  ------------------------------------------------------------------
#  请求格式注册表（扩展点 2/2）：每种 shape 是一个「自包含」脚本块。
#  约束：块内只能使用传入的 $ctx 和 .NET API，**不要调用本文件里的其它函数** ——
#        它会被序列化后丢进后台 PowerShell 进程执行。
#  入参 $ctx：baseUrl/model/apiKey/prompt/detail/temperature/userText/imageBase64
#  返回：@{ Path = 追加到 baseUrl 的路径; Body = 请求体字符串;
#           Headers = 附加请求头; Parser = 解析响应的脚本块（返回正文文字） }
#  要接 Anthropic / Gemini 这类非 OpenAI 格式，在这里加一条就行；
#  在下面目录里加个 provider 指向新 shape，其余代码不用改。
# =====================================================================
$script:RequestShapes = @{
    'openai-vision' = {
        param($ctx)
        $image = [ordered]@{ url = ('data:image/png;base64,' + [string]$ctx['imageBase64']) }
        # 有些服务不认 detail 字段，provider 里 supportsDetail=$false 时就不发
        if (-not [string]::IsNullOrWhiteSpace([string]$ctx['detail'])) { $image['detail'] = [string]$ctx['detail'] }
        $payload = [ordered]@{
            model       = [string]$ctx['model']
            messages    = @(
                [ordered]@{ role = 'system'; content = [string]$ctx['prompt'] },
                [ordered]@{ role = 'user'; content = @(
                        [ordered]@{ type = 'text'; text = [string]$ctx['userText'] },
                        [ordered]@{ type = 'image_url'; image_url = $image }
                    )
                }
            )
            temperature = $ctx['temperature']
            stream      = $false
        }
        return @{
            Path    = '/chat/completions'
            Body    = ($payload | ConvertTo-Json -Depth 12 -Compress)
            Headers = @{ Authorization = ('Bearer ' + [string]$ctx['apiKey']) }
            Parser  = {
                param($json)
                $c = $json.choices[0].message.content
                if ($c -is [string]) { return $c }
                $t = ''
                if ($null -ne $c) { foreach ($b in $c) { if ($null -ne $b.text) { $t += [string]$b.text } } }
                return $t
            }
        }
    }
}

# 后台任务体：自包含，接收「shape 源码 + 已解析好的参数」，不依赖本文件其它函数
$script:RemoteVisionCall = {
    param(
        [string]$ShapeSource,
        [hashtable]$Ctx,
        [string]$ImagePath
    )
    $res = @{ Ok = $false; Text = ''; Error = ''; ElapsedMs = 0; Model = [string]$Ctx['model']; Uri = ''; Status = 0 }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    try { [Net.ServicePointManager]::Expect100Continue = $false } catch { }
    try {
        if (-not (Test-Path -LiteralPath $ImagePath)) { throw ('找不到待识别图片：' + $ImagePath) }
        $base = [string]$Ctx['baseUrl']
        if ([string]::IsNullOrWhiteSpace($base)) { throw '没有填接口地址：请按 Alt+R+S 打开设置填写。' }
        $base = $base.Trim().TrimEnd('/')

        # 图片在这里才读进内存并 base64，避免把几 MB 字符串塞进后台任务的参数序列化
        $Ctx['imageBase64'] = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ImagePath))

        $shapeBuilder = [scriptblock]::Create($ShapeSource)
        $shape = & $shapeBuilder $Ctx
        $path = [string]$shape['Path']
        if ([string]::IsNullOrWhiteSpace($path)) { $path = '/chat/completions' }
        if ($base.EndsWith($path)) { $uri = $base } else { $uri = $base + $path }
        $res.Uri = $uri

        $body = [System.Text.Encoding]::UTF8.GetBytes([string]$shape['Body'])
        $timeout = [int]$Ctx['timeoutSec']
        if ($timeout -le 0) { $timeout = 60 }

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
            foreach ($k in $shape['Headers'].Keys) {
                $v = [string]$shape['Headers'][$k]
                if (-not [string]::IsNullOrWhiteSpace($v)) { $req.Headers.Add([string]$k, $v) }
            }
            $req.Timeout = $timeout * 1000
            $req.ReadWriteTimeout = $timeout * 1000
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
        try { $content = [string](& $shape['Parser'] $jsonObj) } catch { }
        if ([string]::IsNullOrWhiteSpace($content)) { throw ('接口返回内容为空。原始响应：' + $respText) }
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

# 把当前配置解析成「一次识别调用」需要的全部参数（后台任务只认这个，不读全局配置）
function Get-RecognitionContext {
    $eng = Resolve-Engine
    $id = [string]$eng['Id']
    $p = $eng['Provider']
    $ps = $script:Config['providers'][$id]
    $baseUrl = [string]$ps['baseUrl']
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl = [string]$p['baseUrl'] }
    $model = [string]$ps['model']
    if ([string]::IsNullOrWhiteSpace($model)) { $model = [string]$p['model'] }
    $detail = [string]$ps['detail']
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'original' }
    if (-not [bool]$p['supportsDetail']) { $detail = '' }   # 不认 detail 的服务就别发这个字段
    return @{
        providerId  = $id
        providerName = [string]$p['name']
        shape       = [string]$p['shape']
        baseUrl     = $baseUrl
        model       = $model
        apiKey      = [string]$ps['apiKey']
        prompt      = [string]$script:Config['prompt']
        detail      = $detail
        temperature = [double]$script:Config['temperature']
        timeoutSec  = [int]$script:Config['timeoutSec']
        maxSide     = [int]$script:Config['maxSide']
        userText    = '请提取这张图片中的全部文字。'
    }
}

# =====================================================================
#  后台任务：远程识别不能卡住消息循环（否则热键钩子会被系统回收）
#  与具体厂商无关：只把「请求格式 + 解析好的参数」丢给后台进程。
# =====================================================================
function Start-ApiJob {
    param(
        [string]$ImagePath,
        [string]$TempFile,
        [int]$HardTimeoutSec,
        [scriptblock]$OnDone
    )
    if ($null -ne $script:ApiJob) { return $false }
    if ($HardTimeoutSec -le 0) { $HardTimeoutSec = 90 }
    $ctx = Get-RecognitionContext
    $shapeName = [string]$ctx['shape']
    if (-not $script:RequestShapes.ContainsKey($shapeName)) { return $false }
    $shapeSource = $script:RequestShapes[$shapeName].ToString()
    try {
        $job = Start-Job -ScriptBlock $script:RemoteVisionCall -ArgumentList $shapeSource, $ctx, $ImagePath
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
    $hard = [int]$script:Config['timeoutSec'] + 30
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
        $text = '屏幕OCR助手［' + (Get-EngineLabel) + '］Alt+R 识别 · Alt+R+S 设置'
    }
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    try { $script:Notify.Text = $text } catch { }
}

# 出问题时留个痕迹，方便排查（和配置文件放一起）
function Write-DiagLog {
    param([string]$Message)
    try {
        $dir = Split-Path -Parent (Get-ConfigPath)
        if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Message + "`r`n"
        [System.IO.File]::AppendAllText((Join-Path $dir 'imgocr.log'), $line, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# 识别结果落盘：剪贴板写不进去时至少不丢字
function Save-LastOcrText {
    param([string]$Text)
    try {
        $dir = Split-Path -Parent (Get-ConfigPath)
        if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $p = Join-Path $dir 'last-ocr.txt'
        [System.IO.File]::WriteAllText($p, $Text, (New-Object System.Text.UTF8Encoding($true)))
        return $p
    } catch { return '' }
}

# 写剪贴板：先 WinForms（自带 OLE 重试），不行再退回原生 Win32 剪贴板
# 写一次剪贴板。原生 Win32 通路为主：它不经过 OLE，失败会立刻返回（不阻塞消息循环），
# 而且同时放 CF_UNICODETEXT + CF_TEXT 两份，兼容性够。OLE 那条留作最后的兜底。
function Set-ClipboardText {
    param([string]$Text, [int]$Attempts = 1, [int]$GapMs = 120, [switch]$SkipOle)
    $errs = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $e = [ImgOcrNative.Clip]::SetText($Text)
            if ($null -eq $e) { return @{ Ok = $true; Via = 'Win32'; Error = '' } }
            [void]$errs.Add('Win32#' + $i + ': ' + $e)
        } catch { [void]$errs.Add('Win32#' + $i + ': ' + $_.Exception.Message) }
        if ($i -lt $Attempts) { Start-Sleep -Milliseconds $GapMs }
    }
    if (-not $SkipOle) {
        # WinForms 内部自带约 1 秒的 OLE 重试，所以只在主要通路失败后才用
        try {
            [System.Windows.Forms.Clipboard]::SetText($Text)
            return @{ Ok = $true; Via = 'WinForms'; Error = '' }
        } catch { [void]$errs.Add('WinForms: ' + $_.Exception.Message) }
    }
    return @{ Ok = $false; Via = ''; Error = ($errs -join ' | ') }
}

# 投递识别结果：先同步快试一次，失败就交给定时器在消息循环里继续重试
# （长时间 sleep 会把消息循环卡住，进而拖慢甚至被系统回收键盘钩子）
function Start-ClipboardDelivery {
    param([string]$Text, [string]$Suffix = '')
    if ([string]::IsNullOrWhiteSpace($Text)) {
        Show-NotifyBalloon '未识别到文字' '所选区域没有可识别的文字，或文字太小 / 太模糊。' 'Warning'
        return $false
    }
    $script:LastOcrText = $Text
    $sn = ($Text -replace '\s+', ' ').Trim()
    if ($sn.Length -gt 26) { $sn = $sn.Substring(0, 26) + '...' }

    # 第一步：原生快速重试几次（每次失败都是立刻返回，几乎不阻塞）
    $r = Set-ClipboardText -Text $Text -Attempts 3 -GapMs 150 -SkipOle
    if (-not $r['Ok']) {
        # 第二步：走 OLE（自带重试），这一步最多阻塞约 1 秒
        $r = Set-ClipboardText -Text $Text -Attempts 1
    }
    if ($r['Ok']) {
        $script:ClipPending = $null
        Show-NotifyBalloon '已复制' ('识别文字已复制到剪贴板' + $Suffix + '：' + $sn) 'Info'
        return $true
    }

    Write-DiagLog ('剪贴板首次写入失败（引擎' + $Suffix + '，长度' + $Text.Length + '）：' + $r['Error'])
    $script:ClipPending = @{ Text = $Text; Suffix = $Suffix; Sn = $sn; Tries = 0 }
    if ($null -eq $script:ClipTimer) {
        $script:ClipTimer = New-Object System.Windows.Forms.Timer
        $script:ClipTimer.Interval = 400
        $script:ClipTimer.add_Tick({ Step-ClipboardDelivery })
    }
    if (-not $script:ClipTimer.Enabled) { $script:ClipTimer.Start() }
    Show-NotifyBalloon '正在重试复制' '剪贴板被别的程序（常见是微信/剪贴板工具）占用了一下，正在自动重试…' 'Info'
    return $false
}

function Step-ClipboardDelivery {
    $p = $script:ClipPending
    if ($null -eq $p) { try { $script:ClipTimer.Stop() } catch { }; return }
    $p['Tries'] = [int]$p['Tries'] + 1
    $r = Set-ClipboardText -Text $p['Text'] -Attempts 1 -SkipOle

    if ($r['Ok']) {
        try { $script:ClipTimer.Stop() } catch { }
        $script:ClipPending = $null
        $suffix = $p['Suffix'] + '，重试 ' + $p['Tries'] + ' 次后成功'
        Show-NotifyBalloon '已复制' ('识别文字已复制到剪贴板' + $suffix + '：' + $p['Sn']) 'Info'
        Write-DiagLog ('剪贴板重试 ' + $p['Tries'] + ' 次后写入成功（' + $r['Via'] + '）')
        return
    }
    if ($p['Tries'] -ge 25) {
        try { $script:ClipTimer.Stop() } catch { }
        $script:ClipPending = $null
        Write-DiagLog ('剪贴板重试 ' + $p['Tries'] + ' 次仍失败：' + $r['Error'])
        $path = Save-LastOcrText -Text $p['Text']
        $tip = '文字识别出来了，但剪贴板一直被别的程序占用，写不进去。'
        if (-not [string]::IsNullOrEmpty($path)) { $tip = $tip + '文字已保存到：' + $path + '（可直接打开复制）' }
        $tip = $tip + ' 也可以关掉占用剪贴板的程序后，点托盘菜单「复制上次识别结果」。'
        Show-NotifyBalloon '剪贴板写入失败' $tip 'Error'
    }
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
        if ($engine['Fallback'] -eq 'missing-key') {
            Show-NotifyBalloon '未配置 API Key' ('当前引擎是 ' + $engine['Provider']['name'] + ' 但还没有 API Key，已回退为本地识别。按 Alt+R+S 可填入 Key。') 'Warning'
        }

        if ($engine['Active'] -ne 'local') {
            $label = [string]$engine['Provider']['name']
            $png = Join-Path ([System.IO.Path]::GetTempPath()) ('imgocr_ds_' + [guid]::NewGuid().ToString('N') + '.png')
            Save-ImageToPngFile -Image $bmp -Path $png -MaxSide ([int]$script:Config['maxSide'])
            $bmp.Dispose(); $bmp = $null
            Update-TrayText -Override ('屏幕OCR助手：正在用 ' + $label + ' 识别…')
            Show-NotifyBalloon '正在识别' ('已把截图发送到 ' + $label + ' 接口，请稍候…') 'Info'
            $handedOff = Start-ApiJob -ImagePath $png -TempFile $png `
                -HardTimeoutSec ([int]$script:Config['timeoutSec'] + 30) `
                -OnDone { param($r) Complete-ApiOcr -Result $r }
            if (-not $handedOff) {
                try { Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue } catch { }
                Show-NotifyBalloon '无法启动识别任务' '后台任务占用中（可能正在测试接口），请稍后再试。' 'Warning'
            }
            return
        }

        if (-not (Ensure-LocalOcr)) {
            Show-NotifyBalloon '本地 OCR 不可用' '这台机器上没找到可用的 Windows OCR 语言包。可以按 Alt+R+S 改用接口引擎，或在「设置 → 时间和语言 → 语言和区域」里给中文补装「光学字符识别」组件。' 'Error'
            return
        }

        $text = ''
        try { $text = Invoke-OcrImage -Image $bmp } catch { Show-NotifyBalloon '本地识别出错' $_.Exception.Message 'Error'; return }
        [void](Start-ClipboardDelivery -Text $text -Suffix '（本地）')
    }
    catch { Show-NotifyBalloon '识别出错' $_.Exception.Message 'Error' }
    finally {
        if ($null -ne $bmp) { $bmp.Dispose() }
        if (-not $handedOff) { $script:Busy = $false; Update-TrayText }
    }
}

function Complete-ApiOcr {
    param($Result)
    $label = [string](Resolve-Engine)['Provider']['name']
    if ([string]::IsNullOrWhiteSpace($label)) { $label = '接口' }
    try {
        if ($null -eq $Result) { Show-NotifyBalloon ($label + ' 识别失败') '后台任务异常结束。' 'Error'; return }
        if (-not $Result['Ok']) {
            Show-NotifyBalloon ($label + ' 识别失败') ([string]$Result['Error']) 'Error'
            return
        }
        $text = Format-OcrText -Text ([string]$Result['Text'])
        $ms = [int]$Result['ElapsedMs']
        $suffix = '（' + $label
        if ($ms -gt 0) { $suffix = $suffix + ' ' + [Math]::Round($ms / 1000.0, 1) + 's' }
        $suffix = $suffix + '）'
        [void](Start-ClipboardDelivery -Text $text -Suffix $suffix)
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

# 「标签在左、控件在右」的一行，省掉一堆重复的 Location/Size 样板
function Add-UiRow {
    param(
        [System.Windows.Forms.Control]$Group,
        [string]$Text,
        [double]$Y,
        [System.Windows.Forms.Control]$Control,
        [double]$LabelX = 14,
        [double]$ControlX = 130,
        [double]$Width = 0
    )
    [void]$Group.Controls.Add((New-Label $Text $LabelX $Y))
    $Control.Location = (New-ScaledPoint $ControlX ($Y - 3))
    if ($Width -gt 0) { $Control.Size = (New-ScaledSize $Width 23) }
    [void]$Group.Controls.Add($Control)
    return $Control
}

function New-UiText { param([string]$Value = '') $t = New-Object System.Windows.Forms.TextBox; $t.Text = $Value; return $t }
function New-UiNum { param([double]$Value, [double]$Min, [double]$Max) 
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = $Min; $n.Maximum = $Max
    $n.Value = [decimal][Math]::Max($Min, [Math]::Min($Max, $Value))
    return $n
}
function New-UiCombo { param([string[]]$Items, [string]$Selected = '')
    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    if ($Items.Count -gt 0) { [void]$c.Items.AddRange($Items) }
    if (-not [string]::IsNullOrWhiteSpace($Selected)) { $c.SelectedItem = $Selected }
    if ($null -eq $c.SelectedItem -and $c.Items.Count -gt 0) { $c.SelectedIndex = 0 }
    return $c
}

# 深拷贝配置：设置窗口里的改动先落在草稿上，取消就整体丢掉
function Copy-Config {
    param($Config)
    $copy = New-DefaultConfig
    $copy['version'] = $Config['version']
    $copy['engine'] = $Config['engine']
    $copy['prompt'] = $Config['prompt']
    foreach ($k in @('maxSide', 'temperature', 'timeoutSec')) { $copy[$k] = $Config[$k] }
    foreach ($id in $Config['providers'].Keys) {
        if (-not $copy['providers'].Contains($id)) { $copy['providers'][$id] = (New-ProviderSettings -Id $id) }
        foreach ($k in $Config['providers'][$id].Keys) { $copy['providers'][$id][$k] = $Config['providers'][$id][$k] }
    }
    return $copy
}

function Get-DlgProviderId {
    $d = $script:Dlg
    if ($null -eq $d) { return 'deepseek' }
    $i = [int]$d['cboProvider'].SelectedIndex
    if ($i -lt 0 -or $i -ge $script:DlgProviderIds.Count) { return 'deepseek' }
    return [string]$script:DlgProviderIds[$i]
}

# 把界面上这份填写内容存回草稿。
# 关键：必须存回「这份数据本来属于哪个 provider」，而不是「下拉框现在选中的那个」——
# 在 SelectedIndexChanged 里，索引此时已经变成新值了，用新值存就会把上一个服务的
# Key/地址/模型整份拷进新选中的服务里（切几个就污染几个）。
function Store-FormToDraft {
    param([string]$ProviderId)
    $d = $script:Dlg
    if ($null -eq $d -or $null -eq $script:DlgDraft) { return }
    $id = $ProviderId
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [string]$script:DlgLoadedProvider }
    if ([string]::IsNullOrWhiteSpace($id) -or -not $script:DlgDraft['providers'].Contains($id)) { $id = Get-DlgProviderId }
    $ps = $script:DlgDraft['providers'][$id]
    if ($null -eq $ps) { return }
    $ps['apiKey'] = ([string]$d['txtKey'].Text).Trim()
    $ps['baseUrl'] = ([string]$d['txtBase'].Text).Trim()
    $ps['model'] = ([string]$d['txtModel'].Text).Trim()
    $ps['detail'] = [string]$d['cboDetail'].SelectedItem
    $script:DlgDraft['prompt'] = [string]$d['txtPrompt'].Text
    $script:DlgDraft['maxSide'] = [int]$d['numMaxSide'].Value
    $script:DlgDraft['timeoutSec'] = [int]$d['numTimeout'].Value
}

# 把草稿里某个 provider 的内容刷到界面上
function Load-ProviderToForm {
    param([string]$Id)
    $d = $script:Dlg
    if ($null -eq $d -or $null -eq $script:DlgDraft) { return }
    $p = Get-Provider -Id $Id
    $ps = $script:DlgDraft['providers'][$Id]
    if ($null -eq $ps) { $ps = New-ProviderSettings -Id $Id; $script:DlgDraft['providers'][$Id] = $ps }
    $baseUrl = [string]$ps['baseUrl']; if ([string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl = [string]$p['baseUrl'] }
    $model = [string]$ps['model']; if ([string]::IsNullOrWhiteSpace($model)) { $model = [string]$p['model'] }
    $d['txtBase'].Text = $baseUrl
    $d['txtModel'].Text = $model
    $d['txtKey'].Text = [string]$ps['apiKey']
    $d['cboDetail'].SelectedItem = [string]$ps['detail']
    if ($null -eq $d['cboDetail'].SelectedItem -and $d['cboDetail'].Items.Count -gt 0) { $d['cboDetail'].SelectedIndex = 0 }
    $d['numMaxSide'].Value = [decimal][Math]::Max(0, [Math]::Min(8192, [int]$script:DlgDraft['maxSide']))
    $d['numTimeout'].Value = [decimal][Math]::Max(5, [Math]::Min(300, [int]$script:DlgDraft['timeoutSec']))
    $d['txtPrompt'].Text = [string]$script:DlgDraft['prompt']
    $hint = [string]$p['note']
    if ([string]::IsNullOrWhiteSpace($hint)) { $hint = [string]$p['desc'] }
    $d['lblProviderNote'].Text = $hint
    # 记下「界面现在展示的是哪个服务」，Store-FormToDraft 靠它才知道该存回哪里
    $script:DlgLoadedProvider = $Id
}

function Update-SettingsUi {
    $d = $script:Dlg
    if ($null -eq $d) { return }
    $remote = $d['rbApi'].Checked
    $p = Get-Provider -Id (Get-DlgProviderId)
    $needsKey = [bool]$p['keyRequired']
    $hasDetail = [bool]$p['supportsDetail']
    foreach ($k in @('cboProvider', 'txtBase', 'txtModel', 'numMaxSide', 'numTimeout', 'lnkKey')) {
        if ($null -ne $d[$k]) { $d[$k].Enabled = $remote }
    }
    $d['cboDetail'].Enabled = ($remote -and $hasDetail)
    $d['txtKey'].Enabled = ($remote -and $needsKey)
    $d['chkShow'].Enabled = ($remote -and $needsKey)
    $d['txtPrompt'].Enabled = $remote
    $d['btnResetPrompt'].Enabled = $remote
    $d['btnTest'].Enabled = ($remote -and -not $script:DlgTesting)
    if ($remote) {
        $tail = $(if ($needsKey) { '（需要 API Key，截图会上传）' } else { '（不需要 Key）' })
        $d['lblEngineHint'].Text = [string]$p['name'] + '：' + [string]$p['desc'] + $tail
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
    $script:DlgDraft = Copy-Config -Config $cfg
    $script:DlgProviderIds = @((Get-ProviderCatalog).Keys | Where-Object { $_ -ne 'local' })
    $d = @{}
    $font = Get-UiFont

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '屏幕OCR助手 · 设置'
    $form.ClientSize = (New-ScaledSize 624 670)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.Font = $font
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.TopMost = $true
    $d['Form'] = $form

    [void]$form.Controls.Add((New-Label '识别引擎（截图默认走本地，可随时切到别的模型接口）' 16 12 560 -Bold))

    $rbLocal = New-Object System.Windows.Forms.RadioButton
    $rbLocal.Text = '本地识别（Windows 内置 OCR）— 离线、免费、不上传【默认】'
    $rbLocal.Location = (New-ScaledPoint 20 38)
    $rbLocal.AutoSize = $true
    $d['rbLocal'] = $rbLocal

    $rbApi = New-Object System.Windows.Forms.RadioButton
    $rbApi.Text = '接口识别（远程模型）— 上传截图，复杂排版 / 小字更准'
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

    # ---- 接口（远程模型）----
    $gbApi = New-Object System.Windows.Forms.GroupBox
    $gbApi.Text = '接口识别设置（可换成别的模型服务）'
    $gbApi.Location = (New-ScaledPoint 12 110)
    $gbApi.Size = (New-ScaledSize 600 272)
    [void]$form.Controls.Add($gbApi)

    $providerItems = @()
    foreach ($id in $script:DlgProviderIds) {
        $p = Get-Provider -Id $id
        $providerItems += ([string]$p['name'] + '  —  ' + [string]$p['desc'])
    }
    $cboProvider = New-UiCombo -Items $providerItems
    $d['cboProvider'] = $cboProvider
    [void](Add-UiRow $gbApi '识别服务' 30 $cboProvider 14 130 330)
    $lblProviderNote = New-Object System.Windows.Forms.Label
    $lblProviderNote.Location = (New-ScaledPoint 470 27)
    $lblProviderNote.AutoSize = $true
    $lblProviderNote.ForeColor = [System.Drawing.Color]::DimGray
    $d['lblProviderNote'] = $lblProviderNote
    [void]$gbApi.Controls.Add($lblProviderNote)

    $txtBase = New-UiText
    $d['txtBase'] = $txtBase
    [void](Add-UiRow $gbApi '接口地址' 60 $txtBase 14 130 450)

    $txtModel = New-UiText
    $d['txtModel'] = $txtModel
    [void](Add-UiRow $gbApi '模型' 90 $txtModel 14 130 190)
    $cboDetail = New-UiCombo -Items @('original', 'high', 'low', 'auto')
    $d['cboDetail'] = $cboDetail
    [void](Add-UiRow $gbApi '图片细节' 90 $cboDetail 336 405 175)

    $txtKey = New-UiText
    $txtKey.UseSystemPasswordChar = $true
    $d['txtKey'] = $txtKey
    [void](Add-UiRow $gbApi 'API Key' 120 $txtKey 14 130 310)

    $chkShow = New-Object System.Windows.Forms.CheckBox
    $chkShow.Text = '显示'
    $chkShow.Location = (New-ScaledPoint 452 119)
    $chkShow.AutoSize = $true
    $d['chkShow'] = $chkShow
    [void]$gbApi.Controls.Add($chkShow)

    $numMaxSide = New-UiNum -Value 1920 -Min 0 -Max 8192
    $d['numMaxSide'] = $numMaxSide
    [void](Add-UiRow $gbApi '图片最长边' 150 $numMaxSide 14 130 80)
    [void]$gbApi.Controls.Add((New-Label '像素（0 = 不压缩；超出会等比缩小后再上传）' 218 150))

    $numTimeout = New-UiNum -Value 60 -Min 5 -Max 300
    $d['numTimeout'] = $numTimeout
    [void](Add-UiRow $gbApi '超时' 180 $numTimeout 14 130 80)
    [void]$gbApi.Controls.Add((New-Label '秒（单次请求）' 218 180))

    $lnkKey = New-Object System.Windows.Forms.LinkLabel
    $lnkKey.Text = '→ 点这里打开当前识别服务的 Key 申请页 / 模型列表'
    $lnkKey.Location = (New-ScaledPoint 130 210)
    $lnkKey.AutoSize = $true
    $d['lnkKey'] = $lnkKey
    [void]$gbApi.Controls.Add($lnkKey)

    [void]$gbApi.Controls.Add((New-Label 'Key 只保存在本机配置文件里，不会发给除上面接口地址以外的任何地方。' 14 238))

    # ---- 提示词 ----
    $gbPrompt = New-Object System.Windows.Forms.GroupBox
    $gbPrompt.Text = '上下文提示词（写给模型的要求；仅接口引擎生效，可自行修改）'
    $gbPrompt.Location = (New-ScaledPoint 12 390)
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
    $lblStatus.Location = (New-ScaledPoint 16 582)
    $lblStatus.Size = (New-ScaledSize 596 20)
    $lblStatus.AutoEllipsis = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $d['lblStatus'] = $lblStatus
    [void]$form.Controls.Add($lblStatus)

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = '测试接口'
    $btnTest.Location = (New-ScaledPoint 302 610)
    $btnTest.Size = (New-ScaledSize 100 32)
    $d['btnTest'] = $btnTest
    [void]$form.Controls.Add($btnTest)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = '保存并关闭'
    $btnSave.Location = (New-ScaledPoint 408 610)
    $btnSave.Size = (New-ScaledSize 110 32)
    $d['btnSave'] = $btnSave
    [void]$form.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = (New-ScaledPoint 524 610)
    $btnCancel.Size = (New-ScaledSize 88 32)
    $d['btnCancel'] = $btnCancel
    [void]$form.Controls.Add($btnCancel)

    # ---- 事件 ----
    $form.AcceptButton = $btnSave
    $form.CancelButton = $btnCancel

    $rbLocal.add_CheckedChanged({ Update-SettingsUi })
    $rbApi.add_CheckedChanged({ Update-SettingsUi })
    $cboProvider.add_SelectedIndexChanged({
        # 初始化期间不让它跑：那时界面还没装数据，存进去等于把值清空
        if ($script:DlgLoading) { return }
        # 先把界面这份存回「它原本属于的」provider，再加载新选中的
        Store-FormToDraft -ProviderId $script:DlgLoadedProvider
        Load-ProviderToForm -Id (Get-DlgProviderId)
        Update-SettingsUi
    })
    $chkShow.add_CheckedChanged({
        $d = $script:Dlg
        if ($null -ne $d) { $d['txtKey'].UseSystemPasswordChar = -not $d['chkShow'].Checked }
    })
    $lnkKey.add_LinkClicked({
        $p = Get-Provider -Id (Get-DlgProviderId)
        $url = [string]$p['keyUrl']
        if ([string]::IsNullOrWhiteSpace($url)) { Set-SettingsStatus '这个服务没有预设链接，请直接填接口地址。'; return }
        try { Start-Process $url } catch { }
    })
    $btnResetPrompt.add_Click({
        $d = $script:Dlg
        if ($null -ne $d) { $d['txtPrompt'].Text = Get-DefaultPrompt }
    })
    $btnCancel.add_Click({ $script:DlgForm.Close() })

    $btnTest.add_Click({
        if ($null -eq $script:Dlg) { return }
        Store-FormToDraft
        if ($null -eq (Read-SettingsForm -Silent)) { return }
        # 用界面上正在编辑的那份配置去测，不动已保存的配置
        $saved = $script:Config
        $script:Config = Copy-Config -Config $script:DlgDraft
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
        $script:Config = $saved
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

    # 打开时定位到当前引擎：radio + 服务下拉框 + 该服务自己的设置。
    # 这一段全程上锁（DlgLoading），避免 SelectedIndex 变化触发的事件把还没装载的
    # 空界面当成用户输入存回草稿。
    $script:DlgLoading = $true
    $engineId = [string]$cfg['engine']
    if ($engineId -eq 'local') {
        $rbLocal.Checked = $true
    } else {
        $rbApi.Checked = $true
        $idx = [Array]::IndexOf($script:DlgProviderIds, $engineId)
        if ($idx -lt 0) { $idx = 0 }
        $cboProvider.SelectedIndex = $idx
    }
    $script:DlgLoadedProvider = Get-DlgProviderId
    Load-ProviderToForm -Id $script:DlgLoadedProvider
    Update-SettingsUi
    $script:DlgLoading = $false

    try { $form.Show() } catch { }
    try { $form.Activate(); $form.BringToFront() } catch { }
}

# 校验设置窗口里的内容；-Silent 时不弹错误框，只返回 $null
function Read-SettingsForm {
    param([switch]$Silent)
    $d = $script:Dlg
    if ($null -eq $d) { return $null }
    Store-FormToDraft
    $cfg = Copy-Config -Config $script:DlgDraft
    if ($d['rbApi'].Checked) { $cfg['engine'] = Get-DlgProviderId } else { $cfg['engine'] = 'local' }

    if ([string]::IsNullOrWhiteSpace([string]$cfg['prompt'])) {
        if ($Silent) { return $null }
        [void][System.Windows.Forms.MessageBox]::Show('提示词不能为空（可点「恢复默认提示词」）。', '还差一步', 'OK', 'Warning')
        return $null
    }

    $id = [string]$cfg['engine']
    if ($id -ne 'local') {
        $p = Get-Provider -Id $id
        $ps = $cfg['providers'][$id]
        if ([string]::IsNullOrWhiteSpace([string]$ps['baseUrl'])) { $ps['baseUrl'] = [string]$p['baseUrl'] }
        if ([string]::IsNullOrWhiteSpace([string]$ps['model'])) { $ps['model'] = [string]$p['model'] }
        if ([string]::IsNullOrWhiteSpace([string]$ps['baseUrl']) -or [string]::IsNullOrWhiteSpace([string]$ps['model'])) {
            if ($Silent) { return $null }
            [void][System.Windows.Forms.MessageBox]::Show('还没填接口地址或模型名。', '还差一步', 'OK', 'Warning')
            return $null
        }
        if ([bool]$p['keyRequired'] -and [string]::IsNullOrWhiteSpace([string]$ps['apiKey'])) {
            if ($Silent) { return $null }
            [void][System.Windows.Forms.MessageBox]::Show(('选了 ' + [string]$p['name'] + ' 但 API Key 还是空的。请填入 Key，或改回本地引擎。'), '还差一步', 'OK', 'Warning')
            return $null
        }
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
    $label = [string]$engine['Provider']['name']
    # 只有托盘在跑的时候才做「自动接入」测速（独立打开设置窗口时没有气泡可显示）
    if ($engine['Active'] -ne 'local' -and $null -ne $script:Notify) {
        # 填完 Key 自动接入：后台真跑一次识别，结果用托盘气泡回报
        $started = Start-ConfigProbe -OnDone {
            param($r)
            $cur = [string](Resolve-Engine)['Provider']['name']
            if ($null -ne $r -and $r['Ok']) {
                Show-NotifyBalloon ('已接入 ' + $cur) ('接口测试通过（' + [int]$r['ElapsedMs'] + ' ms），之后 Alt+R 就走接口识别。配置：' + (Get-RecognitionContext)['baseUrl']) 'Info'
            } else {
                $msg = '未知错误'
                if ($null -ne $r -and $r['Error']) { $msg = [string]$r['Error'] }
                Show-NotifyBalloon ($cur + ' 接入失败') ($msg + '　（Alt+R+S 可回去检查 Key / 接口地址）') 'Error'
            }
        }
        if ($started) {
            Show-NotifyBalloon '设置已保存' ('已切到 ' + $label + '，正在后台测试接口连接…') 'Info'
        } else {
            Show-NotifyBalloon '设置已保存' ('已切到 ' + $label + '（接口测试被其他任务占用，稍后 Alt+R 时会真正调用）。') 'Info'
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
# 请求退出：只负责让消息循环停下来，**不销毁任何东西**。
# 托盘菜单项自己的点击处理里不能顺手 Dispose 掉那个菜单：ToolStrip 收尾时
# 会碰到已释放的对象，抛出的异常在消息循环里没人接，就变成 .NET 报错框。
# 真正的销毁交给 Application.Run() 返回之后的 Invoke-Exit。
function Request-Exit {
    try { if ($null -ne $script:ExitTimer) { $script:ExitTimer.Stop() } } catch { }
    $script:ExitTimer = New-Object System.Windows.Forms.Timer
    $script:ExitTimer.Interval = 60
    $script:ExitTimer.add_Tick({
        try { $script:ExitTimer.Stop() } catch { }
        try { [System.Windows.Forms.Application]::Exit() } catch { }
    })
    $script:ExitTimer.Start()
}

# 真正的清理，只在消息循环结束后调用
function Invoke-Exit {
    try { if ($null -ne $script:ExitTimer) { $script:ExitTimer.Stop() } } catch { }
    try { if ($null -ne $script:ApiTimer) { $script:ApiTimer.Stop() } } catch { }
    try { if ($null -ne $script:ClipTimer) { $script:ClipTimer.Stop() } } catch { }
    try { if ($null -ne $script:CfgWatch) { $script:CfgWatch.Stop() } } catch { }
    try { if ($null -ne $script:ApiJob) { Remove-Job -Job $script:ApiJob['Job'] -Force -ErrorAction SilentlyContinue } } catch { }
    try { if ($null -ne $script:Chord) { $script:Chord.Uninstall() } } catch { }
    try { if ($script:Notify) { $script:Notify.Visible = $false; $script:Notify.Dispose() } } catch { }
    try { if ($script:HotkeyWin) { $script:HotkeyWin.UnregisterHotkey($script:HK_ID_REGION); $script:HotkeyWin.Shutdown() } } catch { }
    try { [System.Windows.Forms.Application]::Exit() } catch { }
}

# 界面线程兜底：任何漏网的异常都只写日志，绝不弹 .NET 报错框
# （这是个后台托盘程序，弹框比出错本身更讨厌）
function Install-ExceptionGuard {
    try {
        [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
        [System.Windows.Forms.Application]::add_ThreadException([System.Threading.ThreadExceptionEventHandler]{
            param($sender, $e)
            Write-DiagLog ('界面线程未处理异常：' + $e.Exception.ToString())
        })
        [System.AppDomain]::CurrentDomain.add_UnhandledException([System.UnhandledExceptionEventHandler]{
            param($sender, $e)
            Write-DiagLog ('未处理异常：' + $e.ExceptionObject.ToString())
        })
    } catch { }
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

    # 剪贴板被占用时，用这个一键重试（文字一直留在内存里）
    $miRecopy = New-Object System.Windows.Forms.ToolStripMenuItem('复制上次识别结果')
    $miRecopy.add_Click({
        if ([string]::IsNullOrEmpty($script:LastOcrText)) {
            Show-NotifyBalloon '还没有内容' '先用 Alt+R 识别一次文字。' 'Info'
            return
        }
        [void](Start-ClipboardDelivery -Text $script:LastOcrText -Suffix '（上次结果）')
    })
    [void]$menu.Items.Add($miRecopy)
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

    # 引擎切换做成子菜单：本地 + 目录里的每个远程服务，直接点选，不用进设置窗口
    $miMode = New-Object System.Windows.Forms.ToolStripMenuItem('识别引擎')
    [void]$miMode.DropDownItems.Add((New-EngineMenuItem -Id 'local' -Text '本地 OCR'))
    [void]$miMode.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    foreach ($provId in (Get-ProviderCatalog).Keys) {
        if ($provId -eq 'local') { continue }
        [void]$miMode.DropDownItems.Add((New-EngineMenuItem -Id $provId -Text ([string](Get-Provider -Id $provId)['name'])))
    }
    [void]$menu.Items.Add($miMode)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miExit = New-Object System.Windows.Forms.ToolStripMenuItem('退出')
    $miExit.add_Click({ Request-Exit })
    [void]$menu.Items.Add($miExit)

    # 注意：下面这些引用必须放 $script: 作用域。Build-TrayUi 早就返回了，
    # 事件处理器运行时函数局部变量已经不存在（取到 $null），而 Opening 里的异常
    # 发生在消息循环内，try/catch 抓不到，默认就会弹一个 .NET 报错框。
    $script:MenuEngine = $miMode
    $script:MenuRecopy = $miRecopy
    $script:MenuExitItem = $miExit
    $menu.add_Opening({
        try {
            $active = [string](Resolve-Engine)['Active']
            $script:MenuEngine.Text = '识别引擎：' + (Get-EngineLabel)
            # 子菜单里每一项都带 Tag（含「本地 OCR」），统一在这里打勾
            foreach ($mi in $script:MenuEngine.DropDownItems) {
                if ($null -ne $mi.Tag) { $mi.Checked = ([string]$mi.Tag -eq $active) }
            }
            $script:MenuRecopy.Enabled = (-not [string]::IsNullOrEmpty($script:LastOcrText))
        } catch {
            # 菜单刷新只是锦上添花，出问题也不能影响弹菜单
            Write-DiagLog ('托盘菜单刷新失败：' + $_.Exception.Message)
        }
    })
    $script:Notify.ContextMenuStrip = $menu
}

# 收一个带 id 的菜单项；用强类型委托拿 sender，避免闭包变量被最后一项覆盖
function New-EngineMenuItem {
    param([string]$Id, [string]$Text)
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
    $mi.Tag = $Id
    $mi.add_Click([System.EventHandler]{
        param($sender, $e)
        Set-ActiveEngine -Id ([string]$sender.Tag)
    })
    return $mi
}

# 切换当前引擎并落盘（供托盘菜单使用）
function Set-ActiveEngine {
    param([string]$Id)
    if (-not (Test-ProviderId -Id $Id)) { return }
    $script:Config['engine'] = $Id
    try { [void](Export-Config -Config $script:Config) } catch { }
    $eng = Resolve-Engine
    Update-TrayText
    $tail = ''
    if ($eng['Fallback'] -eq 'missing-key') { $tail = '（还没填 API Key，会先用本地识别；按 Alt+R+S 填）' }
    # 切到本地时顺手把 OCR 环境准备好，缺语言包就当场告诉用户，别等按 Alt+R 才发现
    if ($eng['Active'] -eq 'local' -and -not (Ensure-LocalOcr)) { $tail = '（本地 OCR 不可用：系统里没有 OCR 语言包）' }
    Show-NotifyBalloon '已切换引擎' ('当前：' + (Get-EngineLabel -Engine $eng) + $tail) 'Info'
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
    Install-ExceptionGuard

    # 本地 OCR 环境启动就准备好（原来就是这样，第一次按 Alt+R 才不会卡一下）。
    # 但只有当前引擎真的是本地时，初始化失败才需要提醒 —— 用接口引擎的话无所谓，
    # 而且切到本地时 Invoke-RegionOcr 里还有 Ensure-LocalOcr 兜底。
    $localOcrOk = $false
    try { $localOcrOk = [bool](Initialize-OcrEnvironment) } catch { $localOcrOk = $false }
    $engine = Resolve-Engine
    if (-not $localOcrOk -and $engine['Active'] -eq 'local') {
        Write-Warning '本地 OCR 初始化失败（缺少识别语言包），可改用接口引擎（Alt+R+S）。'
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
        $smokeTimer.add_Tick({ $smokeTimer.Stop(); Request-Exit })
        $smokeTimer.Start()
    }

    try { [System.Windows.Forms.Application]::Run() }
    catch { Write-Output ('GUISMOKE-CRASH ' + $_.Exception.ToString()) }
    Invoke-Exit   # 真正的清理都在消息循环之后做
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
# 剪贴板自检：分别验 WinForms 和原生 Win32 两条写入通路
# 跑一项剪贴板写入检查：写入 -> 用原生读回 -> （可选）再用 OLE 读回
function Test-ClipboardRoundTrip {
    param([string]$Name, [string]$Text, [switch]$CheckOle)
    $result = @{ Name = $Name; Ok = $false; Info = '' }
    try {
        $r = Set-ClipboardText -Text $Text -Attempts 3
        if (-not $r['Ok']) { $result.Info = $r['Error']; return $result }
        $result.Info = 'via=' + $r['Via']
        $back = [ImgOcrNative.Clip]::GetText()
        if ($back -ne $Text) {
            $len = $(if ($null -eq $back) { 'null' } else { [string]$back.Length })
            $result.Info = $result.Info + ' 回读不一致(len=' + $len + ')'
            return $result
        }
        if ($CheckOle) {
            try {
                $viaOle = [System.Windows.Forms.Clipboard]::GetText()
                if ($viaOle -ne $Text) { $result.Info = $result.Info + ' OLE 回读不一致'; return $result }
                $result.Info = $result.Info + '，Win32+OLE 都能读'
            } catch { $result.Info = $result.Info + '（OLE 读取失败：' + $_.Exception.Message + '）' }
        }
        $result.Ok = $true
    } catch { $result.Info = $_.Exception.Message }
    return $result
}

function Invoke-ClipboardTest {
    Write-Output ('CLIPTEST sta=' + [System.Threading.Thread]::CurrentThread.GetApartmentState())
    $stamp = 'IMGOCR-CLIP-' + (Get-Date).ToString('HHmmss')
    $pass = 0; $fail = 0

    # 裸探针：只试一次，不带重试。失败不算问题 —— 说明别的程序（微信、剪贴板工具、
    # 远程桌面等）恰好在这一瞬间占着剪贴板，这正是要重试的原因。
    $wfRaw = 'OK'
    try { [System.Windows.Forms.Clipboard]::SetText($stamp + '-WF-RAW') }
    catch { $wfRaw = '被占用(' + $_.Exception.Message + ')' }
    Write-Output ('CLIPTEST raw-winforms-single-try=' + $wfRaw + '   [仅参考，不判定成败]')

    $ntRaw = 'OK'
    try {
        $e = [ImgOcrNative.Clip]::SetText($stamp + '-NT-RAW')
        if ($null -ne $e) { $ntRaw = '被占用(' + $e + ')' }
    } catch { $ntRaw = '被占用(' + $_.Exception.Message + ')' }
    Write-Output ('CLIPTEST raw-win32-single-try=' + $ntRaw + '    [仅参考，不判定成败]')

    # 实际使用的策略（带重试）—— 这几项才算成败
    $cn = [string]::Join('', [char[]](0x7B2C, 0x4E8C, 0x884C, 0xFF1A, 0x4FDD, 0x7559, 0x6362, 0x884C))
    $cases = @(
        @{ name = 'strategy-retry'; text = ($stamp + '-STRATEGY'); ole = $true },
        @{ name = 'multiline-cn';  text = "OCR TEST 12345`r`n$cn`r`nEnd line three"; ole = $false },
        @{ name = 'large-text';    text = (('IMGOCR-BIG-' + $stamp + "`r`n") * 2000); ole = $false }
    )
    foreach ($c in $cases) {
        $r = Test-ClipboardRoundTrip -Name $c['name'] -Text $c['text'] -CheckOle:$c['ole']
        if ($r['Ok']) { $pass++ } else { $fail++ }
        $extra = ''
        if ($c['name'] -eq 'large-text') { $extra = 'len=' + ([string]$c['text']).Length + ' ' }
        Write-Output ('CLIPTEST ' + $c['name'] + '=' + $(if ($r['Ok']) { 'OK ' } else { 'FAIL ' }) + $extra + $r['Info'])
    }

    # 当前剪贴板里是什么（判断是不是被别的程序接管了）
    $cur = [ImgOcrNative.Clip]::GetText()
    if ($null -eq $cur) { Write-Output 'CLIPTEST current=<非文本或读不到>' }
    else {
        $show = $cur
        if ($show.Length -gt 60) { $show = $show.Substring(0, 60) + '...' }
        Write-Output ('CLIPTEST current=[' + ($show -replace "`r?`n", ' | ') + '] len=' + $cur.Length)
    }

    Write-Output ('CLIPTEST result pass=' + $pass + ' fail=' + $fail + $(if ($fail -eq 0) { '  => 写入没问题' } else { '  => 请看上面的错误' }))
    if ($wfRaw -ne 'OK' -or $ntRaw -ne 'OK') {
        Write-Output 'CLIPTEST note=裸探针失败说明有程序在抢剪贴板（微信/剪贴板工具最常见）；工具本身会重试，所以不影响使用。'
    }
    Write-Output 'CLIPTEST-DONE'
}

# 退出路径自检：真的把托盘菜单弹出来、用键盘选中「退出」再回车。
# 目的是抓「消息循环里的未处理异常」—— 这种异常 try/catch 抓不到，
# 默认行为就是弹一个 .NET 报错对话框（用户看到的就是这个）。
function Invoke-ExitTest {
    Write-Output 'EXITTEST-START'
    $script:ExitTestLog = New-Object System.Collections.ArrayList
    $script:ExitTestFail = 0

    # 先装兜底，并把异常记下来（正式运行时这里是写日志、不弹框）
    try {
        [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
        [System.Windows.Forms.Application]::add_ThreadException([System.Threading.ThreadExceptionEventHandler]{
            param($sender, $e)
            $script:ExitTestFail++
            [void]$script:ExitTestLog.Add('未处理异常 ' + $e.Exception.GetType().FullName + ' :: ' + $e.Exception.Message)
            if ($null -ne $e.Exception.StackTrace) { [void]$script:ExitTestLog.Add(($e.Exception.StackTrace -split "`n")[0]) }
        })
    } catch { [void]$script:ExitTestLog.Add('装兜底失败: ' + $_.Exception.Message) }

    [void][ImgOcrNative.Dpi]::MakeAware()
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
    $script:Config = Import-Config
    $script:Busy = $false
    $script:Chord = New-Object ImgOcrNative.KeyChord
    $script:Chord.add_OcrRequested({ })
    $script:Chord.add_SettingsRequested({ })
    [void]$script:Chord.Install()
    Build-TrayUi

    $t1 = New-Object System.Windows.Forms.Timer
    $t1.Interval = 1800
    $t1.add_Tick({
        $t1.Stop()
        try {
            # 先把鼠标挪到屏幕中间再弹菜单：贴边时菜单会自己翻转位置，
            # 算出来的点击坐标就偏了（这个是自检本身的坑，不是程序的）
            [System.Windows.Forms.Cursor]::Position = (New-Object System.Drawing.Point(700, 500))
            Start-Sleep -Milliseconds 200
            $script:Notify.ContextMenuStrip.Show([System.Windows.Forms.Cursor]::Position)
            [void]$script:ExitTestLog.Add('托盘菜单已弹出')
        } catch {
            $ex = $_.Exception
            $msg = '弹菜单失败: ' + $ex.GetType().FullName + ' :: ' + $ex.Message
            if ($null -ne $ex.InnerException) { $msg = $msg + ' | inner: ' + $ex.InnerException.GetType().FullName + ' :: ' + $ex.InnerException.Message }
            [void]$script:ExitTestLog.Add($msg)
            if ($_.ScriptStackTrace) { [void]$script:ExitTestLog.Add('stack: ' + ($_.ScriptStackTrace -replace "`r?`n", ' <- ')) }
        }
    })
    $t1.Start()

    $t2 = New-Object System.Windows.Forms.Timer
    $t2.Interval = 3000
    $t2.add_Tick({
        $t2.Stop()
        try {
            # 先确认 Opening 处理器真的跑成功了（这正是当初会抛未处理异常的地方）
            if ($null -eq $script:MenuEngine -or [string]::IsNullOrWhiteSpace([string]$script:MenuEngine.Text)) {
                $script:ExitTestFail++
                [void]$script:ExitTestLog.Add('菜单标题没被刷新，Opening 处理器可能又挂了')
            } else {
                [void]$script:ExitTestLog.Add('菜单标题=' + [string]$script:MenuEngine.Text + '，复制上次结果 enabled=' + [string]$script:MenuRecopy.Enabled)
            }
            $mi = $script:MenuExitItem
            $menu = $script:Notify.ContextMenuStrip
            # 先试注入真实点击（最贴近用户操作）；注入偶尔不生效就退化为直接触发菜单项，
            # 两者走的是同一个 Click 处理器，退出逻辑一样会被执行到。
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                if ($null -ne $script:ExitTimer) { break }
                if ($null -ne $mi -and $null -ne $menu -and $menu.Visible) {
                    $pt = $menu.RectangleToScreen($mi.Bounds)
                    $cx = $pt.X + [int]($pt.Width / 2)
                    $cy = $pt.Y + [int]($pt.Height / 2)
                    [void]$script:ExitTestLog.Add('第 ' + $attempt + ' 次：在 (' + $cx + ',' + $cy + ') 注入真实点击「退出」')
                    [ImgOcrNative.Mouse]::ClickAt($cx, $cy)
                }
                Start-Sleep -Milliseconds 700
            }
            if ($null -eq $script:ExitTimer) {
                [void]$script:ExitTestLog.Add('注入点击未生效，改为直接触发菜单项（同一个 Click 处理器）')
                $mi.PerformClick()
                Start-Sleep -Milliseconds 500
            }
            if ($null -ne $script:ExitTimer) {
                [void]$script:ExitTestLog.Add('菜单「退出」已触发（Request-Exit 执行完成）')
            } else {
                $script:ExitTestFail++
                [void]$script:ExitTestLog.Add('「退出」没能触发')
            }
        } catch { [void]$script:ExitTestLog.Add('点击失败: ' + $_.Exception.Message) }
    })
    $t2.Start()

    $t3 = New-Object System.Windows.Forms.Timer
    $t3.Interval = 12000
    $t3.add_Tick({
        $t3.Stop()
        [void]$script:ExitTestLog.Add('超时兜底：仍在运行，强制退出')
        $script:ExitTestFail++
        Request-Exit
    })
    $t3.Start()

    try { [System.Windows.Forms.Application]::Run() }
    catch { [void]$script:ExitTestLog.Add('Run 抛出: ' + $_.Exception.Message) }
    Invoke-Exit
    foreach ($l in $script:ExitTestLog) { Write-Output ('EXITTEST ' + $l) }
    Write-Output ('EXITTEST result fail=' + $script:ExitTestFail)
    Write-Output 'EXITTEST-DONE'
}

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
    $x = 0x58

    # 表驱动：keys = @(键码, 是否按下)，wantOcr/wantSet = 期望触发次数
    $cases = @(
        @{ name = '按住Alt -> R -> 松开Alt';          keys = @(@($alt, $true), @($r, $true), @($r, $false), @($alt, $false)); wantOcr = 1; wantSet = 0 },
        @{ name = '按住Alt -> R -> S -> 松开';        keys = @(@($alt, $true), @($r, $true), @($s, $true), @($s, $false), @($r, $false), @($alt, $false)); wantOcr = 0; wantSet = 1 },
        @{ name = '按住Alt -> R -> 其他键 -> 松开';   keys = @(@($alt, $true), @($r, $true), @($x, $true), @($x, $false), @($alt, $false)); wantOcr = 0; wantSet = 0 },
        @{ name = '不按Alt 直接按 R / S';             keys = @(@($r, $true), @($r, $false), @($s, $true), @($s, $false)); wantOcr = 0; wantSet = 0 },
        @{ name = '连续两次 Alt+R';                   keys = @(@($alt, $true), @($r, $true), @($r, $false), @($alt, $false), @($alt, $true), @($r, $true), @($r, $false), @($alt, $false)); wantOcr = 2; wantSet = 0 }
    )
    $fail = 0
    $i = 0
    foreach ($c in $cases) {
        $i++
        $script:ChordOcrHits = 0
        $script:ChordSetHits = 0
        foreach ($k in $c['keys']) { $chord.SimulateKey([int]$k[0], [bool]$k[1]) }
        $ok = ($script:ChordOcrHits -eq $c['wantOcr'] -and $script:ChordSetHits -eq $c['wantSet'])
        if (-not $ok) { $fail++ }
        Write-Output ('CHORDTEST case' + $i + ' ' + $c['name'] + ' => ocr=' + $script:ChordOcrHits + ' set=' + $script:ChordSetHits + ' ' + $(if ($ok) { 'OK' } else { 'FAIL(期望 ocr=' + $c['wantOcr'] + ' set=' + $c['wantSet'] + ')' }))
    }
    Write-Output ('CHORDTEST result fail=' + $fail)
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
    $eng = Resolve-Engine
    $ctx = Get-RecognitionContext
    Write-Output ('APITEST engine=' + (Get-EngineLabel -Engine $eng) + ' (' + [string]$ctx['providerId'] + '/' + [string]$ctx['shape'] + ')')
    Write-Output ('APITEST baseUrl=' + [string]$ctx['baseUrl'])
    Write-Output ('APITEST model=' + [string]$ctx['model'])
    Write-Output ('APITEST key=' + $(if ([string]::IsNullOrWhiteSpace([string]$ctx['apiKey'])) { '<empty>' } else { '<set,len=' + ([string]$ctx['apiKey']).Length + '>' }))
    $img = New-TestImagePng
    # 故意走和 Alt+R 完全相同的后台任务链路（Start-Job + 定时器轮询 + 回调），
    # 这样这个自检就真的在验证生产路径，而不是另写一条捷径。
    $script:ApiTestResult = $null
    $hard = [int]$script:Config['timeoutSec'] + 30
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
    $eng = Resolve-Engine
    $ctx = Get-RecognitionContext
    $key = [string]$ctx['apiKey']
    $masked = '<empty>'
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        if ($key.Length -le 8) { $masked = '****' } else { $masked = $key.Substring(0, 4) + '****' + $key.Substring($key.Length - 4) }
    }
    Write-Output ('CONFIG path=' + (Get-ConfigPath))
    Write-Output ('CONFIG exists=' + (Test-Path -LiteralPath (Get-ConfigPath)))
    Write-Output ('CONFIG version=' + [string]$cfg['version'])
    Write-Output ('CONFIG engine=' + [string]$cfg['engine'] + ' -> ' + (Get-EngineLabel -Engine $eng) + ' active=' + [string]$eng['Active'] + $(if ($eng['Fallback']) { ' fallback=' + [string]$eng['Fallback'] } else { '' }))
    Write-Output ('CONFIG provider=' + [string]$ctx['providerId'] + ' shape=' + [string]$ctx['shape'])
    Write-Output ('CONFIG baseUrl=' + [string]$ctx['baseUrl'])
    Write-Output ('CONFIG model=' + [string]$ctx['model'])
    Write-Output ('CONFIG detail=' + [string]$ctx['detail'] + ' maxSide=' + [string]$ctx['maxSide'] + ' timeout=' + [string]$ctx['timeoutSec'])
    Write-Output ('CONFIG apiKey=' + $masked)
    Write-Output ('CONFIG providers-configured=' + (@($cfg['providers'].Keys | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$cfg['providers'][$_]['apiKey']) }) -join ','))
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
        Write-Output ('config-engine=' + [string]$script:Config['engine'] + ' -> ' + (Get-EngineLabel))
        return
    }
    if ($ShowConfig) { Show-CurrentConfig; return }
    if ($SelfTest) { Invoke-OcrSelfTest; return }
    if ($ApiSelfTest) { Invoke-ApiSelfTest; return }
    if ($ClipboardTest) { Invoke-ClipboardTest; return }
    if ($ChordTest) { Invoke-ChordTest; return }
    if ($ChordTestLive) { Invoke-ChordTestLive; return }
    if ($OverlayTest) {
        [void][ImgOcrNative.Dpi]::MakeAware()
        $b = [ImgOcrNative.ScreenCapture]::SelectRegion()
        Write-Output ('OVERLAY-RESULT=' + $(if ($null -ne $b) { 'bitmap' } else { 'cancelled' }))
        return
    }
    if ($SmokeTest) { Invoke-SmokeTest; return }
    if ($ExitTest) { Invoke-ExitTest; return }
    if ($Settings) { Start-SettingsOnly; return }
    Start-Assistant -GuiSmoke:$GuiSmoke
}
catch {
    Write-Output ('FATAL ' + $_.Exception.ToString())
    throw
}
