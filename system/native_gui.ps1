param([switch]$SelfTest)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root = Split-Path -Parent $PSScriptRoot
$App = Join-Path $Root 'app'
$Python = Join-Path $App 'python.exe'
$Worker = Join-Path $PSScriptRoot 'native_worker.py'
$OcrEntry = Join-Path $PSScriptRoot 'socketless_ocr.py'
$Strings = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'native_strings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$RunReport = Join-Path $Root 'OCR native run report.txt'

if ($SelfTest) {
    foreach ($required in @($Python, $Worker, $OcrEntry, (Join-Path $PSScriptRoot 'native_strings.json'))) {
        if (-not [IO.File]::Exists($required)) { throw "Missing required file: $required" }
    }
    if ($null -eq $Strings.en -or $null -eq $Strings.ar) {
        throw 'The interface language file is incomplete.'
    }
    Write-Output 'native GUI selftest ok - WinForms and language resources loaded'
    exit 0
}

$script:InputPaths = New-Object 'System.Collections.Generic.List[string]'
$script:Results = New-Object 'System.Collections.Generic.List[string]'
$script:Running = $false
$script:Cancelled = $false
$script:SummarySeen = $false
$script:Process = $null
$script:JobDir = $null
$script:EventReader = $null
$script:InterfaceLanguage = 'en'

$Font = New-Object System.Drawing.Font('Segoe UI', 9)
$MonoFont = New-Object System.Drawing.Font('Consolas', 9)
$TitleFont = New-Object System.Drawing.Font('Segoe UI Semibold', 22)
$SubtitleFont = New-Object System.Drawing.Font('Segoe UI', 10)

$Form = New-Object System.Windows.Forms.Form
$Form.Text = 'Document OCR'
$Form.ClientSize = New-Object System.Drawing.Size(1120, 720)
$Form.MinimumSize = New-Object System.Drawing.Size(980, 650)
$Form.StartPosition = 'CenterScreen'
$Form.BackColor = [System.Drawing.Color]::FromArgb(239, 242, 245)
$Form.Font = $Font
$Form.AllowDrop = $true

$Header = New-Object System.Windows.Forms.Label
$Header.Location = New-Object System.Drawing.Point(24, 18)
$Header.Size = New-Object System.Drawing.Size(620, 42)
$Header.Font = $TitleFont
$Header.ForeColor = [System.Drawing.Color]::FromArgb(21, 32, 43)
$Form.Controls.Add($Header)

$Subtitle = New-Object System.Windows.Forms.Label
$Subtitle.Location = New-Object System.Drawing.Point(28, 59)
$Subtitle.Size = New-Object System.Drawing.Size(620, 24)
$Subtitle.Font = $SubtitleFont
$Subtitle.ForeColor = [System.Drawing.Color]::FromArgb(91, 107, 123)
$Form.Controls.Add($Subtitle)

$InterfaceLabel = New-Object System.Windows.Forms.Label
$InterfaceLabel.Location = New-Object System.Drawing.Point(870, 23)
$InterfaceLabel.Size = New-Object System.Drawing.Size(90, 24)
$InterfaceLabel.Anchor = 'Top,Right'
$Form.Controls.Add($InterfaceLabel)

$InterfaceChoice = New-Object System.Windows.Forms.ComboBox
$InterfaceChoice.Location = New-Object System.Drawing.Point(960, 19)
$InterfaceChoice.Size = New-Object System.Drawing.Size(132, 28)
$InterfaceChoice.Anchor = 'Top,Right'
$InterfaceChoice.DropDownStyle = 'DropDownList'
[void]$InterfaceChoice.Items.Add('English')
[void]$InterfaceChoice.Items.Add('العربية')
$InterfaceChoice.SelectedIndex = 0
$Form.Controls.Add($InterfaceChoice)

