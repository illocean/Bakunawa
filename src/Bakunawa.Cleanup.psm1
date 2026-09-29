. (Join-Path $PSScriptRoot 'Bakunawa.Discovery.ps1')

# Bakunawa.Cleanup.psm1 â€” Cleanup task execution

# Write-Log is provided by Bakunawa.UI.psm1 (imported after this module with -Scope Global)
# so the global Write-Log will be the themed version from UI.psm1.

# NOTE FOR REVIEWERS: Measure-AndClear is the SINGLE error-collection boundary for deletion work.
# Its internal try/catch appends every terminating failure to $script:Errors - callers must NOT
# wrap Measure-AndClear calls in additional try/catch (that would double-collect).

# Private helper: one consistent sink for per-path cleanup errors (collect-errors-and-continue).
function Get-CleanupFailureReason {
    param([string]$Message)
    if ($Message -match 'protected|excluded|reparse|offline|C: only|Refusing to remove') { return 'protected' }
    if ($Message -match 'evidence') { return 'no evidence' }
    if ($Message -match 'used by another|sharing|in use|owning app|close the browser|running app') { return 'in use' }
    if ($Message -match 'Changed since scan') { return 'changed since scan' }
    if ($Message -match 'denied|unauthorized') { return 'access denied' }
    return 'error'
}

function Register-CleanupError {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Path,
        [AllowEmptyString()][string]$Category,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $script:Errors) { $script:Errors = @() }
    $script:Errors += @{
        Path     = $Path
        Category = $(if ($Category) { $Category } else { 'Uncategorized' })
        Error    = $Message
    }
    if ($script:Planning) { Add-CleanupRecord -Path $Path -Category $Category -Reason (Get-CleanupFailureReason $Message) -Detail $Message }
    if (Get-Command Write-ScanLogText -ErrorAction Ignore) { Write-ScanLogText ("CLEANUP ERROR | {0} | {1} | {2}" -f $Category, $Path, $Message) }
}

function Add-CleanupRecord {
    param([string]$Path, [string]$Category, [Nullable[long]]$Bytes, [string]$Reason,
        [string]$Detail, $Measurement, [string]$Detector = 'Cleanup', [string]$Tier = 'Tier1', $Finding)
    if (-not $script:Planning) { return }
    if ($script:ActiveCategory) { $Category = $script:ActiveCategory }
    if (-not $Category) { $Category = 'Discovery' }
    $script:CandidateRecords.Add([pscustomobject]@{
        Path = $Path; Category = $Category; Bytes = $Bytes; Reason = $Reason; Detail = $Detail
        Status = $(if ($Reason) { 'Skipped' } else { 'Eligible' }); Measurement = $Measurement
        Detector = $Detector; Tier = $Tier; Finding = $Finding; ActedBytes = 0L; OutcomeKnown = $true
    })
}

function Test-CleanupDirectory {
    param([string]$Path)
    if (-not $Path) { return $false }
    $issue = [Bakunawa.Scanner]::PathIssue($Path)
    if ($issue -or (Test-IsExcludedPath $Path)) {
        if (-not $issue) { $issue = 'Protected folder or exclusion' }
        Add-CleanupRecord -Path $Path -Reason (Get-CleanupFailureReason $issue) -Detail $issue
        Register-SkippedItem -Target $Path -Reason $issue
        return $false
    }
    try { return (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).PSIsContainer }
    catch [Management.Automation.ItemNotFoundException] { return $false }
    catch { Register-CleanupError -Path $Path -Message $_.Exception.Message; return $false }
}

# Private helper: the single deletion choke point. Re-validates immediately before every
# mutation so nothing is deleted on a stale measurement, and honours preview mode.
# Returns validated bytes for preview or successful processing; failures throw.
function Remove-ItemSafely {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [string]$Reason = 'Cleanup',
        [ValidateSet('Tier1','Tier2','Tier3')][string]$Tier = 'Tier1',
        [string]$DetectorName = 'Cleanup',
        [switch]$Preview
    )
    $script:PartialActedBytes = 0L
    $script:PartialOutcomeKnown = $true
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($resolved -eq [IO.Path]::GetPathRoot($resolved).TrimEnd('\') -or
        $resolved -in @((Get-EnvPath 'USERPROFILE'),(Get-EnvPath 'LOCALAPPDATA'),(Get-EnvPath 'APPDATA'),(Get-EnvPath 'SystemRoot'),(Get-EnvPath 'ProgramData'),(Get-EnvPath 'ProgramFiles'),(Get-EnvPath 'ProgramFiles(x86)'))) {
        throw "Refusing to remove a drive or system/profile root: $resolved"
    }
    $measurement = [Bakunawa.Scanner]::Inspect($resolved, [string[]]@(Get-CoreExcludedPaths))
    if ($script:Planning) {
        Add-CleanupRecord -Path $resolved -Category $Reason -Bytes $measurement.Bytes -Measurement $measurement -Detector $DetectorName -Tier $Tier -Finding $script:CurrentOrphan
        return [long]$measurement.Bytes
    }
    if ($Preview -or $script:IsPreview) { return [long]$measurement.Bytes }
    if ($Tier -eq 'Tier3') { throw "Report-only candidate: $resolved" }
    # Quarantine was removed: every delete is final, which is what actually frees the space.
    # Re-inspect immediately before the mutation so nothing is deleted on a stale measurement.
    $null = [Bakunawa.Scanner]::Inspect($resolved, [string[]]@(Get-CoreExcludedPaths))
    try { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop }
    catch {
        $failure = $_
        try {
            $remaining = [Bakunawa.Scanner]::Inspect($resolved, [string[]]@(Get-CoreExcludedPaths))
            $script:PartialActedBytes = [math]::Max(0, $measurement.Bytes - $remaining.Bytes)
        } catch { $script:PartialOutcomeKnown = $false }
        throw $failure
    }
    if (Test-Path -LiteralPath $resolved) { throw "Target remains after removal: $resolved" }
    return [long]$measurement.Bytes
}

# Recursively expands {placeholder} tokens in a path by enumerating matching
# filesystem entries. Handles paths like <dir>/{profile}/Cache, where
# {profile} maps to Default/Profile 1/Profile 2/etc.
# Returns an array of fully-resolved absolute paths (never returns wildcard).
function Expand-WildcardPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$DirectoriesOnly,
        [switch]$Strict
    )
    if ($Path -notmatch '^C:[\\/]') {
        if ($Strict) { throw "C: only; cannot verify $Path" }
        Add-CleanupRecord -Path $Path -Reason 'protected' -Detail 'C: only'
        return @()
    }
    $patternPath = $Path -replace '\{sub:([^}]+)\}', '$1' -replace '\{profile\}', '*'
    if ($patternPath -match '\{[^}]+\}') { throw "Unknown cleanup path placeholder: $Path" }
    if ($patternPath -notmatch '[*?]' -and -not $Strict) {
        $issue = [Bakunawa.Scanner]::PathIssue($patternPath)
        if (-not $issue) { [IO.Path]::GetFullPath($patternPath) }
        else { Add-CleanupRecord -Path $patternPath -Reason (Get-CleanupFailureReason $issue) -Detail $issue; Register-SkippedItem -Target $patternPath -Reason $issue }
        return
    }
    # Expand one segment at a time so wildcards cannot traverse junctions first.
    $paths = @('C:\')
    foreach ($segment in ($patternPath.Substring(3) -split '[\\/]' | Where-Object { $_ })) {
        $paths = @(foreach ($parent in $paths) {
            try {
                $issue = [Bakunawa.Scanner]::PathIssue($parent)
                if ($issue) { throw $issue }
                if (Test-IsExcludedPath $parent) { throw "Protected path: $parent" }
                if ($segment -match '[*?]' -or $Strict) {
                $pattern = $segment.Replace('[', '`[').Replace(']', '`]')
                foreach ($child in @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop | Where-Object { $_.Name -like $pattern })) {
                    $issue = [Bakunawa.Scanner]::PathIssue($child.FullName)
                    if ($issue) {
                        if ($Strict) { throw $issue }
                        Register-SkippedItem -Target $child.FullName -Reason $issue
                        Add-CleanupRecord -Path $child.FullName -Reason (Get-CleanupFailureReason $issue) -Detail $issue
                    } elseif (-not $DirectoriesOnly -or $child.PSIsContainer) { $child.FullName }
                }
            } else {
                $candidate = Join-Path $parent $segment
                $issue = [Bakunawa.Scanner]::PathIssue($candidate)
                if ($issue) { throw $issue }
                try { $null = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop; $candidate }
                catch [Management.Automation.ItemNotFoundException] { }
            }
            } catch {
                if ($Strict) { throw }
                Register-SkippedItem -Target $parent -Reason $_.Exception.Message
                Add-CleanupRecord -Path $parent -Reason (Get-CleanupFailureReason $_.Exception.Message) -Detail $_.Exception.Message
            }
        })
    }
    $paths
}

