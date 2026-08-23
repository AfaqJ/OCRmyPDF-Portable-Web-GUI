"""OCRmyPDF front-end that runs in the browser instead of Tk.

Python's own http.server serves a single local page, so this needs no GUI
toolkit, no extra DLLs and nothing installed. Drop PDFs on the page, choose
where results go, press Start, watch the live log.
"""
import json, os, re, secrets, shutil, subprocess, sys, tempfile, threading, uuid, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs, quote

TOKEN = secrets.token_urlsafe(16)          # keeps other local processes out
WORK = Path(tempfile.mkdtemp(prefix="ocrmypdf_web_"))
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0
ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
# ocrmypdf -v 1 is chatty: drop plumbing so the log reads like a terminal
NOISE = re.compile(r"^\s*(\d+\s+)?(Running: \[|pikepdf mmap|os\.symlink|xref \d|Recursing into|stdout/stderr = |Evaluating lazy import|Gathering info|Using Tesseract OpenMP|\[tesseract\] OMP:|resolution \(|.*optimize\.pdf ->|[a-z]{3}(_[a-z]+)*$)")

UPLOADS: list[Path] = []
RESULTS: dict[str, Path] = {}
LOG: list[str] = []
STATE = {"running": False, "done": False}


def log(msg: str) -> None:
    LOG.append(ANSI.sub("", msg.rstrip()))


def ocr_cmd(src: Path, dst: Path, o: dict) -> list:
    cmd = [sys.executable, "-m", "ocrmypdf", "-l", "eng",
           "--jobs", str(os.cpu_count() or 2),
           "--output-type", "pdfa" if o.get("pdfa") else "pdf"]
    cmd += ["--redo-ocr"] if o.get("redo") else ["--skip-text"]
    if o.get("rotate"):
        cmd += ["--rotate-pages", "--rotate-pages-threshold", "0.1"]
    if o.get("deskew") and not o.get("redo"):     # ocrmypdf rejects this pair
        cmd.append("--deskew")
    if o.get("verbose"):
        cmd += ["-v", "1"]
    return cmd + [str(src), str(dst)]


def run_batch(opts: dict) -> None:
    """Worker thread: OCR every uploaded file, streaming output into LOG."""
    STATE.update(running=True, done=False)
    ok = fail = 0
    try:
        for i, src in enumerate(UPLOADS, 1):
            dst = src.parent / f"{src.stem}_ocr.pdf"
            log(f"\n[{i}/{len(UPLOADS)}] {src.name}")
            log("$ ocrmypdf " + " ".join(ocr_cmd(src, dst, opts)[3:-2]) + f" {src.name} {dst.name}")
            p = subprocess.Popen(ocr_cmd(src, dst, opts), stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, bufsize=1,
                                 errors="replace", creationflags=CREATE_NO_WINDOW)
            for line in p.stdout:
                if not NOISE.match(line):
                    log("   " + line)
            if p.wait() == 0 and dst.exists():
                ok += 1
                RESULTS[uuid.uuid4().hex] = dst
                log(f"   -> {dst.name}  ({dst.stat().st_size // 1024} KB)")
            else:
                fail += 1
                log(f"   FAILED (exit code {p.returncode})")
        log(f"\nFinished. {ok} succeeded, {fail} failed.")
        if ok:
            log("Now choose a folder and press Save, or use the download links.")
    except Exception as exc:                       # never leave the UI hanging
        log(f"\nUnexpected error: {exc!r}")
    finally:
        STATE.update(running=False, done=True)


