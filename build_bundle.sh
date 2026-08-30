#!/usr/bin/env bash
# Rebuild app/ -- the portable Windows runtime. Runs on macOS or Linux; no
# Windows machine and no compiler are needed, because nothing is compiled:
# micromamba unpacks prebuilt win-64 packages.
set -euo pipefail
APP=app

curl -Ls https://micro.mamba.pm/api/micromamba/$(uname -s | tr A-Z a-z)-$(uname -m)/latest \
  | tar -xj bin/micromamba

rm -rf "$APP"
# No python and no tk. This branch drives tesseract.exe and gswin64c.exe from
# PowerShell/.NET, so the interpreter, OCRmyPDF and every wheel it pulled are
# dead weight -- about half the download. Neither engine depends on Python, but
# the cleanup below removes it anyway in case a future package drags it in.
CONDA_OVERRIDE_WIN=10 ./bin/micromamba create -y -p "$APP" --platform win-64 \
  -c conda-forge tesseract ghostscript

# conda-forge splits tesseract's data across two trees: .traineddata files land
# in share/tessdata but configs/ lands in Library/share/tessdata. TESSDATA_PREFIX
# points at one directory only, and a config is named on every tesseract call
# we make ("pdf" in Invoke-TesseractPdf) -- so without this every run dies with
# "read_params_file: Can't open ...". It was OCRmyPDF's "hocr" config that
# first exposed this; the need did not go away with OCRmyPDF.
cp -R "$APP/Library/share/tessdata/configs" \
      "$APP/Library/share/tessdata/tessconfigs" "$APP/share/tessdata/"

# keep English, Arabic and orientation data; drop the other ~120 languages
find "$APP/share/tessdata" -maxdepth 1 -name '*.traineddata' \
  ! -name 'eng.traineddata' ! -name 'osd.traineddata' -delete
curl -Ls -o "$APP/share/tessdata/ara.traineddata" \
  https://github.com/tesseract-ocr/tessdata/raw/main/ara.traineddata

# NB: keep any LICENSE/COPYING files. Stripping them would breach the AGPL and
# Apache terms the bundled programs are redistributed under.
rm -rf "$APP"/{include,conda-meta,man} "$APP/Library/include"

# Belt and braces: if a dependency ever drags Python or Tcl/Tk back in, drop it
# again here rather than letting the bundle quietly regrow by 150 MB.
rm -rf "$APP"/{Lib,DLLs,libs,Scripts,Tools,bin,etc} "$APP/share/zoneinfo" \
       "$APP"/python*.exe "$APP"/python*.dll "$APP/LICENSE_PYTHON.txt"
rm -rf "$APP/Library/lib"/{tcl*,tk*,itcl*,thread*,tdbc*,cmake,nmake}
# The engines carry their own complete C runtime in Library/bin, so the copies
# conda drops at the environment root were only ever there for Python.
rm -f "$APP"/{api-ms-win-*.dll,msvcp140*.dll,vcruntime140*.dll,ucrtbase.dll} \
      "$APP"/{concrt140.dll,vcamp140.dll,vccorlib140.dll,vcomp140.dll,zlib.dll}

find "$APP" \( -name '*.lib' -o -name '*.a' -o -name '*.pdb' \) -delete
find "$APP" -name '__pycache__' -type d -prune -exec rm -rf {} +
echo "built $APP ($(du -sh "$APP" | cut -f1))"
