@echo off
rem Use this when double-clicking START OCR.bat does nothing.
rem
rem It runs START OCR.bat in debug mode and saves every line to
rem system\logs\troubleshoot.txt, then prints the whole thing. The output is
rem held back until the app closes, because it is being captured to the file --
rem that file is the one thing worth sending to whoever is helping.
setlocal
set "LOGDIR=%~dp0system\logs"
set "LOG=%LOGDIR%\troubleshoot.txt"
set "OCR_NO_PAUSE=1"
md "%LOGDIR%" 2>nul

echo Running the checks and then opening Document OCR...
echo.
echo Nothing will appear here until the OCR window is closed - the output is
echo being written to a file first. If no OCR window opens at all, wait a few
echo seconds and the reason will be printed below.
echo.

call "%~dp0START OCR.bat" debug > "%LOG%" 2>&1

echo ==================================================================
type "%LOG%"
echo ==================================================================
echo.
echo A copy of everything above is saved in:
echo   "%LOG%"
echo.
pause
