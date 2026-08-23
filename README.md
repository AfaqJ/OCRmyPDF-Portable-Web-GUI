# OCRmyPDF Portable — Web GUI

A fully portable [OCRmyPDF](https://github.com/ocrmypdf/OCRmyPDF) bundle for Windows,
plus a browser-based GUI. Built for a locked-down corporate PC: **no installer,
no admin rights, no Python on the machine, nothing added to PATH or the registry.**
Extract a folder, double-click a `.bat`, done. Delete the folder and it's gone.

Drop scanned PDFs on the page → press Start → get searchable PDFs with an invisible
text layer, with sideways and upside-down pages turned upright automatically.

## Why a browser GUI

The Tk front-end this started as would not run on the target machine: `_tkinter.pyd`
failed with `%1 is not a valid Win32 application` even with every Tcl/Tk DLL present,
correct and 64-bit. Rather than keep fighting it, the GUI moved to
`http.server` — Python's own standard library — serving one page on `127.0.0.1`.

No framework, no dependency, no build step. One file: [`src/web_gui.py`](src/web_gui.py).

## Using it

| | |
|---|---|
| `Start OCRmyPDF.bat` | opens the GUI in your browser |
| `OCR (drag PDFs here).bat` | drag PDFs onto it, results appear as `NAME_ocr.pdf` |
| `Check rotation (drag PDFs here).bat` | reports each page's detected angle, changes nothing |
| `Self test.bat` | six checks, ending in a real OCR run and a real rotation |

## Building the bundle

`src/` holds the scripts. The 300 MB `app/` runtime is not in the repo — build it:

```bash
./build_bundle.sh
```

Runs on macOS or Linux. Nothing is compiled: `micromamba --platform win-64` unpacks
prebuilt Windows binaries (Python 3.12, Tesseract 5.5.3, Ghostscript 10.07.1, Tk) and
`pip --platform win_amd64` fetches prebuilt cp312 wheels. A Windows machine is never
involved.

## Three things that cost real time

**Tesseract's config files live in a different tree from its language data.**
conda-forge installs `eng.traineddata` under `app/share/tessdata` but `configs/`
under `app/Library/share/tessdata`. `TESSDATA_PREFIX` points at one directory, and
OCRmyPDF always invokes tesseract with the `hocr` config — so OCR dies with
`read_params_file: Can't open hocr` while `--list-langs` works perfectly.
Consolidate the two trees.

**Python 3.8+ ignores `PATH` for extension-module dependencies.** Only the directory
holding the `.pyd`, the system directories, and paths registered via
`os.add_dll_directory()` are searched. Putting `Library\bin` on `PATH` does nothing
for `_tkinter.pyd`.

**`--rotate-pages` alone does not rotate drawing sheets.** Tesseract reports an
orientation *and* a confidence, and confidence tracks how much text is on the page:

| page | confidence | default threshold 14 |
|---|---|---|
| dense text (contracts, schedules) | 26 – 34 | rotates |
| sparse (drawings, single-line diagrams) | 0.7 – 1.6 | **refuses** |

The reported *angle* was correct in every low-confidence case — only the confidence
was low. `--rotate-pages-threshold 0.1` lets them through. Lowering it is safe
because an already-upright page reports 0°, and a zero correction is ignored at any
threshold.

Verified on 15 generated pages — landscape and portrait, dense and sparse, turned
left, turned right, upside down, already upright — by rendering each output page to
an image and OCRing *that image*, not by reading the text layer (which reads back
correctly regardless of how the page displays).

## Limitations

- English only (`eng`). Other languages need the matching `.traineddata` in
  `app/share/tessdata`.
- A page with almost no text gives the orientation detector nothing to work with and
  is left alone.
- Windows x64 only.

## Licence

The scripts here are MIT. The bundled components keep their own licences —
OCRmyPDF (MPL-2.0), Tesseract (Apache-2.0), Ghostscript (AGPL-3.0), Python (PSF).
Ghostscript's AGPL is worth a look before redistributing a built bundle.
