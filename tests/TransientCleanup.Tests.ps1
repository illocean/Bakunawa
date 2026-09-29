#requires -Version 5.1
# Pester v5 tests for transient (install-staging) cleanup and permanent deletion.
#
# These tests pin the behaviour the previous code could not express: Measure-AndClear
# clears a directory's CHILDREN and ignores non-containers, so it can never remove a staging
# file or a staging folder itself. Pointing it at a container such as the npm prefix would
# delete the tool's own shims.
#
# Deletion is permanent: there is no recovery copy and the space is reclaimed immediately.
# Preview mode is the only dry run.
#
# Run: Invoke-Pester -Path tests/TransientCleanup.Tests.ps1 -Output Detailed

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module "$repoRoot/src/Bakunawa.Core.psm1" -Force
    Import-Module "$repoRoot/src/Bakunawa.UI.psm1" -Force -DisableNameChecking
    Import-Module "$repoRoot/src/Bakunawa.Cleanup.psm1" -Force -DisableNameChecking
    Import-Module "$repoRoot/src/Bakunawa.Config.psm1" -Force -DisableNameChecking

    # Every test works on disposable fixtures; no live drive cleanup is needed.
    Mock -ModuleName Bakunawa.Cleanup Get-ScanDriveRoots { @($TestDrive) }
    Mock -ModuleName Bakunawa.Cleanup Write-CommandLog { }

    $script:NpmStagingPatterns = @('.omniroute-*', '.opencode-ai-*', '.*-????????')

    function script:New-FixtureFile {
        param([string]$Path, [int]$Bytes = 512)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
        return $Path
    }

    function script:New-FixtureDir {
        param([string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        return $Path
    }

    # Baseline module state: preview on, no planning. Never deletes.
    function script:Reset-CleanupState {
        & (Get-Module Bakunawa.Cleanup) {
            $script:IsPreview = $true
            $script:Planning = $false
            $script:ActiveCategory = $null
            $script:BytesFreed = 0L
            $script:TaskCleared = 0
            $script:TaskBytes = 0L
            $script:TaskSkipped = 0
            $script:CategorySizes = @{}
            $script:Errors = @()
            $script:SkippedItems = @()
            $script:CandidateRecords = [Collections.Generic.List[object]]::new()
            $script:ProcessedCacheRoots = New-TrackedSet
            $script:BusyCachePaths = [Collections.Generic.List[string]]::new()
            $script:ExcludedPaths = $null
            $script:CleanupConfig = $null
            $script:IsAggressive = $false
        }
    }

    # Let fixture deletions actually happen. Only ever used against $TestDrive paths.
    function script:Enable-RealDeletion {
        & (Get-Module Bakunawa.Cleanup) {
            $script:IsPreview = $false
            $script:Planning = $false
        }
    }
}

AfterAll {
    Remove-Module Bakunawa.Cleanup -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.UI -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.Config -ErrorAction SilentlyContinue
}

Describe 'App definitions: entry-mode fields' {

    It 'loads entry-mode locations with their patterns and entry type' {
        $entryDefs = @(Get-AllAppDefinitions -Category 'Dev Caches' | Where-Object { $_.Mode -eq 'entry' })
        $entryDefs | Should -Not -BeNullOrEmpty

        $vsCode = @($entryDefs | Where-Object { $_.Name -eq 'VS Code' })
        $vsCode.Count | Should -Be 1 -Because '.vscode/extensions is the only VS Code entry-mode location'
        $vsCode[0].EntryType | Should -Be 'directory' -Because '.obsolete is a file and must never be swept'
        $vsCode[0].EntryPatterns | Should -Contain '.*'
        $vsCode[0].EntryPatterns | Should -Contain '*.vsctmp'

        $npm = @($entryDefs | Where-Object { $_.Name -eq 'npm-staging-temps' })
        $npm.Count | Should -Be 2 -Because 'both the npm prefix and its node_modules stage installs'
        foreach ($entry in $npm) {
            $entry.EntryPatterns | Should -Contain '.omniroute-*'
            $entry.EntryPatterns | Should -Contain '.opencode-ai-*'
        }
    }

    It 'defaults every other location to contents mode (no behaviour change for existing definitions)' {
        $defs = @(Get-AllAppDefinitions -Category 'Dev Caches')
        $contents = @($defs | Where-Object { $_.Mode -ne 'entry' })
        $contents | Should -Not -BeNullOrEmpty
        foreach ($entry in $contents) {
            $entry.Mode | Should -Be 'contents'
            @($entry.EntryPatterns).Count | Should -Be 0
        }
    }

    It 'leaves the age gate to the configured scan age unless a definition overrides it' {
        $defs = @(Get-AllAppDefinitions -Category 'Dev Caches' | Where-Object { $_.Mode -eq 'entry' })
        foreach ($entry in $defs) { $entry.MinAgeDays | Should -Be 0 -Because '0 means: use the configured scan age' }
        Get-TransientAgeDays | Should -BeGreaterThan 0
    }
}

Describe 'Get-TransientEntryMatches' {

    BeforeEach {
        Reset-CleanupState
        $script:root = Join-Path $TestDrive ("pester_transient_$([guid]::NewGuid().ToString('N'))")
        New-FixtureDir $script:root | Out-Null
    }

    It 'matches by name pattern without descending into subdirectories' {
        New-FixtureFile (Join-Path $script:root '.omniroute-abc12345') | Out-Null
        $nested = Join-Path (Join-Path $script:root 'sub') '.omniroute-deadbeef'
        New-FixtureFile $nested | Out-Null

        $matches = @(Get-TransientEntryMatches -Directory $script:root -Patterns $script:NpmStagingPatterns)
        $matches.Count | Should -Be 1 -Because 'a nested staging file belongs to another container, not this one'
        $matches[0].Name | Should -Be '.omniroute-abc12345'
    }

    It 'leaves legitimate npm shims alone' {
        foreach ($name in @('npm', 'npm.cmd', 'npm.ps1', 'opencode', 'node_modules', 'package.json', '.bin')) {
            New-FixtureFile (Join-Path $script:root $name) | Out-Null
        }
        @(Get-TransientEntryMatches -Directory $script:root -Patterns $script:NpmStagingPatterns).Count | Should -Be 0
    }

    It 'honours EntryType directory so a dot-prefixed FILE is not matched' {
        New-FixtureFile (Join-Path $script:root '.obsolete') | Out-Null
        New-FixtureDir (Join-Path $script:root '.4f1c2b3a-0000-0000-0000-000000000000') | Out-Null

        $dirs = @(Get-TransientEntryMatches -Directory $script:root -Patterns @('.*', '*.vsctmp') -EntryType 'directory')
        $dirs.Count | Should -Be 1
        $dirs[0].Name | Should -Not -Be '.obsolete'

        $any = @(Get-TransientEntryMatches -Directory $script:root -Patterns @('.*') -EntryType 'any')
        $any.Count | Should -Be 2 -Because 'without the type filter both the file and the folder match'
    }

    It 'reports not stale for an entry newer than the age gate' {
        New-FixtureFile (Join-Path $script:root '.omo-fresh123') | Out-Null
        $matches = @(Get-TransientEntryMatches -Directory $script:root -Patterns $script:NpmStagingPatterns -MinAgeDays 30)
        $matches.Count | Should -Be 1
        $matches[0].Reason | Should -Be 'not stale'
    }

    It 'reports an empty reason and a measured size for a stale entry' {
        $file = New-FixtureFile (Join-Path $script:root '.omo-stale123')
        (Get-Item -LiteralPath $file).LastWriteTime = (Get-Date).AddDays(-90)
        $matches = @(Get-TransientEntryMatches -Directory $script:root -Patterns $script:NpmStagingPatterns -MinAgeDays 30)
        $matches.Count | Should -Be 1
        $matches[0].Reason | Should -BeNullOrEmpty
        $matches[0].Bytes | Should -Be 512
    }

    It 'returns nothing for a missing container and records no error' {
        $errorsBefore = @(Get-CleanupErrorLog).Count
        $matches = @(Get-TransientEntryMatches -Directory (Join-Path $script:root 'not-installed') -Patterns $script:NpmStagingPatterns)
        $matches.Count | Should -Be 0
        @(Get-CleanupErrorLog).Count | Should -Be $errorsBefore
    }
}

Describe 'Clear-TransientEntries' {

    BeforeEach {
        $script:root = Join-Path $TestDrive ("pester_clear_$([guid]::NewGuid().ToString('N'))")
        New-FixtureDir $script:root | Out-Null
        Reset-CleanupState
    }

    It 'removes the matched entry itself and keeps the container and its siblings' {
        $stale = New-FixtureFile (Join-Path $script:root '.omo-stale123')
        (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddDays(-90)
        $keep = New-FixtureFile (Join-Path $script:root 'npm.cmd')
        Enable-RealDeletion

        $removed = Clear-TransientEntries -Directory $script:root -Patterns $script:NpmStagingPatterns -MinAgeDays 30

        $removed | Should -Be 1
        Test-Path -LiteralPath $stale | Should -Be $false -Because 'the staging entry itself must go'
        Test-Path -LiteralPath $script:root -PathType Container | Should -Be $true -Because 'the container is never removed'
        Test-Path -LiteralPath $keep | Should -Be $true -Because 'a non-matching sibling must survive'
    }

    It 'removes a matched staging FOLDER, not just its contents' {
        $staging = New-FixtureDir (Join-Path $script:root '.opencode-ai-deadbeef')
        New-FixtureFile (Join-Path $staging 'package.json') | Out-Null
        (Get-Item -LiteralPath $staging).LastWriteTime = (Get-Date).AddDays(-90)
        Enable-RealDeletion

        $removed = Clear-TransientEntries -Directory $script:root -Patterns $script:NpmStagingPatterns -MinAgeDays 30

        $removed | Should -Be 1
        Test-Path -LiteralPath $staging | Should -Be $false -Because 'Measure-AndClear would have emptied it and left the folder behind'
    }

    It 'keeps an entry that is newer than the age gate' {
        $fresh = New-FixtureFile (Join-Path $script:root '.omo-fresh123')
        Enable-RealDeletion

        Clear-TransientEntries -Directory $script:root -Patterns $script:NpmStagingPatterns -MinAgeDays 30 | Should -Be 0
        Test-Path -LiteralPath $fresh | Should -Be $true -Because 'an install may be in progress'
    }

    It 'records a skip with a reason instead of deleting when the age gate blocks' {
        New-FixtureFile (Join-Path $script:root '.omo-fresh123') | Out-Null
        & (Get-Module Bakunawa.Cleanup) { $script:Planning = $true }

        $null = Clear-TransientEntries -Directory $script:root -Patterns $script:NpmStagingPatterns -MinAgeDays 30

        $records = @(& (Get-Module Bakunawa.Cleanup) { $script:CandidateRecords })
        $records.Count | Should -Be 1
        $records[0].Status | Should -Be 'Skipped'
        $records[0].Reason | Should -Be 'not stale'
    }

    It 'returns 0 for a missing container without throwing' {
        { Clear-TransientEntries -Directory (Join-Path $script:root 'nope') -Patterns $script:NpmStagingPatterns } | Should -Not -Throw
        Clear-TransientEntries -Directory (Join-Path $script:root 'nope') -Patterns $script:NpmStagingPatterns | Should -Be 0
    }
}

Describe 'Dev Caches arm: entry-mode must never reach Measure-AndClear' {

    BeforeEach {
        $script:container = Join-Path $TestDrive ("pester_container_$([guid]::NewGuid().ToString('N'))")
        New-FixtureDir $script:container | Out-Null
        # A staging entry and a shim that must survive, exactly like the npm prefix.
        $script:staging = New-FixtureFile (Join-Path $script:container '.omniroute-abc12345')
        (Get-Item -LiteralPath $script:staging).LastWriteTime = (Get-Date).AddDays(-90)
        $script:shim = New-FixtureFile (Join-Path $script:container 'npm.cmd')

        Reset-CleanupState
        $script:measureCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions {
            param([string]$Category)
            @([PSCustomObject]@{
                Name = 'fake-staging'; Path = $script:container; Env = 'TEST'; Process = $null
                Category = 'Dev Caches'; SourceFile = 'fixture.json'; Mode = 'entry'
                EntryPatterns = @('.omniroute-*'); EntryType = 'any'; MinAgeDays = 0
            })
        }
        Mock -ModuleName Bakunawa.Cleanup Measure-AndClear {
            param([string]$Path, [switch]$EnsureDirectory, [string]$Category)
            $script:measureCalls.Add($Path)
            return $true
        }
    }

    It 'never calls Measure-AndClear on the entry-mode container or anything inside it' {
        $null = Clear-DevCaches
        $offenders = @($script:measureCalls | Where-Object {
            [Bakunawa.Scanner]::Within($_, $script:container) -or [Bakunawa.Scanner]::Within($script:container, $_)
        })
        $offenders.Count | Should -Be 0 -Because 'clearing the container would delete the tool own files'
    }

    It 'still detects the staging entry through the transient path' {
        $matches = @(Get-TransientEntryMatches -Directory $script:container -Patterns @('.omniroute-*') -MinAgeDays 30)
        $matches.Count | Should -Be 1
        $matches[0].Reason | Should -BeNullOrEmpty
    }

    It 'leaves the non-matching shim in place when it actually runs' {
        Enable-RealDeletion
        $removed = Clear-TransientEntries -Directory $script:container -Patterns @('.omniroute-*') -MinAgeDays 30
        $removed | Should -Be 1
        Test-Path -LiteralPath $script:shim | Should -Be $true
        Test-Path -LiteralPath $script:staging | Should -Be $false
    }
}

