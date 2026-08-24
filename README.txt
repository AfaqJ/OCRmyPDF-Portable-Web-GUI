OCRmyPDF Portable
=================

Makes scanned PDFs searchable by adding an invisible text layer.
Nothing is installed. Delete this folder and it is gone.

TO USE IT
  Double-click  START OCR.bat
  A startup-check window opens and stays open; leave it running.
  The Windows-native Document OCR app opens:

      1. drag PDFs onto the window, or press Add PDFs
      2. choose where results should go
      3. press Start OCR
      4. press Open output folder when finished

  Originals are never modified. Close the black window when finished.

OPTIONS
  Document language   English, English + Arabic, or Arabic only.
  Auto-rotate pages   fixes pages scanned sideways or upside down. On by default.
  Redo OCR            use when the file already has a wrong text layer.
  Show technical detail  shows the internal processing log.

IF SOMETHING GOES WRONG
  START OCR.bat checks every required component and saves a readable report.
  system\diagnostics\Self test.bat runs deeper checks and ends with a real OCR.
  system\diagnostics\OCR without the GUI (drag PDFs here).bat  processes a batch
  with no window at all - useful for a large folder.

WHAT IS INSIDE
  START OCR.bat   the launcher, the only thing you need
  app\            Python, Tesseract, Ghostscript, OCRmyPDF - do not touch
  system\         the program itself and its diagnostics
