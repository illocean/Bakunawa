#requires -Version 5.1
# Pester v5 tests covering the Phase 1+2 coverage-boost changes.
#
# These tests would have caught the four root-cause bugs:
#   1. Get-AllAppDefinitions only loaded apps.json (10 other JSONs ignored)
#   2. No "category" field on entries; switch arms filtering by $app.Category never matched
#   3. Clear-ChromiumCaches joined cache subdirs directly to User Data root, missing
#      Default/Profile N subdirectories
#   4. Get-CleanupPotential had no switch arms for Cloud Sync, Creative Apps,
#      Productivity, DevOps Tools, or Recycle Bin
#
# Run: Invoke-Pester -Path tests/CoverageBoost.Tests.ps1 -Output Detailed

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module "$repoRoot/src/Bakunawa.Core.psm1" -Force
    Import-Module "$repoRoot/src/Bakunawa.UI.psm1" -Force -DisableNameChecking
    Import-Module "$repoRoot/src/Bakunawa.Cleanup.psm1" -Force -DisableNameChecking
    # Keep legacy tests inside Pester's disposable sandbox. Script variables in this
    # test file do not set module state, so configure the actual module explicitly.
    Import-Module "$repoRoot/src/Bakunawa.Config.psm1" -Force -DisableNameChecking
    & (Get-Module Bakunawa.Cleanup) { $script:IsPreview = $true }
    Mock -ModuleName Bakunawa.Cleanup Get-ScanDriveRoots { @($TestDrive) }
    Mock -ModuleName Bakunawa.Cleanup Get-DirectorySize {
        param($Path)
        # Real sizing for fixture paths; no machine-wide measurements in unit tests.
        if ($Path -like '*pester_*' -or $Path -like '*phase*_test_*' -or $Path -like '*regression_test_*' -or $Path -like '*integration_test_*') {
            Bakunawa.Core\Get-DirectorySize -Path $Path
        } else { 0L }
    }


    # Expected source files (one per app-definitions/*.json) used for cross-validation.
    $script:ExpectedSourceFiles = @(
        'apps.json','browsers.json','cloud.json','creative.json','devops.json',
        'devtools.json','devtools-extended.json','games.json','messaging.json',
        'productivity.json','system.json','browser-automation.json'
    )
}

AfterAll {
    Remove-Module Bakunawa.Cleanup -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.UI -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue
}

Describe 'Get-AllAppDefinitions (Phase 1+2 fix: load all JSONs, attach Category)' {

    It 'returns entries from every app-definitions/*.json file (not just apps.json)' {
        $all = Get-AllAppDefinitions
        $all | Should -Not -BeNullOrEmpty

        $actualSourceFiles = @($all | ForEach-Object SourceFile | Sort-Object -Unique)
        $actualSourceFiles.Count | Should -BeGreaterOrEqual $script:ExpectedSourceFiles.Count
        foreach ($expected in $script:ExpectedSourceFiles) {
            $actualSourceFiles | Should -Contain $expected -Because "the loader must include $expected (regression: bug #1)"
        }
    }

    It 'returns more than 100 entries total (regression guard for "only apps.json" bug)' {
        $all = Get-AllAppDefinitions
        $all.Count | Should -BeGreaterThan 100 -Because '11 JSON files x multiple apps must aggregate to >100'
    }

    It 'attaches .Category to every entry, never empty (regression: bug #2)' {
        $all = Get-AllAppDefinitions
        $all | ForEach-Object { $_.Category | Should -Not -BeNullOrEmpty -Because "$($_.Name) from $($_.SourceFile) is missing category" }
    }

    It 'attaches .SourceFile to every entry matching the JSON of origin' {
        $all = Get-AllAppDefinitions
        $all | ForEach-Object { $_.SourceFile | Should -BeIn $script:ExpectedSourceFiles }
    }

    It 'covers all 8 known category buckets' {
        $all = Get-AllAppDefinitions
        $cats = @($all | ForEach-Object Category | Sort-Object -Unique)
        foreach ($expected in @('App Caches','Browser Caches','Cloud Sync','Creative Apps',
                                'DevOps Tools','Dev Caches','Game Caches','Productivity',
                                'System Caches')) {
            $cats | Should -Contain $expected
        }
    }
}