PAGE = r"""<!doctype html><meta charset=utf-8><title>OCRmyPDF Portable</title>
<style>
*{box-sizing:border-box}
body{font:15px/1.55 "Segoe UI",system-ui,sans-serif;margin:0;background:#eef1f5;color:#1b1f24}
main{max-width:880px;margin:0 auto;padding:26px 20px 70px}
h1{font-size:22px;margin:0} .sub{color:#5b6470;margin:2px 0 22px}
.card{background:#fff;border:1px solid #dde2e8;border-radius:10px;padding:18px 20px;margin-bottom:14px;
      box-shadow:0 1px 2px rgba(16,24,40,.04)}
.card h2{font-size:12px;text-transform:uppercase;letter-spacing:.8px;color:#6b7480;margin:0 0 12px}
#drop{border:2px dashed #b6c2d2;border-radius:10px;padding:26px;text-align:center;color:#5b6470;
      cursor:pointer;transition:.15s;background:#fafbfd}
#drop.hot{border-color:#1268c3;background:#eaf2fd;color:#1268c3}
#list{margin:12px 0 0;padding:0;list-style:none;max-height:150px;overflow:auto}
#list li{display:flex;justify-content:space-between;gap:10px;padding:5px 8px;border-radius:5px;font-size:14px}
#list li:nth-child(odd){background:#f6f8fa}
#list b{font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#list span{color:#78828e;font-variant-numeric:tabular-nums;white-space:nowrap}
label.opt{display:block;margin:7px 0}
button{font:inherit;padding:9px 18px;border-radius:7px;border:1px solid #c3ccd7;background:#fff;cursor:pointer}
button:hover:not(:disabled){border-color:#8fa3ba}
button.primary{background:#1268c3;border-color:#0b5cad;color:#fff;padding:11px 30px;font-weight:600}
button:disabled{opacity:.5;cursor:default}
input[type=text]{font:inherit;padding:9px 11px;border:1px solid #c3ccd7;border-radius:7px;width:100%}
#log{background:#11161c;color:#d7dee6;font:12.5px/1.5 ui-monospace,Consolas,monospace;padding:14px;
     border-radius:8px;height:290px;overflow:auto;white-space:pre-wrap;word-break:break-word}
.bar{height:7px;background:#e2e6eb;border-radius:4px;overflow:hidden;margin:14px 0 0}
.bar>i{display:block;height:100%;width:0;background:#1268c3;transition:width .3s}
a.dl{display:inline-block;margin:5px 8px 0 0;padding:7px 13px;background:#eaf2fd;border:1px solid #b9d0ee;
     border-radius:7px;text-decoration:none;color:#0b4a8f;font-size:14px}
.row{display:flex;gap:10px;align-items:center}
.ok{color:#137333} .warn{color:#a33}
</style>
<main>
<h1>OCRmyPDF Portable</h1>
<p class=sub>Adds an invisible, searchable text layer to scanned PDFs. Everything stays on this PC.</p>

<div class=card><h2>1 &nbsp;Add PDFs</h2>
  <div id=drop>Drop PDF files here, or click to browse</div>
  <input type=file id=picker accept=application/pdf multiple hidden>
  <ul id=list></ul>
</div>

<div class=card><h2>2 &nbsp;Where to save the results</h2>
  <div class=row><button id=pick>Choose folder…</button><span id=dest>No folder chosen.</span></div>
  <div id=pathbox style="margin-top:10px;display:none">
    <input type=text id=path placeholder="e.g. C:\Users\you\Desktop\OCR output">
    <p class=sub style=margin:6px_0_0>Paste a folder path from Explorer's address bar, then press Tab.</p>
  </div>
</div>

<div class=card><h2>3 &nbsp;Options</h2>
  <label class=opt><input type=checkbox id=rotate checked> Auto-rotate sideways and upside-down pages</label>
  <label class=opt><input type=checkbox id=redo> Redo OCR &mdash; replace an existing bad text layer (e.g. from NAPS2)</label>
  <label class=opt><input type=checkbox id=deskew> Deskew crooked scans <span style=color:#8a929c>(ignored if Redo OCR is on)</span></label>
  <label class=opt><input type=checkbox id=pdfa> PDF/A output <span style=color:#8a929c>(archival; rewrites the whole file)</span></label>
  <label class=opt><input type=checkbox id=verbose checked> Detailed per-page log</label>
</div>

<div class=card><h2>4 &nbsp;Run</h2>
  <div class=row><button id=go class=primary disabled>Start OCR</button>
    <button id=save disabled>Save to folder</button><span id=savemsg></span></div>
  <div class=bar><i id=prog></i></div>
  <div id=dl></div>
  <div id=log style=margin-top:14px>Ready. Add some PDFs to begin.</div>
</div>
</main>
<script>
const T=new URLSearchParams(location.search).get('t');
const $=id=>document.getElementById(id);
let files=[],dirHandle=null,since=0,poll=null,results=[];

/* ---------- 1. file list ---------- */
const drop=$('drop');
drop.onclick=()=>$('picker').click();
$('picker').onchange=e=>add([...e.target.files]);
['dragenter','dragover'].forEach(t=>drop.addEventListener(t,e=>{e.preventDefault();drop.classList.add('hot')}));
['dragleave','drop'].forEach(t=>drop.addEventListener(t,e=>{e.preventDefault();drop.classList.remove('hot')}));
drop.addEventListener('drop',e=>add([...e.dataTransfer.files]));
function add(fs){
  fs=fs.filter(f=>f.name.toLowerCase().endsWith('.pdf'));
  for(const f of fs) if(!files.some(x=>x.name===f.name&&x.size===f.size)) files.push(f);
  $('list').innerHTML=files.map((f,i)=>
    `<li><b>${f.name}</b><span>${(f.size/1048576).toFixed(1)} MB</span></li>`).join('');
  refresh();
}

/* ---------- 2. destination ---------- */
$('pick').onclick=async()=>{
  if(window.showDirectoryPicker){
    try{dirHandle=await showDirectoryPicker({mode:'readwrite'});
        $('dest').innerHTML='<span class=ok>&#10003; '+dirHandle.name+'</span>';
    }catch(e){}
  }else{
    $('pathbox').style.display='block';
    $('dest').textContent='Type the folder path below.';
  }
  refresh();
};
$('path').onchange=async()=>{
  const r=await fetch(`/checkdir?t=${T}&dir=${encodeURIComponent($('path').value)}`);
  const j=await r.json();
  $('dest').innerHTML=j.ok?'<span class=ok>&#10003; '+j.dir+'</span>'
                          :'<span class=warn>Folder not found</span>';
  refresh();
};
const haveDest=()=>!!dirHandle||$('dest').textContent.trim().startsWith('\u2713');

function refresh(){$('go').disabled=!(files.length&&haveDest())}

/* ---------- 3. run ---------- */
$('go').onclick=async()=>{
  $('go').disabled=$('pick').disabled=true;$('save').disabled=true;
  $('dl').innerHTML='';$('log').textContent='';since=0;results=[];
  $('prog').style.width='4%';
  for(const f of files)
    await fetch(`/upload?t=${T}&name=${encodeURIComponent(f.name)}`,{method:'POST',body:f});
  const q=i=>$(i).checked?1:0;
  await fetch(`/start?t=${T}&rotate=${q('rotate')}&redo=${q('redo')}&deskew=${q('deskew')}`+
              `&pdfa=${q('pdfa')}&verbose=${q('verbose')}`,{method:'POST'});
  poll=setInterval(tick,400);
};
async function tick(){
  const j=await (await fetch(`/log?t=${T}&since=${since}`)).json();
  since=j.next;
  if(j.lines.length){$('log').textContent+=j.lines.join('\n')+'\n';$('log').scrollTop=1e9}
  $('prog').style.width=Math.max(4,j.progress*100)+'%';
  if(j.done){
    clearInterval(poll);results=j.results;
    $('dl').innerHTML=results.map(r=>
      `<a class=dl download="${r.name}" href="/result?t=${T}&id=${r.id}">&#11015; ${r.name}</a>`).join('');
    $('go').disabled=$('pick').disabled=false;
    $('save').disabled=!results.length;
  }
}

/* ---------- 4. save ---------- */
$('save').onclick=async()=>{
  $('save').disabled=true;$('savemsg').textContent='Saving…';
  try{
    if(dirHandle){
      for(const r of results){
        const blob=await (await fetch(`/result?t=${T}&id=${r.id}`)).blob();
        const fh=await dirHandle.getFileHandle(r.name,{create:true});
        const w=await fh.createWritable();await w.write(blob);await w.close();
      }
      $('savemsg').innerHTML='<span class=ok>Saved '+results.length+' file(s) to '+dirHandle.name+'</span>';
    }else{
      const j=await (await fetch(`/save?t=${T}&dir=${encodeURIComponent($('path').value)}`,
                                 {method:'POST'})).json();
      $('savemsg').innerHTML=j.ok?'<span class=ok>Saved '+j.count+' file(s) to '+j.dir+'</span>'
                                 :'<span class=warn>'+j.error+'</span>';
    }
  }catch(e){$('savemsg').innerHTML='<span class=warn>'+e+'</span>'}
  $('save').disabled=false;
};
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
            since = int(q.get("since", ["0"])[0])
            total = max(len(UPLOADS), 1)
            self._json({"lines": LOG[since:], "next": len(LOG),
                        "done": STATE["done"] and not STATE["running"],
                        "progress": min(1.0, len(RESULTS) / total),
                        "results": [{"id": k, "name": v.name} for k, v in RESULTS.items()]})
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
        if u.path == "/upload":
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
            LOG.clear()
            RESULTS.clear()
            opts = {k: q.get(k, ["0"])[0] == "1"
                    for k in ("rotate", "redo", "deskew", "pdfa", "verbose")}
            threading.Thread(target=run_batch, args=(opts,), daemon=True).start()
            self._json({"ok": True})
        elif u.path == "/save":
            d = Path(q.get("dir", [""])[0].strip().strip('"'))
            if not d.is_dir():
                return self._json({"ok": False, "error": "Folder not found"})
            n = 0
            for path in RESULTS.values():
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
    print("OCRmyPDF is running. Leave this window open while you work.\n")
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
    c = ocr_cmd(Path("a.pdf"), Path("b.pdf"), {"rotate": True, "deskew": True, "verbose": True})
    assert "--skip-text" in c and "--deskew" in c and c[-3:-2] == ["1"]
    assert c[c.index("--rotate-pages-threshold") + 1] == "0.1"
    r = ocr_cmd(Path("a.pdf"), Path("b.pdf"), {"redo": True, "deskew": True, "pdfa": True})
    assert "--redo-ocr" in r and "--deskew" not in r      # incompatible pair
    assert r[r.index("--output-type") + 1] == "pdfa"
    assert ANSI.sub("", "\x1b[32mgreen\x1b[0m") == "green"
    assert NOISE.match("   afr") and NOISE.match("   chi_sim_vert")
    assert NOISE.match("        1 Running: ['tesseract', '--version']")
    assert NOISE.match("        1 [tesseract] OMP: Warning #96: Cannot form a team")
    assert not NOISE.match("        1 page is facing, confidence 1.52 - will rotate")
    assert not NOISE.match("   Postprocessing...")
    assert not NOISE.match("    1 page is facing U+21E8, confidence 1.52 - will rotate")
    assert not NOISE.match("   Postprocessing...")
    for needed in ("showDirectoryPicker", "dataTransfer", "/checkdir", "/save", "id=log"):
        assert needed in PAGE, needed
    print("selftest ok - browser UI, no Tk needed")


if __name__ == "__main__":
    selftest() if "--selftest" in sys.argv else main()
