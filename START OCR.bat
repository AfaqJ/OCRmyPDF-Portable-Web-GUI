@echo off
setlocal
title OCRmyPDF - leave this window open
call "%~dp0system\env.bat"
set "ERROR_LOG=%~dp0OCR startup error.txt"
del "%ERROR_LOG%" 2>nul

if not exist "%APP%\python.exe" goto :missing
if not exist "%APP%\Lib\http\server.py" goto :missing
if not exist "%APP%\Lib\site-packages\ocrmypdf\__init__.py" goto :missing
if not exist "%APP%\Lib\site-packages\pikepdf\__init__.py" goto :missing
if not exist "%APP%\Lib\site-packages\pypdfium2\__init__.py" goto :missing

"%APP%\python.exe" "%~dp0system\web_gui.py" 2>"%ERROR_LOG%"
set "EXIT_CODE=%ERRORLEVEL%"
if "%EXIT_CODE%"=="0" goto :end

echo.
echo OCR did not start. The error is shown below and saved in:
echo %ERROR_LOG%
echo.
type "%ERROR_LOG%"
echo.
pause
goto :end

:missing
echo.
echo OCR cannot find a required portable file in the app folder.
echo Extract the complete ZIP before running this file.
echo Missing or unreadable files can also be checked by security software.
echo.
pause
set "EXIT_CODE=1"

:end
exit /b %EXIT_CODE%
