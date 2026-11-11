' Starts the key listener (DodgeSignal.ps1) as a background process with no
' window at all: wscript is a windowless host and PowerShell is started with a
' hidden window, so the listener cannot steal focus from the game.
Option Explicit

Dim fso, sh, dir, script, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

dir = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(dir, "DodgeSignal.ps1")

If Not fso.FileExists(script) Then WScript.Quit 1

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """"
sh.Run cmd, 0, False
