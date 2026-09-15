@echo off
rem ImgOcrAssistant - start the tray helper without leaving a console window behind.
rem
rem This .cmd exists for command-line / scripting use. A .cmd always gets its own
rem console window for a moment, so for a pure double-click launch use
rem start-assistant.vbs instead - that one never shows anything.
rem
rem The actual launching is done by the .vbs (wscript has no console, and it starts
rem PowerShell with SW_HIDE). Do NOT go back to `powershell.exe -WindowStyle Hidden`:
rem on Windows 11 the console is hosted by Windows Terminal, which turns that into a
rem window that stays in the taskbar minimized.
start "" wscript.exe "%~dp0start-assistant.vbs"
