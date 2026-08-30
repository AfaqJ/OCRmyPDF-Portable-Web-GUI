@echo off
rem Sets up the portable environment. Called by START OCR.bat only.
rem
rem Almost nothing needs this any more. The worker sets TESSDATA_PREFIX itself
rem from its own folder and calls tesseract.exe and gswin64c.exe by absolute
rem path, and those two find their DLLs in their own directory. What is left is
rem here because START OCR.bat's debug mode prints paths built from %APP%.
set "ROOT=%~dp0.."
set "APP=%ROOT%\app"
set "PATH=%APP%\Library\bin;%PATH%"
set "TESSDATA_PREFIX=%APP%\share\tessdata"
