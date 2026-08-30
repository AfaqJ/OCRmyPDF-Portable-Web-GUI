@echo off
rem Builds "Document OCR.exe" into the main folder, from Launcher.cs.
rem
rem It uses the C# compiler that is already part of Windows -- there is no SDK,
rem no Visual Studio and nothing to install. Run this once on Windows after
rem changing Launcher.cs. End users never run this file; it lives in
rem system\launcher\ so it is not sitting next to START OCR.bat.
rem
rem Same path rules as every other .bat here: quote everything, expand no path
rem inside a parenthesised block, branch with goto.
setlocal
set "SRC=%~dp0Launcher.cs"
set "OUT=%~dp0..\..\Document OCR.exe"
set "CSC=%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%SystemRoot%\Microsoft.NET\Framework\v4.0.30319\csc.exe"

if not exist "%CSC%" goto :nocsc
if not exist "%SRC%" goto :nosrc

echo Building Document OCR.exe
echo   compiler: "%CSC%"
echo   source:   "%SRC%"
echo.

"%CSC%" /nologo /target:winexe /platform:anycpu /out:"%OUT%" /reference:System.dll /reference:System.Windows.Forms.dll "%SRC%"
if errorlevel 1 goto :failed

echo.
echo Done. Created:
echo   "%OUT%"
echo.
echo Double-click "Document OCR.exe" in the main folder to open the app.
echo START OCR.bat is unchanged and still works - keep it. If the .exe is
echo blocked or does nothing, use the .bat and the app is unaffected.
echo.
pause
exit /b 0

:nocsc
echo The C# compiler that ships with Windows was not found:
echo   "%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
echo.
echo That means .NET Framework 4.x is missing, which would also stop the OCR
echo window itself from opening. Nothing to fix here - report it.
echo.
pause
exit /b 1

:nosrc
echo Launcher.cs is missing next to this file:
echo   "%SRC%"
echo.
pause
exit /b 1

:failed
echo.
echo The build FAILED. The compiler messages are above - send them.
echo Nothing was changed; START OCR.bat still works.
echo.
pause
exit /b 1
