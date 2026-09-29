#requires -Version 5.1
BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot/..").Path
    foreach ($module in @('Core','Config','Cleanup','UI')) {
        Import-Module "$repo/src/Bakunawa.$module.psm1" -Force -DisableNameChecking
    }
    function New-FixtureFile([string]$Path, [int]$Bytes = 128) {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
        [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
    }
    function Set-FixtureAge([string]$Path, [int]$Days = 90) {
        @(Get-ChildItem -LiteralPath $Path -Recurse -Force) + @(Get-Item -LiteralPath $Path) | ForEach-Object { $_.LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-$Days) }
    }
    function Get-FixtureSnapshot([string]$Path) {
        @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName | ForEach-Object {
            '{0}|{1}|{2}|{3}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks, $(if (-not $_.PSIsContainer) { (Get-FileHash -LiteralPath $_.FullName).Hash })
        }) -join "`n"
    }
}

Describe 'Orphan evidence, protected paths and common cleanup planning' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path "$root/scan", "$root/shortcuts", "$root/owner"
        $cfg = Get-DefaultConfig
        $cfg.scanSettings.roots = @("$root/scan")
        $app = [pscustomobject]@{
            Name = 'Fixture'; Process = 'bakunawa-fixture'; Path = "$root/scan/leftover"; SourceFile = 'fixture.json'; Category = 'Orphan fixtures'
            OrphanRule = [pscustomobject]@{ id = 'fixture-owner-absent'; uninstallNames = @('Fixture*'); shortcutNames = @('Fixture*'); executables = @([pscustomobject]@{env = 'BAKUNAWA_FIXTURE'; path = 'owner/app.exe'}) }
        }
        Mock -ModuleName Bakunawa.Core Get-ProtectedKnownFolders { @("$root/redirected") }
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { @($app) }
        Mock -ModuleName Bakunawa.Cleanup Get-InstalledApplicationNames { @() }
        Mock -ModuleName Bakunawa.Cleanup Get-OrphanShortcutRoots { @("$root/shortcuts") }
        Mock -ModuleName Bakunawa.Cleanup Get-EnvPath { $root } -ParameterFilter { $Name -eq 'BAKUNAWA_FIXTURE' }
        Mock -ModuleName Bakunawa.Cleanup Test-AnyProcessRunning { $false }
        Mock -ModuleName Bakunawa.Cleanup Get-ScanExclusions { @(Get-CoreExcludedPaths) }
        Mock -ModuleName Bakunawa.Cleanup Get-CleanupTasks { @([pscustomobject]@{Name = 'Orphan Scan'; Parallel = $false}) }
        Mock -ModuleName Bakunawa.UI Get-ScanLogDirectory { "$root/logs" }
        Initialize-CleanupState -Config $cfg -ScanRoot "$root/scan" -ExtraExcludePath @() -Aggressive:$false -VerboseScan:$false
        & (Get-Module Bakunawa.Cleanup) { $script:IsPreview = $false; $script:Planning = $false; $script:Errors = @(); $script:CategorySizes = @{} }
    }

    It 'records the app-definition rule and requires all absence checks for an old tree' {
        New-FixtureFile "$root/scan/leftover/sub/data.bin" 4096
        Set-FixtureAge "$root/scan"
        Initialize-CleanupState -Config $cfg -ScanRoot "$root/scan"
        $finding = @(Find-OrphanFolders -Refresh)[0]
        $finding.SafeDelete | Should -BeTrue
        $finding.EvidenceRule | Should -Be 'fixture.json:fixture-owner-absent'
        $finding.EvidenceChecks.Count | Should -Be 3
        $finding.Size | Should -Be 4096
    }

    It 'never promotes name-only findings or a forged SafeDelete without a rule' {
        New-FixtureFile "$root/scan/cache/data.bin"
        Set-FixtureAge "$root/scan"
        $finding = @(Find-OrphanFolders -Refresh)[0]
        $finding.SafeDelete | Should -BeFalse
        $finding.SafeDelete = $true
        Clear-CachedOrphans | Should -Be 0
        Test-Path "$root/scan/cache/data.bin" | Should -BeTrue
    }

    It 'keeps a matching rule review-only when <Check> fails' -TestCases @(
        @{Check = 'registry'}, @{Check = 'registry denied'}, @{Check = 'executable'}, @{Check = 'shortcut'}, @{Check = 'process'}
    ) {
        param($Check)
        New-FixtureFile "$root/scan/leftover/data.bin"
        Set-FixtureAge "$root/scan"
        switch ($Check) {
            registry { Mock -ModuleName Bakunawa.Cleanup Get-InstalledApplicationNames { @('Fixture installed') } }
            'registry denied' { Mock -ModuleName Bakunawa.Cleanup Get-InstalledApplicationNames { throw 'Access denied to uninstall registry' } }
            executable { New-FixtureFile "$root/owner/app.exe" }
            shortcut { New-FixtureFile "$root/shortcuts/Fixture.lnk" }
            process { Mock -ModuleName Bakunawa.Cleanup Test-AnyProcessRunning { $true } }
        }
        # Initialize with no running app, then simulate changes during the evidence check.
        $finding = @(Find-OrphanFolders -Refresh | Where-Object EvidenceRule)[0]
        $finding.SafeDelete | Should -BeFalse
        Clear-CachedOrphans | Should -Be 0
        Test-Path "$root/scan/leftover/data.bin" | Should -BeTrue
    }

    It 'uses the newest nested LastWriteTime and ignores old parent timestamps' {
        New-FixtureFile "$root/scan/leftover/sub/data.bin"
        Set-FixtureAge "$root/scan"
        (Get-Item "$root/scan/leftover/sub/data.bin").LastWriteTimeUtc = [datetime]::UtcNow
        $finding = @(Find-OrphanFolders -Refresh | Where-Object EvidenceRule)[0]
        $finding.SafeDelete | Should -BeFalse
        $finding.DaysSinceModified | Should -Be 0
    }

    It 'protects conventional personal folders and an arbitrarily redirected known folder' {
        Mock -ModuleName Bakunawa.Core Get-EnvPath { "$root/profile" } -ParameterFilter { $Name -eq 'USERPROFILE' }
        foreach ($name in @('Desktop','Documents','Downloads','Pictures','Videos','Music')) { New-FixtureFile "$root/profile/$name/cache/data.bin" }
        New-FixtureFile "$root/redirected/cache/data.bin"
        Set-FixtureAge $root
        Initialize-CleanupState -Config $cfg -ScanRoot $root
        @(Find-OrphanFolders -Refresh | Where-Object { $_.Path -like "$root/profile/*" -or $_.Path -like "$root/redirected*" }).Count | Should -Be 0
        foreach ($name in @('Desktop','Documents','Downloads','Pictures','Videos','Music')) {
            Measure-AndClear "$root/profile/$name/cache" | Should -BeFalse
            Test-Path "$root/profile/$name/cache/data.bin" | Should -BeTrue
        }
        Measure-AndClear "$root/redirected/cache" | Should -BeFalse
        { InModuleScope Bakunawa.Cleanup { Remove-ItemSafely -Path "$root/redirected" -Reason Test } } | Should -Throw '*Protected*'
    }

    It 'rechecks known-folder protection immediately before deletion' {
        New-FixtureFile "$root/scan/leftover/data.bin"
        Set-FixtureAge "$root/scan"
        $null = Find-OrphanFolders -Refresh
        Mock -ModuleName Bakunawa.Core Get-ProtectedKnownFolders { @("$root/scan/leftover") }
        Clear-CachedOrphans | Should -Be 0
        # Measure-AndClear is the public route into Remove-ItemSafely; it returns $false and
        # records the skip when the target is protected, so nothing is deleted.
        Measure-AndClear -Path "$root/scan/leftover" -Category Test | Should -BeFalse
        Test-Path "$root/scan/leftover/data.bin" | Should -BeTrue
    }

    It 'does not traverse a junction into a protected fixture and labels the scan incomplete' {
        New-FixtureFile "$root/redirected/private.bin"
        $null = New-Item -ItemType Junction -Path "$root/scan/cache" -Target "$root/redirected"
        try {
            $null = Find-OrphanFolders -Refresh
            $report = Get-OrphanScanReport
            $report.IsComplete | Should -BeFalse
            $report.Issues.Path | Should -Contain ([IO.Path]::GetFullPath("$root/scan/cache"))
            Measure-AndClear "$root/scan/cache" | Should -BeFalse
            Test-Path "$root/redirected/private.bin" | Should -BeTrue
        } finally { [IO.Directory]::Delete("$root/scan/cache") }
    }

    It 'reports a denied fixture path and exports incomplete coverage' {
        New-FixtureFile "$root/scan/denied/data.bin"
        $path = "$root/scan/denied"
        $acl = Get-Acl -LiteralPath $path
        $denied = Get-Acl -LiteralPath $path
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'ListDirectory', 'Deny')
        $denied.AddAccessRule($rule)
        try {
            Set-Acl -LiteralPath $path -AclObject $denied
            $null = Find-OrphanFolders -Refresh
            $report = Get-OrphanScanReport
            $report.Status | Should -Be 'Incomplete'
            $report.Issues.Path | Should -Contain ([IO.Path]::GetFullPath($path))
            ($report.Issues.Reason -join ' ') | Should -Match 'denied'
            $text = Show-OrphanScanResults $report 6>&1 | Out-String
            $text | Should -Match 'Incomplete'
            $text | Should -Match 'denied'
            Export-ScanReport $report "$root/report.json"
            (Get-Content "$root/report.json" -Raw | ConvertFrom-Json).IsComplete | Should -BeFalse
        } finally { Set-Acl -LiteralPath $path -AclObject $acl }
    }

    It 'Preview makes no filesystem changes and plans the same orphan candidates as Standard' {
        New-FixtureFile "$root/scan/leftover/data.bin" 4096
        New-FixtureFile "$root/scan/cache/data.bin" 1024
        Set-FixtureAge "$root/scan"
        $before = Get-FixtureSnapshot $root
        $preview = Invoke-LoggedOperation -Mode Preview -Action { Invoke-CleanupRun -Mode Preview -Config $cfg }
        Get-FixtureSnapshot $root | Should -Be $before
        $standard = Invoke-CleanupRun -Mode Standard -Config $cfg
        ($preview.Candidates.Path -join '|') | Should -Be ($standard.Candidates.Path -join '|')
        $standard.BytesFreed | Should -Be 4096
        $summary = $standard.CategoryReport | Where-Object Category -eq 'Orphan Scan'
        $summary.IdentifiedBytes | Should -Be 5120
        $summary.ActedBytes | Should -Be 4096
        $summary.NotActedBytes | Should -Be 1024
        $summary.Reasons.Reason | Should -Contain 'no evidence'
        Test-Path "$root/scan/cache/data.bin" | Should -BeTrue
        Test-Path "$root/scan/leftover" | Should -BeFalse
    }

    It 'captures ordinary cache candidates before mutations and reports denied expansion' {
        New-FixtureFile "$root/scan/cache/data.bin" 2048
        Set-FixtureAge $root
        Mock -ModuleName Bakunawa.Cleanup Get-CleanupTasks { @([pscustomobject]@{Name = 'Game Caches'; Parallel = $false}) }
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { @([pscustomobject]@{ Name = 'Fixture cache'; Path = "$root/scan/cache"; Process = 'fixture'; Category = 'Game Caches' }) }
        $before = Get-FixtureSnapshot $root
        $preview = Invoke-CleanupRun -Mode Preview -Config $cfg
        Get-FixtureSnapshot $root | Should -Be $before
        $standard = Invoke-CleanupRun -Mode Standard -Config $cfg
        $standard.BytesFreed | Should -Be 2048
        ($preview.Candidates.Path -join '|') | Should -Be ($standard.Candidates.Path -join '|')
    }

    It 'uses actual Roblox and Playwright definitions against fixtures and preserves executables' {
        $definitions = @(Bakunawa.Core\Get-AllAppDefinitions | Where-Object { $_.Name -in @('Roblox','Playwright') -and $_.Category -in @('Game Caches','Browser Automation Caches') })
        foreach ($definition in $definitions) {
            $base = [Environment]::GetEnvironmentVariable($definition.Env)
            $definition.Path = $definition.Path.Replace($base, $root)
        }
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { param($Category) @($definitions | Where-Object { -not $Category -or $_.Category -eq $Category }) }
        Mock -ModuleName Bakunawa.Cleanup Get-CleanupTasks { @('Game Caches','Browser Automation Caches' | ForEach-Object { [pscustomobject]@{Name = $_; Parallel = $false} }) }
        New-FixtureFile "$root/Roblox/Versions/v1/ClientCache/data.bin" 1024
        New-FixtureFile "$root/Roblox/Versions/v1/RobloxPlayerBeta.exe" 2048
        New-FixtureFile "$root/ms-playwright/chromium/browser.bin" 4096
        $preview = Invoke-CleanupRun -Mode Preview -Config $cfg
        $preview.BytesFreed | Should -Be 5120
        $preview.Candidates.Count | Should -Be 2
        $run = Invoke-CleanupRun -Mode Standard -Config $cfg
        $run.BytesFreed | Should -Be 5120
        Test-Path "$root/Roblox/Versions/v1/RobloxPlayerBeta.exe" | Should -BeTrue
    }

    It 'preserves existing report bytes and names the path in its error' {
        $path = "$root/report.json"
        Export-ScanReport @{ Findings = @('first') } $path
        $hash = (Get-FileHash $path).Hash
        { Export-ScanReport @{ Findings = @('second') } $path } | Should -Throw '*report.json*Existing reports are preserved*'
        (Get-FileHash $path).Hash | Should -Be $hash
    }

    It 'counts a permanent delete as freed space and leaves no recovery copy' {
        New-FixtureFile "$root/scan/leftover/data.bin" 4096
        Set-FixtureAge "$root/scan"
        $run = Invoke-CleanupRun -Mode Standard -Config $cfg
        $run.BytesFreed | Should -Be 4096
        $run.CategoryReport[0].ActedBytes | Should -Be 4096
        Test-Path "$root/scan/leftover" | Should -BeFalse
        Test-Path "$root/quarantine" | Should -BeFalse
    }

    It 'reports a locked file without counting it as acted on' {
        New-FixtureFile "$root/scan/cache/locked.bin" 2048
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { @([pscustomobject]@{ Name = 'Fixture'; Path = "$root/scan/cache"; Category = 'Game Caches' }) }
        Mock -ModuleName Bakunawa.Cleanup Get-CleanupTasks { @([pscustomobject]@{ Name = 'Game Caches'; Parallel = $false }) }
        $handle = [IO.File]::Open("$root/scan/cache/locked.bin", 'Open', 'ReadWrite', 'None')
        try {
            $run = Invoke-CleanupRun -Mode Standard -Config $cfg
            $run.BytesFreed | Should -Be 0
            $run.CategoryReport[0].ActedBytes | Should -Be 0
            $run.Outcomes[0].Reason | Should -Be 'in use'
            Test-Path "$root/scan/cache/locked.bin" | Should -BeTrue
        } finally { $handle.Dispose() }
    }

    It 'marks Preview incomplete and reports the exact wildcard enumeration denial' {
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { @([pscustomobject]@{ Name = 'Fixture'; Path = "$root/scan/*/cache"; Category = 'Game Caches' }) }
        Mock -ModuleName Bakunawa.Cleanup Get-CleanupTasks { @([pscustomobject]@{ Name = 'Game Caches'; Parallel = $false }) }
        Mock -ModuleName Bakunawa.Cleanup Get-ChildItem { throw [UnauthorizedAccessException]::new('Fixture access denied') } -ParameterFilter { $LiteralPath -eq ([IO.Path]::GetFullPath("$root/scan")) }
        $run = Invoke-CleanupRun -Mode Preview -Config $cfg
        $run.IsComplete | Should -BeFalse
        $run.Outcomes[0].Path | Should -Be ([IO.Path]::GetFullPath("$root/scan"))
        $run.Outcomes[0].Detail | Should -Match 'access denied'
        $run.CategoryReport[0].UnknownSizePaths | Should -Be 1
    }

    It 'reports measured partial deletions without counting the remaining bytes as acted on' {
        New-FixtureFile "$root/scan/cache/sub/a.bin" 1024
        New-FixtureFile "$root/scan/cache/sub/b.bin" 2048
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { @([pscustomobject]@{ Name = 'Fixture'; Path = "$root/scan/cache"; Category = 'Game Caches' }) }
        Mock -ModuleName Bakunawa.Cleanup Get-CleanupTasks { @([pscustomobject]@{ Name = 'Game Caches'; Parallel = $false }) }
        Mock -ModuleName Bakunawa.Cleanup Remove-Item {
            [IO.File]::Delete([IO.Path]::GetFullPath("$root/scan/cache/sub/a.bin"))
            throw [IO.IOException]::new('File in use')
        } -ParameterFilter { $LiteralPath -eq ([IO.Path]::GetFullPath("$root/scan/cache/sub")) }
        $run = Invoke-CleanupRun -Mode Standard -Config $cfg
        $run.CategoryReport[0].IdentifiedBytes | Should -Be 3072
        $run.CategoryReport[0].ActedBytes | Should -Be 1024
        $run.CategoryReport[0].NotActedBytes | Should -Be 2048
        $run.BytesFreed | Should -Be 1024
        Test-Path "$root/scan/cache/sub/b.bin" | Should -BeTrue
    }

    It 'rechecks evidence before a planned orphan is removed' {
        New-FixtureFile "$root/scan/leftover/data.bin" 4096
        Set-FixtureAge "$root/scan"
        Mock -ModuleName Bakunawa.Cleanup Finish-Step { New-FixtureFile "$root/owner/app.exe" }
        $run = Invoke-CleanupRun -Mode Standard -Config $cfg
        $run.Candidates.Count | Should -Be 1
        $run.BytesFreed | Should -Be 0
        $run.Outcomes[0].Reason | Should -Be 'no evidence'
        Test-Path "$root/scan/leftover/data.bin" | Should -BeTrue
    }

    It 'marks an unmeasurable failure unknown instead of inventing acted-on bytes' {
        New-FixtureFile "$root/scan/cache/sub/a.bin" 1024
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { @([pscustomobject]@{ Name = 'Fixture'; Path = "$root/scan/cache"; Category = 'Game Caches' }) }
        Mock -ModuleName Bakunawa.Cleanup Get-CleanupTasks { @([pscustomobject]@{ Name = 'Game Caches'; Parallel = $false }) }
        Mock -ModuleName Bakunawa.Cleanup Remove-Item {
            # Both exact targets are inside this test's newly created fixture.
            [IO.File]::Delete([IO.Path]::GetFullPath("$root/scan/cache/sub/a.bin"))
            [IO.Directory]::Delete([IO.Path]::GetFullPath("$root/scan/cache/sub"))
            throw [IO.IOException]::new('Fixture operation failed after modifying its target')
        } -ParameterFilter { $LiteralPath -eq ([IO.Path]::GetFullPath("$root/scan/cache/sub")) }
        $run = Invoke-CleanupRun -Mode Standard -Config $cfg
        $run.IsComplete | Should -BeFalse
        $run.UnknownOutcomePaths | Should -Be 1
        $run.CategoryReport[0].IdentifiedBytes | Should -Be 1024
        $run.CategoryReport[0].ActedBytes | Should -BeNullOrEmpty
        $run.CategoryReport[0].NotActedBytes | Should -BeNullOrEmpty
        $text = Show-CleanupResult $run 6>&1 | Out-String
        $text | Should -Match 'acted on unknown'
        $text | Should -Match 'lower bounds'
    }

    It 'passes verbose and aggressive settings explicitly into discovery' {
        New-FixtureFile "$root/scan/leftover/data.bin"
        Set-FixtureAge "$root/scan" 20
        Initialize-CleanupState -Config $cfg -ScanRoot "$root/scan" -VerboseScan -Aggressive
        $text = Find-OrphanFolders -Refresh 6>&1 | Out-String
        $text | Should -Match 'Visited:'
        @(Get-OrphanScanReport).Findings[0].SafeDelete | Should -BeTrue
        Initialize-CleanupState -Config $cfg -ScanRoot "$root/scan" -VerboseScan:$false -Aggressive:$false
        $null = Find-OrphanFolders -Refresh
        (Get-OrphanScanReport).Findings[0].SafeDelete | Should -BeFalse
    }
}

