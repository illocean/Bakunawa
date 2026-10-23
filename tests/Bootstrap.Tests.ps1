#requires -Version 5.1
BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot/../").Path
    foreach ($module in @('Core','Config','Cleanup','UI','Bootstrap')) {
        Import-Module "$repo/src/Bakunawa.$module.psm1" -Force -Global -DisableNameChecking
    }
    function In-Cleanup([scriptblock]$Script) { & (Get-Module Bakunawa.Cleanup) $Script }
    function New-ProfileRoot([string]$Json, [string]$Name = 'test') {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'profiles') -Force
        [IO.File]::WriteAllText((Join-Path $root "profiles\$Name.json"), $Json, [Text.UTF8Encoding]::new($false))
        return $root
    }
}

Describe 'Mode resolution' {
    It 'rejects a mode it does not know' {
        $result = Resolve-BakunawaMode -Mode 'Nonsense'
        $result.Error | Should -Match 'Invalid mode'
        $result.Mode | Should -Be 'Nonsense'
    }
    It 'keeps the requested mode when no profile is named' {
        (Resolve-BakunawaMode -Mode 'Preview').Mode | Should -Be 'Preview'
    }
    It 'applies the profile mode when the caller named no mode' {
        $root = New-ProfileRoot '{"mode":"Aggressive"}'
        (Resolve-BakunawaMode -Mode 'Menu' -Profile 'test' -ProfileRoot $root).Mode | Should -Be 'Aggressive'
    }
    It 'lets an explicit mode win over the profile mode' {
        $root = New-ProfileRoot '{"mode":"Aggressive"}'
        (Resolve-BakunawaMode -Mode 'Preview' -Profile 'test' -ProfileRoot $root -ModeWasSpecified).Mode | Should -Be 'Preview'
    }
    It 'applies aggressive.enabled when the caller named no mode' {
        $root = New-ProfileRoot '{"aggressive":{"enabled":true}}'
        (Resolve-BakunawaMode -Mode 'Menu' -Profile 'test' -ProfileRoot $root).Mode | Should -Be 'Aggressive'
    }
    It 'keeps an explicit mode when the profile only enables aggressive' {
        $root = New-ProfileRoot '{"aggressive":{"enabled":true}}'
        (Resolve-BakunawaMode -Mode 'Preview' -Profile 'test' -ProfileRoot $root -ModeWasSpecified).Mode | Should -Be 'Preview'
    }
    It 'warns about an unusable profile mode and keeps the requested one' {
        $root = New-ProfileRoot '{"mode":"Nonsense"}'
        $result = Resolve-BakunawaMode -Mode 'Preview' -Profile 'test' -ProfileRoot $root
        $result.Warning | Should -Match 'invalid mode'
        $result.Mode | Should -Be 'Preview'
    }
    It 'fails when the profile file is missing' {
        $root = New-ProfileRoot '{}' -Name 'other'
        (Resolve-BakunawaMode -Mode 'Preview' -Profile 'test' -ProfileRoot $root).Error | Should -Match 'Profile file not found'
    }
    It 'fails when the profile is not valid JSON' {
        $root = New-ProfileRoot '{ not json'
        (Resolve-BakunawaMode -Mode 'Preview' -Profile 'test' -ProfileRoot $root).Error | Should -Match 'Failed to load profile'
    }
    It 'fails when aggressive.enabled is not a boolean' {
        $root = New-ProfileRoot '{"aggressive":{"enabled":"yes"}}'
        (Resolve-BakunawaMode -Mode 'Preview' -Profile 'test' -ProfileRoot $root).Error | Should -Match 'JSON boolean'
    }
}

Describe 'Session preparation' {
    BeforeEach {
        Mock Initialize-ConfigModule {} -ModuleName Bakunawa.Bootstrap
        Mock Get-UserConfig { @{ extraExcludePaths = @() } } -ModuleName Bakunawa.Bootstrap
        Mock Set-UiContext {} -ModuleName Bakunawa.Bootstrap
        Mock Set-UiOptions {} -ModuleName Bakunawa.Bootstrap
        Mock Set-CleanupSessionScope {} -ModuleName Bakunawa.Bootstrap
        Mock Initialize-CleanupState {} -ModuleName Bakunawa.Bootstrap
    }
    It 'stores the scope and leaves the cleanup state to the mode that needs it' {
        $null = Initialize-BakunawaSession -Mode 'Preview' -ScanRoot @('C:\fixture') -ExtraExcludePath @('C:\excluded')
        Should -Invoke Set-CleanupSessionScope -ModuleName Bakunawa.Bootstrap -Times 1 -Exactly
        Should -Invoke Initialize-CleanupState -ModuleName Bakunawa.Bootstrap -Times 0 -Exactly
    }
    It 'merges the config exclusions with the ones given on the command line' {
        Mock Get-UserConfig { @{ extraExcludePaths = @('C:\from-config') } } -ModuleName Bakunawa.Bootstrap
        $session = Initialize-BakunawaSession -Mode 'Preview' -ExtraExcludePath @('C:\from-cli')
        $session.Exclusions | Should -Be @('C:\from-config', 'C:\from-cli')
    }
    It 'fails with a readable message when the log path is unusable' {
        Mock Initialize-UiLogging { throw 'bad path' } -ModuleName Bakunawa.Bootstrap
        { Initialize-BakunawaSession -Mode 'Standard' -LogFile 'X:\nope\cleaner.log' } | Should -Throw '*Invalid log file path*'
    }
}

