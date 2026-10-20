Option Explicit

Dim fso, shell, scriptPath, args, i
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "scrcpy-monitor.ps1")

args = ""
For i = 0 To WScript.Arguments.Count - 1
    args = args & " """ & Replace(WScript.Arguments(i), """", "\""") & """"
Next

shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """" & args, 0, False
