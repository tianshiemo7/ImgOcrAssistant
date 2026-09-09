@echo off
rem ImgOcrAssistant - remove startup entry
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0ImgOcrAssistant.ps1" -UninstallSelf
echo.
pause
