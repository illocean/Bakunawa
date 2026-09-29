#requires -Version 5.1
BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot/..").Path
    foreach ($module in @('Core','Config','Cleanup','UI')) {
        Import-Module "$repo/src/Bakunawa.$module.psm1" -Force -DisableNameChecking
    }
}

Describe 'Command-line mode routing' {
    BeforeEach {
        $logRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName Bakunawa.UI Get-ScanLogDirectory { $logRoot }
        Mock Import-Module {}
        Mock Initialize-ConfigModule {}
        Mock Get-UserConfig { @{} }
        Mock Initialize-CleanupState {}
        Mock Set-UiContext {}
        Mock -ModuleName Bakunawa.UI Set-UiContext {}
        Mock Show-Header {}
        Mock Show-HealthDetail { Write-ReviewLine 'Fixture health summary' }
        Mock Find-OrphanFolders { @() }
        Mock Get-OrphanScanReport { @{ Findings = @(); Coverage = @(); Issues = @(); DurationSec = 0 } }
        Mock Get-CleanupTasks { @([pscustomobject]@{ Name = 'Fixture category'; Parallel = $false }) }
        Mock Get-CleanupPotential { [pscustomobject]@{ EstimatedBytes = 4096; FileCount = 1 } }
        Mock Get-CleanupErrorLog { @() }
        # A second guard prevents accidental live cleanup if a routing mock is missed.
        Mock -ModuleName Bakunawa.Cleanup Get-CleanupTasks { throw 'Unexpected real cleanup in routing test' }
        Mock Invoke-CleanupRun {
            param($Mode)
            [pscustomobject]@{ Mode = $Mode; IsPreview = ($Mode -eq 'Preview'); DurationSec = 0;
                PathsCleared = 0; BytesFreed = 0; Errors = @();
                SkippedItems = @(); CategorySizes = @{}; ScanReport = $null }
        }
        & (Get-Module Bakunawa.UI) { $script:LogFilePath = $null; $script:ScanLogPath = $null }
    }

    It 'runs the <RunMode> entry point through automatic logging' -TestCases @(
        @{ RunMode = 'Standard'; Expected = 'CLEANUP SUMMARY' },
        @{ RunMode = 'Aggressive'; Expected = 'CLEANUP SUMMARY' },
        @{ RunMode = 'Scan'; Expected = 'SCAN SUMMARY' },
        @{ RunMode = 'Health'; Expected = 'Fixture health summary' },
        @{ RunMode = 'Benchmark'; Expected = 'BENCHMARK SUMMARY' }
    ) {
        param($RunMode, $Expected)
        & "$repo/Bakunawa.ps1" -Mode $RunMode -NoPause -NoAnimations -ForceAdmin
        $logs = @(Get-ChildItem -LiteralPath $logRoot -Filter *.txt)
        $logs.Count | Should -Be 1
        $text = Get-Content -LiteralPath $logs[0].FullName -Raw
        $text | Should -Match $Expected
        $text | Should -Match 'RUN FINISHED'
        Should -Invoke Get-UserConfig -Times 0 -Exactly -ParameterFilter { $UseDefault }
    }
}

Describe 'Runtime report scope respects configuration' {
    It 'retains configured exclusions and disabled tasks after config helpers read configuration' {
        Import-Module "$repo/src/Bakunawa.Config.psm1" -Force -DisableNameChecking
        $cfg = Get-DefaultConfig
        $cfg.taskCategories['System Caches'].enabled = $false
        $cfg.exclusions.userCustomExclusions = @((Join-Path $TestDrive 'protected'))
        $configFile = Join-Path $TestDrive 'scope-config.json'
        $cfg | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $configFile -Encoding UTF8
        Initialize-ConfigModule -ConfigPath $configFile
        $loaded = Get-UserConfig
        $loaded.taskCategories['System Caches'].enabled | Should -BeFalse
        (Get-UserConfig).taskCategories['System Caches'].enabled | Should -BeFalse
        (Get-UserConfig).exclusions.userCustomExclusions | Should -Contain $cfg.exclusions.userCustomExclusions[0]
    }
}

