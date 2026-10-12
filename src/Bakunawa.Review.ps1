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
    $roots = @($Coverage | Where-Object { $_ })
    if (-not $roots.Count) { return }
    foreach ($drive in $roots) {
        $color = if ($drive.Errors -gt 0 -or $drive.Skipped -gt 0 -or $drive.Status -notin @('Complete','Complete within exclusions')) { 'Yellow' } else { 'Gray' }
        Write-ReportRow ('{0,-16}{1} · {2} · {3} skipped · {4}' -f (Get-DisplayText (Get-PathTail $drive.Root 2) 15), $drive.Status, (Format-Count $drive.Files 'file'), (Format-Count $drive.Skipped 'path'), (Format-ReportDuration $drive.DurationSec)) -Color $color
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
    # Four rows answer the whole scan: how much space, how much is reclaimable,
    # how much was covered, and whether the walk can be trusted. The full
    # breakdown stays in the text log instead of scrolling past.
    $label = '{0,-16}' -f ''
    $files = [long](($coverage | Measure-Object Files -Sum).Sum)
    $folders = [long](($coverage | Measure-Object Directories -Sum).Sum)
    $bytes = [long](($findings | Measure-Object Size -Sum).Sum)
    $safeBytes = [long](($safe | Measure-Object Size -Sum).Sum)
    Clear-UiProgress

    Write-ReportTitle 'Scan complete' -Meta (Format-ReportDuration $ScanResult.DurationSec)
    $comparison = Get-StorageComparison
    if ($comparison) { Write-StorageLine $comparison -Note 'unchanged - read-only run' }
    # Without a drive comparison (preview) the total needs a label of its own,
    # otherwise every row in the block starts with a blank column.
    $totalLabel = if ($comparison) { '{0,-16}' -f '' } else { '{0,-16}' -f 'Found' }
    Write-ReportRow ('{0}{1} in {2}' -f $totalLabel, (Format-FileSize $bytes), (Format-Count $findings.Count 'candidate')) -Color Cyan
    Write-ReportRow ('{0}{1} in {2} · {3:N0} needing review' -f $label, (Format-FileSize $safeBytes), (Format-Count $safe.Count 'eligible orphan'), ($findings.Count - $safe.Count)) -Color $(if ($findings.Count -gt $safe.Count) { 'Yellow' } else { 'Gray' })
    Write-ReportRow ('{0}{1} · {2} · {3} skipped' -f $label, (Format-Count $files 'file'), (Format-Count $folders 'folder'), (Format-Count $excluded 'path')) -Color Gray
    Write-ReportRow ('{0}{1}' -f $label, $status) -Color $(if ($scanErrors -or $partial -or -not $coverage.Count) { 'Yellow' } else { 'Green' })
    if ($scanErrors -or $partial) { Write-ReportRow '  Some locations were not fully scanned. Check coverage and issues before acting.' -Color Yellow }
    Show-ScanCoverage -Coverage $ScanResult.Coverage
    if ($findings.Count) {
        $groups = @($findings | Group-Object Category | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Count = $_.Count; Bytes = [long](($_.Group | Measure-Object Size -Sum).Sum) }
        } | Sort-Object Bytes -Descending)
        Write-ReportRow ''
        foreach ($group in $groups) { Write-ReportRow ('{0}{1,10}  {2}' -f $label, (Format-FileSize $group.Bytes), (Format-Count $group.Count 'item')) -Color DarkGray }
        Write-ReportRow 'Next: Preview [3] for routine cleanup; Scan C: [4] to review and delete selections.' -Color DarkCyan
    }
    if ($ScanResult.TextLogPath -and -not $script:ScanLogFailed) { Write-ReportRow ('Full report  {0}' -f $ScanResult.TextLogPath) -Color DarkGray -Raw }
}

