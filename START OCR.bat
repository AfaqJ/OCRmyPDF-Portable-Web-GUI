@echo off
setlocal
title Document OCR native launcher - leave this window open
call "%~dp0system\env.bat"

set "REPORT=%~dp0OCR native startup report.txt"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "FAILURES=0"
set "OPTIONAL_CHECK=0"
set "EXIT_CODE=0"

>"%REPORT%" echo Document OCR native startup report
>>"%REPORT%" echo Generated: %DATE% %TIME%

echo.
echo === Document OCR native startup check ===
call :check_file "Portable environment" "%~dp0system\env.bat"
call :check_file "Bundled Python" "%APP%\python.exe"
call :check_file "Bundled Python runtime" "%APP%\python312.dll"
call :check_file "Native Windows GUI" "%~dp0system\native_gui.ps1"
call :check_file "Native OCR worker" "%~dp0system\native_worker.py"
call :check_file "Socket compatibility entry point" "%~dp0system\socketless_ocr.py"
call :check_file "Interface languages" "%~dp0system\native_strings.json"
call :check_file "Orientation correction" "%~dp0system\prerotate.py"
call :check_file "OCRmyPDF" "%APP%\Lib\site-packages\ocrmypdf\__init__.py"
call :check_file "pikepdf" "%APP%\Lib\site-packages\pikepdf\__init__.py"
call :check_file "pypdfium2" "%APP%\Lib\site-packages\pypdfium2\__init__.py"
call :check_file "Tesseract" "%APP%\Library\bin\tesseract.exe"
call :check_file "Ghostscript" "%APP%\Library\bin\gswin64c.exe"
call :check_file "English OCR language" "%APP%\share\tessdata\eng.traineddata"
call :check_file "Arabic OCR language" "%APP%\share\tessdata\ara.traineddata"
call :check_file "Windows PowerShell" "%POWERSHELL%"

echo.
call :check_hash "Bundled Python executable" "%APP%\python.exe" "32733c1f0c531b2a259a7003c9af5de6771427c4d7d90797a41d11d0ed708c90"
call :check_hash "Bundled Python runtime" "%APP%\python312.dll" "fd525012d25b4e0641e147ca1ba224c492e07586fd578ed0e8ff74085d143836"

echo.
call :check_command "Python basic startup" "%APP%\python.exe" -X utf8 -s -c "import sys; print(sys.executable); print(sys.version)"
call :check_command "Native OCR worker" "%APP%\python.exe" -X utf8 -s "%~dp0system\native_worker.py" --selftest
call :check_command "Socket compatibility entry point" "%APP%\python.exe" -X utf8 -s "%~dp0system\socketless_ocr.py" --selftest
set "OPTIONAL_CHECK=1"
call :check_command "OCR pipeline without socket support" "%APP%\python.exe" -X utf8 -s "%~dp0system\socketless_ocr.py" --selftest-ocr-fallback
set "OPTIONAL_CHECK=0"
call :check_command "PDF rendering library" "%APP%\python.exe" -X utf8 -s -c "import pypdfium2; print(pypdfium2.__file__)"
call :check_command "PDF editing library" "%APP%\python.exe" -X utf8 -s -c "import pikepdf; print(pikepdf.__file__)"
call :check_command "OCR pipeline through compatibility entry point" "%APP%\python.exe" -X utf8 -s "%~dp0system\socketless_ocr.py" --version
call :check_command "Tesseract OCR engine" "%APP%\Library\bin\tesseract.exe" --version
call :check_command "Ghostscript PDF engine" "%APP%\Library\bin\gswin64c.exe" --version
call :check_command "Windows Forms interface" "%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0system\native_gui.ps1" -SelfTest

if "%FAILURES%"=="1" goto :failed

echo.
echo All startup checks passed.
echo Opening the Windows-native Document OCR app...
>>"%REPORT%" echo.
>>"%REPORT%" echo RESULT: All startup checks passed.
"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0system\native_gui.ps1" 2>>"%REPORT%"
set "EXIT_CODE=%ERRORLEVEL%"
if "%EXIT_CODE%"=="0" goto :end
>>"%REPORT%" echo RESULT: The native GUI exited with code %EXIT_CODE%.
set "FAILURES=1"

:failed
echo.
echo Document OCR could not start because one or more checks failed.
echo Every check was attempted. The complete evidence is saved in:
echo %REPORT%
echo.
type "%REPORT%"
echo.
echo Keep OCR native startup report.txt for troubleshooting.
echo This window will remain open until you press a key.
echo.
pause
set "EXIT_CODE=1"

:end
exit /b %EXIT_CODE%

:check_file
if exist "%~2" (
  echo Found: %~1
  >>"%REPORT%" echo FILE OK: %~1 = %~2
  exit /b 0
)
echo MISSING: %~1
>>"%REPORT%" echo FILE FAILED: %~1
>>"%REPORT%" echo Expected path: %~2
>>"%REPORT%" echo INTERPRETATION: The ZIP is incomplete, was not fully extracted, or security software removed a required file.
set "FAILURES=1"
exit /b 1

:check_hash
echo Checking integrity: %~1
if not exist "%~2" (
  echo FAILED: %~1 is missing
  >>"%REPORT%" echo INTEGRITY FAILED: %~1 is missing
  set "FAILURES=1"
  exit /b 1
)
set "ACTUAL_HASH="
for /f "skip=1 tokens=1" %%H in ('certutil -hashfile "%~2" SHA256 2^>nul') do if not defined ACTUAL_HASH set "ACTUAL_HASH=%%H"
if /i "%ACTUAL_HASH%"=="%~3" (
  echo OK: %~1
  >>"%REPORT%" echo INTEGRITY OK: %~1 = %ACTUAL_HASH%
  exit /b 0
)
echo FAILED: %~1
>>"%REPORT%" echo INTEGRITY FAILED: %~1
>>"%REPORT%" echo Expected SHA-256: %~3
>>"%REPORT%" echo Actual SHA-256: %ACTUAL_HASH%
>>"%REPORT%" echo INTERPRETATION: This core runtime file differs from the tested release. Download and extract a fresh ZIP.
set "FAILURES=1"
exit /b 1

:check_command
echo Checking: %~1
>>"%REPORT%" echo.
>>"%REPORT%" echo ===== %~1 =====
set "CHECK_NAME=%~1"
shift
%1 %2 %3 %4 %5 %6 %7 %8 %9 >>"%REPORT%" 2>&1
if not errorlevel 1 (
  echo OK: %CHECK_NAME%
  >>"%REPORT%" echo RESULT: OK - %CHECK_NAME%
  exit /b 0
)
echo FAILED: %CHECK_NAME%
>>"%REPORT%" echo RESULT: FAILED - %CHECK_NAME%
>>"%REPORT%" echo INTERPRETATION: The traceback or Windows error directly above identifies this failed component.
if "%OPTIONAL_CHECK%"=="1" (
  echo WARNING ONLY: This optional fallback check does not block startup.
  >>"%REPORT%" echo INTERPRETATION: Warning only. The mandatory OCR pipeline check decides whether this PC can run OCR.
  exit /b 0
)
set "FAILURES=1"
exit /b 1