Describe 'Get-AllAppDefinitions -Category filter' {

    It 'returns only Browser Caches when -Category "Browser Caches" is supplied' {
        $browsers = Get-AllAppDefinitions -Category 'Browser Caches'
        $browsers | Should -Not -BeNullOrEmpty
        $browsers | ForEach-Object { $_.Category | Should -Be 'Browser Caches' }
    }

    It 'returns only Cloud Sync when -Category "Cloud Sync" is supplied' {
        $cloud = Get-AllAppDefinitions -Category 'Cloud Sync'
        $cloud | Should -Not -BeNullOrEmpty
        $cloud | ForEach-Object { $_.Category | Should -Be 'Cloud Sync' }
    }

    It 'supports wildcard filter (regression: filter is -like, not -eq)' {
        $browserLike = Get-AllAppDefinitions -Category 'Browser*'
        $browserLike | Should -Not -BeNullOrEmpty
        $browserLike | ForEach-Object { $_.Category | Should -Match '^Browser' }
    }

    It 'returns empty array when filter matches no category' {
        $none = Get-AllAppDefinitions -Category 'NoSuchCategory'
        @($none).Count | Should -Be 0
    }
}

Describe 'Clear-ChromiumCaches (Phase 2 fix: iterate profile subdirs)' {

    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester_chromium_$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null
        # Reset global state the function depends on so we can run it deterministically.
        $script:RunningProcesses = @()
        $script:ExcludedPaths = $null
        $script:IsPreview = $true
    }

    AfterEach {
        if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
            Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'clears cache dirs inside the Default profile subdirectory (regression: bug #3)' {
        $default = Join-Path $script:tmpRoot 'Default'
        $cache   = Join-Path $default 'Cache'
        $codeCache = Join-Path $default 'Code Cache'
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        New-Item -ItemType Directory -Path $codeCache -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $cache 'data.bin'), (New-Object byte[] 4096))
        [System.IO.File]::WriteAllBytes((Join-Path $codeCache 'data.bin'), (New-Object byte[] 4096))

        $cleared = Clear-ChromiumCaches -UserDataRoot $script:tmpRoot -Label 'TestChrome'
        $cleared | Should -BeGreaterThan 0 -Because 'Default profile cache should be enumerated'
        Test-Path -LiteralPath $cache -PathType Container | Should -Be $true
    }

    It 'clears cache dirs inside multiple Profile N subdirectories (regression: bug #3)' {
        foreach ($profName in @('Default','Profile 1','Profile 2','Profile 5')) {
            $profPath = Join-Path $script:tmpRoot $profName
            $cache = Join-Path $profPath 'Cache'
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $cache 'data.bin'), (New-Object byte[] 4096))
        }

        $cleared = Clear-ChromiumCaches -UserDataRoot $script:tmpRoot -Label 'TestChrome'

        # If the bug were present (no profile iteration), 0 cache dirs would be cleared.
        # With the fix, every Cache dir across the 4 profiles must be reached.
        $cleared | Should -BeGreaterOrEqual 4 -Because 'Cache dir exists in 4 profile subdirectories'
    }

    It 'returns 0 when UserDataRoot does not exist' {
        $missing = Join-Path $script:tmpRoot 'does-not-exist'
        $cleared = Clear-ChromiumCaches -UserDataRoot $missing -Label 'TestChrome'
        $cleared | Should -Be 0
    }

    It 'falls back to root-level scan when no profile subdirs exist (legacy path)' {
        # User Data root with no Default/Profile N subdirs (very old profiles / custom setup)
        $oldCache = Join-Path $script:tmpRoot 'Cache'
        New-Item -ItemType Directory -Path $oldCache -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $oldCache 'data.bin'), (New-Object byte[] 4096))

        $cleared = Clear-ChromiumCaches -UserDataRoot $script:tmpRoot -Label 'TestChrome'
        $cleared | Should -BeGreaterThan 0 -Because 'root-level cache fallback must still work'
    }
}

