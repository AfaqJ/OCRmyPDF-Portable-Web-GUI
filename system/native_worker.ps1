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
    [Parameter(ParameterSetName = 'Self')][switch]$SelfTest,
    [int]$Dpi = 300,
    # auto = lossless Path B when the PDF library loads, else Path A;
    # A = force rasterize path; B = force lossless path (still falls back per doc).
    [ValidateSet('auto', 'A', 'B')][string]$Mode = 'auto'
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
$script:Done = 0
$script:TotalUnits = 1
function Update-Progress {
    $script:Done++
    Emit 'progress' @{ value = [Math]::Min(99, [int]($script:Done * 100 / $script:TotalUnits)) }
}

# --- small helpers (pure -> unit tested) -----------------------------------
function Get-NextTarget([string]$Folder, [string]$SourcePath) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $candidate = Join-Path $Folder ($stem + '_ocr.pdf')
    $n = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $Folder ($stem + "_ocr_$n.pdf")
        $n++
    }
    return $candidate
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

function Invoke-Engine([string]$Exe, [string[]]$EngineArgs) {
    # Run a bundled exe, capture stdout+stderr, no visible window.
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($EngineArgs | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    # Read stdout async so a full stderr buffer can't deadlock the child.
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $out = $outTask.Result
    return @{ code = $p.ExitCode; out = $out; err = $err }
}

function Get-PageCount([string]$Pdf) {
    # Ghostscript page-count trick; falls back to 1 on any trouble.
    $prog = "($($Pdf.Replace('\','/'))) (r) file runpdfbegin pdfpagecount = quit"
    $r = Invoke-Engine $script:Ghostscript @('-q', '-dNODISPLAY', '-dNOSAFER', '-c', $prog)
    $m = [regex]::Match($r.out, '\d+')
    if ($m.Success) { return [Math]::Max(1, [int]$m.Value) }
    return 1
}

function Export-PageImage([string]$Pdf, [int]$Page, [string]$OutPng, [int]$Dpi) {
    $r = Invoke-Engine $script:Ghostscript @(
        '-q', '-dNOPAUSE', '-dBATCH', '-dSAFER',
        '-sDEVICE=png16m', "-r$Dpi",
        "-dFirstPage=$Page", "-dLastPage=$Page",
        "-o", $OutPng, $Pdf
    )
    if ($r.code -ne 0 -or -not (Test-Path -LiteralPath $OutPng)) {
        throw "Ghostscript could not render page $Page ($($r.err.Trim()))"
    }
}

function Get-Orientation([string]$Png) {
    # Tesseract OSD on the rendered page. Same decision rule as prerotate.py.
    $r = Invoke-Engine $script:Tesseract @($Png, 'stdout', '--psm', '0', '-l', 'osd')
    $osd = ConvertFrom-OsdOutput ($r.out + $r.err)
    if ($osd.turn -ne 0 -and $osd.conf -ge $script:OsdConfidenceFloor) {
        return @{ turn = $osd.turn; why = ("confidence {0:F2}" -f $osd.conf) }
    }
    if ($osd.conf -ge $script:OsdConfidenceFloor) {
        return @{ turn = 0; why = ("already upright, confidence {0:F2}" -f $osd.conf) }
    }
    return @{ turn = 0; why = 'too little text to tell which way up it is - left alone' }
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
function Invoke-OneDocument {
    param(
        [int]$Index, [string]$Source, [int]$Pages, [string]$OutputDir,
        [string]$JobDir, [string]$Lang, [bool]$Rotate, [int]$Dpi,
        $Report
    )
    Emit 'file' @{ index = $Index; state = 'running'; pages = $Pages; page = 0 }
    Emit 'log'  @{ kind = 'head'; text = "$([IO.Path]::GetFileName($Source)) - $Pages page(s)" }
    Write-Report $Report "`n===== $Source ====="

    $pageDir = Join-Path $JobDir "doc$Index"
    [IO.Directory]::CreateDirectory($pageDir) | Out-Null
    $images = New-Object Collections.Generic.List[string]

    for ($p = 1; $p -le $Pages; $p++) {
        $png = Join-Path $pageDir ("page{0:D4}.png" -f $p)
        Export-PageImage $Source $p $png $Dpi

        if ($Rotate) {
            Emit 'stage' @{ text = "$([IO.Path]::GetFileName($Source)) - checking page orientation" }
            $o = Get-Orientation $png
            if ($o.turn) {
                Set-ImageRotation $png $o.turn
                Emit 'log' @{ kind = 'turn'; text = "Page ${p}: turned $($o.turn) degrees clockwise - $($o.why)" }
                Write-Report $Report "   page ${p}: turned $($o.turn) deg clockwise ($($o.why))"
            } else {
                Emit 'log' @{ kind = 'dim'; text = "Page ${p}: $($o.why)" }
                Write-Report $Report "   page ${p}: left upright ($($o.why))"
            }
            Update-Progress
        }

        $images.Add($png)
        Emit 'file' @{ index = $Index; state = 'running'; pages = $Pages; page = $p }
        Emit 'stage' @{ text = "$([IO.Path]::GetFileName($Source)) - reading page $p of $Pages" }
        Update-Progress
    }

    Emit 'stage' @{ text = "$([IO.Path]::GetFileName($Source)) - building searchable PDF" }
    $ocr = Invoke-TesseractPdf $images.ToArray() (Join-Path $pageDir 'out') $Lang $Dpi

    $target = Get-NextTarget $OutputDir $Source
    Publish-Output $ocr $target
    Emit 'file'   @{ index = $Index; state = 'done'; pages = $Pages; page = $Pages }
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

function Test-PageHasText([string]$Pdf, [int]$Page, [string]$WorkDir) {
    # A page already carrying a real text layer (born-digital) needs no OCR.
    # Ghostscript's txtwrite extracts it; any letters/digits => it has text.
    $txt = Join-Path $WorkDir "text$Page.txt"
    $r = Invoke-Engine $script:Ghostscript @(
        '-q', '-dNOPAUSE', '-dBATCH', '-dSAFER', '-sDEVICE=txtwrite',
        "-dFirstPage=$Page", "-dLastPage=$Page", '-o', $txt, $Pdf
    )
    if ($r.code -ne 0 -or -not (Test-Path -LiteralPath $txt)) { return $false }
    $content = Get-Content -LiteralPath $txt -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $txt -Force -ErrorAction SilentlyContinue
    return ($content -and ($content -match '[A-Za-z0-9]'))
}

function Convert-SinglePageToPdf {
    # OCR one page to a one-page searchable PDF (render -> OSD rotate -> tesseract).
    param([string]$Source, [int]$Page, [string]$WorkDir, [string]$Lang, [bool]$Rotate, [int]$Dpi, $Report)
    $png = Join-Path $WorkDir ("page{0:D4}.png" -f $Page)
    Export-PageImage $Source $Page $png $Dpi
    if ($Rotate) {
        $o = Get-Orientation $png
        if ($o.turn) {
            Set-ImageRotation $png $o.turn
            Emit 'log' @{ kind = 'turn'; text = "Page ${Page}: turned $($o.turn) degrees clockwise - $($o.why)" }
            Write-Report $Report "   page ${Page}: turned $($o.turn) deg clockwise ($($o.why))"
        } else {
            Emit 'log' @{ kind = 'dim'; text = "Page ${Page}: $($o.why)" }
        }
    }
    return (Invoke-TesseractPdf @($png) (Join-Path $WorkDir "p$Page") $Lang $Dpi)
}

function Invoke-OneDocumentLossless {
    # Path B: keep pages that already have text untouched (lossless); OCR only
    # the scanned pages; assemble everything into one PDF with PDFsharp.
    param(
        [int]$Index, [string]$Source, [int]$Pages, [string]$OutputDir,
        [string]$JobDir, [string]$Lang, [bool]$Rotate, [bool]$Redo, [int]$Dpi, $Report
    )
    Emit 'file' @{ index = $Index; state = 'running'; pages = $Pages; page = 0 }
    Emit 'log'  @{ kind = 'head'; text = "$([IO.Path]::GetFileName($Source)) - $Pages page(s)" }
    Write-Report $Report "`n===== $Source (lossless path) ====="

    $pageDir = Join-Path $JobDir "docB$Index"
    [IO.Directory]::CreateDirectory($pageDir) | Out-Null
    $perPage = if ($Rotate) { 2 } else { 1 }

    $reader = [PdfSharp.Pdf.IO.PdfReader]::Open($Source, [PdfSharp.Pdf.IO.PdfDocumentOpenMode]::Import)
    $output = New-Object PdfSharp.Pdf.PdfDocument
    $ocrDocs = New-Object Collections.Generic.List[object]
    try {
        for ($p = 1; $p -le $Pages; $p++) {
            $hasText = (-not $Redo) -and (Test-PageHasText $Source $p $pageDir)
            if ($hasText) {
                [void]$output.AddPage($reader.Pages[$p - 1])   # untouched, lossless
                Emit 'log' @{ kind = 'dim'; text = "Page ${p}: already has text - kept unchanged" }
                Write-Report $Report "   page ${p}: already has text - kept unchanged"
            } else {
                Emit 'stage' @{ text = "$([IO.Path]::GetFileName($Source)) - reading page $p of $Pages" }
                $onePdf = Convert-SinglePageToPdf -Source $Source -Page $p -WorkDir $pageDir `
                    -Lang $Lang -Rotate $Rotate -Dpi $Dpi -Report $Report
                $ocrDoc = [PdfSharp.Pdf.IO.PdfReader]::Open($onePdf, [PdfSharp.Pdf.IO.PdfDocumentOpenMode]::Import)
                $ocrDocs.Add($ocrDoc)
                [void]$output.AddPage($ocrDoc.Pages[0])
            }
            Emit 'file' @{ index = $Index; state = 'running'; pages = $Pages; page = $p }
            for ($u = 0; $u -lt $perPage; $u++) { Update-Progress }
        }

        Emit 'stage' @{ text = "$([IO.Path]::GetFileName($Source)) - saving searchable PDF" }
        $staged = Join-Path $pageDir 'assembled.pdf'
        $output.Save($staged)
    } finally {
        foreach ($d in $ocrDocs) { try { $d.Close() } catch {} }
        try { $output.Close() } catch {}
        try { $reader.Close() } catch {}
    }

    $target = Get-NextTarget $OutputDir $Source
    Publish-Output $staged $target
    Emit 'file'   @{ index = $Index; state = 'done'; pages = $Pages; page = $Pages }
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

    if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        Emit 'fatal' @{ text = "Output folder does not exist: $outputDir" }; return 2
    }
    $sources = @($Job.inputs)
    if ($sources.Count -eq 0) { Emit 'fatal' @{ text = 'No PDF files were supplied.' }; return 2 }
    [IO.Directory]::CreateDirectory($jobDir) | Out-Null

    # validate + count
    $valid = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt $sources.Count; $i++) {
        $src = $sources[$i]
        if (-not (Test-Path -LiteralPath $src -PathType Leaf) -or [IO.Path]::GetExtension($src).ToLower() -ne '.pdf') {
            Emit 'file' @{ index = $i; state = 'failed'; pages = 0 }
            Emit 'log'  @{ kind = 'bad'; text = "Skipped missing or non-PDF file: $src" }
            continue
        }
        $pages = Get-PageCount $src
        $valid.Add(@{ index = $i; source = $src; pages = $pages })
        Emit 'file' @{ index = $i; state = 'queued'; pages = $pages }
    }

    $perPage = if ($rotate) { 2 } else { 1 }
    $sum = ($valid | ForEach-Object { $_.pages * $perPage } | Measure-Object -Sum).Sum
    $script:TotalUnits = [Math]::Max(1, [int]$sum)
    $script:Done = 0

    $report = $null
    if ($Job.ContainsKey('report_path') -and $Job.report_path) {
        $report = New-Object IO.StreamWriter($Job.report_path, $false, (New-Object Text.UTF8Encoding($false)))
        Write-Report $report "Document OCR native worker report (Path A: tesseract + ghostscript)"
        Write-Report $report "Output: $outputDir"
        Write-Report $report ("Options: lang=$lang rotate=$rotate dpi=$dpi")
    }

    # Decide the path. Path B (lossless) needs the PDF library to load.
    $useB = $false
    if ($mode -ne 'A') {
        if (Test-PdfLibrary) { $useB = $true }
        elseif ($mode -eq 'B') {
            Emit 'log' @{ kind = 'bad'; text = 'PDF library did not load; using the rasterize path.' }
        }
    }
    Write-Report $report ("Path: {0}" -f $(if ($useB) { 'B (lossless)' } else { 'A (rasterize)' }))

    $succeeded = 0; $failed = 0
    try {
        foreach ($v in $valid) {
            try {
                if ($useB) {
                    try {
                        Invoke-OneDocumentLossless -Index $v.index -Source $v.source -Pages $v.pages `
                            -OutputDir $outputDir -JobDir $jobDir -Lang $lang -Rotate $rotate `
                            -Redo $redo -Dpi $dpi -Report $report
                    } catch {
                        # Any lossless-path failure falls back to the reliable rasterize path.
                        Emit 'log' @{ kind = 'dim'; text = "Lossless path failed ($($_.Exception.Message)); using rasterize fallback." }
                        Write-Report $report ("Lossless path failed: " + ($_ | Out-String))
                        Invoke-OneDocument -Index $v.index -Source $v.source -Pages $v.pages `
                            -OutputDir $outputDir -JobDir $jobDir -Lang $lang -Rotate $rotate -Dpi $dpi `
                            -Report $report
                    }
                } else {
                    Invoke-OneDocument -Index $v.index -Source $v.source -Pages $v.pages `
                        -OutputDir $outputDir -JobDir $jobDir -Lang $lang -Rotate $rotate -Dpi $dpi `
                        -Report $report
                }
                $succeeded++
            } catch {
                $failed++
                Emit 'file' @{ index = $v.index; state = 'failed'; pages = $v.pages }
                Emit 'log'  @{ kind = 'bad'; text = "OCR failed: $($_.Exception.Message)" }
                Write-Report $report ($_ | Out-String)
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

    Check 'rotate 90'  ((Get-RotateFlip 90)  -eq [Drawing.RotateFlipType]::Rotate90FlipNone)
    Check 'rotate 180' ((Get-RotateFlip 180) -eq [Drawing.RotateFlipType]::Rotate180FlipNone)
    Check 'rotate 0'   ((Get-RotateFlip 0)   -eq [Drawing.RotateFlipType]::RotateNoneFlipNone)

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ocrtest_' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tmp) | Out-Null
    try {
        Check 'next target base' ((Split-Path (Get-NextTarget $tmp 'C:\x\sample.pdf') -Leaf) -eq 'sample_ocr.pdf')
        New-Item -ItemType File -Path (Join-Path $tmp 'sample_ocr.pdf') | Out-Null
        Check 'next target _2' ((Split-Path (Get-NextTarget $tmp 'C:\x\sample.pdf') -Leaf) -eq 'sample_ocr_2.pdf')
        $c = Join-Path $tmp 'c.tmp'; Set-Content $c 'hi'
        $t = Join-Path $tmp 'pub.pdf'; Publish-Output $c $t
        Check 'publish' ((Get-Content $t) -eq 'hi')
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    Check 'tesseract present' (Test-Path -LiteralPath $script:Tesseract)
    Check 'ghostscript present' (Test-Path -LiteralPath $script:Ghostscript)
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
            options = @{ lang = $Lang; rotate = $true; redo = $false; verbose = $false; dpi = $Dpi; mode = $Mode }
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
