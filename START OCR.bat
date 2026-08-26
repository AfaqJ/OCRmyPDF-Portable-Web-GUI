@echo off
rem Opens Document OCR. That is the whole job of this file.
rem
rem   START OCR.bat          silent - what the user gets
rem   START OCR.bat debug    everything visible, nothing hidden
rem
rem Debug mode is not dead weight. A failure that happens before the app can
rem draw a window is invisible in silent mode by definition, so there has to be
rem one command that shows it. "Troubleshoot OCR.bat" is a double-clickable
rem shortcut to this, and saves the output to a file.
rem
rem Every path below is quoted and no path is expanded inside a parenthesised
rem block. That is not style -- an unquoted path is what made this script die
rem silently when its own folder was called "...-dotnet-ocr (1)": cmd.exe
rem substitutes the text while it parses the block, so the ")" ended the block
rem early and the rest of the script was abandoned with no error.
setlocal
call "%~dp0system\env.bat"
set "GUI=%~dp0system\native_gui.ps1"
set "WORKER=%~dp0system\native_worker.ps1"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "DEBUG="
if /i "%~1"=="debug" set "DEBUG=1"

if not exist "%GUI%" goto :broken
if not exist "%POWERSHELL%" goto :nopowershell
if defined DEBUG goto :debug

rem -WindowStyle Hidden hides the PowerShell host window, not the OCR window,
rem which native_gui.ps1 shows itself. start hands the app its own process so
rem this console can close immediately. If the script then fails, the trap at
rem the top of native_gui.ps1 writes system\logs\startup problem.txt and shows
rem a message box -- a hidden process has no other way to speak.
start "Document OCR" "%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%GUI%"
exit /b 0

:debug
echo ==================================================================
echo  Document OCR - debug launch. Nothing is hidden.
echo ==================================================================
echo.
echo [1/4] Files the app needs
call :show_file "OCR window"           "%GUI%"
call :show_file "OCR worker"           "%WORKER%"
call :show_file "Interface languages"  "%~dp0system\native_strings.json"
call :show_file "Tesseract"            "%APP%\Library\bin\tesseract.exe"
call :show_file "Ghostscript"          "%APP%\Library\bin\gswin64c.exe"
call :show_file "English OCR data"     "%APP%\share\tessdata\eng.traineddata"
call :show_file "Arabic OCR data"      "%APP%\share\tessdata\ara.traineddata"
call :show_file "Orientation data"     "%APP%\share\tessdata\osd.traineddata"
call :show_file "PDF library"          "%~dp0system\lib\PdfSharp.dll"

echo.
echo [2/4] Do the scripts parse?
echo       A syntax error kills PowerShell before any error handler exists,
echo       which from outside looks exactly like "nothing happened".
"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "try { $null = [ScriptBlock]::Create((Get-Content -Raw -LiteralPath '%GUI%')); '   PARSE OK      native_gui.ps1' } catch { '   PARSE FAILED  native_gui.ps1'; $_.Exception.Message }"
"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "try { $null = [ScriptBlock]::Create((Get-Content -Raw -LiteralPath '%WORKER%')); '   PARSE OK      native_worker.ps1' } catch { '   PARSE FAILED  native_worker.ps1'; $_.Exception.Message }"

echo.
echo [3/4] Self-tests
"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%WORKER%" -SelfTest
echo    worker self-test exit code: %ERRORLEVEL%
"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%GUI%" -SelfTest
echo    GUI self-test exit code: %ERRORLEVEL%

echo.
echo [4/4] Opening the app in this window, NOT hidden, so that any error it
echo       hits is printed here instead of vanishing with the process.
echo       Close the OCR window when you are done looking at it.
echo.
"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%GUI%"
echo.
echo The app exited with code %ERRORLEVEL%.
echo (0 and no window means it closed normally. Anything else is the failure.)
if not defined OCR_NO_PAUSE pause
exit /b 0

:show_file
if not exist "%~2" goto :show_file_missing
echo    found   : %~1
exit /b 0
:show_file_missing
echo    MISSING : %~1
echo              expected at "%~2"
exit /b 0

:broken
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
