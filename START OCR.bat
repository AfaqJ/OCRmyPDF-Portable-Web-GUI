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
set "PROBE_CODE=0"
set "CTYPES_FAILED=0"
set "SOCKET_FAILED=0"
set "HTTP_FAILED=0"
set "SELECT_FAILED=0"
set "MISSING_FILES=0"
set "CORE_INTEGRITY_FAILED=0"

echo.
echo === Document OCR startup check ===
call :check_file "Bundled Python" "%APP%\python.exe"
call :check_file "Python HTTP server" "%APP%\Lib\http\server.py"
call :check_file "Native loader diagnostic" "%~dp0system\startup_probe.py"
call :check_file "OCRmyPDF" "%APP%\Lib\site-packages\ocrmypdf\__init__.py"
call :check_file "pikepdf" "%APP%\Lib\site-packages\pikepdf\__init__.py"
call :check_file "pypdfium2" "%APP%\Lib\site-packages\pypdfium2\__init__.py"
if "%MISSING_FILES%"=="1" goto :missing

echo.
call :check_hash "Bundled Python executable" "%APP%\python.exe" "32733c1f0c531b2a259a7003c9af5de6771427c4d7d90797a41d11d0ed708c90"
call :check_hash "Bundled Python runtime" "%APP%\python312.dll" "fd525012d25b4e0641e147ca1ba224c492e07586fd578ed0e8ff74085d143836"
call :check_hash "Python socket module" "%APP%\DLLs\_socket.pyd" "2796bce493bae64f00a97becdb5d0ed67f24cc267baf185fed8434f0c5ca485e"
if "%CORE_INTEGRITY_FAILED%"=="1" goto :startup_error
call :check_socket_source
if errorlevel 1 set "IMPORT_FAILURES=1"

echo.
echo Checking: Windows native loader
>>"%ERROR_LOG%" echo.
>>"%ERROR_LOG%" echo ===== Windows native loader =====
"%APP%\python.exe" -s "%~dp0system\startup_probe.py" >>"%ERROR_LOG%" 2>&1
set "PROBE_CODE=%ERRORLEVEL%"
if not "%PROBE_CODE%"=="0" (
  echo FAILED: Windows native loader
  set "IMPORT_FAILURES=1"
  set "FAILED_STEP=Windows native loader"
  set "EXIT_CODE=1"
) else (
  echo OK: Windows native loader
)

call :check_import "Python native support: _ctypes" "import _ctypes; print(_ctypes.__file__)"
if errorlevel 1 set "CTYPES_FAILED=1"
call :check_import "Python socket extension: _socket" "import _socket; print(_socket.__file__)"
if errorlevel 1 set "SOCKET_FAILED=1"
call :check_import "Python standard library: http.server" "import http.server"
if errorlevel 1 set "HTTP_FAILED=1"
call :check_import "Independent native module: select" "import select; print(select.__file__)"
if errorlevel 1 set "SELECT_FAILED=1"
call :check_import "PDF rendering library: pypdfium2" "import pypdfium2"
call :check_import "PDF editing library: pikepdf" "import pikepdf"
call :check_import "OCR pipeline: ocrmypdf" "import ocrmypdf"
call :check_import "Local browser port: 127.0.0.1" "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); s.close()"

if not "%IMPORT_FAILURES%"=="1" goto :imports_ok
call :write_conclusion
goto :startup_error

:imports_ok

echo.
echo Starting Document OCR in your browser...
set "FAILED_STEP=starting the browser interface"
"%APP%\python.exe" -s "%~dp0system\web_gui.py" 2>>"%ERROR_LOG%"
set "EXIT_CODE=%ERRORLEVEL%"
if "%EXIT_CODE%"=="0" goto :end
>>"%ERROR_LOG%" echo INTERPRETATION: All preflight checks passed, but the browser interface exited. The final traceback is specific to GUI startup.

