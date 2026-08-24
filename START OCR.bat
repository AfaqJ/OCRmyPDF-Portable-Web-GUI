@echo off
setlocal
title OCRmyPDF - leave this window open
call "%~dp0system\env.bat"
set "ERROR_LOG=%~dp0OCR startup error.txt"
del "%ERROR_LOG%" 2>nul

echo.
echo === Document OCR startup check ===
call :check_file "Bundled Python" "%APP%\python.exe" || goto :missing
call :check_file "Python HTTP server" "%APP%\Lib\http\server.py" || goto :missing
call :check_file "OCRmyPDF" "%APP%\Lib\site-packages\ocrmypdf\__init__.py" || goto :missing
call :check_file "pikepdf" "%APP%\Lib\site-packages\pikepdf\__init__.py" || goto :missing
call :check_file "pypdfium2" "%APP%\Lib\site-packages\pypdfium2\__init__.py" || goto :missing

echo.
call :check_import "Python standard library: http.server" "import http.server" || goto :startup_error
call :check_import "PDF rendering library: pypdfium2" "import pypdfium2" || goto :startup_error
call :check_import "PDF editing library: pikepdf" "import pikepdf" || goto :startup_error
call :check_import "OCR pipeline: ocrmypdf" "import ocrmypdf" || goto :startup_error
call :check_import "Local browser port: 127.0.0.1" "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); s.close()" || goto :startup_error

echo.
echo Starting Document OCR in your browser...
set "FAILED_STEP=starting the browser interface"
"%APP%\python.exe" "%~dp0system\web_gui.py" 2>>"%ERROR_LOG%"
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
"%APP%\python.exe" -c "%~2" 2>>"%ERROR_LOG%"
if errorlevel 1 (
  set "FAILED_STEP=%~1"
  set "EXIT_CODE=1"
  exit /b 1
)
echo OK: %~1
exit /b 0