Describe 'Mode dispatch' {
    BeforeEach {
        Mock Invoke-CleanupRun { [pscustomobject]@{ Mode = 'Mocked' } } -ModuleName Bakunawa.Bootstrap
        Mock Show-RunSummary {} -ModuleName Bakunawa.Bootstrap
        Mock Show-Header {} -ModuleName Bakunawa.Bootstrap
        Mock Show-Menu {} -ModuleName Bakunawa.Bootstrap
        Mock Show-HealthDetail {} -ModuleName Bakunawa.Bootstrap
        Mock Initialize-CleanupState {} -ModuleName Bakunawa.Bootstrap
        Mock Find-OrphanFolders { @() } -ModuleName Bakunawa.Bootstrap
        Mock Get-OrphanScanReport { @{ Findings = @(); Issues = @(); Coverage = @(); IsComplete = $true; Status = 'Complete' } } -ModuleName Bakunawa.Bootstrap
        Mock Show-OrphanScanResults {} -ModuleName Bakunawa.Bootstrap
        Mock Invoke-LoggedOperation { param($Mode, $Action) & $Action } -ModuleName Bakunawa.Bootstrap
    }
    It 'lets the run build the cleanup state for the cleanup modes' {
        Invoke-BakunawaMode -Mode 'Preview'
        Should -Invoke Initialize-CleanupState -ModuleName Bakunawa.Bootstrap -Times 0 -Exactly
        Should -Invoke Invoke-CleanupRun -ModuleName Bakunawa.Bootstrap -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Preview' }
    }
    It 'builds the cleanup state itself for the scan mode' {
        Invoke-BakunawaMode -Mode 'Scan'
        Should -Invoke Initialize-CleanupState -ModuleName Bakunawa.Bootstrap -Times 1 -Exactly
    }
    It 'does not build the cleanup state for the menu' {
        Invoke-BakunawaMode -Mode 'Menu'
        Should -Invoke Initialize-CleanupState -ModuleName Bakunawa.Bootstrap -Times 0 -Exactly
        Should -Invoke Show-Menu -ModuleName Bakunawa.Bootstrap -Times 1 -Exactly
    }
    It 'runs every mode except the menu inside the logged operation' {
        Invoke-BakunawaMode -Mode 'Health'
        Should -Invoke Invoke-LoggedOperation -ModuleName Bakunawa.Bootstrap -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Health' }
    }
}

Describe 'Cleanup session scope' {
    BeforeEach {
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { @() }
    }
    It 'falls back to the stored scope when the state is built without arguments' {
        $cfg = Get-DefaultConfig
        $cfg.scanSettings.roots = @('C:\scope-root')
        In-Cleanup { Set-CleanupSessionScope -Config $cfg -ScanRoot @('C:\scope-root') -ExtraExcludePath @('C:\scope-exclude') -VerboseScan }
        In-Cleanup { Initialize-CleanupState }
        In-Cleanup { $script:ScanRoots } | Should -Be @('C:\scope-root')
        In-Cleanup { $script:ExtraExcludePaths } | Should -Be @('C:\scope-exclude')
        In-Cleanup { $script:VerboseScan } | Should -BeTrue
    }
    It 'lets explicit arguments win over the stored scope' {
        $cfg = Get-DefaultConfig
        $cfg.scanSettings.roots = @('C:\scope-root')
        In-Cleanup { Set-CleanupSessionScope -Config $cfg -ScanRoot @('C:\scope-root') -ExtraExcludePath @('C:\scope-exclude') }
        In-Cleanup { Initialize-CleanupState -Config $cfg -ScanRoot @('C:\explicit-root') -ExtraExcludePath @('C:\explicit-exclude') }
        In-Cleanup { $script:ScanRoots } | Should -Be @('C:\explicit-root')
        In-Cleanup { $script:ExtraExcludePaths } | Should -Be @('C:\explicit-exclude')
    }
}