# Resolve the age gate for transient (install-staging) entries. Mirrors the orphan
# discovery contract: scanSettings.minAgeDays, or aggressiveMinAgeDays in Aggressive
# mode. A positive per-definition override wins.
function Get-TransientAgeDays {
    [CmdletBinding()]
    param([ValidateRange(0, 3650)][int]$Override = 0)
    if ($Override -gt 0) { return $Override }
    $days = 30
    $cfg = $script:CleanupConfig
    if ($cfg -and $cfg.scanSettings) {
        if ($cfg.scanSettings.minAgeDays) { $days = [int]$cfg.scanSettings.minAgeDays }
        if ($script:IsAggressive -and $cfg.scanSettings.aggressiveMinAgeDays) { $days = [int]$cfg.scanSettings.aggressiveMinAgeDays }
    }
    if ($days -lt 1 -or $days -gt 3650) { $days = 30 }
    return $days
}

# Human-readable detail for a skip decided by Get-TransientEntryMatches.
function Get-TransientSkipDetail {
    param([string]$Reason, [int]$MinAgeDays)
    switch ($Reason) {
        'protected' { 'Protected folder or exclusion' }
        'in use'    { 'Owning application is running' }
        'not stale' { "Newest write is less than $MinAgeDays days old; an install may be in progress" }
        default     { $Reason }
    }
}

# Read-only enumeration of disposable entries directly inside a container directory.
# Unlike Expand-WildcardPath this matches names only, never descends, and reports why
# a match would be skipped so callers log the same decision they act on.
function Get-TransientEntryMatches {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Directory,
        [Parameter(Mandatory)][string[]]$Patterns,
        [ValidateSet('any','file','directory')][string]$EntryType = 'any',
        [ValidateRange(0, 3650)][int]$MinAgeDays = 0
    )
    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    # A missing container is normal: the tool simply is not installed here.
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    if (-not [Bakunawa.Scanner]::IsAllowedPath($Directory)) {
        Register-SkippedItem -Reason ([Bakunawa.Scanner]::PathIssue($Directory)) -Target $Directory
        return
    }
    $cutoff = if ($MinAgeDays -gt 0) { (Get-Date).AddDays(-$MinAgeDays) } else { $null }
    try { $entries = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop) }
    catch { Register-CleanupError -Path $Directory -Message $_.Exception.Message; return }
    foreach ($entry in $entries) {
        $matched = $false
        foreach ($pattern in $Patterns) { if ($entry.Name -like $pattern) { $matched = $true; break } }
        if (-not $matched) { continue }
        if ($EntryType -eq 'directory' -and -not $entry.PSIsContainer) { continue }
        if ($EntryType -eq 'file' -and $entry.PSIsContainer) { continue }
        $reason = $null
        if (Test-IsExcludedPath $entry.FullName) { $reason = 'protected' }
        elseif ($cutoff -and $entry.LastWriteTime -ge $cutoff) { $reason = 'not stale' }
        elseif ($script:BusyCachePaths) {
            foreach ($busy in $script:BusyCachePaths) {
                if ([Bakunawa.Scanner]::Within($entry.FullName, $busy) -or [Bakunawa.Scanner]::Within($busy, $entry.FullName)) { $reason = 'in use'; break }
            }
        }
        $bytes = $null
        try { $bytes = [long]([Bakunawa.Scanner]::Inspect($entry.FullName, [string[]]@(Get-CoreExcludedPaths))).Bytes } catch { }
        [PSCustomObject]@{ FullName = $entry.FullName; Name = $entry.Name; Bytes = $bytes; IsContainer = [bool]$entry.PSIsContainer; Reason = $reason }
    }
}

# Check-then-delete for install-staging leftovers. Measure-AndClear cannot do this job:
# it clears a directory's children and ignores non-containers, so a staging file would
# survive and a staging folder's container would be emptied instead of the folder.
function Clear-TransientEntries {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Directory,
        [Parameter(Mandatory)][string[]]$Patterns,
        [ValidateSet('any','file','directory')][string]$EntryType = 'any',
        [ValidateRange(0, 3650)][int]$MinAgeDays = 0,
        [string]$Category = 'Dev Caches'
    )
    $count = 0
    foreach ($match in @(Get-TransientEntryMatches -Directory $Directory -Patterns $Patterns -EntryType $EntryType -MinAgeDays $MinAgeDays)) {
        if ($match.Reason) {
            $detail = Get-TransientSkipDetail -Reason $match.Reason -MinAgeDays $MinAgeDays
            Register-SkippedItem -Reason $detail -Target $match.FullName -Category $Category -Bytes $match.Bytes
            Add-CleanupRecord -Path $match.FullName -Category $Category -Bytes $match.Bytes -Reason $match.Reason -Detail $detail
            continue
        }
        try {
            $size = Remove-ItemSafely -Path $match.FullName -Reason $Category -Preview:$script:IsPreview
            $script:BytesFreed += $size
            $script:TaskBytes += $size
            $script:TaskCleared++
            if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
            if (-not $script:CategorySizes.ContainsKey($Category)) { $script:CategorySizes[$Category] = [long]0 }
            $script:CategorySizes[$Category] += [long]$size
            Write-CommandLog $(if ($script:IsPreview) { 'PREVIEW' } else { 'PROCESSED' }) "$($match.FullName) ($(Format-FileSize $size))"
            $count++
        } catch {
            Register-CleanupError -Path $match.FullName -Category $Category -Message $_.Exception.Message
        }
    }
    return $count
}

# Read-only accessor for collected cleanup errors (post-run reporting / diagnostics).
# Emits elements directly - callers normalize with @(); do NOT comma-wrap (double-wrap bug).
function Get-CleanupErrorLog {
    [CmdletBinding()]
    param()
    if ($script:Errors) { return @($script:Errors) }
}

function Measure-AndClear {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path, [switch]$EnsureDirectory, [AllowEmptyString()][string]$Category)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not [Bakunawa.Scanner]::IsAllowedPath($Path)) {
        Register-SkippedItem -Reason 'C: only; linked, offline or inaccessible paths are skipped' -Target $Path
        $script:TaskSkipped++
        Add-CleanupRecord -Path $Path -Category $Category -Reason (Get-CleanupFailureReason ([Bakunawa.Scanner]::PathIssue($Path))) -Detail ([Bakunawa.Scanner]::PathIssue($Path))
        return $false
    }
    $Path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($script:ProcessedCacheRoots -and $script:ProcessedCacheRoots.Contains($Path)) { return $false }
    foreach ($busy in $script:BusyCachePaths) {
        if ([Bakunawa.Scanner]::Within($Path, $busy) -or [Bakunawa.Scanner]::Within($busy, $Path)) {
            Register-SkippedItem -Reason 'Close the owning app to clean this cache' -Target $Path
            $script:TaskSkipped++
            $bytes = $null
            try { $bytes = ([Bakunawa.Scanner]::Inspect($Path, [string[]]@(Get-CoreExcludedPaths))).Bytes } catch { }
            Add-CleanupRecord -Path $Path -Category $Category -Bytes $bytes -Reason 'in use' -Detail 'Owning application is running'
            return $false
        }
    }
    if (Test-IsExcludedPath $Path) {
        Register-SkippedItem -Reason 'Path is excluded from cleanup' -Target $Path
        $script:TaskSkipped++
        Add-CleanupRecord -Path $Path -Category $Category -Reason 'protected' -Detail 'Protected folder or exclusion'
        return $false
    }
    try {
        try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
        catch [Management.Automation.ItemNotFoundException] { return $false }
        if (-not $item.PSIsContainer) { return $false }
        Write-ReviewLine ("{0}: {1}" -f $(if ($script:IsPreview) { 'Measuring' } else { 'Processing' }), $Path) -ForegroundColor Gray
        # Preserve the cache root and process siblings independently when one is locked.
        $size = 0L; $processed = 0
        foreach ($item in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
            try {
                $size += Remove-ItemSafely -Path $item.FullName -Reason $(if ($Category) { $Category } else { 'Cache cleanup' }) -Preview:$script:IsPreview
                $processed++
            } catch { Register-CleanupError -Path $item.FullName -Category $Category -Message $_.Exception.Message }
        }
        if ($processed -eq 0) { return $false }
        if ($null -eq $script:ProcessedCacheRoots) { $script:ProcessedCacheRoots = New-TrackedSet }
        [void]$script:ProcessedCacheRoots.Add($Path)
        $script:BytesFreed += $size
        if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
        if ($Category) { $script:CategorySizes[$Category] += $size }
        $script:TaskCleared++; $script:TaskBytes += $size
        Write-CommandLog $(if ($script:IsPreview) { 'PREVIEW' } else { 'PROCESSED' }) "$Path ($(Format-FileSize $size))"
        return $true
    } catch {
        Register-CleanupError -Path $Path -Category $Category -Message $_.Exception.Message
        return $false
    }
}

