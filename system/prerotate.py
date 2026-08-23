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
Tesseract's orientation detector reports an angle and a confidence, and the
confidence tracks how much text is on the page rather than how sure the angle
is: dense contract pages score 26-34, drawing sheets 0.7-1.9. In testing the
angle was correct even at the bottom of that range, so any angle it offers is
acted on. When it finds too little text to offer one at all -- a page that is
nearly all diagram -- the page is left exactly as it is, which is safer than
guessing.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import pikepdf
import pypdfium2 as pdfium

OSD_DPI = 300
MIN_CONFIDENCE = 0.01         # any angle the detector offers is acted on; see above
ROTATE_RE = re.compile(r"^Rotate:\s*(\d+)", re.M)
CONF_RE = re.compile(r"^Orientation confidence:\s*([\d.]+)", re.M)
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


def decide(page, workdir: Path, index: int, lang: str) -> tuple[int, str]:
    """Return (clockwise degrees needed to make this page upright, why)."""
    png = workdir / f"p{index}.png"
    page.render(scale=OSD_DPI / 72).to_pil().convert("L").save(png)
    turn, conf = osd_guess(png)
    if turn and conf >= MIN_CONFIDENCE:
        return turn, f"confidence {conf:.2f}"
    if conf >= MIN_CONFIDENCE:
        return 0, f"already upright, confidence {conf:.2f}"
    return 0, "too little text to tell which way up it is - left alone"


def prerotate(src: Path, dst: Path, lang: str = "eng", report=print, should_stop=None) -> list:
    """Write dst = src with every page upright. Only /Rotate changes; pixels do not.

    should_stop is polled once per page so a cancelled run stops on the next page
    rather than straightening the whole document first.
    """
    decisions = []
    render_doc = pdfium.PdfDocument(src)
    with pikepdf.open(src) as pdf, tempfile.TemporaryDirectory() as td:
        for i, page in enumerate(pdf.pages):
            if should_stop and should_stop():
                break
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
