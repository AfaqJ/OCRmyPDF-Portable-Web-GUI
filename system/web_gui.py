"""OCRmyPDF front-end that runs in the browser instead of a desktop toolkit.

Python's own http.server serves one page on 127.0.0.1, so this needs no GUI
library, no extra DLLs and nothing installed. Drop PDFs on the page, choose
where results go, press Start, watch the log.
"""
import json, os, re, secrets, shutil, subprocess, sys, tempfile, threading, uuid, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs, quote

TOKEN = secrets.token_urlsafe(16)          # keeps other local processes out
WORK = Path(tempfile.mkdtemp(prefix="ocrmypdf_web_"))
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0
LANGS = {"eng": "eng", "eng+ara": "eng+ara", "ara": "ara"}

UPLOADS: list[Path] = []
RESULTS: dict[str, Path] = {}
LOG: list[str] = []
STATE = {"running": False, "done": False}

ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
# Things the user must never be shown: probes for optional tools we do not ship,
# and Python's own complaint about printing an arrow to a legacy console.
JUNK = re.compile(r"\[WinError 2\]|--- Logging error ---|^Traceback|^\s+File \"|^\s+\w.*\^+$|"
                  r"UnicodeEncodeError|^Message: |^Arguments: |^Call stack:|"
                  r"^\s+(self|result|work_item|ocr_image_out|orientation_correction|log)\b")
# Internal plumbing: hidden unless the detailed log is asked for.
CHATTER = re.compile(r"^\s*(\d+\s+)?(Running: \[|pikepdf mmap|os\.symlink|xref \d|Recursing into|"
                     r"stdout/stderr = |Evaluating lazy import|Gathering info|Using Tesseract OpenMP|"
                     r"\[tesseract\] OMP:|resolution \(|XrefExt\(|Adjusting rendered|"
                     r".*optimize\.pdf ->|[a-z]{3}(_[a-z]+)*$)")
FACING = re.compile(r"(?:^|\s)(\d+)\s+page is facing (.), confidence ([\d.]+) - (.*)")
ARROWS = {"⇧": "upright", "⇨": "on its side (facing right)",
          "⇩": "upside down", "⇦": "on its side (facing left)"}


def log(msg: str) -> None:
    LOG.append(ANSI.sub("", msg.rstrip()))


def friendly(line: str) -> str | None:
    """Turn one ocrmypdf line into something worth showing, or None to drop it."""
    m = FACING.search(line)
    if m:
        page, arrow, conf, action = m.groups()
        was = ARROWS.get(arrow, "unclear")
        turned = "turned upright" if "will rotate" in action else "left as it is"
        return f"   page {page}: {was} -> {turned}  (confidence {float(conf):.2f})"
    if "Too few characters" in line:
        return "   (page has too little text to judge its orientation - left as it is)"
    if re.search(r"\b(ERROR|CRITICAL|Error during processing)\b", line):
        return "   " + line.strip()
    return None


def ocr_cmd(src: Path, dst: Path, o: dict) -> list:
    cmd = [sys.executable, "-m", "ocrmypdf",
           "-l", LANGS.get(o.get("lang", "eng"), "eng"),
           "--jobs", str(os.cpu_count() or 2), "--output-type", "pdf",
           # the optimizer only ever calls jbig2/pngquant, which this bundle does
           # not ship; with them absent it saves 0 bytes and just prints WinError 2
           "--optimize", "0"]
    cmd += ["--redo-ocr"] if o.get("redo") else ["--skip-text"]
    if o.get("rotate"):
        cmd += ["--rotate-pages", "--rotate-pages-threshold", "0.1"]
    if o.get("deskew") and not o.get("redo"):     # ocrmypdf rejects this pair
        cmd.append("--deskew")
    return cmd + ["-v", "1", str(src), str(dst)]


def child_env() -> dict:
    """UTF-8 for the child, or it dies trying to print an arrow on a cp1252 console."""
    env = dict(os.environ)
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    return env


