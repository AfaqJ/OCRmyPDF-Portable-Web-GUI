# OCRmyPDF Portable — Web GUI

Makes scanned PDFs searchable by adding an invisible text layer. Built for a
locked-down corporate Windows PC: **no installer, no admin rights, no Python on the
machine, nothing added to PATH or the registry.** Download, extract, double-click.

English and Arabic interface. Pages scanned sideways or upside down are turned
upright automatically.

## Use it

**Code → Download ZIP**, extract, double-click **`START OCR.bat`**. A console window
opens and stays open — that is the program — and the tool appears in your browser.

Drag PDFs onto the page → choose a save folder → Start OCR → Save to folder.

```
START OCR.bat          the launcher, the only thing to click
app/                   Python 3.12, Tesseract 5.5.3, Ghostscript 10.07.1, OCRmyPDF 17.10.0
system/                web_gui.py and env.bat
system/diagnostics/    self test, and a no-GUI batch runner
```

## Why the GUI is a web page

The Tk version would not load on the target machine: `_tkinter.pyd` failed with
`%1 is not a valid Win32 application` with every Tcl/Tk DLL present, correct and
64-bit. So the GUI moved to `http.server` — Python's own standard library — serving
one page on `127.0.0.1`. No framework, no dependency, no build step. One file:
[`system/web_gui.py`](system/web_gui.py).

## Rebuilding the runtime

```bash
./build_bundle.sh
```

Runs on macOS or Linux. `micromamba --platform win-64` unpacks prebuilt Windows
binaries and `pip --platform win_amd64` fetches prebuilt cp312 wheels. Nothing is
compiled and no Windows machine is involved.

## Three things that cost real time

**Tesseract's config files live in a different tree from its language data.**
conda-forge puts `eng.traineddata` in `app/share/tessdata` but `configs/` in
`app/Library/share/tessdata`. `TESSDATA_PREFIX` points at one directory, and
OCRmyPDF always calls tesseract with the `hocr` config — so OCR dies with
`read_params_file: Can't open hocr` while `--list-langs` works perfectly.

**Python 3.8+ ignores `PATH` for extension-module dependencies.** Only the directory
holding the `.pyd`, the system directories, and paths added via
`os.add_dll_directory()` are searched.

**`--rotate-pages` puts the text layer in the wrong place.** Not always — only when
the incoming page already carries a `/Rotate` flag, which is what most scanners
produce. The page is turned correctly and looks right; the invisible text lands
where the words used to be. Measured on a real scan, page rendered at 150 dpi:

| input page | median distance between a word and its text | words matched |
|---|---|---|
| upright | 2.8 px | 182 / 185 |
| sideways, no flag | 2.7 px | 176 / 181 |
| upside down, no flag | 2.8 px | 184 / 185 |
| **sideways, with a `/Rotate` flag** | **830.5 px** | **5 / 181** |

So [`system/prerotate.py`](system/prerotate.py) turns each page upright *first*, and
OCRmyPDF is then run without `--rotate-pages` on a page that is already the right way
up. Only `/Rotate` is changed; the scanned pixels are untouched. That brings the last
row back to 2.7 px and 176 of 181 words.

**Orientation detection abstains on sparse pages.** Tesseract reports an angle and a
confidence, and the confidence tracks how much text is on the page rather than how sure
the angle is — dense contract pages score 26–34, drawing sheets 0.7–1.9, and pages that
are nearly all diagram return no angle at all. Across 11 test pages the angle was
correct even at the bottom of that range, so `prerotate.py` acts on any angle offered
and leaves the no-angle pages exactly as they are. Guessing those was tried and
measured: OCRing all four orientations and keeping the best-scoring one picked the
wrong way up on pages carrying a single label, so it was removed. A page with almost no
text is left alone rather than turned at random.

## Limitations

- English and Arabic only. Other languages need the matching `.traineddata` in
  `app/share/tessdata`.
- Arabic accuracy on scans is lower than English.
- A page with almost no text gives the orientation detector nothing to work with and
  is left alone.
- Windows x64 only.

## Licence

Scripts here are MIT. Bundled components keep their own licences — OCRmyPDF
(MPL-2.0), Tesseract (Apache-2.0), Ghostscript (AGPL-3.0), Python (PSF). Read
Ghostscript's AGPL before redistributing a built bundle.
