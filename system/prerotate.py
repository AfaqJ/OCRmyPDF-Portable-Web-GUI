"""Turn every page upright *before* OCRmyPDF sees it.

Why this exists
---------------
OCRmyPDF's own --rotate-pages places the text layer wrongly when the incoming
page already carries a /Rotate flag -- which is what most scanners produce.
Measured on a real scan: 830 px of error, 5 of 181 words landing on their word.
Rotating first and handing OCRmyPDF an already-upright page avoids the problem
entirely, and needs no patch to the library.

How pages are judged
--------------------
Tesseract's orientation detector (OSD) is tried first. It is cheap but gives up
on pages with little text -- drawings, title sheets, stamps -- which is why so
many pages came back unrotated. When it abstains or is unsure, each of the four
orientations is OCR'd and the one whose text scores best wins. That is four
times the work, so it only runs on the pages OSD could not settle.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import pikepdf
import pypdfium2 as pdfium

OSD_DPI = 300
PROBE_DPI = 150               # the four-way fallback does not need full detail
OSD_TRUSTED = 1.0             # OSD confidence at or above this is taken as final
ROTATE_RE = re.compile(r"^Rotate:\s*(\d+)", re.M)
CONF_RE = re.compile(r"^Orientation confidence:\s*([\d.]+)", re.M)
WORD_RE = re.compile(r"^(\S+)\s+(\d+)$")
NO_WINDOW = 0x08000000 if sys.platform == "win32" else 0


def tesseract() -> str:
    local = Path(sys.executable).parent / "Library" / "bin" / "tesseract.exe"
    return str(local) if local.exists() else "tesseract"


def _run(args: list) -> str:
    r = subprocess.run([tesseract(), *args], capture_output=True, text=True,
                       errors="replace", creationflags=NO_WINDOW)
    return r.stdout + r.stderr


def osd_guess(png: Path) -> tuple[int, float]:
    """Tesseract's own orientation call: (clockwise degrees to upright, confidence)."""
    out = _run([str(png), "stdout", "--psm", "0", "-l", "osd"])
    rot, conf = ROTATE_RE.search(out), CONF_RE.search(out)
    if not rot or not conf:
        return 0, 0.0
    return int(rot.group(1)) % 360, float(conf.group(1))


def score(png: Path, lang: str) -> float:
    """How much readable text OCR finds here: count of real words."""
    text = _run([str(png), "stdout", "-l", lang, "--psm", "6"])
    return float(len([w for w in text.split() if len(w) > 2 and any(c.isalnum() for c in w)]))


def four_way(img, workdir: Path, lang: str) -> tuple[int, float]:
    """OCR all four orientations and keep the one that reads best."""
    results = []
    for turn in (0, 90, 180, 270):
        probe = workdir / f"probe{turn}.png"
        (img.rotate(-turn, expand=True) if turn else img).save(probe)
        results.append((score(probe, lang), turn))
    results.sort(reverse=True)
    best_score, best_turn = results[0]
    runner_up = results[1][0]
    # a clear winner means real text; a tie means the page has nothing to read
    margin = (best_score - runner_up) / best_score if best_score else 0.0
    return (best_turn, margin) if best_score >= 4 and margin >= 0.2 else (0, 0.0)


def decide(page, workdir: Path, index: int, lang: str) -> tuple[int, str]:
    """Return (clockwise degrees needed, how it was decided)."""
    png = workdir / f"p{index}.png"
    page.render(scale=OSD_DPI / 72).to_pil().convert("L").save(png)
    turn, conf = osd_guess(png)
    if conf >= OSD_TRUSTED:
        return turn, f"orientation detector, confidence {conf:.2f}"
    small = page.render(scale=PROBE_DPI / 72).to_pil().convert("L")
    turn2, margin = four_way(small, workdir, lang)
    if turn2:
        return turn2, f"read all four ways, {margin:.0%} clearer than the next"
    if turn and conf > 0:
        return turn, f"orientation detector, low confidence {conf:.2f}"
    return 0, "too little text to judge"


def prerotate(src: Path, dst: Path, lang: str = "eng", report=print) -> list:
    """Write dst = src with every page upright. Only /Rotate changes; pixels do not."""
    decisions = []
    render_doc = pdfium.PdfDocument(src)
    with pikepdf.open(src) as pdf, tempfile.TemporaryDirectory() as td:
        for i, page in enumerate(pdf.pages):
            turn, why = decide(render_doc[i], Path(td), i, lang)
            if turn:
                page.obj["/Rotate"] = (int(page.obj.get("/Rotate", 0)) + turn) % 360
            decisions.append((i + 1, turn, why))
            if report:
                what = f"turned {turn} deg clockwise" if turn else "left upright"
                report(f"   page {i + 1}: {what}  ({why})")
        pdf.save(dst)
    return decisions


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        assert ROTATE_RE.search("Rotate: 270\n").group(1) == "270"
        assert CONF_RE.search("Orientation confidence: 1.52\n").group(1) == "1.52"
        assert osd_guess.__doc__ and prerotate.__doc__
        print("prerotate selftest ok")
    elif len(sys.argv) >= 3:
        prerotate(Path(sys.argv[1]), Path(sys.argv[2]))
    else:
        sys.exit("usage: prerotate.py input.pdf output.pdf")
