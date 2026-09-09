@echo off
rem ImgOcrAssistant - start tray OCR helper (background)
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0ImgOcrAssistant.ps1"
