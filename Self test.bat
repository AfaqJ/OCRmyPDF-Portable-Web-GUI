@echo off
call "%~dp0env.bat"
echo === 1. tesseract ===
"%APP%\Library\bin\tesseract.exe" --version
"%APP%\Library\bin\tesseract.exe" --list-langs
echo.
echo === 2. ghostscript ===
"%APP%\Library\bin\gswin64c.exe" --version
echo.
echo === 3. ocrmypdf ===
"%APP%\python.exe" -m ocrmypdf --version
echo.
echo === 4. browser GUI ===
"%APP%\python.exe" "%~dp0web_gui.py" --selftest
echo.
echo === 5. real OCR, end to end ===
"%APP%\python.exe" -m ocrmypdf -l eng --skip-text --output-type pdf "%~dp0sample_scan.pdf" "%TEMP%\sample_scan_ocr.pdf"
echo --- text read back out of the OCR output ---
"%APP%\python.exe" -c "import sys; from pdfminer.high_level import extract_text; print(extract_text(sys.argv[1])[:400])" "%TEMP%\sample_scan_ocr.pdf"
echo.
echo === 6. auto-rotation of a sideways page ===
"%APP%\python.exe" -m ocrmypdf -l eng --skip-text --output-type pdf --rotate-pages --rotate-pages-threshold 0.1 "%~dp0sample_rotated.pdf" "%TEMP%\sample_rotated_ocr.pdf"
"%APP%\python.exe" "%~dp0show_rotation.py" "%TEMP%\sample_rotated_ocr.pdf"
echo.
echo Steps 5 and 6 are the ones that matter: text read back, page turned upright.
pause
