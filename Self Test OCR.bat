@echo off
rem Runs the two self-tests and shows the result. Double-click it.
rem
rem This is the proof after any change to the OCR worker or the OCR window.
rem It touches no PDFs and writes nothing outside system\logs, so it is safe to
rem run at any time. START OCR.bat deliberately does NOT run these (D-020) --
rem the user opening the app should never see a developer check.
rem
rem Every path is quoted and none is expanded inside a parenthesised block.
rem That is not style: an unquoted path inside "if exist (...)" is what made
rem START OCR.bat die silently when its folder was called "...-dotnet-ocr (1)".
setlocal
call "%~dp0system\env.bat"
set "GUI=%~dp0system\native_gui.ps1"
set "WORKER=%~dp0system\native_worker.ps1"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "LOGDIR=%~dp0system\logs"
set "LOG=%LOGDIR%\selftest.txt"
md "%LOGDIR%" 2>nul

if not exist "%POWERSHELL%" goto :nopowershell
if not exist "%WORKER%" goto :missing
if not exist "%GUI%" goto :missing

echo ==================================================================
echo  Document OCR - self test
echo ==================================================================
echo.
echo Running. This takes a few seconds and starts some short-lived
echo Ghostscript processes on purpose, to test the parallel runner.
echo.

call :run_both > "%LOG%" 2>&1
type "%LOG%"

echo.
echo ==================================================================
echo A copy is saved in:
echo   "%LOG%"
echo.
echo Every line should say "ok". If any line says "FAIL", stop and send
echo that file - do not run a real document until it passes.
echo ==================================================================
pause
exit /b 0

:run_both
echo ----- OCR worker (native_worker.ps1) -----
"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%WORKER%" -SelfTest
echo.
echo ----- OCR window (native_gui.ps1) -----
"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%GUI%" -SelfTest
goto :eof

:nopowershell
echo Windows PowerShell was not found where it should be:
echo   "%POWERSHELL%"
echo.
pause
exit /b 1

:missing
echo The download is incomplete - a script the self test needs is missing:
echo   "%WORKER%"
echo   "%GUI%"
echo.
echo Extract the ZIP again, whole.
echo.
pause
exit /b 1
