<#
Bakunawa v4.0 - Self-Contained System Cleaner
Modular architecture with separate modules in src/
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Standard', 'Aggressive', 'Preview', 'Scan', 'Health', 'Benchmark')]
    [string]$Mode = 'Menu',
    [switch]$NoPause,
    [switch]$VerboseScan,
    [string[]]$ExtraExcludePath,
    [string]$LogFile,
    [string]$Profile,
    [switch]$SkipBootstrap,
    [switch]$ForceAdmin,
    [switch]$NoAnimations,
    [string[]]$ScanRoot,
    [string]$ReportPath
)

Set-Variable -Name ErrorActionPreference -Value 'Continue' -Scope Script
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Animation frames
$script:SpinnerFrames = @('|','/','-','\')
$script:SpinnerIndex = 0
$script:WaveFrames = @('1','2','3','4','5','6','7','8')
$script:WaveIndex = 0
$script:PulseFrames = @('o','O','@','*')
$script:PulseIndex = 0

# Import modules from src/
$moduleDir = Join-Path $PSScriptRoot 'src'
Import-Module (Join-Path $moduleDir 'Bakunawa.Core.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
Import-Module (Join-Path $moduleDir 'Bakunawa.Config.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
Import-Module (Join-Path $moduleDir 'Bakunawa.Runspace.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
Import-Module (Join-Path $moduleDir 'Bakunawa.Cleanup.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
Import-Module (Join-Path $moduleDir 'Bakunawa.UI.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue

function Show-RunSummary {
    param([PSCustomObject]$Result)
    Show-CleanupResult -Result $Result
}

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
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
    $entry = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $PSScriptRoot 'Bakunawa.ps1' }
    # Serialize arguments as data so arrays, spaces, apostrophes and dollar signs survive elevation.
    $forward = @{ Mode = $SelectedMode }
    foreach ($name in @('ForceAdmin','NoAnimations','VerboseScan','NoPause')) {
        if (Get-Variable -Name $name -ValueOnly) { $forward[$name] = $true }
    }
    foreach ($name in @('ExtraExcludePath','LogFile','ScanRoot','ReportPath','Profile')) {
        $value = Get-Variable -Name $name -ValueOnly
        if ($value) { $forward[$name] = $value }
    }
    $data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($forward)))
    $body = '$forward = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''{0}''))); & ''{1}'' @forward' -f $data, $entry.Replace("'", "''")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $cmd = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    Write-Host ''
    Write-Host 'Administrator rights required. Requesting elevation...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $cmd | Out-Null
        return $true
    } catch {
        Write-Host "Elevation failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

if (-not $SkipBootstrap) {
    # Validate mode against allowed values
    $validModes = @('Menu', 'Standard', 'Aggressive', 'Preview', 'Scan', 'Health', 'Benchmark')
    if ($Mode -notin $validModes) {
        Write-Host "Invalid mode: '$Mode'. Valid modes: $($validModes -join ', ')" -ForegroundColor Red
        exit 1
    }

    # Profile handling with validation
    if ($Profile) {
        $profilePath = Join-Path $PSScriptRoot "profiles\$Profile.json"
        if (Test-Path -LiteralPath $profilePath) {
            try {
                $profileConfig = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                if ($profileConfig.aggressive -and $null -ne $profileConfig.aggressive.enabled -and $profileConfig.aggressive.enabled -isnot [bool]) {
                    throw 'Profile aggressive.enabled must be a JSON boolean.'
                }
                if ($profileConfig.mode -and -not $PSBoundParameters.ContainsKey('Mode')) {
                    if ($profileConfig.mode -in $validModes) {
                        $Mode = $profileConfig.mode
                    } else {
                        Write-Host "Profile specifies invalid mode: '$($profileConfig.mode)'. Using '$Mode'." -ForegroundColor Yellow
                    }
                }
                # The flag chooses Aggressive only when the caller did not specify a mode.
                if (-not $PSBoundParameters.ContainsKey('Mode') -and $profileConfig.aggressive.enabled) { $Mode = 'Aggressive' }
            } catch {
                Write-Host "Failed to load profile '$Profile': $($_.Exception.Message)" -ForegroundColor Red
                exit 1
            }
        } else {
            Write-Host "Profile file not found: $profilePath" -ForegroundColor Red
            exit 1
        }
    }

    # Admin check for modes that require it (Menu requires admin for cleanup actions)
    $needsAdmin = $Mode -in @('Menu','Standard','Aggressive') -and -not (Test-IsAdministrator) -and -not $ForceAdmin
    if ($needsAdmin) {
        Write-Host "$Mode mode requires administrator privileges for full system access." -ForegroundColor Yellow
        if (-not (Restart-Elevated -SelectedMode $Mode)) {
            Write-Host ''
            Write-Host 'Automatic elevation failed. Without admin rights, system-level cleanup fails with "Access is denied".' -ForegroundColor Red
            Write-Host 'Fix: right-click PowerShell, choose "Run as administrator", then run Bakunawa again.' -ForegroundColor Yellow
            Write-Host '      (Your account must be in the local Administrators group and UAC must be enabled.)' -ForegroundColor Yellow
            exit 1
        }
        exit 0
    }

    if ($ExtraExcludePath) { $script:ExtraExcludePaths = $ExtraExcludePath }
    
    # Validate and set log file path (explicit single-writer contract via UI module)
    if ($LogFile -and $Mode -ne 'Preview') {
        try {
            $null = Initialize-UiLogging -Path $LogFile
        } catch {
            Write-Host "Invalid log file path: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    }

    # Initialize config module with default path
    $configPath = Join-Path $env:APPDATA 'Bakunawa\config.json'
    Initialize-ConfigModule -ConfigPath $configPath

    $config = Get-UserConfig -ConfigPath $configPath
    $extraExclusions = @()
    if ($config.extraExcludePaths) { $extraExclusions += $config.extraExcludePaths }
    if ($script:ExtraExcludePaths) { $extraExclusions += $script:ExtraExcludePaths }

    Initialize-CleanupState -Config $config -ScanRoot $ScanRoot -ExtraExcludePath $extraExclusions -VerboseScan:$VerboseScan -Aggressive:($Mode -eq 'Aggressive')
    Set-UiContext -Mode $Mode
    Set-UiOptions -NoAnimations:$NoAnimations

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
            Write-ReportHeading 'BENCHMARK SUMMARY'
            Write-ReportMetric 'Elapsed' (Format-ReportDuration $totalSb.Elapsed.TotalSeconds)
            Write-ReportMetric 'Total milliseconds' ([string]$totalMs)
            Write-ReportMetric 'Categories measured' ([string]$tasks.Count)
            Write-ReportMetric 'Recorded errors' ([string]@(Get-CleanupErrorLog).Count)
            Write-ReviewLine 'Category estimates do not establish complete filesystem coverage.'
            Write-ReviewLine 'Slowest categories:'
            
            # Show top 5 slowest categories
            $sorted = $categoryTimes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5
            foreach ($entry in $sorted) {
                Write-Log "  $($entry.Key): $($entry.Value)ms" 'SIZE'
            }
            
            Write-ReviewLine 'Timing depends on data size, access, and cached results. No files were deleted.'
            
            Write-Host ''
        }
        default      { Show-Menu }
    }
    }
    if ($Mode -eq 'Menu') { & $runMode }
    else { Invoke-LoggedOperation -Mode $Mode -Action $runMode }

    if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
}
