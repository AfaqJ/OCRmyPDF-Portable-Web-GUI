@echo off
call "%~dp0env.bat"
if "%~1"=="" (
  echo Drag one or more PDF files onto this .bat file to OCR them.
  echo Each result is written next to the original as NAME_ocr.pdf
  pause
  exit /b
)
:next
echo === %~nx1
"%APP%\python.exe" -m ocrmypdf -l eng --skip-text --output-type pdf --rotate-pages --rotate-pages-threshold 0.1 "%~1" "%~dpn1_ocr.pdf"
if errorlevel 1 (echo FAILED: %~nx1) else (echo saved: %~dpn1_ocr.pdf)
shift
if not "%~1"=="" goto next
echo.
echo Done.
pause
