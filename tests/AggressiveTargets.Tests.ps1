#requires -Version 5.1
# Pester v5 tests for the Aggressive-mode cleanup targets (items 2, 3, 4, 5, 6, 8, 10, 11).
#
# These tests pin the wiring (not the live drive): the new app-definition entries load,
# KeepLatest retention protects the live release / newest backup, the Package
# Maintenance arm is Aggressive-only and preview-safe, and the Downloads maintenance
# function only ever touches the two named product trees.
#
# Deletion is permanent and Preview is the only dry run. Nothing here touches a live drive:
# every behavioural case runs on a $TestDrive fixture and asserts the SKIP REASON so it can
# never pass for the wrong reason (e.g. an unrelated IsAllowedPath block).
#
# Run: Invoke-Pester -Path tests/AggressiveTargets.Tests.ps1 -Output Detailed

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module "$repoRoot/src/Bakunawa.Core.psm1" -Force
    Import-Module "$repoRoot/src/Bakunawa.UI.psm1" -Force -DisableNameChecking
    Import-Module "$repoRoot/src/Bakunawa.Cleanup.psm1" -Force -DisableNameChecking
    Import-Module "$repoRoot/src/Bakunawa.Config.psm1" -Force -DisableNameChecking

    Mock -ModuleName Bakunawa.Cleanup Write-CommandLog { }

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

    function script:Enable-RealDeletion {
        & (Get-Module Bakunawa.Cleanup) {
            $script:IsPreview = $false
            $script:Planning = $false
        }
    }

    # Register-SkippedItem is defined in Core, so skip records live in the Core module's
    # $script:SkippedItems (Cleanup's own store is only touched when $script:Planning is set).
    function script:Get-CleanupSkipRecords {
        & (Get-Module Bakunawa.Core) { $script:SkippedItems }
    }
}

AfterAll {
    Remove-Module Bakunawa.Cleanup -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.UI -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.Config -ErrorAction SilentlyContinue
}

Describe 'KeepLatest is parsed from app definitions' {

    It 'exposes KeepLatest and the sibling pointer on the codex release definition' {
        $def = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'codex-release-cache' })
        # Exactly one definition: a second copy without keepTargetOf would retain
        # newest-by-timestamp only and could delete the live release.
        $def.Count | Should -Be 1 -Because 'a duplicate without KeepTargetOf could delete the live release'
        $def | Should -Not -BeNullOrEmpty
        $def[0].KeepLatest | Should -Be 1
        $def[0].Mode | Should -Be 'entry'
        # The junction lives one level up (app-server-daemon\current), not inside releases.
        $def[0].KeepTargetOf | Should -Be '..\current'
    }

    It 'exposes KeepLatest on the flattened OmniRoute db backup definition' {
        $def = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'OmniRoute' -and $_.Path -like '*db_backups*' })
        $def | Should -Not -BeNullOrEmpty
        $def[0].KeepLatest | Should -Be 1
        $def[0].Mode | Should -Be 'entry'
    }

    It 'defaults KeepLatest to 0 when the definition does not set it' {
        $def = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'codex-sessions' })
        $def | Should -Not -BeNullOrEmpty
        $def[0].KeepLatest | Should -Be 0
    }
}

Describe 'Aggressive Targets new definitions are wired' {

    It 'replaces the unsafe codex package cache with the release entry target' {
        @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'codex-package-cache' }) |
            Should -BeNullOrEmpty -Because 'contents mode on .codex/packages would wipe the live junction target'
        $def = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'codex-release-cache' })
        $def | Should -Not -BeNullOrEmpty
        $def[0].Path | Should -Match 'app-server-daemon[\\/]releases$'
        $def[0].Mode | Should -Be 'entry'
        @($def[0].EntryPatterns) | Should -Contain '*'
        $def[0].EntryType | Should -Be 'directory'
        $def[0].Category | Should -Be 'Dev Caches'
    }

    It 'adds the hermes uv cache as an ordinary Dev Cache' {
        $def = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'hermes-uv-cache' })
        $def | Should -Not -BeNullOrEmpty
        $def[0].Category | Should -Be 'Dev Caches'
        $def[0].Env | Should -Be 'LOCALAPPDATA'
        $def[0].Path | Should -Match 'hermes[\\/]cache[\\/]uv$'
    }

    It 'adds the codex sessions as an entry target with a one day age gate' {
        $def = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'codex-sessions' })
        $def | Should -Not -BeNullOrEmpty
        $def[0].Category | Should -Be 'AI Agent Caches'
        $def[0].Mode | Should -Be 'entry'
        @($def[0].EntryPatterns) | Should -Contain '*'
        $def[0].EntryType | Should -Be 'directory'
        $def[0].MinAgeDays | Should -Be 1
        $def[0].Path | Should -Match '\.codex[\\/]sessions$'
    }

    It 'ages OmniRoute call logs out at one day' {
        $def = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'OmniRoute' -and $_.Path -like '*call_logs*' })
        $def | Should -Not -BeNullOrEmpty
        $def[0].MinAgeDays | Should -Be 1
        $def[0].Mode | Should -Be 'entry'
    }

    It 'targets only the OmniRoute sqlite backups as files with newest retention' {
        $def = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'OmniRoute' -and $_.Path -like '*db_backups*' })
        $def | Should -Not -BeNullOrEmpty
        $def[0].Mode | Should -Be 'entry'
        @($def[0].EntryPatterns) | Should -Contain '*.sqlite*'
        $def[0].EntryType | Should -Be 'file'
        $def[0].KeepLatest | Should -Be 1
    }
}

