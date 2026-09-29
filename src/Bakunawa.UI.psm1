# Bakunawa.UI.psm1 -- Terminal rendering engine

if ($null -eq $script:TotalSteps) { $script:TotalSteps = 0 }
if ($null -eq $script:StepIndex)  { $script:StepIndex = 0 }

# NOTE: $script:LogFilePath is owned by THIS module. Set it only via Initialize-UiLogging -
# assigning it from outside (e.g. Bakunawa.ps1 script scope) silently does nothing.

function Initialize-UiLogging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path
    )
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $dir = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $script:LogFilePath = $full
        return $full
    } catch {
        throw "Initialize-UiLogging failed: $($_.Exception.Message)"
    }
}

function Test-VT100Supported {
    [CmdletBinding()]
    param()
    try { return $Host.UI.SupportsVirtualTerminal } catch { return $false }
}

function Get-ModeColor {
    [CmdletBinding()]
    param([string]$Mode)
    switch ($Mode) {
        'Standard'   { 'Green' }
        'Aggressive' { 'Yellow' }
        'Preview'    { 'DarkGray' }
        default      { 'DarkCyan' }
    }
}

function Write-Log {
    [CmdletBinding()]
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR','CMD','STEP','SIZE','SCAN')][string]$Level='INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $color = switch($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red' }
        'CMD'  { 'DarkGray' }
        'STEP' { 'Cyan' }
        'SIZE' { 'Magenta' }
        'SCAN' { 'Cyan' }
        default{ 'Gray' }
    }
    # Minimal console line: no timestamp, no glyph. Full detail goes to the file log.
    Write-ReviewLine ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
}

