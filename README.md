# Document OCR (portable, Windows 64-bit)

Makes scanned PDFs searchable by adding an invisible text layer behind the
scan. The page still looks exactly the same; the text can now be selected,
copied, searched, and indexed by compatible document systems.

Nothing is installed. No admin rights, no Python on the machine, nothing added
to PATH or the registry. Download, extract, double-click. Delete the folder and
it is gone.

English and Arabic. The interface is available in both.

## Get it

Click "Code" then "Download ZIP", and extract the folder somewhere on disk.

## Use it

Double-click `START OCR.bat`. A black window opens and stays open - that is
the program, leave it running. The tool itself opens in your browser.

    1. Drag PDFs onto the page
    2. Choose the folder where results should go
    3. Press Start OCR
    4. Press Save to folder

Your original files are never changed. Results are saved as `NAME_ocr.pdf`.
Closing the black window shuts everything down.

## Options

    Document language      English, English + Arabic, or Arabic.
    Auto-rotate pages      Turns sideways and upside-down scans upright
                           before reading them. On by default.
    Redo OCR               For files that already have a wrong text layer.
                           Off means pages holding real text are left alone.
    Show technical detail  Puts every internal step in the log.

## Good to know

    - Pages with almost no text (a drawing, a stamp) cannot be checked for
      orientation, so they are left exactly as they are.
    - English + Arabic reads every page twice, once per script. It is slower,
      and Arabic on scans is read less accurately than English.
    - Arabic text is stored in the page in visual order, so searching for an
      exact Arabic phrase may not match. English is not affected.
    - Expect a few seconds per page. All processor cores are used.

## If something goes wrong

Run `system\diagnostics\Self test.bat`. It runs six checks and ends with a
real OCR of a test page, so it tells you what is broken rather than guessing.

For a large batch with no window at all, drag files onto
`system\diagnostics\OCR without the GUI (drag PDFs here).bat`.

## Rebuilding the bundled programs

    ./build_bundle.sh

Runs on macOS or Linux. It downloads the official Windows builds and the
matching Python packages and arranges them in `app\`. Nothing is compiled and
no Windows machine is needed.

## What is inside, and its licensing

This project is a wrapper. The scripts here add a browser interface, Arabic
language data, and a step that turns pages upright before reading them. The
programs that do the actual work are unmodified copies of other people's
software, redistributed under their own licences:

    OCRmyPDF 17.10.0     MPL-2.0        the OCR pipeline
    Tesseract 5.5.3      Apache-2.0     the OCR engine
    Ghostscript 10.07.1  AGPL-3.0       PDF processing
    Python 3.12          PSF            runs everything
    pikepdf, Pillow, pypdfium2, lxml and others
                         MPL-2.0, MIT, BSD, Apache-2.0
    fpdf2, img2pdf       LGPL-3.0       used by OCRmyPDF
    Language data        Apache-2.0     from the Tesseract project

Full licence texts are in `LICENSES\`, and `LICENSES\NOTICE.txt` lists every
bundled program with its version and where its source is published.

Ghostscript is the one to be aware of. Artifex publishes it under the GNU
Affero General Public License, or a paid commercial licence. Passing this
bundle to anyone else counts as redistribution, so the AGPL terms travel with
it, including the requirement that the source code stays available. The copy
here is unmodified and its source is published at
https://ghostscript.com/releases/ . If this is ever built into a product that
is sold, or offered as a service to people outside the organisation, read the
AGPL first or buy the commercial licence from Artifex.

The scripts written for this project (`START OCR.bat`, everything in
`system\`, and `build_bundle.sh`) are released under the MIT licence - see
`LICENSE`. They call the bundled programs as separate programs, the same way
OCRmyPDF itself calls Ghostscript, and do not modify them.