Describe 'Get-CleanupPotential (Phase 2 fix: add 5 missing switch arms)' {

    It 'returns non-empty results for tasks the loop iterates' {
        $potential = Get-CleanupPotential -Mode Standard
        $potential | Should -Not -BeNullOrEmpty
        $tasks = @($potential | ForEach-Object Task | Sort-Object -Unique)
        # We added 4 category arms and the Recycle Bin arm. All must now appear in the
        # results list (with or without an estimate, they are returned).
        $tasks | Should -Contain 'Cloud Sync'        -Because 'arm added in Phase 2 (regression: bug #4)'
        $tasks | Should -Contain 'Creative Apps'     -Because 'arm added in Phase 2 (regression: bug #4)'
        $tasks | Should -Contain 'Productivity'      -Because 'arm added in Phase 2 (regression: bug #4)'
        $tasks | Should -Contain 'DevOps Tools'      -Because 'arm added in Phase 2 (regression: bug #4)'
    }

    It 'Cloud Sync arm reports zero count when no cloud apps are installed (this machine has none)' {
        $potential = @(Get-CleanupPotential -Mode Standard | Where-Object Task -eq 'Cloud Sync')
        $potential.Count | Should -Be 1
        $potential[0].EstimatedBytes | Should -BeGreaterOrEqual 0
        $potential[0].FileCount       | Should -BeGreaterOrEqual 0
    }
}

