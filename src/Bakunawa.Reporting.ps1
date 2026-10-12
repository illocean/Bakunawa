# Loaded by the UI module. One automatic text log per user-selected operation.
function Write-ScanLogText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '')
    if ($script:ReadOnlyOutput) { return }
    # Keep logs readable even when a path contains terminal control characters.
    $plain = $Text -replace '\x1B\[[0-?]*[ -/]*[@-~]', '' -replace '[\x00-\x08\x0B-\x1F\x7F]', ''
    if ($script:ScanLogWriter) {
        try { $script:ScanLogWriter.WriteLine($plain) }
        catch {
            if (-not $script:ScanLogFailed) { Write-Warning "Text log could not be written: $($_.Exception.Message)" }
            $script:ScanLogFailed = $true
        }
    }
    if ($script:LogFilePath) {
        try { Add-Content -LiteralPath $script:LogFilePath -Value $plain -Encoding UTF8 -ErrorAction Stop }
        catch {
            if (-not $script:ExtraLogFailed) { Write-Warning "Additional log could not be written: $($_.Exception.Message)" }
            $script:ExtraLogFailed = $true
        }
    }
}

function Get-ScanLogPath {
    [CmdletBinding()]
    param()
    $script:ScanLogPath
}

function Get-ScanLogDirectory {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Bakunawa\Logs'
}

function Set-UiOptions {
    [CmdletBinding()]
    param([switch]$NoAnimations)
    $script:NoAnimations = [bool]$NoAnimations
}

function Invoke-LoggedOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Standard','Aggressive','Preview','Scan','Health','Benchmark')][string]$Mode,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if ($Mode -eq 'Preview') {
        $previous = $script:ReadOnlyOutput
        $script:ReadOnlyOutput = $true
        $script:ScanLogPath = $null
        try { & $Action } finally { $script:ReadOnlyOutput = $previous }
        return
    }
    if ($script:ScanLogWriter) { & $Action; return }
    $directory = Get-ScanLogDirectory
    $null = [IO.Directory]::CreateDirectory($directory)
    $name = '{0}-{1}-{2}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $Mode, ([guid]::NewGuid().ToString('N').Substring(0,8))
    $script:ScanLogPath = Join-Path $directory $name
    # CreateNew preserves existing reports. Fail before work if logging cannot start.
    $stream = $null
    try {
        $stream = [IO.File]::Open($script:ScanLogPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $script:ScanLogWriter = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($true))
        $script:ScanLogWriter.AutoFlush = $true
    } catch {
        if ($stream) { $stream.Dispose() }
        $script:ScanLogWriter = $null
        throw "Cannot start text log at '$script:ScanLogPath': $($_.Exception.Message)"
    }
    $script:ScanLogFailed = $false
    $script:ExtraLogFailed = $false
    $script:LastProgressLogTime = [datetime]::MinValue
    $script:CurrentModeName = $Mode
    $status = 'Interrupted'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        Start-StorageBaseline
        Write-ReportTitle ('{0} · started {1}' -f $Mode, (Get-Date -Format 'HH:mm:ss')) -Meta 'local disk C: only'
        Write-ReportRow ('Log  {0}' -f (Split-Path -Leaf $script:ScanLogPath)) -Color DarkGray
        Write-ScanLogText 'An Interrupted run or a log without RUN FINISHED is incomplete.'
        foreach ($path in @(Get-CoreExcludedPaths)) { Write-ScanLogText ("PROTECTED PATH | {0}" -f $path) }
        & $Action
        $status = 'Finished; see summary for errors and coverage gaps'
    } catch {
        $status = 'Failed'
        Write-ReviewLine ("Operation failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        throw
    } finally {
        Write-Progress -Id 1 -Activity 'Bakunawa' -Completed
        Clear-UiProgress
        Write-ScanLogText ("RUN FINISHED | {0} | {1} | elapsed {2}" -f $status, (Get-Date -Format o), (Format-ReportDuration $watch.Elapsed.TotalSeconds))
        try { $script:ScanLogWriter.Dispose() }
        catch { $script:ScanLogFailed = $true; Write-Warning "Text log could not be closed: $($_.Exception.Message)" }
        finally { $script:ScanLogWriter = $null }
        if ($script:ScanLogFailed) { Write-ReviewLine "Text log INCOMPLETE: $script:ScanLogPath" -ForegroundColor Yellow }
        else { Write-ReviewLine "Text log saved: $script:ScanLogPath" -ForegroundColor Cyan }
    }
}

