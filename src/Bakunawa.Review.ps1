function Write-ReviewLine {
    param([AllowEmptyString()][string]$Text = '', [ConsoleColor]$ForegroundColor = 'White')
    Write-ScanLogText $Text
    $Text = $Text -replace '\x1B\[[0-?]*[ -/]*[@-~]', '' -replace '[\x00-\x1F\x7F]', ' '
    $consoleWidth = Get-ConsoleWidth
    $width = [math]::Max(1, [math]::Min(96, $consoleWidth - 4))
    $indent = ' ' * [math]::Max(0, [int](($consoleWidth - $width) / 2))
    if (-not $Text) { Write-Host ''; return }
    # Wrap instead of hiding the end of a path or an explanation.
    $remaining = $Text
    while ($remaining.Length -gt $width) {
        $break = $remaining.LastIndexOf(' ', $width)
        if ($break -le 0 -or $break -lt [int]($width / 2)) { $break = $width }
        Write-Host ($indent + $remaining.Substring(0, $break)) -ForegroundColor $ForegroundColor
        $remaining = $remaining.Substring($break).TrimStart(' ')
    }
    if ($remaining) { Write-Host ($indent + $remaining) -ForegroundColor $ForegroundColor }
}

function Write-ReportHeading {
    param([string]$Title, [ConsoleColor]$Color = 'Cyan')
    Write-ReviewLine
    Write-ReviewLine ('=' * [math]::Max(1, [math]::Min(72, (Get-ConsoleWidth) - 4))) -ForegroundColor $Color
    Write-ReviewLine $Title -ForegroundColor $Color
    Write-ReviewLine ('-' * [math]::Max(1, [math]::Min(72, (Get-ConsoleWidth) - 4))) -ForegroundColor DarkGray
}

function Write-ReportMetric {
    param([string]$Label, [string]$Value, [ConsoleColor]$Color = 'White')
    if ((Get-ConsoleWidth) -lt 60) { Write-ReviewLine ("{0}: {1}" -f $Label, $Value) -ForegroundColor $Color }
    else { Write-ReviewLine ('{0,-24} : {1}' -f $Label, $Value) -ForegroundColor $Color }
}

function Format-ReportDuration {
    param([double]$Seconds)
    $duration = [TimeSpan]::FromSeconds([math]::Max(0, $Seconds))
    '{0:00}:{1:00}:{2:00}' -f [math]::Floor($duration.TotalHours), $duration.Minutes, $duration.Seconds
}

function Export-ScanReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Report, [Parameter(Mandatory)][string]$Path)
    try { $Report | ConvertTo-Json -Depth 12 | Out-File -LiteralPath $Path -Encoding UTF8 -NoClobber -ErrorAction Stop }
    catch { throw "Cannot write report '$Path'. Existing reports are preserved; choose a new path. $($_.Exception.Message)" }
}

function Show-ScanCoverage {
    param([object[]]$Coverage)
    if (-not @($Coverage | Where-Object { $_ }).Count) { return }
    Write-ReviewLine
    Write-ReviewLine 'SCAN COVERAGE' -ForegroundColor Cyan
    foreach ($drive in ($Coverage | Where-Object { $_ })) {
        $color = if ($drive.Errors -gt 0 -or $drive.Skipped -gt 0 -or $drive.Status -notin @('Complete','Complete within exclusions')) { 'Yellow' } else { 'Green' }
        Write-ReviewLine $drive.Root
        Write-ReportMetric '  Status' $drive.Status -Color $color
        Write-ReportMetric '  Files / folders' ('{0:N0} / {1:N0}' -f $drive.Files, $drive.Directories)
        Write-ReportMetric '  Errors / excluded' ('{0:N0} / {1:N0}' -f $drive.Errors, $drive.Skipped) -Color $(if ($drive.Errors) { 'Yellow' } else { 'Gray' })
    }
}

