"""Socket-free OCR worker for the Windows Forms front end.

The GUI starts this process and reads one JSON event per stdout line. OCR is
performed in a temporary job directory; completed files alone are copied to
the user's chosen destination, so cancellation cannot overwrite originals.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import traceback
from collections import deque
from pathlib import Path
from typing import TextIO

CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0
LANGS = {"eng": "eng", "eng+ara": "eng+ara", "ara": "ara"}
ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
PAGE_NO = re.compile(r"^\s*(\d+)\s+\S")
FACING = re.compile(r"(?:^|\s)(\d+)\s+page is facing (.), confidence ([\d.]+) - (.*)")
PRE_LINE = re.compile(
    r"page (\d+): (turned (\d+) deg clockwise|left upright|too little text[^(]*)"
    r"\s*\(?([^)]*)\)?"
)
JUNK = re.compile(
    r"\[WinError 2\]|--- Logging error ---|^Traceback|^\s+File \"|"
    r"^\s+\w.*\^+$|UnicodeEncodeError|^Message: |^Arguments: |^Call stack:|"
    r"^\s+(self|result|work_item|ocr_image_out|orientation_correction|log)\b"
)
CHATTER = re.compile(
    r"^\s*(\d+\s+)?(Running: \[|pikepdf mmap|os\.symlink|xref \d|Recursing into|"
    r"stdout/stderr = |Evaluating lazy import|Gathering info|Using Tesseract OpenMP|"
    r"\[tesseract\] OMP:|resolution \(|XrefExt\(|Adjusting rendered|"
    r".*optimize\.pdf ->|[a-z]{3}(_[a-z]+)*$)"
)
EVENT_STREAM: TextIO = sys.stdout


def emit(event: str, **fields) -> None:
    print(
        json.dumps({"event": event, **fields}, ensure_ascii=False),
        file=EVENT_STREAM,
        flush=True,
    )


def page_count(path: Path) -> int:
    try:
        import pypdfium2 as pdfium

        document = pdfium.PdfDocument(path)
        try:
            return max(1, len(document))
        finally:
            document.close()
    except Exception:
        return 1


def ocr_cmd(src: Path, dst: Path, options: dict) -> list[str]:
    language = LANGS.get(options.get("lang", "eng"), "eng")
    entry_point = Path(__file__).with_name("socketless_ocr.py")
    command = [
        sys.executable,
        "-X",
        "utf8",
        "-s",
        str(entry_point),
        "-l",
        language,
        "--jobs",
        str(os.cpu_count() or 2),
        "--output-type",
        "pdf",
        "--optimize",
        "0",
        "--use-threads",
    ]
    command += ["--redo-ocr"] if options.get("redo") else ["--skip-text"]
    return command + ["-v", "1", str(src), str(dst)]


def child_env() -> dict[str, str]:
    environment = dict(os.environ)
    environment["PYTHONIOENCODING"] = "utf-8"
    environment["PYTHONUTF8"] = "1"
    return environment


def classify(line: str) -> tuple[str, str, str] | None:
    facing = FACING.search(line)
    if facing:
        page, _arrow, confidence, action = facing.groups()
        if "will rotate" in action:
            return page, "turn", f"turned upright - confidence {float(confidence):.2f}"
        return page, "dim", f"already upright - confidence {float(confidence):.2f}"
    if "Too few characters" in line:
        return "", "plain", "too little text to determine orientation - left unchanged"
    if re.search(r"\b(ERROR|CRITICAL|Error during processing)\b", line):
        return "", "bad", line.strip()
    return None


def next_target(folder: Path, source: Path) -> Path:
    candidate = folder / f"{source.stem}_ocr.pdf"
    number = 2
    while candidate.exists():
        candidate = folder / f"{source.stem}_ocr_{number}.pdf"
        number += 1
    return candidate


def publish(completed: Path, target: Path) -> None:
    staging = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    try:
        shutil.copy2(completed, staging)
        os.replace(staging, target)
    finally:
        staging.unlink(missing_ok=True)


def write_report(report, text: str) -> None:
    report.write(text.rstrip() + "\n")
    report.flush()


def run(config: dict) -> int:
    options = config.get("options", {})
    output_dir = Path(config["output_dir"])
    job_dir = Path(config["job_dir"])
    report_path = Path(config["report_path"])
    sources = [Path(value) for value in config.get("inputs", [])]

    if not output_dir.is_dir():
        emit("fatal", text=f"Output folder does not exist: {output_dir}")
        return 2
    if not sources:
        emit("fatal", text="No PDF files were supplied.")
        return 2

    job_dir.mkdir(parents=True, exist_ok=True)
    valid: list[tuple[int, Path, int]] = []
    for index, source in enumerate(sources):
        if not source.is_file() or source.suffix.lower() != ".pdf":
            emit("file", index=index, state="failed", pages=0)
            emit("log", kind="bad", text=f"Skipped missing or non-PDF file: {source}")
            continue
        pages = page_count(source)
        valid.append((index, source, pages))
        emit("file", index=index, state="queued", pages=pages)

    per_page = 2 if options.get("rotate", True) else 1
    total_units = max(1, sum(pages * per_page for _, _, pages in valid))
    done_units = 0
    succeeded = failed = 0

    with report_path.open("w", encoding="utf-8", errors="replace") as report:
        write_report(report, "Document OCR native worker report")
        write_report(report, f"Python: {sys.executable}")
        write_report(report, f"Output: {output_dir}")
        write_report(report, f"Options: {options}")

        for index, source, pages in valid:
            emit("file", index=index, state="running", pages=pages, page=0)
            emit("log", kind="head", text=f"{source.name} - {pages} page(s)")
            write_report(report, f"\n===== {source} =====")
            working_source = source

            if options.get("rotate", True):
                emit("stage", text=f"{source.name} - checking page orientation")
                upright = job_dir / f"{index}_upright.pdf"
                rotation_seen = 0

                def rotation_report(message: str) -> None:
                    nonlocal done_units, rotation_seen
                    rotation_seen += 1
                    done_units += 1
                    match = PRE_LINE.search(message)
                    if match:
                        page, what, degrees, reason = match.groups()
                        if degrees:
                            text = f"Page {page}: turned {degrees} degrees clockwise - {reason}"
                            kind = "turn"
                        elif what.startswith("left upright"):
                            text = f"Page {page}: already upright - {reason}"
                            kind = "dim"
                        else:
                            text = f"Page {page}: too little text to determine orientation"
                            kind = "plain"
                        emit("file", index=index, state="running", pages=pages, page=int(page))
                        emit("log", kind=kind, text=text)
                    else:
                        emit("log", kind="dim", text=message.strip())
                    emit("progress", value=min(99, int(done_units * 100 / total_units)))
                    write_report(report, message)

                try:
                    from prerotate import prerotate

                    prerotate(
                        source,
                        upright,
                        options.get("lang", "eng").split("+")[0],
                        report=rotation_report,
                    )
                    working_source = upright
                except Exception as exc:
                    done_units += max(0, pages - rotation_seen)
                    emit(
                        "log",
                        kind="bad",
                        text=f"Could not correct orientation ({exc!r}); continuing unchanged.",
                    )
                    write_report(report, traceback.format_exc())

            emit("stage", text=f"{source.name} - reading text")
            temporary_output = job_dir / f"{index}_ocr.pdf"
            base_units = done_units
            seen = 0
            recent_output: deque[str] = deque(maxlen=80)
            try:
                process = subprocess.Popen(
                    ocr_cmd(working_source, temporary_output, options),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                    errors="replace",
                    env=child_env(),
                    creationflags=CREATE_NO_WINDOW,
                    start_new_session=os.name != "nt",
                )
                assert process.stdout is not None
                for raw_line in process.stdout:
                    line = ANSI.sub("", raw_line.rstrip())
                    recent_output.append(line)
                    write_report(report, line)
                    page_match = PAGE_NO.match(line)
                    if page_match:
                        seen = max(seen, min(int(page_match.group(1)), pages))
                        done_units = base_units + seen
                        emit("file", index=index, state="running", pages=pages, page=seen)
                        emit("progress", value=min(99, int(done_units * 100 / total_units)))
                        emit(
                            "stage",
                            text=(
                                f"{source.name} - finishing the last pages"
                                if seen >= pages
                                else f"{source.name} - reading page {seen} of {pages}"
                            ),
                        )
                    if options.get("verbose"):
                        if line and not CHATTER.match(line):
                            emit("log", kind="tech", text=re.sub(r"^\s*\d+\s+", "", line))
                    elif not JUNK.search(line):
                        classified = classify(line)
                        if classified:
                            emit("log", kind=classified[1], text=classified[2])
                code = process.wait()
            except Exception:
                code = -1
                write_report(report, traceback.format_exc())

            done_units = base_units + pages
            emit("progress", value=min(99, int(done_units * 100 / total_units)))
            if code == 0 and temporary_output.exists():
                try:
                    target = next_target(output_dir, source)
                    publish(temporary_output, target)
                    succeeded += 1
                    emit("file", index=index, state="done", pages=pages, page=pages)
                    emit("result", index=index, path=str(target))
                    emit("log", kind="ok", text=f"Saved: {target}")
                except Exception as exc:
                    failed += 1
                    emit("file", index=index, state="failed", pages=pages, page=seen)
                    emit("log", kind="bad", text=f"Could not save output: {exc}")
                    write_report(report, traceback.format_exc())
            else:
                failed += 1
                emit("file", index=index, state="failed", pages=pages, page=seen)
                emit("log", kind="bad", text=f"OCR failed with exit code {code}.")
                if recent_output:
                    emit("log", kind="tech", text="Last OCR messages are in OCR native run report.txt.")

        skipped = len(sources) - len(valid)
        failed += skipped
        emit("progress", value=100)
        emit("stage", text="")
        emit("summary", succeeded=succeeded, failed=failed)
        write_report(report, f"\nFinished: {succeeded} succeeded, {failed} failed")

    shutil.rmtree(job_dir, ignore_errors=True)
    return 0 if failed == 0 else 1


def selftest() -> None:
    command = ocr_cmd(Path("a.pdf"), Path("b.pdf"), {"lang": "eng+ara"})
    assert command[command.index("-l") + 1] == "eng+ara"
    assert "--skip-text" in command and "--rotate-pages" not in command
    assert "socketless_ocr.py" in command[4]
    assert "--use-threads" in command
    assert "--optimize" in command and command[command.index("--optimize") + 1] == "0"
    assert "--redo-ocr" in ocr_cmd(Path("a"), Path("b"), {"redo": True})
    assert classify("  4 page is facing x, confidence 1.25 - will rotate")[0] == "4"
    with tempfile.TemporaryDirectory() as directory:
        folder = Path(directory)
        source = folder / "sample.pdf"
        assert next_target(folder, source).name == "sample_ocr.pdf"
        (folder / "sample_ocr.pdf").touch()
        assert next_target(folder, source).name == "sample_ocr_2.pdf"
        completed = folder / "complete.tmp"
        completed.write_bytes(b"complete pdf")
        target = folder / "published.pdf"
        publish(completed, target)
        assert target.read_bytes() == b"complete pdf"
        assert not any(path.name.startswith(".published.pdf.") for path in folder.iterdir())
    assert "socket" not in sys.modules
    print("native worker selftest ok - no socket import")


def main() -> int:
    global EVENT_STREAM
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path)
    parser.add_argument("--events", type=Path)
    parser.add_argument("--selftest", action="store_true")
    arguments = parser.parse_args()
    if arguments.selftest:
        selftest()
        return 0
    if not arguments.config:
        parser.error("--config is required")
    with arguments.config.open(encoding="utf-8-sig") as stream:
        config = json.load(stream)

    event_context = (
        arguments.events.open("w", encoding="utf-8", buffering=1)
        if arguments.events
        else None
    )
    if event_context:
        EVENT_STREAM = event_context
    try:
        try:
            return run(config)
        except Exception as exc:
            emit("fatal", text=f"Unexpected worker error: {exc!r}")
            emit("log", kind="tech", text=traceback.format_exc())
            return 2
    finally:
        if event_context:
            event_context.close()


if __name__ == "__main__":
    raise SystemExit(main())
