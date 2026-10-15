# Bakunawa.Core.psm1 — Core engine, safety, sizing, health

# ── C# ACCELERATOR ──
if (-not ('Bakunawa.Scanner' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'Bakunawa.Scanner.cs') -ErrorAction Stop
}
# ── SCRIPT STATE ──
$script:ExcludedPaths    = $null
$script:SkippedItems     = @()
$script:RunningProcesses = $null
$script:HealthCache      = $null
$script:TempSizeCache    = $null
$script:InstalledAppNames = $null

function Get-FreeSpaceInfo {
    [CmdletBinding()]
    param([string]$DriveLetter)
    if (-not $DriveLetter) { $DriveLetter = 'C' }
    
    try {
        $driveInfo = [System.IO.DriveInfo]::new("${DriveLetter}:")
        if (-not $driveInfo.IsReady) { 
            return [PSCustomObject]@{MB=0;GB=0;TotalMB=0;TotalGB=0;UsedMB=0;UsedGB=0;FreeBytes=0;TotalBytes=0}
        }
        
        $freeBytes = [long]$driveInfo.AvailableFreeSpace
        if ($freeBytes -lt 0) { $freeBytes = 0 }
        $totalBytes = [long]$driveInfo.TotalSize
        if ($totalBytes -lt 1) { $totalBytes = 1 }
        $usedBytes = [long]($totalBytes - $freeBytes)
        
        return [PSCustomObject]@{
            MB = [math]::Round($freeBytes / 1MB)
            GB = [math]::Round($freeBytes / 1GB, 2)
            TotalMB = [math]::Round($totalBytes / 1MB)
            TotalGB = [math]::Round($totalBytes / 1GB, 2)
            UsedMB = [math]::Round($usedBytes / 1MB)
            UsedGB = [math]::Round($usedBytes / 1GB, 2)
            # Raw bytes so a before/after storage comparison is exact; the rounded
            # MB/GB fields above cannot express a small difference.
            FreeBytes = $freeBytes
            TotalBytes = $totalBytes
        }
    } catch {
        Write-Verbose "Get-FreeSpaceInfo error: $_"
        return [PSCustomObject]@{MB=0;GB=0;TotalMB=0;TotalGB=0;UsedMB=0;UsedGB=0}
    }
}

function Get-DirectorySize {
    [CmdletBinding()]
    param([string]$Path)
    return [long](Get-DirectorySizeEstimate -Path $Path).Bytes
}