function Show-ScanSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$ScanResult, [switch]$Review)
    $findings = @($ScanResult.Findings | Where-Object { $_ })
    $coverage = @($ScanResult.Coverage | Where-Object { $_ })
    $issues = @($ScanResult.Issues | Where-Object { $_ })
    $safe = @($findings | Where-Object { $_.SafeDelete })
    $scanErrors = [math]::Max(@($issues | Where-Object Kind -eq 'Error').Count, [long](($coverage | Measure-Object Errors -Sum).Sum))
    $excluded = [math]::Max(@($issues | Where-Object Kind -eq 'Skipped').Count, [long](($coverage | Measure-Object Skipped -Sum).Sum))
    $partial = @($coverage | Where-Object { $_.Status -notin @('Complete','Complete within exclusions') -or $_.Errors -gt 0 -or $_.Skipped -gt 0 }).Count
    $status = if ($scanErrors -gt 0 -or $partial -gt 0 -or $excluded -gt 0) { 'Incomplete - finished with coverage gaps' }
              elseif (-not $coverage.Count) { 'Coverage not recorded' }
              else { 'Complete' }
    Write-ReportHeading 'SCAN SUMMARY'
    Write-ReportMetric 'Scope' 'Local disk C: only'
    Write-ReportMetric 'Status' $status -Color $(if ($scanErrors -or $partial -or -not $coverage.Count) { 'Yellow' } else { 'Green' })
    Write-ReportMetric 'Elapsed' (Format-ReportDuration $ScanResult.DurationSec)
    Write-ReportMetric 'Scan roots' ('{0:N0}' -f $coverage.Count)
    Write-ReportMetric 'Roots visited / skipped' ('{0} / {1}' -f @($ScanResult.RootsVisited).Count, @($ScanResult.RootsSkipped).Count)
    Write-ReportMetric 'Files / folders scanned' ('{0:N0} / {1:N0}' -f [long](($coverage | Measure-Object Files -Sum).Sum), [long](($coverage | Measure-Object Directories -Sum).Sum))
    Write-ReportMetric $(if ($Review) { 'Candidates remaining' } else { 'Candidates found' }) ('{0:N0}' -f $findings.Count) -Color Cyan
    Write-ReportMetric 'Candidate data' (Format-FileSize (($findings | Measure-Object Size -Sum).Sum)) -Color Cyan
    Write-ReportMetric 'Eligible orphans' ('{0:N0} ({1})' -f $safe.Count, (Format-FileSize (($safe | Measure-Object Size -Sum).Sum)))
    Write-ReportMetric 'Review required' ('{0:N0} ({1})' -f ($findings.Count - $safe.Count), (Format-FileSize (($findings | Where-Object { -not $_.SafeDelete } | Measure-Object Size -Sum).Sum))) -Color $(if ($findings.Count -gt $safe.Count) { 'Yellow' } else { 'Gray' })
    Write-ReportMetric 'Scan errors' ('{0:N0}' -f $scanErrors) -Color $(if ($scanErrors) { 'Red' } else { 'Gray' })
    Write-ReportMetric 'Excluded / skipped' ('{0:N0}' -f $excluded) -Color Gray
    Write-ReviewLine ('-' * [math]::Min(72, (Get-ConsoleWidth) - 4)) -ForegroundColor DarkGray
    Write-ReviewLine 'Discovery does not delete files. Candidate data is not reclaimed space.' -ForegroundColor Gray
    if ($scanErrors -or $partial) { Write-ReviewLine 'Some locations were not fully scanned. Check coverage and issues before acting.' -ForegroundColor Yellow }
    if ($ScanResult.TextLogPath -and -not $script:ScanLogFailed) { Write-ReviewLine ("Full report: {0}" -f $ScanResult.TextLogPath) -ForegroundColor Cyan }
    if ($findings.Count) {
        Write-ReviewLine
        Write-ReviewLine 'DATA BY CATEGORY / largest first' -ForegroundColor Cyan
        $groups = @($findings | Group-Object Category | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Count = $_.Count; Bytes = [long](($_.Group | Measure-Object Size -Sum).Sum) }
        } | Sort-Object Bytes -Descending)
        foreach ($group in $groups) { Write-ReportMetric $group.Name ('{0,10} | {1:N0} items' -f (Format-FileSize $group.Bytes), $group.Count) }
        Write-ReviewLine 'Next: Preview [3] for routine cleanup; Scan C: [4] to review and delete selections.' -ForegroundColor Cyan
    }
}