function Write-CommandLog {
    [CmdletBinding()]
    param([string]$Verb,[string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) { Write-Log $Verb 'CMD'; return }
    Write-Log "$Verb $Target" 'CMD'
}

function Write-CenteredLine {
    [CmdletBinding()]
    param([string]$Text,[string]$ForegroundColor='White')
    $cw = Get-ConsoleWidth
    $rt = Get-DisplayText $Text $cw
    $pad = [Math]::Max(0,[int](($cw-$rt.Length)/2))
    Write-Host ((' '*$pad)+$rt) -ForegroundColor $ForegroundColor
}

function Write-SectionHeader {
    [CmdletBinding()]
    param([string]$Title,[string]$ForegroundColor='White')
    $cw = Get-ConsoleWidth
    $useVT = Test-VT100Supported
    if ($useVT) {
        $boxH = [char]0x2500
        $line = $boxH.ToString() * [Math]::Max(0, $cw - 4)
        Write-Host (([char]0x250C).ToString()+"- $Title $line") -ForegroundColor $ForegroundColor
    } else {
        $prefix = "-- $Title "
        $line = $prefix + ('-' * [Math]::Max(0, $cw - $prefix.Length))
        Write-Host (Get-DisplayText $line $cw) -ForegroundColor $ForegroundColor
    }
}

function Write-Panel {
    [CmdletBinding()]
    param([string[]]$Lines,[string]$BorderColor='DarkCyan',[string]$TextColor='White',[int]$MinWidth=60,[int]$MaxWidth=92)
    $cw = Get-ConsoleWidth
    if ($cw -lt 8) { foreach ($line in $Lines) { Write-ReviewLine $line }; return }
    $longest = [int](($Lines | Measure-Object Length -Maximum).Maximum)
    $pw = [Math]::Min($cw - 2, [Math]::Min($MaxWidth, [Math]::Max($MinWidth, $longest + 4)))
    $iw = [Math]::Max(1, $pw - 4)
    $indent = ' ' * [Math]::Max(0, [int](($cw - $pw) / 2))
    $border = $indent + '+' + ('-' * ($pw - 2)) + '+'
    Write-Host $border -ForegroundColor $BorderColor
    foreach ($line in $Lines) {
        $remaining = [string]$line -replace '\x1B\[[0-?]*[ -/]*[@-~]', '' -replace '[\x00-\x1F\x7F]', ' '
        while ($remaining.Length -gt $iw) {
            $split = $remaining.LastIndexOf(' ', $iw)
            if ($split -lt [Math]::Max(1, [int]($iw / 2))) { $split = $iw }
            Write-Host ($indent + '| ' + $remaining.Substring(0, $split).PadRight($iw) + ' |') -ForegroundColor $TextColor
            $remaining = $remaining.Substring($split).TrimStart(' ')
        }
        Write-Host ($indent + '| ' + $remaining.PadRight($iw) + ' |') -ForegroundColor $TextColor
    }
    Write-Host $border -ForegroundColor $BorderColor
}

function Show-AppLogo {
    [CmdletBinding()]
    param()
    $logo = @(
        '▀█████████▄     ▄████████    ▄█   ▄█▄ ███    █▄  ███▄▄▄▄      ▄████████  ▄█     █▄     ▄████████'
        ' ███    ███   ███    ███   ███ ▄███▀ ███    ███ ███▀▀▀██▄   ███    ███ ███     ███   ███    ███'
        ' ███    ███   ███    ███   ███▐██▀   ███    ███ ███   ███   ███    ███ ███     ███   ███    ███'
        ' ▄███▄▄▄██▀    ███    ███  ▄█████▀    ███    ███ ███   ███   ███    ███ ███     ███   ███    ███'
        '▀▀███▀▀▀██▄  ▀███████████ ▀▀█████▄    ███    ███ ███   ███ ▀███████████ ███     ███ ▀███████████'
        ' ███    ██▄   ███    ███   ███▐██▄   ███    ███ ███   ███   ███    ███ ███     ███   ███    ███'
        ' ███    ███   ███    ███   ███ ▀███▄ ███    ███ ███   ███   ███    ███ ███ ▄█▄ ███   ███    ███'
        ' ▄█████████▀    ███    █▀    ███   ▀█▀ ████████▀   ▀█   █▀    ███    █▀   ▀███▀███▀    ███    █▀ '
        '                            ▀                                                                   '
        '                     D E V O U R   Y O U R   D I G I T A L   W A S T E'
    )
    for ($index = 0; $index -lt $logo.Count; $index++) {
        Write-CenteredLine $logo[$index] 'White'
    }
}

# ── GLYPHS ──
# Monochrome glyph helpers for headers and status lines. The serpent animation
# engine was removed with the minimal-UI redesign; these survive because live
# rendering still uses them.

function Get-ThemedGlyph {
    [CmdletBinding()]
    param([ValidateSet('Step','Ok','Warn','Err','Cmd','Scan','Size','Info','Serp','Flame')][string]$Kind)
    switch ($Kind) {
        'Step'  { return '>>' }
        'Ok'    { return '[+]' }
        'Warn'  { return '[!]' }
        'Err'   { return '[X]' }
        'Cmd'   { return '>' }
        'Scan'  { return '[S]' }
        'Size'  { return 'vv' }
        'Info'  { return '[i]' }
        'Serp'  { return '~' }
        'Flame' { return '*' }
        default { return '#' }
    }
}

function Get-MoonPhaseGlyph {
    [CmdletBinding()]
    param([int]$Percent)
    if (Test-VT100Supported) {
        # Monochrome geometric circles (no emoji): new -> crescent -> half -> gibbous -> full
        $moon = @(
            [char]0x25CB,  # ○
            [char]0x25D0,  # ◐
            [char]0x25D2,  # ◒
            [char]0x25D5,  # ◕
            [char]0x25CF   # ●
        )
        $idx = [Math]::Min(4, [Math]::Max(0, [int]($Percent / 25)))
        return $moon[$idx]
    }
    $ascii = @('o','O','@','*')
    $idx = [Math]::Min(3, [Math]::Max(0, [int]($Percent / 34)))
    return $ascii[$idx]
}

function Reset-CleanupProgress {
    $script:StepIndex = 0
    $script:TotalSteps = 0
    $script:ActiveStepName = $null
}

function Set-UiContext {
    param([string]$Mode, $Result)
    if ($Mode) { $script:CurrentModeName = $Mode }
    $script:ExcludedPaths = @(Get-CoreExcludedPaths)
    $script:RunningProcesses = Get-RunningProcessNames
    if ($Result) {
        $script:LastRunSummary = @{ Mode = $Result.Mode; DurationSeconds = $Result.DurationSec; TotalFreed = $Result.BytesFreed; IsPreview = $Result.IsPreview }
    }
}

function Start-Step {
    [CmdletBinding()]
    param([string]$Name, [int]$Total = 0)
    $script:StepIndex++
    if ($Total -gt 0) { $script:TotalSteps = $Total }
    elseif (-not $script:TotalSteps -or $script:TotalSteps -le 0) { $script:TotalSteps = $script:StepIndex }
    Write-Host ''
    $stepTag = if ($script:TotalSteps -gt 0) { '[{0:D2}/{1:D2}]' -f $script:StepIndex, $script:TotalSteps } else { '[--/--]' }
    Write-ReviewLine ("{0} {1}" -f $stepTag, $Name)
    $script:ActiveStepName = $Name; $script:ActiveStepPct = 0
    $script:StepWatch = [Diagnostics.Stopwatch]::StartNew()
    if (-not $script:NoAnimations) {
        Write-Progress -Id 1 -Activity 'Bakunawa / categories' -Status "$stepTag $Name" -PercentComplete ([int](100 * ($script:StepIndex - 1) / $script:TotalSteps))
    }
    try { $Host.UI.RawUI.WindowTitle = "Bakunawa $($script:StepIndex)/$($script:TotalSteps) $Name" } catch {}
}

function Finish-Step {
    [CmdletBinding()]
    param([string]$Summary)
    $script:ActiveStepName = $null
    if ($Summary) {
        Write-ReviewLine ("  Done in {0} | {1}" -f (Format-ReportDuration $script:StepWatch.Elapsed.TotalSeconds), $Summary) -ForegroundColor Gray
    }
    if ($script:StepIndex -ge $script:TotalSteps -and $script:TotalSteps -gt 0) {
        Write-Progress -Activity 'Bakunawa' -Completed -Id 1
        try { $Host.UI.RawUI.WindowTitle = 'Bakunawa - done' } catch {}
    }
}

function Show-Header {
    [CmdletBinding()]
    param()
    if (-not $script:CurrentModeName) { $script:CurrentModeName = 'Menu' }
    Clear-Host; Write-Host ''; Show-AppLogo; Write-Host ''
    $modeColor = Get-ModeColor $script:CurrentModeName
    $free = Get-FreeSpaceInfo
    $ml = if($script:CurrentModeName -eq 'Menu'){'INTERACTIVE'}else{$script:CurrentModeName.ToUpperInvariant()}
    $lr = if ($script:LastRunSummary) {
        $label = if ($script:LastRunSummary.IsPreview) { 'estimated' } else { 'deleted' }
        "$($script:LastRunSummary.Mode) | $(Format-ReportDuration $script:LastRunSummary.DurationSeconds) | $(Format-FileSize $script:LastRunSummary.TotalFreed) $label"
    } else { 'none yet' }
    $protected = Format-CompactList -Items ($script:ExcludedPaths | Sort-Object) -MaxItems 3
    # Dynamic run bar that reflects current mode and progress
    if($script:CurrentModeName -eq 'Menu'){
        $runBar = '[..................] idle'
    } elseif ($script:CurrentModeName -eq 'Scan') {
        # For scan mode, show a pulsing indicator since it's a single long-running operation
        $runBar = '[..................] preparing scan'
    } else {
        # For cleanup modes, show step progress
        $runBar = New-AsciiBar -Value $script:StepIndex -Total $script:TotalSteps -Width 18
    }
    $freePct = if ($free.TotalMB -gt 0) { [math]::Round(100 * $free.MB / $free.TotalMB) } else { 0 }
    Write-Panel @(
        "Mode       : $ml"
        'Scope      : Local disk C: only'
        "Free       : $($free.GB) GB / $($free.TotalGB) GB ($freePct% available)"
        "Protected  : $protected"
        "Last run   : $lr"
        "Run bar    : $runBar"
    ) -BorderColor $modeColor -TextColor 'White' -MinWidth 62 -MaxWidth 92
    Write-Host ''
}

function Show-CleanupPotential {
    [CmdletBinding()]
    param([ValidateSet('Standard','Aggressive','Preview')][string]$Mode = 'Standard')
    $effectiveMode = if ($Mode -eq 'Preview') { 'Standard' } else { $Mode }
    $potential = @(Get-CleanupPotential -Mode $effectiveMode)
    if (-not $potential -or $potential.Count -eq 0) {
        Write-Log 'No cleanup potential data available.' 'WARN'
        return
    }
    Write-SectionHeader 'Cleanup Potential'
    Write-Host ("  {0,-22} {1,12} {2,8}" -f 'Task', 'Size', 'Targets') -ForegroundColor Cyan
    foreach ($item in $potential) {
        Write-Host ("  {0,-22} {1,12} {2,8}" -f $item.Task, (Format-FileSize $item.EstimatedBytes), $item.FileCount) -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Show-Menu {
    [CmdletBinding()]
    param()
    while ($true) {
        $script:CurrentModeName = 'Menu'
        Show-Header
        $runningApps = @()
        if ($script:RunningProcesses) {
            $checkNames = @('chrome','msedge','brave','firefox','discord','slack','teams','spotify','Code')
            $runningApps = $checkNames | Where-Object { $script:RunningProcesses.Contains($_) } | ForEach-Object {
                $label = switch ($_) {
                    'chrome' { 'Chrome' }; 'msedge' { 'Edge' }; 'brave' { 'Brave' }; 'firefox' { 'Firefox' }
                    'discord' { 'Discord' }; 'slack' { 'Slack' }; 'teams' { 'Teams' }; 'spotify' { 'Spotify' }
                    'Code' { 'VS Code' }; default { $_ }
                }
                $label
            }
        }
        $menuLines = [System.Collections.Generic.List[string]]::new()
        [void]$menuLines.Add('MAIN MENU'); [void]$menuLines.Add('')
        [void]$menuLines.Add('[1] Standard    temp, browsers, apps, orphans')
        [void]$menuLines.Add('[2] Aggressive  + Windows components + prefetch')
        [void]$menuLines.Add('[3] Preview     dry run -- see plan only')
        [void]$menuLines.Add('[4] Scan C:     caches, leftovers, review and restore')
        [void]$menuLines.Add('[5] Health      detailed system health report')
        [void]$menuLines.Add('')
        [void]$menuLines.Add('Start with [3] Preview. Use [4] to review the largest findings.')
        [void]$menuLines.Add('Other drives and busy application caches are skipped.')
        [void]$menuLines.Add('[Q] Quit')
        if ($runningApps.Count -gt 0) {
            [void]$menuLines.Add('')
            [void]$menuLines.Add("Running -- skipped: $($runningApps -join ', ')")
        }
        Write-Panel @($menuLines) -BorderColor 'Cyan' -TextColor 'White' -MinWidth 64 -MaxWidth 88
        Write-Host ''
        Write-CenteredLine 'Choose a mode and press Enter.' 'DarkGray'
        Write-Host ''
        $choice = Read-Host 'Selection'
if (-not $choice) { continue }
$choice = $choice.Trim().ToUpperInvariant()
        switch ($choice) {
            '1' { Invoke-LoggedOperation -Mode Standard -Action { Show-CleanupResult (Invoke-CleanupRun 'Standard') }; [void](Read-Host '[Press Enter to return to Menu]') }
            '2' { Invoke-LoggedOperation -Mode Aggressive -Action { Show-CleanupResult (Invoke-CleanupRun 'Aggressive') }; [void](Read-Host '[Press Enter to return to Menu]') }
            '3' { Invoke-LoggedOperation -Mode Preview -Action { Show-CleanupResult (Invoke-CleanupRun 'Preview') }; [void](Read-Host '[Press Enter to return to Menu]') }
            '4' { Invoke-LoggedOperation -Mode Scan -Action { $null = Find-OrphanFolders -Refresh; Show-OrphanScanResults -ScanResult (Get-OrphanScanReport) -Interactive }; [void](Read-Host '[Press Enter to return to Menu]') }
            '5' { Invoke-LoggedOperation -Mode Health -Action { Show-HealthDetail }; [void](Read-Host '[Press Enter to return to Menu]') }
            'Q' { return }
            default { Write-Host 'Invalid.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 500 }
        }
    }
}

function Show-RunSummary {
    [CmdletBinding()]
    param(
        [string]$Mode, [double]$Duration, $StartSpace, $EndSpace,
        [hashtable]$Steps, [switch]$Aggressive, [int]$LogsCl
    )
    $summaryColor = Get-ModeColor $Mode
    $sumLines = @(
        "Run summary  : $($Mode.ToUpper())"
        "Finished     : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
        "Duration     : ${Duration}s"
        "Before       : $($StartSpace.MB) MB ($($StartSpace.GB) GB)"
        "After        : $($EndSpace.MB) MB ($($EndSpace.GB) GB)"
        "Measured     : $(Format-FileSize ([Math]::Max(0, $script:BytesFreed)))"
        "Observed     : $($EndSpace.MB - $StartSpace.MB) MB ($([math]::Round(($EndSpace.MB - $StartSpace.MB)/1024,2)) GB)"
    )
    Write-Host ''
    Write-Panel $sumLines -BorderColor $summaryColor -TextColor 'White' -MinWidth 58 -MaxWidth 86
    Write-Host ''
    if ($script:CategorySizes.Count -gt 0) {
        Write-SectionHeader 'Category Breakdown'
        $script:CategorySizes.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            Write-Host ("  {0,-22} {1,12}" -f $_.Key, (Format-FileSize $_.Value)) -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    Write-SectionHeader 'Impact'
    Write-Host ("  {0,-16} {1}" -f 'System caches', $Steps.s1) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Browsers', "$($Steps.s2) Chromium | $($Steps.s3) Firefox") -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'App caches', $Steps.s4) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Dev caches', $Steps.s5) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'GPU/Shell', $Steps.s6) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Log files', $Steps.s8) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Empty folders', $Steps.emptyRm) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Stale junk', $Steps.staleRm) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Orphans', $Steps.orphans) -ForegroundColor $(if($Steps.orphans -gt 0){'Yellow'}else{'DarkGray'})
    if ($script:SkippedItems.Count -gt 0) {
        Write-Host ''; Write-SectionHeader 'Safety Skips'
        $script:SkippedItems | Group-Object Reason | Sort-Object Count -Descending | ForEach-Object {
            Write-Host ("  {0,2}x {1}" -f $_.Count, $_.Name) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    if ($script:IsPreview) { Write-Log 'PREVIEW mode. Nothing was deleted.' 'WARN' }
    elseif ($script:IsAggressive) { Write-Log 'Aggressive mode completed with extras.' 'WARN' }
}

. (Join-Path $PSScriptRoot 'Bakunawa.Reporting.ps1')
. (Join-Path $PSScriptRoot 'Bakunawa.Review.ps1')


function Show-HealthDetail {
    [CmdletBinding()]
    param()
    Write-ReviewLine 'Measuring temporary data and reading drive capacity...' -ForegroundColor Cyan
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $health = Get-HealthScore
    Write-ReportHeading 'STORAGE HEALTH SUMMARY'
    Write-ReportMetric 'Elapsed' (Format-ReportDuration $watch.Elapsed.TotalSeconds)
    Write-ReportMetric 'C: storage score' ("{0}/100 - {1}" -f $health.Score, $health.Grade)
    Write-ReportMetric 'C: free space' ("{0}%" -f $health.DiskPct)
    Write-ReportMetric 'Estimated temp data' (Format-FileSize ($health.TempMB * 1MB))
    Write-ReviewLine 'This score is a cleanup estimate, not a disk hardware diagnostic.'
    Write-ReviewLine 'Health measurements do not establish complete filesystem coverage.' -ForegroundColor Gray
    foreach ($root in @(Get-ScanDriveRoots)) {
        try {
            $drive = [IO.DriveInfo]::new($root)
            if ($drive.IsReady) { Write-ReviewLine ("{0}  {1} available / {2} total" -f $root, (Format-FileSize $drive.AvailableFreeSpace), (Format-FileSize $drive.TotalSize)) }
            else { Write-ReviewLine "$root unavailable" }
        } catch { Write-ReviewLine "$root could not be read: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function @(
    'Invoke-LoggedOperation',
    'Get-ScanLogPath',
    'Set-UiOptions',
    'Write-ScanLogText',
    'Write-ScanReportLog',
    'Write-ScanProgress',
    'Write-ReportHeading',
    'Write-ReportMetric',
    'Format-ReportDuration',
    'Initialize-UiLogging',
    'Write-Log',
    'Write-CommandLog',
    'Write-CenteredLine',
    'Write-SectionHeader',
    'Write-Panel',
    'Show-AppLogo',
    'Get-ThemedGlyph',
    'Get-MoonPhaseGlyph',
    'Start-Step',
    'Reset-CleanupProgress',
    'Set-UiContext',
    'Finish-Step',
    'Show-Header',
    'Show-CleanupPotential',
    'Show-Menu',
    'Show-RunSummary',
    'Export-ScanReport',
    'Show-OrphanScanResults',
    'Show-CleanupResult',
    'Write-ReviewLine',
    'Show-HealthDetail',
    'Test-VT100Supported',
    'Get-ModeColor'
)