function Get-CleanupTasks {
    [CmdletBinding()]
    param([ValidateSet('Standard','Aggressive')][string]$Mode = 'Standard')
    $tasks = [System.Collections.Generic.List[System.Object]]::new()
    $null = $tasks.Add([PSCustomObject]@{ Name = 'System Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Browser Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'App Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Dev Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Game Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Browser Automation Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Package Manager Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Cloud Sync'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Creative Apps'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Productivity'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'DevOps Tools'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'GPU/Shell Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Recycle Bin'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Thumbnail Cache'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Log Files'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Empty/Stale Folders'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Orphan Scan'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'User Hidden Folders'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Scoop Cache'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Rust Cargo Cache'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Go Module Cache'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Bun Cache'; Parallel = $false })
    return @($tasks)
}

function Get-CleanupPotential {
    [CmdletBinding()]
    param([ValidateSet('Standard','Aggressive')][string]$Mode = 'Standard', [string]$TaskName)
    $results = [System.Collections.Generic.List[System.Object]]::new()
    $tasks = Get-CleanupTasks -Mode $Mode
    if ($TaskName) { $tasks = @($tasks | Where-Object { $_.Name -eq $TaskName }) }
    foreach ($task in $tasks) {
        $taskName = $task.Name
        $status = 'ok'
        $bytes = 0L
        $count = 0
        switch ($taskName) {
            'System Caches' {
                foreach ($t in @((Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'), $script:SysLoc.WindowsTemp)) {
                    if ($t -and (Test-Path -LiteralPath $t -PathType Container)) {
                        $bytes += Get-DirectorySize $t
                        $count++
                    }
                }
            }
            'Browser Caches' {
                # Source from app definitions so Brave/Opera/Vivaldi/etc. are
                # fully covered (the prior hardcoded list missed them).
                $applist = Get-AllAppDefinitions -Category 'Browser Caches'
                foreach ($app in $applist) {
                    if (-not $app.Path) { continue }
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME
                    $expandedPath = $expandedPath -replace '{appdata}', $env:APPDATA
                    $expandedPath = $expandedPath -replace '{localappdata}', $env:LOCALAPPDATA
                    $expandedPath = $expandedPath -replace '{programdata}', $env:PROGRAMDATA
                    $expandedPath = $expandedPath -replace '{systemdrive}', $env:SYSTEMDRIVE
                    foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $resolved -PathType Container) {
                            $bytes += Get-DirectorySize $resolved
                            $count++
                        }
                    }
                }
            }
            'App Caches' {
                $applist = Get-AllAppDefinitions -Category 'App Caches'
                foreach ($app in $applist) {
                    if (-not $app.Name) { continue }
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME
                    $expandedPath = $expandedPath -replace '{appdata}', $env:APPDATA
                    $expandedPath = $expandedPath -replace '{localappdata}', $env:LOCALAPPDATA
                    $expandedPath = $expandedPath -replace '{programdata}', $env:PROGRAMDATA
                    $expandedPath = $expandedPath -replace '{commonprogramfiles}', $env:COMMONPROGRAMFILES
                    $expandedPath = $expandedPath -replace '{systemdrive}', $env:SYSTEMDRIVE
                    $expandedPath = $expandedPath -replace '{windows}', $env:WINDIR
                    foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $resolved -PathType Container) {
                            $bytes += Get-DirectorySize $resolved
                            $count++
                        }
                    }
                }
            }
            'Dev Caches' {
                foreach ($d in @(
                    (Join-EnvPath 'LOCALAPPDATA' 'npm' '_logs'),
                    (Join-EnvPath 'LOCALAPPDATA' 'pip' 'Cache'),
                    (Join-EnvPath 'LOCALAPPDATA' 'Yarn' 'Cache')
                )) {
                    if ($d -and (Test-Path -LiteralPath $d -PathType Container)) {
                        $bytes += Get-DirectorySize $d
                        $count++
                    }
                }
                # Process every Dev Caches app definition across app-definitions/*.json
                $extendedDefs = Get-AllAppDefinitions -Category 'Dev Caches'
                foreach ($app in $extendedDefs) {
                    if (-not $app.Name) { continue }
                    try {
                        $expandedPath = $app.Path -replace '{username}',$env:USERNAME
                        $expandedPath = $expandedPath -replace '{appdata}', $env:APPDATA
                        $expandedPath = $expandedPath -replace '{localappdata}', $env:LOCALAPPDATA
                        $expandedPath = $expandedPath -replace '{programdata}', $env:PROGRAMDATA
                        $expandedPath = $expandedPath -replace '{commonprogramfiles}', $env:COMMONPROGRAMFILES
                        $expandedPath = $expandedPath -replace '{systemdrive}', $env:SYSTEMDRIVE
                        $expandedPath = $expandedPath -replace '{windows}', $env:WINDIR
                        # Entry-mode locations name a container of disposable leftovers.
                        # Measuring the container itself would report unrelated data.
                        if ($app.Mode -eq 'entry') {
                            if (-not $app.EntryPatterns) { continue }
                            $ageDays = Get-TransientAgeDays -Override $app.MinAgeDays
                            foreach ($match in @(Get-TransientEntryMatches -Directory $expandedPath -Patterns @($app.EntryPatterns) -EntryType $app.EntryType -MinAgeDays $ageDays)) {
                                if ($match.Reason -or $null -eq $match.Bytes) { continue }
                                $bytes += [long]$match.Bytes
                                $count++
                            }
                            continue
                        }
                        foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                            if (Test-Path -LiteralPath $resolved -PathType Container) {
                                $bytes += Get-DirectorySize $resolved
                                $count++
                            }
                        }
                    } catch {
                        Register-CleanupError -Path $expandedPath -Category 'Potential Scan' -Message $_.Exception.Message
                    }
                }
            }
            'User Hidden Folders' {
                foreach ($h in @((Join-EnvPath 'USERPROFILE' '.local'), (Join-EnvPath 'USERPROFILE' '.cache'), (Join-EnvPath 'LOCALAPPDATA' '.cache'))) {
                    if ($h -and (Test-Path -LiteralPath $h -PathType Container)) {
                        $bytes += Get-DirectorySize $h
                        $count++
                    }
                }
            }
            'Scoop Cache' {
                $scoopDir = (Join-EnvPath 'USERPROFILE' 'scoop' 'cache')
                if ($scoopDir -and (Test-Path -LiteralPath $scoopDir -PathType Container)) {
                    $bytes += Get-DirectorySize $scoopDir
                    $count++
                }
                $scoopApps = (Join-EnvPath 'USERPROFILE' 'scoop' 'apps')
                if ($scoopApps -and (Test-Path -LiteralPath $scoopApps -PathType Container)) {
                    $bytes += Get-DirectorySize $scoopApps
                    $count++
                }
            }
            'Rust Cargo Cache' {
                $cargoDir = (Join-EnvPath 'USERPROFILE' '.cargo')
                if ($cargoDir -and (Test-Path -LiteralPath $cargoDir -PathType Container)) {
                    $bytes += Get-DirectorySize $cargoDir
                    $count++
                }
            }
            'Go Module Cache' {
                $goDir = (Join-EnvPath 'USERPROFILE' 'go' 'pkg' 'mod')
                if ($goDir -and (Test-Path -LiteralPath $goDir -PathType Container)) {
                    $bytes += Get-DirectorySize $goDir
                    $count++
                }
                $goSumDir = (Join-EnvPath 'USERPROFILE' 'go' 'pkg' 'sumdb')
                if ($goSumDir -and (Test-Path -LiteralPath $goSumDir -PathType Container)) {
                    $bytes += Get-DirectorySize $goSumDir
                    $count++
                }
            }
            'Bun Cache' {
                $bunDir1 = (Join-EnvPath 'USERPROFILE' '.bun' 'install' 'cache')
                $bunDir2 = (Join-EnvPath 'LOCALAPPDATA' 'bun' 'install' 'cache')
                foreach ($bd in @($bunDir1, $bunDir2)) {
                    if ($bd -and (Test-Path -LiteralPath $bd -PathType Container)) {
                        $bytes += Get-DirectorySize $bd
                        $count++
                    }
                }
            }
            { $_ -in @('Game Caches','Browser Automation Caches') } {
                foreach ($app in @(Get-AllAppDefinitions -Category $taskName)) {
                    foreach ($path in @(Expand-WildcardPath -Path $app.Path -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $path -PathType Container) {
                            $bytes += Get-DirectorySize $path
                            $count++
                        }
                    }
                }
            }
            'Package Manager Caches' {
                foreach ($pmc in @(
                    (Join-EnvPath 'APPDATA' 'npm-cache'),
                    (Join-EnvPath 'LOCALAPPDATA' 'pip\Cache'),
                    (Join-EnvPath 'USERPROFILE' 'AppData\Local\pip\Cache'),
                    (Join-EnvPath 'USERPROFILE' '.cache\huggingface'),
                    (Join-EnvPath 'LOCALAPPDATA' 'huggingface\cache')
                )) {
                    if ($pmc -and (Test-Path -LiteralPath $pmc -PathType Container)) {
                        $bytes += Get-DirectorySize $pmc
                        $count++
                    }
                }
            }
            'GPU/Shell Caches' {
                foreach ($g in @((Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'DXCache'))) {
                    if ($g -and (Test-Path -LiteralPath $g -PathType Container)) {
                        $bytes += Get-DirectorySize $g
                        $count++
                    }
                }
            }
            'Log Files' {
                # Must mirror Clear-SystemLogFiles: event logs and C:\Windows\Logs are
                # retained, so measuring them here would over-report the category.
                foreach ($l in @((Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'WebCache'),
                                  (Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'IECompatCache'))) {
                    if ($l -and (Test-Path -LiteralPath $l -PathType Container)) {
                        $bytes += Get-DirectorySize $l
                        $count++
                    }
                }
            }
            'Thumbnail Cache' {
                $thumbDir = (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Windows\Explorer')
                if ($thumbDir -and (Test-Path -LiteralPath $thumbDir -PathType Container)) {
                    $bytes += Get-DirectorySize $thumbDir
                    $count++
                }
            }
            'Empty/Stale Folders' {
                # Measure empty directories in approved stale-cleanup roots
                $staleRoots = @(
                    (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
                    (Join-EnvPath 'APPDATA' 'Microsoft' 'Windows' 'Recent')
                )
                foreach ($root in $staleRoots) {
                    if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
                        try {
                            $emptyDirs = @([Bakunawa.Scanner]::Walk($root, [string[]]@(Get-CoreExcludedPaths)) |
                                Where-Object { $_.Kind -eq 'EmptyDirectory' -and $_.Complete })
                            foreach ($dir in $emptyDirs) {
                                $bytes += 0  # Empty dirs are 0 bytes, but count them
                                $count++
                            }
                        } catch {
                            # Silently continue on access errors
                        }
                    }
                }
            }
            'Orphan Scan' {
                # Call Phase 3's rewritten Find-OrphanFolders to get real orphan findings (Tier1+2/3)
                try {
                    $orphanFindings = Find-OrphanFolders
                    if ($orphanFindings) {
                        foreach ($orphan in $orphanFindings) {
                            $bytes += $orphan.Size
                            $count++
                        }
                    }
                } catch {
                    Register-CleanupError -Path 'Orphan Scan' -Category 'Orphan Scan' -Message $_.Exception.Message
                    $bytes = 0
                    $count = 0
                }
            }
            'Cloud Sync' {
                $applist = Get-AllAppDefinitions -Category 'Cloud Sync'
                foreach ($app in $applist) {
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                    foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $resolved -PathType Container) {
                            $bytes += Get-DirectorySize $resolved
                            $count++
                        }
                    }
                }
            }
            'Creative Apps' {
                $applist = Get-AllAppDefinitions -Category 'Creative Apps'
                foreach ($app in $applist) {
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                    foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $resolved -PathType Container) {
                            $bytes += Get-DirectorySize $resolved
                            $count++
                        }
                    }
                }
            }
            'Productivity' {
                $applist = Get-AllAppDefinitions -Category 'Productivity'
                foreach ($app in $applist) {
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                    foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $resolved -PathType Container) {
                            $bytes += Get-DirectorySize $resolved
                            $count++
                        }
                    }
                }
            }
            'DevOps Tools' {
                $applist = Get-AllAppDefinitions -Category 'DevOps Tools'
                foreach ($app in $applist) {
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                    foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $resolved -PathType Container) {
                            $bytes += Get-DirectorySize $resolved
                            $count++
                        }
                    }
                }
            }
            'Recycle Bin' {
                $bytes = Get-DirectorySize -Path 'C:\$Recycle.Bin'
            }
        }
        [void]$results.Add([PSCustomObject]@{
            Task = $taskName
            Target = $taskName
            EstimatedBytes = $bytes
            FileCount = $count
            Status = $status
        })
    }
    return @($results | Sort-Object EstimatedBytes -Descending)
}
function Remove-FilesByPattern {
    [CmdletBinding()]
    param([ValidateNotNullOrEmpty()][string]$Directory, [ValidateNotNullOrEmpty()][string[]]$Patterns, [string]$Category = 'General')
    if (-not (Test-CleanupDirectory $Directory)) { return 0 }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push([IO.Path]::GetFullPath($Directory))
    $count = 0
    while ($pending.Count) {
        $current = $pending.Pop()
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Test-IsExcludedPath $current)) { continue }
            foreach ($child in (Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
                if ($child.PSIsContainer) { $pending.Push($child.FullName); continue }
                $matches = $false
                foreach ($pattern in $Patterns) { if ($child.Name -like $pattern) { $matches = $true; break } }
                if (-not $matches) { continue }
                try {
                    $size = Remove-ItemSafely -Path $child.FullName -Reason $Category -Preview:$script:IsPreview
                    $script:BytesFreed += $size; $script:TaskBytes += $size; $script:TaskCleared++
                    if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
                    $script:CategorySizes[$Category] += $size
                    $count++
                } catch { Register-CleanupError -Path $child.FullName -Category $Category -Message $_.Exception.Message }
            }
        } catch { Register-CleanupError -Path $current -Category $Category -Message $_.Exception.Message }
    }
    return $count
}

