' ImgOcrAssistant - flash-free launcher (double-click this file).
'
' Why this exists: on Windows 11 the console host is delegated to Windows Terminal,
' and `powershell.exe -WindowStyle Hidden` does NOT hide it - the terminal window
' still shows up and then sits in the taskbar minimized. wscript.exe has no console
' of its own, and WshShell.Run(..., 0, False) starts the child with SW_HIDE from the
' very beginning, so nothing ever flashes.
'
' This file is deliberately ASCII-only: .vbs files are read using the system ANSI
' code page, so keeping it ASCII avoids mojibake on any locale.
Option Explicit

Dim fso, sh, base, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

base = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(base, "ImgOcrAssistant.ps1")

If Not fso.FileExists(ps1) Then
    MsgBox "ImgOcrAssistant.ps1 was not found next to this launcher:" & vbCrLf & ps1, 16, "ImgOcrAssistant"
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File """ & ps1 & """"
sh.Run cmd, 0, False