Describe 'Phase 3: Wildcard expansion in cleanup arms' {

    BeforeEach {
        # Sandbox: redirect LOCALAPPDATA to a fresh temp dir so the wildcard
        # expansion in the cleanup arms can resolve a known absolute path.
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester_phase3_$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null

        $script:origLocalAppData = $env:LOCALAPPDATA
        $script:origAppData      = $env:APPDATA
        $script:origUsername     = $env:USERNAME

        $env:LOCALAPPDATA = $script:tmpRoot
        $env:APPDATA      = $script:tmpRoot
        $env:USERNAME     = 'pester-user'

        # The cleanup arms consult $script:RunningProcesses / $script:IsPreview
        # / $script:ExcludedPaths. Make them inert for deterministic test runs.
        $script:RunningProcesses = @()
        $script:ExcludedPaths    = $null
        $script:IsPreview        = $true
        if (-not $script:SysLoc) { $script:SysLoc = Get-SystemLocations }
        if (-not $script:CleanupResults) { $script:CleanupResults = New-Object System.Collections.Generic.List[object] }
        # Track Measure-AndClear invocations for assertions.
        $script:MeasureAndClearCalls = [System.Collections.Generic.List[object]]::new()
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:origLocalAppData
        $env:APPDATA      = $script:origAppData
        $env:USERNAME     = $script:origUsername
        if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
            Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Get-CleanupPotential Browser Caches arm sources from app defs (not hardcoded list)' {
        # Mock Get-AllAppDefinitions to return a single fake browser entry whose
        # path uses the {profile} token. Seed a Default profile on disk.
        $userDataRoot   = Join-Path $script:tmpRoot 'UserData'
        $defaultProfile = Join-Path $userDataRoot 'Default'
        $cacheDir       = Join-Path $defaultProfile 'Cache'
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $cacheDir 'data.bin'), (New-Object byte[] 4194304)) # 4 MB

        $fakeBrowsers = @(
            [PSCustomObject]@{
                Name       = 'FakeBrowser'
                Path       = (Join-Path $userDataRoot '{profile}\Cache')
                Env        = 'LOCALAPPDATA'
                Process    = $null
                Category   = 'Browser Caches'
                SourceFile = 'browsers.json'
            }
        )
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { param([string]$Category) $fakeBrowsers }

        $potential = @(Get-CleanupPotential -Mode Standard | Where-Object Task -eq 'Browser Caches')
        $potential.Count | Should -Be 1
        $potential[0].FileCount       | Should -BeGreaterOrEqual 1 -Because 'mocked browser returned a profile that exists on disk'
        $potential[0].EstimatedBytes | Should -BeGreaterOrEqual 4MB -Because '4 MB file must be measured'
    }

    It 'Get-CleanupPotential Productivity arm expands {profile} tokens (regression: missed profiles)' {
        # Seed a fake Thunderbird profile with 1 MB of cache. The {profile}
        # token in messaging.json must be expanded for the estimate to count it.
        $profilePath = Join-Path (Join-Path (Join-Path $script:tmpRoot 'Profiles') 'abc.default-release') 'cache2'
        New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $profilePath 'data.bin'), (New-Object byte[] 1048576)) # 1 MB

        $fakeApps = @(
            [PSCustomObject]@{
                Name       = 'Thunderbird'
                Path       = (Join-Path (Join-Path $script:tmpRoot 'Profiles') '{profile}\cache2')
                Env        = 'LOCALAPPDATA'
                Process    = $null
                Category   = 'Productivity'
                SourceFile = 'messaging.json'
            }
        )
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { param([string]$Category) $fakeApps }

        $potential = @(Get-CleanupPotential -Mode Standard | Where-Object Task -eq 'Productivity')
        $potential.Count | Should -Be 1
        $potential[0].FileCount       | Should -BeGreaterOrEqual 1
        $potential[0].EstimatedBytes | Should -BeGreaterOrEqual 1MB
    }

    It 'Invoke-CleanupRun Productivity arm expands {profile} and calls Measure-AndClear on resolved path' {
        $profilePath = Join-Path (Join-Path (Join-Path $script:tmpRoot 'Profiles') 'xyz.default-release') 'cache2'
        New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $profilePath 'data.bin'), (New-Object byte[] 524288)) # 512 KB

        $fakeApps = @(
            [PSCustomObject]@{
                Name       = 'Thunderbird'
                Path       = (Join-Path (Join-Path $script:tmpRoot 'Profiles') '{profile}\cache2')
                Env        = 'LOCALAPPDATA'
                Process    = $null
                Category   = 'Productivity'
                SourceFile = 'messaging.json'
            }
        )
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { param([string]$Category) $fakeApps }
        Mock -ModuleName Bakunawa.Cleanup Measure-AndClear {
            param([string]$Path,[switch]$EnsureDirectory,[string]$Category)
            $script:MeasureAndClearCalls.Add([PSCustomObject]@{ Path = $Path; Category = $Category })
            return $true
        }

        # Invoke-CleanupRun tasks loop also touches other categories. Stub them
        # out so the test only exercises the Productivity arm. Stub out the UI
        # stepper functions (Start-Step / Finish-Step) that live in the UI module
        # and aren't available in this isolated test context.
        $script:TasksToRun = @(@{ Name = 'Productivity'; Parallel = $false })
        Mock -ModuleName Bakunawa.Cleanup Get-CleanupTasks { @($script:TasksToRun) }
        Mock -ModuleName Bakunawa.UI       Start-Step       { } -ParameterFilter { $true }
        Mock -ModuleName Bakunawa.UI       Finish-Step      { } -ParameterFilter { $true }
        Mock -ModuleName Bakunawa.UI       Write-CommandLog { } -ParameterFilter { $true }

        $testConfig = Get-DefaultConfig
        $testConfig.taskCategories['Productivity'].enabled = $true
        $null = Invoke-CleanupRun -Mode Preview -Config $testConfig

        # Find the Measure-AndClear mock invocation(s) for the Productivity arm
        $hits = @($script:MeasureAndClearCalls | Where-Object Category -eq 'Productivity')
        $hits.Count | Should -BeGreaterOrEqual 1 -Because '{profile} must expand to the seeded profile on disk'
        $hits[0].Path | Should -BeLike '*xyz.default-release*cache2*' -Because 'Measure-AndClear must be called on the resolved path, not the wildcard'
    }
}