$DocumentsGroup = New-Object System.Windows.Forms.GroupBox
$DocumentsGroup.Location = New-Object System.Drawing.Point(24, 94)
$DocumentsGroup.Size = New-Object System.Drawing.Size(530, 294)
$DocumentsGroup.Anchor = 'Top,Bottom,Left'
$DocumentsGroup.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($DocumentsGroup)

$DropHint = New-Object System.Windows.Forms.Label
$DropHint.Location = New-Object System.Drawing.Point(16, 25)
$DropHint.Size = New-Object System.Drawing.Size(490, 24)
$DropHint.ForeColor = [System.Drawing.Color]::FromArgb(91, 107, 123)
$DocumentsGroup.Controls.Add($DropHint)

$FileList = New-Object System.Windows.Forms.ListView
$FileList.Location = New-Object System.Drawing.Point(16, 54)
$FileList.Size = New-Object System.Drawing.Size(498, 182)
$FileList.Anchor = 'Top,Bottom,Left,Right'
$FileList.View = 'Details'
$FileList.FullRowSelect = $true
$FileList.MultiSelect = $true
$FileList.HideSelection = $false
$FileList.AllowDrop = $true
[void]$FileList.Columns.Add('File', 184)
[void]$FileList.Columns.Add('Folder', 222)
[void]$FileList.Columns.Add('Status', 86)
$DocumentsGroup.Controls.Add($FileList)

$AddButton = New-Object System.Windows.Forms.Button
$AddButton.Location = New-Object System.Drawing.Point(16, 248)
$AddButton.Size = New-Object System.Drawing.Size(110, 30)
$AddButton.Anchor = 'Bottom,Left'
$DocumentsGroup.Controls.Add($AddButton)

$RemoveButton = New-Object System.Windows.Forms.Button
$RemoveButton.Location = New-Object System.Drawing.Point(134, 248)
$RemoveButton.Size = New-Object System.Drawing.Size(140, 30)
$RemoveButton.Anchor = 'Bottom,Left'
$DocumentsGroup.Controls.Add($RemoveButton)

$ClearButton = New-Object System.Windows.Forms.Button
$ClearButton.Location = New-Object System.Drawing.Point(282, 248)
$ClearButton.Size = New-Object System.Drawing.Size(90, 30)
$ClearButton.Anchor = 'Bottom,Left'
$DocumentsGroup.Controls.Add($ClearButton)

$SettingsGroup = New-Object System.Windows.Forms.GroupBox
$SettingsGroup.Location = New-Object System.Drawing.Point(24, 400)
$SettingsGroup.Size = New-Object System.Drawing.Size(530, 170)
$SettingsGroup.Anchor = 'Bottom,Left'
$SettingsGroup.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($SettingsGroup)

$LanguageLabel = New-Object System.Windows.Forms.Label
$LanguageLabel.Location = New-Object System.Drawing.Point(16, 28)
$LanguageLabel.Size = New-Object System.Drawing.Size(160, 24)
$SettingsGroup.Controls.Add($LanguageLabel)

$LanguageChoice = New-Object System.Windows.Forms.ComboBox
$LanguageChoice.Location = New-Object System.Drawing.Point(180, 24)
$LanguageChoice.Size = New-Object System.Drawing.Size(220, 28)
$LanguageChoice.DropDownStyle = 'DropDownList'
[void]$LanguageChoice.Items.Add('English')
[void]$LanguageChoice.Items.Add('English + Arabic')
[void]$LanguageChoice.Items.Add('Arabic')
$LanguageChoice.SelectedIndex = 0
$SettingsGroup.Controls.Add($LanguageChoice)

$RotateCheck = New-Object System.Windows.Forms.CheckBox
$RotateCheck.Location = New-Object System.Drawing.Point(16, 62)
$RotateCheck.Size = New-Object System.Drawing.Size(480, 25)
$RotateCheck.Checked = $true
$SettingsGroup.Controls.Add($RotateCheck)

