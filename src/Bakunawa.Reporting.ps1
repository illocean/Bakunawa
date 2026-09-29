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
        Write-ReportHeading ('BAKUNAWA / {0}' -f $Mode.ToUpperInvariant())
        Write-ReportMetric 'Started' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
        Write-ReportMetric 'Scope' 'Local disk C: only'
        Write-ReviewLine "Text log: $script:ScanLogPath"
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
        Write-Progress -Id 2 -Activity 'Bakunawa discovery' -Completed
        Write-ScanLogText ("RUN FINISHED | {0} | {1} | elapsed {2}" -f $status, (Get-Date -Format o), (Format-ReportDuration $watch.Elapsed.TotalSeconds))
        try { $script:ScanLogWriter.Dispose() }
        catch { $script:ScanLogFailed = $true; Write-Warning "Text log could not be closed: $($_.Exception.Message)" }
        finally { $script:ScanLogWriter = $null }
        if ($script:ScanLogFailed) { Write-ReviewLine "Text log INCOMPLETE: $script:ScanLogPath" -ForegroundColor Yellow }
        else { Write-ReviewLine "Text log saved: $script:ScanLogPath" -ForegroundColor Cyan }
    }
}

function Write-ScanProgress {
    [CmdletBinding()]
    param(
        [string]$Root, [int]$RootIndex, [int]$RootCount,
        [long]$Visited, [long]$Directories, [int]$Candidates, [int]$Errors, [int]$Skipped,
        [double]$Seconds, [string]$CurrentPath, [switch]$Force
    )
    $status = 'Root {0}/{1} | {2:N0}+ entries visited | {3:N0} folders completed | {4:N0} possible candidates | {5}' -f $RootIndex, $RootCount, $Visited, $Directories, $Candidates, (Format-ReportDuration $Seconds)
    if (-not $script:NoAnimations) {
        Write-Progress -Id 2 -Activity 'Bakunawa discovery / total size unknown' -Status $status -CurrentOperation $CurrentPath -PercentComplete -1
    }
    if ($Force -or -not $script:LastProgressLogTime -or ((Get-Date) - $script:LastProgressLogTime).TotalSeconds -ge 5) {
        Write-ReviewLine $status -ForegroundColor Cyan
        Write-ReviewLine ("Errors: {0:N0} | Excluded / skipped: {1:N0} | Current: {2}" -f $Errors, $Skipped, $CurrentPath) -ForegroundColor Gray
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
