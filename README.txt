OCRmyPDF Portable
=================

Makes scanned PDFs searchable by adding an invisible text layer.
Nothing is installed. Delete this folder and it is gone.

TO USE IT
  Double-click  START OCR.bat
  A black window opens and stays open - that is the program, leave it running.
  Your browser opens on the tool:

      1. drag PDFs onto the page
      2. choose where results should go
      3. press Start OCR
      4. press Save to folder

  Originals are never modified. Close the black window when finished.

OPTIONS
  Every option has an (i) next to it that explains what it does.
  Document language   English, English + Arabic, or Arabic only.
  Auto-rotate pages   fixes pages scanned sideways or upside down. On by default.
  Redo OCR            use when the file already has a wrong text layer.
  Deskew              straightens slightly tilted scans.

IF SOMETHING GOES WRONG
  system\diagnostics\Self test.bat  runs six checks and ends with a real OCR.
  system\diagnostics\OCR without the GUI (drag PDFs here).bat  processes a batch
  with no window at all - useful for a large folder.

WHAT IS INSIDE
  START OCR.bat   the launcher, the only thing you need
  app\            Python, Tesseract, Ghostscript, OCRmyPDF - do not touch
  system\         the program itself and its diagnostics