function Get-DirectorySizeEstimate {
    [CmdletBinding()]
    param([string]$Path)
    if (-not [Bakunawa.Scanner]::IsAllowedPath($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [PSCustomObject]@{ Path = $Path; Bytes = 0; FileCount = 0; IsEstimate = $false }
    }
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $result = $null
    foreach ($entry in [Bakunawa.Scanner]::Walk($resolved + '\', [string[]]@(Get-CoreExcludedPaths))) {
        if ($entry.Path.TrimEnd('\') -eq $resolved) { $result = $entry }
    }
    return [PSCustomObject]@{ Path = $Path; Bytes = [long]$result.Bytes; FileCount = [long]$result.Files; IsEstimate = -not $result.Complete }
}

function Format-FileSize {
    [CmdletBinding()]
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    "$Bytes B"
}

function New-TrackedSet {
    return ,([System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase))
}

function Resolve-FullPath {
    [CmdletBinding()]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { return [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { Write-Verbose "Resolve-FullPath: $_"; return $null }
}

function Resolve-RealPath {
    [CmdletBinding()]
    param([string]$Path)
    # Resolves full path, then follows symlinks/junctions to true destination
    $full = Resolve-FullPath $Path
    if (-not $full -or -not (Test-Path -LiteralPath $full)) { return $full }
    try {
        $item = Get-Item -LiteralPath $full -Force -EA SilentlyContinue
        if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            # It's a symlink or junction; resolve to target
            $target = $item.Target
            if ($target) {
                $resolved = Resolve-FullPath $target
                return if ($resolved) { $resolved } else { $full }
            }
        }
    } catch {}
    return $full
}

function Get-EnvPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    # COMMONPROGRAMFILES resolves to the 64-bit Common Files even from a 32-bit
    # process on 64-bit Windows, so the 32-bit variant needs an explicit alias:
    # Google Updater caches under the x86 tree.
    if ($Name -eq 'COMMONPROGRAMFILES86') { $Name = 'CommonProgramFiles(x86)' }
    foreach ($s in 'Process','User','Machine') {
        $v = [Environment]::GetEnvironmentVariable($Name, $s)
        # GetFullPath('C:') returns the process CWD on that drive; a bare drive
        # root is its own path, so anchor it before resolving.
        if ($v -match '^[A-Za-z]:$') { $v = "$v\" }
        $r = Resolve-FullPath $v
        if ($r) { return $r }
    }
    return $null
}

function Join-EnvPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$ChildPath
    )
    $b = Get-EnvPath -Name $Name
    if (-not $b) { return $null }
    if (-not $ChildPath -or $ChildPath.Count -eq 0) { return $b }
    $fullPath = $b
    foreach ($segment in $ChildPath) {
        if ($segment) { $fullPath = Join-Path $fullPath $segment }
    }
    return Resolve-FullPath $fullPath
}

function Test-IsAdministrator {
    [CmdletBinding()]
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    [CmdletBinding()]
    param([string]$SelectedMode)
    $hostExe = $null
    $pwsh = Get-Command pwsh.exe -ErrorAction Ignore
    if ($pwsh) { $hostExe = $pwsh.Source }
    else {
        $winPs = Get-Command powershell.exe -ErrorAction Ignore
        if ($winPs) { $hostExe = $winPs.Source }
    }
    if (-not $hostExe) {
        Write-Host 'PowerShell executable not found. Elevation requires powershell.exe or pwsh.exe.' -ForegroundColor Red
        return $false
    }
    # Entry script lives one level above src/ in this repo layout; prefer real command path when available
    $entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'Bakunawa.ps1'
    if ($PSCommandPath -and $PSCommandPath -like '*.ps1') { $entry = $PSCommandPath }
    if (-not (Test-Path -LiteralPath $entry)) { return $false }
    $cmd = "-NoProfile -ExecutionPolicy Bypass -File `"$entry`""
    if ($SelectedMode) { $cmd += " -Mode $SelectedMode" }
    try {
        Write-Host ''
        Write-Host 'Administrator rights required. Requesting elevation...' -ForegroundColor Yellow
        Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $cmd | Out-Null
        return $true
    } catch {
        Write-Host "Elevation failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Get-ProtectedKnownFolders {
    [CmdletBinding()]
    param()
    foreach ($id in @(
        'B4BFCC3A-DB2C-424C-B029-7FE99A87C641', # Desktop
        'FDD39AD0-238F-46AF-ADB4-6C85480369C7', # Documents
        '374DE290-123F-4565-9164-39C4925E467B', # Downloads
        '33E28130-4E1E-4676-835A-98395C3BC3BB', # Pictures
        '18989B1D-99B5-455B-841C-AB7C74E4DDFC', # Videos
        '4BD8D571-6D19-48D3-BE97-422220080E43'  # Music
    )) {
        $path = [Bakunawa.Scanner]::KnownFolder($id)
        if (-not $path) { throw "Cannot resolve protected known folder $id; cleanup is blocked." }
        [IO.Path]::GetFullPath($path).TrimEnd('\')
    }
}

function Get-ExcludedPaths {
    [CmdletBinding()]
    param([string[]]$ExtraExcludePath)
    $set = New-TrackedSet
    foreach ($path in @(Get-ProtectedKnownFolders)) { [void]$set.Add([IO.Path]::GetFullPath($path).TrimEnd('\')) }
    $standardFolders = @('Downloads','Documents','Desktop','Pictures','Videos','Music')
    
    # User profile standard folders (hard exclusion)
    foreach ($folder in $standardFolders) {
        $r = Resolve-RealPath (Join-EnvPath 'USERPROFILE' $folder)
        if ($r) { [void]$set.Add($r) }
    }
    
    # OneDrive personal (all five redirectable folders)
    foreach ($folder in $standardFolders) {
        $r = Resolve-RealPath (Join-EnvPath 'OneDrive' $folder)
        if ($r) { [void]$set.Add($r) }
    }
    
    # OneDrive Business (if present)
    foreach ($folder in $standardFolders) {
        $r = Resolve-RealPath (Join-EnvPath 'OneDriveCommercial' $folder)
        if ($r) { [void]$set.Add($r) }
    }
    
    # WinGet packages (user-managed)
    $r = Resolve-RealPath (Join-EnvPath 'LOCALAPPDATA' 'Packages')
    if ($r) { [void]$set.Add($r) }
    
    # User-provided extra exclusions
    foreach ($c in $ExtraExcludePath) {
        $r = Resolve-RealPath $c
        if ($r) { [void]$set.Add($r) }
    }
    return ,$set
}

function Get-CoreExcludedPaths {
    if ($null -eq $script:ExcludedPaths) { $script:ExcludedPaths = Get-ExcludedPaths }
    # Resolve again at mutation time: known-folder redirection can change after scanning.
    foreach ($path in @(Get-ProtectedKnownFolders)) { [void]$script:ExcludedPaths.Add([IO.Path]::GetFullPath($path).TrimEnd('\')) }
    foreach ($path in $script:ExcludedPaths) { $path }
}

function Get-CoreSkippedItems { $script:SkippedItems }

function Test-IsExcludedPath {
    [CmdletBinding()]
    param([string]$Path)
    $r = Resolve-RealPath $Path
    if (-not $r) { return $false }
    foreach ($e in @(Get-CoreExcludedPaths)) {
        if ($r.Equals($e,[StringComparison]::OrdinalIgnoreCase) -or
            $r.StartsWith("$e\",[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-DisposableDirectoryNames {
    [CmdletBinding()]
    $names = New-TrackedSet
    @(
        'cache','caches','code cache','gpucache','media cache','dawncache',
        'shadercache','grshadercache','graphitedawncache','startupcache','cache2',
        'temp','tmp','logs','log','crashpad','crashdumps','blob_storage'
    ) | ForEach-Object { [void]$names.Add($_) }
    return ,$names
}

function Get-InstalledApplicationNames {
    <#
    .SYNOPSIS
    Enumerate installed Windows applications from the uninstall registry keys.

    .DESCRIPTION
    Reads DisplayName values from standard Uninstall registry keys (32-bit, 64-bit, per-user).
    Skips KB hotfixes, entries without DisplayName, and entries without UninstallString.
    Returns a deduplicated, lowercased array suitable for orphan-risk scoring.
    Caches result for the duration of the run.

    .PARAMETER SkipCaching
    If true, bypass cache and re-read registry. Useful for testing.

    .PARAMETER UninstallKeys
    Override registry paths (for testing). Defaults to standard three Uninstall key paths.

    .EXAMPLE
    $appNames = Get-InstalledApplicationNames
    # Returns: @('chrome', 'firefox', 'visual studio code', ...)
    #>
    [CmdletBinding()]
    param(
        [switch]$SkipCaching,
        [switch]$Strict,
        [string[]]$UninstallKeys
    )

    # Return cached result if available and not skipping cache
    if (-not $SkipCaching -and $script:InstalledAppNames) {
        return $script:InstalledAppNames
    }

    # Default registry paths if not provided
    if (-not $UninstallKeys) {
        $UninstallKeys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        )
    }

    $appNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($keyPath in $UninstallKeys) {
        try {
            if (-not (Test-Path -LiteralPath $keyPath -ErrorAction Stop)) {
                if ($Strict) {
                    # A readable parent establishes absence; an unreadable parent is inconclusive.
                    $null = Get-ChildItem -LiteralPath (Split-Path -Parent $keyPath) -ErrorAction Stop
                }
                continue
            }

            $regKey = Get-Item -LiteralPath $keyPath -ErrorAction Stop
            foreach ($subKey in $regKey.GetSubKeyNames()) {
                try {
                    $fullPath = Join-Path $keyPath $subKey
                    $props = Get-ItemProperty -LiteralPath $fullPath -ErrorAction Stop

                    # Skip entries without DisplayName
                    if (-not $props.DisplayName) {
                        continue
                    }

                    # Skip KB hotfixes
                    if ($props.DisplayName -match '^KB\d+') {
                        continue
                    }

                    # Skip entries without UninstallString (indicates incomplete/corrupted entry)
                    # MSI entries can legitimately omit UninstallString.

                    # Add to set (deduplication via HashSet)
                    [void]$appNames.Add($props.DisplayName.ToLower())
                }
                catch {
                    if ($Strict) { throw }
                    # Skip individual key read errors; continue scanning
                    continue
                }
            }
        }
        catch {
            if ($Strict) { throw }
            # Skip entire registry hive read errors; continue to next key
            continue
        }
    }

    # Convert to sorted array and cache
    $result = @($appNames | Sort-Object)
    $script:InstalledAppNames = $result

    return $result
}

function Get-RunningProcessNames {
    [CmdletBinding()]
    $set = New-TrackedSet
    foreach ($name in (Get-Process -EA SilentlyContinue | Select-Object -ExpandProperty Name -Unique)) {
        [void]$set.Add($name)
    }
    return ,$set
}

function Initialize-CoreSafetyState {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$ExtraExcludePath,
        [hashtable]$Config,
        [string]$ModeName
    )
    
    $custom = @($ExtraExcludePath)
    if ($Config -and $Config.exclusions) { $custom += @($Config.exclusions.userCustomExclusions) }
    $script:ExcludedPaths = Get-ExcludedPaths -ExtraExcludePath $custom
    $script:RunningProcesses = Get-RunningProcessNames
    $script:SkippedItems = @()

    # Quarantine was removed: every delete is final and immediately reclaims disk space.
    # The warning follows the mode: telling a read-only scan that deletes are
    # permanent reads as a risk that does not exist.
    switch ($ModeName) {
        'Preview' { Write-CommandLog 'INFO' 'Preview only: nothing will be deleted.' }
        'Scan'    { Write-CommandLog 'INFO' 'Read-only run: nothing will be deleted.' }
        default   { Write-CommandLog 'INFO' 'Deletes are permanent; use Preview to inspect the plan first.' }
    }

    return [PSCustomObject]@{
        ExcludedPathCount = if ($script:ExcludedPaths) { $script:ExcludedPaths.Count } else { 0 }
        ProcessCount = if ($script:RunningProcesses) { $script:RunningProcesses.Count } else { 0 }
    }
}

function Test-AnyProcessRunning {
    [CmdletBinding()]
    param($RunningProcesses, [string[]]$Names)
    if (-not $RunningProcesses) { $RunningProcesses = Get-RunningProcessNames }
    foreach ($name in $Names) {
        if ($RunningProcesses.Contains($name)) { return $true }
    }
    return $false
}

function Register-SkippedItem {
    [CmdletBinding()]
    param([string]$Reason, [string]$Target, [string]$Category = 'Discovery', [Nullable[long]]$Bytes)
    $script:SkippedItems += [PSCustomObject]@{ Reason = $Reason; Target = $Target; Category = $Category; Bytes = $Bytes }
}

function Get-HealthScore {
    [CmdletBinding()]
    param([switch]$Fast)
    $now = Get-Date
    if ($script:HealthCache -and $script:HealthCache.Fast -eq [bool]$Fast -and ($now -lt $script:HealthCache.Expires)) { return $script:HealthCache.Data }
    
    $free = Get-FreeSpaceInfo
    # Calculate disk percentage correctly: (free / total) * 100
    $diskPct = if ($free.TotalMB -gt 0) { [math]::Round(($free.MB / $free.TotalMB) * 100) } else { 0 }
    $diskScore = if ($diskPct -ge 30) { 30 } elseif ($diskPct -ge 20) { 25 } elseif ($diskPct -ge 10) { 15 } elseif ($diskPct -ge 5) { 5 } else { 0 }
    
    $tempTotal = 0L
    if ($Fast) {
        # ponytail: header health skips the recursive temp walk (can take 10s+ on big temps); full score in Health view
        if ($script:TempSizeCache) { $tempTotal = $script:TempSizeCache }
    } else {
        foreach ($tp in (@((Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp')) | Sort-Object -Unique)) {
            $tempTotal += Get-DirectorySize $tp 
        }
        $script:TempSizeCache = $tempTotal
    }
    $tempMB = $tempTotal / 1MB
    $tempScore = if ($tempMB -lt 500) { 25 } elseif ($tempMB -lt 2000) { 18 } elseif ($tempMB -lt 5000) { 10 } elseif ($tempMB -lt 10000) { 5 } else { 0 }
    
    $browserRoots = @(
        (Join-EnvPath 'LOCALAPPDATA' 'Google\Chrome\User Data\Default\Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Edge\User Data\Default\Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'BraveSoftware\Brave-Browser\User Data\Default\Cache')
    )
    $oldestCacheDays = 0
    foreach ($br in $browserRoots) {
        if ([Bakunawa.Scanner]::IsAllowedPath($br) -and (Test-Path -LiteralPath $br)) {
            $age = ((Get-Date) - (Get-Item $br -EA SilentlyContinue).LastWriteTime).TotalDays
            if ($age -gt $oldestCacheDays) { $oldestCacheDays = [int]$age }
        }
    }
    $browserScore = if ($oldestCacheDays -lt 7) { 20 } elseif ($oldestCacheDays -lt 30) { 14 } elseif ($oldestCacheDays -lt 90) { 8 } else { 0 }
    
    # Orphan risk is scored from the last scan report; with no scan there is no
    # evidence either way, so the component keeps its full 25 points.
    $orphanScore = 25
    $orphanInfo = $null
    if (Get-Command Get-OrphanScanReport -ErrorAction SilentlyContinue) {
        $scanReport = Get-OrphanScanReport -ErrorAction SilentlyContinue
        if ($scanReport -and $scanReport.Findings) {
            $scanFindings = @($scanReport.Findings)
            $orphanInfo = [PSCustomObject]@{
                HighCount = @($scanFindings | Where-Object { $_.RiskLevel -eq 'High' }).Count
                MedCount  = @($scanFindings | Where-Object { $_.RiskLevel -eq 'Medium' }).Count
            }
        }
    }
    if ($orphanInfo) {
        $orphanScore = if ($orphanInfo.HighCount -eq 0 -and $orphanInfo.MedCount -lt 3) { 25 }
                    elseif ($orphanInfo.HighCount -le 2 -or $orphanInfo.MedCount -le 5) { 15 }
                    elseif ($orphanInfo.HighCount -le 5 -or $orphanInfo.MedCount -le 10) { 5 }
                    else { 0 }
    }
    
    $totalScore = $diskScore + $tempScore + $browserScore + $orphanScore
    $grade = if ($totalScore -ge 85) { 'Excellent' } elseif ($totalScore -ge 65) { 'Good' } elseif ($totalScore -ge 40) { 'Fair' } else { 'Needs attention' }
    $gradeColor = if ($totalScore -ge 85) { 'Green' } elseif ($totalScore -ge 65) { 'Cyan' } elseif ($totalScore -ge 40) { 'Yellow' } else { 'Red' }
    
    $result = [PSCustomObject]@{ 
        Score = $totalScore
        Grade = $grade
        GradeColor = $gradeColor
        DiskScore = $diskScore
        TempScore = $tempScore
        BrowserScore = $browserScore
        OrphanScore = $orphanScore
        DiskPct = $diskPct
        TempMB = [math]::Round($tempMB)
        BrowserAge = $oldestCacheDays
        OrphanInfo = $orphanInfo
    }
    $script:HealthCache = @{ Fast = [bool]$Fast; Data = $result; Expires = $now.AddSeconds(30) }
    return $result
}

function Get-ConsoleWidth {
    try { $w = $Host.UI.RawUI.WindowSize.Width; if ($w -gt 0) { return $w } } catch {}
    return 100
}

function Get-DisplayText {
    [CmdletBinding()]
    param([string]$Text,[int]$MaxWidth)
    if(!$Text){return ''}
    if($Text.Length -le $MaxWidth){return $Text}
    if($MaxWidth -le 3){return $Text.Substring(0,[Math]::Max(0,$MaxWidth))}
    return $Text.Substring(0,$MaxWidth-3)+'...'
}

function Get-PathLabel {
    [CmdletBinding()]
    param([string]$Path)
    $resolved = Resolve-FullPath $Path
    if (-not $resolved) { return $null }
    $leaf = Split-Path -Path $resolved -Leaf
    if ($leaf) { return $leaf }
    return $resolved
}

function Format-CompactList {
    [CmdletBinding()]
    param([string[]]$Items,[int]$MaxItems=3)
    $labels = @($Items | Where-Object { $_ } | ForEach-Object { Get-PathLabel $_ } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $labels) { return 'none' }
    $shown = @($labels | Select-Object -First $MaxItems)
    $extra = $labels.Count - $shown.Count
    if ($extra -gt 0) { return ('{0} (+{1} more)' -f ($shown -join ', '), $extra) }
    return $shown -join ', '
}

function Get-SystemLocations {
    [CmdletBinding()]
    $wr = Get-EnvPath 'SystemRoot'
    $pd = Get-EnvPath 'ProgramData'
    $sd = Get-EnvPath 'SystemDrive'
    $sysLoc = [PSCustomObject]@{
        WindowsRoot  = $wr
        ProgramData  = $pd
        SystemDrive  = $sd
        WindowsTemp  = $(if($wr){Join-Path $wr 'Temp'})
        WerArchive   = $(if($pd){Join-Path $pd 'Microsoft\Windows\WER\ReportArchive'})
        WerQueue     = $(if($pd){Join-Path $pd 'Microsoft\Windows\WER\ReportQueue'})
        NetDownloader= $(if($pd){Join-Path $pd 'Microsoft\Network\Downloader'})
        SoftDistDL   = $(if($wr){Join-Path $wr 'SoftwareDistribution\Download'})
        Prefetch     = $(if($wr){Join-Path $wr 'Prefetch'})
        DeliveryOpt  = $(if($wr){Join-Path $wr 'SoftwareDistribution\DeliveryOptimization'})
        LiveKernel   = $(if($wr){Join-Path $wr 'LiveKernelReports'})
        RecycleBin   = $(if($sd){Join-Path $sd '$Recycle.Bin'})
    }
    return $sysLoc
}

function Get-LocationOptions {
    [CmdletBinding()]
    <#
    .SYNOPSIS
    Reads the optional per-location fields of an app definition.

    .DESCRIPTION
    A location names a cache root whose contents are cleared. Setting
    mode = 'entry' re-reads the location as a container whose matching children
    are themselves disposable, which is what install-staging leftovers need:
    the staged entry, not its contents, is the artifact. Absent fields keep the
    historical contents semantics, so existing definitions are unchanged.
    #>
    param([Parameter(Mandatory)][object]$Location)

    $mode = 'contents'
    if ($Location.PSObject.Properties['mode'] -and $Location.mode) { $mode = [string]$Location.mode }

    $patterns = @()
    if ($Location.PSObject.Properties['entryPatterns'] -and $Location.entryPatterns) { $patterns = @($Location.entryPatterns) }

    $entryType = 'any'
    if ($Location.PSObject.Properties['entryType'] -and $Location.entryType) { $entryType = [string]$Location.entryType }

    # 0 means "use the configured scan age"; a positive value overrides it.
    $minAgeDays = 0
    if ($Location.PSObject.Properties['minAgeDays'] -and $Location.minAgeDays) {
        $null = [int]::TryParse([string]$Location.minAgeDays, [ref]$minAgeDays)
    }

    return [PSCustomObject]@{
        Mode          = $mode
        EntryPatterns = $patterns
        EntryType     = $entryType
        MinAgeDays    = $minAgeDays
    }
}

function Get-AllAppDefinitions {
    [CmdletBinding()]
    <#
    .SYNOPSIS
    Loads all application definitions from every app-definitions/*.json file
    .PARAMETER Category
    Optional category filter. When supplied, only entries whose 'category' field
    matches (case-insensitive, wildcard) are returned. When omitted, every entry
    from every JSON file is returned.
    .OUTPUTS
    Array of app definition objects with Name, Path, Env, Process, Category,
    SourceFile, Mode, EntryPatterns, EntryType and MinAgeDays properties
    (flattened from locations).
    #>
    param([string]$Category)

    $appDefDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'app-definitions'
    if (-not (Test-Path -LiteralPath $appDefDir -PathType Container)) {
        Write-Verbose "App definitions directory not found at $appDefDir"
        return @()
    }

    $jsonFiles = @(Get-ChildItem -LiteralPath $appDefDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($jsonFiles.Count -eq 0) {
        Write-Verbose "No app definition JSON files found under $appDefDir"
        return @()
    }

    $flattened = [System.Collections.Generic.List[object]]::new()
    foreach ($jf in $jsonFiles) {
        try {
            $allApps = Get-Content -LiteralPath $jf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $allApps) { continue }

            foreach ($app in $allApps) {
                if (-not $app.name -or -not $app.locations) { continue }

                $appCategory = if ($app.PSObject.Properties['category']) { [string]$app.category } else { '' }

                # Optional filter by category
                if (-not [string]::IsNullOrWhiteSpace($Category)) {
                    if ([string]::IsNullOrWhiteSpace($appCategory)) { continue }
                    if ($appCategory -notlike $Category) { continue }
                }

                foreach ($loc in $app.locations) {
                    if (-not $loc.env -or $null -eq $loc.path) { continue }

                    # Get-EnvPath, not the raw environment call: it resolves the
                    # COMMONPROGRAMFILES86 alias to CommonProgramFiles(x86), whose
                    # literal name cannot be indexed as a normal env variable.
                    $envValue = Get-EnvPath ([string]$loc.env)
                    if (-not $envValue) { continue }

                    $fullPath = Join-Path $envValue ([string]$loc.path)
                    $options = Get-LocationOptions -Location $loc
                    $flattened.Add([PSCustomObject]@{
                        Name          = [string]$app.name
                        Path          = $fullPath
                        Env           = [string]$loc.env
                        Process       = $app.process
                        Category      = $appCategory
                        SourceFile    = $jf.Name
                        OrphanRule    = $app.orphanRule
                        Mode          = $options.Mode
                        EntryPatterns = $options.EntryPatterns
                        EntryType     = $options.EntryType
                        MinAgeDays    = $options.MinAgeDays
                    })
                }
            }
        } catch {
            Write-Verbose "Error loading app definitions from $($jf.Name): $($_.Exception.Message)"
        }
    }
    return @($flattened)
}

function Get-AppDefinitions {
    [CmdletBinding()]
    <#
    .SYNOPSIS
    Gets app definitions from a category-specific definition file
    .PARAMETER Category
    The category file basename to load (e.g., 'devtools-extended' loads
    app-definitions\devtools-extended.json). If the value ends in .json
    it is used as-is.
    .OUTPUTS
    Array of flattened app definition objects with Name, Path, Env, Process,
    Category, and SourceFile properties.
    #>
    param([string]$Category)

    if ([string]::IsNullOrWhiteSpace($Category)) {
        Write-Verbose 'Get-AppDefinitions: no category specified'
        return @()
    }

    $fileBase = $Category.TrimEnd('.json')
    $appDefPath = Join-Path (Split-Path -Parent $PSScriptRoot) ("app-definitions\{0}.json" -f $fileBase)
    if (-not (Test-Path -LiteralPath $appDefPath)) {
        Write-Verbose "App definitions file not found at $appDefPath"
        return @()
    }

    try {
        $allApps = Get-Content -LiteralPath $appDefPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $allApps) { return @() }

        $flattened = [System.Collections.Generic.List[object]]::new()
        foreach ($app in $allApps) {
            if (-not $app.name -or -not $app.locations) { continue }

            $appCategory = if ($app.PSObject.Properties['category']) { [string]$app.category } else { '' }

            foreach ($loc in $app.locations) {
                if (-not $loc.env -or $null -eq $loc.path) { continue }

                # Get-EnvPath, not the raw environment call: it resolves the
                # COMMONPROGRAMFILES86 alias to CommonProgramFiles(x86), whose
                # literal name cannot be indexed as a normal env variable.
                $envValue = Get-EnvPath ([string]$loc.env)
                if (-not $envValue) { continue }

                $fullPath = Join-Path $envValue ([string]$loc.path)
                $options = Get-LocationOptions -Location $loc
                $flattened.Add([PSCustomObject]@{
                    Name          = [string]$app.name
                    Path          = $fullPath
                    Env           = [string]$loc.env
                    Process       = $app.process
                    Category      = $appCategory
                    SourceFile    = (Split-Path -Leaf $appDefPath)
                    Mode          = $options.Mode
                    EntryPatterns = $options.EntryPatterns
                    EntryType     = $options.EntryType
                    MinAgeDays    = $options.MinAgeDays
                })
            }
        }
        return @($flattened)
    } catch {
        Write-Verbose "Error loading app definitions: $($_.Exception.Message)"
        return @()
    }
}

Export-ModuleMember -Function Get-ProtectedKnownFolders, Get-CoreSkippedItems, Get-CoreExcludedPaths, Get-FreeSpaceInfo, Get-DirectorySize, Get-DirectorySizeEstimate, Format-FileSize, New-TrackedSet, Resolve-FullPath, Resolve-RealPath, Get-EnvPath, Join-EnvPath, Test-IsAdministrator, Restart-Elevated, Get-ExcludedPaths, Test-IsExcludedPath, Get-DisposableDirectoryNames, Get-InstalledApplicationNames, Get-RunningProcessNames, Test-AnyProcessRunning, Register-SkippedItem, Get-HealthScore, Get-AllAppDefinitions, Get-AppDefinitions, Get-SystemLocations, Get-ConsoleWidth, Get-DisplayText, Get-PathLabel, Format-CompactList, Initialize-CoreSafetyState