def run_batch(opts: dict) -> None:
    """Worker thread: OCR every uploaded file, streaming output into LOG."""
    STATE.update(running=True, done=False)
    ok = fail = 0
    try:
        for i, src in enumerate(UPLOADS, 1):
            dst = src.parent / f"{src.stem}_ocr.pdf"
            log(f"[{i}/{len(UPLOADS)}] {src.name}")
            p = subprocess.Popen(ocr_cmd(src, dst, opts), stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, bufsize=1,
                                 errors="replace", env=child_env(),
                                 creationflags=CREATE_NO_WINDOW)
            for line in p.stdout:
                if JUNK.search(line):
                    continue
                if opts.get("verbose"):
                    if not CHATTER.match(line):
                        log("   " + line)
                else:
                    nice = friendly(line)
                    if nice:
                        log(nice)
            if p.wait() == 0 and dst.exists():
                ok += 1
                RESULTS[uuid.uuid4().hex] = dst
                log(f"   done -> {dst.name}  ({dst.stat().st_size // 1024} KB)\n")
            else:
                fail += 1
                log(f"   FAILED (exit code {p.returncode})\n")
        log(f"Finished. {ok} succeeded, {fail} failed.")
        if ok:
            log("Press Save to folder, or use the download links.")
    except Exception as exc:                       # never leave the UI hanging
        log(f"Unexpected error: {exc!r}")
    finally:
        STATE.update(running=False, done=True)