# True when every direct child of a directory predates the configured cleanup age.
# Guards the conventional scratch roots (C:\temp, C:\tmp), which routinely hold a user's
# own install-staging and scratch files and must not be swept just because they are named
# like a temp directory.
function Test-DirectoryFullyStale {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $cutoff = (Get-Date).AddDays(-(Get-TransientAgeDays))
    $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    if ($children.Count -eq 0) { return $true }
    foreach ($child in $children) { if ($child.LastWriteTime -ge $cutoff) { return $false } }
    return $true
}

function Clear-SystemCaches {
    [CmdletBinding()]
    param()
    $cat = 'System Caches'; $n = 0
    # C:\temp and C:\tmp are conventional scratch roots, not owned temp directories. Only
    # sweep them when nothing in them has been touched since the configured cleanup age.
    foreach ($scratch in @((Join-Path (Get-EnvPath 'SystemDrive') 'temp'),
                            (Join-Path (Get-EnvPath 'SystemDrive') 'tmp'))) {
        if ($scratch -and (Test-Path -LiteralPath $scratch -PathType Container) -and -not (Test-DirectoryFullyStale $scratch)) {
            Register-SkippedItem -Reason 'Scratch root has recent files; not swept as system cache' -Target $scratch
        }
    }
    # Resolve then dedupe: %TEMP% and %LOCALAPPDATA%\Temp are usually the same directory
    $targets = @(
        (Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        $script:SysLoc.WindowsTemp, (Join-EnvPath 'LOCALAPPDATA' 'CrashDumps'),
        $script:SysLoc.WerArchive, $script:SysLoc.WerQueue, $script:SysLoc.NetDownloader,
        (Join-Path (Get-EnvPath 'SystemDrive') 'temp'),
        (Join-Path (Get-EnvPath 'SystemDrive') 'tmp')
    ) | Where-Object { $_ } | ForEach-Object { Resolve-FullPath $_ } |
        Where-Object { $_ -notmatch '^[A-Za-z]:\\(temp|tmp)$' -or (Test-DirectoryFullyStale $_) } |
        Select-Object -Unique
    foreach ($t in $targets) { if ($t -and (Measure-AndClear $t -EnsureDirectory -Category $cat)) { $n++ } }
    if (-not [Bakunawa.Scanner]::IsAllowedPath($script:SysLoc.WindowsRoot)) { return $n }
    $restart = @()
    try {
        foreach ($svc in 'wuauserv','bits','dosvc') {
            $s = Get-Service $svc -EA SilentlyContinue
            if ($s -and $s.Status -ne 'Stopped') {
                Write-CommandLog ($(if($script:IsPreview){'PREVIEW stop'}else{'STOP'})) $svc
                if (-not $script:IsPreview) { Stop-Service $svc -Force -EA SilentlyContinue; $restart += $svc }
            }
        }
        if ($script:SysLoc.SoftDistDL -and (Measure-AndClear $script:SysLoc.SoftDistDL -EnsureDirectory -Category $cat)) { $n++ }
        if ($script:SysLoc.DeliveryOpt -and (Measure-AndClear $script:SysLoc.DeliveryOpt -EnsureDirectory -Category $cat)) { $n++ }
    } finally {
        foreach ($svc in $restart) { Write-CommandLog 'START' $svc; Start-Service $svc -EA SilentlyContinue }
    }
    $n
}

function Clear-ChromiumCaches {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$UserDataRoot, [AllowEmptyString()][string]$Label)
    $cat = 'Browser Caches'; $n = 0

    # If no UserDataRoot provided, scan default Chromium locations
    if ([string]::IsNullOrWhiteSpace($UserDataRoot)) {
        $chromiumPaths = @(
            (Join-EnvPath 'LOCALAPPDATA' 'Google' 'Chrome' 'User Data'),
            (Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Edge' 'User Data'),
            (Join-EnvPath 'LOCALAPPDATA' 'BraveSoftware' 'Brave-Browser' 'User Data'),
            (Join-EnvPath 'APPDATA' 'Opera Software' 'Opera Stable'),
            (Join-EnvPath 'LOCALAPPDATA' 'Vivaldi' 'User Data')
        )
        foreach ($path in $chromiumPaths) {
            if (Test-Path -LiteralPath $path -PathType Container) {
                $result = Clear-ChromiumCaches -UserDataRoot $path -Label (Split-Path -Leaf $path)
                $n += $result
            }
        }
        return $n
    }

    if (-not [Bakunawa.Scanner]::IsAllowedPath($UserDataRoot) -or -not (Test-Path -LiteralPath $UserDataRoot -PathType Container)) { return 0 }
    $running = if ($script:RunningProcesses) { $script:RunningProcesses } else { Get-RunningProcessNames }
    $processNames = switch ($Label) { 'Chrome' { @('chrome') } 'Edge' { @('msedge') } 'Brave' { @('brave') } 'Opera' { @('opera') } 'Vivaldi'{ @('vivaldi') } default { @() } }
    if ($processNames.Count -gt 0 -and (Test-AnyProcessRunning -RunningProcesses $running -Names $processNames)) {
        Register-SkippedItem -Reason 'close the browser for a deeper cache cleanup' -Target $Label
        return 0
    }

    $cacheDirs = @('Cache','Code Cache','GPUCache','Media Cache','DawnCache','ShaderCache','GrShaderCache','GraphiteDawnCache','DawnWebGPUCache','Crashpad')

    # Iterate every profile subdirectory (Default, Profile 1, ...) so per-profile
    # caches are actually reached. Fall back to root-level cache dirs only when
    # the root has no profile subdirectories at all (very old profiles).
    $profileDirs = @(Get-ChildItem -LiteralPath $UserDataRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -like 'Guest Profile' })
    $targets = if ($profileDirs.Count -gt 0) {
        $profileDirs
    } else {
        @([pscustomobject]@{ FullName = $UserDataRoot })
    }

    foreach ($prof in $targets) {
        foreach ($d in $cacheDirs) {
            $p = Join-Path $prof.FullName $d
            if ($p -and (Measure-AndClear $p -EnsureDirectory -Category $cat)) { $n++ }
        }
    }
    return $n
}

