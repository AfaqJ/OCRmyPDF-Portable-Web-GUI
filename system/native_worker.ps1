<#
  Python-free OCR worker for the Windows Forms front end.

  Why this exists
  ---------------
  On locked-down company PCs, Windows refuses to load Python's compiled
  extension modules (_ctypes, _socket, _imaging, pikepdf._core, ...), which
  kills OCRmyPDF. But the two programs that actually do the OCR work --
  tesseract.exe and ghostscript (gswin64c.exe) -- are standalone executables
  and load fine. This worker reproduces the pipeline using only those two,
  driven from PowerShell (.NET, always allowed).

  This file is "Path A": the engines-only, rasterizing path. It re-renders each
  page to an image, tries full-page recognition at each possible orientation
  until strong language evidence is found, then falls back to Tesseract's OSD
  sample windows and whole-page detector when words cannot decide. Tesseract
  emits a searchable PDF with an invisible text layer. For scanned documents the result is visually identical
  to OCRmyPDF's output at the same resolution. Path B (a lossless text overlay
  onto the original page, via a .NET PDF library) layers on top of this later
  and falls back to this path if the library is unavailable.

  Where the time goes
  -------------------
  Every page costs one Ghostscript render and one or more Tesseract recognition
  passes. Path B keeps the pass that proves orientation as the final page PDF;
  Path A must build its combined PDF afterward. What was reducible was the overhead:
    - Ghostscript renders a batch of pages per process (-ChunkPages, default
      10), not one page per process, so a 350-page PDF is opened ~35 times
      instead of 350.
    - Up to -Jobs Tesseract processes run at once, and the pool is kept full:
      the moment one page exits the next one starts. Tesseract is one page per
      process and does not thread, so this is the only way to use other cores.
  None of this trades accuracy for speed: same engines, same resolution, same
  settings, same output. It only stops re-launching programs and re-reading the
  same PDF. Knobs, if a machine needs different numbers: -Jobs, -ChunkPages.

  Why the progress never jumps
  ----------------------------
  A batched engine is fast but silent, and a silent window reads as a frozen
  one. Every stage therefore reports page by page against the whole document,
  never per batch, so the numbers only ever count up 1, 2, 3 ... of 22:
    - Ghostscript writes one file per page as it works, so Invoke-EngineWatched
      polls the output folder instead of waiting for the process to exit. That
      covers both the render and the born-digital text scan.
    - Invoke-EngineBatch reports each parallel process the moment it exits,
      rather than waiting for a whole wave of four -- that wait was what made
      the count jump 4, 8, 12. A call may also carry a `label`, which is
      written to the log at that same instant; that is how recognition says
      "Page 7: text layer added" while the run is still going. Under -Jobs the
      pages finish out of order, so those lines are not sorted by page.
    - Assembly reports per page as pages are added.
  The progress bar uses the same idea: a page is worth one unit per step that
  will actually be spent on it, so the bar advances at the same rate in every
  phase. A page that already has text is credited its skipped units at once,
  because that work genuinely never happens.

  Page ranges
  -----------
  job.json may carry a "ranges" array parallel to "inputs", each {first,last}.
  0 or missing means the document's own limits. Only the selected pages are
  OCR'd and only they appear in the output, which is named with the range so it
  cannot be mistaken for the whole document.

  Contract with native_gui.ps1 (unchanged from the Python worker):
    - reads a job.json (see -Config)
    - writes one JSON event per line to the events file (see -Events)
  Event shapes: file{index,state,pages,page} stage{text} progress{value}
                log{text,kind} result{path} summary{succeeded,failed} fatal{text}
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')][string]$Config,
    [Parameter(ParameterSetName = 'Run')][string]$Events,
    # Convenience: OCR a single file from the command line, no GUI / no job.json.
    [Parameter(ParameterSetName = 'One')][string]$InputPdf,
    [Parameter(ParameterSetName = 'One')][string]$OutDir,
    [Parameter(ParameterSetName = 'One')][string]$Lang = 'eng+ara',
    [Parameter(ParameterSetName = 'One')][int]$FirstPage = 0,
    [Parameter(ParameterSetName = 'One')][int]$LastPage = 0,
    [Parameter(ParameterSetName = 'Self')][switch]$SelfTest,
    [int]$Dpi = 300,
    # auto = lossless Path B when the PDF library loads, else Path A;
    # A = force rasterize path; B = force lossless path (still falls back per doc).
    [ValidateSet('auto', 'A', 'B')][string]$Mode = 'auto',
    # Speed knobs. 0 = pick from the core count. See "speed" note below.
    [int]$Jobs = 0,
    [int]$ChunkPages = 10,
    # How much extracted text makes a page "already has text". See
    # Test-PageHasText -- a stamp is not a text layer.
    [int]$TextMinChars = 100,
    # How many small crops of each page get their own orientation check and
    # vote. 0 = ask the whole page once, which is what this did before.
    # See Get-OrientationBatch.
    [int]$OsdCrops = 5,
    # Exact words that prove which way up a page reads. EMPTY BY DEFAULT: keep
    # document-specific words in ignored system\orientation_words.json (see
    # orientation_words.example.json), or pass generic ones here.
    [string[]]$PriorityWords = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# --- paths to the bundled engines ------------------------------------------
$App = Join-Path $PSScriptRoot '..\app'
$script:Tesseract  = Join-Path $App 'Library\bin\tesseract.exe'
$script:Ghostscript = Join-Path $App 'Library\bin\gswin64c.exe'
$env:TESSDATA_PREFIX = (Join-Path $App 'share\tessdata')

$script:LangMap = @{ 'eng' = 'eng'; 'eng+ara' = 'eng+ara'; 'ara' = 'ara' }
$script:OsdConfidenceFloor = 0.01   # matches prerotate.py: act on any angle offered
$script:PdfLib = Join-Path $PSScriptRoot 'lib\PdfSharp.dll'
$script:PdfLibLoaded = $false

# Speed settings (see the "Where the time goes" note in the header).
$script:MaxParallel = if ($Jobs -gt 0) { $Jobs }
                      else { [Math]::Max(1, [Math]::Min(4, [Environment]::ProcessorCount - 1)) }
$script:ChunkPages = [Math]::Max(1, $ChunkPages)
$script:TextMinChars = [Math]::Max(1, $TextMinChars)
$script:OsdCrops = [Math]::Max(0, [Math]::Min(5, $OsdCrops))
# 650 px is the crop size used by the makandra recipe this follows. At
# 300 dpi that is about 2.2 inches -- enough body text for OSD, small
# enough that page margins and stamps cannot drown it.
$script:OsdCropPx = 650
# Full recognition tries upright first, then the common upside-down case, then
# the two sideways cases. A page stops at the first rotation with strong text.
$script:OrientationTurns = @(0, 180, 90, 270)
$script:WordConfidence = 70.0
# ONE number, one rule. Every known word read on a rotation is worth one point,
# EVERY TIME IT APPEARS. No word classes, no caps, no second tier: a hit is a
# hit. Months, years and abbreviations are ordinary words and score the same.
#
# Three points stops the search -- one word three times, three different words,
# or any mix. A word from the private list passes on its own, immediately.
#
# The same number also picks the winning rotation when nothing reaches three,
# so a page that scores 1 is still read as upright rather than handed to OSD.
$script:ScoreToDecide = 3
$script:ScorePriority = 1000
$script:PriorityWords = @($PriorityWords | Where-Object { $_ -and $_.Trim().Length -gt 0 })
if ($script:PriorityWords.Count -eq 0 -and -not $PSBoundParameters.ContainsKey('PriorityWords')) {
    # Not tracked by git on purpose. What is written on someone's documents is
    # theirs, and this repository is a generic tool.
    $wordFile = Join-Path $PSScriptRoot 'orientation_words.json'
    if (Test-Path -LiteralPath $wordFile) {
        try {
            $loaded = (Get-Content -LiteralPath $wordFile -Raw -Encoding UTF8 | ConvertFrom-Json)
            $script:PriorityWords = @($loaded.words | Where-Object { $_ -and $_.Trim().Length -gt 0 })
        } catch { $script:PriorityWords = @() }
    }
}
$script:PriorityWordSet = @{}
foreach ($word in $script:PriorityWords) {
    $clean = (($word.ToLowerInvariant() -replace '[^a-z0-9]', ' ') -replace '\s+', ' ').Trim()
    if ($clean -and $clean -notmatch ' ') { $script:PriorityWordSet[$clean] = $true }
}
$script:CommonWordSet = @{}
$commonFile = Join-Path $PSScriptRoot 'common_words.txt'
if (Test-Path -LiteralPath $commonFile) {
    foreach ($word in @(Get-Content -LiteralPath $commonFile -Encoding UTF8)) {
        $clean = $word.Trim().ToLowerInvariant()
        # 2, not 4. The old floor of four threw away and, or, of, no, may, vat
        # -- the words that actually appear on a bill or a contract. A single
        # character is still refused: OCR noise produces those by the dozen.
        if ($clean.Length -ge 2) { $script:CommonWordSet[$clean] = $true }
    }
}
# Any year a document is likely to carry. Cheaper than 51 lines in the file,
# and it cannot drift out of date by being forgotten.
foreach ($year in 2000..2050) { $script:CommonWordSet["$year"] = $true }

# How the progress bar is weighted. One unit = one step spent on one page.
# Both are set for real in Invoke-Run, once the path and the rotate setting are
# known, because those decide how many steps a page actually costs.
#   Path B: scan + render + [orientation] + recognise + assemble  = 4 or 5
#   Path A:        render + [orientation] + build                 = 2 or 3
$script:UnitsPerOcrPage = 3   # the steps a page skips if it already has text
$script:UnitsPerPage    = 5   # everything one page costs, start to finish
# Deliberately absent: any knob that trades output quality for speed. Every
# change here is structural -- the same engines, the same settings, the same
# pixels -- so the OCR result is byte-identical to the per-page version.

# --- event emission --------------------------------------------------------
$script:EventWriter = $null

function Emit([string]$Event, [hashtable]$Fields = @{}) {
    $obj = [ordered]@{ event = $Event }
    foreach ($k in $Fields.Keys) { $obj[$k] = $Fields[$k] }
    $line = ($obj | ConvertTo-Json -Compress -Depth 6)
    if ($script:EventWriter) { $script:EventWriter.WriteLine($line); $script:EventWriter.Flush() }
    else { [Console]::Out.WriteLine($line) }
}

function Write-Report($Report, [string]$Text) {
    if ($Report) { $Report.WriteLine($Text.TrimEnd()); $Report.Flush() }
}

# Progress is one shared counter (script scope, no closures -- closures get
# their own module scope in PowerShell, which silently breaks the count).
# A unit is one step spent on one page, so the bar moves at the same rate
# whether the current step is rendering, checking orientation, recognising or
# assembling. See "Why the progress never jumps" in the header.
$script:Done = 0
$script:TotalUnits = 1
function Update-Progress([int]$Units = 1) {
    if ($Units -le 0) { return }
    $script:Done += $Units
    Emit 'progress' @{ value = [Math]::Min(99, [int]($script:Done * 100 / $script:TotalUnits)) }
}

# --- what the window is told about the document being worked on ------------
# Also script scope, and for the same reason. Every stage line and every file
# row update counts pages of THIS document, never pages of the current batch,
# so a batch boundary is invisible to whoever is watching.
$script:DocIndex = 0
$script:DocName  = ''
$script:DocPages = 1
$script:DocDone  = 0

function Start-Document([int]$Index, [string]$Name, [int]$Pages) {
    $script:DocIndex = $Index
    $script:DocName  = $Name
    $script:DocPages = [Math]::Max(1, $Pages)
    $script:DocDone  = 0
    Emit 'file' @{ index = $Index; state = 'running'; pages = $Pages; page = 0 }
}

