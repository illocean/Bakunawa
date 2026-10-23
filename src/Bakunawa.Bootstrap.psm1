<#
    Bakunawa.Bootstrap.psm1 - session orchestration for the cleaner.

    The launcher script keeps the host-process concerns: elevation, terminal
    relaunch, exit codes. Everything the cleaner itself does lives here:
    resolve the mode, prepare the session, dispatch the run.

    The cleanup state is deliberately NOT initialized while the session is
    prepared. Expanding every app definition takes seconds, and only the modes
    that touch the filesystem need it. The session scope (config, scan roots,
    extra exclusions) is stored instead, and Initialize-CleanupState picks it
    up when a mode starts. That keeps the menu instant and every cleanup run
    to a single initialization.
#>

$script:ValidModes = @('Menu', 'Standard', 'Aggressive', 'Preview', 'Scan', 'Health', 'Benchmark')

foreach ($name in @('Core', 'Config', 'Cleanup', 'UI')) {
    $moduleName = "Bakunawa.$name"
    if (-not (Get-Module -Name $moduleName)) {
        Import-Module (Join-Path $PSScriptRoot "$moduleName.psm1") -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
    }
}

function Show-RunSummary {
    param([PSCustomObject]$Result)
    Show-CleanupResult -Result $Result
}

function Resolve-BakunawaMode {
    [CmdletBinding()]
    <#
    .SYNOPSIS
    Resolves the effective mode from the requested mode and an optional profile.
    .DESCRIPTION
    Never exits and never writes to the host: the caller decides what an
    invalid mode or profile means. The profile only takes over when the caller
    did not name a mode explicitly.
    .OUTPUTS
    PSCustomObject with Mode, Error and Warning.
    #>
    param(
        [string]$Mode = 'Menu',
        [string]$Profile,
        [string]$ProfileRoot,
        [switch]$ModeWasSpecified
    )

    $result = [PSCustomObject]@{ Mode = $Mode; Error = $null; Warning = $null }

    if ($Mode -notin $script:ValidModes) {
        $result.Error = "Invalid mode: '$Mode'. Valid modes: $($script:ValidModes -join ', ')"
        return $result
    }

    if (-not $Profile) { return $result }

    $profilePath = Join-Path $ProfileRoot "profiles\$Profile.json"
    if (-not (Test-Path -LiteralPath $profilePath)) {
        $result.Error = "Profile file not found: $profilePath"
        return $result
    }

    try {
        $profileConfig = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($profileConfig.aggressive -and $null -ne $profileConfig.aggressive.enabled -and $profileConfig.aggressive.enabled -isnot [bool]) {
            throw 'Profile aggressive.enabled must be a JSON boolean.'
        }
        if ($profileConfig.mode -and -not $ModeWasSpecified) {
            if ($profileConfig.mode -in $script:ValidModes) {
                $result.Mode = [string]$profileConfig.mode
            } else {
                $result.Warning = "Profile specifies invalid mode: '$($profileConfig.mode)'. Using '$Mode'."
            }
        }
        # The flag chooses Aggressive only when the caller did not specify a mode.
        if (-not $ModeWasSpecified -and $profileConfig.aggressive.enabled) { $result.Mode = 'Aggressive' }
    } catch {
        $result.Error = "Failed to load profile '$Profile': $($_.Exception.Message)"
    }

    return $result
}

function Initialize-BakunawaSession {
    [CmdletBinding()]
    <#
    .SYNOPSIS
    Prepares everything a run needs, without touching the filesystem.
    .DESCRIPTION
    Sets up logging, the config module, the UI context and the cleanup session
    scope. The cleanup state itself is initialized by the mode that needs it.
    #>
    param(
        [string]$Mode = 'Menu',
        [string]$ConfigPath,
        [string[]]$ScanRoot,
        [string[]]$ExtraExcludePath,
        [switch]$VerboseScan,
        [switch]$NoAnimations,
        [string]$LogFile
    )

    # The UI module owns the log path: explicit single-writer contract.
    if ($LogFile -and $Mode -ne 'Preview') {
        try {
            $null = Initialize-UiLogging -Path $LogFile
        } catch {
            throw "Invalid log file path: $($_.Exception.Message)"
        }
    }

    if (-not $ConfigPath) { $ConfigPath = Join-Path $env:APPDATA 'Bakunawa\config.json' }
    Initialize-ConfigModule -ConfigPath $ConfigPath
    $config = Get-UserConfig -ConfigPath $ConfigPath

    $exclusions = @()
    if ($config.extraExcludePaths) { $exclusions += @($config.extraExcludePaths) }
    if ($ExtraExcludePath) { $exclusions += @($ExtraExcludePath) }

    Set-UiContext -Mode $Mode
    Set-UiOptions -NoAnimations:$NoAnimations

    # Store the scope; the state is built when a mode asks for it.
    Set-CleanupSessionScope -Config $config -ScanRoot $ScanRoot -ExtraExcludePath $exclusions -VerboseScan:$VerboseScan

    return [PSCustomObject]@{ Config = $config; Exclusions = $exclusions }
}

