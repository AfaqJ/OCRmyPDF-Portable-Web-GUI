@echo off
title OCRmyPDF - leave this window open
call "%~dp0system\env.bat"
"%APP%\python.exe" "%~dp0system\web_gui.py"
