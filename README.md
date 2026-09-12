# 屏幕OCR助手

按 `Alt + R` → 框选屏幕上任意区域 → 识别 → 文字自动复制到剪贴板 → 托盘气泡提示。
按 `Alt + R + S` → 打开设置窗口，切换识别引擎 / 填 API Key / 改提示词。

## 两种识别引擎

| 引擎 | 说明 | 是否需要联网 |
| --- | --- | --- |
| **本地**（默认） | Windows 10/11 内置 OCR（`Windows.Media.Ocr`）。离线、免费、不上传。 | 否 |
| **DeepSeek** | 把截图发到 DeepSeek 多模态接口（OpenAI 兼容 `/chat/completions` + `image_url`），复杂排版、小字、表格更准。需要自己填 API Key。 | 是 |

开箱即用是**本地**引擎，不需要任何配置；想换成接口识别，按 `Alt + R + S` 填 Key 即可。

## 使用

1. 双击 `start-assistant.cmd` 启动（托盘出现放大镜图标）。
2. 按 **`Alt + R`**，鼠标框选屏幕区域（Esc 取消）。
3. 松开鼠标即识别，文字进剪贴板，直接 Ctrl+V 粘贴。
   - 双击托盘图标 / 托盘右键 →「框选屏幕区域识别文字」效果相同。

### 设置窗口：`Alt + R + S`

按住 `Alt`，先按 `R`，再按 `S`。（也可以直接托盘右键 →「设置…」）

窗口里可以改：

- **识别引擎**：本地 / DeepSeek 二选一。
- **接口地址**：默认 `https://api.deepseek.com`。任何 OpenAI 兼容的多模态接口都能填（会自动补 `/chat/completions`）。
- **模型**：默认 `deepseek-flash`（DeepSeek 目前支持图片输入的模型）。
- **API Key**：填进去点「保存并关闭」就**自动接入** —— 保存后程序会在后台拿一张测试图真跑一次识别，成功会弹托盘气泡「已接入 DeepSeek」，失败会弹出具体错误（Key 无效 / 网络不通 / 模型不支持图片）。
  - 在 Key 输入框里直接按回车 = 保存并接入。
  - 「显示」勾选后可以看到明文。
- **图片细节**：`original` / `high` / `low` / `auto`，传给接口的 `detail` 字段。
- **图片最长边**：上传前等比压缩到该像素数（默认 1920，填 0 = 不压缩）。
- **超时**：单次请求超时秒数。
- **上下文提示词**：写给模型的要求，**默认已经包含**下面这些约束，可以直接改：

  ```
  你是 OCR 文字提取工具：从图片中提取全部可见文字。
  必须严格遵守以下规则：
  1. 只输出提取到的文字本身，不要任何解释、说明、前言、总结、寒暄或“以下是”之类的话。
  2. 不要使用 Markdown 格式：不要出现 #、*、**、`、```、>、[]( )、| 表格等标记。
  3. 严格保留原文的换行与段落结构：该换行就换行，不要把多行合并成一行，也不要自行拆分。
  4. 不要翻译、不要改写、不要纠错、不要补全、不要增删标点；保持原文语言、大小写与数字。
  5. 按原文阅读顺序输出（多栏排版按栏依次输出）。
  6. 辨认不清的字用「□」占位。
  7. 如果图片里没有任何文字，只输出：（无文字）
  ```

- 「测试接口」按钮：不保存也能先测，会拿一张写着 `OCR TEST 12345` 的测试图真跑一次，把识别结果显示在窗口底部。

### 托盘右键菜单

- 框选屏幕区域识别文字（Alt+R）
- 设置…（Alt+R+S）
- 复制上次识别结果（剪贴板被占用时，用这个一键重试）
- 打开配置文件所在文件夹
- 识别引擎：本地 OCR / DeepSeek 接口（快速切换，不用开设置窗口）
- 退出

## 剪贴板写不进去怎么办

Windows 的剪贴板是**独占**的：任何程序在打开剪贴板的那一刻（读或写），别的程序都进不去，`OpenClipboard` 会返回
`ACCESS_DENIED(5)`，.NET 则报 `Requested Clipboard operation did not succeed`。微信、各种剪贴板工具、
远程桌面、Office 这类会**主动盯着剪贴板**的程序，都很容易在你要复制的那一瞬间正好占着它。
这不是本工具的 bug，但可以绕过：

工具现在的做法是：

1. 先用原生 Win32 通路写（不走 OLE，失败会立刻返回，不会卡住热键），连试 3 次；
2. 还不行就走一次 OLE 通路（它自身带约 1 秒的重试）；
3. 还不行就交给定时器，每 0.4 秒再试一次，最多再试 25 次（约 10 秒）—— **这一步在消息循环里跑，不会卡住 Alt+R**；
4. 全部失败才会放弃，并把文字存到 `%APPDATA%\ImgOcrAssistant\last-ocr.txt`，气泡里会告诉你路径。

