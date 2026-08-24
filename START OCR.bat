@echo off
setlocal
title OCRmyPDF - leave this window open
call "%~dp0system\env.bat"
set "ERROR_LOG=%~dp0OCR startup error.txt"
del "%ERROR_LOG%" 2>nul
>"%ERROR_LOG%" echo OCR startup diagnostic report
>>"%ERROR_LOG%" echo Generated: %DATE% %TIME%
set "IMPORT_FAILURES=0"
set "FAILED_STEP="

echo.
echo === Document OCR startup check ===
call :check_file "Bundled Python" "%APP%\python.exe" || goto :missing
call :check_file "Python HTTP server" "%APP%\Lib\http\server.py" || goto :missing
call :check_file "Native loader diagnostic" "%~dp0system\startup_probe.py" || goto :missing
call :check_file "OCRmyPDF" "%APP%\Lib\site-packages\ocrmypdf\__init__.py" || goto :missing
call :check_file "pikepdf" "%APP%\Lib\site-packages\pikepdf\__init__.py" || goto :missing
call :check_file "pypdfium2" "%APP%\Lib\site-packages\pypdfium2\__init__.py" || goto :missing

echo.
call :check_hash "Bundled Python executable" "%APP%\python.exe" "32733c1f0c531b2a259a7003c9af5de6771427c4d7d90797a41d11d0ed708c90" || goto :startup_error
call :check_hash "Bundled Python runtime" "%APP%\python312.dll" "fd525012d25b4e0641e147ca1ba224c492e07586fd578ed0e8ff74085d143836" || goto :startup_error
call :check_hash "Python socket module" "%APP%\DLLs\_socket.pyd" "2796bce493bae64f00a97becdb5d0ed67f24cc267baf185fed8434f0c5ca485e" || goto :startup_error
call :check_socket_source || goto :startup_error

echo.
echo Checking: Windows native loader
>>"%ERROR_LOG%" echo.
>>"%ERROR_LOG%" echo ===== Windows native loader =====
"%APP%\python.exe" -s "%~dp0system\startup_probe.py" >>"%ERROR_LOG%" 2>&1
if errorlevel 1 (
  echo FAILED: Windows native loader
  set "IMPORT_FAILURES=1"
  set "FAILED_STEP=Windows native loader"
  set "EXIT_CODE=1"
) else (
  echo OK: Windows native loader
)

call :check_import "Python native support: _ctypes" "import _ctypes; print(_ctypes.__file__)"
call :check_import "Python socket extension: _socket" "import _socket; print(_socket.__file__)"
call :check_import "Python standard library: http.server" "import http.server"
call :check_import "Independent native module: select" "import select; print(select.__file__)"
call :check_import "PDF rendering library: pypdfium2" "import pypdfium2"
call :check_import "PDF editing library: pikepdf" "import pikepdf"
call :check_import "OCR pipeline: ocrmypdf" "import ocrmypdf"
call :check_import "Local browser port: 127.0.0.1" "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); s.close()"

if "%IMPORT_FAILURES%"=="1" goto :startup_error

echo.
echo Starting Document OCR in your browser...
set "FAILED_STEP=starting the browser interface"
"%APP%\python.exe" -s "%~dp0system\web_gui.py" 2>>"%ERROR_LOG%"
set "EXIT_CODE=%ERRORLEVEL%"
if "%EXIT_CODE%"=="0" goto :end

:startup_error
echo.
echo OCR did not start during: %FAILED_STEP%
echo The technical error is shown below and saved in:
echo %ERROR_LOG%
echo.
type "%ERROR_LOG%"
echo.
pause
goto :end

:missing
echo.
echo OCR cannot find this required portable file: %MISSING_ITEM%
echo Expected location: %MISSING_PATH%
echo Extract the complete ZIP before running this file.
echo Missing or unreadable files can also be checked by security software.
echo.
pause
set "EXIT_CODE=1"

:end
exit /b %EXIT_CODE%

:check_file
if exist "%~2" (
  echo Found: %~1
  exit /b 0
)
set "MISSING_ITEM=%~1"
set "MISSING_PATH=%~2"
exit /b 1

:check_import
echo Checking: %~1
>>"%ERROR_LOG%" echo.
>>"%ERROR_LOG%" echo ===== %~1 =====
"%APP%\python.exe" -s -c "%~2" >>"%ERROR_LOG%" 2>&1
if not errorlevel 1 goto :check_import_ok
echo FAILED: %~1
set "IMPORT_FAILURES=1"
if not defined FAILED_STEP set "FAILED_STEP=%~1"
set "EXIT_CODE=1"
exit /b 1

:check_import_ok
echo OK: %~1
exit /b 0

:check_hash
echo Checking integrity: %~1
set "ACTUAL_HASH="
for /f "skip=1 tokens=1" %%H in ('certutil -hashfile "%~2" SHA256') do if not defined ACTUAL_HASH set "ACTUAL_HASH=%%H"
if /i "%ACTUAL_HASH%"=="%~3" (
  echo OK: %~1
  >>"%ERROR_LOG%" echo Integrity OK: %~1 = %ACTUAL_HASH%
  exit /b 0
)
echo Expected SHA-256: %~3
echo Actual SHA-256: %ACTUAL_HASH%
>>"%ERROR_LOG%" echo Integrity FAILED: %~1
>>"%ERROR_LOG%" echo Expected SHA-256: %~3
>>"%ERROR_LOG%" echo Actual SHA-256: %ACTUAL_HASH%
set "FAILED_STEP=integrity check: %~1"
set "EXIT_CODE=1"
exit /b 1

:check_socket_source
echo Checking: _socket module location
echo Expected: %~dp0app\DLLs\_socket.pyd
"%APP%\python.exe" -s -c "import importlib.util; print('Actual:', importlib.util.find_spec('_socket').origin)" 2>>"%ERROR_LOG%"
if not errorlevel 1 (
  echo Compare Actual with Expected above.
  exit /b 0
)
set "FAILED_STEP=_socket module location"
set "EXIT_CODE=1"
exit /b 1
