@echo off
call "%~dp0env.bat"
"%APP%\python.exe" "%~dp0web_gui.py"
