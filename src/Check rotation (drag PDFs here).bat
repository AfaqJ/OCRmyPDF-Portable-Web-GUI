@echo off
call "%~dp0env.bat"
if "%~1"=="" (
  echo Drag PDFs onto this file to see what Tesseract thinks each page.s
  echo orientation is. Nothing is changed - it only reports.
  pause
  exit /b
)
:next
"%APP%\python.exe" "%~dp0osd_report.py" "%~1"
shift
if not "%~1"=="" goto next
pause