function Show-OrphanScanResults {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$ScanResult, [switch]$Interactive)
    $findings = @($ScanResult.Findings | Where-Object { $_ })
    $hasFullLog = $ScanResult.TextLogPath -and -not $script:ScanLogFailed
    $page = 0; $pageSize = 10
    do {
        Show-ScanSummary -ScanResult $ScanResult -Review:$Interactive
        Show-ScanCoverage -Coverage $ScanResult.Coverage
        Write-ReviewLine
        Write-ReviewLine 'CANDIDATE REVIEW / largest first' -ForegroundColor Cyan
        Write-ReviewLine ('-' * [math]::Min(72, (Get-ConsoleWidth) - 4))
        $safe = @($findings | Where-Object SafeDelete)
        $bytes = ($findings | Measure-Object Size -Sum).Sum
        Write-ReviewLine ("{0} candidates | {1} | {2} eligible orphans | {3} need review" -f $findings.Count, (Format-FileSize $bytes), $safe.Count, ($findings.Count - $safe.Count))
        Write-ReviewLine 'Finding a candidate does not delete it. Age alone does not prove it is unused.'
        if (-not $findings.Count) { Write-ReviewLine 'No candidates found within the scanned scope.' }
        $start = if ($Interactive) { $page * $pageSize } else { 0 }
        $end = if ($Interactive -or $hasFullLog) { [math]::Min($start + $pageSize, $findings.Count) } else { $findings.Count }
        for ($i = $start; $i -lt $end; $i++) {
            $item = $findings[$i]
            Write-ReviewLine
            $action = if ($item.SafeDelete) { 'Eligible orphan' } else { 'Review required' }
            Write-ReviewLine ("[{0}] {1} | {2} | {3} days" -f ($i + 1), $item.Category, (Format-FileSize $item.Size), $item.DaysSinceModified) -ForegroundColor $(if ($item.SafeDelete) { 'Cyan' } else { 'Yellow' })
            Write-ReviewLine $item.Path
            Write-ReviewLine ("{0}: {1}" -f $action, $item.Reason) -ForegroundColor Gray
        }
        $issues = @($ScanResult.Issues | Where-Object { $_ })
        if ($issues.Count) {
            Write-ReportHeading 'SCAN ISSUES' -Color Yellow
            foreach ($issue in $issues) { Write-ReviewLine ("{0}: {1} - {2}" -f $issue.Kind, $issue.Path, $issue.Reason) -ForegroundColor $(if ($issue.Kind -eq 'Error') { 'Red' } else { 'Gray' }) }
        }
        if (-not $Interactive) {
            if ($end -lt $findings.Count) { Write-ReviewLine ("Showing the largest {0} of {1} candidates. Every candidate and reason is in the text log." -f $end, $findings.Count) -ForegroundColor Cyan }
            return
        }
        Write-ReviewLine
        Write-ReviewLine ("Page {0}/{1} | N next | P previous | E export | I scan issues | Q return" -f ($page + 1), [math]::Max(1, [math]::Ceiling($findings.Count / $pageSize)))
        Write-ReviewLine 'Enter item numbers separated by commas to review a selection.'
        $choice = (Read-Host 'Review').Trim()
        switch ($choice.ToUpperInvariant()) {
            'Q' { return }
            'N' { if (($page + 1) * $pageSize -lt $findings.Count) { $page++ }; continue }
            'P' { $page = [math]::Max(0, $page - 1); continue }
            'E' {
                $destination = Read-Host 'Report file path (.json)'
                if ($destination) {
                    try {
                        Export-ScanReport -Report $ScanResult -Path $destination
                        Write-ReviewLine "Report saved: $destination"
                    } catch { Write-ReviewLine $_.Exception.Message }
                }
                continue
            }
            'I' {
                foreach ($issue in @($ScanResult.Issues)) { if ($issue) { Write-ReviewLine ("{0}: {1} - {2}" -f $issue.Kind, $issue.Path, $issue.Reason) } }
                if (-not @($ScanResult.Issues).Count) { Write-ReviewLine 'No scan issues.' }
                [void](Read-Host 'Press Enter to return to review'); continue
            }
        }
        if ($choice -notmatch '^\d+(\s*,\s*\d+)*$') { Write-ReviewLine 'Choose a listed command or item number.'; continue }
        try { $numbers = @($choice -split ',' | ForEach-Object { [int]$_.Trim() } | Sort-Object -Unique) }
        catch { Write-ReviewLine 'Item number is out of range.'; continue }
        if (@($numbers | Where-Object { $_ -lt 1 -or $_ -gt $findings.Count }).Count) { Write-ReviewLine 'Item number is out of range.'; continue }
        $selection = @($numbers | ForEach-Object { $findings[$_ - 1] })
        Write-ReviewLine 'Permanently delete these items:'
        foreach ($item in $selection) { Write-ReviewLine $item.Path; Write-ReviewLine $item.Reason }
        Write-ReviewLine 'Deletion is permanent. There is no recovery copy.'
        if ((Read-Host 'Type DELETE to proceed; Enter cancels') -cne 'DELETE') { continue }
        foreach ($item in $selection) {
            try {
                $null = Clear-ReviewedOrphans -Path $item.Path
                Write-ReviewLine "Deleted: $($item.Path)"
                $findings = @($findings | Where-Object { $_.Path -ne $item.Path })
                $ScanResult.Findings = $findings
            } catch { Write-ReviewLine "Could not delete $($item.Path): $($_.Exception.Message)" }
        }
        $page = 0
    } while ($true)
}

