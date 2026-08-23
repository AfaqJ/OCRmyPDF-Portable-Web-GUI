@echo off
rem Sets up the portable environment. Called by the launchers.
set "ROOT=%~dp0.."
set "APP=%ROOT%\app"
set "PATH=%APP%;%APP%\Library\bin;%APP%\DLLs;%PATH%"
set "TESSDATA_PREFIX=%APP%\share\tessdata"
set "PYTHONHOME=%APP%"
set "PYTHONPATH=%APP%\Lib;%APP%\Lib\site-packages"
set "PYTHONIOENCODING=utf-8"
set "PYTHONUTF8=1"