期间托盘气泡会提示「正在重试复制」/「已复制（重试 N 次后成功）」。文字在内存里也一直保留着，
随时可以点托盘菜单「复制上次识别结果」再试一次（比如关掉微信之后）。

诊断：`-ClipboardTest` 会分别验裸通路、带重试的通路、多行中文、6 万字大文本，
并把结果和当前剪贴板内容打出来。注意里面 `raw-*-single-try` 两项是**只试一次的裸探针**，
它们失败是正常的（说明有程序在抢剪贴板），不算工具的毛病。

历史记录（出问题时的原因、重试次数、耗时）在 `%APPDATA%\ImgOcrAssistant\imgocr.log`。

## 配置文件

`%APPDATA%\ImgOcrAssistant\config.json`（可用环境变量 `IMGO_CFG` 指定别的路径）：

```json
{
  "version": 1,
  "engine": "local",
  "prompt": "……（上下文提示词）……",
  "deepseek": {
    "apiKey": "",
    "baseUrl": "https://api.deepseek.com",
    "model": "deepseek-flash",
    "detail": "original",
    "maxSide": 1920,
    "temperature": 0,
    "timeoutSec": 60
  }
}
```

- API Key 是明文存在这个文件里的，**注意保密**，别把它连同文件一起发出去。
- 程序运行中会监视这个文件，外部改动（比如手动编辑、或另开一个设置窗口保存）会被自动重新加载。
- `-ShowConfig` 可以打印当前配置（Key 会打码）。

## 开机自启

- 双击 `register-autostart.cmd` 添加；`unregister-autostart.cmd` 取消。

## 命令行开关

```
-Settings        只打开设置窗口（不启动托盘）
-ShowConfig      打印当前配置（API Key 打码）
-CheckOcr        检查本地 OCR 是否可用 + 当前生效引擎
-ClipboardTest   剪贴板写入自检（裸通路 / 带重试通路 / 中文 / 大文本）
-SelfTest        本地 OCR 自检（会验证换行是否保留）
-ApiSelfTest     用当前配置真跑一次接口识别（走和 Alt+R 一样的后台任务链路）
-ChordTest       热键状态机自检（不需要真人按键）
-ChordTestLive   热键链路自检（真的注入按键，需要交互式桌面）
-OverlayTest     只测框选遮罩
-SmokeTest       托盘/图标/热键注册冒烟
-GuiSmoke        启动托盘 2.5 秒后自动退出
-InstallSelf / -UninstallSelf   开机自启的注册 / 取消
```

## 说明与注意事项

- 触发键是 `Alt+R` 和 `Alt+R+S`。因为 `RegisterHotKey` 表达不了三键组合，`Alt+R(+S)` 是用低级键盘钩子实现的：
  - 按住 Alt → 按 R → **松开 Alt** = 识别（识别在松开 Alt 的瞬间触发，和原来一样跟手）。
  - 按住 Alt → 按 R → 再按 S = 打开设置。
  - 引导键最长存活 8 秒，中途按了别的键就放弃，不会误触发。
  - 万一钩子装不上，程序会自动回退成原来的 `Alt+R` 全局热键（设置改用托盘菜单）。
- 想换成别的快捷键：改 `ImgOcrAssistant.ps1` 里 `KeyChord` 的 `VK_R` / `VK_S` 常量，以及回退用的 `HK_VK_REGION` / `HK_MODS`（1=Alt，2=Ctrl，4=Shift，可相加）。
- **接口识别时截图会上传**到你填的接口地址；用本地引擎则全程离线。
- 接口调用跑在后台 PowerShell 任务里，不会卡住热键和托盘（也因此钩子不会被系统回收）。
- 接口返回的正文是按 UTF-8 显式解码的（PowerShell 5.1 的 `Invoke-RestMethod` 在响应头不带 charset 时会把中文解成乱码，所以这里自己发了 `HttpWebRequest`）。
- DeepSeek 接口要求图片只能出现在 user 消息里，程序就是这么拼的：`system` 放提示词，`user` 放「文字要求 + base64 图片」。
- 环境：Windows 10/11 + 系统自带 `powershell.exe`（Windows PowerShell 5.1）。
- 中文识别需要系统已装中文 OCR 可选功能；用 `-CheckOcr` 查看是否可用。
- 脚本文件必须保存为 **UTF-8 with BOM**，否则 Windows PowerShell 5.1 会按本地代码页解析导致中文乱码、语法报错。
- 托盘右键 → 退出 结束程序。

## 文件

```
ImgOcrAssistant.ps1      主程序（单文件）
start-assistant.cmd      后台启动
register-autostart.cmd   注册开机自启
unregister-autostart.cmd 取消开机自启
config.json              运行后生成在 %APPDATA%\ImgOcrAssistant\
```
