@echo off
rem Sets up the portable environment. Called by the other .bat files.
set "APP=%~dp0app"
set "PATH=%APP%;%APP%\Library\bin;%APP%\DLLs;%PATH%"
set "TESSDATA_PREFIX=%APP%\share\tessdata"
set "PYTHONHOME=%APP%"
set "PYTHONPATH=%APP%\Lib;%APP%\Lib\site-packages"
set "TCL_LIBRARY=%APP%\Library\lib\tcl8.6"
set "TK_LIBRARY=%APP%\Library\lib\tk8.6"