# ── REPORT LAYOUT ──
# Report rows are left-aligned at one gutter so labels form a column. They used
# to be centred, which gave every row its own left edge and made a summary read
# as a ragged block instead of a table.
function Write-ReportRow {
    param([AllowEmptyString()][string]$Text = '', [ConsoleColor]$Color = 'White', [switch]$Raw)
    Write-ScanLogText $Text
    $plain = $Text -replace '\x1B\[[0-?]*[ -/]*[@-~]', '' -replace '[\x00-\x08\x0B-\x1F\x7F]', ' '
    $indent = ' ' * $script:UiGutter
    # A rule wider than the window wraps, so the report never claims more room
    # than the terminal has (and never uses the whole screen on a wide one).
    $width = [math]::Max(20, [math]::Min(100, (Get-UiLayout).Content - $script:UiGutter))
    # A path is one token: wrapping it mid-name makes it unreadable, so a raw
    # row is printed whole and the terminal decides where it ends.
    if ($Raw) {
        Write-Host ($indent + $plain) -ForegroundColor $Color
        return
    }
    # Wrap with a hanging indent: a long path stays readable and stays in column.
    while ($plain.Length -gt $width) {
        $break = $plain.LastIndexOf(' ', $width)
        if ($break -lt [int]($width / 2)) { $break = $width }
        Write-Host ($indent + $plain.Substring(0, $break)) -ForegroundColor $Color
        $plain = $indent + '   ' + $plain.Substring($break).TrimStart(' ')
        $width -= 3
    }
    Write-Host ($indent + $plain) -ForegroundColor $Color
}

# One hairline carries the section name and its meta value, so a report opens
# with a divider instead of a three-line banner.
function Write-ReportTitle {
    param([string]$Title, [string]$Meta = '')
    Write-ScanLogText ($Title + $(if ($Meta) { "  $Meta" } else { '' }))
    $width = [math]::Max(20, [math]::Min(100, (Get-UiLayout).Content - $script:UiGutter))
    $left = "── $Title "
    $right = if ($Meta) { " $Meta ──" } else { ' ──' }
    $fill = [math]::Max(2, $width - $left.Length - $right.Length)
    Write-Host ((' ' * $script:UiGutter) + $left + ('─' * $fill) + $right) -ForegroundColor DarkCyan
}

# Free space is the one number that has to read at a glance, so it is the only
# figure shown twice: before and after. The baseline is taken when the run
# starts, which makes the difference exact rather than estimated.
function Start-StorageBaseline {
    [CmdletBinding()]
    param()
    $script:StorageBaseline = $null
    try {
        $info = Get-FreeSpaceInfo
        if ($info -and $null -ne $info.FreeBytes) {
            $script:StorageBaseline = [PSCustomObject]@{ FreeBytes = [long]$info.FreeBytes; Started = Get-Date }
        }
    } catch { $script:StorageBaseline = $null }
}

function Get-StorageComparison {
    [CmdletBinding()]
    param([string]$Label = 'Free space')
    if (-not $script:StorageBaseline) { return $null }
    try { $info = Get-FreeSpaceInfo } catch { return $null }
    if (-not $info -or $null -eq $info.FreeBytes) { return $null }
    $before = [long]$script:StorageBaseline.FreeBytes
    $after = [long]$info.FreeBytes
    [PSCustomObject]@{ Label = $Label; Before = $before; After = $after; Change = ($after - $before) }
}

function Write-StorageLine {
    param($Comparison, [string]$Note = '')
    if (-not $Comparison) { return }
    $suffix = if ($Note) { "   $Note" } else { '' }
    $color = if ($Comparison.Change -gt 0) { 'Green' } elseif ($Comparison.Change -lt 0) { 'Yellow' } else { 'Gray' }
    Write-ReportRow ('{0,-16}{1} → {2}{3}' -f $Comparison.Label, (Format-FileSize $Comparison.Before), (Format-FileSize $Comparison.After), $suffix) -Color $color
}

# "1 candidates" reads as a bug in a summary a user is reading for numbers.
function Format-Count {
    param([double]$Count, [string]$Noun, [string]$Plural)
    if (-not $Plural) { $Plural = $Noun + 's' }
    '{0:N0} {1}' -f $Count, $(if ($Count -eq 1) { $Noun } else { $Plural })
}

