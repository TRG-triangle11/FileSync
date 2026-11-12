' FileSync silent launcher - no console window, no taskbar button.
' Content is ASCII-only on purpose (cmd.exe mis-parses Chinese in batch files,
' and wscript reads VBS in ANSI codepage which also garbles non-ASCII comments).
' The web console, tray icon and desktop mini-bar all still work as usual;
' server output goes to logs\console.log if you ever need to look at it.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
serve = here & "\Serve-Console.ps1"
If Not fso.FileExists(serve) Then
    MsgBox "Serve-Console.ps1 not found next to this launcher: " & serve, 16, "FileSync"
    WScript.Quit 1
End If
sh.CurrentDirectory = here
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & serve & """", 0, False