$RedoCheck = New-Object System.Windows.Forms.CheckBox
$RedoCheck.Location = New-Object System.Drawing.Point(16, 89)
$RedoCheck.Size = New-Object System.Drawing.Size(480, 25)
$SettingsGroup.Controls.Add($RedoCheck)

$VerboseCheck = New-Object System.Windows.Forms.CheckBox
$VerboseCheck.Location = New-Object System.Drawing.Point(16, 116)
$VerboseCheck.Size = New-Object System.Drawing.Size(480, 25)
$SettingsGroup.Controls.Add($VerboseCheck)

$ArabicWarning = New-Object System.Windows.Forms.Label
$ArabicWarning.Location = New-Object System.Drawing.Point(16, 142)
$ArabicWarning.Size = New-Object System.Drawing.Size(500, 22)
$ArabicWarning.ForeColor = [System.Drawing.Color]::FromArgb(166, 94, 0)
$ArabicWarning.Visible = $false
$SettingsGroup.Controls.Add($ArabicWarning)

$OutputGroup = New-Object System.Windows.Forms.GroupBox
$OutputGroup.Location = New-Object System.Drawing.Point(24, 582)
$OutputGroup.Size = New-Object System.Drawing.Size(530, 78)
$OutputGroup.Anchor = 'Bottom,Left'
$OutputGroup.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($OutputGroup)

$OutputText = New-Object System.Windows.Forms.TextBox
$OutputText.Location = New-Object System.Drawing.Point(16, 31)
$OutputText.Size = New-Object System.Drawing.Size(392, 27)
$OutputText.ReadOnly = $true
$OutputGroup.Controls.Add($OutputText)

$BrowseButton = New-Object System.Windows.Forms.Button
$BrowseButton.Location = New-Object System.Drawing.Point(416, 28)
$BrowseButton.Size = New-Object System.Drawing.Size(98, 30)
$OutputGroup.Controls.Add($BrowseButton)

$ActivityGroup = New-Object System.Windows.Forms.GroupBox
$ActivityGroup.Location = New-Object System.Drawing.Point(568, 94)
$ActivityGroup.Size = New-Object System.Drawing.Size(528, 566)
$ActivityGroup.Anchor = 'Top,Bottom,Left,Right'
$ActivityGroup.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($ActivityGroup)

$StageLabel = New-Object System.Windows.Forms.Label
$StageLabel.Location = New-Object System.Drawing.Point(16, 28)
$StageLabel.Size = New-Object System.Drawing.Size(496, 24)
$StageLabel.Anchor = 'Top,Left,Right'
$StageLabel.ForeColor = [System.Drawing.Color]::FromArgb(21, 32, 43)
$ActivityGroup.Controls.Add($StageLabel)

$Progress = New-Object System.Windows.Forms.ProgressBar
$Progress.Location = New-Object System.Drawing.Point(16, 56)
$Progress.Size = New-Object System.Drawing.Size(496, 18)
$Progress.Anchor = 'Top,Left,Right'
$Progress.Minimum = 0
$Progress.Maximum = 100
$ActivityGroup.Controls.Add($Progress)

$LogBox = New-Object System.Windows.Forms.RichTextBox
$LogBox.Location = New-Object System.Drawing.Point(16, 86)
$LogBox.Size = New-Object System.Drawing.Size(496, 414)
$LogBox.Anchor = 'Top,Bottom,Left,Right'
$LogBox.ReadOnly = $true
$LogBox.BackColor = [System.Drawing.Color]::FromArgb(21, 32, 43)
$LogBox.ForeColor = [System.Drawing.Color]::White
$LogBox.Font = $MonoFont
$LogBox.WordWrap = $false
$ActivityGroup.Controls.Add($LogBox)

