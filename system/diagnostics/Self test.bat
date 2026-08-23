@echo off
call "%~dp0..\env.bat"
echo === 1. tesseract ===
"%APP%\Library\bin\tesseract.exe" --version
"%APP%\Library\bin\tesseract.exe" --list-langs
echo.& echo === 2. ghostscript ===
"%APP%\Library\bin\gswin64c.exe" --version
echo.& echo === 3. ocrmypdf ===
"%APP%\python.exe" -m ocrmypdf --version
echo.& echo === 4. the GUI ===
"%APP%\python.exe" "%~dp0..\web_gui.py" --selftest
echo.& echo === 5. real OCR, end to end ===
"%APP%\python.exe" -m ocrmypdf -l eng --skip-text --output-type pdf "%~dp0..\test-pages\sample_scan.pdf" "%TEMP%\st1.pdf"
"%APP%\python.exe" -c "import sys; from pdfminer.high_level import extract_text; print(extract_text(sys.argv[1])[:300])" "%TEMP%\st1.pdf"
echo.& echo === 6. rotation of a sideways page ===
"%APP%\python.exe" "%~dp0..\prerotate.py" "%~dp0..\test-pages\sample_rotated.pdf" "%TEMP%\st2pre.pdf"
"%APP%\python.exe" -m ocrmypdf -l eng --skip-text --output-type pdf --optimize 0 "%TEMP%\st2pre.pdf" "%TEMP%\st2.pdf"
"%APP%\python.exe" "%~dp0show_rotation.py" "%TEMP%\st2.pdf"
echo.& echo Steps 5 and 6 are the ones that matter.
pause