function Invoke-BakunawaMode {
    [CmdletBinding()]
    <#
    .SYNOPSIS
    Runs the resolved mode.
    .DESCRIPTION
    Each arm initializes the cleanup state only when it needs it. The cleanup
    modes initialize it inside Invoke-CleanupRun; Scan and Benchmark initialize
    it here; Health and Menu do not need it.
    #>
    param(
        [string]$Mode = 'Menu',
        [string]$ReportPath
    )

    $runMode = {
        switch ($Mode) {
            'Standard'   {
                Show-RunSummary (Invoke-CleanupRun -Mode 'Standard')
                Write-Host ''
            }
            'Aggressive' {
                Show-RunSummary (Invoke-CleanupRun -Mode 'Aggressive')
                Write-Host ''
            }
            'Preview'    {
                Show-RunSummary (Invoke-CleanupRun -Mode 'Preview' -WhatIf)
                Write-Host ''
            }
            'Scan'       {
                Show-Header
                Initialize-CleanupState -ModeName 'Scan'
                $null = Find-OrphanFolders -Refresh
                $report = Get-OrphanScanReport
                Show-OrphanScanResults -ScanResult $report
                if ($ReportPath) {
                    Export-ScanReport -Report $report -Path $ReportPath
                    Write-ReviewLine "Report saved: $ReportPath"
                }
            }
            'Health'     {
                Show-Header
                Show-HealthDetail
                Write-Host ''
            }
            'Benchmark'  {
                Show-Header
                Write-Log 'Running performance benchmark...' 'INFO'
                Write-Log 'This will scan all cleanup categories without deleting anything.' 'INFO'
                Write-Host ''

                Initialize-CleanupState -ModeName 'Benchmark'

                $totalSb = [System.Diagnostics.Stopwatch]::StartNew()
                $categoryTimes = @{}

                $tasks = Get-CleanupTasks -Mode 'Standard'
                Reset-CleanupProgress
                foreach ($task in $tasks) {
                    Start-Step -Name $task.Name -Total $tasks.Count
                    $taskSb = [System.Diagnostics.Stopwatch]::StartNew()
                    $potential = Get-CleanupPotential -Mode 'Standard' -TaskName $task.Name
                    $taskSb.Stop()
                    $categoryTimes[$task.Name] = [math]::Round($taskSb.Elapsed.TotalMilliseconds, 2)
                    if ($potential) {
                        Write-Log ("{0} | {1} ms | Estimated: {2} | {3} locations" -f $task.Name, $categoryTimes[$task.Name], (Format-FileSize $potential.EstimatedBytes), $potential.FileCount) 'SCAN'
                    } else {
                        Write-Log ("{0} | {1} ms | No data" -f $task.Name, $categoryTimes[$task.Name]) 'SCAN'
                    }
                    Finish-Step -Summary 'Measurement finished'
                }

                $totalSb.Stop()
                $totalMs = [math]::Round($totalSb.Elapsed.TotalMilliseconds, 2)

                Write-Host ''
                Write-ReportTitle 'Benchmark summary' -Meta (Format-ReportDuration $totalSb.Elapsed.TotalSeconds)
                Write-ReportRow ('Total milliseconds  {0}' -f $totalMs)
                Write-ReportRow ('Categories measured  {0}' -f $tasks.Count)
                Write-ReportRow ('Recorded errors  {0}' -f @(Get-CleanupErrorLog).Count)
                Write-ReportRow 'Category estimates do not establish complete filesystem coverage.' -Color DarkGray
                Write-ReportRow 'Slowest categories:' -Color DarkGray

                # Show top 5 slowest categories
                $sorted = $categoryTimes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5
                foreach ($entry in $sorted) {
                    Write-ReportRow ('{0}{1,8} ms' -f ('    ' + $entry.Key), $entry.Value) -Color DarkGray
                    Write-ScanLogText ("{0}: {1}ms" -f $entry.Key, $entry.Value)
                }

                Write-ReportRow 'Timing depends on data size, access, and cached results. No files were deleted.' -Color DarkGray

                Write-Host ''
            }
            default      { Show-Menu }
        }
    }

    if ($Mode -eq 'Menu') { & $runMode }
    else { Invoke-LoggedOperation -Mode $Mode -Action $runMode }
}

Export-ModuleMember -Function @(
    'Resolve-BakunawaMode',
    'Initialize-BakunawaSession',
    'Invoke-BakunawaMode',
    'Show-RunSummary'
)
