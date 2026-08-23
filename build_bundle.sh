#!/usr/bin/env bash
# Rebuild app/ -- the portable Windows runtime. Runs on macOS or Linux; no
# Windows machine and no compiler are needed, because nothing is compiled:
# micromamba unpacks prebuilt win-64 packages and pip fetches prebuilt
# win_amd64 wheels.
set -euo pipefail
PY=3.12
APP=app

curl -Ls https://micro.mamba.pm/api/micromamba/$(uname -s | tr A-Z a-z)-$(uname -m)/latest \
  | tar -xj bin/micromamba

rm -rf "$APP"
CONDA_OVERRIDE_WIN=10 ./bin/micromamba create -y -p "$APP" --platform win-64 \
  -c conda-forge python=$PY tesseract ghostscript tk

pip install --target "$APP/Lib/site-packages" \
  --platform win_amd64 --python-version $PY --implementation cp \
  --only-binary=:all: --upgrade ocrmypdf

# conda-forge splits tesseract's data across two trees: .traineddata files land
# in share/tessdata but configs/ lands in Library/share/tessdata. TESSDATA_PREFIX
# points at one directory only, and OCRmyPDF always calls tesseract with the
# "hocr" config -- so without this every run dies with "Can't open hocr".
cp -R "$APP/Library/share/tessdata/configs" \
      "$APP/Library/share/tessdata/tessconfigs" "$APP/share/tessdata/"

# keep English, Arabic and orientation data; drop the other ~120 languages
find "$APP/share/tessdata" -maxdepth 1 -name '*.traineddata' \
  ! -name 'eng.traineddata' ! -name 'osd.traineddata' -delete
curl -Ls -o "$APP/share/tessdata/ara.traineddata" \
  https://github.com/tesseract-ocr/tessdata/raw/main/ara.traineddata

# Python 3.8+ ignores PATH when resolving an extension module's DLL
# dependencies, so tcl/tk must sit next to _tkinter.pyd rather than in
# Library/bin. (The GUI is browser-based and does not need Tk, but the
# interpreter still imports it in places.)
cp "$APP/Library/bin/"{tcl86t.dll,tk86t.dll,zlib1.dll} "$APP/DLLs/"

rm -rf "$APP"/{include,conda-meta,man} "$APP/Library/include" \
       "$APP/Lib"/{test,idlelib,ensurepip}
find "$APP" \( -name '*.lib' -o -name '*.a' -o -name '*.pdb' \) -delete
find "$APP" -name '__pycache__' -type d -prune -exec rm -rf {} +
echo "built $APP ($(du -sh "$APP" | cut -f1))"
