@echo off
rem Opens Document OCR. That is the whole job of this file.
rem
rem Nothing is printed and nothing is checked here on purpose. The app verifies
rem its own files milliseconds after it starts (Test-Startup in
rem system\native_gui.ps1) and shows a message box if one is missing -- so a
rem broken download is still reported, just not to a console nobody wants to
rem see. The two -SelfTest runs that used to happen here are developer checks;
rem they are still there, run by hand, and no longer sit in front of the user.
rem
rem cmd.exe always draws a window for a .bat file, so this one does as little
rem as possible and exits: a brief flash instead of a console.
rem
rem Every path below is quoted and no path is expanded inside a parenthesised
rem block. That is not style -- an unquoted path is what made this script die
rem silently when its own folder was called "...-dotnet-ocr (1)": cmd.exe
rem substitutes the text while it parses the block, so the ")" ended the block
rem early and the rest of the script was abandoned with no error.
setlocal
call "%~dp0system\env.bat"
set "GUI=%~dp0system\native_gui.ps1"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%GUI%" goto :broken
if not exist "%POWERSHELL%" goto :nopowershell

rem -WindowStyle Hidden hides the PowerShell host window, not the OCR window,
rem which native_gui.ps1 shows itself. start hands the app its own process so
rem this console can close immediately.
start "Document OCR" "%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%GUI%"
exit /b 0

:broken
rem The one case that still gets a visible window: there is no app to put the
rem message in.
echo Document OCR cannot start - a file is missing:
echo   "%GUI%"
echo.
echo The ZIP was not extracted completely, or security software removed a file.
echo Extract the whole folder again, then run this file once more.
echo.
pause
exit /b 1

:nopowershell
echo Document OCR cannot start - Windows PowerShell was not found:
echo   "%POWERSHELL%"
echo.
echo This is part of Windows. If it is missing or blocked, this tool cannot run
echo on this PC without help from IT.
echo.
pause
exit /b 1
