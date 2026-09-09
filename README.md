# 屏幕OCR助手（极简版）

只做一件事：**按 `Alt + R` → 框选屏幕上任意区域 → Windows 内置 OCR 识别 → 文字自动复制到剪贴板 → 托盘气泡提示**。

没有自动检测、没有弹窗询问、没有任何多余功能。识别全程在本机完成，不上传。

## 使用

1. 双击 `start-assistant.cmd` 启动（托盘出现放大镜图标）。
2. 需要提取文字时按 **`Alt + R`**，鼠标框选屏幕区域（Esc 取消）。
3. 松开鼠标即识别，文字进剪贴板，直接 Ctrl+V 粘贴即可。
   - 双击托盘图标 或 托盘右键 →「框选屏幕区域识别文字」效果相同。

## 开机自启

- 双击 `register-autostart.cmd` 添加；`unregister-autostart.cmd` 取消。

## 说明

- 触发键是 `Alt + R`（两键）。想改：编辑 `ImgOcrAssistant.ps1` 顶部 `HK_VK_REGION`（键码）和 `HK_MODS`（修饰键，1=Alt，2=Ctrl，4=Shift，可加和）即可。
- 环境：Windows 10/11 + 系统自带 powershell.exe（Windows PowerShell 5.1）。
- 中文识别需要系统已装中文 OCR 可选功能；可用 `powershell.exe -STA -File ImgOcrAssistant.ps1 -CheckOcr` 查看可用语言。
- 托盘右键 → 退出 结束程序。

## 文件

```
ImgOcrAssistant.ps1      主程序（极简单文件）
start-assistant.cmd      后台启动
register-autostart.cmd   注册开机自启
unregister-autostart.cmd 取消开机自启
```