$StartButton = New-Object System.Windows.Forms.Button
$StartButton.Location = New-Object System.Drawing.Point(16, 516)
$StartButton.Size = New-Object System.Drawing.Size(130, 34)
$StartButton.Anchor = 'Bottom,Left'
$StartButton.BackColor = [System.Drawing.Color]::FromArgb(26, 115, 232)
$StartButton.ForeColor = [System.Drawing.Color]::White
$StartButton.FlatStyle = 'Flat'
$ActivityGroup.Controls.Add($StartButton)

$CancelButton = New-Object System.Windows.Forms.Button
$CancelButton.Location = New-Object System.Drawing.Point(154, 516)
$CancelButton.Size = New-Object System.Drawing.Size(100, 34)
$CancelButton.Anchor = 'Bottom,Left'
$CancelButton.Enabled = $false
$ActivityGroup.Controls.Add($CancelButton)

$OpenOutputButton = New-Object System.Windows.Forms.Button
$OpenOutputButton.Location = New-Object System.Drawing.Point(352, 516)
$OpenOutputButton.Size = New-Object System.Drawing.Size(160, 34)
$OpenOutputButton.Anchor = 'Bottom,Right'
$OpenOutputButton.Enabled = $false
$ActivityGroup.Controls.Add($OpenOutputButton)

function Get-TextSet {
    if ($script:InterfaceLanguage -eq 'ar') { return $Strings.ar }
    return $Strings.en
}

function Apply-Language {
    $text = Get-TextSet
    $Form.Text = $text.title
    $Header.Text = $text.title
    $Subtitle.Text = $text.subtitle
    $InterfaceLabel.Text = $text.interface
    $DocumentsGroup.Text = $text.documents
    $DropHint.Text = $text.drop
    $AddButton.Text = $text.add
    $RemoveButton.Text = $text.remove
    $ClearButton.Text = $text.clear
    $SettingsGroup.Text = $text.settings
    $LanguageLabel.Text = $text.language
    $RotateCheck.Text = $text.rotate
    $RedoCheck.Text = $text.redo
    $VerboseCheck.Text = $text.verbose
    $ArabicWarning.Text = $text.arabic_warning
    $OutputGroup.Text = $text.output
    $BrowseButton.Text = $text.browse
    $ActivityGroup.Text = $text.activity
    $StartButton.Text = $text.start
    $CancelButton.Text = $text.cancel
    $OpenOutputButton.Text = $text.open_output
    if (-not $script:Running -and [string]::IsNullOrWhiteSpace($StageLabel.Text)) {
        $StageLabel.Text = $text.ready
    }
    $FileList.Columns[0].Text = $text.file
    $FileList.Columns[1].Text = $text.folder
    $FileList.Columns[2].Text = $text.status
    $rtl = $script:InterfaceLanguage -eq 'ar'
    $Form.RightToLeft = if ($rtl) { 'Yes' } else { 'No' }
    $Form.RightToLeftLayout = $rtl
}

function Append-Log([string]$Text, [string]$Kind = 'plain') {
    $colour = switch ($Kind) {
        'bad' { [System.Drawing.Color]::FromArgb(255, 113, 113) }
        'ok' { [System.Drawing.Color]::FromArgb(91, 214, 132) }
        'done' { [System.Drawing.Color]::FromArgb(91, 214, 132) }
        'turn' { [System.Drawing.Color]::FromArgb(75, 205, 230) }
        'tech' { [System.Drawing.Color]::FromArgb(145, 161, 177) }
        'dim' { [System.Drawing.Color]::FromArgb(145, 161, 177) }
        default { [System.Drawing.Color]::White }
    }
    $LogBox.SelectionStart = $LogBox.TextLength
    $LogBox.SelectionLength = 0
    $LogBox.SelectionColor = $colour
    $LogBox.AppendText($Text + [Environment]::NewLine)
    $LogBox.SelectionColor = $LogBox.ForeColor
    $LogBox.ScrollToCaret()
}

