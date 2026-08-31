#!/usr/bin/env bash
# Build the work-PC package: the runtime tree only. No Git metadata, no
# maintainer docs, no build or check scripts -- and it DOES carry the ignored
# system/orientation_words.json, which is the whole reason this cannot be a
# `git archive`.
set -euo pipefail
OUT="${1:-$HOME/Desktop/OCR-Tool/ocr tool pc.zip}"
STAGE="$(mktemp -d)"
rsync -a --exclude-from=- ./ "$STAGE/OCR Tool/" <<'EX'
.git/
__pycache__/
.DS_Store
docs/
scratch/
.gitignore
AGENTS.md
CLAUDE.md
OCR_Tool_Documentation.md
build_bundle.sh
check_ps1.py
package_pc.sh
EX
# Stamp the build so the running app can say which one it is. Two rounds of
# "why is the log still saying X" turned out to be a stale folder on the target
# PC; nothing on screen could tell the builds apart. Not tracked in git -- it
# is generated here, into the package only.
printf '%s %s\n' "$(git rev-parse --short HEAD)" "$(date '+%Y-%m-%d %H:%M')" \
  > "$STAGE/OCR Tool/system/build.txt"

rm -f "$OUT"
(cd "$STAGE" && zip -qrX "$OUT" "OCR Tool")
rm -rf "$STAGE"
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