Describe 'Interactive menu report lifecycle' {
    It 'creates a separate text report for every selected menu action' {
        InModuleScope Bakunawa.UI -Parameters @{ FixtureRoot = $TestDrive } {
            param($FixtureRoot)
            $script:MenuChoices = [Collections.Generic.Queue[string]]::new()
            foreach ($choice in @('1','2','3','4','5','4','Q')) { $script:MenuChoices.Enqueue($choice) }
            $script:LogFilePath = $null
            Mock Get-ScanLogDirectory { Join-Path $FixtureRoot 'menu-logs' }
            Mock Show-Header {}
            Mock Set-UiContext {}
            Mock Read-Host {
                param($Prompt)
                if ($Prompt -eq 'Selection') { return $script:MenuChoices.Dequeue() }
                if ($Prompt -eq 'Review') { return 'Q' }
                return ''
            }
            Mock Invoke-CleanupRun {
                param($Mode)
                [pscustomobject]@{ Mode = $Mode; IsPreview = ($Mode -eq 'Preview'); DurationSec = 0;
                    PathsCleared = 0; BytesFreed = 0; Errors = @();
                    SkippedItems = @(); CategorySizes = @{}; ScanReport = $null }
            }
            Mock Find-OrphanFolders { @() }
            Mock Get-OrphanScanReport { @{ Findings = @(); Coverage = @(); Issues = @(); DurationSec = 0 } }
            Mock Show-HealthDetail { Write-ReviewLine 'Fixture health summary' }
            Show-Menu
            $logs = @(Get-ChildItem -LiteralPath (Join-Path $FixtureRoot 'menu-logs') -Filter *.txt)
            $logs.Count | Should -Be 5
            @($logs | Where-Object Name -Like '*-Scan-*').Count | Should -Be 2
            foreach ($log in $logs) { (Get-Content -LiteralPath $log.FullName -Raw) | Should -Match 'RUN FINISHED' }
        }
    }
}