Describe 'Entry precedence and source encoding' {
    BeforeEach {
        Mock Import-Module {}
        Mock Get-UserConfig { Get-DefaultConfig }
        Mock Initialize-ConfigModule {}
        Mock Initialize-CleanupState {}
        Mock Set-UiContext {}
        Mock Show-CleanupResult {}
        Mock Invoke-LoggedOperation { param($Mode, $Action) & $Action }
        Mock Invoke-CleanupRun { param($Mode) [pscustomobject]@{Mode = $Mode} }
    }
    It 'explicit Preview wins over an aggressive profile and stays Standard-equivalent' {
        & "$repo/Bakunawa.ps1" -Mode Preview -Profile aggressive -VerboseScan -NoPause -ForceAdmin
        Should -Invoke Invoke-CleanupRun -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Preview' }
        Should -Invoke Initialize-CleanupState -Times 1 -Exactly -ParameterFilter { $VerboseScan -and -not $Aggressive }
    }
    It 'profile aggressive.enabled selects aggressive behavior when Mode is omitted' {
        Mock Get-Content { '{"mode":"Standard","aggressive":{"enabled":true}}' } -ParameterFilter { $LiteralPath -like '*profiles*aggressive.json' }
        & "$repo/Bakunawa.ps1" -Profile aggressive -NoPause -ForceAdmin
        Should -Invoke Invoke-CleanupRun -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Aggressive' }
        Should -Invoke Initialize-CleanupState -Times 1 -Exactly -ParameterFilter { $Aggressive }
    }
    It 'uses the same task categories for Standard and Aggressive' {
        (@(Get-CleanupTasks Standard).Name -join '|') | Should -Be (@(Get-CleanupTasks Aggressive).Name -join '|')
    }
    It 'runs ReportPath twice through the entry point and preserves the first report' {
        Mock Find-OrphanFolders { @() }
        Mock Get-OrphanScanReport { @{Findings = @(); Issues = @(); Coverage = @(); IsComplete = $true; Status = 'Complete'} }
        Mock Show-Header {}
        $path = Join-Path $TestDrive 'entry-report.json'
        & "$repo/Bakunawa.ps1" -Mode Scan -ReportPath $path -NoPause -ForceAdmin
        $first = (Get-FileHash $path).Hash
        { & "$repo/Bakunawa.ps1" -Mode Scan -ReportPath $path -NoPause -ForceAdmin } | Should -Throw '*entry-report.json*Existing reports are preserved*'
        (Get-FileHash $path).Hash | Should -Be $first
    }
    It 'keeps every PowerShell source and test UTF-8 with BOM' {
        foreach ($file in @(Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object Extension -in @('.ps1','.psm1'))) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            [BitConverter]::ToString($bytes[0..2]) | Should -Be 'EF-BB-BF' -Because $file.FullName
        }
    }
}