function Show-CleanupResult {
    param([Parameter(Mandatory)]$Result)
    Set-UiContext -Mode $Result.Mode -Result $Result
    $errors = @($Result.Errors | Where-Object { $_ })
    $skips = @($Result.SkippedItems | Where-Object { $_ })
    Write-ReportHeading $(if ($Result.IsPreview) { 'PREVIEW SUMMARY' } else { 'CLEANUP SUMMARY' })
    Write-ReportMetric 'Mode' $Result.Mode
    Write-ReportMetric 'Scope' 'Local disk C: only'
    Write-ReportMetric 'Status' $(if ($errors.Count) { 'Finished with errors' } else { 'Finished' }) -Color $(if ($errors.Count) { 'Yellow' } else { 'Green' })
    Write-ReportMetric 'Elapsed' (Format-ReportDuration $Result.DurationSec)
    Write-ReportMetric $(if ($Result.IsPreview) { 'Paths previewed' } else { 'Paths processed' }) ('{0:N0}' -f $Result.PathsCleared)
    Write-ReportMetric $(if ($Result.IsPreview) { 'Estimated eligible data' } elseif ($Result.UnknownOutcomePaths) { 'Confirmed deleted data' } else { 'Deleted data' }) (Format-FileSize $Result.BytesFreed) -Color Cyan
    Write-ReportMetric 'Errors / skipped' ('{0:N0} / {1:N0}' -f $errors.Count, $skips.Count) -Color $(if ($errors.Count -or $skips.Count) { 'Yellow' } else { 'Gray' })
    if ($Result.IsPreview) { Write-ReviewLine 'Preview only. No files were deleted; sizes are estimates.' -ForegroundColor Gray }
    else { Write-ReviewLine 'Deletion is permanent and the space is reclaimed immediately.' -ForegroundColor Gray }
    if ($Result.PSObject.Properties['IsComplete'] -and -not $Result.IsComplete) { Write-ReviewLine 'INCOMPLETE: some paths could not be inspected. Elevated runs can identify additional candidates.' -ForegroundColor Yellow }
    if ($Result.UnknownOutcomePaths) { Write-ReviewLine ("{0} failed action(s) could not be remeasured. Confirmed totals are lower bounds." -f $Result.UnknownOutcomePaths) -ForegroundColor Yellow }
    foreach ($category in @($Result.CategoryReport)) {
        if (-not $category) { continue }
        Write-ReviewLine ("{0}: identified {1}; acted on {2}; not acted on {3}; unknown-size paths {4}" -f $category.Category, $category.IdentifiedBytes, $(if ($null -eq $category.ActedBytes) { 'unknown' } else { $category.ActedBytes }), $(if ($null -eq $category.NotActedBytes) { 'unknown' } else { $category.NotActedBytes }), $category.UnknownSizePaths)
        foreach ($reason in $category.Reasons) { Write-ReviewLine ("  {0}: {1} bytes; {2} unknown-size paths" -f $reason.Reason, $(if ($null -eq $reason.Bytes) { 'unknown' } else { $reason.Bytes }), $reason.UnknownSizePaths) }
    }
    foreach ($row in @($Result.Outcomes | Where-Object Status -eq 'Skipped')) {
        Write-ReviewLine ("Skipped: {0} | {1} | {2}" -f $row.Path, $row.Reason, $row.Detail) -ForegroundColor Yellow
    }
    if ($Result.CategorySizes.Count) {
        Write-ReportHeading $(if ($Result.IsPreview) { 'ESTIMATED DATA BY CATEGORY' } else { 'PROCESSED DATA BY CATEGORY' })
        if (-not $Result.IsPreview) { Write-ReviewLine 'Category totals include deleted data.' -ForegroundColor Gray }
        foreach ($category in ($Result.CategorySizes.GetEnumerator() | Sort-Object Value -Descending)) {
            Write-ReportMetric $category.Key $(if ($null -eq $category.Value) { 'unknown' } else { Format-FileSize $category.Value })
        }
    }
    if ($Result.ScanReport) { Show-ScanSummary -ScanResult $Result.ScanReport; Show-ScanCoverage -Coverage $Result.ScanReport.Coverage }
    else { Write-ReviewLine 'Orphan discovery was not run; no drive coverage is reported.' -ForegroundColor Gray }
    if ($errors.Count) {
        Write-ReportHeading 'CLEANUP ERRORS' -Color Yellow
        foreach ($failure in $errors) { Write-ReviewLine "$($failure.Path): $($failure.Error)" -ForegroundColor Yellow }
    }
    if ($skips.Count) {
        Write-ReportHeading 'SKIPPED ITEMS' -Color Yellow
        foreach ($skip in $skips) { Write-ReviewLine "$($skip.Target): $($skip.Reason)" }
    }
    if (Get-ScanLogPath) { Write-ReviewLine ("Full report: {0}" -f (Get-ScanLogPath)) -ForegroundColor Cyan }
}
