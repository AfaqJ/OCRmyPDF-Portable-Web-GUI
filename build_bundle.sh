#!/usr/bin/env bash
# Build the portable Windows bundle. Runs on macOS or Linux -- no Windows
# machine needed, because nothing is compiled: micromamba downloads and unpacks
# prebuilt win-64 packages, and pip fetches prebuilt win_amd64 wheels.
set -euo pipefail
OUT=${1:-dist/OCRmyPDF_Portable}
PY=3.12

curl -Ls https://micro.mamba.pm/api/micromamba/$(uname -s | tr A-Z a-z)-$(uname -m)/latest \
  | tar -xj bin/micromamba

# 1. native Windows binaries: interpreter, Tk, Tesseract, Ghostscript
CONDA_OVERRIDE_WIN=10 ./bin/micromamba create -y -p "$OUT/app" --platform win-64 \
  -c conda-forge python=$PY tesseract ghostscript tk

# 2. OCRmyPDF and its dependencies as cp312 win_amd64 wheels
pip install --target "$OUT/app/Lib/site-packages" \
  --platform win_amd64 --python-version $PY --implementation cp \
  --only-binary=:all: --upgrade ocrmypdf

# 3. conda-forge splits tesseract's data across two trees: the .traineddata
#    files land in share/tessdata but configs/ lands in Library/share/tessdata.
#    TESSDATA_PREFIX can only point at one, and OCRmyPDF always invokes
#    tesseract with the "hocr" config -- so consolidate them or every run dies
#    with "read_params_file: Can't open hocr".
cp -R "$OUT/app/Library/share/tessdata/configs" \
      "$OUT/app/Library/share/tessdata/tessconfigs" "$OUT/app/share/tessdata/"

# 4. keep only English + orientation data; drop the other ~120 languages
find "$OUT/app/share/tessdata" -maxdepth 1 -name '*.traineddata' \
  ! -name 'eng.traineddata' ! -name 'osd.traineddata' -delete

# 5. Python 3.8+ ignores PATH when resolving an extension module's DLL
#    dependencies. _tkinter.pyd lives in app/DLLs but tcl86t.dll lives in
#    app/Library/bin, so it must be copied next to the .pyd or the import
#    fails with "%1 is not a valid Win32 application".
cp "$OUT/app/Library/bin/"{tcl86t.dll,tk86t.dll,zlib1.dll} "$OUT/app/DLLs/"

# 6. trim
rm -rf "$OUT/app"/{include,conda-meta,man} "$OUT/app/Library/include" \
       "$OUT/app/Lib"/{test,idlelib,ensurepip}
find "$OUT/app" \( -name '*.lib' -o -name '*.a' -o -name '*.pdb' \) -delete
find "$OUT/app" -name '__pycache__' -type d -prune -exec rm -rf {} +

cp src/* "$OUT/"
echo "built $OUT  ($(du -sh "$OUT" | cut -f1))"
