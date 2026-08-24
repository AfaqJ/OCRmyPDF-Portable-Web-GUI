"""OCRmyPDF front-end that runs in the browser instead of a desktop toolkit.

Python's own http.server serves one page on 127.0.0.1, so this needs no GUI
library, no extra DLLs and nothing installed.
"""
import json, os, re, secrets, shutil, subprocess, sys, tempfile, threading, time, uuid, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs, quote

import pypdfium2 as pdfium

from prerotate import prerotate

TOKEN = secrets.token_urlsafe(16)          # keeps other local processes out
WORK = Path(tempfile.mkdtemp(prefix="ocrmypdf_web_"))
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0
LANGS = {"eng": "eng", "eng+ara": "eng+ara", "ara": "ara"}

UPLOADS: list[Path] = []
RESULTS: dict[str, Path] = {}
LOG: list[dict] = []                        # {"g": gutter, "k": kind, "t": text}
FILES: list[dict] = []                      # one row per document, for the queue
STATE = {"running": False, "done": False, "cancel": False, "proc": None,
         "units_done": 0, "units_total": 0, "stage": "", "started": 0.0}

ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
# never shown: probes for optional tools we do not ship, and Python's own
# complaint about printing an arrow to a legacy console
JUNK = re.compile(r"\[WinError 2\]|--- Logging error ---|^Traceback|^\s+File \"|^\s+\w.*\^+$|"
                  r"UnicodeEncodeError|^Message: |^Arguments: |^Call stack:|"
                  r"^\s+(self|result|work_item|ocr_image_out|orientation_correction|log)\b")
# internal plumbing: hidden unless the detailed log is asked for
CHATTER = re.compile(r"^\s*(\d+\s+)?(Running: \[|pikepdf mmap|os\.symlink|xref \d|Recursing into|"
                     r"stdout/stderr = |Evaluating lazy import|Gathering info|Using Tesseract OpenMP|"
                     r"\[tesseract\] OMP:|resolution \(|XrefExt\(|Adjusting rendered|"
                     r".*optimize\.pdf ->|[a-z]{3}(_[a-z]+)*$)")
PAGE_NO = re.compile(r"^\s*(\d+)\s+\S")     # ocrmypdf -v 1 prefixes lines with the page
FACING = re.compile(r"(?:^|\s)(\d+)\s+page is facing (.), confidence ([\d.]+) - (.*)")
PRE_LINE = re.compile(r"page (\d+): (turned (\d+) deg clockwise|left upright|too little text[^(]*)"
                      r"\s*\(?([^)]*)\)?")


def log(text: str, kind: str = "dim", gutter: str = "") -> None:
    LOG.append({"g": str(gutter), "k": kind, "t": ANSI.sub("", text.rstrip())})


def page_count(pdf: Path) -> int:
    try:
        return len(pdfium.PdfDocument(pdf))
    except Exception:
        return 1


def ocr_cmd(src: Path, dst: Path, o: dict) -> list:
    cmd = [sys.executable, "-m", "ocrmypdf",
           "-l", LANGS.get(o.get("lang", "eng"), "eng"),
           "--jobs", str(os.cpu_count() or 2), "--output-type", "pdf",
           # the optimizer only calls jbig2/pngquant, which this bundle does not
           # ship; with them absent it saves 0 bytes and just prints WinError 2
           "--optimize", "0"]
    cmd += ["--redo-ocr"] if o.get("redo") else ["--skip-text"]
    # NB: no --rotate-pages. Rotating inside OCRmyPDF puts the text layer in the
    # wrong place when the page already carries a /Rotate flag, which most
    # scanners set. prerotate.py turns the page upright first instead.
    return cmd + ["-v", "1", str(src), str(dst)]


def kill_tree(proc: subprocess.Popen) -> None:
    """Stop OCRmyPDF and everything it started.

    terminate() only signals the parent; OCRmyPDF runs tesseract and ghostscript
    as children of its own worker processes, and those keep writing to the pipe,
    so the run appeared to carry on after Cancel.
    """
    if proc.poll() is not None:
        return
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                           capture_output=True, creationflags=CREATE_NO_WINDOW)
        else:
            os.killpg(os.getpgid(proc.pid), 9)
    except Exception:
        proc.kill()


def child_env() -> dict:
    """UTF-8 for the child, or it dies printing a rotation arrow to a cp1252 console."""
    env = dict(os.environ)
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    return env


def classify(line: str) -> tuple[str, str, str] | None:
    """One ocrmypdf line -> (gutter, kind, text), or None to drop it."""
    m = FACING.search(line)
    if m:
        page, arrow, conf, action = m.groups()
        if "will rotate" in action:
            return page, "turn", f"turned upright  ·  confidence {float(conf):.2f}"
        return page, "dim", f"already upright  ·  confidence {float(conf):.2f}"
    if "Too few characters" in line:
        return "", "plain", "too little text to tell which way up it is - left alone"
    if re.search(r"\b(ERROR|CRITICAL|Error during processing)\b", line):
        return "", "bad", line.strip()
    return None


def note_prerotate(msg: str, row: dict) -> None:
    """Turn one prerotate report line into a coloured record row."""
    STATE["units_done"] += 1
    m = PRE_LINE.search(msg)
    if not m:
        return log(msg.strip())
    page, what, deg, why = m.group(1), m.group(2), m.group(3), m.group(4)
    row["page"] = int(page)
    if deg:
        log(f"turned {deg}° clockwise  ·  {why}", "turn", page)
    elif what.startswith("left upright"):
        log(f"already upright  ·  {why}", "dim", page)
    else:
        log("too little text to tell which way up it is - left alone", "plain", page)


