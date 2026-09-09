@echo off
rem ImgOcrAssistant - add startup entry (HKCU Run)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0ImgOcrAssistant.ps1" -InstallSelf
echo.
pause
