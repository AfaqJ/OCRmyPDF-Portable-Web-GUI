"""Print the /Rotate value stored on each page. Changes nothing.

/Rotate is how a PDF says "display this page turned by N degrees". OCRmyPDF's
--rotate-pages sets it, which is why a page can look upright in a viewer while
the underlying scan is still stored sideways.
"""
import sys

import pikepdf


def main(paths: list[str]) -> int:
    if not paths:
        print(__doc__)
        print("usage: show_rotation.py FILE.pdf [FILE.pdf ...]")
        return 1
    for path in paths:
        with pikepdf.open(path) as pdf:
            rotations = [int(page.obj.get("/Rotate", 0)) for page in pdf.pages]
        print(f"{path}: /Rotate per page = {rotations}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