Describe 'Automatic text reports and terminal layout' {
    BeforeEach {
        $logRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock -ModuleName Bakunawa.UI Get-ScanLogDirectory { $logRoot }
        Mock -ModuleName Bakunawa.UI Get-ConsoleWidth { 80 }
        & (Get-Module Bakunawa.UI) {
            $script:LogFilePath = $null
            $script:ScanLogPath = $null
        }
        Set-UiOptions -NoAnimations
    }

    It 'exports a readable automatic text log for <RunMode>' -TestCases @(
        @{ RunMode = 'Standard' }, @{ RunMode = 'Aggressive' },
        @{ RunMode = 'Scan' }, @{ RunMode = 'Health' }, @{ RunMode = 'Benchmark' }
    ) {
        param($RunMode)
        $value = Invoke-LoggedOperation -Mode $RunMode -Action {
            Write-ReviewLine 'Fixture report: 4096 bytes'
            [pscustomobject]@{ Count = 3 }
        }
        $value.Count | Should -Be 3
        $path = Get-ScanLogPath
        [IO.Path]::GetExtension($path) | Should -Be '.txt'
        $log = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $log | Should -Match ("BAKUNAWA / {0}" -f $RunMode.ToUpperInvariant())
        $log | Should -Match 'Fixture report: 4096 bytes'
        $log | Should -Match 'RUN FINISHED.*Finished; see summary'
        $log | Should -Not -Match '\x1B'
    }

    It 'keeps repeated runs separate and shares a log with nested scans' {
        Invoke-LoggedOperation -Mode Standard -Action {
            Invoke-LoggedOperation -Mode Scan -Action { Write-ReviewLine 'Nested discovery' }
        }
        $first = Get-ScanLogPath
        $original = Get-Content -LiteralPath $first -Raw
        Invoke-LoggedOperation -Mode Standard -Action { Write-ReviewLine 'Second run' }
        (Get-ScanLogPath) | Should -Not -Be $first
        @(Get-ChildItem -LiteralPath $logRoot -Filter *.txt).Count | Should -Be 2
        (Get-Content -LiteralPath $first -Raw) | Should -Be $original
        $original | Should -Match 'Nested discovery'
    }

    It 'preserves a partial report on failure and releases the file handle' {
        { Invoke-LoggedOperation -Mode Scan -Action {
            Write-ReviewLine 'Root started'
            throw 'Fixture scan failure'
        } } | Should -Throw '*Fixture scan failure*'
        $path = Get-ScanLogPath
        $log = Get-Content -LiteralPath $path -Raw
        $log | Should -Match 'Root started'
        $log | Should -Match 'RUN FINISHED.*Failed'
        $handle = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        $handle.Dispose()
        { Invoke-LoggedOperation -Mode Scan -Action { Write-ReviewLine 'Recovered' } } | Should -Not -Throw
    }

    It 'does not start work when the log directory cannot be created' {
        Set-Content -LiteralPath $logRoot -Value 'This is a file'
        Mock -ModuleName Bakunawa.UI Show-HealthDetail {}
        { Invoke-LoggedOperation -Mode Health -Action { Show-HealthDetail } } | Should -Throw
        Should -Invoke -ModuleName Bakunawa.UI Show-HealthDetail -Times 0 -Exactly
    }

    It 'reports an incomplete log instead of success after a write failure' {
        $output = Invoke-LoggedOperation -Mode Scan -Action {
            & (Get-Module Bakunawa.UI) { $script:ScanLogWriter.Dispose() }
            Write-ReviewLine 'Cannot persist this line'
        } 3>&1 6>&1 | Out-String
        $output | Should -Match 'Text log INCOMPLETE'
        $output | Should -Not -Match 'Text log saved:'
    }

    It 'appends to an explicit log while retaining the automatic text report' {
        $extra = Join-Path $TestDrive 'additional.log'
        Set-Content -LiteralPath $extra -Value 'Existing content'
        $null = Initialize-UiLogging -Path $extra
        Invoke-LoggedOperation -Mode Scan -Action { Write-Log 'Fixture scan event' 'SCAN' }
        $copy = Get-Content -LiteralPath $extra -Raw
        $copy | Should -Match 'Existing content'
        ([regex]::Matches($copy, 'Fixture scan event')).Count | Should -Be 1
        (Get-Content -LiteralPath (Get-ScanLogPath) -Raw) | Should -Match 'Fixture scan event'
    }

    It 'wraps full paths within a <Width> column terminal' -TestCases @(
        @{ Width = 24 }, @{ Width = 40 }, @{ Width = 80 }, @{ Width = 120 }
    ) {
        param($Width)
        Mock -ModuleName Bakunawa.UI Get-ConsoleWidth { $Width }
        $longPath = 'C:\' + ('LongDirectory\' * 12) + 'final-file.tmp'
        $lines = @(Write-ReviewLine $longPath 6>&1 | ForEach-Object { $_.ToString() })
        foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual $Width }
        (($lines | ForEach-Object { $_.Trim() }) -join '') | Should -Be $longPath
    }

    It 'wraps menu panels without losing text or adding emoji at <Width> columns' -TestCases @(
        @{ Width = 24 }, @{ Width = 40 }, @{ Width = 80 }, @{ Width = 120 }
    ) {
        param($Width)
        Mock -ModuleName Bakunawa.UI Get-ConsoleWidth { $Width }
        $text = '[4] Scan C:     caches, leftovers, review and restore'
        $lines = @(Write-Panel -Lines @($text) 6>&1 | ForEach-Object { $_.ToString() })
        foreach ($line in $lines) { $line.Length | Should -BeLessOrEqual $Width }
        $body = ($lines | Where-Object { $_ -match '\|' } | ForEach-Object { $_.Trim().Trim('|').Trim() }) -join ' '
        ($body -replace '\s+', ' ') | Should -Be ($text -replace '\s+', ' ')
        foreach ($kind in @('Ok','Warn','Err','Scan')) { [string](Get-ThemedGlyph $kind) | Should -Match '^[\x20-\x7e]+$' }
    }

    It 'retains every finding and issue in the log while showing a bounded summary first' {
        $findings = @(1..14 | ForEach-Object {
            [pscustomobject]@{ Path = "C:\fixture\candidate-$_.tmp"; Size = 4096; FileCount = 1;
                Category = 'Stale temporary file'; Reason = "Evidence $_"; SafeDelete = $false;
                DaysSinceModified = 90; Tier = 'Tier2'; ScanRoot = 'C:\fixture'; LatestWriteUtc = [datetime]'2026-01-01' }
        })
        $report = @{ Findings = $findings; DurationSec = 65; Exclusions = @('C:\fixture\keep');
            Coverage = @([pscustomobject]@{ Root = 'C:\fixture'; Files = 14; Directories = 1; Errors = 7; Skipped = 0; Status = 'Partial'; DurationSec = 65 });
            Issues = @(1..7 | ForEach-Object { [pscustomobject]@{ Kind = 'Error'; Path = "C:\fixture\locked-$_"; Reason = 'Access denied' } }) }
        $output = Invoke-LoggedOperation -Mode Scan -Action {
            Write-ScanReportLog -Report $report
            Show-OrphanScanResults -ScanResult $report
        } 6>&1 | Out-String
        $output.IndexOf('SCAN SUMMARY') | Should -BeLessThan $output.IndexOf('[1]')
        $output | Should -Match 'Finished with coverage gaps'
        $output | Should -Match 'Local disk C: only'
        $output | Should -Match 'DATA BY CATEGORY / largest first'
        $output | Should -Match 'Showing the largest 10 of 14'
        $output | Should -Match 'locked-7'
        $output | Should -Not -Match 'candidate-14.tmp'
        $log = Get-Content -LiteralPath (Get-ScanLogPath) -Raw
        foreach ($finding in $findings) { $log | Should -Match ([regex]::Escape($finding.Path)) }
        foreach ($issue in $report.Issues) { $log | Should -Match ([regex]::Escape($issue.Path)) }
        $log | Should -Match 'Evidence 14'
        $log | Should -Match 'CONFIGURED EXCLUSIONS'
    }

    It 'keeps preview estimates distinct from permanently deleted data' {
        Mock -ModuleName Bakunawa.UI Set-UiContext {}
        $result = [pscustomobject]@{ Mode = 'Preview'; IsPreview = $true; DurationSec = 2;
            PathsCleared = 1; BytesFreed = 4096; Errors = @();
            SkippedItems = @(); CategorySizes = @{ Cache = 4096 }; ScanReport = $null }
        $preview = Show-CleanupResult $result 6>&1 | Out-String
        $preview | Should -Match 'Estimated eligible data'
        $preview | Should -Match 'No files were deleted'
        $preview | Should -Not -Match 'Deleted data\s*:'
        $result.Mode = 'Standard'; $result.IsPreview = $false
        $cleanup = Show-CleanupResult $result 6>&1 | Out-String
        $cleanup | Should -Match 'Deleted data\s*: 4 KB'
        $cleanup | Should -Not -Match 'Quarantined data'
        $cleanup | Should -Match 'Deletion is permanent'
    }

    It 'displays a single scan issue without an empty hidden-issue count' {
        $report = @{ Findings = @(); Coverage = @(); DurationSec = 0;
            Issues = @([pscustomobject]@{ Kind = 'Skipped'; Path = 'C:\fixture\.git'; Reason = 'Protected metadata' }) }
        $output = Invoke-LoggedOperation -Mode Scan -Action {
            Write-ScanReportLog $report
            Show-OrphanScanResults $report
        } 6>&1 | Out-String
        $output | Should -Match 'Protected metadata'
        $output | Should -Not -Match 'Showing .* of 1 issues'
    }
}