Describe 'KeepLatest retention in Get-TransientEntryMatches' {

    BeforeEach {
        $script:root = Join-Path $TestDrive ("keeps_$([guid]::NewGuid().ToString('N'))")
        New-FixtureDir $script:root | Out-Null
        Reset-CleanupState
        & (Get-Module Bakunawa.Core) { $script:SkippedItems = @() }
    }

    It 'protects the newest entry when there is no current pointer' {
        $old = New-FixtureFile (Join-Path $script:root 'old.sqlite') 1024
        $new = New-FixtureFile (Join-Path $script:root 'new.sqlite') 2048
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-10)
        (Get-Item -LiteralPath $new).LastWriteTime = (Get-Date).AddDays(-1)

        $matches = @(Get-TransientEntryMatches -Directory $script:root -Patterns @('*.sqlite*') -EntryType 'file' -MinAgeDays 1 -KeepLatest 1)
        $oldMatch = @($matches | Where-Object { $_.FullName -eq $old })[0]
        $newMatch = @($matches | Where-Object { $_.FullName -eq $new })[0]

        $null -ne $newMatch | Should -Be $true
        $newMatch.Reason | Should -Be 'kept latest' -Because 'the newest entry is retained regardless of age'
        $null -ne $oldMatch | Should -Be $true
        $oldMatch.Reason | Should -Be $null -Because 'the older entry is still a candidate'
    }

    It 'never clears the retained entry, clearing only the older one' {
        $old = New-FixtureFile (Join-Path $script:root 'old.sqlite') 1024
        $new = New-FixtureFile (Join-Path $script:root 'new.sqlite') 2048
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-10)
        (Get-Item -LiteralPath $new).LastWriteTime = (Get-Date).AddDays(-1)
        Enable-RealDeletion

        $n = Clear-TransientEntries -Directory $script:root -Patterns @('*.sqlite*') -EntryType 'file' -MinAgeDays 1 -KeepLatest 1 -Category 'AI Agent Caches'

        $n | Should -Be 1
        Test-Path -LiteralPath $old | Should -Be $false -Because 'the older backup is a candidate'
        Test-Path -LiteralPath $new | Should -Be $true -Because 'the newest backup is retained even though it is past the age gate'
    }

    # Mirrors the real Codex layout: app-server-daemon\current -> releases\<live>, so the
    # live release is NOT the newest one and is reachable only through the pointer.
    It 'protects the release a sibling junction names, even when it is not the newest' {
        $parent = Join-Path $script:root 'app-server-daemon'
        $releases = Join-Path $parent 'releases'
        $live = Join-Path $releases '0.1.0'
        $newest = Join-Path $releases '0.2.0'
        New-FixtureDir $live | Out-Null
        New-FixtureDir $newest | Out-Null
        New-FixtureFile (Join-Path $live 'server.exe') 1024
        New-FixtureFile (Join-Path $newest 'server.exe') 1024
        (Get-Item -LiteralPath $live).LastWriteTime = (Get-Date).AddDays(-20)
        (Get-Item -LiteralPath $newest).LastWriteTime = (Get-Date).AddDays(-10)
        $null = New-Item -ItemType Junction -Path (Join-Path $parent 'current') -Target $live

        $matches = @(Get-TransientEntryMatches -Directory $releases -Patterns @('*') -EntryType 'directory' -MinAgeDays 1 -KeepLatest 1 -KeepTargetOf '..\current')
        $liveMatch = @($matches | Where-Object { $_.FullName -eq $live })[0]
        $newestMatch = @($matches | Where-Object { $_.FullName -eq $newest })[0]

        $null -ne $liveMatch | Should -Be $true
        $liveMatch.Reason | Should -Be 'current release' -Because 'the junction target is the live release even though it is not the newest'
        # Newest wins by VERSION, not LastWriteTime: an unused newer build that happens
        # to carry a fresher timestamp must not push the live release out of retention.
        $null -ne $newestMatch | Should -Be $true
        $newestMatch.Reason | Should -Be 'kept latest' -Because 'retention is the newest version, which a pointer would switch to'
    }

    It 'keeps the live release when an unused newer build has a fresher timestamp' {
        $parent = Join-Path $script:root 'app-server-daemon'
        $releases = Join-Path $parent 'releases'
        $live = Join-Path $releases '0.99.0'
        $stale = Join-Path $releases '0.100.0'
        New-FixtureDir $live | Out-Null
        New-FixtureDir $stale | Out-Null
        New-FixtureFile (Join-Path $live 'server.exe') 1024
        New-FixtureFile (Join-Path $stale 'server.exe') 1024
        # '0.100.0' sorts before '0.99.0' but looks newer by LastWriteTime.
        (Get-Item -LiteralPath $live).LastWriteTime = (Get-Date).AddDays(-40)
        (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddDays(-1)
        $null = New-Item -ItemType Junction -Path (Join-Path $parent 'current') -Target $live
        Enable-RealDeletion

        $n = Clear-TransientEntries -Directory $releases -Patterns @('*') -EntryType 'directory' -MinAgeDays 1 -KeepLatest 1 -KeepTargetOf '..\current' -Category 'Dev Caches'

        $n | Should -Be 0 -Because 'both the live release and the newest version are retained, so nothing is disposable'
        Test-Path -LiteralPath $live -PathType Container | Should -Be $true
        Test-Path -LiteralPath $stale -PathType Container | Should -Be $true
    }

    It 'clears a release that is neither the live one nor the newest version' {
        $parent = Join-Path $script:root 'app-server-daemon'
        $releases = Join-Path $parent 'releases'
        $live = Join-Path $releases '0.1.0'
        $stale = Join-Path $releases '0.1.5'
        $newest = Join-Path $releases '0.2.0'
        foreach ($dir in @($live, $stale, $newest)) {
            New-FixtureDir $dir | Out-Null
            New-FixtureFile (Join-Path $dir 'server.exe') 1024
            (Get-Item -LiteralPath $dir).LastWriteTime = (Get-Date).AddDays(-30)
        }
        $null = New-Item -ItemType Junction -Path (Join-Path $parent 'current') -Target $live
        Enable-RealDeletion

        $n = Clear-TransientEntries -Directory $releases -Patterns @('*') -EntryType 'directory' -MinAgeDays 1 -KeepLatest 1 -KeepTargetOf '..\current' -Category 'Dev Caches'

        $n | Should -Be 1 -Because 'only the release that is neither live nor newest is disposable'
        Test-Path -LiteralPath $live -PathType Container | Should -Be $true -Because 'the live release must survive, via the real directory and via current'
        Test-Path -LiteralPath $newest -PathType Container | Should -Be $true -Because 'the newest version is retained'
        Test-Path -LiteralPath $stale -PathType Container | Should -Be $false
    }

    It 'clears every release below the live one when the newest is the live one' {
        $parent = Join-Path $script:root 'app-server-daemon'
        $releases = Join-Path $parent 'releases'
        $stale = Join-Path $releases '0.1.0'
        $live = Join-Path $releases '0.2.0'
        New-FixtureDir $stale | Out-Null
        New-FixtureDir $live | Out-Null
        New-FixtureFile (Join-Path $stale 'server.exe') 1024
        New-FixtureFile (Join-Path $live 'server.exe') 1024
        (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddDays(-30)
        (Get-Item -LiteralPath $live).LastWriteTime = (Get-Date).AddDays(-30)
        $null = New-Item -ItemType Junction -Path (Join-Path $parent 'current') -Target $live
        Enable-RealDeletion

        $n = Clear-TransientEntries -Directory $releases -Patterns @('*') -EntryType 'directory' -MinAgeDays 1 -KeepLatest 1 -KeepTargetOf '..\current' -Category 'Dev Caches'

        $n | Should -Be 1 -Because 'this is the steady state: every release except the live/newest one goes'
        Test-Path -LiteralPath $stale -PathType Container | Should -Be $false
        Test-Path -LiteralPath $live -PathType Container | Should -Be $true
    }

    It 'ignores a pointer that resolves outside the container' {
        $outside = Join-Path $TestDrive 'elsewhere'
        New-FixtureDir $outside | Out-Null
        $old = Join-Path $script:root '0.1.0'
        New-FixtureDir $old | Out-Null
        $newer = Join-Path $script:root '0.2.0'
        New-FixtureDir $newer | Out-Null
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-30)
        (Get-Item -LiteralPath $newer).LastWriteTime = (Get-Date).AddDays(-20)
        $null = New-Item -ItemType Junction -Path (Join-Path $script:root 'current') -Target $outside

        $matches = @(Get-TransientEntryMatches -Directory $script:root -Patterns @('*') -EntryType 'directory' -MinAgeDays 1 -KeepLatest 1 -KeepTargetOf 'current')

        @($matches | Where-Object { $_.Reason -eq 'current release' }) | Should -BeNullOrEmpty -Because 'an outside target cannot be an entry of this container'
        # The broken pointer protects nothing, so the newest-N rule decides on its own.
        $oldMatch = @($matches | Where-Object { $_.FullName -eq $old })[0]
        $newerMatch = @($matches | Where-Object { $_.FullName -eq $newer })[0]
        $oldMatch.Reason | Should -Be $null -Because 'the older name sorts below the newest version, so it is disposable'
        $newerMatch.Reason | Should -Be 'kept latest'
    }

    It 'leaves a recent entry in place in preview mode' {
        $fresh = New-FixtureFile (Join-Path $script:root 'fresh.sqlite') 1024

        $n = Clear-TransientEntries -Directory $script:root -Patterns @('*.sqlite*') -EntryType 'file' -MinAgeDays 1 -KeepLatest 1 -Category 'AI Agent Caches'

        $n | Should -Be 0
        Test-Path -LiteralPath $fresh | Should -Be $true -Because 'Preview is the only dry run'
    }
}