function Step-Document([int]$Pages = 1) {
    # N more pages of this document need no further recognition work: either
    # Tesseract has just finished them, or they already carried text.
    if ($Pages -le 0) { return }
    $script:DocDone = [Math]::Min($script:DocPages, $script:DocDone + $Pages)
    Emit 'file' @{ index = $script:DocIndex; state = 'running'
                   pages = $script:DocPages; page = $script:DocDone }
}

function Show-Stage([string]$Verb, [int]$Done, [int]$Total) {
    # One shape for every stage: "scan.pdf - reading 7 of 22 pages". Built by
    # concatenation, not -f: a file name containing a brace would break -f.
    Emit 'stage' @{ text = "$script:DocName - $Verb $Done of $Total pages" }
}

# --- small helpers (pure -> unit tested) -----------------------------------
function Get-NextTarget([string]$Folder, [string]$SourcePath, [string]$Suffix = '') {
    $stem = [IO.Path]::GetFileNameWithoutExtension($SourcePath) + $Suffix
    $candidate = Join-Path $Folder ($stem + '_ocr.pdf')
    $n = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $Folder ($stem + "_ocr_$n.pdf")
        $n++
    }
    return $candidate
}

function Resolve-PageRange([int]$PageCount, $First, $Last) {
    # Clamp a requested page range to what the document actually has. A missing
    # or zero bound means "the document's own limit", so "all pages" needs no
    # special case anywhere else. Always returns a usable range.
    $f = if ($First) { [int]$First } else { 1 }
    $l = if ($Last)  { [int]$Last }  else { $PageCount }
    if ($f -lt 1) { $f = 1 }
    if ($f -gt $PageCount) { $f = $PageCount }
    if ($l -gt $PageCount) { $l = $PageCount }
    if ($l -lt $f) { $l = $f }
    return @{ first = $f; last = $l; count = ($l - $f + 1) }
}

function Get-RangeSuffix([int]$First, [int]$Last, [int]$PageCount) {
    # Name a part-document output after the pages it actually contains, so it is
    # never mistaken for the whole file.
    if ($First -le 1 -and $Last -ge $PageCount) { return '' }
    if ($First -eq $Last) { return "_p$First" }
    return "_p$First-$Last"
}

# Tesseract OSD "Rotate:" = clockwise degrees to make the page upright.
function ConvertFrom-OsdOutput([string]$Text) {
    $rot = [regex]::Match($Text, '(?m)^Rotate:\s*(\d+)')
    $conf = [regex]::Match($Text, '(?m)^Orientation confidence:\s*([\d.]+)')
    if (-not $rot.Success -or -not $conf.Success) { return @{ turn = 0; conf = 0.0 } }
    return @{ turn = ([int]$rot.Groups[1].Value % 360); conf = [double]$conf.Groups[1].Value }
}

# clockwise degrees -> System.Drawing.RotateFlipType
function Get-RotateFlip([int]$Turn) {
    switch ($Turn % 360) {
        90  { [Drawing.RotateFlipType]::Rotate90FlipNone }
        180 { [Drawing.RotateFlipType]::Rotate180FlipNone }
        270 { [Drawing.RotateFlipType]::Rotate270FlipNone }
        default { [Drawing.RotateFlipType]::RotateNoneFlipNone }
    }
}

function Resolve-Lang([string]$Lang) {
    if ($script:LangMap.ContainsKey($Lang)) { return $script:LangMap[$Lang] }
    return 'eng'
}

