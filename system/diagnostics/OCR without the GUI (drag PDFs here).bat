@echo off
call "%~dp0..\env.bat"
if "%~1"=="" (echo Drag one or more PDF files onto this file. & pause & exit /b)
:next
echo === %~nx1
"%APP%\python.exe" "%~dp0..\prerotate.py" "%~1" "%TEMP%\_upright.pdf"
"%APP%\python.exe" -X utf8 -s "%~dp0..\socketless_ocr.py" -l eng --use-threads --skip-text --output-type pdf --optimize 0 "%TEMP%\_upright.pdf" "%~dpn1_ocr.pdf"
if errorlevel 1 (echo FAILED: %~nx1) else (echo saved: %~dpn1_ocr.pdf)
shift
if not "%~1"=="" goto next
echo.& echo Done.& pause
