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

**`--rotate-pages` alone will not rotate drawing sheets.** Tesseract reports an
orientation *and* a confidence, and confidence tracks how much text is on the page:

| page | confidence | at the default threshold of 14 |
|---|---|---|
| dense text (contracts, schedules) | 26 – 34 | rotates |
| sparse (drawings, single-line diagrams) | 0.7 – 1.6 | **refuses** |

The reported angle was correct in every low-confidence case — only the confidence was
low. `--rotate-pages-threshold 0.1` lets them through, and is safe because an
upright page reports 0°, which is ignored at any threshold.

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