def run_batch(opts: dict) -> None:
    """Worker thread: OCR every uploaded document, streaming into LOG."""
    STATE.update(running=True, done=False, cancel=False, units_done=0, started=time.time())
    ok = fail = 0
    try:
        per_page = 2 if opts.get("rotate") else 1
        FILES.clear()
        for src in UPLOADS:
            FILES.append({"name": src.name, "pages": page_count(src), "page": 0, "state": "queued"})
        STATE["units_total"] = max(1, sum(f["pages"] * per_page for f in FILES))
        for i, src in enumerate(list(UPLOADS)):
            if i >= len(FILES):
                break                      # the list changed underneath us
            row = FILES[i]
            if STATE["cancel"]:
                row["state"] = "cancelled"
                continue
            pages = row["pages"]
            row["state"] = "running"
            dst = src.parent / f"{src.stem}_ocr.pdf"
            log(f"{src.name}  ·  {pages} page{'s' if pages != 1 else ''}", "head")
            ocr_src = src
            if opts.get("rotate"):
                STATE["stage"] = f"{src.name} — checking page orientation"
                try:
                    upright = src.parent / f"{src.stem}_upright.pdf"
                    prerotate(src, upright, opts.get("lang", "eng").split("+")[0],
                              report=lambda m: note_prerotate(m, row),
                              should_stop=lambda: STATE["cancel"])
                    ocr_src = upright
                except Exception as exc:
                    log(f"could not pre-rotate ({exc!r}); reading pages as they are", "bad")
                    STATE["units_done"] += pages
            if STATE["cancel"]:
                row["state"] = "cancelled"
                break

            STATE["stage"] = f"{src.name} — reading the text"
            base, seen = STATE["units_done"], 0
            p = subprocess.Popen(ocr_cmd(ocr_src, dst, opts), stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, bufsize=1,
                                 errors="replace", env=child_env(),
                                 creationflags=CREATE_NO_WINDOW,
                                 start_new_session=os.name != "nt")
            STATE["proc"] = p
            for line in p.stdout:
                if STATE["cancel"]:
                    break
                if JUNK.search(line):
                    continue
                m = PAGE_NO.match(line)
                if m:
                    seen = max(seen, min(int(m.group(1)), pages))
                    row["page"] = seen
                    STATE["units_done"] = base + seen
                    STATE["stage"] = (f"{src.name} — finishing the last pages" if seen >= pages
                                      else f"{src.name} — reading page {seen} of {pages}")
                if opts.get("verbose"):
                    if not CHATTER.match(line):
                        g = m.group(1) if m else ""
                        log(re.sub(r"^\s*\d+\s+", "", line).strip(), "tech", g)
                else:
                    row_out = classify(line)
                    if row_out:
                        log(row_out[2], row_out[1], row_out[0])
            if STATE["cancel"]:
                kill_tree(p)
            try:
                code = p.wait(timeout=20)
            except subprocess.TimeoutExpired:
                kill_tree(p)
                code = -1
            STATE["proc"] = None
            STATE["units_done"] = base + pages
            if STATE["cancel"]:
                row["state"] = "cancelled"
                log("run cancelled - your files and settings are unchanged", "plain")
                break
            if code == 0 and dst.exists():
                ok += 1
                row.update(state="done", page=pages)
                RESULTS[uuid.uuid4().hex] = dst
                log(f"{dst.name}  ·  {dst.stat().st_size // 1024} KB", "ok")
            else:
                fail += 1
                row["state"] = "failed"
                log(f"failed, exit code {code}", "bad")
        for row in FILES:
            if row["state"] == "queued":
                row["state"] = "cancelled" if STATE["cancel"] else row["state"]
        if STATE["cancel"]:
            log("Cancelled.", "head")
        elif fail:
            log(f"Finished  ·  {ok} succeeded, {fail} failed", "bad")
        else:
            log(f"Finished  ·  {ok} succeeded", "done")
    except Exception as exc:                       # never leave the UI hanging
        log(f"unexpected error: {exc!r}", "bad")
    finally:
        STATE.update(running=False, done=True, stage="", proc=None)