function Refresh-Controls {
    $hasFiles = $script:InputPaths.Count -gt 0
    $hasOutput = -not [string]::IsNullOrWhiteSpace($OutputText.Text) -and [IO.Directory]::Exists($OutputText.Text)
    $StartButton.Enabled = -not $script:Running -and $hasFiles -and $hasOutput
    $CancelButton.Enabled = $script:Running
    $AddButton.Enabled = -not $script:Running
    $RemoveButton.Enabled = -not $script:Running -and $FileList.SelectedItems.Count -gt 0
    $ClearButton.Enabled = -not $script:Running -and $hasFiles
    $BrowseButton.Enabled = -not $script:Running
    $LanguageChoice.Enabled = -not $script:Running
    $RotateCheck.Enabled = -not $script:Running
    $RedoCheck.Enabled = -not $script:Running
    $VerboseCheck.Enabled = -not $script:Running
    $OpenOutputButton.Enabled = -not $script:Running -and $script:Results.Count -gt 0
}

function Add-PdfPaths([string[]]$Paths) {
    if ($script:Running) { return }
    foreach ($candidate in $Paths) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $fullPath = [IO.Path]::GetFullPath($candidate)
        if (-not [IO.File]::Exists($fullPath)) { continue }
        if ([IO.Path]::GetExtension($fullPath) -ine '.pdf') { continue }
        if ($script:InputPaths -contains $fullPath) { continue }
        [void]$script:InputPaths.Add($fullPath)
        $item = New-Object System.Windows.Forms.ListViewItem([IO.Path]::GetFileName($fullPath))
        [void]$item.SubItems.Add([IO.Path]::GetDirectoryName($fullPath))
        [void]$item.SubItems.Add((Get-TextSet).queued)
        $item.Tag = $fullPath
        [void]$FileList.Items.Add($item)
        if ([string]::IsNullOrWhiteSpace($OutputText.Text)) {
            $OutputText.Text = [IO.Path]::GetDirectoryName($fullPath)
        }
    }
    $script:Results.Clear()
    $Progress.Value = 0
    Refresh-Controls
}

function Remove-Selected {
    if ($script:Running) { return }
    $indices = @($FileList.SelectedIndices | Sort-Object -Descending)
    foreach ($index in $indices) {
        $script:InputPaths.RemoveAt([int]$index)
        $FileList.Items.RemoveAt([int]$index)
    }
    $script:Results.Clear()
    $Progress.Value = 0
    Refresh-Controls
}

function Set-Busy([bool]$Busy) {
    $script:Running = $Busy
    Refresh-Controls
}

function Stop-Worker {
    if ($null -ne $script:Process -and -not $script:Process.HasExited) {
        & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /F /T /PID $script:Process.Id 2>$null | Out-Null
        [void]$script:Process.WaitForExit(5000)
    }
}