function Clear-FirefoxCaches {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ProfileRoot)
    $cat = 'Browser Caches'; $n = 0
    if (-not (Test-Path -LiteralPath $ProfileRoot -PathType Container)) { return 0 }
    $cacheDirs = @('cache2','thumbnails','startupCache','shader-cache')
    foreach ($d in $cacheDirs) {
        $p = Join-Path $ProfileRoot $d
        if ($p -and (Measure-AndClear $p -EnsureDirectory -Category $cat)) { $n++ }
    }
    return $n
}

function Clear-AppCaches {
    [CmdletBinding()]
    param()
    $applist = Get-AllAppDefinitions -Category 'App Caches'
    $cat = 'App Caches'; $total = 0

    foreach ($app in $applist) {
        # Skip if any required fields are missing
        if (-not $app.Name) { continue }

        # Expand wildcards in path
        try {
            $expandedPath = $app.Path -replace '\{username\}',$env:USERNAME
            $expandedPath = $expandedPath -replace '\{appdata\}', $env:APPDATA
            $expandedPath = $expandedPath -replace '\{localappdata\}', $env:LOCALAPPDATA
            $expandedPath = $expandedPath -replace '\{programdata\}', $env:PROGRAMDATA
            $expandedPath = $expandedPath -replace '\{commonprogramfiles\}', $env:COMMONPROGRAMFILES
            $expandedPath = $expandedPath -replace '\{systemdrive\}', $env:SYSTEMDRIVE
            $expandedPath = $expandedPath -replace '\{windows\}', $env:WINDIR

            $appsubcat = "$($app.Name) - $($app.Category)"
            foreach ($resolvedPath in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                if ($resolvedPath) {
                    if (Measure-AndClear $resolvedPath -Category $appsubcat) { $total++ }
                }
            }
        } catch {
            Register-CleanupError -Path $expandedPath -Category $appsubcat -Message $_.Exception.Message
        }
    }
    return $total
}

