@echo off
setlocal
title Document OCR launcher - leave this window open
call "%~dp0system\env.bat"

set "REPORT=%~dp0OCR startup report.txt"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "FAILURES=0"
set "EXIT_CODE=0"

>"%REPORT%" echo Document OCR startup report (Python-free: tesseract + ghostscript + .NET)
>>"%REPORT%" echo Generated: %DATE% %TIME%

echo.
echo === Document OCR startup check ===
call :check_file "Windows PowerShell" "%POWERSHELL%"
call :check_file "OCR window" "%~dp0system\native_gui.ps1"
call :check_file "OCR worker" "%~dp0system\native_worker.ps1"
call :check_file "Interface languages" "%~dp0system\native_strings.json"
call :check_file "Tesseract" "%APP%\Library\bin\tesseract.exe"
call :check_file "Ghostscript" "%APP%\Library\bin\gswin64c.exe"
call :check_file "English OCR language" "%APP%\share\tessdata\eng.traineddata"
call :check_file "Arabic OCR language" "%APP%\share\tessdata\ara.traineddata"
call :check_file "Orientation data" "%APP%\share\tessdata\osd.traineddata"

echo.
call :check_command "Tesseract OCR engine" "%APP%\Library\bin\tesseract.exe" --version
call :check_command "Ghostscript PDF engine" "%APP%\Library\bin\gswin64c.exe" --version
call :check_command "OCR worker self-test" "%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0system\native_worker.ps1" -SelfTest
call :check_command "Windows Forms interface" "%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0system\native_gui.ps1" -SelfTest

if "%FAILURES%"=="1" goto :failed

echo.
echo All startup checks passed.
echo Opening Document OCR...
>>"%REPORT%" echo.
>>"%REPORT%" echo RESULT: All startup checks passed.
"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0system\native_gui.ps1" 2>>"%REPORT%"
set "EXIT_CODE=%ERRORLEVEL%"
if "%EXIT_CODE%"=="0" goto :end
>>"%REPORT%" echo RESULT: The OCR window exited with code %EXIT_CODE%.
set "FAILURES=1"

:failed
echo.
echo Document OCR could not start because one or more checks failed.
echo The complete evidence is saved in:
echo %REPORT%
echo.
type "%REPORT%"
echo.
echo Keep OCR startup report.txt for troubleshooting.
echo This window will remain open until you press a key.
echo.
pause
set "EXIT_CODE=1"

:end
exit /b %EXIT_CODE%

:check_file
rem No parenthesised block here on purpose. cmd.exe substitutes %~2 while it
rem parses the block, so a ")" anywhere in the path -- "Downloads\folder (1)",
rem "C:\Program Files (x86)" -- closes the block early and kills the script
rem with no error. Paths are also quoted when echoed, for the same reason.
if not exist "%~2" goto :check_file_missing
echo Found: %~1
>>"%REPORT%" echo FILE OK: %~1 = "%~2"
exit /b 0
:check_file_missing
echo MISSING: %~1
>>"%REPORT%" echo FILE FAILED: %~1
>>"%REPORT%" echo Expected path: %~2
>>"%REPORT%" echo INTERPRETATION: The ZIP is incomplete, was not fully extracted, or security software removed a required file.
set "FAILURES=1"
exit /b 1

:check_command
echo Checking: %~1
>>"%REPORT%" echo.
>>"%REPORT%" echo ===== %~1 =====
set "CHECK_NAME=%~1"
shift
%1 %2 %3 %4 %5 %6 %7 %8 %9 >>"%REPORT%" 2>&1
if errorlevel 1 goto :check_command_failed
echo OK: %CHECK_NAME%
>>"%REPORT%" echo RESULT: OK - %CHECK_NAME%
exit /b 0
:check_command_failed
echo FAILED: %CHECK_NAME%
>>"%REPORT%" echo RESULT: FAILED - %CHECK_NAME%
>>"%REPORT%" echo INTERPRETATION: The error directly above identifies this failed component.
set "FAILURES=1"
exit /b 1