PAGE = r"""<!doctype html><html lang=en dir=ltr><meta charset=utf-8>
<title>OCRmyPDF Portable</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#eceff3;--card:#fff;--line:#dde2e9;--ink:#1a1f27;--dim:#69727e;
      --accent:#1266c7;--accent-dark:#0d4f9e;--ok:#14733a;--bad:#b3261e}
body{font:15px/1.6 "Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--ink);
     padding:26px 18px 70px}
main{max-width:840px;margin:0 auto}
header{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;margin-bottom:22px}
h1{font-size:23px;font-weight:650;letter-spacing:-.2px}
.sub{color:var(--dim);font-size:14px;margin-top:3px}
#langtoggle{display:flex;border:1px solid var(--line);border-radius:8px;overflow:hidden;background:#fff;flex:none}
#langtoggle button{border:0;background:#fff;padding:7px 14px;font:inherit;font-size:13px;cursor:pointer;color:var(--dim)}
#langtoggle button.on{background:var(--accent);color:#fff}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:20px;margin-bottom:14px}
.card>h2{font-size:13px;font-weight:650;color:var(--dim);margin-bottom:14px;
         display:flex;align-items:center;gap:10px}
.num{width:22px;height:22px;border-radius:50%;background:var(--accent);color:#fff;flex:none;
     display:grid;place-items:center;font-size:12px;font-weight:700}
#drop{border:2px dashed #b8c4d4;border-radius:10px;padding:30px 16px;text-align:center;
      color:var(--dim);cursor:pointer;transition:.15s;background:#fafbfd;font-size:14px}
#drop.hot{border-color:var(--accent);background:#e9f1fc;color:var(--accent)}
#list{list-style:none;margin-top:12px;max-height:150px;overflow:auto}
#list li{display:flex;justify-content:space-between;gap:12px;padding:6px 9px;border-radius:6px;font-size:13.5px}
#list li:nth-child(odd){background:#f5f7fa}
#list span{color:var(--dim);font-variant-numeric:tabular-nums;white-space:nowrap}
.opt{display:flex;align-items:center;gap:9px;padding:7px 0;font-size:14.5px}
.opt input[type=checkbox]{width:16px;height:16px;accent-color:var(--accent);flex:none}
select{font:inherit;padding:8px 11px;border:1px solid var(--line);border-radius:8px;background:#fff;min-width:230px}
.i{width:19px;height:19px;border-radius:50%;border:1px solid #b8c4d4;background:#fff;color:var(--dim);
   font:600 12px/1 serif;cursor:pointer;flex:none;display:grid;place-items:center}
.i:hover{border-color:var(--accent);color:var(--accent)}
.info{display:none;font-size:13.2px;color:var(--dim);background:#f5f7fa;border-inline-start:3px solid #c9d4e2;
      padding:9px 12px;border-radius:0 7px 7px 0;margin:2px 0 8px}
.info.show{display:block}
button.act{font:inherit;padding:10px 20px;border-radius:8px;border:1px solid var(--line);
           background:#fff;cursor:pointer}
button.act:hover:not(:disabled){border-color:#93a5ba}
button.primary{background:var(--accent);border-color:var(--accent-dark);color:#fff;font-weight:600;padding:12px 32px}
button:disabled{opacity:.45;cursor:default}
.row{display:flex;gap:11px;align-items:center;flex-wrap:wrap}
.bar{height:6px;background:#e0e5ea;border-radius:3px;overflow:hidden;margin:15px 0 0}
.bar>i{display:block;height:100%;width:0;background:var(--accent);transition:width .3s}
#log{background:#12171e;color:#d5dce5;font:12.5px/1.6 ui-monospace,Consolas,monospace;padding:15px;
     border-radius:9px;height:280px;overflow:auto;white-space:pre-wrap;word-break:break-word;
     margin-top:14px;direction:ltr;text-align:left}
a.dl{display:inline-block;margin:7px 8px 0 0;padding:8px 14px;background:#e9f1fc;border:1px solid #bcd4ef;
     border-radius:8px;text-decoration:none;color:var(--accent-dark);font-size:14px}
.ok{color:var(--ok);font-weight:600} .bad{color:var(--bad)}
[dir=rtl] .info{border-radius:7px 0 0 7px}
[dir=rtl] #log{direction:ltr;text-align:left}
</style>
<main>
<header>
  <div><h1 data-t=title></h1><p class=sub data-t=sub></p></div>
  <div id=langtoggle><button id=btn-en class=on>English</button><button id=btn-ar>عربي</button></div>
</header>

<div class=card><h2><span class=num>1</span><span data-t=s1></span></h2>
  <div id=drop data-t=drop></div>
  <input type=file id=picker accept=application/pdf multiple hidden>
  <ul id=list></ul>
</div>

<div class=card><h2><span class=num>2</span><span data-t=s2></span></h2>
  <div class=row><button class=act id=pick data-t=choose></button><span id=dest data-t=nodir></span></div>
  <div id=pathbox style="margin-top:11px;display:none">
    <input type=text id=path style="font:inherit;padding:9px 11px;border:1px solid var(--line);border-radius:8px;width:100%">
    <p class="info show" data-t=pathhint></p>
  </div>
</div>

<div class=card><h2><span class=num>3</span><span data-t=s3></span></h2>
  <div class=row style=margin-bottom:4px>
    <span data-t=doclang></span>
    <select id=lang>
      <option value=eng data-t=l_eng></option>
      <option value=eng+ara data-t=l_both></option>
      <option value=ara data-t=l_ara></option>
    </select>
    <button class=i data-info=i_lang>i</button>
  </div>
  <p class=info id=i_lang data-t=t_lang></p>

  <div class=opt><input type=checkbox id=rotate checked><label for=rotate data-t=o_rotate></label>
    <button class=i data-info=i_rotate>i</button></div>
  <p class=info id=i_rotate data-t=t_rotate></p>

  <div class=opt><input type=checkbox id=redo><label for=redo data-t=o_redo></label>
    <button class=i data-info=i_redo>i</button></div>
  <p class=info id=i_redo data-t=t_redo></p>

  <div class=opt><input type=checkbox id=deskew><label for=deskew data-t=o_deskew></label>
    <button class=i data-info=i_deskew>i</button></div>
  <p class=info id=i_deskew data-t=t_deskew></p>

  <div class=opt><input type=checkbox id=verbose><label for=verbose data-t=o_verbose></label>
    <button class=i data-info=i_verbose>i</button></div>
  <p class=info id=i_verbose data-t=t_verbose></p>
</div>

<div class=card><h2><span class=num>4</span><span data-t=s4></span></h2>
  <div class=row>
    <button id=go class="act primary" data-t=start disabled></button>
    <button id=save class=act data-t=save disabled></button><span id=savemsg></span>
  </div>
  <div class=bar><i id=prog></i></div>
  <div id=dl></div>
  <div id=log></div>
</div>
</main>
<script>
const STR={
 en:{title:"OCRmyPDF Portable",
     sub:"Adds an invisible, searchable text layer to scanned PDFs. Every file stays on this PC.",
     s1:"Add PDFs", drop:"Drop PDF files here, or click to browse",
     s2:"Where to save the results", choose:"Choose folder…", nodir:"No folder chosen.",
     pathhint:"Paste a folder path from Explorer's address bar, then press Tab.",
     s3:"Options", doclang:"Document language:",
     l_eng:"English", l_both:"English + Arabic", l_ara:"Arabic only",
     t_lang:"English is fastest and most accurate. Choose English + Arabic when one document mixes both — each page is read in both scripts, which is slower and slightly less accurate on English-only pages. Arabic accuracy on scans is lower than English in all cases.",
     o_rotate:"Auto-rotate pages",
     t_rotate:"Detects pages scanned sideways or upside down and turns them upright before reading them.",
     o_redo:"Redo OCR (replace existing text layer)",
     t_redo:"Use when the PDF already has a text layer that is wrong. The old one is discarded and rebuilt. Leave this off for plain scans, where pages that already contain real text are skipped untouched.",
     o_deskew:"Deskew crooked scans",
     t_deskew:"Straightens pages that went through the scanner at a slight angle of 1 to 3 degrees. Improves reading accuracy, but the page image is re-rendered rather than kept exactly as scanned. Cannot be combined with Redo OCR.",
     o_verbose:"Detailed log",
     t_verbose:"Shows every internal step instead of a short summary. Useful only when something goes wrong.",
     s4:"Run", start:"Start OCR", save:"Save to folder",
     ready:"Ready. Add some PDFs to begin.", saving:"Saving…",
     saved:n=>`Saved ${n} file(s)`, nofiles:"Add at least one PDF first.",
     notfound:"Folder not found"},
 ar:{title:"OCRmyPDF المحمول",
     sub:"يضيف طبقة نص غير مرئية قابلة للبحث إلى ملفات PDF الممسوحة ضوئيًا. تبقى جميع الملفات على هذا الجهاز.",
     s1:"إضافة ملفات PDF", drop:"أفلت ملفات PDF هنا، أو انقر للاختيار",
     s2:"مكان حفظ النتائج", choose:"اختيار مجلد…", nodir:"لم يتم اختيار مجلد.",
     pathhint:"الصق مسار المجلد من شريط العنوان في مستكشف الملفات، ثم اضغط Tab.",
     s3:"الخيارات", doclang:"لغة المستند:",
     l_eng:"الإنجليزية", l_both:"الإنجليزية والعربية", l_ara:"العربية فقط",
     t_lang:"الإنجليزية هي الأسرع والأدق. اختر «الإنجليزية والعربية» عندما يجمع المستند الواحد بين اللغتين، إذ تُقرأ كل صفحة بالنظامين معًا، وهو أبطأ وأقل دقة قليلًا في الصفحات الإنجليزية وحدها. دقة التعرف على العربية في المستندات الممسوحة أقل من الإنجليزية في جميع الأحوال.",
     o_rotate:"تدوير الصفحات تلقائيًا",
     t_rotate:"يكتشف الصفحات الممسوحة بشكل جانبي أو المقلوبة ويعيدها إلى وضعها الصحيح قبل قراءتها.",
     o_redo:"إعادة التعرف الضوئي (استبدال طبقة النص الحالية)",
     t_redo:"استخدم هذا الخيار عندما يحتوي الملف على طبقة نص خاطئة، إذ تُحذف الطبقة القديمة وتُنشأ طبقة جديدة. اترك الخيار غير محدد للمستندات الممسوحة العادية، حيث تُترك الصفحات التي تحتوي على نص حقيقي كما هي.",
     o_deskew:"تصحيح ميلان الصفحات",
     t_deskew:"يصحح الصفحات التي مرت في الماسح الضوئي بزاوية مائلة بين درجة وثلاث درجات. يحسّن دقة القراءة، لكن تُعاد معالجة صورة الصفحة بدلًا من الاحتفاظ بها كما مُسحت. لا يمكن الجمع بينه وبين إعادة التعرف الضوئي.",
     o_verbose:"سجل تفصيلي",
     t_verbose:"يعرض كل خطوة داخلية بدلًا من ملخص مختصر. مفيد فقط عند حدوث مشكلة.",
     s4:"التشغيل", start:"بدء المعالجة", save:"حفظ في المجلد",
     saving:"جارٍ الحفظ…",   /* the log itself stays English in both languages */
     saved:n=>`تم حفظ ${n} ملف`, nofiles:"أضف ملف PDF واحدًا على الأقل.",
     notfound:"المجلد غير موجود"}};

const T=new URLSearchParams(location.search).get('t');
const $=id=>document.getElementById(id);
let L='en', files=[], dirHandle=null, since=0, poll=null, results=[];

function apply(lang){
  L=lang; const s=STR[lang];
  document.documentElement.lang=lang;
  document.documentElement.dir = lang==='ar' ? 'rtl' : 'ltr';
  document.querySelectorAll('[data-t]').forEach(el=>{
    const v=s[el.dataset.t]; if(typeof v==='string') el.textContent=v;});
  $('btn-en').className = lang==='en'?'on':'';
  $('btn-ar').className = lang==='ar'?'on':'';
  if(!$('log').textContent.trim()||$('log').dataset.idle) {
    $('log').textContent=STR.en.ready; $('log').dataset.idle='1';}
  if(!dirHandle && !$('dest').dataset.set) $('dest').textContent=s.nodir;
}
$('btn-en').onclick=()=>apply('en'); $('btn-ar').onclick=()=>apply('ar');
document.querySelectorAll('.i').forEach(b=>b.onclick=()=>$(b.dataset.info).classList.toggle('show'));

/* 1. files */
const drop=$('drop');
drop.onclick=()=>$('picker').click();
$('picker').onchange=e=>add([...e.target.files]);
['dragenter','dragover'].forEach(t=>drop.addEventListener(t,e=>{e.preventDefault();drop.classList.add('hot')}));
['dragleave','drop'].forEach(t=>drop.addEventListener(t,e=>{e.preventDefault();drop.classList.remove('hot')}));
drop.addEventListener('drop',e=>add([...e.dataTransfer.files]));
function add(fs){
  fs=fs.filter(f=>f.name.toLowerCase().endsWith('.pdf'));
  for(const f of fs) if(!files.some(x=>x.name===f.name&&x.size===f.size)) files.push(f);
  $('list').innerHTML=files.map(f=>
    `<li><b>${f.name}</b><span>${(f.size/1048576).toFixed(1)} MB</span></li>`).join('');
  refresh();
}

/* 2. destination */
$('pick').onclick=async()=>{
  if(window.showDirectoryPicker){
    try{dirHandle=await showDirectoryPicker({mode:'readwrite'});
        $('dest').innerHTML='<span class=ok>✓ '+dirHandle.name+'</span>';
        $('dest').dataset.set='1';}catch(e){}
  }else{$('pathbox').style.display='block';}
  refresh();
};
$('path').onchange=async()=>{
  const j=await (await fetch(`/checkdir?t=${T}&dir=${encodeURIComponent($('path').value)}`)).json();
  $('dest').innerHTML=j.ok?'<span class=ok>✓ '+j.dir+'</span>'
                          :'<span class=bad>'+STR[L].notfound+'</span>';
  $('dest').dataset.set = j.ok ? '1' : '';
  refresh();
};
const haveDest=()=>!!dirHandle||$('dest').dataset.set==='1';
function refresh(){$('go').disabled=!(files.length&&haveDest())}

/* 3. run */
$('go').onclick=async()=>{
  $('go').disabled=$('pick').disabled=true; $('save').disabled=true;
  $('dl').innerHTML=''; $('log').textContent=''; delete $('log').dataset.idle;
  since=0; results=[]; $('prog').style.width='4%';
  for(const f of files)
    await fetch(`/upload?t=${T}&name=${encodeURIComponent(f.name)}`,{method:'POST',body:f});
  const q=i=>$(i).checked?1:0;
  await fetch(`/start?t=${T}&lang=${$('lang').value}&rotate=${q('rotate')}`+
              `&redo=${q('redo')}&deskew=${q('deskew')}&verbose=${q('verbose')}`,{method:'POST'});
  poll=setInterval(tick,400);
};
async function tick(){
  const j=await (await fetch(`/log?t=${T}&since=${since}`)).json();
  since=j.next;
  if(j.lines.length){$('log').textContent+=j.lines.join('\n')+'\n';$('log').scrollTop=1e9}
  $('prog').style.width=Math.max(4,j.progress*100)+'%';
  if(j.done){
    clearInterval(poll); results=j.results;
    $('dl').innerHTML=results.map(r=>
      `<a class=dl download="${r.name}" href="/result?t=${T}&id=${r.id}">⬇ ${r.name}</a>`).join('');
    $('go').disabled=$('pick').disabled=false;
    $('save').disabled=!results.length;
  }
}

/* 4. save */
$('save').onclick=async()=>{
  $('save').disabled=true; $('savemsg').textContent=STR[L].saving;
  try{
    if(dirHandle){
      for(const r of results){
        const blob=await (await fetch(`/result?t=${T}&id=${r.id}`)).blob();
        const w=await (await dirHandle.getFileHandle(r.name,{create:true})).createWritable();
        await w.write(blob); await w.close();
      }
      $('savemsg').innerHTML='<span class=ok>'+STR[L].saved(results.length)+'</span>';
    }else{
      const j=await (await fetch(`/save?t=${T}&dir=${encodeURIComponent($('path').value)}`,
                                 {method:'POST'})).json();
      $('savemsg').innerHTML=j.ok?'<span class=ok>'+STR[L].saved(j.count)+'</span>'
                                 :'<span class=bad>'+STR[L].notfound+'</span>';
    }
  }catch(e){$('savemsg').innerHTML='<span class=bad>'+e+'</span>'}
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
            self._json({"lines": LOG[int(q.get("since", ["0"])[0]):], "next": len(LOG),
                        "done": STATE["done"] and not STATE["running"],
                        "progress": min(1.0, len(RESULTS) / max(len(UPLOADS), 1)),
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
                    for k in ("rotate", "redo", "deskew", "verbose")}
            opts["lang"] = q.get("lang", ["eng"])[0]
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
    c = ocr_cmd(Path("a.pdf"), Path("b.pdf"), {"rotate": True, "deskew": True, "lang": "eng+ara"})
    assert c[c.index("-l") + 1] == "eng+ara"
    assert "--skip-text" in c and "--deskew" in c
    assert c[c.index("--rotate-pages-threshold") + 1] == "0.1"
    assert "--output-type" in c and c[c.index("--output-type") + 1] == "pdf"
    assert c[c.index("--optimize") + 1] == "0"      # silences the jbig2/pngquant probes
    r = ocr_cmd(Path("a.pdf"), Path("b.pdf"), {"redo": True, "deskew": True})
    assert "--redo-ocr" in r and "--deskew" not in r          # incompatible pair
    assert ocr_cmd(Path("a"), Path("b"), {"lang": "nonsense"})[3:5] == ["-l", "eng"]

    assert JUNK.search("[WinError 2] The system cannot find the file specified")
    assert JUNK.search("UnicodeEncodeError: 'charmap' codec can't encode")
    assert not JUNK.search("    1 page is facing")
    assert CHATTER.match("        1 Running: ['tesseract', '--version']")
    assert not CHATTER.match("   Postprocessing...")

    nice = friendly("        1 page is facing ⇨, confidence 1.52 - will rotate")
    assert "on its side" in nice and "turned upright" in nice, nice
    assert "left as it is" in friendly("   1 page is facing ⇧, confidence 0.00 - no change")
    assert friendly("   1 [tesseract] Too few characters. Skipping this page")
    assert friendly("   Postprocessing...") is None
    assert child_env()["PYTHONIOENCODING"] == "utf-8"

    for key in ("title", "o_redo", "t_deskew", "l_both", "doclang"):
        assert f'{key}:"' in PAGE or f"{key}:" in PAGE, key
    assert "PDF/A" not in PAGE and "NAPS2" not in PAGE      # both removed on request
    assert "العربية" in PAGE and "dir=rtl" in PAGE
    print("selftest ok - bilingual browser UI, no desktop toolkit needed")


if __name__ == "__main__":
    selftest() if "--selftest" in sys.argv else main()