function Clear-DevCaches {
    [CmdletBinding()]
    param()
    # Wildcard patterns must never be pushed through Join-EnvPath: it normalises the
    # result with [IO.Path]::GetFullPath, which rejects '*' and returns $null. Passing
    # that $null to Expand-WildcardPath's mandatory [string] parameter threw a
    # *terminating* error, aborting this function before the definitions loop below ever
    # ran. Build the wildcard entries from the resolved parent instead, and skip any
    # entry that still failed to resolve so one missing variable cannot sink the arm.
    $tempRoot = Join-EnvPath 'LOCALAPPDATA' 'Temp'
    $devDirs = @(
        (Join-EnvPath 'LOCALAPPDATA' 'npm' '_logs'),
        (Join-EnvPath 'LOCALAPPDATA' 'pip' 'Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'NuGet' 'v3' 'http-cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Yarn' 'Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'LOCALAPPDATA' 'pip' 'Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'dotnet' 'NuGet' 'v2' 'http-cache'),
        (Join-EnvPath 'APPDATA' 'Code' 'Cache'),
        $(if ($tempRoot) { Join-Path $tempRoot 'npm-*' }),
        $(if ($tempRoot) { Join-Path $tempRoot 'yarn-*' }),
        (Join-EnvPath 'USERPROFILE' '.android' 'cache')
    )
    $cat = 'Dev Caches'; $n = 0
    foreach ($d in $devDirs) {
        if (-not $d) { continue }
        foreach ($path in @(Expand-WildcardPath -Path $d -DirectoriesOnly)) {
            if ($path -and (Measure-AndClear $path -Category $cat)) { $n++ }
        }
    }

    # Process every Dev Caches app definition across app-definitions/*.json
    $extendedDefs = Get-AllAppDefinitions -Category 'Dev Caches'
    foreach ($app in $extendedDefs) {
        if (-not $app.Name) { continue }
        try {
            $expandedPath = $app.Path -replace '{username}',$env:USERNAME
            $expandedPath = $expandedPath -replace '{appdata}',$env:APPDATA
            $expandedPath = $expandedPath -replace '{localappdata}',$env:LOCALAPPDATA
            $expandedPath = $expandedPath -replace '{programdata}',$env:PROGRAMDATA
            $expandedPath = $expandedPath -replace '{commonprogramfiles}',$env:COMMONPROGRAMFILES
            $expandedPath = $expandedPath -replace '{systemdrive}',$env:SYSTEMDRIVE
            $expandedPath = $expandedPath -replace '{windows}',$env:WINDIR

            # Entry-mode locations hold disposable leftovers, not a cache root. They must
            # never reach Measure-AndClear: that would clear the container's children,
            # deleting the tool's own files (the npm prefix holds its shims).
            if ($app.Mode -eq 'entry') {
                if ($app.EntryPatterns) {
                    $n += Clear-TransientEntries -Directory $expandedPath -Patterns @($app.EntryPatterns) `
                        -EntryType $app.EntryType -MinAgeDays (Get-TransientAgeDays -Override $app.MinAgeDays) -Category $cat
                }
                continue
            }

            foreach ($resolvedPath in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                if ($resolvedPath) {
                    if (Measure-AndClear $resolvedPath -Category "$cat - $($app.Name)") { $n++ }
                }
            }
        } catch {
            Register-CleanupError -Path $expandedPath -Category $cat -Message $_.Exception.Message
        }
    }
    return $n
}

function Clear-GpuAndShellCaches {
    [CmdletBinding()]
    param()
    $locations = @(
        (Join-EnvPath 'LOCALAPPDATA' 'NVIDIA' 'DXCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'NVIDIA' 'GLCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'AMD' 'DxCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'AMD' 'VkCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'D3DSCache')
    )
    $cat = 'GPU/Shell Caches'; $n = 0
    foreach ($loc in $locations) {
        if ($loc -and (Measure-AndClear $loc -Category $cat)) { $n++ }
    }
    return $n
}

function Clear-RecycleBinSafe {
    [CmdletBinding()]
    param()
    if ($script:Planning) {
        try {
            foreach ($directory in @(Get-ChildItem -LiteralPath 'C:\$Recycle.Bin' -Directory -Force -ErrorAction Stop)) {
                $null = Measure-AndClear -Path $directory.FullName -Category 'Recycle Bin'
            }
        } catch { Register-CleanupError -Path 'C:\$Recycle.Bin' -Category 'Recycle Bin' -Message $_.Exception.Message }
        return $true
    }
    try {
        $recycleBin = 0
        if (-not $script:IsPreview) {
            Clear-RecycleBin -DriveLetter C -Force -ErrorAction Stop
        }
          Write-CommandLog "CLEAR $(if($script:IsPreview){'PREVIEW'}else{''})" 'Recycle Bin on C:'
          return $true
      } catch {
          Register-CleanupError -Path 'Recycle Bin' -Category 'Recycle Bin' -Message $_.Exception.Message
          return $false
      }
}

function Clear-SystemLogFiles {
    [CmdletBinding()]
    param()
    # Windows event logs and C:\Windows\Logs are diagnostics, not junk. Deleting them
    # destroys forensic history and WEF continuity, and the live .evtx files are protected
    # only by an OS file lock, so a partial delete is the normal outcome. Retention is a
    # user decision; report these as retained instead of clearing them.
    Register-SkippedItem -Reason 'Windows event logs and C:\Windows\Logs are retained as diagnostics' -Target "$env:SystemRoot\System32\winevt\Logs"
    Register-SkippedItem -Reason 'Windows event logs and C:\Windows\Logs are retained as diagnostics' -Target "$env:SystemRoot\Logs"
    $logDirs = @(
        (Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'WebCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'IECompatCache')
    )
    $cat = 'Log Files'; $n = 0
    foreach ($logDir in $logDirs) {
        if ($logDir -and (Measure-AndClear $logDir -Category $cat)) { $n++ }
    }
    return $n
}

function Remove-EmptyDirectories {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$RootPath)
    if (-not (Test-CleanupDirectory $RootPath)) { return }
    $resolved = [IO.Path]::GetFullPath($RootPath).TrimEnd('\')
    foreach ($entry in [Bakunawa.Scanner]::Walk($resolved, [string[]]@(Get-CoreExcludedPaths))) {
        if ($entry.Kind -in @('Error','Skipped')) { Register-CleanupError -Path $entry.Path -Category 'Empty folders' -Message $entry.Message }
        if ($entry.Kind -ne 'EmptyDirectory' -or $entry.Path -eq $resolved -or -not $entry.Complete) { continue }
        try {
            $null = Remove-ItemSafely -Path $entry.Path -Reason 'Empty temp folder' -Preview:$script:IsPreview
            $script:TaskCleared++
        } catch { Register-CleanupError -Path $entry.Path -Category 'Empty folders' -Message $_.Exception.Message }
    }
}

function Remove-StaleJunkFolders {
    [CmdletBinding()]
    param()
    $staleLocations = @(
        (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        (Join-EnvPath 'APPDATA' 'Microsoft' 'Windows' 'Recent')
    )
    foreach ($loc in $staleLocations) {
        Remove-EmptyDirectories -RootPath $loc
    }
}

function Find-OrphanFolders {
    [CmdletBinding()]
    param([string[]]$Roots, [ValidateRange(1,3650)][int]$OlderThanDays = 30, [switch]$Refresh)
    Invoke-OrphanDiscovery @PSBoundParameters
}

function Clear-CachedOrphans {
    [CmdletBinding()]
    param([switch]$Preview)
    $isDryRun = $Preview -or $script:IsPreview
    $totalSize = 0L; $count = 0
    foreach ($orphan in @($script:OrphanCache)) {
        if (-not $orphan) { continue }
        if (-not $orphan.SafeDelete -or -not $orphan.EvidenceRule) {
            Add-CleanupRecord -Path $orphan.Path -Category 'Orphan Scan' -Bytes $orphan.Size -Reason 'no evidence' -Detail $orphan.Reason
            continue
        }
        try {
            $app = $script:OrphanRulePaths[$orphan.Path]
            if (-not $app -or -not (Test-OrphanEvidence -App $app).Eligible) { throw 'Orphan evidence no longer passes.' }
            $current = [Bakunawa.Scanner]::Inspect($orphan.Path, [string[]]@(Get-ScanExclusions))
            if ($current.Bytes -ne $orphan.Size -or $current.LatestWriteUtc -ne $orphan.LatestWriteUtc -or $current.Files -ne $orphan.FileCount) {
                throw 'Target changed since scan; rescan required.'
            }
            $script:CurrentOrphan = $orphan
            $totalSize += Remove-ItemSafely -Path $orphan.Path -Reason $orphan.Category -Tier $orphan.Tier -DetectorName 'Find-OrphanFolders' -Preview:$isDryRun
            $count++
        } catch { Register-CleanupError -Path $orphan.Path -Category 'Orphan Scan' -Message $_.Exception.Message }
        finally { $script:CurrentOrphan = $null }
    }
    $script:BytesFreed += $totalSize; $script:TaskBytes += $totalSize; $script:TaskCleared += $count
    if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
    $script:CategorySizes['Orphan Files'] = $totalSize
    if (-not $isDryRun) { $script:OrphanCacheTime = $null }
    return $count
}

function Clear-Prefetch {
    [CmdletBinding()]
    param()
    $prefetchDir = "$env:SystemRoot\Prefetch"
    $cat = 'Prefetch'; $n = 0
    if ($prefetchDir -and (Measure-AndClear $prefetchDir -Category $cat)) { $n++ }
    return $n
}

function Clear-EventLogs {
    [CmdletBinding()]
    param()
    # Event log storage can be redirected. Preserve diagnostics rather than clear another drive.
    Register-SkippedItem -Reason 'Event logs are retained; storage may be redirected outside C:' -Target 'Event Logs'
    return $false
}

function Clear-FontCache {
    [CmdletBinding()]
    param()
    $fontCache = Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'FontCache'
    $cat = 'Font Cache'
    return (Measure-AndClear $fontCache -Category $cat)
}

function Clear-ThumbnailCache {
    [CmdletBinding()]
    param()
    $thumbDir = (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Windows\Explorer')
    $cat = 'Thumbnail Cache'; $n = 0
    if (-not (Test-CleanupDirectory $thumbDir)) { return 0 }
    # Only target the thumbnail DB files; leave other Explorer state (IconCache.db is also here)
    try {
        $files = Get-ChildItem -LiteralPath $thumbDir -File -Force -ErrorAction Stop |
            Where-Object { $_.Name -like 'thumbcache_*.db' -or $_.Name -ieq 'IconCache.db' }
    } catch { Register-CleanupError -Path $thumbDir -Category $cat -Message $_.Exception.Message; return 0 }

    # Thumbnail cache files (thumbcache_*.db, IconCache.db) are small, safe, and isolated.
    # Explorer rebuilds them on demand, so a permanent delete is the right trade here.
    foreach ($f in $files) {
        if (Test-IsExcludedPath $f.FullName) { continue }
        $sz = $f.Length
        try {
        Write-CommandLog "CLEAR $(if($script:IsPreview){'PREVIEW'}else{''})" "$($f.FullName) ($([math]::Round($sz/1MB,2)) MB)"
        $deletedSize = Remove-ItemSafely -Path $f.FullName -Reason $cat -Tier 'Tier1' `
            -DetectorName 'Clear-ThumbnailCache' -Preview:$script:IsPreview
        $script:BytesFreed += [long]$deletedSize
        if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
        if (-not $script:CategorySizes.ContainsKey($cat)) { $script:CategorySizes[$cat] = [long]0 }
        $script:CategorySizes[$cat] += [long]$deletedSize
        $script:TaskCleared++; $script:TaskBytes += [long]$deletedSize
        $n++
        } catch { Register-CleanupError -Path $f.FullName -Category $cat -Message $_.Exception.Message }
    }
    return $n
}

function Invoke-CleanupRun {
    [CmdletBinding()]
    param(
        [ValidateSet('Standard','Aggressive','Preview')][string]$Mode = 'Standard',
        [switch]$WhatIf,
        [AllowNull()][hashtable]$Config
    )
    
    $script:BytesFreed = 0L
    $script:CategorySizes = @{}
    $script:Errors = @()
    $script:SkippedItems = @()
    $preview = ($WhatIf.IsPresent -or ($Mode -eq 'Preview'))
    $script:IsPreview = $true
    $script:Planning = $true
    $script:ActiveCategory = 'Discovery'
    $script:CandidateRecords = [Collections.Generic.List[object]]::new()
    try {
    $effectiveMode = if ($Mode -eq 'Preview') { 'Standard' } else { $Mode }
    
    # Load config if not provided
    if (-not $Config) {
        try {
            if (Get-Command Get-UserConfig -ErrorAction SilentlyContinue) {
                $Config = Get-UserConfig -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Debug "Failed to load user config, using defaults: $($_.Exception.Message)"
        }
    }

    Initialize-CleanupState -Config $Config -Aggressive:($effectiveMode -eq 'Aggressive')
    $Config = $script:CleanupConfig
    $preview = ($preview -or [bool]$Config.cleanupMode.dryRun)

    # Get tasks based on mode
    $tasks = Get-CleanupTasks -Mode $effectiveMode
    
    # Filter tasks based on config if available
    if ($Config -and $Config.taskCategories) {
        $tasks = @($tasks | Where-Object { 
            $task = $_
            $enabled = $Config.taskCategories[$task.Name].enabled
            if ($null -eq $enabled) { $true } else { $enabled }
        })
    }
    
    $script:TotalSteps = $tasks.Count
    $script:StepIndex = 0
    Reset-CleanupProgress

    $modeNote = if ($preview) { 'nothing will be deleted' } else { 'planning, then revalidating and processing eligible candidates' }
    Write-Host ''
    Write-ReviewLine ("Bakunawa - {0}: {1} tasks - {2}" -f $Mode, $tasks.Count, $modeNote)

    $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:RunCleared = 0

    # Process tasks
    foreach ($task in $tasks) {
        $taskName = $task.Name
        $script:ActiveCategory = $taskName
        $isParallel = $task.Parallel

        Start-Step -Name $taskName -Total $tasks.Count

        # Per-task statistics (rendered by Finish-Step below)
        $script:TaskCleared = 0
        $script:TaskSkipped = 0
        $script:TaskBytes   = [long]0
        
        $errorsBefore = @($script:Errors).Count
        try {
        switch ($taskName) {
            'System Caches' { $null = Clear-SystemCaches }
            'Browser Caches' {
                # Definitions already point to exact cache directories, including profile tokens.
                foreach ($app in (Get-AllAppDefinitions -Category 'Browser Caches')) {
                    if (-not $app.Path) { continue }
                    foreach ($path in @(Expand-WildcardPath -Path $app.Path -DirectoriesOnly)) {
                        $null = Measure-AndClear -Path $path -Category 'Browser Caches'
                    }
                }
            }
             'App Caches' { $null = Clear-AppCaches }
             'Dev Caches' { $null = Clear-DevCaches }
             'Game Caches' { $null = Clear-GameCaches }
             'Browser Automation Caches' { $null = Clear-BrowserAutomationCaches }
             'Package Manager Caches' { $null = Clear-PackageManagerCaches }
             'GPU/Shell Caches' { $null = Clear-GpuAndShellCaches }
            'Recycle Bin' { $null = Clear-RecycleBinSafe }
            'Thumbnail Cache' { $null = Clear-ThumbnailCache }
            'Log Files' { $null = Clear-SystemLogFiles }
            'Empty/Stale Folders' { 
                $tempDirs = @((Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'), $script:SysLoc.WindowsTemp)
                foreach ($tempDir in $tempDirs) {
                    $null = Remove-EmptyDirectories -RootPath $tempDir
                }
                $null = Remove-StaleJunkFolders
            }
            'Orphan Scan' { 
                $null = Find-OrphanFolders  # Scans and caches orphans
                $null = Clear-CachedOrphans # Deletes cached orphans (respects preview mode)
            }
            'Prefetch' { $null = Clear-Prefetch }
            'DISM' { 
                if (-not [Bakunawa.Scanner]::IsAllowedPath((Get-EnvPath 'SystemRoot'))) {
                    Register-SkippedItem -Reason 'Windows servicing is restricted to C:' -Target 'DISM'
                    break
                }
                if ($script:IsPreview) {
                    Write-CommandLog 'PREVIEW' 'DISM /Online /Cleanup-Image /StartComponentCleanup'
                } else {
                    $dism = Join-Path (Get-EnvPath 'SystemRoot') 'System32\dism.exe'
                    try {
                        & $dism /Online /Cleanup-Image /StartComponentCleanup | ForEach-Object { Write-CommandLog 'DISM' $_ }
                        if ($LASTEXITCODE -notin @(0,3010)) { throw "DISM exited with code $LASTEXITCODE" }
                        if ($LASTEXITCODE -eq 3010) { Write-CommandLog 'INFO' 'Restart Windows to finish component cleanup.' }
                    } catch { Register-CleanupError -Path $dism -Category 'DISM' -Message $_.Exception.Message }
                }
            }
             'Event Logs + Font Cache' { 
                 $null = Clear-EventLogs
                 $null = Clear-FontCache
             }
             'Cloud Sync' {
                 # OneDrive, Google Drive, Dropbox temp files
                 $applist = Get-AllAppDefinitions -Category 'Cloud Sync'
                 foreach ($app in $applist) {
                     if ($app.Path) {
                         $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                         foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                             if ($resolved) {
                                 Measure-AndClear $resolved -Category 'Cloud Sync' -EA SilentlyContinue | Out-Null
                             }
                         }
                     }
                 }
             }
             'Creative Apps' {
                 # Adobe, Affinity, Blender, etc. caches
                 $applist = Get-AllAppDefinitions -Category 'Creative Apps'
                 foreach ($app in $applist) {
                     if ($app.Path) {
                         $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                         foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                             if ($resolved) {
                                 Measure-AndClear $resolved -Category 'Creative Apps' -EA SilentlyContinue | Out-Null
                             }
                         }
                     }
                 }
             }
             'Productivity' {
                 # Office, Slack, Teams, etc. caches
                 $applist = Get-AllAppDefinitions -Category 'Productivity'
                 foreach ($app in $applist) {
                     if ($app.Path) {
                         $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                         foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                             if ($resolved) {
                                 Measure-AndClear $resolved -Category 'Productivity' -EA SilentlyContinue | Out-Null
                             }
                         }
                     }
                 }
             }
             'DevOps Tools' {
                 # Docker, Kubernetes, Terraform, etc. caches
                 $applist = Get-AllAppDefinitions -Category 'DevOps Tools'
                 foreach ($app in $applist) {
                     if ($app.Path) {
                         $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                         foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                             if ($resolved) {
                                 Measure-AndClear $resolved -Category 'DevOps Tools' -EA SilentlyContinue | Out-Null
                             }
                         }
                     }
                 }
             }
             'User Hidden Folders' {
                 # Hidden system files and caches
                 $hiddenFolders = @(
                     (Join-EnvPath 'USERPROFILE' '.cache'),
                     (Join-EnvPath 'USERPROFILE' '.config\cache'),
                     (Join-EnvPath 'LOCALAPPDATA' 'VirtualStore')
                 )
                 foreach ($hf in $hiddenFolders) {
                     if ($hf) {
                         Measure-AndClear $hf -Category 'User Hidden' -EA SilentlyContinue | Out-Null
                     }
                 }
             }
             'Scoop Cache' {
                 $scoopCache = Join-EnvPath 'USERPROFILE' 'scoop\cache'
                 if ($scoopCache) {
                     Measure-AndClear $scoopCache -Category 'Package Managers' -EA SilentlyContinue | Out-Null
                 }
             }
             'Rust Cargo Cache' {
                 $cargoTarget = Join-EnvPath 'USERPROFILE' '.cargo\registry\cache'
                 if ($cargoTarget) {
                     Measure-AndClear $cargoTarget -Category 'Package Managers' -EA SilentlyContinue | Out-Null
                 }
             }
             'Go Module Cache' {
                 $goModCache = Join-EnvPath 'USERPROFILE' 'go\pkg\mod\cache'
                 if ($goModCache) {
                     Measure-AndClear $goModCache -Category 'Package Managers' -EA SilentlyContinue | Out-Null
                 }
             }
             'Bun Cache' {
                 $bunCache = @(
                     (Join-EnvPath 'USERPROFILE' '.bun\install\cache'),
                     (Join-EnvPath 'LOCALAPPDATA' 'bun\install\cache')
                 )
                 foreach ($bc in $bunCache) {
                     if ($bc) {
                         Measure-AndClear $bc -Category 'Package Managers' -EA SilentlyContinue | Out-Null
                     }
                 }
             }
        }

        } catch {
            Register-CleanupError -Path $taskName -Category $taskName -Message $_.Exception.Message
        }

        # Compose informative per-task summary
        $script:RunCleared += $script:TaskCleared
        $parts = @()
        $taskErrors = @($script:Errors).Count - $errorsBefore
        if ($taskErrors -gt 0) { $parts += ("$taskErrors error(s)") }
        if ($script:TaskCleared -gt 0) { $parts += ('{0} path{1}' -f $script:TaskCleared, $(if ($script:TaskCleared -eq 1) { '' } else { 's' })) }
        if ($script:TaskBytes -gt 0)   { $parts += (Format-FileSize $script:TaskBytes) }
        if ($script:TaskSkipped -gt 0) { $parts += ('{0} skipped' -f $script:TaskSkipped) }
        $summary = if ($parts.Count -gt 0) { $parts -join '  |  ' } else { 'nothing found' }
        Finish-Step -Summary $summary
    }


    $script:ActiveCategory = $null
    foreach ($skip in @(Get-CoreSkippedItems)) {
        if (@($script:CandidateRecords | Where-Object Path -eq $skip.Target).Count) { continue }
        Add-CleanupRecord -Path $skip.Target -Category $skip.Category -Bytes $skip.Bytes -Reason (Get-CleanupFailureReason $skip.Reason) -Detail $skip.Reason
    }
    $script:Planning = $false
    $script:IsPreview = $preview
    $script:ActiveCategory = $null
    # Select outermost eligible targets once, before any mutation, in both modes.
    $records = [Collections.Generic.List[object]]::new()
    $selected = New-TrackedSet
    foreach ($row in @($script:CandidateRecords | Where-Object Status -eq 'Eligible' | Sort-Object { $_.Path.Length })) {
        $ancestor = $row.Path; $covered = $false
        while ($ancestor) {
            if ($selected.Contains($ancestor)) { $covered = $true; break }
            $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        }
        if ($covered) { continue }
        [void]$selected.Add($row.Path)
        $records.Add($row)
    }
    $candidates = @($records)
    # ponytail: skipped parent totals compare planned paths; use ancestor byte totals if huge reports make this costly.
    foreach ($row in @($script:CandidateRecords | Where-Object Status -eq 'Skipped' | Sort-Object { $_.Path.Length })) {
        if (@($records | Where-Object { $_.Path -eq $row.Path -or [Bakunawa.Scanner]::Within($row.Path, $_.Path) }).Count) { continue }
        if ($null -ne $row.Bytes) {
            $covered = [long](($records | Where-Object { [Bakunawa.Scanner]::Within($_.Path, $row.Path) } | Measure-Object Bytes -Sum).Sum)
            $row.Bytes = [math]::Max(0, $row.Bytes - $covered)
        }
        $records.Add($row)
    }
    if (-not $preview) {
        foreach ($row in $candidates) {
            $script:PartialActedBytes = 0L
            $script:PartialOutcomeKnown = $true
            try {
                Write-ReviewLine ("Processing: {0}" -f $row.Path) -ForegroundColor Gray
                if ($row.Finding) {
                    $app = $script:OrphanRulePaths[$row.Path]
                    if (-not $row.Finding.EvidenceRule -or -not $app -or -not (Test-OrphanEvidence -App $app).Eligible) { throw 'No evidence: orphan rule no longer passes.' }
                }
                $current = [Bakunawa.Scanner]::Inspect($row.Path, [string[]]@(Get-CoreExcludedPaths))
                if ($current.Bytes -ne $row.Measurement.Bytes -or $current.Files -ne $row.Measurement.Files -or $current.LatestWriteUtc -ne $row.Measurement.LatestWriteUtc) { throw 'Changed since scan; rescan required.' }
                $runningNow = Get-RunningProcessNames
                foreach ($app in $script:DefinitionPaths) {
                    if (-not $app.Process -or -not (Test-AnyProcessRunning -RunningProcesses $runningNow -Names @($app.Process))) { continue }
                    if ([Bakunawa.Scanner]::Within($row.Path, $app.Path) -or [Bakunawa.Scanner]::Within($app.Path, $row.Path)) { throw "In use: $($app.Name)" }
                }
                $row.ActedBytes = Remove-ItemSafely -Path $row.Path -Reason $row.Category -Tier $row.Tier -DetectorName $row.Detector
                $row.Status = 'Acted'
            } catch {
                $row.ActedBytes = $script:PartialActedBytes
                $row.OutcomeKnown = $script:PartialOutcomeKnown
                $row.Status = 'Skipped'; $row.Detail = $_.Exception.Message
                $row.Reason = Get-CleanupFailureReason $row.Detail
                Register-CleanupError -Path $row.Path -Category $row.Category -Message $row.Detail
            }
        }
    }
    $categoryReport = @(foreach ($group in @($records | Group-Object Category)) {
        $identified = [long](($group.Group | Measure-Object Bytes -Sum).Sum)
        $acted = [long](($group.Group | Measure-Object ActedBytes -Sum).Sum)
        $unknownOutcomes = @($group.Group | Where-Object { -not $_.OutcomeKnown }).Count
        $reasons = @(foreach ($reason in @($group.Group | Where-Object { $_.Status -ne 'Acted' } | Group-Object { if ($_.Reason) { $_.Reason } else { 'preview' } })) {
            [pscustomobject]@{ Reason = $reason.Name; Bytes = $(if (@($reason.Group | Where-Object { -not $_.OutcomeKnown }).Count) { $null } else { [long](($reason.Group | Measure-Object Bytes -Sum).Sum) - [long](($reason.Group | Measure-Object ActedBytes -Sum).Sum) }); UnknownSizePaths = @($reason.Group | Where-Object { $null -eq $_.Bytes }).Count }
        })
        [pscustomobject]@{ Category = $group.Name; IdentifiedBytes = $identified; ActedBytes = $(if ($unknownOutcomes) { $null } else { $acted }); NotActedBytes = $(if ($unknownOutcomes) { $null } else { $identified - $acted }); ConfirmedActedBytes = $acted; Reasons = $reasons; UnknownSizePaths = @($group.Group | Where-Object { $null -eq $_.Bytes }).Count; UnknownOutcomePaths = $unknownOutcomes }
    })
    foreach ($task in $tasks) {
        if ($task.Name -notin @($categoryReport.Category)) {
            $categoryReport += [pscustomobject]@{ Category = $task.Name; IdentifiedBytes = 0L; ActedBytes = 0L; NotActedBytes = 0L; Reasons = @(); UnknownSizePaths = 0 }
        }
    }
    $script:CategorySizes = @{}
    foreach ($group in $categoryReport) { $script:CategorySizes[$group.Category] = $(if ($preview) { [long](($candidates | Where-Object Category -eq $group.Category | Measure-Object Bytes -Sum).Sum) } else { $group.ActedBytes }) }
    $script:BytesFreed = if ($preview) { [long](($candidates | Measure-Object Bytes -Sum).Sum) } else { [long](($records | Measure-Object ActedBytes -Sum).Sum) }
    $script:RunCleared = if ($preview) { $candidates.Count } else { @($records | Where-Object Status -eq 'Acted').Count }
    $denied = @($records | Where-Object { $_.Reason -eq 'access denied' })

    $runStopwatch.Stop()
    # Return results
    return [PSCustomObject]@{
        Mode = $Mode
        Candidates = $candidates
        Outcomes = @($records)
        CategoryReport = $categoryReport
        UnknownOutcomePaths = @($records | Where-Object { -not $_.OutcomeKnown }).Count
        IsComplete = ($denied.Count -eq 0 -and @($records | Where-Object { $null -eq $_.Bytes -or -not $_.OutcomeKnown }).Count -eq 0 -and (-not $script:LastScanReport -or $script:LastScanReport.IsComplete))
        BytesFreed = [long]$script:BytesFreed
        IsPreview = [bool]$script:IsPreview
        PathsCleared = [int]$script:RunCleared
        CategorySizes = $script:CategorySizes
        Errors = $script:Errors
        SkippedItems = @(Get-CoreSkippedItems)
        OrphanFounds = @($script:OrphanCache | Where-Object { $_ }).Count
        ScanReport = $script:LastScanReport
        DurationSec = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 1)
    }
    } finally { $script:Planning = $false; $script:ActiveCategory = $null; $script:CurrentOrphan = $null }
}

function Clear-DefinitionCaches {
    [CmdletBinding()]
    param([string]$Category)
    $count = 0
    foreach ($app in @(Get-AllAppDefinitions -Category $Category)) {
        foreach ($path in @(Expand-WildcardPath -Path $app.Path -DirectoriesOnly)) {
            if (Measure-AndClear -Path $path -Category $Category) { $count++ }
        }
    }
    return $count
}

function Clear-GameCaches { Clear-DefinitionCaches -Category 'Game Caches' }
function Clear-BrowserAutomationCaches { Clear-DefinitionCaches -Category 'Browser Automation Caches' }

function Clear-PackageManagerCaches {
    [CmdletBinding()]
    param()
    Write-CommandLog 'SCAN' 'Package Manager Caches'
    $cat = 'Dev Caches'; $n = 0
    
    # npm cache: resolved from the app definition so one source of truth drives the
    # path. npm 5+ writes %LOCALAPPDATA%\npm-cache; legacy installs used %APPDATA%.
    foreach ($npmCache in @(Get-AllAppDefinitions -Category 'Dev Caches' |
            Where-Object { $_.Name -eq 'npm-cache' -and $_.Mode -ne 'entry' } |
            ForEach-Object { $_.Path })) {
        if ($npmCache -and (Measure-AndClear $npmCache -Category $cat)) { $n++ }
    }
    
    # pip cache (Python)
    $pipCache = @(
        (Join-EnvPath 'LOCALAPPDATA' 'pip\Cache'),
        (Join-EnvPath 'USERPROFILE' 'AppData\Local\pip\Cache')
    )
    foreach ($pc in $pipCache) {
        if ($pc) {
            if (Measure-AndClear $pc -Category $cat) { $n++ }
        }
    }
    
    # Hugging Face cache (ML models)
    $hfCache = @(
        (Join-EnvPath 'USERPROFILE' '.cache\huggingface'),
        (Join-EnvPath 'LOCALAPPDATA' 'huggingface\cache')
    )
    foreach ($hc in $hfCache) {
        if ($hc) {
            if (Measure-AndClear $hc -Category $cat) { $n++ }
        }
    }
    
    return $n
}

Export-ModuleMember -Function @(
    'Measure-AndClear',
    'Get-CleanupTasks',
    'Get-CleanupPotential',
    'Remove-FilesByPattern',
    'Expand-WildcardPath',
    'Get-TransientEntryMatches',
    'Clear-TransientEntries',
    'Get-TransientAgeDays',
    'Clear-SystemCaches',
    'Clear-ChromiumCaches',
    'Clear-FirefoxCaches',
    'Clear-AppCaches',
    'Clear-DevCaches',
    'Clear-GpuAndShellCaches',
    'Clear-GameCaches',
    'Clear-BrowserAutomationCaches',
    'Clear-PackageManagerCaches',
    'Clear-RecycleBinSafe',
    'Clear-SystemLogFiles',
    'Remove-EmptyDirectories',
    'Remove-StaleJunkFolders',
    'Find-OrphanFolders',
    'Get-ScanDriveRoots',
    'Get-OrphanScanReport',
    'Clear-ReviewedOrphans',
    'Initialize-CleanupState',
    'Clear-CachedOrphans',
    'Clear-Prefetch',
    'Clear-EventLogs',
    'Clear-FontCache',
    'Get-CleanupErrorLog',
    'Invoke-CleanupRun'
)