# --- engine calls ----------------------------------------------------------
function ConvertTo-CmdArg([string]$Value) {
    # Quote an argument for ProcessStartInfo.Arguments (Windows PowerShell 5.1
    # has no ArgumentList). Enough for our file paths and flags.
    if ($Value -eq '' -or $Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Start-Engine([string]$Exe, [string[]]$EngineArgs) {
    # Launch one bundled exe and hand back the live process. Nothing waits here,
    # so the caller decides how to report while it runs.
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($EngineArgs | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    # Read both pipes async: a full buffer on either one deadlocks the child.
    return @{
        proc = $proc
        out  = $proc.StandardOutput.ReadToEndAsync()
        err  = $proc.StandardError.ReadToEndAsync()
        index = 0
    }
}

function Complete-Engine($Running) {
    # WaitForExit() with no timeout is required even after the process has
    # exited: it is what waits for the two async pipe reads to finish.
    $Running.proc.WaitForExit()
    $r = @{ code = $Running.proc.ExitCode; out = $Running.out.Result; err = $Running.err.Result }
    $Running.proc.Dispose()
    return $r
}

function Invoke-Engine([string]$Exe, [string[]]$EngineArgs) {
    # Run one bundled exe to completion, capture stdout+stderr, no window.
    return (Complete-Engine (Start-Engine $Exe $EngineArgs))
}

function Invoke-EngineWatched {
    # Run ONE engine that writes a file per page, and report each page the
    # moment its file lands on disk. Ghostscript renders a whole batch in a
    # single process, so without this the window says nothing at all for the
    # length of the batch -- the longest silence in the run. Polling the output
    # folder needs no output stream parsing and cannot deadlock.
    param(
        [string]$Exe, [string[]]$EngineArgs,
        [string]$WatchDir, [string]$Filter, [int]$Expected,
        [string]$Verb, [int]$Offset, [int]$Total, [int]$ProgressUnits = 1
    )
    $run = Start-Engine $Exe $EngineArgs
    $seen = 0
    $exited = $false
    while (-not $exited) {
        $exited = $run.proc.WaitForExit(200)
        # On exit everything it was going to write is written; while running,
        # the newest file may still be half-written, which is fine -- the page
        # it belongs to really is the one being worked on.
        $n = if ($exited) { $Expected }
             else { @(Get-ChildItem -LiteralPath $WatchDir -Filter $Filter -ErrorAction SilentlyContinue).Count }
        if ($n -gt $Expected) { $n = $Expected }
        while ($seen -lt $n) {
            $seen++
            Show-Stage $Verb ($Offset + $seen) $Total
            Update-Progress $ProgressUnits
        }
    }
    return (Complete-Engine $run)
}

function Invoke-EngineBatch {
    # Run several bundled-exe calls with up to -Jobs alive at once, and return
    # their results in the order they were given. Each call is
    # @{ exe = <path>; engineArgs = @(...); label = <optional log line> }.
    #
    # A call carrying a `label` writes that line to the log the instant its own
    # process exits. That is the only place it CAN be written from: this
    # function does not return until the whole batch is done, so a caller
    # looping over the results afterwards would print a chunk's worth of lines
    # all at once, which is the silence D-021 exists to prevent. The cost of
    # writing them as they land is that pages finish out of order under -Jobs,
    # so the page numbers in the log are not sorted. That is real -- they
    # genuinely finished in that order.
    #
    # The pool is kept full: the moment one page exits, the next one starts.
    # The old version launched four, waited for all four, then launched four
    # more -- which left cores idle at the tail of every wave AND made the
    # count jump 4, 8, 12 instead of counting up one page at a time.
    param(
        [object[]]$Calls, [string]$Verb = '', [int]$Offset = 0, [int]$Total = 0,
        [int]$ProgressUnits = 0, [bool]$StepDocument = $false
    )
    if ($Calls.Count -eq 0) { return @() }
    $results = New-Object 'object[]' $Calls.Count
    $running = New-Object Collections.Generic.List[object]
    $next = 0
    $finished = 0
    while ($finished -lt $Calls.Count) {
        while ($running.Count -lt $script:MaxParallel -and $next -lt $Calls.Count) {
            $started = Start-Engine $Calls[$next].exe $Calls[$next].engineArgs
            $started['index'] = $next
            [void]$running.Add($started)
            $next++
        }
        Start-Sleep -Milliseconds 50
        # Backwards, because finished entries are removed from the list.
        for ($j = $running.Count - 1; $j -ge 0; $j--) {
            if (-not $running[$j].proc.HasExited) { continue }
            $b = $running[$j]
            $results[$b.index] = Complete-Engine $b
            $running.RemoveAt($j)
            $finished++
            if ($Calls[$b.index].ContainsKey('label')) {
                Emit 'log' @{ kind = 'dim'; text = $Calls[$b.index].label }
            }
            if ($Verb) { Show-Stage $Verb ($Offset + $finished) $Total }
            Update-Progress $ProgressUnits
            if ($StepDocument) { Step-Document 1 }
        }
    }
    # Flat array of hashtables. Every caller wraps the result in @() so a
    # single-item result cannot arrive as a bare scalar.
    return $results
}

function Get-ChunkEnd([int]$Count, [int]$Start, [int]$Size) {
    # Last index of the batch that starts at $Start -- one plain integer.
    # An earlier version handed back the batches themselves as an array of
    # arrays; PowerShell flattened that on the way out of the function and the
    # caller got one long list of loose page numbers instead of batches. A
    # scalar cannot be unrolled, so the callers slice for themselves.
    return [Math]::Min($Count, $Start + $Size) - 1
}

function ConvertTo-PostScriptPath([string]$Path) {
    # Counting pages is the one place a file name is not passed as an argument
    # but pasted into a PostScript program, where "(" and ")" delimit a string
    # and "\" escapes. "invoice (1).pdf" survives only because its brackets
    # happen to balance; "scan (1.pdf" or "report).pdf" would end the string
    # early and Ghostscript would fail to parse the program at all -- the same
    # class of bug as the launcher dying on a folder called "... (1)".
    # Backslashes go first: they become "/", so the escapes added after are the
    # only backslashes left in the string.
    return $Path.Replace('\', '/').Replace('(', '\(').Replace(')', '\)')
}

function Get-PageCount([string]$Pdf) {
    # Ghostscript page-count trick; falls back to 1 on any trouble.
    $prog = "($(ConvertTo-PostScriptPath $Pdf)) (r) file runpdfbegin pdfpagecount = quit"
    $r = Invoke-Engine $script:Ghostscript @('-q', '-dNODISPLAY', '-dNOSAFER', '-c', $prog)
    $m = [regex]::Match($r.out, '\d+')
    if ($m.Success) { return [Math]::Max(1, [int]$m.Value) }
    return 1
}

function Export-PageImages([string]$Pdf, [int[]]$PageNumbers, [string]$Folder, [int]$Dpi,
                           [int]$Offset = 0, [int]$Total = 0) {
    # Render a batch of pages in ONE Ghostscript process. One process per page
    # meant re-opening and re-parsing the PDF once for every page, which on a
    # 350-page file is 350 full document loads.
    # Returns the rendered files in the same order as $PageNumbers.
    # $Offset/$Total are only for the "reading N of M pages" line: the process
    # is watched while it runs so the count rises page by page, not per batch.
    if ($PageNumbers.Count -eq 0) { return @() }
    if (Test-Path -LiteralPath $Folder) { Remove-Item -LiteralPath $Folder -Recurse -Force }
    [IO.Directory]::CreateDirectory($Folder) | Out-Null

    $contiguous = $true
    for ($i = 1; $i -lt $PageNumbers.Count; $i++) {
        if ($PageNumbers[$i] -ne ($PageNumbers[$i - 1] + 1)) { $contiguous = $false; break }
    }
    $gsArgs = @('-q', '-dNOPAUSE', '-dBATCH', '-dSAFER', '-sDEVICE=png16m', "-r$Dpi")
    if ($contiguous) {
        $gsArgs += @("-dFirstPage=$($PageNumbers[0])", "-dLastPage=$($PageNumbers[$PageNumbers.Count - 1])")
    } else {
        $gsArgs += @('-sPageList=' + ($PageNumbers -join ','))
    }
    $gsArgs += @('-o', (Join-Path $Folder 'p%05d.png'), $Pdf)
    $r = Invoke-EngineWatched $script:Ghostscript $gsArgs $Folder 'p*.png' `
            $PageNumbers.Count 'reading' $Offset ($(if ($Total) { $Total } else { $PageNumbers.Count })) 1

    # Ghostscript's %d counter differs between page-range forms, so trust the
    # sorted order rather than the numbers it chose.
    $files = @(Get-ChildItem -LiteralPath $Folder -Filter 'p*.png' -ErrorAction SilentlyContinue |
               Sort-Object Name | ForEach-Object { $_.FullName })
    if ($files.Count -ne $PageNumbers.Count) {
        throw ("Ghostscript rendered {0} of {1} pages ({2})" -f $files.Count, $PageNumbers.Count, $r.err.Trim())
    }
    return $files
}

function ConvertTo-OrientationDecision([hashtable]$Osd) {
    # Same decision rule as prerotate.py: act on any angle the detector offers.
    # "detector score", not "confidence": this is Tesseract's own OSD number,
    # which is not a percentage and not the 0-100 word confidence used by the
    # language check. Two different scales in one log need two different words.
    if ($Osd.turn -ne 0 -and $Osd.conf -ge $script:OsdConfidenceFloor) {
        return @{ turn = $Osd.turn; why = ("detector score {0:F2}" -f $Osd.conf) }
    }
    if ($Osd.conf -ge $script:OsdConfidenceFloor) {
        return @{ turn = 0; why = ("already upright, detector score {0:F2}" -f $Osd.conf) }
    }
    return @{ turn = 0; why = 'too little text to tell which way up it is - left alone' }
}

function Get-NormalizedText([string]$Text) {
    # Everything the comparison should not care about, removed: case,
    # punctuation, line breaks, and the runs of spaces OCR leaves behind.
    if (-not $Text) { return '' }
    $t = $Text.ToLowerInvariant() -replace '[^a-z0-9]', ' '
    return ($t -replace '\s+', ' ').Trim()
}

function Get-TsvWords([string]$Path) {
    # Tesseract TSV has one word per level-5 row: confidence in column 11 and
    # text in column 12. Return flat hashtables (D-018's PowerShell shape rule).
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $out = New-Object Collections.Generic.List[object]
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $parts = @($line -split "`t", 12)
        if ($parts.Count -lt 12 -or $parts[0] -ne '5') { continue }
        try { $confidence = [double]::Parse($parts[10], [Globalization.CultureInfo]::InvariantCulture) }
        catch { continue }
        foreach ($word in @((Get-NormalizedText $parts[11]) -split ' ' | Where-Object { $_ })) {
            [void]$out.Add(@{ word = $word; confidence = $confidence })
        }
    }
    return $out.ToArray()
}

function Get-LanguageEvidence([object[]]$Words) {
    # Score one rotation: one point per known word read, every time it appears.
    # Returns @{ decided; score; why }.
    #
    # `decided` only means "stop searching now". `score` is the real output:
    # Get-OrientationBatch compares the four rotations with it, so a page that
    # never clears the bar is still decided by evidence rather than by OSD.
    #
    # Case cannot matter: Get-NormalizedText has already lower-cased the page
    # and both word sets were built lower-cased.
    $score = 0
    $priority = 0
    foreach ($item in $Words) {
        if ([double]$item.confidence -lt $script:WordConfidence) { continue }
        $word = ([string]$item.word).ToLowerInvariant()
        if ($script:PriorityWordSet.ContainsKey($word)) { $priority++; continue }
        if ($script:CommonWordSet.ContainsKey($word)) { $score++ }
    }
    if ($priority -gt 0) { $score += $script:ScorePriority }
    $why = ''
    if ($priority -gt 0) {
        # WHICH word matched is never said. That it came from the list is not a
        # leak, and without it the log cannot explain itself.
        $why = 'a word from your list'
    } elseif ($score -ge $script:ScoreToDecide) {
        $why = "$score words matched"
    }
    return @{ decided = [bool]$why; score = $score; why = $why }
}

function Get-CropRects([int]$Width, [int]$Height, [int]$Count) {
    # Where to cut the sample windows: centre first, then the four quadrants.
    # A flat array of hashtables -- never an array of arrays (D-018 shape rule).
    #
    # A page must be big enough to hold windows that are actually DIFFERENT.
    # Five windows cut from a page barely wider than one window overlap by ~93%
    # and would vote as five copies of the same sample -- a stuffed ballot that
    # looks like agreement. Below twice the window size, take the centre only.
    # Exact duplicates are dropped too, for the same reason.
    if ($Count -le 0) { return @() }
    $size = [Math]::Min($script:OsdCropPx, [Math]::Min($Width, $Height))
    if ($size -lt 64) { return @() }
    if ($Width -lt (2 * $size) -or $Height -lt (2 * $size)) { $Count = 1 }
    $fx = @(0.5, 0.28, 0.72, 0.28, 0.72)
    $fy = @(0.5, 0.28, 0.28, 0.72, 0.72)
    $rects = New-Object Collections.Generic.List[object]
    $seen = New-Object Collections.Generic.HashSet[string]
    for ($i = 0; $i -lt $Count -and $i -lt $fx.Count; $i++) {
        $x = [int]([Math]::Round($fx[$i] * $Width) - $size / 2)
        $y = [int]([Math]::Round($fy[$i] * $Height) - $size / 2)
        if ($x -lt 0) { $x = 0 }
        if ($y -lt 0) { $y = 0 }
        if (($x + $size) -gt $Width)  { $x = $Width  - $size }
        if (($y + $size) -gt $Height) { $y = $Height - $size }
        if ($seen.Add("$x,$y")) { [void]$rects.Add(@{ x = $x; y = $y; size = $size }) }
    }
    return $rects.ToArray()
}

function New-OsdCrops([string]$Png, [int]$Count) {
    # Cut the sample windows out of a rendered page. Flat array of file paths.
    if ($Count -le 0) { return @() }
    $out = New-Object Collections.Generic.List[string]
    $src = [Drawing.Bitmap]::FromFile($Png)
    try {
        $rects = @(Get-CropRects $src.Width $src.Height $Count)
        for ($i = 0; $i -lt $rects.Count; $i++) {
            $r = $rects[$i]
            $rect = New-Object Drawing.Rectangle([int]$r.x, [int]$r.y, [int]$r.size, [int]$r.size)
            $crop = $src.Clone($rect, $src.PixelFormat)
            try {
                $path = "$Png.osd$i.png"
                $crop.Save($path, [Drawing.Imaging.ImageFormat]::Png)
                [void]$out.Add($path)
            } finally { $crop.Dispose() }
        }
    } finally { $src.Dispose() }
    return $out.ToArray()
}

function Get-CropVerdict([object[]]$Crops) {
    # Tally the sample windows. Returns @{ decided; turn; why; voters }.
    #
    # Separate from Resolve-Orientation because the ANSWER TO decided
    # decides whether the whole-page check has to run at all. On a page whose
    # windows agree, it does not -- and that call is the expensive one
    # (a full A4 at 300 dpi is ~20x the pixels of one 650 px window).
    $tally = @{}
    $voters = 0
    foreach ($c in $Crops) {
        if ($c.conf -lt $script:OsdConfidenceFloor) { continue }
        $voters++
        if ($tally.ContainsKey($c.turn)) { $tally[$c.turn] = $tally[$c.turn] + 1 }
        else { $tally[$c.turn] = 1 }
    }
    $bestCount = 0
    foreach ($k in $tally.Keys) { if ($tally[$k] -gt $bestCount) { $bestCount = $tally[$k] } }
    $winners = New-Object Collections.Generic.List[int]
    foreach ($k in $tally.Keys) { if ($tally[$k] -eq $bestCount) { [void]$winners.Add([int]$k) } }
    if ($bestCount -ge 2 -and $winners.Count -eq 1) {
        return @{ decided = $true; turn = $winners[0]
                  why = "$bestCount of $voters samples agree"; voters = $voters }
    }
    return @{ decided = $false; turn = 0; why = ''; voters = $voters }
}

function Resolve-Orientation([object[]]$Crops, [hashtable]$FullPage) {
    # The decision, plus what to do when it cannot be made.
    #
    # $Crops are RAW OSD readings @{turn;conf}, deliberately not decisions.
    # ConvertTo-OrientationDecision flattens "no confidence" into turn 0, which
    # reads as a vote for "upright" -- a completely different claim from "no
    # opinion". Voting on decisions would stuff the ballot with silent windows.
    #
    # Windows that answer but disagree are the case nobody could see before: the
    # page is kept on the whole-page answer, but the disagreement is said out
    # loud, so a confidently wrong angle stops being indistinguishable from a
    # confidently right one.
    $v = Get-CropVerdict $Crops
    if ($v.decided) { return @{ turn = $v.turn; why = $v.why } }
    if ($v.voters -ge 2) {
        return @{ turn = $FullPage.turn
                  why  = "samples disagree ($($v.voters) answered) - fell back to the whole page: $($FullPage.why)" }
    }
    return $FullPage
}

function Get-OsdOrientationBatch([string[]]$Pngs) {
    # The D-024 detector is the fallback only: sample windows first, then the
    # whole page when fewer than two samples agree.
    if ($Pngs.Count -eq 0) { return @() }
    $out = New-Object 'object[]' $Pngs.Count
    $rawCrops = New-Object 'object[]' $Pngs.Count
    for ($i = 0; $i -lt $Pngs.Count; $i++) {
        $rawCrops[$i] = New-Object 'object[]' 0
    }
    $temp = New-Object Collections.Generic.List[string]

    try {
        if ($script:OsdCrops -gt 0) {
            $calls = New-Object Collections.Generic.List[object]
            $first = New-Object 'int[]' $Pngs.Count
            $count = New-Object 'int[]' $Pngs.Count
            for ($i = 0; $i -lt $Pngs.Count; $i++) {
                $first[$i] = $calls.Count
                $crops = @(New-OsdCrops $Pngs[$i] $script:OsdCrops)
                $count[$i] = $crops.Count
                foreach ($c in $crops) {
                    [void]$temp.Add($c)
                    [void]$calls.Add(@{ exe = $script:Tesseract
                                        engineArgs = @($c, 'stdout', '--psm', '0', '-l', 'osd',
                                                       '-c', 'min_characters_to_try=20') })
                }
            }
            if ($calls.Count -gt 0) {
                $res = @(Invoke-EngineBatch $calls.ToArray() '' 0 0 0 $false)
                for ($i = 0; $i -lt $Pngs.Count; $i++) {
                    $r = New-Object 'object[]' $count[$i]
                    for ($k = 0; $k -lt $count[$i]; $k++) {
                        $one = $res[$first[$i] + $k]
                        $r[$k] = ConvertFrom-OsdOutput ($one.out + $one.err)
                    }
                    $rawCrops[$i] = $r
                }
            }
        }

        $needFull = New-Object Collections.Generic.List[int]
        for ($i = 0; $i -lt $Pngs.Count; $i++) {
            $v = Get-CropVerdict $rawCrops[$i]
            if ($v.decided) { $out[$i] = @{ turn = $v.turn; why = $v.why } }
            else { [void]$needFull.Add($i) }
        }

        if ($needFull.Count -gt 0) {
            $calls2 = New-Object Collections.Generic.List[object]
            foreach ($i in $needFull) {
                [void]$calls2.Add(@{ exe = $script:Tesseract
                                     engineArgs = @($Pngs[$i], 'stdout', '--psm', '0', '-l', 'osd') })
            }
            $fullRes = @(Invoke-EngineBatch $calls2.ToArray() '' 0 0 0 $false)
            $slot = 0
            foreach ($i in $needFull) {
                $one = $fullRes[$slot]; $slot++
                $full = ConvertTo-OrientationDecision (ConvertFrom-OsdOutput ($one.out + $one.err))
                $out[$i] = Resolve-Orientation $rawCrops[$i] $full
            }
        }
        return $out
    } finally {
        foreach ($c in $temp) { Remove-Item -LiteralPath $c -Force -ErrorAction SilentlyContinue }
    }
}

function Get-OrientationBatch {
    param(
        [string[]]$Pngs, [int]$Offset = 0, [int]$Total = 0,
        [string]$Lang = 'eng', [int]$Dpi = 300, [string]$TrialDir = ''
    )
    # Whole-page recognition is the strongest orientation test. Each rotation
    # emits TSV for scoring; Path B also emits its final searchable PDF in that
    # same call. Only pages without language evidence reach OSD.
    if ($Pngs.Count -eq 0) { return @() }
    $total = $(if ($Total) { $Total } else { $Pngs.Count })
    # The configured lexical evidence is English. In Arabic-only mode it can
    # never fire, so do not pay for four guaranteed-empty recognition passes.
    if ($Lang -eq 'ara') {
        $arabicFallback = @(Get-OsdOrientationBatch $Pngs)
        for ($i = 0; $i -lt $Pngs.Count; $i++) {
            $arabicFallback[$i]['pdf'] = ''
            Show-Stage 'checking orientation of' ($Offset + $i + 1) $total
            Update-Progress 1
        }
        return $arabicFallback
    }
    $wantPdf = -not [string]::IsNullOrEmpty($TrialDir)
    if ($wantPdf) { [IO.Directory]::CreateDirectory($TrialDir) | Out-Null }

    $out = New-Object 'object[]' $Pngs.Count
    $work = New-Object 'object[]' $Pngs.Count
    $currentTurn = New-Object 'int[]' $Pngs.Count
    $trialBases = New-Object 'object[]' $Pngs.Count
    # Best rotation seen so far for a page that has not cleared the bar. This
    # is what keeps OSD away from any page carrying readable text at all.
    $bestScore = New-Object 'int[]' $Pngs.Count
    $bestTurn = New-Object 'int[]' $Pngs.Count
    for ($i = 0; $i -lt $Pngs.Count; $i++) {
        $work[$i] = "$($Pngs[$i]).orientation.png"
        Copy-Item -LiteralPath $Pngs[$i] -Destination $work[$i] -Force
        $trialBases[$i] = @{}
    }

    try {
        foreach ($turn in $script:OrientationTurns) {
            $calls = New-Object Collections.Generic.List[object]
            $slots = New-Object Collections.Generic.List[int]
            for ($i = 0; $i -lt $Pngs.Count; $i++) {
                if ($null -ne $out[$i]) { continue }
                $delta = (($turn - $currentTurn[$i]) + 360) % 360
                if ($delta) { Set-ImageRotation $work[$i] $delta }
                $currentTurn[$i] = $turn
                $base = if ($wantPdf) {
                    Join-Path $TrialDir ("orientation_{0}_{1}" -f ($Offset + $i), $turn)
                } else { "$($Pngs[$i]).orientation_$turn" }
                $trialBases[$i][$turn] = $base
                $engineArgs = @($work[$i], $base, '--dpi', "$Dpi", '-l', $Lang)
                if ($wantPdf) { $engineArgs += @('pdf', 'tsv') } else { $engineArgs += @('tsv') }
                [void]$calls.Add(@{ exe = $script:Tesseract; engineArgs = $engineArgs })
                [void]$slots.Add($i)
            }
            if ($calls.Count -eq 0) { break }
            Show-Stage ("testing ${turn}-degree orientation on") $Offset $total
            $results = @(Invoke-EngineBatch $calls.ToArray() '' 0 0 0 $false)
            for ($slot = 0; $slot -lt $slots.Count; $slot++) {
                $i = $slots[$slot]
                $base = [string]$trialBases[$i][$turn]
                if ($results[$slot].code -ne 0) { continue }
                $evidence = Get-LanguageEvidence @(Get-TsvWords "$base.tsv")
                if ([int]$evidence.score -gt $bestScore[$i]) {
                    $bestScore[$i] = [int]$evidence.score
                    $bestTurn[$i] = $turn
                }
                if ($evidence.decided) {
                    $pdf = $(if ($wantPdf -and (Test-Path -LiteralPath "$base.pdf")) { "$base.pdf" } else { '' })
                    $out[$i] = @{ turn = $turn; why = $evidence.why; pdf = $pdf }
                }
            }
        }

        # A page that cleared nobody's bar but still read as SOMETHING at one
        # rotation is decided by comparison: the best of the four wins.
        #
        # This is the fix for the worst failure this code has had. The sample
        # windows are five crops of ONE page, so they are not five independent
        # opinions -- when OSD misreads a layout it misreads every crop the same
        # way, and "4 of 5 samples agree" is agreement about nothing. Eighteen
        # upright pages were turned over by exactly that. OSD is now unreachable
        # for any page where a single known word was read at any rotation.
        for ($i = 0; $i -lt $Pngs.Count; $i++) {
            if ($null -ne $out[$i] -or $bestScore[$i] -le 0) { continue }
            $turn = $bestTurn[$i]
            $pdf = ''
            if ($wantPdf -and $trialBases[$i].ContainsKey($turn)) {
                $candidate = ([string]$trialBases[$i][$turn]) + '.pdf'
                if (Test-Path -LiteralPath $candidate) { $pdf = $candidate }
            }
            $out[$i] = @{ turn = $turn; pdf = $pdf
                          why = "best of four rotations, $($bestScore[$i]) words matched" }
        }

        # Only a page with no known word at ANY rotation reaches the detector.
        $fallbackPngs = New-Object Collections.Generic.List[string]
        $fallbackSlots = New-Object Collections.Generic.List[int]
        for ($i = 0; $i -lt $Pngs.Count; $i++) {
            if ($null -eq $out[$i]) {
                [void]$fallbackPngs.Add($Pngs[$i]); [void]$fallbackSlots.Add($i)
            }
        }
        if ($fallbackSlots.Count -gt 0) {
            $fallback = @(Get-OsdOrientationBatch $fallbackPngs.ToArray())
            for ($slot = 0; $slot -lt $fallbackSlots.Count; $slot++) {
                $i = $fallbackSlots[$slot]
                $decision = $fallback[$slot]
                $pdf = ''
                $chosenTurn = [int]$decision.turn
                if ($wantPdf -and $trialBases[$i].ContainsKey($chosenTurn)) {
                    $candidate = ([string]$trialBases[$i][$chosenTurn]) + '.pdf'
                    if (Test-Path -LiteralPath $candidate) { $pdf = $candidate }
                }
                $out[$i] = @{ turn = $chosenTurn
                              why = "no known words at any rotation, $([string]$decision.why)"
                              pdf = $pdf }
            }
        }

        # Keep only the selected PDF. TSV and rejected rotations are temporary.
        for ($i = 0; $i -lt $Pngs.Count; $i++) {
            $keep = [string]$out[$i].pdf
            foreach ($base in $trialBases[$i].Values) {
                Remove-Item -LiteralPath "$base.tsv" -Force -ErrorAction SilentlyContinue
                $candidate = "$base.pdf"
                if ($candidate -ne $keep) {
                    Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
                }
            }
            Show-Stage 'checking orientation of' ($Offset + $i + 1) $total
            Update-Progress 1
        }
        return $out
    } finally {
        foreach ($path in $work) {
            if ($path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
        for ($i = 0; $i -lt $trialBases.Count; $i++) {
            foreach ($base in $trialBases[$i].Values) {
                Remove-Item -LiteralPath "$base.tsv" -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Set-ImageRotation([string]$Png, [int]$Turn) {
    if (($Turn % 360) -eq 0) { return }
    $bmp = [Drawing.Bitmap]::FromFile($Png)
    try {
        $bmp.RotateFlip((Get-RotateFlip $Turn))
        $copy = New-Object Drawing.Bitmap($bmp)   # detach from the file handle
        $bmp.Dispose()
        $copy.Save($Png, [Drawing.Imaging.ImageFormat]::Png)
        $copy.Dispose()
    } catch { $bmp.Dispose(); throw }
}

function Invoke-TesseractPdf([string[]]$Images, [string]$OutBase, [string]$Lang, [int]$Dpi) {
    # One searchable PDF from a list of page images (invisible text layer).
    $listFile = "$OutBase.images.txt"
    Set-Content -LiteralPath $listFile -Value $Images -Encoding ASCII
    $r = Invoke-Engine $script:Tesseract @($listFile, $OutBase, '--dpi', "$Dpi", '-l', $Lang, 'pdf')
    Remove-Item -LiteralPath $listFile -ErrorAction SilentlyContinue
    if ($r.code -ne 0 -or -not (Test-Path -LiteralPath "$OutBase.pdf")) {
        throw "Tesseract could not build the searchable PDF ($($r.err.Trim()))"
    }
    return "$OutBase.pdf"
}

function Publish-Output([string]$Completed, [string]$Target) {
    $staging = Join-Path (Split-Path $Target) (".{0}.{1}.tmp" -f (Split-Path $Target -Leaf), $PID)
    try {
        Copy-Item -LiteralPath $Completed -Destination $staging -Force
        if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force }
        Move-Item -LiteralPath $staging -Destination $Target -Force
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
    }
}

# --- one document ----------------------------------------------------------
function Set-PageOrientation([string]$Png, [int]$PageNo, [hashtable]$Decision, $Report) {
    if ($Decision.turn) {
        Set-ImageRotation $Png $Decision.turn
        Emit 'log' @{ kind = 'turn'; text = "Page ${PageNo}: turned $($Decision.turn) cw - $($Decision.why)" }
        Write-Report $Report "   page ${PageNo}: turned $($Decision.turn) cw ($($Decision.why))"
    } else {
        Emit 'log' @{ kind = 'dim'; text = "Page ${PageNo}: upright - $($Decision.why)" }
        Write-Report $Report "   page ${PageNo}: upright ($($Decision.why))"
    }
}

function Set-BatchOrientation {
    param(
        [string[]]$Pngs, [int[]]$PageNumbers, [int]$Offset, [int]$Total,
        $Report, [string]$Lang = 'eng', [int]$Dpi = 300, [string]$TrialDir = ''
    )
    # Check orientation a wave at a time, where a wave is the number of pages
    # actually running at once, and write each wave's LOG lines as soon as it
    # lands. Handing the whole chunk over in one call produced no log lines
    # until every page in the chunk had been checked, which looks frozen.
    #
    # Each candidate rotation updates the stage line before its batch starts.
    # The progress bar advances once the page's final orientation is known; a
    # rejected candidate is internal work, not another completed page.
    $out = New-Object 'object[]' $Pngs.Count
    for ($w = 0; $w -lt $Pngs.Count; $w += $script:MaxParallel) {
        $end = [Math]::Min($Pngs.Count, $w + $script:MaxParallel) - 1
        $wave = @($Pngs[$w..$end])
        $turns = @(Get-OrientationBatch $wave ($Offset + $w) $Total $Lang $Dpi $TrialDir)
        for ($k = 0; $k -lt $wave.Count; $k++) {
            Set-PageOrientation $wave[$k] $PageNumbers[$w + $k] $turns[$k] $Report
            $out[$w + $k] = $turns[$k]
        }
    }
    return $out
}

function Invoke-OneDocument {
    param(
        [int]$Index, [string]$Source, [int]$First, [int]$Last, [int]$PageCount,
        [string]$OutputDir, [string]$JobDir, [string]$Lang, [bool]$Rotate, [int]$Dpi,
        $Report
    )
    $count = $Last - $First + 1
    $name = [IO.Path]::GetFileName($Source)
    Start-Document $Index $name $count
    Emit 'log'  @{ kind = 'head'; text = "$name - $count page(s)" }
    Write-Report $Report "`n===== $Source (pages $First-$Last of $PageCount) ====="

    $pageDir = Join-Path $JobDir "doc$Index"
    [IO.Directory]::CreateDirectory($pageDir) | Out-Null
    $images = New-Object Collections.Generic.List[string]

    $pageNumbers = [int[]]@($First..$Last)
    for ($i = 0; $i -lt $pageNumbers.Count; $i += $script:ChunkPages) {
        $slice = [int[]]@($pageNumbers[$i..(Get-ChunkEnd $pageNumbers.Count $i $script:ChunkPages)])
        $pngs = @(Export-PageImages $Source $slice (Join-Path $pageDir ("c{0:D5}" -f $slice[0])) $Dpi $i $count)

        if ($Rotate) { [void](Set-BatchOrientation $pngs $slice $i $count $Report $Lang $Dpi) }

        for ($k = 0; $k -lt $slice.Count; $k++) {
            [void]$images.Add($pngs[$k])
            Step-Document 1
        }
    }

    # ponytail: the one step in either path that cannot report per page.
    # Tesseract is handed the whole page list and writes one PDF at the end, so
    # nothing lands on disk to count until it is finished. Path B does not have
    # this problem because it writes one PDF per page. Fixing it here needs a
    # way to merge PDFs without PDFsharp -- which is the very thing Path A
    # exists to do without. Its units are credited in one go below.
    Emit 'stage' @{ text = "$name - building the searchable PDF from $count page(s) - last step" }
    $ocr = Invoke-TesseractPdf $images.ToArray() (Join-Path $pageDir 'out') $Lang $Dpi
    Update-Progress $count

    $target = Get-NextTarget $OutputDir $Source (Get-RangeSuffix $First $Last $PageCount)
    Publish-Output $ocr $target
    Emit 'file'   @{ index = $Index; state = 'done'; pages = $count; page = $count }
    Emit 'result' @{ index = $Index; path = $target }
    Emit 'log'    @{ kind = 'ok'; text = "Saved: $target" }
    Write-Report $Report "Saved: $target"
}

# --- Path B: lossless assembly via PDFsharp --------------------------------
function Test-PdfLibrary {
    # Load the .NET PDF library once. Returns $false if it is missing or the
    # machine refuses it -- the caller then uses Path A.
    if ($script:PdfLibLoaded) { return $true }
    try {
        if (-not (Test-Path -LiteralPath $script:PdfLib)) { return $false }
        # Load from bytes, not LoadFrom: a downloaded DLL may carry mark-of-the-web,
        # which makes Assembly.LoadFrom refuse it. Bytes have no file zone.
        $bytes = [IO.File]::ReadAllBytes($script:PdfLib)
        [Reflection.Assembly]::Load($bytes) | Out-Null
        $null = [PdfSharp.Pdf.PdfDocument]   # fails if the assembly did not load
        $script:PdfLibLoaded = $true
        return $true
    } catch { return $false }
}

function Test-PageHasText([string]$Content, [int]$MinChars) {
    # Does this page carry a real text layer, or only a stamp?
    #
    # The old test was "any letter or digit anywhere on the page", and it lost
    # pages silently. A scan carrying a Bates number or a post-scan header
    # stamp extracts about ten characters, passed as born-digital, and was
    # never OCR'd -- the page shipped looking perfectly normal and searching it
    # found nothing. So count the characters instead of asking whether any
    # exist.
    #
    # \w is Unicode-aware in .NET (letters, marks and digits of any script), so
    # Arabic counts here. The old [A-Za-z0-9] never matched Arabic at all,
    # which rasterized and re-OCR'd every Arabic born-digital page.
    #
    # Being wrong low is safe and being wrong high is not: a real text page
    # judged scanned gets rasterized and OCR'd, which is exactly what a scan
    # gets anyway, while a scan judged born-digital loses its content for good.
    # So the threshold leans toward OCR. A sparse born-digital page -- a cover
    # sheet, a drawing with one caption -- falls below it and is OCR'd; that is
    # the intended trade, not a bug. Retune with -TextMinChars.
    if (-not $Content) { return $false }
    return (($Content -replace '\W', '').Length -ge $MinChars)
}

function Get-PagesWithText([string]$Pdf, [int]$First, [int]$Last, [string]$WorkDir) {
    # Which pages already carry a real text layer (born-digital) and need no OCR.
    # One Ghostscript txtwrite pass for the whole document; the old code launched
    # one per page. Test-PageHasText decides what counts as a text layer.
    # If the pass fails, every page is reported as needing OCR (the safe way to
    # be wrong).
    $count = $Last - $First + 1
    $flags = New-Object 'bool[]' $count
    $dir = Join-Path $WorkDir 'text'
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    try {
        # Watched, not just run: txtwrite drops one .txt per page as it goes, so
        # the folder is a live page counter for a pass that would otherwise be
        # one long silence at the very start of every document.
        $r = Invoke-EngineWatched $script:Ghostscript @(
            '-q', '-dNOPAUSE', '-dBATCH', '-dSAFER', '-sDEVICE=txtwrite',
            "-dFirstPage=$First", "-dLastPage=$Last",
            '-o', (Join-Path $dir 't%05d.txt'), $Pdf
        ) $dir 't*.txt' $count 'checking for existing text on' 0 $count 1
        $files = @(Get-ChildItem -LiteralPath $dir -Filter 't*.txt' -ErrorAction SilentlyContinue |
                   Sort-Object Name)
        if ($r.code -eq 0 -and $files.Count -eq $count) {
            for ($i = 0; $i -lt $count; $i++) {
                $content = Get-Content -LiteralPath $files[$i].FullName -Raw -ErrorAction SilentlyContinue
                $flags[$i] = [bool](Test-PageHasText $content $script:TextMinChars)
            }
        }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $flags
}

function Invoke-OneDocumentLossless {
    # Path B, in three phases. The phases exist to keep the PDF library out of
    # memory during the slow part: OCR can run for hours, assembly takes seconds,
    # so the documents are only opened once every page is already on disk.
    #
    #   1. ask Ghostscript, in ONE pass, which pages already carry text
    #   2. OCR the scanned pages to one-page PDFs on disk -- no PDF library yet
    #   3. open the original, assemble, save, close
    param(
        [int]$Index, [string]$Source, [int]$First, [int]$Last, [int]$PageCount,
        [string]$OutputDir, [string]$JobDir, [string]$Lang, [bool]$Rotate,
        [bool]$Redo, [int]$Dpi, $Report
    )
    $count = $Last - $First + 1
    $name = [IO.Path]::GetFileName($Source)
    Start-Document $Index $name $count
    Emit 'log'  @{ kind = 'head'; text = "$name - $count page(s)" }
    Write-Report $Report "`n===== $Source (lossless path, pages $First-$Last of $PageCount) ====="

    $pageDir = Join-Path $JobDir "docB$Index"
    [IO.Directory]::CreateDirectory($pageDir) | Out-Null

    # --- phase 1: which pages already have a text layer? --------------------
    Show-Stage 'checking for existing text on' 0 $count
    if ($Redo) {
        # "Redo" means treat every page as needing OCR, so the scan is skipped
        # entirely -- and its one unit per page has to be credited here, or the
        # bar would run a whole phase short for this document.
        $hasText = @(New-Object 'bool[]' $count)
        Update-Progress $count
    } else {
        $hasText = @(Get-PagesWithText $Source $First $Last $pageDir)
    }
    $need = New-Object Collections.Generic.List[int]
    for ($p = $First; $p -le $Last; $p++) { if (-not $hasText[$p - $First]) { [void]$need.Add($p) } }

    # A page that already has text skips the render, the orientation check and
    # recognition. That work genuinely never happens, so credit it now rather
    # than letting the bar crawl and then leap at the end.
    $skipped = $count - $need.Count
    if ($skipped -gt 0) {
        Update-Progress ($skipped * ($script:UnitsPerOcrPage))
        Step-Document $skipped
    }
    # Say the split out loud. Without it the stage line counts "of 20 pages"
    # while the file row counts "of 22" and there is nothing on screen
    # explaining where the other two went.
    Emit 'log' @{ kind = 'dim'; text = ("$name - $skipped of $count page(s) can already be searched, so " +
                                        "they are copied straight from the original; " +
                                        "$($need.Count) page(s) are scans and need OCR") }
    Write-Report $Report "   $skipped of $count page(s) already have text; $($need.Count) need OCR"
    if ($Rotate -and $Lang -ne 'ara' -and $need.Count -gt 0) {
        Emit 'log' @{ kind = 'dim'; text = "$name - each page is read as its rotation is checked, never twice" }
    }

    # --- phase 2: OCR the scanned pages, straight to disk -------------------
    # ponytail: one PDF per page, so phase 3 opens as many documents as there
    # are OCR'd pages. If that peak ever matters, hand Tesseract a list of
    # images per call so one PDF covers several pages instead of one.
    $ocrPdf = @{}
    $batch = 0
    $needPages = [int[]]@($need.ToArray())
    $needTotal = $needPages.Count
    for ($i = 0; $i -lt $needPages.Count; $i += $script:ChunkPages) {
        $slice = [int[]]@($needPages[$i..(Get-ChunkEnd $needPages.Count $i $script:ChunkPages)])
        $batch++
        $chunkDir = Join-Path $pageDir ("c{0:D5}" -f $batch)
        # Every count below is "of the pages this document still needs", not
        # "of this chunk", so the numbers keep rising across chunk boundaries.
        $pngs = @(Export-PageImages $Source $slice $chunkDir $Dpi $i $needTotal)

        $orientation = @()
        if ($Rotate) {
            $orientation = @(Set-BatchOrientation $pngs $slice $i $needTotal $Report $Lang $Dpi $chunkDir)
        }

        $calls = New-Object Collections.Generic.List[object]
        $callSlots = New-Object Collections.Generic.List[int]
        $cached = 0
        for ($k = 0; $k -lt $slice.Count; $k++) {
            if ($Rotate -and $k -lt $orientation.Count -and
                $orientation[$k].pdf -and (Test-Path -LiteralPath $orientation[$k].pdf)) {
                $ocrPdf[$slice[$k]] = [string]$orientation[$k].pdf
                $cached++
                Show-Stage 'recognising text on' ($i + $cached) $needTotal
                Update-Progress 1
                Step-Document 1
                # No log line: this page's text came from the reading that
                # proved its rotation, and that line already said so. A second
                # line per page saying the same thing every time is noise.
                continue
            }
            [void]$calls.Add(@{
                exe = $script:Tesseract
                engineArgs = @($pngs[$k], (Join-Path $chunkDir ("p{0:D5}" -f $slice[$k])),
                               '--dpi', "$Dpi", '-l', $Lang, 'pdf')
                label = "Page $($slice[$k]): text layer added"
            })
            [void]$callSlots.Add($k)
        }
        # The file row and the bar move as each page's own process exits, from
        # inside the runner -- not in this loop, which cannot run until every
        # process in the chunk has finished.
        $res = @()
        if ($calls.Count -gt 0) {
            $res = @(Invoke-EngineBatch $calls.ToArray() 'recognising text on' ($i + $cached) $needTotal 1 $true)
        }
        for ($slot = 0; $slot -lt $callSlots.Count; $slot++) {
            $k = $callSlots[$slot]
            $onePdf = (Join-Path $chunkDir ("p{0:D5}.pdf" -f $slice[$k]))
            if ($res[$slot].code -ne 0 -or -not (Test-Path -LiteralPath $onePdf)) {
                throw "Tesseract could not build page $($slice[$k]) ($($res[$slot].err.Trim()))"
            }
            $ocrPdf[$slice[$k]] = $onePdf
        }
        # The page images have done their job; only the one-page PDFs are needed
        # at assembly. Drop them so temp does not hold the document twice over.
        Get-ChildItem -LiteralPath $chunkDir -Filter '*.png' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # --- phase 3: assemble, now that every page is already on disk ----------
    Show-Stage 'assembling' 0 $count
    $staged = Join-Path $pageDir 'assembled.pdf'
    $reader = [PdfSharp.Pdf.IO.PdfReader]::Open($Source, [PdfSharp.Pdf.IO.PdfDocumentOpenMode]::Import)
    $output = New-Object PdfSharp.Pdf.PdfDocument
    $ocrDocs = New-Object Collections.Generic.List[object]
    try {
        for ($p = $First; $p -le $Last; $p++) {
            if ($ocrPdf.ContainsKey($p)) {
                $ocrDoc = [PdfSharp.Pdf.IO.PdfReader]::Open($ocrPdf[$p], [PdfSharp.Pdf.IO.PdfDocumentOpenMode]::Import)
                [void]$ocrDocs.Add($ocrDoc)
                [void]$output.AddPage($ocrDoc.Pages[0])
            } else {
                [void]$output.AddPage($reader.Pages[$p - 1])   # untouched, lossless
                Emit 'log' @{ kind = 'dim'; text = "Page ${p}: already searchable - copied from the original" }
                Write-Report $Report "   page ${p}: already searchable - copied from the original"
            }
            # Assembly is fast, but on a 350-page file it is still long enough
            # to look like a hang if it says nothing, so it counts too.
            Show-Stage 'assembling' ($p - $First + 1) $count
            Update-Progress 1
        }
        $output.Save($staged)
    } finally {
        foreach ($d in $ocrDocs) { try { $d.Close() } catch {} }
        try { $output.Close() } catch {}
        try { $reader.Close() } catch {}
    }

    $target = Get-NextTarget $OutputDir $Source (Get-RangeSuffix $First $Last $PageCount)
    Publish-Output $staged $target
    Emit 'file'   @{ index = $Index; state = 'done'; pages = $count; page = $count }
    Emit 'result' @{ index = $Index; path = $target }
    Emit 'log'    @{ kind = 'ok'; text = "Saved: $target" }
    Write-Report $Report "Saved: $target"
}

# --- the run ---------------------------------------------------------------
function Invoke-Run([hashtable]$Job) {
    # Which build is this? Written by package_pc.sh into the package; absent in
    # a working copy. First line of every run, before anything can go wrong,
    # because two rounds of "why is the log still saying X" turned out to be a
    # stale folder on the target PC that nothing on screen could distinguish.
    $script:BuildStamp = ''
    $stampFile = Join-Path $PSScriptRoot 'build.txt'
    if (Test-Path -LiteralPath $stampFile) {
        $script:BuildStamp = ((Get-Content -LiteralPath $stampFile -Raw -ErrorAction SilentlyContinue) + '').Trim()
        if ($script:BuildStamp) {
            Emit 'log' @{ kind = 'head'; text = "Build $script:BuildStamp" }
        }
    }

    $opts = $Job.options
    $outputDir = $Job.output_dir
    $jobDir    = $Job.job_dir
    $lang      = Resolve-Lang $opts.lang
    $rotate    = [bool]$opts.rotate
    $redo      = if ($opts.ContainsKey('redo')) { [bool]$opts.redo } else { $false }
    $dpi       = if ($opts.ContainsKey('dpi')) { [int]$opts.dpi } else { $Dpi }
    $mode      = if ($opts.ContainsKey('mode')) { [string]$opts.mode } else { $Mode }
    # These knobs may also come from job.json so the GUI can expose them later.
    # text_min is not a speed knob -- it decides which pages get OCR'd (D-023).
    if ($opts.ContainsKey('jobs'))   { $script:MaxParallel = [Math]::Max(1, [int]$opts.jobs) }
    if ($opts.ContainsKey('chunk'))  { $script:ChunkPages  = [Math]::Max(1, [int]$opts.chunk) }
    if ($opts.ContainsKey('text_min')) { $script:TextMinChars = [Math]::Max(1, [int]$opts.text_min) }
    if ($opts.ContainsKey('osd_crops')) { $script:OsdCrops = [Math]::Max(0, [Math]::Min(5, [int]$opts.osd_crops)) }
    if ($opts.ContainsKey('priority_words')) {
        $script:PriorityWordSet = @{}
        foreach ($word in @($opts.priority_words | Where-Object { $_ -and $_.Trim().Length -gt 0 })) {
            $clean = (Get-NormalizedText $word)
            if ($clean -and $clean -notmatch ' ') { $script:PriorityWordSet[$clean] = $true }
        }
    }

    if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        Emit 'fatal' @{ text = "Output folder does not exist: $outputDir" }; return 2
    }
    $sources = @($Job.inputs)
    if ($sources.Count -eq 0) { Emit 'fatal' @{ text = 'No PDF files were supplied.' }; return 2 }
    [IO.Directory]::CreateDirectory($jobDir) | Out-Null

    # Optional page ranges, one entry per input. Missing means the whole file.
    $ranges = @()
    if ($Job.ContainsKey('ranges') -and $Job.ranges) { $ranges = @($Job.ranges) }

    # validate + count
    $valid = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt $sources.Count; $i++) {
        $src = $sources[$i]
        if (-not (Test-Path -LiteralPath $src -PathType Leaf) -or [IO.Path]::GetExtension($src).ToLower() -ne '.pdf') {
            Emit 'file' @{ index = $i; state = 'failed'; pages = 0 }
            Emit 'log'  @{ kind = 'bad'; text = "Skipped missing or non-PDF file: $src" }
            continue
        }
        # Ghostscript has to open the file to answer this, which is a second or
        # two on a large PDF. Say which file, so the window is never blank.
        Emit 'stage' @{ text = "Opening $([IO.Path]::GetFileName($src))" }
        $pages = Get-PageCount $src
        $wantFirst = 0; $wantLast = 0
        if ($i -lt $ranges.Count -and $ranges[$i]) {
            $r = $ranges[$i]
            if ($r.ContainsKey('first')) { $wantFirst = [int]$r.first }
            if ($r.ContainsKey('last'))  { $wantLast  = [int]$r.last }
        }
        $range = Resolve-PageRange $pages $wantFirst $wantLast
        if (($wantFirst -gt 0 -or $wantLast -gt 0) -and
            ($range.first -ne $wantFirst -or ($wantLast -gt 0 -and $range.last -ne $wantLast))) {
            Emit 'log' @{ kind = 'dim'; text = ("$([IO.Path]::GetFileName($src)): requested pages " +
                "$wantFirst-$wantLast, document has $pages - using $($range.first)-$($range.last)") }
        }
        $valid.Add(@{ index = $i; source = $src; pages = $pages
                      first = $range.first; last = $range.last; count = $range.count })
        Emit 'file' @{ index = $i; state = 'queued'; pages = $range.count }
    }

    # Decide the path first, because it decides what a page costs. Path B
    # (lossless) needs the PDF library to load.
    $useB = $false
    if ($mode -ne 'A') {
        if (Test-PdfLibrary) { $useB = $true }
        elseif ($mode -eq 'B') {
            Emit 'log' @{ kind = 'bad'; text = 'PDF library did not load; using the rasterize path.' }
        }
    }

    # Weight the bar by the steps a page will really cost on the chosen path,
    # so it advances at one rate from start to finish instead of standing still
    # through a render and then leaping. See Update-Progress.
    $script:UnitsPerOcrPage = 2 + $(if ($rotate) { 1 } else { 0 })   # render + [orientation] + recognise
    $script:UnitsPerPage = if ($useB) { $script:UnitsPerOcrPage + 2 }  # + text scan + assemble
                           else       { $script:UnitsPerOcrPage }     # Path A: the build replaces recognise
    $sum = ($valid | ForEach-Object { $_.count * $script:UnitsPerPage } | Measure-Object -Sum).Sum
    $script:TotalUnits = [Math]::Max(1, [int]$sum)
    $script:Done = 0

    $report = $null
    if ($Job.ContainsKey('report_path') -and $Job.report_path) {
        $report = New-Object IO.StreamWriter($Job.report_path, $false, (New-Object Text.UTF8Encoding($false)))
        Write-Report $report "Document OCR native worker report (tesseract + ghostscript)"
        if ($script:BuildStamp) { Write-Report $report "Build $script:BuildStamp" }
        Write-Report $report "Output: $outputDir"
        Write-Report $report ("Options: lang=$lang rotate=$rotate dpi=$dpi")
        Write-Report $report ("Speed: jobs=$($script:MaxParallel) chunk=$($script:ChunkPages)")
        # Recorded because it is the answer to "why was this page not OCR'd?".
        Write-Report $report ("Text layer threshold: $($script:TextMinChars) character(s)")
    }
    Write-Report $report ("Path: {0}" -f $(if ($useB) { 'B (lossless)' } else { 'A (rasterize)' }))

    $succeeded = 0; $failed = 0
    try {
        foreach ($v in $valid) {
            try {
                if ($useB) {
                    try {
                        Invoke-OneDocumentLossless -Index $v.index -Source $v.source `
                            -First $v.first -Last $v.last -PageCount $v.pages `
                            -OutputDir $outputDir -JobDir $jobDir -Lang $lang -Rotate $rotate `
                            -Redo $redo -Dpi $dpi -Report $report
                    } catch {
                        # Any lossless-path failure falls back to the reliable rasterize path.
                        Emit 'log' @{ kind = 'dim'; text = "Lossless path failed ($($_.Exception.Message)); using rasterize fallback." }
                        Write-Report $report ("Lossless path failed: " + ($_ | Out-String))
                        Invoke-OneDocument -Index $v.index -Source $v.source `
                            -First $v.first -Last $v.last -PageCount $v.pages `
                            -OutputDir $outputDir -JobDir $jobDir -Lang $lang -Rotate $rotate -Dpi $dpi `
                            -Report $report
                    }
                } else {
                    Invoke-OneDocument -Index $v.index -Source $v.source `
                        -First $v.first -Last $v.last -PageCount $v.pages `
                        -OutputDir $outputDir -JobDir $jobDir -Lang $lang -Rotate $rotate -Dpi $dpi `
                        -Report $report
                }
                $succeeded++
            } catch {
                $failed++
                Emit 'file' @{ index = $v.index; state = 'failed'; pages = $v.count }
                Emit 'log'  @{ kind = 'bad'; text = "OCR failed: $($_.Exception.Message)" }
                Write-Report $report ($_ | Out-String)
            } finally {
                # Free this document's page images and one-page PDFs now. The old
                # code kept every file's temp data until the whole batch ended,
                # so six 350-page files piled up on the C: drive at once.
                foreach ($stale in @("doc$($v.index)", "docB$($v.index)")) {
                    $dir = Join-Path $jobDir $stale
                    if (Test-Path -LiteralPath $dir) {
                        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    } finally {
        if ($report) { $report.Close() }
    }

    $failed += ($sources.Count - $valid.Count)
    Emit 'progress' @{ value = 100 }
    Emit 'stage' @{ text = '' }
    Emit 'summary' @{ succeeded = $succeeded; failed = $failed }
    Remove-Item -LiteralPath $jobDir -Recurse -Force -ErrorAction SilentlyContinue
    return $(if ($failed -eq 0) { 0 } else { 1 })
}

# --- entry points ----------------------------------------------------------
function Convert-JsonToHashtable($Obj) {
    if ($Obj -is [Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($prop in $Obj.PSObject.Properties) { $h[$prop.Name] = Convert-JsonToHashtable $prop.Value }
        return $h
    } elseif ($Obj -is [Array]) {
        return @($Obj | ForEach-Object { Convert-JsonToHashtable $_ })
    }
    return $Obj
}

function Invoke-SelfTest {
    # Several checks below drive the real progress and stage helpers, which emit
    # JSON. With no events file that JSON goes to the console and buries the
    # ok/FAIL list, so send it nowhere for the duration.
    $script:EventWriter = New-Object IO.StreamWriter([IO.Stream]::Null)
    try { return (Invoke-SelfTestBody) }
    finally { $script:EventWriter.Dispose(); $script:EventWriter = $null }
}

function Invoke-SelfTestBody {
    $fail = 0
    function Check([string]$Name, [bool]$Ok) {
        if ($Ok) { Write-Host "  ok  - $Name" }
        else { Write-Host "  FAIL- $Name"; $script:selfFail++ }
    }
    $script:selfFail = 0

    Check 'lang map eng+ara' ((Resolve-Lang 'eng+ara') -eq 'eng+ara')
    Check 'lang map unknown -> eng' ((Resolve-Lang 'zzz') -eq 'eng')

    $osd = ConvertFrom-OsdOutput "Page number: 0`nRotate: 270`nOrientation confidence: 12.34`n"
    Check 'osd parse turn' ($osd.turn -eq 270)
    Check 'osd parse conf' ([Math]::Abs($osd.conf - 12.34) -lt 0.001)
    $none = ConvertFrom-OsdOutput "Too few characters"
    Check 'osd parse empty -> 0/0' ($none.turn -eq 0 -and $none.conf -eq 0.0)

    Check 'quote plain' ((ConvertTo-CmdArg 'abc') -eq 'abc')
    Check 'quote spaces' ((ConvertTo-CmdArg 'a b') -eq '"a b"')

    # Brackets in a file name. Everywhere else a path is an argument, where
    # brackets mean nothing; in the page-count program it is a PostScript
    # string, where they are syntax. This is the same bug class that killed the
    # launcher when its own folder was called "... (1)".
    Check 'postscript path uses forward slashes' (
        (ConvertTo-PostScriptPath 'C:\x\a.pdf') -eq 'C:/x/a.pdf')
    Check 'postscript path escapes balanced brackets' (
        (ConvertTo-PostScriptPath 'C:\Downloads (1)\a.pdf') -eq 'C:/Downloads \(1\)/a.pdf')
    Check 'postscript path escapes an unbalanced bracket' (
        (ConvertTo-PostScriptPath 'C:\x\scan (1.pdf') -eq 'C:/x/scan \(1.pdf')
    Check 'postscript path leaves no bare bracket behind' (
        (ConvertTo-PostScriptPath 'C:\Program Files (x86)\report).pdf') -notmatch '(?<!\\)[()]')

    $turn = ConvertTo-OrientationDecision @{ turn = 270; conf = 5.0 }
    Check 'decision turns' ($turn.turn -eq 270)
    $up = ConvertTo-OrientationDecision @{ turn = 0; conf = 5.0 }
    Check 'decision upright' ($up.turn -eq 0 -and $up.why -like 'already upright*')
    $unsure = ConvertTo-OrientationDecision @{ turn = 90; conf = 0.0 }
    Check 'decision no confidence -> left alone' ($unsure.turn -eq 0 -and $unsure.why -like 'too little*')

    # Page ranges: a bad request must be clamped, never rejected or obeyed blindly.
    $all = Resolve-PageRange 350 0 0
    Check 'range default is the whole document' ($all.first -eq 1 -and $all.last -eq 350 -and $all.count -eq 350)
    $mid = Resolve-PageRange 350 5 120
    Check 'range as asked' ($mid.first -eq 5 -and $mid.last -eq 120 -and $mid.count -eq 116)
    $over = Resolve-PageRange 100 5 900
    Check 'range clamped to the last page' ($over.first -eq 5 -and $over.last -eq 100)
    $under = Resolve-PageRange 100 -7 0
    Check 'range clamped to the first page' ($under.first -eq 1 -and $under.last -eq 100)
    $past = Resolve-PageRange 10 40 50
    Check 'range starting past the end lands on the last page' ($past.first -eq 10 -and $past.last -eq 10)
    $back = Resolve-PageRange 100 80 20
    Check 'reversed range does not go backwards' ($back.first -eq 80 -and $back.last -eq 80 -and $back.count -eq 1)
    $one = Resolve-PageRange 100 7 7
    Check 'single page range' ($one.count -eq 1)

    Check 'whole document needs no name suffix' ((Get-RangeSuffix 1 350 350) -eq '')
    Check 'part document is named for its pages' ((Get-RangeSuffix 5 120 350) -eq '_p5-120')
    Check 'single page is named for its page' ((Get-RangeSuffix 7 7 350) -eq '_p7')

    # "Already has text" is a threshold, not a yes/no. The old test passed a
    # page with one character on it, so a scan wearing a Bates number or a
    # header stamp was filed as born-digital and never OCR'd -- silently, and
    # the output looked fine.
    $prose  = 'x' * 300
    $bates  = 'SMITH-000123'
    $stamp  = 'SCANNED 12 MAR 2026 - RECORDS DEPT - COPY 2 OF 3'
    $arabic = ([string][char]0x0627) * 150   # 150 Arabic letters, written in ASCII
    $padded = $stamp + ('-' * 400)
    $exact  = 'x' * 100
    $short  = 'x' * 99
    Check 'a blank page needs OCR' (-not (Test-PageHasText '' 100))
    Check 'a null page needs OCR' (-not (Test-PageHasText $null 100))
    Check 'whitespace and punctuation are not text' (-not (Test-PageHasText " . - / `n`t " 100))
    Check 'a Bates number is not a text layer' (-not (Test-PageHasText $bates 100))
    Check 'a header stamp is not a text layer' (-not (Test-PageHasText $stamp 100))
    Check 'a real page of text is a text layer' (Test-PageHasText $prose 100)
    Check 'an Arabic page of text is a text layer' (Test-PageHasText $arabic 100)
    Check 'punctuation does not pad a stamp over the line' (-not (Test-PageHasText $padded 100))
    Check 'threshold is inclusive' (Test-PageHasText $exact 100)
    Check 'one character short needs OCR' (-not (Test-PageHasText $short 100))

    # Crop geometry. The trap is duplicates: on a small page every spot clamps
    # to the same rectangle, and five copies of one sample would look exactly
    # like five samples agreeing.
    $a4 = @(Get-CropRects 2480 3508 5)
    Check 'A4 gives five distinct sample windows' ($a4.Count -eq 5)
    Check 'sample windows are the configured size' ($a4[0].size -eq $script:OsdCropPx)
    Check 'sample windows stay inside the page' (
        -not ($a4 | Where-Object { $_.x -lt 0 -or $_.y -lt 0 -or
                                   ($_.x + $_.size) -gt 2480 -or ($_.y + $_.size) -gt 3508 }))
    Check 'no two windows share a corner' (
        (@($a4 | ForEach-Object { "$($_.x),$($_.y)" } | Sort-Object -Unique)).Count -eq 5)
    Check 'a page too small to space windows out gives one, not five' (
        (@(Get-CropRects 700 700 5)).Count -eq 1)
    Check 'a page exactly one window wide gives one' (
        (@(Get-CropRects 650 650 5)).Count -eq 1)
    Check 'a page too small to sample gives none' ((@(Get-CropRects 50 50 5)).Count -eq 0)
    Check 'zero crops requested gives none' ((@(Get-CropRects 2480 3508 0)).Count -eq 0)

    # The vote. A silent crop must not count as a vote for "upright" -- that is
    # why the vote reads raw OSD and not a decision.
    $pageSaysUpright = @{ turn = 0; why = 'already upright, confidence 3.00' }
    $pageSays180     = @{ turn = 180; why = 'confidence 3.00' }
    $pageSaysNothing = @{ turn = 0; why = 'too little text to tell which way up it is - left alone' }
    $silent = @(@{ turn = 0; conf = 0.0 }, @{ turn = 0; conf = 0.0 }, @{ turn = 0; conf = 0.0 })

    $agree = @(@{ turn = 90; conf = 4.0 }, @{ turn = 90; conf = 3.0 }, @{ turn = 0; conf = 0.0 })
    $v = Resolve-Orientation $agree $pageSaysNothing
    Check 'two agreeing samples rescue a page the whole page could not read' (
        $v.turn -eq 90 -and $v.why -like '*samples agree*')

    # The confidently-wrong case: the page is sure and wrong, the samples are not.
    $sayUpright = @(@{ turn = 0; conf = 4.0 }, @{ turn = 0; conf = 3.5 }, @{ turn = 0; conf = 2.0 })
    $v = Resolve-Orientation $sayUpright $pageSays180
    Check 'agreeing samples overrule a confident whole page' ($v.turn -eq 0)

    $split = @(@{ turn = 90; conf = 4.0 }, @{ turn = 180; conf = 3.0 }, @{ turn = 270; conf = 2.0 })
    $v = Resolve-Orientation $split $pageSays180
    Check 'samples that all disagree fall back to the whole page' ($v.turn -eq 180)
    Check 'a disagreement is said out loud' ($v.why -like '*disagree*')

    $tie = @(@{ turn = 90; conf = 4.0 }, @{ turn = 90; conf = 4.0 },
             @{ turn = 270; conf = 4.0 }, @{ turn = 270; conf = 4.0 })
    $v = Resolve-Orientation $tie $pageSaysUpright
    Check 'a tied vote does not pick a side' ($v.turn -eq 0 -and $v.why -like '*disagree*')

    $v = Resolve-Orientation $silent $pageSays180
    Check 'silent samples are not votes for upright' ($v.turn -eq 180 -and $v.why -eq $pageSays180.why)
    $v = Resolve-Orientation @(@{ turn = 90; conf = 4.0 }) $pageSaysNothing
    Check 'one lone sample is not a majority' ($v.turn -eq 0)
    $v = Resolve-Orientation @() $pageSays180
    Check 'no samples at all leaves the whole page answer untouched' (
        $v.turn -eq 180 -and $v.why -eq $pageSays180.why)

    # The verdict is what decides whether the expensive whole-page check runs
    # at all, so "decided" carries a cost, not just an answer.
    $d = Get-CropVerdict $agree
    Check 'an agreed verdict is decided' ($d.decided -and $d.turn -eq 90)
    $d = Get-CropVerdict $split
    Check 'a split verdict is undecided but counts its voters' (
        -not $d.decided -and $d.voters -eq 3)
    $d = Get-CropVerdict $tie
    Check 'a tied verdict is undecided' (-not $d.decided)
    $d = Get-CropVerdict $silent
    Check 'silent samples decide nothing and vote nothing' (
        -not $d.decided -and $d.voters -eq 0)
    $d = Get-CropVerdict @()
    Check 'no samples decides nothing' (-not $d.decided -and $d.voters -eq 0)

    # --- whole-page language evidence ----------------------------------
    Check 'normalise strips case and punctuation' (
        (Get-NormalizedText "  NORTHERN Utilities-Board!! ") -eq 'northern utilities board')
    Check 'normalise handles nothing' ((Get-NormalizedText $null) -eq '')
    $savedPriority = $script:PriorityWordSet
    $savedCommon = $script:CommonWordSet
    $script:PriorityWordSet = @{ northstar = $true }
    $script:CommonWordSet = @{ and = $true; of = $true; or = $true
                               shall = $true; invoice = $true; '2024' = $true }
    try {
        $v = Get-LanguageEvidence @(@{ word = 'northstar'; confidence = 90.0 })
        Check 'one configured exact word proves orientation' ($v.decided)
        Check 'a configured word outweighs any amount of common text' ($v.score -gt 900)
        $v = Get-LanguageEvidence @(@{ word = 'northstar'; confidence = 69.0 })
        Check 'a low-confidence configured word proves nothing' (
            -not $v.decided -and $v.score -eq 0)

        # One point per hit, three to pass. The three ways to get there must
        # all work, because "three hits" is the entire rule.
        $w = { param($t, $n) @(1..$n | ForEach-Object { @{ word = $t; confidence = 80.0 } }) }
        Check 'one word three times passes' (
            (Get-LanguageEvidence (& $w 'and' 3)).decided)
        Check 'three different words pass' (
            (Get-LanguageEvidence @(@{ word = 'and'; confidence = 80.0 },
                                    @{ word = 'of'; confidence = 80.0 },
                                    @{ word = 'invoice'; confidence = 80.0 })).decided)
        Check 'two of one word plus another passes' (
            (Get-LanguageEvidence @(@{ word = 'and'; confidence = 80.0 },
                                    @{ word = 'and'; confidence = 80.0 },
                                    @{ word = 'of'; confidence = 80.0 })).decided)
        Check 'a year is an ordinary word and counts' (
            (Get-LanguageEvidence (& $w '2024' 3)).decided)

        # Two hits is not three, and repeats are never capped.
        Check 'two hits do not pass' ((Get-LanguageEvidence (& $w 'and' 2)).decided -eq $false)
        Check 'two hits still score' ((Get-LanguageEvidence (& $w 'and' 2)).score -eq 2)
        Check 'repeats are not capped' ((Get-LanguageEvidence (& $w 'and' 40)).score -eq 40)
        Check 'a long word repeated counts every time' (
            (Get-LanguageEvidence (& $w 'invoice' 5)).score -eq 5)

        # Case is not allowed to matter anywhere: the page arrives lower-cased
        # from Get-NormalizedText, and the sets are built lower-cased.
        Check 'matching ignores case' (
            (Get-LanguageEvidence (& $w 'SHALL' 3)).decided -and
            (Get-LanguageEvidence @(@{ word = 'NorthStar'; confidence = 90.0 })).decided)

        Check 'gibberish proves nothing and scores nothing' (
            -not (Get-LanguageEvidence (& $w 'xqzz' 9)).decided)
        Check 'an empty page scores nothing' ((Get-LanguageEvidence @()).score -eq 0)

        # More language must always out-score less, or the comparison in
        # Get-OrientationBatch cannot tell an upright page from a rotated one.
        $upright = @(@{ word = 'and'; confidence = 80.0 }, @{ word = 'of'; confidence = 80.0 },
                     @{ word = 'invoice'; confidence = 80.0 }, @{ word = 'shall'; confidence = 80.0 })
        Check 'more language out-scores less' (
            (Get-LanguageEvidence $upright).score -gt (Get-LanguageEvidence (& $w 'and' 2)).score)
        Check 'one hit beats none' (
            (Get-LanguageEvidence (& $w 'and' 1)).score -gt
            (Get-LanguageEvidence (& $w 'xqzz' 9)).score)

        $leak = (Get-LanguageEvidence @(@{ word = 'northstar'; confidence = 90.0 })).why
        # Worded so it still holds if the sentence is ever reworded: the reason
        # may say the rule, never the word.
        Check 'the reason never repeats a matched word' ($leak -notmatch 'northstar')
        Check 'the reason names the rule that fired' ($leak -eq 'a word from your list')
        # Four hits, four points. Spelled out so a change to the scoring fails
        # here rather than silently shifting the bar.
        Check 'the reason carries the score' (
            (Get-LanguageEvidence $upright).why -eq '4 words matched')
    } finally {
        $script:PriorityWordSet = $savedPriority
        $script:CommonWordSet = $savedCommon
    }

    # The whole point of the split: a page whose windows agree must not pay for
    # the whole-page check. Count how many pages would still need it.
    $pages = @((Get-CropVerdict $agree), (Get-CropVerdict $split),
               (Get-CropVerdict $sayUpright), (Get-CropVerdict $silent))
    Check 'only the undecided pages need the whole-page check' (
        (@($pages | Where-Object { -not $_.decided })).Count -eq 2)

    Check 'batch end, full batch' ((Get-ChunkEnd 5 0 2) -eq 1)
    Check 'batch end, next batch' ((Get-ChunkEnd 5 2 2) -eq 3)
    Check 'batch end, short last batch' ((Get-ChunkEnd 5 4 2) -eq 4)
    Check 'batch end, one batch covers all' ((Get-ChunkEnd 3 0 25) -eq 2)
    # Batching must cover every page exactly once, in order -- the same loop
    # both document paths run.
    $pageProbe = [int[]]@(10..14)
    $seen = New-Object Collections.Generic.List[int]
    for ($b = 0; $b -lt $pageProbe.Count; $b += 2) {
        foreach ($n in [int[]]@($pageProbe[$b..(Get-ChunkEnd $pageProbe.Count $b 2)])) { $seen.Add($n) }
    }
    Check 'batching covers every page once, in order' ((($seen.ToArray()) -join ',') -eq '10,11,12,13,14')

    Check 'rotate 90'  ((Get-RotateFlip 90)  -eq [Drawing.RotateFlipType]::Rotate90FlipNone)
    Check 'rotate 180' ((Get-RotateFlip 180) -eq [Drawing.RotateFlipType]::Rotate180FlipNone)
    Check 'rotate 0'   ((Get-RotateFlip 0)   -eq [Drawing.RotateFlipType]::RotateNoneFlipNone)

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ocrtest_' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tmp) | Out-Null
    try {
        Check 'next target base' ((Split-Path (Get-NextTarget $tmp 'C:\x\sample.pdf') -Leaf) -eq 'sample_ocr.pdf')
        New-Item -ItemType File -Path (Join-Path $tmp 'sample_ocr.pdf') | Out-Null
        Check 'next target _2' ((Split-Path (Get-NextTarget $tmp 'C:\x\sample.pdf') -Leaf) -eq 'sample_ocr_2.pdf')
        Check 'next target with range suffix' (
            (Split-Path (Get-NextTarget $tmp 'C:\x\sample.pdf' '_p5-120') -Leaf) -eq 'sample_p5-120_ocr.pdf')
        $c = Join-Path $tmp 'c.tmp'; Set-Content $c 'hi'
        $t = Join-Path $tmp 'pub.pdf'; Publish-Output $c $t
        Check 'publish' ((Get-Content $t) -eq 'hi')
        $tsv = Join-Path $tmp 'words.tsv'
        Set-Content -LiteralPath $tsv -Encoding UTF8 -Value @(
            "level`tpage_num`tblock_num`tpar_num`tline_num`tword_num`tleft`ttop`twidth`theight`tconf`ttext",
            "5`t1`t1`t1`t1`t1`t10`t20`t30`t40`t91.5`tExample!",
            "4`t1`t1`t1`t1`t0`t0`t0`t0`t0`t-1`t",
            "5`t1`t1`t1`t1`t2`t50`t20`t30`t40`t42.0`tignored")
        $parsed = @(Get-TsvWords $tsv)
        Check 'TSV parser keeps word rows with confidence' (
            $parsed.Count -eq 2 -and $parsed[0].word -eq 'example' -and
            [Math]::Abs($parsed[0].confidence - 91.5) -lt 0.01)
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    Check 'tesseract present' (Test-Path -LiteralPath $script:Tesseract)
    Check 'ghostscript present' (Test-Path -LiteralPath $script:Ghostscript)

    # The progress counter must land on exactly 100% of its own total, or the
    # bar creeps or stalls. Replay a 25-page document the way Path B spends it:
    # 5 pages already carry text, 20 need OCR, orientation on.
    $savedTotal = $script:TotalUnits; $savedDone = $script:Done
    $savedOcr = $script:UnitsPerOcrPage; $savedPer = $script:UnitsPerPage
    $script:UnitsPerOcrPage = 3            # render + orientation + recognise
    $script:UnitsPerPage    = 5            # + text scan + assemble
    $script:TotalUnits = 25 * $script:UnitsPerPage
    $script:Done = 0
    Update-Progress 25                                     # phase 1: scan every page
    Update-Progress (5 * $script:UnitsPerOcrPage)          # 5 pages skip the OCR work
    for ($p = 0; $p -lt 20; $p++) { Update-Progress 3 }    # 20 pages rendered/turned/read
    Update-Progress 25                                     # phase 3: assemble every page
    Check 'progress lands exactly on its total' ($script:Done -eq $script:TotalUnits)
    $script:TotalUnits = $savedTotal; $script:Done = $savedDone
    $script:UnitsPerOcrPage = $savedOcr; $script:UnitsPerPage = $savedPer

    # The parallel process runner is the riskiest part: prove it really runs
    # every call, returns the results in order, and keeps the pool full.
    if (Test-Path -LiteralPath $script:Ghostscript) {
        # -h prints the banner and exits; -v can sit waiting on stdin.
        $probe = @(Invoke-EngineBatch @(
            @{ exe = $script:Ghostscript; engineArgs = @('-h') },
            @{ exe = $script:Ghostscript; engineArgs = @('-h') },
            @{ exe = $script:Ghostscript; engineArgs = @('-h') }
        ))
        Check 'parallel runner returns every result' ($probe.Count -eq 3)
        Check 'parallel runner captures output' (($probe | Where-Object { $_.out -match 'Ghostscript' }).Count -eq 3)
        # More calls than slots: the pool has to refill, which is where a
        # scheduler bug would hang or drop a result.
        $many = New-Object Collections.Generic.List[object]
        for ($p = 0; $p -lt ($script:MaxParallel * 2 + 1); $p++) {
            # Half of them carry a log label and half do not, so both branches
            # of the per-exit log line run. A call with no 'label' key must not
            # throw under Set-StrictMode 2.0, which is the whole risk here.
            if (($p % 2) -eq 0) {
                [void]$many.Add(@{ exe = $script:Ghostscript; engineArgs = @('-h')
                                   label = "Page ${p}: text layer added" })
            } else {
                [void]$many.Add(@{ exe = $script:Ghostscript; engineArgs = @('-h') })
            }
        }
        $refill = @(Invoke-EngineBatch $many.ToArray())
        Check 'pool refills past the first wave' (
            $refill.Count -eq $many.Count -and
            (($refill | Where-Object { $_.code -eq 0 }).Count -eq $many.Count))
        Check 'labelled and unlabelled calls both survive the runner' (
            $refill.Count -eq $many.Count)

        # And the watched runner: one process, one file per page, counted as
        # they land. Ghostscript renders its own bundled example to prove it.
        $watchDir = Join-Path ([IO.Path]::GetTempPath()) ('ocrwatch_' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($watchDir) | Out-Null
        try {
            $ps = Join-Path $watchDir 'three.ps'
            Set-Content -LiteralPath $ps -Encoding ASCII -Value @(
                'showpage', 'showpage', 'showpage')
            $w = Invoke-EngineWatched $script:Ghostscript @(
                '-q', '-dNOPAUSE', '-dBATCH', '-dSAFER', '-sDEVICE=png16m', '-r36',
                '-o', (Join-Path $watchDir 'p%05d.png'), $ps) `
                $watchDir 'p*.png' 3 'reading' 0 3 0
            $made = @(Get-ChildItem -LiteralPath $watchDir -Filter 'p*.png' -ErrorAction SilentlyContinue)
            Check 'watched runner produced a file per page' ($w.code -eq 0 -and $made.Count -eq 3)
        } finally { Remove-Item -LiteralPath $watchDir -Recurse -Force -ErrorAction SilentlyContinue }

        Write-Host "  info- $($script:MaxParallel) page(s) at a time, $($script:ChunkPages) page(s) per render"
    }
    # Path B is optional: report whether the PDF library loads, but never fail on it.
    if (Test-PdfLibrary) { Write-Host '  ok  - PDF library (Path B available)' }
    else { Write-Host '  info- PDF library not loaded (Path A fallback will be used)' }

    if ($script:selfFail -eq 0) { Write-Host 'native worker (Path A) selftest ok'; return 0 }
    Write-Host "native worker selftest FAILED ($script:selfFail)"; return 1
}

# --- dispatch --------------------------------------------------------------
switch ($PSCmdlet.ParameterSetName) {
    'Self' { exit (Invoke-SelfTest) }
    'One'  {
        if (-not $InputPdf -or -not $OutDir) { Write-Error 'Use -InputPdf <pdf> -OutDir <folder>'; exit 2 }
        $job = @{
            inputs = @($InputPdf); output_dir = $OutDir
            job_dir = (Join-Path ([IO.Path]::GetTempPath()) ('document_ocr_' + [Guid]::NewGuid().ToString('N')))
            report_path = $null
            ranges = @(@{ first = $FirstPage; last = $LastPage })
            options = @{ lang = $Lang; rotate = $true; redo = $false; dpi = $Dpi; mode = $Mode }
        }
        exit (Invoke-Run $job)
    }
    'Run'  {
        if (-not $Config -or -not $Events) { Write-Error 'Use -Config <job.json> -Events <events.jsonl>'; exit 2 }
        $script:EventWriter = New-Object IO.StreamWriter($Events, $true, (New-Object Text.UTF8Encoding($false)))
        try {
            $raw = Get-Content -LiteralPath $Config -Raw -Encoding UTF8
            $job = Convert-JsonToHashtable ($raw | ConvertFrom-Json)
            exit (Invoke-Run $job)
        } catch {
            Emit 'fatal' @{ text = "Unexpected worker error: $($_.Exception.Message)" }
            exit 2
        } finally {
            if ($script:EventWriter) { $script:EventWriter.Close() }
        }
    }
}