:startup_error
echo.
echo All available startup checks have finished.
echo OCR did not start during: %FAILED_STEP%
echo The technical error is shown below and saved in:
echo %ERROR_LOG%
echo.
type "%ERROR_LOG%"
echo.
echo === Plain-language conclusion ===
findstr /b /c:"INTERPRETATION:" "%ERROR_LOG%"
echo.
echo Keep OCR startup error.txt. It contains the complete evidence.
echo.
pause
goto :end

:missing
echo.
echo OCR cannot find one or more required portable files.
echo Extract the complete ZIP before running this file.
echo Missing or unreadable files can also be checked by security software.
echo See OCR startup error.txt for every missing path.
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
set "MISSING_FILES=1"
if not defined FAILED_STEP set "FAILED_STEP=required file: %~1"
>>"%ERROR_LOG%" echo INTERPRETATION: MISSING required file: %~1
>>"%ERROR_LOG%" echo Expected path: %~2
exit /b 1

:check_import
echo Checking: %~1
>>"%ERROR_LOG%" echo.
>>"%ERROR_LOG%" echo ===== %~1 =====
"%APP%\python.exe" -s -c "%~2" >>"%ERROR_LOG%" 2>&1
if not errorlevel 1 goto :check_import_ok
echo FAILED: %~1
>>"%ERROR_LOG%" echo INTERPRETATION: FAILED check: %~1. Its technical traceback is directly above this line.
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
>>"%ERROR_LOG%" echo INTERPRETATION: This bundled file differs from the tested release. Re-extract a fresh ZIP before investigating Windows.
set "CORE_INTEGRITY_FAILED=1"
if not defined FAILED_STEP set "FAILED_STEP=integrity check: %~1"
set "EXIT_CODE=1"
exit /b 1

:check_socket_source
echo Checking: _socket module location
>>"%ERROR_LOG%" echo.
>>"%ERROR_LOG%" echo ===== _socket module location =====
"%APP%\python.exe" -s -c "import importlib.util, os, sys; actual=os.path.realpath(importlib.util.find_spec('_socket').origin); expected=os.path.realpath(os.path.join(os.environ['APP'],'DLLs','_socket.pyd')); print('Expected path:', expected); print('Actual path:', actual); sys.exit(0 if os.path.normcase(actual)==os.path.normcase(expected) else 1)" >>"%ERROR_LOG%" 2>&1
set "SOCKET_SOURCE_CODE=%ERRORLEVEL%"
findstr /b /c:"Expected path:" /c:"Actual path:" "%ERROR_LOG%"
if "%SOCKET_SOURCE_CODE%"=="0" (
  echo OK: Both paths identify the same portable file.
  exit /b 0
)
echo FAILED: Python selected a different _socket module.
>>"%ERROR_LOG%" echo INTERPRETATION: Python selected a _socket module outside the portable app folder.
set "FAILED_STEP=_socket module location"
set "EXIT_CODE=1"
exit /b 1

:write_conclusion
>>"%ERROR_LOG%" echo.
>>"%ERROR_LOG%" echo ===== Plain-language conclusion =====
if not "%PROBE_CODE%"=="0" >>"%ERROR_LOG%" echo INTERPRETATION: Windows could not load or inspect the native socket module normally. The native-loader section identifies the exact stage and loaded files.
if "%CTYPES_FAILED%"=="1" >>"%ERROR_LOG%" echo INTERPRETATION: Multiple native Python modules are affected. This is a machine-level native-loading or security-policy problem, not an OCRmyPDF problem.
if "%PROBE_CODE%"=="0" if "%SOCKET_FAILED%"=="1" >>"%ERROR_LOG%" echo INTERPRETATION: Windows directly loaded the correct _socket.pyd and saw its export, but Python import was still intercepted or altered. Give this report to IT or endpoint-security support.
if "%SOCKET_FAILED%"=="1" if "%SELECT_FAILED%"=="0" >>"%ERROR_LOG%" echo INTERPRETATION: Other native Python code loads, so the failure is specific to the socket module or its Windows loading path.
if "%SOCKET_FAILED%"=="0" if "%HTTP_FAILED%"=="1" >>"%ERROR_LOG%" echo INTERPRETATION: The socket module works; the HTTP traceback contains the separate failure above it.
exit /b 0
