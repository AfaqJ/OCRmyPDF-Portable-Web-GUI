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
  page to an image, corrects orientation with Tesseract's own detector (the same
  algorithm prerotate.py used), and lets Tesseract emit a searchable PDF with an
  invisible text layer. For scanned documents the result is visually identical
  to OCRmyPDF's output at the same resolution. Path B (a lossless text overlay
  onto the original page, via a .NET PDF library) layers on top of this later
  and falls back to this path if the library is unavailable.

  Where the time goes
  -------------------
  Every page costs one Ghostscript render, one Tesseract orientation check and
  one Tesseract OCR pass. That work is irreducible. What was reducible was the
  overhead wrapped around it:
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
      the count jump 4, 8, 12.
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
    [int]$ChunkPages = 10
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
    # @{ exe = <path>; engineArgs = @(...) }.
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
    if ($Osd.turn -ne 0 -and $Osd.conf -ge $script:OsdConfidenceFloor) {
        return @{ turn = $Osd.turn; why = ("confidence {0:F2}" -f $Osd.conf) }
    }
    if ($Osd.conf -ge $script:OsdConfidenceFloor) {
        return @{ turn = 0; why = ("already upright, confidence {0:F2}" -f $Osd.conf) }
    }
    return @{ turn = 0; why = 'too little text to tell which way up it is - left alone' }
}

function Get-OrientationBatch([string[]]$Pngs, [int]$Offset = 0, [int]$Total = 0) {
    # The same `--psm 0` check as before, on the same full-resolution image --
    # several tesseract processes at a time instead of one after another.
    if ($Pngs.Count -eq 0) { return @() }
    $calls = New-Object Collections.Generic.List[object]
    foreach ($png in $Pngs) {
        [void]$calls.Add(@{ exe = $script:Tesseract; engineArgs = @($png, 'stdout', '--psm', '0', '-l', 'osd') })
    }
    $res = @(Invoke-EngineBatch $calls.ToArray() 'checking orientation of' $Offset `
                ($(if ($Total) { $Total } else { $Pngs.Count })) 1 $false)
    $out = New-Object 'object[]' $Pngs.Count
    for ($i = 0; $i -lt $Pngs.Count; $i++) {
        $out[$i] = ConvertTo-OrientationDecision (ConvertFrom-OsdOutput ($res[$i].out + $res[$i].err))
    }
    return $out
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
        Emit 'log' @{ kind = 'turn'; text = "Page ${PageNo}: turned $($Decision.turn) degrees clockwise - $($Decision.why)" }
        Write-Report $Report "   page ${PageNo}: turned $($Decision.turn) deg clockwise ($($Decision.why))"
    } else {
        Emit 'log' @{ kind = 'dim'; text = "Page ${PageNo}: $($Decision.why)" }
        Write-Report $Report "   page ${PageNo}: left upright ($($Decision.why))"
    }
}

function Set-BatchOrientation([string[]]$Pngs, [int[]]$PageNumbers, [int]$Offset, [int]$Total, $Report) {
    # Check orientation a wave at a time, where a wave is the number of pages
    # actually running at once, and write each wave's LOG lines as soon as it
    # lands. Handing the whole chunk over in one call produced no log lines
    # until every page in the chunk had been checked, which looks frozen.
    #
    # The stage line and the progress bar do not wait for the wave: they are
    # updated by Invoke-EngineBatch as each individual process exits. The wave
    # is only the granularity of the "Page 7: turned 90 degrees" log lines,
    # because a rotation cannot be reported before its own process has answered.
    for ($w = 0; $w -lt $Pngs.Count; $w += $script:MaxParallel) {
        $end = [Math]::Min($Pngs.Count, $w + $script:MaxParallel) - 1
        $wave = @($Pngs[$w..$end])
        $turns = @(Get-OrientationBatch $wave ($Offset + $w) $Total)
        for ($k = 0; $k -lt $wave.Count; $k++) {
            Set-PageOrientation $wave[$k] $PageNumbers[$w + $k] $turns[$k] $Report
        }
    }
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

        if ($Rotate) { Set-BatchOrientation $pngs $slice $i $count $Report }

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

function Get-PagesWithText([string]$Pdf, [int]$First, [int]$Last, [string]$WorkDir) {
    # Which pages already carry a real text layer (born-digital) and need no OCR.
    # One Ghostscript txtwrite pass for the whole document; the old code launched
    # one per page. Any page whose extracted text has letters or digits has text.
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
                $flags[$i] = [bool]($content -and ($content -match '[A-Za-z0-9]'))
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
    Emit 'log' @{ kind = 'dim'; text = ("$name - $skipped of $count page(s) already have text and are kept " +
                                        "unchanged; $($need.Count) page(s) need OCR") }
    Write-Report $Report "   $skipped of $count page(s) already have text; $($need.Count) need OCR"

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

        if ($Rotate) { Set-BatchOrientation $pngs $slice $i $needTotal $Report }

        $calls = New-Object Collections.Generic.List[object]
        for ($k = 0; $k -lt $slice.Count; $k++) {
            [void]$calls.Add(@{
                exe = $script:Tesseract
                engineArgs = @($pngs[$k], (Join-Path $chunkDir ("p{0:D5}" -f $slice[$k])),
                               '--dpi', "$Dpi", '-l', $Lang, 'pdf')
            })
        }
        # The file row and the bar move as each page's own process exits, from
        # inside the runner -- not in this loop, which cannot run until every
        # process in the chunk has finished.
        $res = @(Invoke-EngineBatch $calls.ToArray() 'recognising text on' $i $needTotal 1 $true)
        for ($k = 0; $k -lt $slice.Count; $k++) {
            $onePdf = (Join-Path $chunkDir ("p{0:D5}.pdf" -f $slice[$k]))
            if ($res[$k].code -ne 0 -or -not (Test-Path -LiteralPath $onePdf)) {
                throw "Tesseract could not build page $($slice[$k]) ($($res[$k].err.Trim()))"
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
                Emit 'log' @{ kind = 'dim'; text = "Page ${p}: already has text - kept unchanged" }
                Write-Report $Report "   page ${p}: already has text - kept unchanged"
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
    $opts = $Job.options
    $outputDir = $Job.output_dir
    $jobDir    = $Job.job_dir
    $lang      = Resolve-Lang $opts.lang
    $rotate    = [bool]$opts.rotate
    $redo      = if ($opts.ContainsKey('redo')) { [bool]$opts.redo } else { $false }
    $dpi       = if ($opts.ContainsKey('dpi')) { [int]$opts.dpi } else { $Dpi }
    $mode      = if ($opts.ContainsKey('mode')) { [string]$opts.mode } else { $Mode }
    # Speed knobs may also come from job.json so the GUI can expose them later.
    if ($opts.ContainsKey('jobs'))   { $script:MaxParallel = [Math]::Max(1, [int]$opts.jobs) }
    if ($opts.ContainsKey('chunk'))  { $script:ChunkPages  = [Math]::Max(1, [int]$opts.chunk) }

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
        Write-Report $report "Output: $outputDir"
        Write-Report $report ("Options: lang=$lang rotate=$rotate dpi=$dpi")
        Write-Report $report ("Speed: jobs=$($script:MaxParallel) chunk=$($script:ChunkPages)")
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
            [void]$many.Add(@{ exe = $script:Ghostscript; engineArgs = @('-h') })
        }
        $refill = @(Invoke-EngineBatch $many.ToArray())
        Check 'pool refills past the first wave' (
            $refill.Count -eq $many.Count -and
            (($refill | Where-Object { $_.code -eq 0 }).Count -eq $many.Count))

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