Describe 'Package Maintenance task wiring' {

    BeforeEach {
        Reset-CleanupState
        & (Get-Module Bakunawa.Core) { $script:SkippedItems = @() }
        Mock -ModuleName Bakunawa.Cleanup Get-ScanDriveRoots { @($TestDrive) }
    }

    It 'lists Package Maintenance only in Aggressive mode' {
        @(Get-CleanupTasks -Mode 'Standard' | Where-Object { $_.Name -eq 'Package Maintenance' }) |
            Should -BeNullOrEmpty -Because 'Downloads maintenance is an Aggressive-only task'
        @(Get-CleanupTasks -Mode 'Aggressive' | Where-Object { $_.Name -eq 'Package Maintenance' }) |
            Should -Not -BeNullOrEmpty -Because 'the Aggressive mode exposes the task'
    }

    It 'defaults Package Maintenance to disabled, Moderate risk' {
        $cfg = Get-DefaultConfig
        $cfg.taskCategories['Package Maintenance'].enabled | Should -Be $false
        $cfg.taskCategories['Package Maintenance'].riskTier | Should -Be 'Moderate'
    }

    It 'measures Package Maintenance instead of reporting it as unmeasured' {
        Mock -ModuleName Bakunawa.Cleanup Join-EnvPath { return $null }
        $script:fixtureDownloads = Join-Path $TestDrive 'downloads_measure'
        New-FixtureDir $script:fixtureDownloads | Out-Null
        New-FixtureFile (Join-Path $script:fixtureDownloads 'App.Setup.exe') 4096
        (Get-Item -LiteralPath (Join-Path $script:fixtureDownloads 'App.Setup.exe')).LastWriteTime = (Get-Date).AddDays(-60)
        Mock -ModuleName Bakunawa.Cleanup Join-EnvPath {
            param($Name, [Parameter(ValueFromRemainingArguments = $true)][string[]]$ChildPath)
            if ($Name -eq 'USERPROFILE' -and $ChildPath -and $ChildPath.Count -eq 1 -and $ChildPath[0] -eq 'Downloads') {
                return $script:fixtureDownloads
            }
            return $null
        }

        $p = Get-CleanupPotential -Mode 'Aggressive' -TaskName 'Package Maintenance'

        $p.Status | Should -Be 'ok' -Because 'a task without a measurement arm reports zero bytes as if nothing were there'
        $p.EstimatedBytes | Should -Be 4096 -Because 'the old installer is measurable reclaim'
        $p.FileCount | Should -Be 1
    }

    It 'clears old installers and spares recent and non-installer files' {
        $script:downloads = Join-Path $TestDrive 'downloads_tree'
        New-FixtureDir $script:downloads | Out-Null
        New-FixtureDir (Join-Path $script:downloads 'Telegram Desktop\AyuGram\tdata') | Out-Null
        $old = New-FixtureFile (Join-Path $script:downloads 'App.Setup.exe') 4096
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-60)
        $recent = New-FixtureFile (Join-Path $script:downloads 'Setup.exe') 4096
        $other = New-FixtureFile (Join-Path $script:downloads 'notes.txt') 4096
        (Get-Item -LiteralPath $other).LastWriteTime = (Get-Date).AddDays(-200)
        $appExe = New-FixtureFile (Join-Path $script:downloads 'Telegram Desktop\AyuGram\AyuGram.exe') 8192
        (Get-Item -LiteralPath $appExe).LastWriteTime = (Get-Date).AddDays(-60)
        $updater = New-FixtureFile (Join-Path $script:downloads 'Telegram Desktop\AyuGram\Updater.exe') 4096
        (Get-Item -LiteralPath $updater).LastWriteTime = (Get-Date).AddDays(-60)
        $session = New-FixtureFile (Join-Path $script:downloads 'Telegram Desktop\AyuGram\tdata\session.bin') 4096
        Mock -ModuleName Bakunawa.Cleanup Join-EnvPath {
            param($Name, [Parameter(ValueFromRemainingArguments = $true)][string[]]$ChildPath)
            if ($Name -eq 'USERPROFILE' -and $ChildPath -and $ChildPath.Count -eq 1 -and $ChildPath[0] -eq 'Downloads') {
                return $script:downloads
            }
            return $null
        }

        Enable-RealDeletion
        $n = Clear-DownloadsMaintenance

        $n | Should -Be 3
        Test-Path -LiteralPath $old | Should -Be $false -Because 'an old installer is reclaimable'
        Test-Path -LiteralPath $recent | Should -Be $true -Because 'a recent installer is protected by the age gate'
        Test-Path -LiteralPath $other | Should -Be $true -Because 'a plain text file is not an installer'
        Test-Path -LiteralPath $appExe | Should -Be $false -Because 'the stale portable app binary is a candidate'
        Test-Path -LiteralPath $updater | Should -Be $false -Because 'the stale updater is a candidate'
        Test-Path -LiteralPath $session | Should -Be $true -Because 'tdata holds the session and must never be removed'
        Test-Path -LiteralPath (Join-Path $script:downloads 'Telegram Desktop\AyuGram') -PathType Container |
            Should -Be $true -Because 'only the matched binaries are removed; the portable app folder stays for a re-download'
        Test-Path -LiteralPath (Join-Path $script:downloads 'Telegram Desktop\AyuGram\tdata') -PathType Container |
            Should -Be $true -Because 'only files directly in the app root are matched'
    }

    It 'leaves matched files in place in preview mode' {
        $script:downloads = Join-Path $TestDrive 'downloads_preview'
        New-FixtureDir $script:downloads | Out-Null
        $old = New-FixtureFile (Join-Path $script:downloads 'App.Setup.exe') 4096
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-60)
        Mock -ModuleName Bakunawa.Cleanup Join-EnvPath {
            param($Name, [Parameter(ValueFromRemainingArguments = $true)][string[]]$ChildPath)
            if ($Name -eq 'USERPROFILE' -and $ChildPath -and $ChildPath.Count -eq 1 -and $ChildPath[0] -eq 'Downloads') {
                return $script:downloads
            }
            return $null
        }

        $null = Clear-DownloadsMaintenance

        Test-Path -LiteralPath $old | Should -Be $true -Because 'Preview is the only dry run'
    }

    It 'records Scoop not installed when the executable is absent' {
        $script:downloads = Join-Path $TestDrive 'downloads_noscoop'
        New-FixtureDir $script:downloads | Out-Null
        Mock -ModuleName Bakunawa.Cleanup Join-EnvPath { return $null }
        Mock -ModuleName Bakunawa.Cleanup Get-Command { return $null }
        Mock -ModuleName Bakunawa.Cleanup Clear-EventLogs { return $false }
        Mock -ModuleName Bakunawa.Cleanup Clear-FontCache { return $false }
        Mock -ModuleName Bakunawa.Cleanup Clear-Prefetch { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-SystemCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-DevCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-AppCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-AIAgentCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-GameCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-BrowserAutomationCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-PackageManagerCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-GpuAndShellCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-RecycleBinSafe { return $false }
        Mock -ModuleName Bakunawa.Cleanup Clear-ThumbnailCache { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-SystemLogFiles { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Remove-EmptyDirectories { return }
        Mock -ModuleName Bakunawa.Cleanup Remove-StaleJunkFolders { return }
        Mock -ModuleName Bakunawa.Cleanup Find-OrphanFolders { return @() }
        Mock -ModuleName Bakunawa.Cleanup Clear-CachedOrphans { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { return @() }
        Mock -ModuleName Bakunawa.Cleanup Get-ScanDriveRoots { @($TestDrive) }
        Mock -ModuleName Bakunawa.Cleanup Get-EnvPath { return $null }

        $config = Get-DefaultConfig
        $config.taskCategories['Package Maintenance'].enabled = $true

        $null = Invoke-CleanupRun -Mode Aggressive -Config $config

        @((Get-CleanupSkipRecords) | Where-Object { $_.Reason -match 'Scoop not installed' }) |
            Should -Not -BeNullOrEmpty -Because 'a missing scoop must be skipped, never queued'
    }

    It 'queues scoop cleanup with the -a switch, never a bare glob' {
        $script:downloads = Join-Path $TestDrive 'downloads_scoopinvoke'
        New-FixtureDir $script:downloads | Out-Null
        Mock -ModuleName Bakunawa.Cleanup Join-EnvPath { return $null }
        Mock -ModuleName Bakunawa.Cleanup Clear-EventLogs { return $false }
        Mock -ModuleName Bakunawa.Cleanup Clear-FontCache { return $false }
        Mock -ModuleName Bakunawa.Cleanup Clear-Prefetch { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-SystemCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-DevCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-AppCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-AIAgentCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-GameCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-BrowserAutomationCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-PackageManagerCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-GpuAndShellCaches { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-RecycleBinSafe { return $false }
        Mock -ModuleName Bakunawa.Cleanup Clear-ThumbnailCache { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Clear-SystemLogFiles { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Remove-EmptyDirectories { return }
        Mock -ModuleName Bakunawa.Cleanup Remove-StaleJunkFolders { return }
        Mock -ModuleName Bakunawa.Cleanup Find-OrphanFolders { return @() }
        Mock -ModuleName Bakunawa.Cleanup Clear-CachedOrphans { return 0 }
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { return @() }
        Mock -ModuleName Bakunawa.Cleanup Get-ScanDriveRoots { @($TestDrive) }
        Mock -ModuleName Bakunawa.Cleanup Get-EnvPath { return $null }
        # Live-safety: this test performs a REAL (non-preview) run, so the execution
        # phase would invoke the queued action. A stub scoop.cmd is placed first on
        # PATH for the duration; the machine's actual scoop can never be reached.
        $stubDir = Join-Path $TestDrive 'scoop_stub'
        New-FixtureDir $stubDir | Out-Null
        $stubLog = Join-Path $stubDir 'invoked.log'
        Set-Content -LiteralPath (Join-Path $stubDir 'scoop.cmd') -Value ('@echo %*>> "' + $stubLog + '"')
        $oldPath = $env:PATH
        $env:PATH = "$stubDir;$oldPath"
        try {
            $config = Get-DefaultConfig
            $config.taskCategories['Package Maintenance'].enabled = $true

            $null = Invoke-CleanupRun -Mode Aggressive -Config $config
        } finally {
            $env:PATH = $oldPath
        }

        $pending = @(& (Get-Module Bakunawa.Cleanup) { $script:PendingActions })
        $pending.Count | Should -Be 0 -Because 'the action is executed during a real run and cleared afterwards'
        $skip = @(Get-CleanupSkipRecords | Where-Object { $_.Path -eq 'scoop' })
        $skip | Should -BeNullOrEmpty -Because 'the stub scoop is found, so nothing is skipped'
        # The stub proves the execution phase really invoked scoop, and with which args.
        Get-Content -LiteralPath $stubLog | Should -Match 'cleanup -a'

        # The queued action is only observable through the PREVIEW log line: read the
        # source and assert the switch form, so a bare '*' cannot come back.
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\Bakunawa.Cleanup.psm1') -Raw
        $source | Should -Match "scoop cleanup -a"
        # A bare '*' only ever appears as a glob; scoop needs the -a all-apps switch.
        $source | Should -Not -Match "scoop cleanup \*"
    }
}
