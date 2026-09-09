@echo off
REM Install-On-Windows.cmd  —  run ONCE on the Windows side (double-click, or
REM right-click > Run as administrator is NOT needed).
REM
REM WHAT: puts the Reconnect button on the Desktop and registers a logon task
REM       that runs it automatically each time Windows starts, so the worker
REM       comes back on its own after a reboot.
REM WHY:  the girlfriend never has to hunt for a file — the button is on the
REM       Desktop, and most outages self-heal at logon without any click.
REM
REM It does NOT install the systemd service — that is the Linux side, done once
REM by Bernardo:   wsl.exe -- bash -lc "cd ~/tcpuxdo && bash setup/windows/Install-Worker-Autostart.sh"

setlocal
set "HERE=%~dp0"
set "VBS=%HERE%Reconnect-Worker.vbs"
set "DESK=%USERPROFILE%\Desktop\Reconnect laptop worker.vbs"

echo Copying the button to the Desktop...
copy /Y "%VBS%" "%DESK%" >nul
if errorlevel 1 ( echo   could not copy to Desktop & goto :done )
echo   Desktop button ready: "%DESK%"

echo Registering a logon task so the worker reconnects automatically at startup...
schtasks /Create /TN "TcpuxdoWorkerReconnect" /SC ONLOGON ^
  /TR "wscript.exe \"%DESK%\"" /F >nul
if errorlevel 1 ( echo   could not register the logon task ^(non-fatal^) ) else ( echo   logon task registered )

:done
echo.
echo Done. Tell her: if the laptop link is down, double-click
echo   "Reconnect laptop worker" on the Desktop and wait for the green message.
echo.
pause
endlocal
