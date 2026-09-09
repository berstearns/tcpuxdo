' Reconnect-Worker.vbs  —  the double-click button (give this to the girlfriend)
'
' WHAT:  Double-click -> runs the WSL bring-up hidden (no black window), then
'        shows one friendly message box: connected, or what to check.
' WHY:   When the laptop's worker drops, someone ON this machine must restart
'        it. This is that someone, reduced to a double-click. It holds NO
'        secrets and NO logic — all the work is the tracked bash program
'        setup/windows/AUTO-worker-bringup.sh inside the WSL repo.
'
' CONFIG: if `wsl.exe` opens the wrong Linux, set DISTRO to its name
'         (see a list with:  wsl.exe -l -q  ). Leave "" to use the default.
Const DISTRO = ""                 ' e.g. "Ubuntu"
Const REPO   = "~/tcpuxdo"        ' the tcpuxdo checkout inside WSL
Const TITLE  = "Reconnect laptop worker"

Dim sh: Set sh = CreateObject("WScript.Shell")
Dim fso: Set fso = CreateObject("Scripting.FileSystemObject")
Dim tmp: tmp = sh.ExpandEnvironmentStrings("%TEMP%") & "\tcpuxdo-bringup.log"

Dim distroArg: distroArg = ""
If Len(DISTRO) > 0 Then distroArg = "-d " & DISTRO & " "

Dim inner:  inner  = "cd " & REPO & " && bash setup/windows/AUTO-worker-bringup.sh"
Dim wslCmd: wslCmd = "wsl.exe " & distroArg & "-- bash -lc " & Chr(34) & inner & Chr(34)
Dim full:   full   = "cmd /c " & Chr(34) & wslCmd & " > " & Chr(34) & tmp & Chr(34) & " 2>&1" & Chr(34)

' 0 = hidden window, True = wait for it to finish.
sh.Run full, 0, True

Dim out: out = ""
If fso.FileExists(tmp) Then
    Dim f: Set f = fso.OpenTextFile(tmp, 1)
    If Not f.AtEndOfStream Then out = f.ReadAll
    f.Close
End If

Dim code: code = -1
Dim msg:  msg  = ""
Dim line, m
For Each line In Split(out, vbLf)
    If Left(line, 15) = "BRINGUP_RESULT=" Then code = CInt(Trim(Mid(line, 16)))
    If Left(line, 12) = "BRINGUP_MSG=" Then msg  = Trim(Mid(line, 13))
Next

Dim icon
Select Case code
    Case 0:            icon = vbInformation   ' connected
    Case 10, 20:       icon = vbExclamation   ' transient / check WiFi
    Case 30, 40, 50:   icon = vbCritical      ' setup problem -> call Bernardo
    Case Else
        icon = vbCritical
        If Len(Trim(out)) = 0 Then
            msg = "Couldn't run WSL. Is the laptop's Linux (WSL) installed and named correctly?"
        Else
            msg = "Unexpected result. Show Bernardo this:" & vbCrLf & vbCrLf & Left(out, 500)
        End If
End Select

MsgBox msg, vbOKOnly + icon, TITLE