function Show-OrphanScanResults {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$ScanResult, [switch]$Interactive)
    $findings = @($ScanResult.Findings | Where-Object { $_ })
    $hasFullLog = $ScanResult.TextLogPath -and -not $script:ScanLogFailed
    $page = 0; $pageSize = 10
    do {
        Show-ScanSummary -ScanResult $ScanResult -Review:$Interactive
        Write-ReportRow ''
        Write-ReportTitle 'Candidates' -Meta ('{0} found' -f $findings.Count)
        $safe = @($findings | Where-Object SafeDelete)
        $bytes = ($findings | Measure-Object Size -Sum).Sum
        Write-ReportRow ('{0,-16}{1} · {2:N0} eligible · {3:N0} need review' -f 'Size', (Format-FileSize $bytes), $safe.Count, ($findings.Count - $safe.Count)) -Color Cyan
        Write-ReportRow 'Finding a candidate does not delete it. Age alone does not prove it is unused.' -Color DarkGray
        if (-not $findings.Count) { Write-ReportRow 'No candidates found within the scanned scope.' -Color Gray }
        $start = if ($Interactive) { $page * $pageSize } else { 0 }
        $end = if ($Interactive -or $hasFullLog) { [math]::Min($start + $pageSize, $findings.Count) } else { $findings.Count }
        for ($i = $start; $i -lt $end; $i++) {
            $item = $findings[$i]
            # Two rows per candidate: what it is on one line, where it is on the
            # next. Three rows per item buried the list under its own labels.
            $color = if ($item.SafeDelete) { 'Cyan' } else { 'Yellow' }
            $action = if ($item.SafeDelete) { 'eligible' } else { 'review' }
            Write-ReportRow ('{0,3}  {1,10}  {2,-24} {3,5} d  {4}' -f ($i + 1), (Format-FileSize $item.Size), $item.Category, $item.DaysSinceModified, $action) -Color $color
            Write-ReportRow ('     {0}' -f $item.Path) -Color Gray
        }
        $issues = @($ScanResult.Issues | Where-Object { $_ })
        if ($issues.Count) {
            Write-ReportTitle 'Scan issues' -Meta (Format-Count $issues.Count 'entry')
            foreach ($issue in $issues) {
                Write-ReportRow ('{0,-10}{1}' -f $issue.Kind, $issue.Path) -Color $(if ($issue.Kind -eq 'Error') { 'Red' } else { 'Yellow' })
                Write-ReportRow ('{0}{1}' -f (' ' * 10), $issue.Reason) -Color DarkGray
            }
        }
        if (-not $Interactive) {
            if ($end -lt $findings.Count) { Write-ReportRow ("Showing the largest {0} of {1}. Every candidate and reason is in the full report." -f $end, (Format-Count $findings.Count 'candidate')) -Color Cyan }
            return
        }
        Write-ReportRow ''
        Write-ReportRow ("Page {0}/{1} · N next · P previous · E export · I scan issues · Q return" -f ($page + 1), [math]::Max(1, [math]::Ceiling($findings.Count / $pageSize))) -Color DarkGray
        Write-ReportRow 'Enter item numbers separated by commas to review a selection.' -Color DarkGray
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
                # The same protected path is reported by every walker that meets
                # it. The log keeps each occurrence; the screen shows each once.
                $issues = @($ScanResult.Issues | Where-Object { $_ } | Sort-Object Kind, Path, Reason -Unique)
                Write-ReportTitle 'Scan issues' -Meta ('{0} entries' -f $issues.Count)
                if (-not $issues.Count) { Write-ReportRow 'No scan issues.' -Color Gray }
                foreach ($issue in $issues) {
                    Write-ReportRow ('{0,-10}{1}' -f $issue.Kind, $issue.Path) -Color $(if ($issue.Kind -eq 'Error') { 'Red' } else { 'Yellow' })
                    Write-ReportRow ('{0}{1}' -f (' ' * 10), $issue.Reason) -Color DarkGray
                }
                [void](Read-Host 'Press Enter to return to review'); continue
            }
        }
        if ($choice -notmatch '^\d+(\s*,\s*\d+)*$') { Write-ReviewLine 'Choose a listed command or item number.'; continue }
        try { $numbers = @($choice -split ',' | ForEach-Object { [int]$_.Trim() } | Sort-Object -Unique) }
        catch { Write-ReviewLine 'Item number is out of range.'; continue }
        if (@($numbers | Where-Object { $_ -lt 1 -or $_ -gt $findings.Count }).Count) { Write-ReviewLine 'Item number is out of range.'; continue }
        $selection = @($numbers | ForEach-Object { $findings[$_ - 1] })
        # The one framed screen in the app. It leads with the total, names every
        # path, repeats that there is no undo, and only then asks.
        $frameLines = @(
            "Permanently delete $($selection.Count) item$(if ($selection.Count -eq 1) { '' } else { 's' })?"
            ''
            "$(Format-FileSize (($selection | Measure-Object Size -Sum).Sum)) will be removed from C:\. No recovery copy is kept."
        )
        $frameColors = @('White', 'White', 'Yellow')
        foreach ($item in $selection) {
            $frameLines += $item.Path
            $frameColors += 'White'
            $frameLines += "  $($item.Reason)"
            $frameColors += 'Gray'
        }
        $frameLines += ''
        $frameLines += 'Deletion is permanent. There is no recovery copy.'
        $frameColors += 'Yellow'
        Write-ReviewLine
        Write-ConfirmFrame -Lines $frameLines -Colors $frameColors
        Write-ReviewLine
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