function Remove-JobDirectory {
    if ($null -ne $script:EventReader) {
        $script:EventReader.Dispose()
        $script:EventReader = $null
    }
    if ($script:JobDir -and [IO.Directory]::Exists($script:JobDir)) {
        Remove-Item -LiteralPath $script:JobDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:JobDir = $null
}

function Handle-WorkerLine([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    try {
        $message = $Line | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Append-Log $Line 'tech'
        return
    }
    switch ($message.event) {
        'file' {
            $index = [int]$message.index
            if ($index -ge 0 -and $index -lt $FileList.Items.Count) {
                $text = Get-TextSet
                $stateText = switch ([string]$message.state) {
                    'running' {
                        $pageProperty = $message.PSObject.Properties['page']
                        $pagesProperty = $message.PSObject.Properties['pages']
                        if ($null -ne $pageProperty -and $null -ne $pagesProperty) {
                            "$($text.running) $($pageProperty.Value)/$($pagesProperty.Value)"
                        } else { $text.running }
                    }
                    'done' { $text.done }
                    'failed' { $text.failed }
                    'cancelled' { $text.cancelled }
                    default { $text.queued }
                }
                $FileList.Items[$index].SubItems[2].Text = $stateText
            }
        }
        'stage' { $StageLabel.Text = [string]$message.text }
        'progress' {
            $value = [Math]::Max(0, [Math]::Min(100, [int]$message.value))
            $Progress.Value = $value
        }
        'log' { Append-Log ([string]$message.text) ([string]$message.kind) }
        'result' {
            [void]$script:Results.Add([string]$message.path)
            Refresh-Controls
        }
        'summary' {
            $script:SummarySeen = $true
            $text = Get-TextSet
            if ([int]$message.failed -gt 0) {
                Append-Log "$($text.finished): $($message.succeeded) succeeded, $($message.failed) failed" 'bad'
            } else {
                Append-Log "$($text.finished): $($message.succeeded) succeeded" 'done'
            }
        }
        'fatal' { Append-Log ([string]$message.text) 'bad' }
    }
}

function Drain-Events {
    if ($null -eq $script:EventReader) { return }
    while (-not $script:EventReader.EndOfStream) {
        $line = $script:EventReader.ReadLine()
        if ($null -ne $line) {
            try {
                Handle-WorkerLine $line
            } catch {
                try { Append-Log "Optional display update skipped: $($_.Exception.Message)" 'tech' } catch {}
            }
        }
    }
}

function Finish-Run {
    if (-not $script:Running) { return }
    Drain-Events
    if ($script:Cancelled) {
        $text = Get-TextSet
        foreach ($item in $FileList.Items) {
            if ($item.SubItems[2].Text -ne $text.done -and $item.SubItems[2].Text -ne $text.failed) {
                $item.SubItems[2].Text = $text.cancelled
            }
        }
        Append-Log $text.cancelled 'plain'
    } elseif (-not $script:SummarySeen) {
        Append-Log (Get-TextSet).unexpected 'bad'
    }
    $StageLabel.Text = (Get-TextSet).ready
    Set-Busy $false
    Remove-JobDirectory
}

function Test-OutputFolder([string]$Path) {
    if (-not [IO.Directory]::Exists($Path)) { return $false }
    $probe = Join-Path $Path ('.ocr_write_test_' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($probe, 'test')
        return $true
    } catch {
        return $false
    } finally {
        try {
            if ([IO.File]::Exists($probe)) { [IO.File]::Delete($probe) }
        } catch {}
    }
}

function Start-Run {
    $text = Get-TextSet
    if ($script:InputPaths.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show($text.need_files, $text.title)
        return
    }
    if (-not [IO.Directory]::Exists($OutputText.Text)) {
        [void][System.Windows.Forms.MessageBox]::Show($text.need_output, $text.title)
        return
    }
    if (-not (Test-OutputFolder $OutputText.Text)) {
        [void][System.Windows.Forms.MessageBox]::Show($text.cannot_write, $text.title)
        return
    }

    $script:Cancelled = $false
    $script:SummarySeen = $false
    $script:Results.Clear()
    $Progress.Value = 0
    $LogBox.Clear()
    foreach ($item in $FileList.Items) { $item.SubItems[2].Text = $text.queued }

    $script:JobDir = Join-Path ([IO.Path]::GetTempPath()) ('document_ocr_' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($script:JobDir) | Out-Null
    $configPath = Join-Path $script:JobDir 'job.json'
    $eventPath = Join-Path $script:JobDir 'events.jsonl'
    $language = @('eng', 'eng+ara', 'ara')[$LanguageChoice.SelectedIndex]
    $config = [ordered]@{
        inputs = @($script:InputPaths)
        output_dir = $OutputText.Text
        job_dir = $script:JobDir
        report_path = $RunReport
        options = [ordered]@{
            lang = $language
            rotate = [bool]$RotateCheck.Checked
            redo = [bool]$RedoCheck.Checked
            verbose = [bool]$VerboseCheck.Checked
        }
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 5), $utf8)
    [IO.File]::WriteAllText($eventPath, '', $utf8)
    $eventFile = New-Object IO.FileStream(
        $eventPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    $script:EventReader = New-Object IO.StreamReader($eventFile, [Text.Encoding]::UTF8, $true)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Python
    $startInfo.Arguments = "-X utf8 -s -u `"$Worker`" --config `"$configPath`" --events `"$eventPath`""
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $script:Process = New-Object System.Diagnostics.Process
    $script:Process.StartInfo = $startInfo

    try {
        if (-not $script:Process.Start()) { throw 'Could not start the OCR worker.' }
        Set-Busy $true
        $StageLabel.Text = $text.running
        Append-Log $text.running 'head'
    } catch {
        Append-Log $_.Exception.Message 'bad'
        Remove-JobDirectory
        Set-Busy $false
    }
}

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 150
$Timer.Add_Tick({
    Drain-Events
    if ($script:Running -and $null -ne $script:Process -and $script:Process.HasExited) {
        $script:Process.WaitForExit()
        Drain-Events
        Finish-Run
    }
})
$Timer.Start()

$AddButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'PDF files (*.pdf)|*.pdf'
    $dialog.Multiselect = $true
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog() -eq 'OK') { Add-PdfPaths $dialog.FileNames }
    $dialog.Dispose()
})
$RemoveButton.Add_Click({ Remove-Selected })
$FileList.Add_SelectedIndexChanged({ Refresh-Controls })
$ClearButton.Add_Click({
    if ($script:Running) { return }
    $script:InputPaths.Clear()
    $script:Results.Clear()
    $FileList.Items.Clear()
    $LogBox.Clear()
    $Progress.Value = 0
    $StageLabel.Text = (Get-TextSet).ready
    Refresh-Controls
})
$BrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ([IO.Directory]::Exists($OutputText.Text)) { $dialog.SelectedPath = $OutputText.Text }
    if ($dialog.ShowDialog() -eq 'OK') { $OutputText.Text = $dialog.SelectedPath }
    $dialog.Dispose()
    Refresh-Controls
})
$LanguageChoice.Add_SelectedIndexChanged({
    $ArabicWarning.Visible = $LanguageChoice.SelectedIndex -eq 1
})
$InterfaceChoice.Add_SelectedIndexChanged({
    $script:InterfaceLanguage = if ($InterfaceChoice.SelectedIndex -eq 1) { 'ar' } else { 'en' }
    Apply-Language
})
$StartButton.Add_Click({ Start-Run })
$CancelButton.Add_Click({
    if (-not $script:Running) { return }
    $script:Cancelled = $true
    $CancelButton.Enabled = $false
    Append-Log (Get-TextSet).cancelling 'plain'
    Stop-Worker
})
$OpenOutputButton.Add_Click({
    if ([IO.Directory]::Exists($OutputText.Text)) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList @($OutputText.Text)
    }
})

$dragEnter = {
    param($sender, $eventArgs)
    if (-not $script:Running -and $eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $eventArgs.Effect = [Windows.Forms.DragDropEffects]::Copy
    } else {
        $eventArgs.Effect = [Windows.Forms.DragDropEffects]::None
    }
}
$dragDrop = {
    param($sender, $eventArgs)
    if (-not $script:Running) {
        Add-PdfPaths ([string[]]$eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
    }
}
$Form.Add_DragEnter($dragEnter)
$Form.Add_DragDrop($dragDrop)
$FileList.Add_DragEnter($dragEnter)
$FileList.Add_DragDrop($dragDrop)

$Form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:Running) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            (Get-TextSet).confirm_close,
            (Get-TextSet).title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $eventArgs.Cancel = $true
            return
        }
        $script:Cancelled = $true
        Stop-Worker
    }
    Remove-JobDirectory
})

Apply-Language
Refresh-Controls
[void][System.Windows.Forms.Application]::Run($Form)