PAGE = r"""<!doctype html><html lang=en dir=ltr><meta charset=utf-8>
<title>Document OCR</title>
<style>
:root{
  --paper:#EFF2F5; --surface:#FFFFFF; --sunk:#E4E9EE;
  --ink:#15202B; --muted:#5B6B7B; --faint:#8695A4;
  --line:#D5DCE4; --line-strong:#B6C1CC;
  --accent:#14557A; --accent-ink:#FFFFFF; --accent-soft:#DDE9F1;
  --ok:#1B6B47; --warn:#8A5A00; --warn-soft:#FBF0DC; --bad:#A32B21;
  --term-bg:#111A22; --term-ink:#EAF1F7; --term-dim:#8698A8; --term-head:#A9BDCC;
  /* two colours only, each with one meaning: a page was turned, something
     failed. Everything else is plain white, or grey when it is plumbing. */
  --term-cyan:#5FB3D4; --term-red:#D4776C; --term-green:#7FB77E;
  --mono:ui-monospace,"Cascadia Mono",Consolas,"SF Mono",monospace;
  --sans:"Segoe UI",system-ui,-apple-system,sans-serif;
}
/* Deliberately light-only: this runs on office PCs whose theme setting varies,
   and the record panel is the one dark surface by design. Every colour below is
   painted explicitly so the page never borrows the browser's dark ground. */
*{box-sizing:border-box;margin:0;padding:0}
/* a class that sets display beats the browser's own [hidden] rule, which is how
   the English+Arabic warning stayed on screen under every language */
[hidden]{display:none !important}
body{background:var(--paper);color:var(--ink);
     font:clamp(15px,0.34vw + 13.2px,18px)/1.6 var(--sans)}
.shell{max-width:clamp(1240px,94vw,1720px);margin:0 auto;padding:22px 18px 60px}
.mock{background:var(--surface);border:1px solid var(--line)}
.appbar{display:flex;align-items:center;justify-content:space-between;gap:16px;
        padding:14px 18px;border-bottom:1px solid var(--line);flex-wrap:wrap}
.brand{display:flex;align-items:baseline;gap:10px}
.brand .name{font:600 1.15em/1 var(--sans);letter-spacing:-.01em}
.brand .tag{font:500 .72em/1 var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--faint)}
.barright{display:flex;gap:10px;align-items:center}
.langsw{display:flex;border:1px solid var(--line-strong)}
.langsw button{font:600 .8em/1 var(--mono);padding:8px 13px;color:var(--muted);
               background:var(--surface);border:0;cursor:pointer}
.langsw button.on{background:var(--accent);color:var(--accent-ink)}
.eyebrow{font:700 .88em/1 var(--mono);letter-spacing:.16em;text-transform:uppercase;color:var(--muted)}
.panel{padding:18px}
.panel+.panel{border-top:1px solid var(--line)}
.plabel{display:flex;align-items:center;gap:10px;margin-bottom:12px}
.plabel i{flex:1;height:1px;background:var(--line);font-style:normal}
.chip{font:600 .78em/1 var(--mono);letter-spacing:.08em;text-transform:uppercase;
      padding:5px 8px;background:var(--sunk);color:var(--muted);white-space:nowrap}
.chip.ok{background:color-mix(in srgb,var(--ok) 15%,transparent);color:var(--ok)}
.chip.run{background:var(--accent-soft);color:var(--accent)}
.chip.wait{background:var(--sunk);color:var(--faint)}
.chip.live{background:color-mix(in srgb,var(--ok) 16%,transparent);color:var(--ok)}
.chip.bad{background:color-mix(in srgb,var(--bad) 14%,transparent);color:var(--bad)}
#drop{border:1.5px dashed var(--line-strong);background:var(--sunk);padding:26px;
      text-align:center;color:var(--muted);font-size:.92em;cursor:pointer}
#drop.hot{border-color:var(--accent);background:var(--accent-soft);color:var(--accent)}
#drop b{display:block;color:var(--ink);font-weight:600;font-size:1.08em;margin-bottom:4px}
#drop.hot b{color:var(--accent)}
#queue{list-style:none;margin-top:12px;border:1px solid var(--line)}
#queue:empty{display:none}
#queue li{display:grid;grid-template-columns:1fr auto auto auto;gap:12px;align-items:center;
          padding:9px 11px;font-size:.92em;border-bottom:1px solid var(--line)}
#queue li:last-child{border-bottom:0}
#queue .nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#queue .rm{border:0;background:transparent;color:var(--faint);cursor:pointer;
  font:400 1.15em/1 var(--sans);padding:2px 5px;width:1.9em}
#queue .rm:hover{color:var(--bad)}
#queue .rm:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
#queue .rm[hidden]{visibility:hidden;display:block !important}
#queue .sz{font:500 .82em/1 var(--mono);color:var(--faint);font-variant-numeric:tabular-nums}
label.opt{display:flex;align-items:center;gap:9px;font-size:.96em;padding:6px 0;cursor:pointer}
input[type=checkbox]{width:15px;height:15px;accent-color:var(--accent)}
select,input[type=text]{font:inherit;font-size:.94em;padding:8px 11px;
  border:1px solid var(--line-strong);background:var(--surface);color:var(--ink)}
.field{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:10px}
.warnbox{display:flex;gap:11px;background:var(--warn-soft);border-left:3px solid var(--warn);
         padding:11px 13px;font-size:.9em;margin:2px 0 13px}
.warnbox .k{font:700 .82em/1.5 var(--mono);letter-spacing:.09em;text-transform:uppercase;
            color:var(--warn);white-space:nowrap}
.hint{font-size:.86em;color:var(--faint);margin:-2px 0 9px 25px}
.btn{font:600 .92em/1 var(--sans);padding:12px 19px;border:1px solid var(--line-strong);
     background:var(--surface);color:var(--ink);cursor:pointer}
.btn.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
.btn.danger{border-color:var(--bad);color:var(--bad);background:transparent}
.btn:disabled{opacity:.45;cursor:default}
.btn:focus-visible,.langsw button:focus-visible,#drop:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.actions{display:flex;gap:9px;align-items:center;flex-wrap:wrap}
.meter{height:4px;background:var(--sunk);overflow:hidden;margin:14px 0 8px}
.meter i{display:block;height:100%;width:0;background:var(--accent);transition:width .3s}
.status{display:flex;justify-content:space-between;gap:12px;font:500 .84em/1.45 var(--mono);
        color:var(--muted);direction:ltr}
.status .eta{font-variant-numeric:tabular-nums;color:var(--faint);white-space:nowrap}
.term{background:var(--term-bg);color:var(--term-ink);font:.86em/1.7 var(--mono);
      display:flex;flex-direction:column;min-height:0;flex:1}
.term .head{display:flex;justify-content:space-between;gap:10px;padding:9px 13px;
  border-bottom:1px solid rgba(255,255,255,.12);color:var(--term-head);
  font-size:.92em;letter-spacing:.09em;text-transform:uppercase}
/* The scroller is taken out of flow so its content cannot set the column's
   height. Without this the log either stopped half way down (fixed height)
   or stretched the whole page (auto height). */
.term .scroll{position:relative;flex:1;min-height:0}
.term .body{position:absolute;inset:0;padding:10px 0;overflow-y:auto;overflow-x:hidden;
            direction:ltr;text-align:left}
.ln{display:grid;grid-template-columns:2.4em 1fr;gap:11px;padding:1px 13px}
.ln .g{color:var(--term-dim);text-align:right;font-variant-numeric:tabular-nums;user-select:none}
.k-plain,.k-dim,.k-ok{color:var(--term-ink)}    /* ordinary lines and finishes: plain white */
.k-ok{font-weight:600}
.k-done{color:var(--term-green);font-weight:700}  /* the run finished with nothing failed */
.k-tech{color:var(--term-dim)}                  /* technical detail stays quiet */
.k-turn{color:var(--term-cyan)}                 /* this page was turned */
.k-warn{color:var(--term-ink)}                  /* kept for old lines; reads as plain */
.k-bad{color:var(--term-red)}                   /* this failed */
.k-head{color:var(--term-ink);font-weight:700;letter-spacing:.02em}
.ln.k-head-row{margin-top:11px;padding-top:7px;padding-bottom:5px;
  background:rgba(255,255,255,.05);border-top:1px solid rgba(255,255,255,.10)}
.dlwrap{display:flex;flex-wrap:wrap;gap:7px;margin-top:10px}
a.dl{display:inline-block;padding:8px 13px;background:var(--accent-soft);
     border:1px solid var(--accent);text-decoration:none;color:var(--accent);font-size:.9em}
.ok-t{color:var(--ok);font-weight:600} .bad-t{color:var(--bad)}
.split{display:grid}
@media(min-width:900px){
  .split{grid-template-columns:minmax(0,1fr) minmax(0,1.05fr)}
  .split>.right{border-left:1px solid var(--line);border-top:0}
}
.split>.right{border-top:1px solid var(--line);display:flex;flex-direction:column;
              min-height:clamp(430px,62vh,820px)}
[dir=rtl] .warnbox{border-left:0;border-right:3px solid var(--warn)}
[dir=rtl] .hint{margin:-2px 24px 8px 0}
</style>
<div class=shell><div class=mock>
<div class=appbar>
  <div class=brand><span class=name data-t=title></span><span class=tag data-t=tag></span></div>
  <div class=barright>
    <span class=chip id=summary hidden></span>
    <div class=langsw><button id=btn-en class=on>EN</button><button id=btn-ar>عربي</button></div>
  </div>
</div>
<div class=split>
  <div class=left>
    <div class=panel>
      <div class=plabel><span class=eyebrow data-t=s_docs></span><i></i>
        <button class=btn id=clear style="padding:5px 10px;font-size:12px" data-t=clear></button></div>
      <div id=drop tabindex=0><b data-t=drop1></b><span data-t=drop2></span></div>
      <input type=file id=picker accept=application/pdf multiple hidden>
      <ul id=queue></ul>
    </div>
    <div class=panel>
      <div class=plabel><span class=eyebrow data-t=s_dest></span><i></i></div>
      <div class=actions><button class=btn id=pick data-t=choose></button>
        <span id=dest class=status style="display:block" data-t=nodir></span></div>
      <div id=pathbox hidden style=margin-top:10px>
        <input type=text id=path style=width:100%>
        <p class=hint style=margin-left:0 data-t=pathhint></p>
      </div>
    </div>
    <div class=panel>
      <div class=plabel><span class=eyebrow data-t=s_set></span><i></i></div>
      <div class=field><label for=lang style=font-size:14px data-t=doclang></label>
        <select id=lang>
          <option value=eng data-t=l_eng></option>
          <option value=eng+ara data-t=l_both></option>
          <option value=ara data-t=l_ara></option>
        </select></div>
      <div class=warnbox id=langwarn hidden>
        <span class=k data-t=w_key></span><span data-t=w_body></span></div>
      <label class=opt><input type=checkbox id=rotate checked><span data-t=o_rotate></span></label>
      <p class=hint data-t=h_rotate></p>
      <label class=opt><input type=checkbox id=redo><span data-t=o_redo></span></label>
      <p class=hint data-t=h_redo></p>
      <label class=opt><input type=checkbox id=verbose checked><span data-t=o_verbose></span></label>
      <p class=hint data-t=h_verbose></p>
    </div>
    <div class=panel>
      <div class=actions>
        <button class="btn primary" id=go disabled data-t=start></button>
        <button class="btn danger" id=cancel hidden data-t=cancel></button>
        <button class=btn id=save disabled data-t=save></button>
      </div>
      <div class=meter><i id=prog></i></div>
      <div class=status><span id=stage></span><span class=eta id=eta></span></div>
      <div class=dlwrap id=dl></div>
      <div id=savemsg class=status style=margin-top:8px></div>
    </div>
  </div>
  <div class=right>
    <div class=panel style="border-bottom:1px solid var(--line);padding-bottom:12px">
      <div class=plabel style=margin-bottom:0><span class=eyebrow data-t=s_rec></span><i></i>
        <span class="chip wait" id=reclive data-t=idlechip></span></div>
    </div>
    <div class=term>
      <div class=head><span id=termfile data-t=idle></span><span id=termcount></span></div>
      <div class=scroll><div class=body id=log></div></div>
    </div>
  </div>
</div></div></div>
<script>
const STR={
 en:{title:"Document OCR", tag:"Scanned PDF → searchable",
  s_docs:"Documents", clear:"Clear", drop1:"Drop PDFs here",
  drop2:"or click to browse — originals are never changed",
  s_dest:"Destination", choose:"Choose folder…", nodir:"No folder chosen",
  pathhint:"Paste a folder path from Explorer's address bar, then press Tab.",
  s_set:"Settings", doclang:"Document language",
  l_eng:"English", l_both:"English + Arabic", l_ara:"Arabic",
  w_key:"Slower", w_body:"Every page is read twice, once per script. Arabic on scans is read less accurately than English.",
  o_rotate:"Auto-rotate pages", h_rotate:"Turns sideways and upside-down scans upright before reading them",
  o_redo:"Redo OCR (replace existing text layer)",
  h_redo:"For files another tool already OCR'd badly. Off means pages that already hold real text are skipped untouched",
  o_verbose:"Show technical detail in the log",
  h_verbose:"Every internal step, not just what happened to each page",
  s_rec:"Log", live:"live", idle:"No run yet",
  start:"Start OCR", cancel:"Cancel run", save:"Save to folder",
  running:"Running…",
  remove:"Remove", q_done:"done", q_run:p=>`page ${p}`, q_wait:"queued", q_fail:"failed", q_cancel:"cancelled",
  sum:(d,t,p)=>`${d} of ${t} documents · ${p} pages`,
  saved:n=>`Saved ${n} file(s)`, saving:"Saving…", notfound:"Folder not found",
  nfiles:(f,p)=>`${f} document(s) · ${p} pages`},
 ar:{title:"التعرّف الضوئي على المستندات", tag:"ملف ممسوح ← قابل للبحث",
  s_docs:"المستندات", clear:"مسح", drop1:"أفلت ملفات PDF هنا",
  drop2:"أو انقر للاختيار — لا تُعدَّل الملفات الأصلية",
  s_dest:"مكان الحفظ", choose:"اختيار مجلد…", nodir:"لم يتم اختيار مجلد",
  pathhint:"الصق مسار المجلد من شريط العنوان في مستكشف الملفات، ثم اضغط Tab.",
  s_set:"الإعدادات", doclang:"لغة المستند",
  l_eng:"الإنجليزية", l_both:"الإنجليزية والعربية", l_ara:"العربية",
  w_key:"أبطأ", w_body:"تُقرأ كل صفحة مرتين، مرة لكل نظام كتابة. ودقة التعرّف على العربية في المستندات الممسوحة أقل من الإنجليزية.",
  o_rotate:"تدوير الصفحات تلقائيًا", h_rotate:"يعيد الصفحات الجانبية والمقلوبة إلى وضعها الصحيح قبل قراءتها",
  o_redo:"إعادة التعرّف الضوئي (استبدال طبقة النص الحالية)",
  h_redo:"للملفات التي عالجها برنامج آخر بشكل خاطئ. عند إيقافه تُترك الصفحات التي تحتوي نصًا حقيقيًا كما هي",
  o_verbose:"إظهار التفاصيل التقنية في السجل",
  h_verbose:"كل خطوة داخلية، وليس ما حدث لكل صفحة فقط",
  s_rec:"السجل", live:"مباشر", idle:"لا توجد عملية بعد",
  start:"بدء المعالجة", cancel:"إلغاء العملية", save:"حفظ في المجلد",
  running:"جارٍ التنفيذ…",
  remove:"إزالة", q_done:"تم", q_run:p=>`صفحة ${p}`, q_wait:"في الانتظار", q_fail:"فشل", q_cancel:"أُلغيت",
  sum:(d,t,p)=>`${d} من ${t} مستندات · ${p} صفحة`,
  saved:n=>`تم حفظ ${n} ملف`, saving:"جارٍ الحفظ…", notfound:"المجلد غير موجود",
  nfiles:(f,p)=>`${f} مستند · ${p} صفحة`}};

const T=new URLSearchParams(location.search).get('t');
const $=id=>document.getElementById(id);
const esc=v=>String(v).replace(/[&<>"']/g,c=>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let L='en', files=[], dirHandle=null, since=0, poll=null, results=[], running=false;

function apply(lang){
  L=lang; const s=STR[lang];
  document.documentElement.lang=lang;
  document.documentElement.dir=lang==='ar'?'rtl':'ltr';
  document.querySelectorAll('[data-t]').forEach(el=>{
    const v=s[el.dataset.t]; if(typeof v==='string') el.textContent=v;});
  $('btn-en').className=lang==='en'?'on':''; $('btn-ar').className=lang==='ar'?'on':'';
  if(!dirHandle && $('dest').dataset.set!=='1') $('dest').textContent=s.nodir;
  langWarn();
  setBusy(running);      /* re-labels Start/Cancel in the new language, keeps the lock */
  setLive(running);
}
$('btn-en').onclick=()=>apply('en'); $('btn-ar').onclick=()=>apply('ar');

/* the warning appears on its own when both scripts are chosen */
function langWarn(){ $('langwarn').hidden = $('lang').value!=='eng+ara'; }
$('lang').onchange=langWarn;

/* --- documents --- */
const drop=$('drop');
drop.onclick=()=>$('picker').click();
drop.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();$('picker').click()}};
$('picker').onchange=e=>add([...e.target.files]);
['dragenter','dragover'].forEach(t=>drop.addEventListener(t,e=>{e.preventDefault();drop.classList.add('hot')}));
['dragleave','drop'].forEach(t=>drop.addEventListener(t,e=>{e.preventDefault();drop.classList.remove('hot')}));
drop.addEventListener('drop',e=>add([...e.dataTransfer.files]));
function add(fs){
  if(running) return;                      /* the queue is live; do not edit it mid-run */
  fs=fs.filter(f=>f.name.toLowerCase().endsWith('.pdf'));
  const before=files.length;
  for(const f of fs) if(!files.some(x=>x.name===f.name&&x.size===f.size)) files.push(f);
  if(files.length!==before) pending();     /* last run's results no longer describe this list */
  paintQueue(); refresh();
}
/* Changing the list after a run invalidates what is on screen: the old rows still
   said "done", and a newly added file was not drawn at all because the queue
   preferred the server's finished list. Drop back to the pending view. */
function pending(){
  serverFiles=[]; results=[];
  $('dl').innerHTML=''; $('savemsg').textContent='';
  $('save').disabled=true; $('summary').hidden=true;
  $('prog').style.width='0'; $('stage').textContent=''; $('eta').textContent='';
  $('termfile').textContent=STR[L].idle; $('termcount').textContent='';
  setLive(false);
}
$('clear').onclick=async()=>{
  if(running) return;
  files=[]; $('log').innerHTML=''; $('picker').value=''; setLive(false);
  pending();
  await fetch(`/reset?t=${T}`,{method:'POST'}); paintQueue(); refresh();
};

let serverFiles=[];
function paintQueue(){
  const s=STR[L];
  const rows = serverFiles.length ? serverFiles : files.map(f=>({name:f.name,size:f.size}));
  $('queue').innerHTML = rows.map((r,i)=>{
    let cls='wait', txt=s.q_wait;
    if(r.state==='running'){cls='run'; txt=s.q_run(`${r.page}/${r.pages}`);}
    else if(r.state==='done'){cls='ok'; txt=s.q_done;}
    else if(r.state==='failed'){cls='bad'; txt=s.q_fail;}
    else if(r.state==='cancelled'){cls='wait'; txt=s.q_cancel;}
    else if(!r.state){cls='wait'; txt=(r.size/1048576).toFixed(1)+' MB';}
    const meta = r.pages ? `${r.pages} pp` : '';
    return `<li><span class=nm>${esc(r.name)}</span><span class=sz>${meta}</span>`+
           `<span class="chip ${cls}">${txt}</span>`+
           `<button class=rm data-i="${i}" title="${s.remove}" aria-label="${s.remove}: ${esc(r.name)}"`+
           `${running?' hidden':''}>&times;</button></li>`;
  }).join('');
  $('queue').querySelectorAll('.rm').forEach(b=>b.onclick=()=>removeAt(+b.dataset.i));
}
function removeAt(i){
  if(running) return;
  files.splice(i,1); pending(); paintQueue(); refresh();
}

/* --- destination --- */
$('pick').onclick=async()=>{
  if(window.showDirectoryPicker){
    try{dirHandle=await showDirectoryPicker({mode:'readwrite'});
      $('dest').innerHTML='<span class=ok-t>✓ '+dirHandle.name+'</span>';
      $('dest').dataset.set='1';}catch(e){}
  }else{$('pathbox').hidden=false;}
  refresh();
};
$('path').onchange=async()=>{
  const j=await (await fetch(`/checkdir?t=${T}&dir=${encodeURIComponent($('path').value)}`)).json();
  $('dest').innerHTML=j.ok?'<span class=ok-t>✓ '+j.dir+'</span>':'<span class=bad-t>'+STR[L].notfound+'</span>';
  $('dest').dataset.set=j.ok?'1':''; refresh();
};
function setLive(on){
  const c=$('reclive');
  c.className='chip '+(on?'live':'wait');
  c.textContent=on?STR[L].live:STR[L].idlechip;
}
const haveDest=()=>!!dirHandle||$('dest').dataset.set==='1';
function refresh(){$('go').disabled=running||!(files.length&&haveDest())}

/* One switch for the whole window, so nothing can be left enabled mid-run:
   every setting, both file controls and the per-file remove buttons. */
const LOCKS=['pick','clear','lang','rotate','redo','verbose','path'];
function setBusy(on){
  running=on;
  LOCKS.forEach(id=>{const e=$(id); if(e) e.disabled=on;});
  $('go').textContent=on?STR[L].running:STR[L].start;
  $('cancel').hidden=!on;
  $('cancel').disabled=false;
  drop.style.pointerEvents=on?'none':'';
  drop.style.opacity=on?'.5':'';
  drop.setAttribute('aria-disabled',String(on));
  drop.tabIndex=on?-1:0;
  if(on) $('save').disabled=true;
  paintQueue();                    /* redraws without the remove buttons */
  refresh();
}

/* --- run --- */
$('go').onclick=async()=>{
  setBusy(true);
  $('save').disabled=true; $('cancel').hidden=false;
  $('go').textContent=STR[L].running;
  $('dl').innerHTML=''; $('savemsg').textContent=''; $('log').innerHTML='';
  since=0; results=[]; $('prog').style.width='3%'; setLive(true);
  await fetch(`/reset?t=${T}`,{method:'POST'});
  for(const f of files)
    await fetch(`/upload?t=${T}&name=${encodeURIComponent(f.name)}`,{method:'POST',body:f});
  const q=i=>$(i).checked?1:0;
  await fetch(`/start?t=${T}&lang=${encodeURIComponent($('lang').value)}&rotate=${q('rotate')}`+
              `&redo=${q('redo')}&verbose=${q('verbose')}`,{method:'POST'});
  poll=setInterval(tick,400);
};
$('cancel').onclick=async()=>{
  $('cancel').disabled=true;
  await fetch(`/cancel?t=${T}`,{method:'POST'});
};

let pollFails=0;
async function tick(){
  let j;
  try{
    j=await (await fetch(`/log?t=${T}&since=${since}`)).json();
    pollFails=0;
  }catch(e){
    /* a dropped poll is survivable; a persistently dead server is not, and
       leaving the window locked with no explanation is the worst outcome */
    if(++pollFails<5) return;
    clearInterval(poll); setBusy(false); setLive(false);
    $('log').insertAdjacentHTML('beforeend',
      `<li class="ln k-bad" style=list-style:none><span class=g></span><span>`+
      `lost contact with the tool - close this tab and run START OCR.bat again</span></li>`);
    return;
  }
  since=j.next;
  if(j.lines.length){
    $('log').insertAdjacentHTML('beforeend', j.lines.map(l=>
      `<li class="ln k-${l.k}${l.k==='head'?' k-head-row':''}" style=list-style:none>`+
      `<span class=g>${l.g||''}</span><span>${l.t.replace(/</g,'&lt;')}</span></li>`).join(''));
    $('log').scrollTop=1e9;
  }
  serverFiles=j.files||[]; paintQueue();
  const active=serverFiles.filter(f=>f.state==='running');   /* not `running`: that is the busy flag */
  const done=serverFiles.filter(f=>f.state==='done').length;
  const pagesDone=serverFiles.reduce((n,f)=>n+(f.state==='done'?f.pages:f.page),0);
  if(serverFiles.length){
    $('summary').hidden=false;
    $('summary').textContent=STR[L].sum(done,serverFiles.length,pagesDone);
    $('summary').className='chip '+(j.done?'ok':'run');
  }
  if(active.length){
    $('termfile').textContent=active[0].name;
    $('termcount').textContent=`${active[0].page} / ${active[0].pages}`;
  }
  $('prog').style.width=Math.max(3,j.progress*100)+'%';
  $('stage').textContent=j.done?'':j.stage;
  const totalPages=serverFiles.reduce((n,f)=>n+f.pages,0);
  $('eta').textContent=totalPages?`${pagesDone} / ${totalPages} pages`:'';
  if(j.done){
    clearInterval(poll); results=j.results; setLive(false);
    $('dl').innerHTML=results.map(r=>
      `<a class=dl download="${esc(r.name)}" href="/result?t=${T}&id=${r.id}">↓ ${esc(r.name)}</a>`).join('');
    setBusy(false);
    $('save').disabled=!results.length;
  }
}

/* --- save --- */
$('save').onclick=async()=>{
  $('save').disabled=true; $('savemsg').textContent=STR[L].saving;
  try{
    if(dirHandle){
      for(const r of results){
        const blob=await (await fetch(`/result?t=${T}&id=${r.id}`)).blob();
        const w=await (await dirHandle.getFileHandle(r.name,{create:true})).createWritable();
        await w.write(blob); await w.close();
      }
      $('savemsg').innerHTML='<span class=ok-t>'+STR[L].saved(results.length)+'</span>';
    }else{
      const j=await (await fetch(`/save?t=${T}&dir=${encodeURIComponent($('path').value)}`,
                                 {method:'POST'})).json();
      $('savemsg').innerHTML=j.ok?'<span class=ok-t>'+STR[L].saved(j.count)+'</span>'
                                 :'<span class=bad-t>'+STR[L].notfound+'</span>';
    }
  }catch(e){$('savemsg').innerHTML='<span class=bad-t>'+e+'</span>'}
  $('save').disabled=false;
};
apply('en');
</script>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):                     # keep the console clean
        pass

    def _send(self, code, ctype, body: bytes, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj):
        self._send(200, "application/json", json.dumps(obj).encode())

    def _auth(self, q) -> bool:
        if secrets.compare_digest(q.get("t", [""])[0], TOKEN):
            return True
        self._send(403, "text/plain", b"forbidden")
        return False

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if not self._auth(q):
            return
        if u.path == "/":
            self._send(200, "text/html; charset=utf-8", PAGE.encode())
        elif u.path == "/log":
            done = STATE["done"] and not STATE["running"]
            frac = STATE["units_done"] / STATE["units_total"] if STATE["units_total"] else 0
            # cap at 95% while running: pages finish in parallel, and a bar that sits
            # at 100% for twenty seconds reads as a hang
            snapshot = list(RESULTS.items())   # the worker inserts while we serve
            self._json({"lines": LOG[int(q.get("since", ["0"])[0]):], "next": len(LOG),
                        "done": done, "progress": 1.0 if done else min(0.95, frac),
                        "stage": STATE["stage"], "files": FILES,
                        "results": [{"id": k, "name": v.name} for k, v in snapshot]})
        elif u.path == "/checkdir":
            d = Path(q.get("dir", [""])[0].strip().strip('"'))
            self._json({"ok": d.is_dir(), "dir": str(d)})
        elif u.path == "/result":
            path = RESULTS.get(q.get("id", [""])[0])
            if not path or not path.exists():
                return self._send(404, "text/plain", b"no such result")
            self._send(200, "application/pdf", path.read_bytes(),
                       {"Content-Disposition": f'attachment; filename="{quote(path.name)}"'})
        else:
            self._send(404, "text/plain", b"not found")

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if not self._auth(q):
            return
        if u.path == "/reset":
            if STATE["running"]:      # a second tab must not clear a live run
                return self._json({"ok": False, "error": "a run is in progress"})
            UPLOADS.clear(); RESULTS.clear(); LOG.clear(); FILES.clear()
            STATE.update(running=False, done=False, cancel=False,
                         units_done=0, units_total=0, stage="")
            self._json({"ok": True})
        elif u.path == "/upload":
            name = Path(q.get("name", ["input.pdf"])[0]).name or "input.pdf"
            job = WORK / uuid.uuid4().hex
            job.mkdir()
            dest = job / name
            dest.write_bytes(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            UPLOADS.append(dest)
            self._json({"ok": True})
        elif u.path == "/start":
            if STATE["running"]:
                return self._json({"ok": False, "error": "already running"})
            LOG.clear(); RESULTS.clear()
            opts = {k: q.get(k, ["0"])[0] == "1" for k in ("rotate", "redo", "verbose")}
            # "eng+ara" arrives as "eng ara" if the client forgets to encode the +
            opts["lang"] = q.get("lang", ["eng"])[0].strip().replace(" ", "+")
            threading.Thread(target=run_batch, args=(opts,), daemon=True).start()
            self._json({"ok": True})
        elif u.path == "/cancel":
            # stop the current page and skip the rest; uploads and settings stay put
            STATE["cancel"] = True
            proc = STATE.get("proc")
            if proc:
                kill_tree(proc)
            self._json({"ok": True})
        elif u.path == "/save":
            d = Path(q.get("dir", [""])[0].strip().strip('"'))
            if not d.is_dir():
                return self._json({"ok": False, "error": "Folder not found"})
            n = 0
            for path in list(RESULTS.values()):
                target = d / path.name
                if target.exists():
                    target = d / f"{path.stem}_{uuid.uuid4().hex[:4]}.pdf"
                shutil.copy2(path, target)
                n += 1
            self._json({"ok": True, "count": n, "dir": str(d)})
        else:
            self._send(404, "text/plain", b"not found")


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    url = f"http://127.0.0.1:{srv.server_address[1]}/?t={TOKEN}"
    print("Document OCR is running. Leave this window open while you work.\n")
    print("   ", url, "\n")
    print("If no browser opened, copy that address into Edge.")
    print("Closing this window shuts the tool down.")
    threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        shutil.rmtree(WORK, ignore_errors=True)


def selftest():
    """python web_gui.py --selftest -- checks the command builder and the page."""
    c = ocr_cmd(Path("a.pdf"), Path("b.pdf"), {"lang": "eng+ara"})
    assert c[c.index("-l") + 1] == "eng+ara"
    assert "--skip-text" in c and "--rotate-pages" not in c     # prerotate does it first
    assert c[c.index("--optimize") + 1] == "0"
    assert c[c.index("--output-type") + 1] == "pdf"
    assert "--redo-ocr" in ocr_cmd(Path("a"), Path("b"), {"redo": True})
    assert ocr_cmd(Path("a"), Path("b"), {"lang": "nonsense"})[3:5] == ["-l", "eng"]
    assert "encodeURIComponent($('lang').value)" in PAGE   # + means space in a query
    assert '.strip().replace(" ", "+")' in open(__file__, encoding="utf-8").read()
    assert "--deskew" not in " ".join(ocr_cmd(Path("a"), Path("b"), {"deskew": True}))

    assert JUNK.search("[WinError 2] The system cannot find the file specified")
    assert CHATTER.match("        1 Running: ['tesseract', '--version']")
    g, k, t = classify("        1 page is facing ⇨, confidence 1.52 - will rotate")
    assert (g, k) == ("1", "turn") and "turned upright" in t
    assert classify("   Postprocessing...") is None
    assert child_env()["PYTHONIOENCODING"] == "utf-8"

    row = {"page": 0}
    LOG.clear(); STATE["units_done"] = 0
    note_prerotate("   page 3: turned 270 deg clockwise  (confidence 8.17)", row)
    assert LOG[-1]["k"] == "turn" and LOG[-1]["g"] == "3" and row["page"] == 3
    note_prerotate("   page 4: too little text to tell which way up it is - left alone", row)
    assert LOG[-1]["k"] == "plain"       # an outcome, not a warning
    LOG.clear(); STATE["units_done"] = 0


    assert "Detailed record" not in PAGE and "h_verbose" in PAGE
    # adding a file after a run must reset the queue to the pending view
    assert "function pending()" in PAGE and "if(files.length!==before) pending();" in PAGE
    assert "if(running) return;" in PAGE
    assert "[hidden]{display:none !important}" in PAGE   # .warnbox sets display:flex
    assert "taskkill" in open(__file__, encoding="utf-8").read()   # cancel kills the tree
    assert "j.eta" not in PAGE and "mins left" not in PAGE   # no time estimate shown
    assert ".k-tech" in PAGE and ".k-plain" in PAGE
    # `running` is the busy flag; shadowing it inside tick() threw on assignment
    assert "const running=" not in PAGE and "function setBusy(on)" in PAGE
    assert "LOCKS=['pick','clear','lang','rotate','redo','verbose','path']" in PAGE
    assert "const esc=" in PAGE and "esc(r.name)" in PAGE      # names are escaped
    assert "pollFails" in PAGE                                # a dead poll unlocks
    assert "a run is in progress" in open(__file__, encoding="utf-8").read()
    assert "--term-amber" not in PAGE                  # green is only the final line
    assert ".k-done{color:var(--term-green)" in PAGE
    assert "height:clamp(300px" not in PAGE            # the log fills its column now
    assert ".term .scroll{position:relative" in PAGE   # content cannot stretch the column
    assert classify("   1 [tesseract] Too few characters. Skipping this page")[1] == "plain"
    for key in ("title", "o_redo", "w_body", "l_both", "q_run", "h_verbose", "remove"):
        assert f"{key}:" in PAGE, key
    assert "PDF/A" not in PAGE and "NAPS2" not in PAGE and "deskew" not in PAGE.lower()
    assert "العربية" in PAGE and "rtl" in PAGE
    assert "border-radius" not in PAGE               # square corners throughout
    assert "prefers-color-scheme" not in PAGE        # light only, by request
    assert "--paper:#EFF2F5" in PAGE and "background:var(--paper)" in PAGE
    print("selftest ok - console layout, no desktop toolkit needed")


if __name__ == "__main__":
    selftest() if "--selftest" in sys.argv else main()