# ── SCAN STATUS ──
# The walk has no total to measure against, so the status line reports what is
# true: the root, the elapsed time, the entries seen and the candidates so far.
function Get-PathTail {
    [CmdletBinding()]
    param([string]$Path, [int]$Segments = 3)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $clean = $Path.TrimEnd('\')
    $parts = @($clean -split '[\\/]')
    if ($parts.Count -le $Segments) { return $clean }
    return '…\' + ($parts[($parts.Count - $Segments)..($parts.Count - 1)] -join '\')
}

function Format-ScanStatus {
    [CmdletBinding()]
    param(
        [string]$Root, [int]$RootIndex = 1, [int]$RootCount = 1,
        [long]$Visited = 0, [int]$Candidates = 0, [int]$Errors = 0, [double]$Seconds = 0,
        [string]$CurrentPath = '', [int]$Width = 0
    )
    if ($Width -le 0) { $Width = [math]::Max(40, (Get-ConsoleWidth) - 4) }
    $where = Get-PathTail $Root 2
    if ($RootCount -gt 1) { $where = '{0} root {1}/{2}' -f $where, $RootIndex, $RootCount }
    $line = '{0} · {1} · {2:N0} entries · {3:N0} candidates' -f $where, (Format-ReportDuration $Seconds), $Visited, $Candidates
    if ($Errors -gt 0) { $line += ' · {0:N0} errors' -f $Errors }
    $tail = Get-PathTail $CurrentPath 3
    if ($tail -and $tail -ne $where) { $line += ' · ' + $tail }
    if ($line.Length -gt $Width) { $line = $line.Substring(0, [math]::Max(1, $Width - 1)) + '…' }
    $line
}

function Write-ScanProgress {
    [CmdletBinding()]
    param(
        [string]$Root, [int]$RootIndex, [int]$RootCount,
        [long]$Visited, [long]$Directories, [int]$Candidates, [int]$Errors, [int]$Skipped,
        [double]$Seconds, [string]$CurrentPath, [switch]$Force
    )
    $line = Format-ScanStatus -Root $Root -RootIndex $RootIndex -RootCount $RootCount -Visited $Visited -Candidates $Candidates -Errors $Errors -Seconds $Seconds -CurrentPath $CurrentPath
    # One line, rewritten where it stands. The old screen drew a native progress
    # bar and then appended two wrapped lines every five seconds, so a scan left
    # a wall of repeated text behind it.
    if (-not $script:NoAnimations -and -not [Console]::IsOutputRedirected) {
        Clear-UiProgress
        Write-Host $line -ForegroundColor 'DarkCyan' -NoNewline
        $script:UiProgressLength = $line.Length
    }
    # The log keeps the history; the console keeps one moving line.
    if ($Force -or -not $script:LastProgressLogTime -or ((Get-Date) - $script:LastProgressLogTime).TotalSeconds -ge 5) {
        Write-ScanLogText ("PROGRESS | {0}" -f $line)
        $script:LastProgressLogTime = Get-Date
    }
}

function Write-ScanReportLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Report)
    Write-ScanLogText ''
    Write-ScanLogText 'FULL DISCOVERY REPORT'
    Write-ScanLogText ("Status: {0} | Roots visited: {1} | Roots skipped: {2}" -f $Report.Status, ($Report.RootsVisited -join ', '), ($Report.RootsSkipped -join ', '))
    Write-ScanLogText ("Elapsed seconds: {0} | Candidates: {1}" -f $Report.DurationSec, @($Report.Findings).Count)
    Write-ScanLogText 'COVERAGE'
    foreach ($drive in $Report.Coverage) {
        Write-ScanLogText ("{0} | {1} | Files: {2} | Folders: {3} | Errors: {4} | Skipped: {5} | Seconds: {6}" -f $drive.Root, $drive.Status, $drive.Files, $drive.Directories, $drive.Errors, $drive.Skipped, $drive.DurationSec)
    }
    Write-ScanLogText 'CONFIGURED EXCLUSIONS'
    foreach ($path in $Report.Exclusions) { Write-ScanLogText $path }
    Write-ScanLogText 'CANDIDATES (data found, not space reclaimed)'
    foreach ($item in $Report.Findings) {
        Write-ScanLogText $item.Path
        Write-ScanLogText ("  {0} | Bytes: {1} | Files: {2} | Age: {3} days | {4} | Eligible orphan: {5}" -f $item.Category, $item.Size, $item.FileCount, $item.DaysSinceModified, $item.Tier, $item.SafeDelete)
        Write-ScanLogText ("  Last modified UTC: {0} | Root: {1}" -f $item.LatestWriteUtc, $item.ScanRoot)
        Write-ScanLogText ("  Reason: {0}" -f $item.Reason)
        Write-ScanLogText ("  Evidence rule: {0} | Checks: {1}" -f $item.EvidenceRule, ($item.EvidenceChecks -join '; '))
    }
    Write-ScanLogText 'ISSUES (all encountered errors and skips)'
    foreach ($issue in $Report.Issues) { Write-ScanLogText ("{0} | {1} | {2}" -f $issue.Kind, $issue.Path, $issue.Reason) }
    Write-ScanLogText 'END DISCOVERY REPORT'
    if ($script:ScanLogWriter -and -not $script:ScanLogFailed) { $Report.TextLogPath = $script:ScanLogPath }
}