# Bytes that were never measured stay honest instead of printing a zero.
function Format-ReportSize {
    param($Bytes)
    if ($null -eq $Bytes) { 'unknown' } else { Format-FileSize $Bytes }
}

function Show-CleanupResult {
    param([Parameter(Mandatory)]$Result)
    Set-UiContext -Mode $Result.Mode -Result $Result
    $errors = @($Result.Errors | Where-Object { $_ })
    $skips = @($Result.SkippedItems | Where-Object { $_ })
    $comparison = Get-StorageComparison
    Clear-UiProgress
    Write-ReportTitle $(if ($Result.IsPreview) { 'Preview complete' } else { 'Cleanup complete' }) -Meta (Format-ReportDuration $Result.DurationSec)
    if ($Result.IsPreview) {
        Write-ReportRow 'Dry run          nothing was deleted · sizes are estimates' -Color DarkGray
        Write-ReportRow ('Reclaimable      {0} · {1} would change' -f (Format-FileSize $Result.BytesFreed), (Format-Count $Result.PathsCleared 'path')) -Color Cyan
    } else {
        # Observed free-space change next to the measured deleted total: the first
        # is what the drive reports, the second is what Bakunawa removed.
        if ($comparison) {
            $note = if ($comparison.Change -gt 0) { '+{0} freed' -f (Format-FileSize $comparison.Change) }
                elseif ($comparison.Change -lt 0) { '{0} lost' -f (Format-FileSize ([math]::Abs($comparison.Change))) }
                else { 'no change' }
            Write-StorageLine $comparison -Note $note
        }
        Write-ReportRow ('Deleted          {0} on disk · {1} processed' -f (Format-FileSize $Result.BytesFreed), (Format-Count $Result.PathsCleared 'path')) -Color Cyan
        Write-ReportRow ('Blocked          {0} · {1} failed' -f (Format-Count $skips.Count 'path'), (Format-Count $errors.Count 'action')) -Color $(if ($errors.Count -or $skips.Count) { 'Yellow' } else { 'Gray' })
        Write-ReportRow 'Deletion is permanent and the space is reclaimed immediately.' -Color DarkGray
    }
    if ($Result.PSObject.Properties['IsComplete'] -and -not $Result.IsComplete) { Write-ReportRow 'INCOMPLETE: some paths could not be inspected. Elevated runs can identify additional candidates.' -Color Yellow }
    if ($Result.UnknownOutcomePaths) { Write-ReportRow ("{0} failed action(s) could not be remeasured. Confirmed totals are lower bounds." -f $Result.UnknownOutcomePaths) -Color Yellow }
    $categoryRows = @($Result.CategoryReport | Where-Object { $_ })
    if ($categoryRows.Count) {
        Write-ReportTitle 'Identified data' -Meta (Format-ReportSize ([long](($categoryRows | ForEach-Object { $_.IdentifiedBytes } | Where-Object { $null -ne $_ } | Measure-Object -Sum).Sum)))
        foreach ($category in $categoryRows) {
            Write-ReportRow ('{0}{1} identified · {2} acted on · {3} left{4}' -f ('{0,-24}  ' -f (Get-DisplayText $category.Category 24)), (Format-ReportSize $category.IdentifiedBytes), (Format-ReportSize $category.ActedBytes), (Format-ReportSize $category.NotActedBytes), $(if ($category.UnknownSizePaths) { " · $(Format-Count $category.UnknownSizePaths 'unmeasured path')" } else { '' })) -Color DarkGray
            foreach ($reason in @($category.Reasons)) {
                if (-not $reason) { continue }
                Write-ReportRow ('{0}{1,-18}{2}{3}' -f (' ' * 4), $reason.Reason, (Format-ReportSize $reason.Bytes), $(if ($reason.UnknownSizePaths) { " · $(Format-Count $reason.UnknownSizePaths 'unmeasured path')" } else { '' })) -Color DarkGray
            }
        }
    }
    # Grouped by reason: the same explanation repeated per path is noise, and the
    # paths are what the reader is actually scanning for.
    $outcomeRows = @($Result.Outcomes | Where-Object Status -eq 'Skipped')
    if ($outcomeRows.Count) {
        Write-ReportTitle 'Skipped' -Meta (Format-Count $outcomeRows.Count 'item')
        # A full-disk run reports thousands of skips. The screen stays bounded;
        # the full report keeps every path and reason.
        $shownPerReason = 10
        foreach ($group in ($outcomeRows | Group-Object Reason)) {
            $paths = @($group.Group | ForEach-Object Path)
            Write-ReportRow ('{0} · {1}' -f $group.Name, (Format-Count $paths.Count 'path')) -Color Yellow
            foreach ($path in @($paths | Select-Object -First $shownPerReason)) { Write-ReportRow ('{0}{1}' -f (' ' * 4), $path) -Color DarkGray }
            if ($paths.Count -gt $shownPerReason) { Write-ReportRow ('{0}… {1} more in the full report' -f (' ' * 4), ($paths.Count - $shownPerReason)) -Color DarkGray }
        }
    }
    # The category report already breaks the totals down per category; the flat
    # map is only a fallback for runs that produced no per-category detail.
    if (-not $categoryRows.Count -and $Result.CategorySizes.Count) {
        Write-ReportTitle $(if ($Result.IsPreview) { 'Estimated data by category' } else { 'Processed data by category' })
        foreach ($category in ($Result.CategorySizes.GetEnumerator() | Sort-Object Value -Descending)) {
            Write-ReportRow ('{0}{1,10}' -f ('{0,-24}  ' -f (Get-DisplayText $category.Key 24)), (Format-ReportSize $category.Value)) -Color DarkGray
        }
    }
    if ($Result.ScanReport) { Show-ScanSummary -ScanResult $Result.ScanReport }
    else { Write-ReportRow 'Orphan discovery was not run; no drive coverage is reported.' -Color Gray }
    if ($errors.Count) {
        Write-ReportTitle 'Errors' -Meta (Format-Count $errors.Count 'item')
        foreach ($failure in $errors) {
            Write-ReportRow $failure.Path -Color Yellow
            Write-ReportRow ('{0}{1}' -f (' ' * 4), $failure.Error) -Color DarkGray
        }
    }
    if ($skips.Count) {
        Write-ReportTitle 'Blocked' -Meta (Format-Count $skips.Count 'item')
        foreach ($skip in $skips) {
            Write-ReportRow $skip.Target -Color Yellow
            Write-ReportRow ('{0}{1}' -f (' ' * 4), $skip.Reason) -Color DarkGray
        }
    }
    if (Get-ScanLogPath) { Write-ReportRow ('Full report  {0}' -f (Get-ScanLogPath)) -Color Cyan -Raw }
}
