"""Report what Tesseract's orientation detector (OSD) sees on each page.

Run it on a PDF whose pages come out sideways. It does not change anything --
it prints, per page, the rotation Tesseract thinks is needed and how confident
it is. OCRmyPDF's --rotate-pages only acts when that confidence reaches
--rotate-pages-threshold (default 14.0), so these numbers say whether to lower
the threshold or whether OSD is failing outright.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

import pypdfium2 as pdfium

DPI = 300
DEFAULT_THRESHOLD = 14.0


def osd(png: Path, timeout: float = 120.0) -> tuple[int, float, str]:
    """Return (clockwise angle to correct, confidence, note) for one page image."""
    proc = subprocess.run(
        ["tesseract", "-l", "osd", "--psm", "0", str(png), "stdout"],
        capture_output=True, text=True, timeout=timeout,
    )
    fields = {}
    for line in proc.stdout.splitlines():
        key, sep, value = line.partition(":")
        if sep:
            fields[key.strip()] = value.strip()
    if "Orientation in degrees" not in fields:
        blob = (proc.stdout + proc.stderr).strip().replace("\n", " ")
        return 0, 0.0, blob[-70:] or "no OSD output"
    return (
        int(fields["Orientation in degrees"]),
        float(fields.get("Orientation confidence", 0)),
        f"script={fields.get('Script', '?')}",
    )


def report(pdf: Path) -> None:
    doc = pdfium.PdfDocument(pdf)
    print(f"\n=== {pdf.name} — {len(doc)} page(s), OSD at {DPI} dpi")
    print(f"{'page':>5}  {'page shape':<10} {'rotate':>7} {'confidence':>11}  note")
    angles: dict[int, int] = {}
    weak = 0
    with tempfile.TemporaryDirectory() as td:
        for number, page in enumerate(doc, start=1):
            width, height = page.get_size()
            shape = "landscape" if width > height else "portrait"
            image = page.render(scale=DPI / 72).to_pil().convert("L")
            png = Path(td) / f"page{number}.png"
            image.save(png)
            angle, confidence, note = osd(png)
            angles[angle] = angles.get(angle, 0) + 1
            if angle and confidence < DEFAULT_THRESHOLD:
                weak += 1
            print(f"{number:>5}  {shape:<10} {angle:>6}° {confidence:>11.2f}  {note}")

    print("\nsummary:", ", ".join(f"{count} page(s) need {angle}°"
                                 for angle, count in sorted(angles.items())))
    if weak:
        print(f"{weak} page(s) need rotating but score below the default "
              f"threshold of {DEFAULT_THRESHOLD} — they are why --rotate-pages "
              f"appears to do nothing. Re-run OCR with a lower value, e.g. "
              f"--rotate-pages --rotate-pages-threshold 0.1")
    elif set(angles) == {0}:
        print("OSD sees every page as already upright. If they still look "
              "sideways, OSD is not reading the text — check the note column.")
    else:
        print("Every page needing rotation scores above the default threshold; "
              "plain --rotate-pages should fix this file.")


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        print("usage: osd_report.py FILE.pdf [FILE.pdf ...]")
        return 1
    for arg in argv:
        report(Path(arg))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
